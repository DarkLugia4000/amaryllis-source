"""Flight control, autopilot, propulsion and recovery."""

# ======================================================================
# From test_autopilot: Current-source AP capture, drift learning, propulsion and bundled display checks.
# ======================================================================
import json
import unittest

import project
from tests.test_builder import LuaRuntime, table, python_value, native_runtime
from tests.test_displays import HARNESS as UI_HARNESS

ROOT = project.ROOT
REPORT = ROOT / "output/tests/ap-route-capture"

AP_HARNESS = r"""
NOW=10
os.clock=function() return NOW end
os.__amaryllisLog=function() end
package=package or {path=''}
function clone(value)
    if type(value)~="table" then return value end
    local result={};for k,v in pairs(value) do result[k]=clone(v) end;return result
end
local loaded={}
function require(name)
    if name=='hardware' then return {thrust={}} end
    if loaded[name] then return loaded[name] end
    local source=assert(SOURCES['/'..name:gsub('%.','/')..'.lua'],name)
    loaded[name]=assert(load(source,'@'..name))()
    return loaded[name]
end
AP=require('avionics.autopilot')
Thrust=require('avionics.thrust')
function sample(io,at,x,z,heading,vx,vz)
    NOW=at
    local r=math.rad(heading)
    io.vessel={valid=true,at=at,uuid='ship',position={x=x,y=160,z=z},
        linearVelocity={x=vx,y=0,z=vz},forwardDirection={x=math.sin(r),y=0,z=-math.cos(r)},
        heading=heading,forwardSpeed=vx*math.sin(r)-vz*math.cos(r),
        altitude=160,verticalSpeed=0,geometryVerified=true,velocityFrameVerified=true,
        mass=200000,environment={airPressure=1,gravity={y=-9.8}}}
end
function fixture(heading,vx)
    local config=clone(CONFIG);config.thrust.enabled=true
    local thrust=Thrust.new(config)
    thrust.controllerReady=function() return true end
    thrust.activationReady=function() return true end
    thrust.fresh=function() return true end
    thrust.speedApplied=function() return {left=0,right=0} end
    for _,role in ipairs(thrust.UNITS) do
        thrust.units[role]={status={available=true,readings={{speedRaw=0,validity={speedRaw=true}}}}}
    end
    local io={config=config,identityReady=true,session='session',thrust=thrust,
        nowSeconds=function() return NOW end,inputs={raw={}}}
    for _,key in ipairs({'prop_forward','prop_reverse','left_press','left_lift','right_press','right_lift','ap_disconnect','altitude_up','altitude_down'}) do io.inputs.raw[key]=0 end
    sample(io,10,0,0,heading or 90,vx or 0,0)
    local controls={available=true,modes={heading='MANUAL',throttle='DIRECT',lateral='MANUAL'},
        targets={heading=72,speed=4,altitude=160},speedTargetUuid='ship',headingTargetUuid='ship',
        request=0,yaw=0,sideways=0,holds={},fresh=function() return true end}
    local ap=AP.new(config)
    ap.draft={name='Route',x=10000,z=0,altitude=180,cruiseSpeed=3}
    assert(ap:engage(io,controls,10))
    io.autopilot=ap
    return ap,io,controls,thrust
end
function step(ap,io,c,at,x,z,heading,vx,vz)
    sample(io,at,x or 0,z or 0,heading or 90,vx or 0,vz or 0)
    local proxy,why=ap:update(io,at,c);assert(proxy,why);return proxy
end
function cruising(ap,io,heading)
    ap.state='CRUISE';ap.primaryIdle=false;ap.speedTarget=3
    ap.guidanceAt=10;ap.lastAt=10;ap.turnSampleAt=10;ap.turnHeading=heading or 90;ap.yawRate=0
end
"""

CASES = {
'impact_is_an_emergency_stop': r"""
local ap,io,c=fixture();cruising(ap,io)
c.modes.throttle='SEL';c.targets.speed=4
io.motionWarnings={lastImpactEvent={seq=1,kind='POSSIBLE IMPACT',axis='MOTION',detail='DELTA V 18.00'}}
sample(io,11,3,0,90,3,0);assert(ap:update(io,11,c)==nil)
assert(not ap.active and ap.route==nil,'route cancelled')
assert(ap.reason=='EMERGENCY STOP: POSSIBLE IMPACT (MOTION)',ap.reason)
assert(c.request==0 and c.yaw==0 and c.targets.speed==0,'propulsion demand zero')
assert(c.requireNeutral and c.neutralCause=='EMERGENCY STOP','pilot takes over at neutral')
assert(c.modes.throttle=='SEL','pilot modes kept')
""",
'impact_before_engagement_does_not_stop_the_route': r"""
local _,io,c=fixture()
io.motionWarnings={lastImpactEvent={seq=3,kind='POSSIBLE IMPACT',axis='MOTION'}}
local ap=AP.new(io.config);ap.draft={name='Route',x=10000,z=0,altitude=180,cruiseSpeed=3}
assert(ap:engage(io,c,10));cruising(ap,io)
step(ap,io,c,11,3,0,90,3,0);assert(ap.active,'earlier impact ignored')
io.motionWarnings.lastImpactEvent={seq=4,kind='POSSIBLE IMPACT',axis='ROTATION'}
sample(io,12,6,0,90,3,0);assert(ap:update(io,12,c)==nil)
assert(not ap.active and ap.reason:find('ROTATION'),'a new impact stops it')
""",
'accel_is_only_the_initial_run_up_to_cruise': r"""
local ap,io,c=fixture();cruising(ap,io)
ap.state='ACCEL'
step(ap,io,c,11,3,0,90,2.5,0);assert(ap.state=='ACCEL','below cruise during the run-up is ACCEL')
step(ap,io,c,12,6,0,90,2.95,0);assert(ap.state=='CRUISE',ap.state)
step(ap,io,c,13,9,0,90,2.85,0);assert(ap.state=='CRUISE','a dip after reaching cruise stays CRUISE')
step(ap,io,c,14,12,0,90,1.5,0);assert(ap.state=='CRUISE','a large drop after reaching cruise stays CRUISE')
""",
'anchor_coast_hysteresis_and_return': r"""
for _,axis in ipairs({'forward','side'}) do
  for _,sign in ipairs({-1,1}) do
    local _,io,c=fixture(90,0)
    local a=require('avionics.anchor').new(io.config)
    assert(a:engage(io,10))
    local at=10
    local function drive(speed,x,z)
      at=at+1
      sample(io,at,x or 0,z or 0,90,axis=='forward' and speed or 0,axis=='side' and speed or 0)
      local p=assert(a:update(io,at,c))
      return axis=='forward' and p.request or p.sideways
    end
    drive(0)
    for _,speed in ipairs({.1,1,2,2.5,3}) do
      assert(math.abs(drive(sign*speed))<1e-9,'coast before rearm')
      assert(a.state=='COASTING' or a.state=='SETTLING')
    end
    assert(drive(sign*3.1)*sign<0,'brake above rearm')
    assert(drive(sign*2.5)*sign<0,'retain brake in hysteresis band')
    assert(math.abs(drive(sign*2))<1e-9,'release at stop threshold')
    assert(math.abs(drive(-sign*2.5))<1e-9,'reversal below rearm coasts')
    -- Return from either side; approach above requested speed coasts.
    local x=axis=='forward' and -sign*4 or 0
    local z=axis=='side' and -sign*4 or 0
    assert(drive(0,x,z)*sign>0,'return toward retained point')
    assert(math.abs(drive(sign*.8,x,z))<1e-9,'approach coasts')
    assert(drive(-sign*.8,x,z)*sign>0,'slow departure returns without high-speed braking')
    drive(0);drive(0);drive(0)
    assert(a.state=='ANCHORED')
    assert(math.abs(drive(sign*.1,axis=='forward' and 1 or 0,axis=='side' and 1 or 0))<1e-9,'captured hold band')
    assert(c.modes.throttle=='DIRECT' and c.targets.speed==4)
  end
end
""",
'acquisition_capture_and_acceleration': r"""
for _,vx in ipairs({4,-4}) do
    local ap,io,c=fixture(0,vx)
    local proxy=step(ap,io,c,10,0,0,0,vx)
    assert(ap.state=='ACQ' and proxy.apPrimaryIdle and proxy.sideways==0)
    for at=11,15 do proxy=step(ap,io,c,at,0,0,90,vx) end
    assert(ap.state=='CAPTURE' and proxy.apPrimaryIdle)
    for at=16,18 do proxy=step(ap,io,c,at,0,0,90,vx) end
    assert(ap.state=='ACCEL' and proxy.apPrimaryIdle and ap.speedTarget==0)
    proxy=step(ap,io,c,19,0,0,90,vx)
    assert(not proxy.apPrimaryIdle and math.abs(proxy.targets.speed-.5)<1e-9)
    assert(c.targets.heading==72 and c.targets.speed==4 and c.targets.altitude==180)
end
""",
'capture_corrects_both_sides_and_rejects_crossing': r"""
for _,side in ipairs({-1,1}) do
    local ap,io,c=fixture();ap.state='CAPTURE';ap.guidanceAt=10
    ap.turnSampleAt=10;ap.turnHeading=90;ap.yawRate=0
    local proxy=step(ap,io,c,11,0,side*3,90,4,0)
    assert(proxy.apPrimaryIdle and proxy.sideways*side<0)
    proxy=step(ap,io,c,12,0,0,90,4,side*.5)
    assert(ap.state=='CAPTURE' and ap.captureSettledSeconds==0)
    proxy=step(ap,io,c,13,0,side*.5,90,4,side*.1)
    assert(ap.state=='CAPTURE')
    step(ap,io,c,14,0,side*2.6,90,4,0)
    assert(ap.captureSettledSeconds==0)
end
""",
'fresh_settling_and_gaps': r"""
local ap,io,c=fixture()
ap:update(io,10,c)
for at=11,15 do NOW=at;ap:update(io,at,c) end
assert(ap.state=='ACQ','duplicate heading samples cannot complete acquisition')
for at=11,15 do step(ap,io,c,at,0,0,90,4,0) end
assert(ap.state=='CAPTURE')
step(ap,io,c,16,0,0,90,4,0)
assert(ap.captureSettledSeconds==2)
for at=16.1,17,.1 do NOW=at;ap:update(io,at,c) end
assert(ap.state=='CAPTURE','duplicate position samples cannot complete capture')
step(ap,io,c,22,0,0,90,4,0)
assert(ap.state=='CAPTURE' and ap.captureSettledSeconds==0)
for at=23,26 do step(ap,io,c,at,0,0,90,4,0) end
assert(ap.state=='ACCEL')
""",
'loose_heading_and_capture_wait': r"""
local ap,io,c=fixture(95,4)
for at=10,22 do step(ap,io,c,at,0,3,95,4,0) end
assert(ap.state=='CAPTURE','loose heading settling must allow route capture')
for at=23,300 do step(ap,io,c,at,0,3,95,4,0) end
assert(ap.active and ap.state=='CAPTURE' and ap.primaryIdle,'capture has no elapsed-time abort')
""",
'major_heading_error_reacquires': r"""
local ap,io,c=fixture();cruising(ap,io)
ap.headingBias=.7
local proxy=step(ap,io,c,11,0,0,60,3,0)
assert(ap.state=='ACQ' and proxy.apPrimaryIdle and ap.headingBias==.7)
assert(ap.captureSettledSeconds==0)
""",
'arrival_hands_over_to_anchor_at_once': r"""
for _,x in ipairs({9995,10001}) do
    local ap,io,c=fixture(0)
    step(ap,io,c,11,x,0,0,0,0)
    assert(not ap.active and ap.state=='ARRIVED','arrival disengages the autopilot in the same update')
    assert(io.positionAnchor.active and io.positionAnchor.state=='BRAKING' and io.positionAnchor.point.x==10000)
    ap:cancel(io,c,'DISENGAGED')
    assert(io.positionAnchor.active,'the anchor belongs to the pilot after the handover')
end
""",
'arrival_sets_selected_heading_to_cruise_heading': r"""
for _,mode in ipairs({'SEL','MANUAL'}) do
    local ap,io,c=fixture(0)
    c.modes=c.modes or {};c.targets=c.targets or {}
    c.modes.heading=mode;c.targets.heading=200
    step(ap,io,c,11,9995,0,0,0,0)
    assert(ap.state=='ARRIVED')
    if mode=='SEL' then
        assert(c.targets.heading==ap.headingTarget and c.targets.heading~=200,'SEL heading must become the cruise heading')
        assert(c.headingTargetUuid==ap.uuid)
    else assert(c.targets.heading==200,'other heading modes keep their target') end
end
""",
'disengage_sets_selected_heading_to_ap_heading': r"""
for _,mode in ipairs({'SEL','MANUAL'}) do
    local ap,io,c=fixture();cruising(ap,io)
    c.modes.heading=mode;c.targets.heading=200
    assert(ap.active and ap.headingTarget~=200)
    ap:cancel(io,c,'DISENGAGED')
    if mode=='SEL' then
        assert(c.targets.heading==ap.headingTarget and c.headingTargetUuid==ap.uuid,'SEL heading becomes the AP heading')
    else assert(c.targets.heading==200,'other heading modes keep their target') end
end
-- Cancelling an autopilot that is already off leaves the selection alone.
local ap,io,c=fixture();ap:cancel(io,c,'DISENGAGED');c.modes.heading='SEL';c.targets.heading=200;ap.headingTarget=90
ap:cancel(io,c,'DISENGAGED');assert(c.targets.heading==200)
""",
'unnamed_destination_uses_its_coordinates': r"""
assert(AP.label({x=1200.4,z=-350.6})=='1200, -351')
assert(AP.label({name='Dock',x=1,z=2})=='Dock')
assert(AP.label({name='   ',x=5,z=6})=='5, 6')
assert(AP.label({})==nil)
local ap,io,c=fixture();ap:cancel(io,c,'DISENGAGED')
assert(AP.new(io.config).draft.name==nil,'no default name')
assert(ap:edit(io,c,{type='ap_edit',key='name',value='Dock'},10) and ap.draft.name=='Dock')
assert(ap:edit(io,c,{type='ap_edit',key='name',value=''},10) and ap.draft.name==nil,'a blank name removes it')
assert(ap:snapshot(io,c,10).destination.label=='10000, 0')
sample(io,11,0,0,90,0,0)
assert(ap:engage(io,c,11))
assert(ap.route.entries[1].name=='10000, 0','the route carries the coordinate name')
""",
'drift_sign_qualification_rate_and_cap': r"""
for _,side in ipairs({-1,1}) do
    local ap,io,c=fixture();cruising(ap,io)
    local previous=0
    for at=11,80 do
        step(ap,io,c,at,(at-10)*3,side,ap.headingTarget,3,0)
        if at<=19 then assert(ap.headingBias==0,'bias must wait for eight seconds of qualified trend') end
        assert(math.abs(ap.headingBias-previous)<=.1000001)
        assert(math.abs(ap.headingBias)<=2)
        previous=ap.headingBias
    end
    assert(math.abs(ap.headingBias+side*2)<1e-9,'compensating heading must face into drift')
    local held=ap.headingBias
    for at=81,120 do step(ap,io,c,at,(at-10)*3,0,ap.headingTarget,3,0) end
    assert(ap.headingBias==held,'quiet lateral demand retains the learned bias')
end
""",
'drift_disturbance_duplicate_and_gap': r"""
local ap,io,c=fixture();cruising(ap,io)
for at=11,15 do step(ap,io,c,at,(at-10)*3,1,90,3,0) end
assert(ap.headingBias==0)
for at=15.1,20,.1 do NOW=at;ap:update(io,at,c) end
assert(ap.headingBias==0)
step(ap,io,c,25,45,1,90,3,0)
assert(ap.headingBias==0 and ap.driftSince==nil)
for at=26,32 do step(ap,io,c,at,(at-10)*3,1,90,3,0) end
assert(ap.headingBias==0)
""",
'drift_freezes_during_other_stages_and_reverses_slowly': r"""
local ap,io,c=fixture();local tuning=require('avionics.navigation_settings').values(io.config,'autopilot')
ap.headingBias=.5;ap.crossDemand=.1
for _,state in ipairs({'ACQ','CAPTURE','ACCEL','DECEL','RECOVERING'}) do
    ap.state=state;ap.driftSince=0;ap.driftSign=1;ap.driftFiltered=.1
    ap:updateHeadingBias(io.vessel,0,0,tuning,1,true)
    assert(ap.headingBias==.5 and ap.driftSince==nil)
end
ap.state='CRUISE';io.vessel.forwardSpeed=3
ap.crossDemand=-.1;ap.driftFiltered=0;ap.driftSince=nil
for at=11,19 do io.vessel.at=at;ap:updateHeadingBias(io.vessel,0,0,tuning,1,true) end
assert(ap.headingBias==.5)
io.vessel.at=20;ap:updateHeadingBias(io.vessel,0,0,tuning,1,true)
assert(ap.headingBias<.5)
""",
'recovery_reacquires_and_keeps_bias': r"""
local ap,io,c=fixture();cruising(ap,io);ap.headingBias=1
io.identityReady=false
assert(ap:update(io,10,c)==nil and ap.state=='RETRYING (1)')
io.identityReady=true
local proxy=step(ap,io,c,11,3,0,91,3,0)
assert(ap.state=='ACQ' and proxy.apPrimaryIdle and ap.headingBias==1)
assert(ap.driftSince==nil)
""",
'mode_selections_survive_input_faults_shortcut_and_rebinding': r"""
local ap,io,c=fixture()
io.autopilot=nil;io.inputs.valid=true;io.inputs.at=10;io.inventory={linkBridge='bridge'}
local Controls=require('avionics.controls');local selected=Controls.new(io.config)
selected.modes.heading='SEL';selected.modes.throttle='SEL'
selected.targets={altitude=160};selected.uuid='previous-vessel'
selected:update(io,10)
assert(selected.modes.heading=='SEL' and selected.modes.throttle=='SEL')
assert(selected.headingTargetUuid==nil and selected.speedTargetUuid==nil)
io.identityReady=false;NOW=11;io.inputs.at=11;selected:update(io,11)
assert(selected.modes.heading=='SEL' and selected.modes.throttle=='SEL')
io.identityReady=true;sample(io,12,0,0,90,0,0);io.inputs.at=12
selected.modes.throttle='MANUAL';selected.targets.heading=72;selected.requireNeutral=false
io.inputs.raw.ap_disconnect=15
selected:update(io,12)
assert(selected.modes.throttle=='MANUAL' and selected.modes.heading=='SEL')
io.inputs.raw.ap_disconnect=0;io.inputs.at=13;sample(io,13,0,0,90,0,0)
local ok,why=selected:mode(io,{axis='throttle',mode='DIRECT'},13)
assert(ok,why);assert(selected.modes.throttle=='DIRECT')
selected:clear();assert(selected.modes.heading=='SEL' and selected.modes.throttle=='DIRECT')
""",
'ap_arrival_and_cancel_preserve_every_pilot_mode_combination': r"""
for _,heading in ipairs({'MANUAL','SEL'}) do
    for _,throttle in ipairs({'MANUAL','SEL','DIRECT'}) do
        local ap,io,c=fixture()
        c.modes.heading=heading;c.modes.throttle=throttle
        step(ap,io,c,11,9995,0,90,0,0)
        assert(not ap.active and c.modes.heading==heading and c.modes.throttle==throttle)
        io.positionAnchor:cancel(c,'RELEASED')
        assert(c.modes.heading==heading and c.modes.throttle==throttle)
        ap.active=true;ap:cancel(io,c,'DISENGAGED')
        assert(c.modes.heading==heading and c.modes.throttle==throttle)
        assert(c.targets.heading==(heading=='SEL' and ap.headingTarget or 72) and c.targets.speed==4)
    end
end
""",
'checkpoint_compatibility_and_cancel': r"""
local ap,io,c=fixture();ap.headingBias=-1.2
local checkpoint=ap:checkpoint()
assert(checkpoint.headingBias==-1.2)
local restored=AP.new(io.config);assert(restored:restore(checkpoint))
assert(restored.headingBias==-1.2 and restored.state=='RECOVERING' and restored.primaryIdle)
checkpoint.headingBias=nil;assert(AP.new(io.config):restore(checkpoint))
checkpoint.headingBias=3;assert(not AP.new(io.config):restore(checkpoint))
checkpoint.headingBias=0/0;assert(not AP.new(io.config):restore(checkpoint))
checkpoint.headingBias=false;assert(not AP.new(io.config):restore(checkpoint))
ap.remoteOwner='remote';assert(ap:checkpoint()==nil)
ap:cancel(io,c,'PILOT DISENGAGED')
assert(not ap.active and not ap.primaryIdle and ap.route==nil)
assert(not c.requireNeutral and c.targets.heading==72 and c.targets.speed==4,"AP cancel hands levers back at their position")
""",
'endpoint_keeps_zero_requests_under_normal_lease_and_ramp': r"""
local ap,io,c,thrust=fixture()
thrust.headingDriveDemand=function() return .5 end
local targets=assert(thrust:makeTargets(io,10,ap:guidanceControls(c)))
__THRUST_TEST=true
local endpoint=assert(load(SOURCES['/endpoint-thrust.lua']))()
local state=endpoint.newState({coreId=0,enabled=true,bindingsVerified=true,maxCommandTtlSeconds=1},'thrust-ls','boot')
assert(endpoint.processPacket(state,0,{v=1,kind='thrust_session',role='thrust-ls',nodeBoot='boot',session='s'},CONFIG.protocol,10))
local requested={}
for _,drive in ipairs(state.drives) do requested[drive]=targets[drive] end
assert(endpoint.processPacket(state,0,{v=1,kind='thrust_command',role='thrust-ls',nodeBoot='boot',session='s',
    seq=1,ttlSeconds=1,targets=requested},CONFIG.protocol,10))
assert(state.leaseUntil==11 and state.desiredTargets['primary-left']==0)
assert(math.abs(endpoint.ramp(.5,state.desiredTargets['primary-left'],.25,.1)-.475)<1e-9)
assert(endpoint.ramp(.5,state.desiredTargets['primary-left'],.25,1)==.25)
""",
'primary_idle_bypasses_speed_loops_and_keeps_yaw_priority': r"""
local ap,io,c,thrust=fixture()
thrust.headingDriveDemand=function() return .8 end
thrust.speedDriveRequest=function() error('speed loop reached during AP idle') end
thrust.manualAccelerationDriveRequest=function() error('acceleration loop reached during AP idle') end
for _,mode in ipairs({'SEL','MANUAL','DIRECT'}) do
    local proxy=ap:guidanceControls(c);proxy.modes.throttle=mode;proxy.sideways=1
    local targets,why=thrust:makeTargets(io,10,proxy)
    assert(targets,why)
    assert(targets['primary-left']==0 and targets['primary-right']==0)
    local sum=0
    for name,value in pairs(targets) do
        assert(value>=0 and value<=1)
        if name:match('^lateral') then sum=sum+value end
    end
    assert(sum>0 and thrust.request.sideDemand<1)
    assert(thrust.request.primaryIdle and thrust.speedControl.state=='IDLE')
end
""",
'sel_overspeed_release_configuration_validation': r"""
local storage=require('avionics.storage');local config=clone(CONFIG)
assert(storage.validateConfig(config))
config.thrust.speed_overspeed_release_per_second=nil;assert(storage.validateConfig(config))
for _,value in ipairs({.01,.04,.1,1}) do
 config.thrust.speed_overspeed_release_per_second=value;assert(storage.validateConfig(config))
end
for _,value in ipairs({0,-.1,1.1,'fast',false,0/0}) do
 config.thrust.speed_overspeed_release_per_second=value
 local ok,why=storage.validateConfig(config)
 assert(not ok and why:find('speed_overspeed_release_per_second',1,true))
end
""",
'sel_overspeed_release_is_gentle_on_fresh_and_repeated_samples': r"""
for _,direction in ipairs({-1,1}) do
 for _,release in ipairs({.1,.04}) do
    local ap,io,c,thrust=fixture()
    local config=io.config.thrust;config.speed_overspeed_release_per_second=release
    config.speed_pid={kp=.5,ki=0,kd=0,integral_limit=1,derivative_filter_seconds=1}
    thrust.speedFeedforwardGain=function() return .025 end
    c.targets.speed=direction*5;c.modes.throttle='SEL'
    thrust.speedLoop={uuid='ship',initialized=true,integral=0,derivative=0,
        lastSampleAt=10,lastMeasurement=direction*5.5,outputAt=10,output=direction*.7}
    sample(io,10.2,0,0,90,direction*5.5,0)
    local out,why=thrust:speedDriveRequest(io,10.2,c);assert(out,why)
    assert(math.abs(out-direction*(.7-release*.2))<1e-9)
    NOW=10.3;out=assert(thrust:speedDriveRequest(io,10.3,c))
    assert(math.abs(out-direction*(.7-release*.3))<1e-9)
    config.speed_output_slew_per_second=.02
    sample(io,10.5,0,0,90,direction*5.5,0)
    local nextOut=assert(thrust:speedDriveRequest(io,10.5,c))
    assert(math.abs(nextOut-out+direction*.02*.2)<1e-9,'retain a slower configured general slew')
 end
end
""",
'sel_overspeed_release_preserves_acceleration_reversal_and_zero': r"""
for _,direction in ipairs({-1,1}) do
 local function request(target,measured,previous)
    local ap,io,c,thrust=fixture()
    local config=io.config.thrust
    config.speed_overspeed_release_per_second=nil
    config.speed_pid={kp=.5,ki=0,kd=0,integral_limit=1,derivative_filter_seconds=1}
    thrust.speedFeedforwardGain=function() return .025 end
    c.targets.speed=target;c.modes.throttle='SEL'
    thrust.speedLoop={uuid='ship',initialized=true,integral=0,derivative=0,
        lastSampleAt=10,lastMeasurement=measured,outputAt=10,output=previous}
    sample(io,10.2,0,0,90,measured,0)
    local out,why=thrust:speedDriveRequest(io,10.2,c);assert(out,why);return out
 end
 assert(math.abs(request(direction*5,direction*5.5,direction*.7)-direction*.68)<1e-9,'existing config gets gentle fallback')
 assert(math.abs(request(direction*5,direction*4,direction*.1)-direction*.15)<1e-9,'acceleration retains general slew')
 assert(math.abs(request(-direction*5,direction*5,direction*.7)-direction*.65)<1e-9,'reversal retains general slew')
 assert(math.abs(request(0,direction*5,direction*.7)-direction*.65)<1e-9,'SEL zero retains braking slew')
end
""",
'sel_zero_coast_rearm_and_explicit_setting': r"""
local ap,io,c,thrust=fixture();c.targets.speed=0;c.modes.throttle='SEL'
local function measure(at,value)
    sample(io,at,0,0,90,value,0)
    local out,why=thrust:speedDriveRequest(io,at,c);assert(out,why)
    return thrust.speedControl
end
assert(measure(10,1.9).zeroCoast)
assert(measure(11,2.5).zeroCoast)
assert(not measure(12,3.1).zeroCoast)
assert(measure(13,-.5).zeroCoast)
thrust:resetSpeedLoop();io.config.thrust.zero_brake_stop_bps=1
assert(not measure(14,1.5).zeroCoast)
thrust:resetSpeedLoop();io.config.thrust.zero_brake_stop_bps=nil
assert(measure(15,1.5).zeroCoast)
""",
'position_loss_fallback_is_preserved': r"""
local ap,io,c,thrust=fixture();cruising(ap,io)
local held=clone(c);held.targets.heading=90;held.targets.speed=3
thrust.routeHold={controls=held,at=10}
thrust.makeTargets=function(self,context,at,proxy)
    CAPTURED=proxy
    local targets={};for _,drive in ipairs(self.DRIVES) do targets[drive]=0 end;return targets
end
thrust.send=function() return true end
sample(io,11,3,0,90,3,0);io.vessel.positionUnavailable=true
assert(thrust:update(io,11,c));assert(CAPTURED.targets.speed==3)
sample(io,19,27,0,90,3,0);io.vessel.positionUnavailable=true
assert(thrust:update(io,19,c));assert(CAPTURED.targets.speed==0)
local proxy=step(ap,io,c,20,30,0,90,3,0)
assert(proxy.apPrimaryIdle and ap.state=='ACQ')
""",
'remote_route_uses_same_acquisition_without_saving_draft': r"""
local ap,io,c=fixture();ap:cancel(io,c,'setup',false)
local original=clone(ap.draft)
local f={enabled=true,controls=c,ensureAutopilot=function() return ap end}
f.request=function(self,context,action,at) assert(action.type=='ap_engage');return ap:engage(context,c,at) end
local Ops=require('avionics.remote_ap')
io.propulsionHeartbeat=10
local ops=Ops.new(io,f,{epoch=function() return 1000 end,permission=function() return true end})
assert(ops:setEnabled(true))
local result=ops:request(99,'pair',{action='ap_send',commandID='one',coreSession=io.session,
    generation=ops.generation,sentAt=1000,destination={name='ignored',x=500,z=0,altitude=180,cruiseSpeed=3}})
assert(result.status=='PENDING');ops:step(10)
assert(ap.active and ap.remoteOwner=='pair' and ap.route.entries[1].name=='Remote CMD')
assert(ap.draft.name==original.name and ap.draft.x==original.x and ap:checkpoint()==nil)
assert(step(ap,io,c,11,0,0,90,3,0).apPrimaryIdle)
""",
'kinematic_drift_model_reduces_lateral_demand': r"""
for _,sign in ipairs({-1,1}) do
    local function simulate(limit)
        local ap,io,c=fixture();cruising(ap,io)
        io.config.navigation.autopilot.drift_heading_limit=limit
        local z,heading,total,count=0,90,0,0
        for tick=1,300 do
            local at=10+tick
            heading=heading+((ap.headingTarget-heading+180)%360-180)*.5
            local vz=sign*.1+3*math.sin(math.rad(heading-90))+(ap.crossDemand or 0)
            z=z+vz
            step(ap,io,c,at,tick*3,z,heading,3,vz)
            if tick>240 then total=total+math.abs(ap.crossDemand);count=count+1 end
        end
        return total/count,ap.headingBias
    end
    local uncompensated=simulate(0)
    local compensated,bias=simulate(2)
    assert(compensated<uncompensated*.6,'heading compensation must reduce steady lateral demand in the model')
    assert(bias*sign<0 and math.abs(bias)<=2)
end
""",
}


class AutopilotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.builder = project.builder_module()
        cls.source = cls.builder.collect_project(project.ROOT)
        cls.packed = cls.builder.bundling.prepare(cls.source, cls.builder.FOLDERS)
        cls.sources = cls.builder.bundling.expand(cls.packed['payload'], cls.source['assets']['runtime-loader.lua'])
        cls.sources['/endpoint-thrust.lua'] = cls.source['library']['/packages/thrust/ls/thrust.lua']
        cls.config = json.loads((ROOT / 'source/core/avionics/config.json').read_bytes())
        cls.captures = {}

    def runtime(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().SOURCES = table(lua, {p: d.decode() for p, d in self.sources.items() if p.endswith('.lua')})
        lua.globals().CONFIG = table(lua, self.config)
        lua.execute(AP_HARNESS)
        return lua

    def test_settings_validate_new_fields_and_keep_existing_values(self):
        lua = self.runtime()
        lua.execute("""
local settings=require('avionics.navigation_settings');local c=clone(CONFIG)
c.navigation.autopilot.capture_position_tolerance=.8
assert(settings.ensure(c) and c.navigation.autopilot.capture_position_tolerance==.8)
c.navigation.autopilot.drift_heading_rate=1;assert(not settings.ensure(c))
""")

    def test_bundled_navigator_pages_and_transport(self):
        lua, _ = native_runtime()
        bundle = self.packed['library']['/packages/navigation/main.lua'].decode()
        lua.globals().UI = lua.execute(bundle, self.builder.bundling.MAGIC, '/avionics/ui.lua')
        lua.globals().CAPTURES = lua.table()
        lua.execute(UI_HARNESS)
        lua.execute("""
local selectors
for _,stage in ipairs({'ACQ','CAPTURE','CRUISE','RETRYING (2)'}) do
    local ui,s,draw,open,choose,region,capture=fixture(57,24,'NAV')
    ui.navView='AUTOPILOT'
    s.ap='ACTIVE';s.authorityReady=true
    s.vessel.heading=stage=='ACQ' and 57.7 or 90.3
    s.vessel.forwardSpeed=stage=='CRUISE' and 3 or 2.3
    s.modes.heading='MANUAL';s.modes.throttle='DIRECT'
    s.effectiveModes={heading='SEL',throttle=(stage=='ACQ' or stage=='CAPTURE') and 'DIRECT' or 'SEL'}
    s.thrust={available=true,roles={},units={},manualAcceleration={available=true,mode='DIRECT'},
        headingControl={available=true,mode='SEL'},speedControl={available=true,state='ACTIVE',controlStatus='ACTIVE'}}
    for _,role in ipairs({'thrust-lb','thrust-rb','thrust-ls','thrust-rs'}) do
        s.thrust.roles[role]={online=true,available=true,statusFresh=true,thrustControlState='RDY'}
    end
    for _,role in ipairs({'primary-left','primary-right'}) do
        s.thrust.units[role]={online=true,available=true,statusFresh=true}
    end
    s.autopilot={active=true,state=stage,headingBias=.4,primaryIdle=stage=='ACQ' or stage=='CAPTURE',
        destination={name='Saved draft'},route={index=1,entries={{name='Remote CMD'}}},
        requestedHeading=90.4,requestedSpeed=stage=='CRUISE' and 3 or 0,crossTrack=-.3,
        distance=150,captureSettledSeconds=1.5,captureSettleSeconds=3,
        reason=stage=='RETRYING (2)' and 'VESSEL TELEMETRY STALE' or nil}
    draw();local lines={};for _,row in ipairs(ui.previous.rows) do lines[#lines+1]=row.text end
    local signature=ui.previous.rows[3].text..ui.previous.rows[3].background
    if selectors then check(signature==selectors,'automatic stages keep selected mode buttons') end
    selectors=signature
    local text=table.concat(lines,'\\n')
    check(text:find('Remote CMD',1,true) and not text:find('Saved draft',1,true),'active route name')
    check(text:find('HDG BIAS +0.4 DEG',1,true),'signed bias')
    if stage=='ACQ' then check(text:find('ACQUIRING HEADING',1,true),'acquisition label') end
    if stage=='CAPTURE' then check(text:find('CAPTURING ROUTE',1,true),'capture label') end
    check(not text:find('PRIMARY REQUEST',1,true),'primary request readout removed')
    check(not text:find('PRIMARY ENGINES IDLE',1,true),'idle footer removed')
    check(not text:find('SETTLED',1,true),'capture settling readout removed')
    if stage=='RETRYING (2)' then check(text:find('VESSEL TELEMETRY STALE',1,true),'recovery reason') end
    capture(stage:gsub('[^%w]','-'))
end
""")
        self.captures.update(python_value(lua.globals().CAPTURES))
        runtime = self.runtime()
        runtime.execute("""
local Payload=require('avionics.display_payload')
local result=Payload.heading({modes={heading='MANUAL',throttle='DIRECT'},
    effectiveModes={heading='SEL',throttle='SEL'},autopilot={active=true,state='CAPTURE',routeHeading=90,headingBias=.4,
    primaryIdle=true,captureSettledSeconds=1,captureSettleSeconds=3}})
assert(result.autopilot.primaryIdle and result.autopilot.headingBias==.4 and result.autopilot.captureSettleSeconds==3)
assert(result.modes.heading=='MANUAL' and result.effectiveModes.heading=='SEL')
""")

    def test_current_decorator_keeps_selectors_and_reports_effective_modes(self):
        from tests.test_state import fixture_source
        lua = self.runtime()
        lua.execute(fixture_source()+r'''
for _,h in ipairs({'MANUAL','SEL'}) do
 for _,t in ipairs({'MANUAL','SEL','DIRECT'}) do
  local io,f,p,clock=setup()
  f.controls.modes.heading=h;f.controls.modes.throttle=t
  f.systemsRun={phase='READY',target=160};f.systemsSnapshot={phase='READY',active=true}
  local ap=f:ensureAutopilot(io)
  ap.active=true;ap.state='ACQ';ap.primaryIdle=true;ap.speedTarget=0;ap.headingTarget=90
  local function snapshot()
   local s={targets={},nodes={},updatedAt=10};f:decorate(s,io,10)
   assert(s.modes.heading==h and s.modes.throttle==t)
   assert(f.controls.modes.heading==h and f.controls.modes.throttle==t)
   return s
  end
  local s=snapshot();assert(s.effectiveModes.heading=='SEL' and s.effectiveModes.throttle=='DIRECT')
  ap.state='CRUISE';ap.primaryIdle=false;ap.speedTarget=3
  s=snapshot();assert(s.effectiveModes.heading=='SEL' and s.effectiveModes.throttle=='SEL')
  ap.active=false;io.positionAnchor=require('avionics.anchor').new(io.config)
  io.positionAnchor.active=true;io.positionAnchor.point={x=0,z=0};io.positionAnchor.uuid=io.vessel.uuid
  s=snapshot();assert(s.effectiveModes.throttle=='DIRECT' and s.effectiveModes.heading==h)
  io.positionAnchor=nil;s=snapshot();assert(s.effectiveModes.heading==h and s.effectiveModes.throttle==t)
 end
end
''')

    def test_selected_strafe_ignores_settled_heading_torque_but_waits_for_turns(self):
        for bundled in (False,True):
            with self.subTest(bundled=bundled):
                lua=self.runtime()
                if bundled:
                    modules={p:d for p,d in self.sources.items() if p.startswith('/avionics/') and p.endswith('.lua')}
                    data=self.builder.bundling.pack({**modules,
                        '/avionics/main.lua':b"return require('avionics.lateral')"},
                        self.source['assets']['runtime-loader.lua'],role='lateral-test',entry='/avionics/main.lua')
                    lua.execute('fs={exists=function()return false end}')
                    lua.globals().Lateral=lua.execute(data.decode())
                else:lua.execute("Lateral=require('avionics.lateral')")
                lua.execute(r"""
local ap,io,c,t=fixture(90,0);io.autopilot=nil
c.modes.heading='SEL';c.targets.heading=90.2
local lateral=Lateral.new(io.config);c.lateral=lateral
assert(lateral:select('SEL',io,c,10))
lateral:input({left_lift=0,right_lift=0},10,.1,false)
lateral:input({left_lift=0,right_lift=15},10.1,.1,false)
for i=1,100 do
 local at=10+i*.1;sample(io,at,0,0,90,0,0)
 local torque=i%2==0 and .019 or .7
 t.headingDriveDemand=function()return torque end
 local targets,why=t:makeTargets(io,at,c);assert(targets,why)
 assert(lateral.state=='MOVING' and (i==1 or lateral.output>0),lateral.state)
 local side=0;for name,value in pairs(targets)do if name:find('lateral-',1,true)then side=side+value end end
 assert(i==1 or side>0)
end
sample(io,20.1,0,0,91,0,0);assert(lateral:evaluate(io,20.1,c,0)==0 and lateral.state=='TURNING')
sample(io,21.2,0,0,91,0,0);assert(lateral:evaluate(io,21.2,c,.7)>0 and lateral.state=='MOVING')
c.targets.heading=100;sample(io,21.3,0,0,91,0,0)
assert(lateral:evaluate(io,21.3,c,0)==0 and lateral.state=='TURNING')
c.targets.heading=91;c.yaw=.1;sample(io,23,0,0,91,0,0)
assert(lateral:evaluate(io,23,c,0)==0 and lateral.state=='TURNING')
""")

    def test_strafe_braking_is_withheld_below_the_minimum_speed(self):
        lua=self.runtime()
        lua.execute("Lateral=require('avionics.lateral')")
        lua.execute(r"""
local function braker(vz,minimum)
 local ap,io,c=fixture(90,0);io.autopilot=nil
 if minimum then io.config.cockpit.lateral_brake_minimum_speed=minimum end
 local lateral=Lateral.new(io.config);c.lateral=lateral
 lateral.mode='MANUAL';lateral.braking=true;lateral.waitNeutral=false
 sample(io,10,0,0,90,0,vz);lateral:evaluate(io,10,c,0)
 sample(io,10.2,0,0,90,0,vz)
 return lateral:evaluate(io,10.2,c,0)
end
-- Below the default 2 b/s there is no active braking; at and above it there is.
assert(braker(1.5)==0,'no brake thrust below the minimum speed')
assert(braker(-1.5)==0,'no brake thrust below the minimum speed in the other direction')
assert(braker(3)<0,'brake thrust opposes positive motion above the minimum')
assert(braker(-3)>0,'brake thrust opposes negative motion above the minimum')
assert(braker(2)<0,'the minimum speed itself brakes')
-- A zero minimum restores braking at every speed; a larger one extends the coast.
assert(braker(1.5,0)<0)
assert(braker(3,4)==0)
""")

    def test_selected_strafe_withholds_approach_braking_but_returns_after_overshoot(self):
        lua=self.runtime()
        lua.execute("Lateral=require('avionics.lateral')")
        lua.execute(r"""
local function selected(z,vz)
 local ap,io,c=fixture(90,0);io.autopilot=nil
 local lateral=Lateral.new(io.config);c.lateral=lateral
 lateral.mode='SEL';lateral.pending=true;lateral.offset=3;lateral.track={x=0,z=0,travelled=0};lateral.waitNeutral=false
 sample(io,10,0,z,90,0,vz);lateral:evaluate(io,10,c,0)
 sample(io,10.2,0,z,90,0,vz)
 return lateral:evaluate(io,10.2,c,0)
end
-- Still short of the target and moving toward it: the slow-down is left to drag.
assert(selected(0,1.5)==0,'approach braking is withheld below the minimum speed')
-- Past the target by more than the settle tolerance: the return thrust still acts.
assert(selected(3.6,1.5)<0,'a selected strafe returns from an overshoot')
-- Fast approach still brakes.
assert(selected(0,3)<0,'approach braking works above the minimum speed')
""")

    def test_selected_strafe_ignores_forward_travel_across_a_heading_change(self):
        lua=self.runtime()
        lua.execute("Lateral=require('avionics.lateral')")
        lua.execute(r"""
local ap,io,c=fixture(0,0);io.autopilot=nil
c.modes.heading='SEL';c.targets.heading=0
local lateral=Lateral.new(io.config);c.lateral=lateral
sample(io,10,0,0,0,0,-8);assert(lateral:select('SEL',io,c,10))
lateral.offset=5;lateral.pending=true
-- Fly 200 blocks forward (north, -Z) at the selected heading.
for i=1,25 do sample(io,10+i,0,-8*i,0,0,-8);lateral:evaluate(io,10+i,c,0) end
assert(math.abs(lateral.track.travelled)<1e-9,'forward flight adds no sideways travel')
-- Turn to 090 and keep flying forward (east, +X).
c.targets.heading=90
for i=1,10 do sample(io,40+i,8*i,-200,90,8,0);lateral:evaluate(io,40+i,c,0) end
assert(math.abs(lateral.remaining-5)<1e-9,'the earlier forward distance stays out of the sideways error: '..tostring(lateral.remaining))
-- A sideways step on the new heading (south, +Z) is counted.
sample(io,52,80,-197,90,0,0);lateral:evaluate(io,52,c,0)
assert(math.abs(lateral.track.travelled-3)<1e-9,tostring(lateral.track.travelled))
""")

    def test_finished_selected_strafe_keeps_no_offset(self):
        lua=self.runtime()
        lua.execute("Lateral=require('avionics.lateral')")
        lua.execute(r"""
local ap,io,c=fixture(0,0);io.autopilot=nil
c.modes.heading='SEL';c.targets.heading=0
local lateral=Lateral.new(io.config);c.lateral=lateral
sample(io,10,0,0,0,0,0);assert(lateral:select('SEL',io,c,10))
lateral.offset=3;lateral.pending=true
-- She arrives 3 blocks to starboard (+X at heading 000) and stays there.
for i=1,4 do sample(io,10+i*.5,3,0,0,0,0);lateral:evaluate(io,10+i*.5,c,0) end
assert(not lateral.pending and lateral.state=='IDLE')
assert(lateral.offset==0 and lateral.remaining==0 and lateral.track.travelled==0,'nothing of the finished strafe is kept')
assert(lateral:snapshot().active==false)
-- Drift while idle is not carried into the next command.
sample(io,13,4,0,0,0,0);lateral:evaluate(io,13,c,0)
assert(lateral.track.travelled==0)
lateral.offset=lateral.offset+.5;lateral.pending=true
sample(io,13.2,4,0,0,0,0);lateral:evaluate(io,13.2,c,0)
assert(math.abs(lateral.remaining-.5)<1e-9,'the next press is measured from where she is: '..tostring(lateral.remaining))
""")

    def test_recording_appends_guidance_columns(self):
        lua = self.runtime()
        lua.execute("""
local ap,io,c=fixture();local Debug=require('avionics.debug_recorder')
local recorder=Debug.new({clock=function() return 123 end});recorder.enabled=true;recorder.sequence=0
ap.routeHeading=90;ap.headingBias=.4;ap.crossDemand=.125;ap.primaryIdle=true;ap.captureSettledSeconds=1.5
recorder:capture({},io,10,{})
assert(#recorder.queue==1)
assert(recorder.queue[1]:match(',90,0%.4,0%.125,1,1%.5\\n$'))
""")

    @classmethod
    def tearDownClass(cls):
        REPORT.mkdir(parents=True, exist_ok=True)
        (REPORT / 'screens.json').write_text(json.dumps(cls.captures, indent=2)+'\n', encoding='utf-8')


for name, source in CASES.items():
    def test(self, source=source):
        self.runtime().execute(source)
    setattr(AutopilotTests, 'test_'+name, test)


# ======================================================================
# From test_flight_model: Analytic plant checks and deterministic loops using maintained lift control.
# ======================================================================
import json
import math
import unittest
import project
from tools.flight_model import Plant,pressure
from tests import test_state as persistence
from tests.test_builder import table

class FlightModelTests(unittest.TestCase):
    def test_pressure_reference_points(self):
        for y,want in [(280,.41979029080811425),(300,.306447),(306,.237081),(310,.1805098250474892),(320,0)]:
            self.assertAlmostEqual(pressure(y),want,places=6)

    def test_drag_neutral_support_and_first_order_fill(self):
        p=Plant(constant_pressure=1,mass=100,raw_lift=100,speed=10)
        p.step(100,0,5.5)
        self.assertAlmostEqual(p.speed,10/math.e,places=9)
        self.assertAlmostEqual(p.altitude,250,places=9)
        p=Plant(constant_pressure=1,mass=100,raw_lift=100,gas_lag=2,gravity=0)
        p.step(200,0,2)
        self.assertAlmostEqual(p.raw_lift,200-100/math.e,places=9)

    def test_constant_imbalance_and_step_convergence(self):
        p=Plant(constant_pressure=1,mass=100,raw_lift=110,vertical_drag=0)
        p.step(110,0,2)
        self.assertAlmostEqual(p.vertical_speed,2.2,places=9)
        self.assertAlmostEqual(p.altitude,252.2,places=9)
        a=Plant();b=Plant()
        for _ in range(200):a.step(400000,0,.5)
        for _ in range(1000):b.step(400000,0,.1)
        self.assertAlmostEqual(a.altitude,b.altitude,places=6)
        self.assertAlmostEqual(a.raw_lift,b.raw_lift,places=6)

    def test_delay_capacity_and_source_provenance(self):
        p=Plant(constant_pressure=1,mass=100,raw_lift=100,gas_delay=2,maximum_raw_lift=120)
        p.step(999,0,1);self.assertEqual(p.raw_lift,100)
        p.step(999,0,20);self.assertLessEqual(p.raw_lift,120)
        profile=json.loads((project.ROOT/'tests/fixtures/plant-profile.json').read_text())
        self.assertEqual(profile['windows'][0]['pressureSource'],'SABLE AERO')
        self.assertEqual(profile['windows'][0]['air_pressure_sable']['samples'],profile['rows'])
        self.assertIn('estimated',profile['gasResponseFit']['status'])

    def test_startup_missing_bulk_data_uses_bounded_fallback(self):
        persistence.PersistenceTests.setUpClass()
        lua=persistence.PersistenceTests().runtime(False)
        lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
        lua.execute(r"""
local F=require('avionics.flight').new(CONFIG)
local run={phase='MAIN_LIFT',target=260,dynamics={sampleSeconds=.5}}
local io={nodes={},vessel={altitude=250,verticalSpeed=0,environment={gravity={y=-11}}}}
local ratio=F:systemsAcquisitionControl(io,run,.5,1,10,.5)
assert(ratio>=.8 and ratio<=1.2 and run.acquisitionPidActive==false)
""")

    def test_longitudinal_loop_uses_maintained_thrust(self):
        pass
        reports=[]
        for selected,initial in [(4,0),(4,6),(0,1.9),(0,4),(0,-4)]:
            lua=persistence.PersistenceTests().runtime(False)
            lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
            lua.execute(AP_HARNESS)
            lua.execute(r"""
A,IO,C,T=fixture();C.targets.speed=4;C.modes.throttle='SEL'
function speedStep(at,value,target,p)
 C.targets.speed=target;sample(IO,at,0,0,90,value,0)
 T.airPressure=p
 local request,why=T:speedDriveRequest(IO,at,C);assert(request,why)
 return request/IO.config.thrust.direct_max_request,T.speedControl.state
end
""")
            p=Plant(constant_pressure=.55,speed=initial)
            for tick in range(600):
                drive,state=lua.globals().speedStep(10+tick*.2,p.speed,selected,.55)
                p.step(p.raw_lift,drive,.2)
                self.assertTrue(math.isfinite(p.speed) and abs(drive)<=1)
            reports.append({'selected':selected,'initial':initial,'final':p.speed,'state':state})
            if selected==0:self.assertLess(abs(p.speed),2)
        out=project.ROOT/'output/tests/flight-model';out.mkdir(parents=True,exist_ok=True)
        (out/'longitudinal.json').write_text(json.dumps(reports,indent=2)+'\n')

    def test_closed_loop_maintained_acquisition_and_hold(self):
        persistence.PersistenceTests.setUpClass()
        reports=[]
        for bundled in [False,True]:
            for start,target,lag in [(250,260,2),(280,290,2),(300,306,5),(306,300,2),(250,255,8)]:
                lua=persistence.PersistenceTests().runtime(bundled)
                lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
                # Load the maintained flight module in either source or generated form.
                if bundled:
                    source=project.builder_module().bundling.pack({**persistence.PersistenceTests.sources,
                        '/avionics/main.lua':b"return require('avionics.flight')"},persistence.PersistenceTests.loader,role='model',entry='/avionics/main.lua')
                    lua.globals().Flight=lua.execute('return assert(load(...))()',source.decode())
                else:lua.execute("Flight=require('avionics.flight')")
                lua.execute(r"""
F=Flight.new(CONFIG)
RUN={phase='MAIN_LIFT',target=260,responseLagSeconds=2,lastAckWaitSeconds=.5,
 dynamics={sampleSeconds=.5,verticalAcceleration=0}}
IO={nodes={},nodeFresh=function() return true end,vessel={environment={gravity={y=-11}}}}
local gas,strength=next(F.config.verified_gas_lift_strengths)
assert(gas and strength>0)
function controller(y,vs,raw,applied,p,mass,at,target,lag)
 RUN.target=target;RUN.responseLagSeconds=lag
 if math.abs(target-y)<1 and math.abs(vs)<.2 then RUN.phase='READY' end
 IO.vessel.altitude=y;IO.vessel.verticalSpeed=vs;IO.vessel.mass=mass
 IO.vessel.environment.airPressure=p
 for _,q in ipairs({'FL','FR','BL','BR'}) do
  IO.nodes[q]={balloon={gasMixValid=true,gasMix={[gas]=raw/(4*strength)}},
   providers={bulk={controlRole='bulk',gasTypeValid=true,gasType=gas,gasOutputValid=true,
    gasOutput=applied/(4*strength),targetAmount=applied/(4*strength)}}}
 end
 local ratio,why=F:systemsAcquisitionControl(IO,RUN,.5,raw*p/mass,at,.5)
 assert(ratio,why);return ratio,RUN.phase,F.verticalTarget
end
""")
                p=Plant(altitude=start,gas_lag=lag)
                commands=[];heights=[];applied=p.raw_lift
                for tick in range(600):
                    ratio,phase,_=lua.globals().controller(p.altitude,p.vertical_speed,p.raw_lift,applied,p.air_pressure(),p.mass,tick*.5,target,lag)
                    self.assertTrue(math.isfinite(ratio) and 0<=ratio<=2)
                    applied=min(p.maximum_raw_lift,ratio*p.mass/max(p.air_pressure(),1e-9))
                    commands.append(applied);p.step(applied,0,.5);heights.append(p.altitude)
                reports.append({'bundled':bundled,'start':start,'target':target,'gasLag':lag,'finalAltitude':p.altitude,
                    'finalError':target-p.altitude,'overshoot':max(heights)-target,'finalPhase':phase,
                    'maxCommand':max(commands),'status':'synthetic aggregate control characterization'})
                self.assertLess(abs(p.vertical_speed),20)
        out=project.ROOT/'output/tests/flight-model';out.mkdir(parents=True,exist_ok=True)
        (out/'scenarios.json').write_text(json.dumps(reports,indent=2)+'\n')
        for i in range(5):
            self.assertAlmostEqual(reports[i]['finalAltitude'],reports[i+5]['finalAltitude'],places=9)


# ======================================================================
# From test_recordings: Recording metrics and bounded recorded-input replay through maintained lift control.
# ======================================================================
import csv
import json
import math
from pathlib import Path
import tempfile
import unittest
import project
from tools.recordings import analyze,write_report
from tests import test_state as persistence
from tests.test_builder import table

class RecordingTests(unittest.TestCase):
    def test_metrics_gaps_sources_stalls_and_missing_values(self):
        with tempfile.TemporaryDirectory(dir=project.ROOT/'.cache') as temp:
            p=Path(temp)/'run.csv'
            fields=['epoch_ms','sample_dt','air_pressure_source','vertical_speed','altitude','systems_target_altitude','speed_output','core_event_lag_s']
            with p.open('w',newline='') as f:
                w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
                for i in range(70):
                    row=dict(zip(fields,[i*1000+(5000 if i>=35 else 0),1,'SABLE AERO' if i<40 else 'ALTITUDE SENSOR',0,100,110,1 if i<10 else .2,'nan' if i==3 else .5]))
                    w.writerow(row)
                    if i==50:w.writerow(row)
            report=write_report(p,Path(temp)/'report')
            self.assertEqual(len(report['gaps']),1)
            self.assertEqual(report['duplicateOrReorderedSamples'],1)
            self.assertEqual(len(report['pressureWindows']),2)
            self.assertEqual(len(report['altitudeStalls']),2)
            self.assertEqual(report['speedOutputSaturation']['saturated'],10)
            self.assertEqual(report['distributions']['core_event_lag_s']['max'],.5)
            self.assertIn('command_ack_wait_s',report['missingColumns'])
            self.assertIsNone(report['distributions']['command_ack_wait_s'])
            self.assertTrue((Path(temp)/'report/report.md').exists())

    def test_historical_headers_and_added_columns(self):
        with tempfile.TemporaryDirectory(dir=project.ROOT/'.cache') as temp:
            p=Path(temp)/'old.csv';p.write_text('epoch_ms,altitude,extra\n1000,100,unused\n2000,101,unused\n')
            report=analyze(p)
            self.assertIsNone(report['recordingSchemaVersion'])
            self.assertEqual(report['rows'],2)
            self.assertIsNone(report['speedOutputSaturation']['fraction'])
            p.with_suffix('.json').write_text('{"schemaVersion":5}')
            self.assertEqual(analyze(p)['recordingSchemaVersion'],5)

    def test_recorded_input_source_bundle_trace(self):
        persistence.PersistenceTests.setUpClass()
        profile=json.loads((project.ROOT/'tests/fixtures/plant-profile.json').read_text())
        traces=[]
        for bundled in [False,True]:
            lua=persistence.PersistenceTests().runtime(False)
            if bundled:
                packed=project.builder_module().bundling.pack({**persistence.PersistenceTests.sources,
                    '/avionics/main.lua':b"return require('avionics.flight')"},persistence.PersistenceTests.loader,role='replay',entry='/avionics/main.lua')
                lua.globals().Flight=lua.execute('return assert(load(...))()',packed.decode())
            else:lua.execute("Flight=require('avionics.flight')")
            lua.globals().CONFIG=table(lua,profile['recordingConfig'])
            lua.execute(r"""
local f=Flight.new(CONFIG);local run={phase='READY',dynamics={sampleSeconds=.5},responseLagSeconds=1}
local io={nodes={},nodeFresh=function()return true end,vessel={environment={gravity={y=-11}}}}
local gas,strength=next(f.config.verified_gas_lift_strengths)
function replay(row,dt)
 io.vessel.altitude=row.altitude;io.vessel.verticalSpeed=row.verticalSpeed;io.vessel.mass=row.mass
 io.vessel.environment.airPressure=row.pressure;run.target=row.selectedAltitude
 for _,q in ipairs({'FL','FR','BL','BR'}) do
  io.nodes[q]={balloon={gasMixValid=true,gasMix={[gas]=row.rawLift/(4*strength)}},
   providers={bulk={controlRole='bulk',gasTypeValid=true,gasType=gas,gasOutputValid=true,
    gasOutput=row.appliedRawLift/(4*strength),targetAmount=row.appliedRawLift/(4*strength)}}}
 end
 local out,why=f:systemsAcquisitionControl(io,run,dt,row.rawLift*row.pressure/row.mass,row.at,dt)
 assert(out,why);return out,f.outer.i,f.inner.i,f.verticalTarget
end
""")
            previous=None;trace=[]
            for row in profile['replayRows']:
                dt=.5 if previous is None else row['at']-previous
                self.assertGreater(dt,0)
                result=lua.globals().replay(table(lua,row),dt)
                self.assertTrue(all(math.isfinite(x) for x in result))
                trace.append(result);previous=row['at']
            traces.append(trace)
        self.assertEqual(traces[0],traces[1])
        output=project.ROOT/'output/tests/recording-replay';output.mkdir(parents=True,exist_ok=True)
        (output/'trace.json').write_text(json.dumps({'recording':profile['recording'],'sha256':profile['sha256'],
            'pressureSource':profile['windows'][0]['pressureSource'],'trace':traces[0],
            'limitation':'component replay; full historical controller/supervisor state is unavailable'},indent=2)+'\n')


# ======================================================================
# From test_control_stages: Characterization traces and offline cost measurements for staged control extraction.
# ======================================================================
import json
import math
import statistics
import time
import unittest
import project
from tests import test_state as persistence
from tests.test_builder import table, python_value


def benchmark(label, repeats=5, samples=1500):
    """Measure repeated selected-speed calculations with identical synthetic inputs."""
    AutopilotTests.setUpClass()
    timings=[];allocations=[];checksums=[]
    for _ in range(repeats):
        lua=AutopilotTests().runtime()
        lua.execute(r"""
function benchmarkSpeed(n)
 local ap,io,c,t=fixture();c.targets.speed=5;c.modes.throttle='SEL'
 collectgarbage('collect');collectgarbage('stop')
 local before=collectgarbage('count');local sum=0
 for i=1,n do
  sample(io,10+i*.1,0,0,90,4+.01*math.sin(i*.01),0)
  local out,why=t:speedDriveRequest(io,10+i*.1,c);assert(out,why);sum=sum+out
 end
 local allocated=collectgarbage('count')-before;collectgarbage('restart')
 return allocated,sum
end
""")
        start=time.perf_counter()
        allocation,checksum=lua.globals().benchmarkSpeed(samples)
        timings.append(time.perf_counter()-start);allocations.append(allocation);checksums.append(checksum)
    result={'label':label,'engine':'Lupa Lua 5.2; offline, synthetic sensor data','samplesPerRun':samples,
            'seconds':timings,'medianSeconds':statistics.median(timings),'allocatedKiB':allocations,
            'checksums':checksums,'includes':'sensor fixture tables and selected-speed control',
            'limitation':'CPU/allocation characterization excludes Minecraft/peripheral waits'}
    out=project.ROOT/'output/tests/control-stages';out.mkdir(parents=True,exist_ok=True)
    (out/(label+'.json')).write_text(json.dumps(result,indent=2)+'\n')
    return result


def hotpath_benchmark(label, baseline=False, repeats=5, samples=300):
    """Measure snapshot, compact-payload and CSV construction with fixed synthetic data."""
    persistence.PersistenceTests.setUpClass()
    timings=[];allocations=[];checksums=[]
    for _ in range(repeats):
        lua=persistence.PersistenceTests().runtime(False)
        sources=dict(persistence.PersistenceTests.sources)
        if baseline:
            for name in ('io.lua','thrust.lua','flight.lua'):
                sources['/avionics/'+name]=(project.ROOT/'.cache/maintenance-delivery-6-before/source/core/avionics'/name).read_bytes()
        lua.globals().SOURCES=table(lua,{k:v.decode() for k,v in sources.items()})
        lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
        lua.execute(r"""
local loaded={};function require(name)
 if loaded[name]then return loaded[name]end
 loaded[name]=assert(load(SOURCES['/'..name:gsub('%.','/')..'.lua'],'@'..name))();return loaded[name]
end
print=function()end
local now=100
local IO=require('avionics.io');local Payload=require('avionics.display_payload');local Debug=require('avionics.debug_recorder')
local io=IO.new(CONFIG,{now=function()return now end,computerID=0,computerLabel='ama-core',session='benchmark'})
io.nodeFresh=function()return true end
for i,q in ipairs({'FL','FR','BL','BR'})do
 io.nodes[q]={id=i,lastSeen=now,ready=true,armed=true,providers={},faults={},altitude={valid=true,sensorWorldY=250},
  balloon={lift=75000,filledVolume=50000,capacity=200000},systemsStage='control',systemsProbeReady=true}
end
io.vessel={valid=true,at=now,uuid='ship',altitude=250,heading=90,verticalSpeed=.1,forwardSpeed=4,
 position={x=0,y=250,z=0},linearVelocity={x=4,y=.1,z=0},mass=150000,
 environment={airPressure=.5,airPressureSource='SABLE AERO',gravity={x=0,y=-11,z=0}}}
io.inputs={valid=true,at=now,raw={}}
local recorder=Debug.new({clock=function()return now*1000 end});recorder.enabled=true;recorder.sequence=0
function benchmarkHotpath(n)
 collectgarbage('collect');collectgarbage('stop');local before=collectgarbage('count');local sum=0
 for i=1,n do
  now=100+i;io.vessel.at=now;io.inputs.at=now
  local snapshot=io:buildSnapshot(now,'FLIGHT');local compact=Payload.heading(snapshot)
  recorder.queue={};recorder:capture(snapshot,io,now,{})
  sum=sum+#recorder.queue[1]+(compact.vessel.altitude or 0)
 end
 local allocated=collectgarbage('count')-before;collectgarbage('restart');return allocated,sum
end
""")
        start=time.perf_counter();allocation,checksum=lua.globals().benchmarkHotpath(samples)
        timings.append(time.perf_counter()-start);allocations.append(allocation);checksums.append(checksum)
    result={'label':label,'engine':'Lupa Lua 5.2; offline','samplesPerRun':samples,'seconds':timings,
        'medianSeconds':statistics.median(timings),'allocatedKiB':allocations,'checksums':checksums,
        'includes':'snapshot + heading payload + one CSV row; fresh synthetic chamber data, unconnected propulsion',
        'limitation':'excludes peripheral waits, Minecraft scheduling and recording disk writes'}
    out=project.ROOT/'output/tests/control-stages';out.mkdir(parents=True,exist_ok=True)
    (out/(label+'.json')).write_text(json.dumps(result,indent=2)+'\n');return result


def io_traces(lock=None):
    """Characterize actual vessel sampling with caches, invalid readings and grid loss.

    The characterization runs without a locked Sable bow axis unless lock names one."""
    persistence.PersistenceTests.setUpClass()
    lua=persistence.PersistenceTests().runtime(False)
    lua.execute("print=function() end")
    lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
    lua.globals().LOCK_AXIS=table(lua,lock) if lock else None
    lua.execute(r"""
local IO=require('avionics.io')
local config=CONFIG;config.hardware.discover=false
config.hardware.velocity_sensors={'velocity-a','velocity-b'}
config.geometry.orientation_verified=true;config.geometry.velocity_frame_verified=true
config.geometry.velocity_unit='blocks_per_second';config.geometry.bow_forward={x=1,y=0,z=0}
config.geometry.velocity_forward={x=1,y=0,z=0}
config.geometry.sable_bow_axis=LOCK_AXIS
local now=10;local mode='valid';local calls={}
local function called(name,value) calls[#calls+1]=name;return value end
local api={isInPlotGrid=function()return called('grid',mode~='off-grid')end,
 getUniqueId=function()return called('uuid','ship')end,
 getLogicalPose=function()return called('pose',{position={x=100,y=250,z=-50},
 rotationPoint={x=1,y=0,z=0},scale={x=1,y=1,z=1},orientation={x=0,y=0,z=0,w=1}})end,
 getCenterOfMass=function()return called('com',{x=2,y=.5,z=0})end,
 getLinearVelocity=function()return called('velocity',{x=2,y=.2,z=3})end,
 getAngularVelocity=function()return called('angular',{x=0,y=.01,z=0})end,
 getMass=function()return called('mass',mode=='invalid' and 0/0 or 150000)end}
local aero={getGravity=function()return called('gravity',{x=0,y=-11,z=0})end,
 getUniversalDrag=function()return called('drag',.09)end,
 getAirPressure=function(point) assert(type(point)=='table');return called('pressure',mode=='invalid' and 0/0 or .5) end}
local io=IO.new(config,{sublevel=api,aero=aero,now=function()return now end,computerID=0,session='test',
 vector={new=function(x,y,z)return {x=x,y=y,z=z}end}})
io.independentVesselSources=false;io.sampling={vessel={}}
io.readSensor=function(self,name,method)
 calls[#calls+1]=tostring(name)..'.'..method
 local values={getOrientation={x=0,y=0,z=0,w=1},getHeading=90,getHeight=249,
 getVerticalSpeed=.2,getGravity={x=0,y=-11,z=0},getAngles={0,0},getAngularRates={x=0,y=.01,z=0},
 getAxis=name=='velocity-a' and 'x' or 'z',getVelocity=name=='velocity-a' and 2 or 3}
 if mode=='invalid' and method=='getVelocity' then return nil,'reading unavailable' end
 return values[method]
end
TRACES={}
for _,case in ipairs({{10,'valid'},{10.5,'valid'},{16,'valid'},{50,'invalid'},{51,'off-grid'}}) do
 now=case[1];mode=case[2];calls={}
 local vessel=io:sampleVessel(now)
 TRACES[#TRACES+1]={at=now,mode=mode,vessel=vessel,calls=calls,stage=io.sampling.vessel.stage}
end
""")
    return python_value(lua.globals().TRACES)


def target_traces():
    """Characterize provider allocation across correction, capacity and response conditions."""
    persistence.PersistenceTests.setUpClass()
    lua=persistence.PersistenceTests().runtime(False)
    lua.execute("print=function() end")
    lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
    lua.execute(r"""
local Flight=require('avionics.flight')
TRACES={}
for _,case in ipairs({
 {phase='MAIN_LIFT',actual=.99,desired=1.02,lag=5,vs=.3},
 {phase='MAIN_LIFT',actual=.99,desired=1.02,lag=5,vs=0,liftRate=.03},
 {phase='MAIN_LIFT',actual=1.05,desired=1,lag=5,vs=1},
 {phase='MAIN_LIFT',actual=.99,desired=1.02,vs=.2},
 {phase='READY',actual=1,desired=1,lag=5,vs=0},
 {phase='READY',actual=.999,desired=1,lag=5,vs=0,ack=3},
 {phase='READY',actual=1.05,desired=1,lag=5,vs=.5},
 {phase='READY',actual=.99,desired=1.01,lag=5,vs=0,atMaximum=true},
 {phase='MAIN_LIFT',actual=.99,desired=1.02,lag=5,vs=.2,supplyStep=true},
 {phase='MAIN_LIFT',actual=.99,desired=1.02,lag=5,vs=.2,full=true}
}) do
 local f=Flight.new(CONFIG);f.trim={FL=1,FR=-1,BL=2,BR=0};f.verticalTarget=1
 local s={phase=case.phase,target=case.vs>0.4 and 251 or 280,responseLagSeconds=case.lag,lastAckWaitSeconds=case.ack or .5,
  lastTargetAppliedAt=99,currentTargets={},baseline={},coarseTrimApplied={},acquisitionMotionSamples=4,acquisitionMotionReadyAt=50,
  dynamics={sampleSeconds=.5,liftRate=case.liftRate or 0,verticalAccelerationRaw=0,verticalAcceleration=0,
   complete=true,outputsValid=true,efficienciesValid=true,fullEfficiency=true,supplyStable=true,supplyStep=case.supplyStep,
   quadrants={}}}
 local io={vessel={mass=150000,altitude=250,verticalSpeed=case.vs,environment={gravity={y=-11},airPressure=.5}},nodes={}}
 for _,q in ipairs({'FL','FR','BL','BR'}) do
  local maximum=case.atMaximum and 50000 or 100000
  io.nodes[q]={providers={bulk={controlRole='bulk',minimumNonzeroTarget=50,maxTarget=maximum},
   fine={controlRole='fine',minimumNonzeroTarget=5,maxTarget=200}},balloon={lift=75000}}
  s.currentTargets[q]={bulk=50000,fine=20};s.baseline[q]={bulk=50000,fine=20};s.coarseTrimApplied[q]={bulk=5}
  s.dynamics.quadrants[q]={fillFraction=case.full and .99 or .3,fillRate=20,capacity=200000,lift=75000}
 end
 for step=1,5 do
  local maps,direction,allAtMaximum,info=f:systemsControlTargets(io,s,.5,case.desired,case.actual,100+step*.5,.5)
  TRACES[#TRACES+1]={case=case,step=step,maps=maps,direction=direction,allAtMaximum=allAtMaximum,info=info,
   fraction=s.lastSupportCorrectionFraction,remainders=textutils.serializeJSON(s.supportCorrectionRemainders),
   motionSamples=s.acquisitionMotionSamples,motionReady=s.acquisitionMotionReadyAt}
  s.currentTargets=maps
 end
end
""")
    result=python_value(lua.globals().TRACES)
    # JSON object ordering is immaterial to per-provider remainder state.
    for row in result:row['remainders']=json.loads(row['remainders'])
    return result


def recovery_traces():
    """Characterize retained-map recovery with simulated guards, readbacks and transport."""
    persistence.PersistenceTests.setUpClass()
    lua=persistence.PersistenceTests().runtime(False)
    lua.execute("print=function() end")
    lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
    lua.execute(r"""
local Flight=require('avionics.flight')
local function clone(v)
 if type(v)~='table' then return v end
 local copy={};for k,x in pairs(v) do copy[k]=clone(x) end;return copy
end
TRACES={};os.__amaryllisLog=function()end
for _,case in ipairs({
 {mode='control',phase='READY'}, {mode='expired',phase='READY'},
 {mode='mixed',phase='READY'}, {mode='expired',phase='PROBING'},
 {mode='control',phase='VENT_IGNITION'}, {mode='expired',phase='READY',delayed=true},
 {mode='expired',phase='READY',sendFailure=true}, {mode='control',phase='READY',changedMap=true},
 {mode='expired',phase='READY',expireControl=true}, {mode='control',phase='READY',assemblyUnknown=true}
}) do
 local sent,stopped={},{};local seq=0;local now=100;local didFail=false;local expired=false
 local f=Flight.new(CONFIG);f.trim={FL=0,FR=0,BL=0,BR=0}
 local s={phase=case.phase,target=260,startedAt=80,phaseStartedAt=85,currentTargets={},providerRoles={},boots={},
  coarseTrimApplied={},telemetryRecovery={since=90,resumePhase=case.phase}}
 f.systemsRun=s;f.enabled=true
 f.systemsGuard=function()return true end
 f.systemsEnvelopeReady=function()return true end
 f.stopSystems=function(self,io,reason,at) stopped[#stopped+1]={reason=reason,at=at};self.systemsRun=nil;self.reason=reason end
 local io={nodes={},vessel={altitude=250,verticalSpeed=.1},commandWasApplied=function()return true end}
 io.assemblyGate=function()if case.assemblyUnknown then return false,'ASSEMBLY STATE UNKNOWN',{state='UNKNOWN'} end;return true end
 for _,q in ipairs({'FL','FR','BL','BR'}) do
  local stage=case.mode=='control' and 'control' or (case.mode=='mixed' and q=='FL' and 'control' or nil)
  io.nodes[q]={boot='boot',systemsSupported=true,systemsStartReady=true,systemsStage=stage,systemsProbeReady=stage~=nil,
   steamCount=1,providers={bulk={present=true,writable=true,targetValid=true,targetAmount=case.changedMap and 49900 or 50000,
    controlRole='bulk',minimumNonzeroTarget=50,maxTarget=100000,signalValid=true,signalStrength=15},
    fine={present=true,writable=true,targetValid=true,targetAmount=20,controlRole='fine',minimumNonzeroTarget=5,
     maxTarget=200,signalValid=true,signalStrength=15}}}
  s.currentTargets[q]={bulk=50000,fine=20};s.providerRoles[q]={bulk='bulk',fine='fine'};s.boots[q]='boot';s.coarseTrimApplied[q]={}
 end
 io.sendSystemsCommand=function(self,q,maps,stage)
  seq=seq+1;sent[#sent+1]={q=q,targets=clone(maps),stage=stage,seq=seq,at=now}
  if case.sendFailure and q=='FR' and not didFail then didFail=true;return false,'transport unavailable' end
  if not case.delayed then
   local node=self.nodes[q];node.lastAppliedSeq=seq;node.lastReceivedSeq=seq;node.systemsStage=stage;node.systemsProbeReady=true
   for name,value in pairs(maps) do node.providers[name].targetAmount=value end
   if case.expireControl and stage=='control' and not expired then node.systemsStage=nil;node.systemsProbeReady=false;expired=true end
  end
  return true,seq
 end
 for _,at in ipairs({100,100.5,101,103,110,130}) do
  now=at
  if f.systemsRun and s.telemetryRecovery then
   local result=f:updateSystemsRecovery(io,now,s)
   TRACES[#TRACES+1]=clone({case=case,at=now,result=result,phase=s.phase,enabled=f.enabled,reason=f.reason,
    currentTargets=s.currentTargets,pending=s.pending,recovery=s.telemetryRecovery,snapshot=f.systemsSnapshot,
    sent=sent,stopped=stopped,lastPidAt=s.lastPidAt,lastTargetAppliedAt=s.lastTargetAppliedAt})
  end
 end
end
""")
    return python_value(lua.globals().TRACES)


def systems_traces():
    """Characterize phase dispatch, pending ACKs, launch settling and retained commands."""
    persistence.PersistenceTests.setUpClass()
    lua=persistence.PersistenceTests().runtime(False);lua.execute('print=function()end')
    lua.globals().CONFIG=table(lua,json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes()))
    lua.execute(r"""
local Flight=require('avionics.flight')
local function clone(v)if type(v)~='table' then return v end;local r={};for k,x in pairs(v)do r[k]=clone(x)end;return r end
TRACES={}
for _,case in ipairs({
 {phase='IDLE'},{phase='IDLE',available=true},{phase='PROBING'},
 {phase='VERIFYING'},{phase='VERIFYING',envelopeMissing=true},{phase='VERIFYING',envelopeMissing=true,renew=true},
 {phase='VERIFYING',capacityMissing=true,floorStart=true},{phase='VERIFYING',capFailure=true},
 {phase='VENT_IGNITION'},{phase='VENT_IGNITION',pending=true,ack=true},
 {phase='PROBING',pending=true,ack=true,pendingStage='probe'},
 {phase='READY',pending=true},{phase='READY',pending=true,timeout=true},
 {phase='READY',pending=true,rejected=true},{phase='READY',pending=true,ack=true,selection=265},
 {phase='READY',gap=true},{phase='READY',backward=true},{phase='READY',expired=true},
 {phase='READY',guardFault=true},{phase='READY',capacityMissing=true},
 {phase='READY',targetLimited=true},{phase='READY',capFailure=true},
 {phase='READY',controlGap=true},{phase='READY',pidGap=true},{phase='READY'},
 {phase='MAIN_LIFT',launch=true},{phase='MAIN_LIFT',launchDone=true},
 {phase='MAIN_LIFT'},{phase='MAIN_LIFT',capture=true},{phase='INVALID'}
}) do
 local calls,sent,stopped={},{},{};local now=100;local seq=10
 local f=Flight.new(CONFIG);f.trim={FL=0,FR=0,BL=0,BR=0};f.verticalTarget=.3
 local s={phase=case.phase,target=260,phaseStartedAt=90,startedAt=80,renewAt=case.renew and 99 or 110,
  lastSystemsUpdateAt=case.gap and 90 or (case.backward and 101 or 99.5),
  lastControlAt=case.controlGap and 90 or 99.5,lastPidAt=case.pidGap and 90 or 99.5,
  lastTargetCommandAt=99,lastTargetAppliedAt=99,currentTargets={},baseline={},probeTargets={},controlStartTargets={},
  coarseTrimApplied={},providerRoles={},boots={},appliedMaps={},dynamics={actualRatio=1,verticalAcceleration=0,
   verticalAccelerationRaw=0,sampleSeconds=.5,complete=true,outputsValid=true,efficienciesValid=true}}
 if case.launch or case.launchDone then s.launchStartedAt=case.launchDone and 90 or 99;s.launchDurationSeconds=5 end
 f.systemsRun=case.phase~='IDLE' and s or nil;f.enabled=f.systemsRun~=nil
 f.controls.targets.altitude=case.selection or 260
 f.systemsPreflight=function()calls[#calls+1]='preflight';if case.available then return {} end;return nil,'configuration unavailable' end
 f.systemsGuard=function()calls[#calls+1]='guard';return not case.guardFault,'CONFIGURATION INVALID' end
 f.stopSystems=function(self,io,reason,at)stopped[#stopped+1]={reason=reason,at=at};self.systemsRun=nil;self.reason=reason end
 f.updateSystemsRecovery=function()calls[#calls+1]='recovery' end
 f.observeSystemsDynamics=function()calls[#calls+1]='dynamics' end
 f.observeSystemsPidAfterAck=function()calls[#calls+1]='ack-feedback' end
 f.balancedLiftModel=function(self,io,target)
  calls[#calls+1]='balanced:'..target
  return {phase=case.capacityMissing and 'UNAVAILABLE' or (case.targetLimited and 'LIMITED' or 'READY'),
   targetUnreachable=case.targetLimited,reason=case.capacityMissing and 'WAITING FOR BULK ENVELOPE CAPACITY' or
    (case.targetLimited and 'TARGET UNREACHABLE' or nil)}
 end
 f.systemsEnvelopeReady=function()calls[#calls+1]='envelope';return not case.envelopeMissing,'BALLOON DATA PENDING' end
 f.isFloorOnlyTargets=function()return case.floorStart==true end
 f.capBalancedTargets=function(self,io,maps)calls[#calls+1]='cap';if case.capFailure then return nil,'CAPACITY PENDING' end;return maps,nil,false end
 f.systemsStartupGasSeedTargets=function(self,io,maps)calls[#calls+1]='seed';return maps,{requestedM3PerChamber=0} end
 f.systemsCaptureReady=function()return case.capture==true end
 f.captureSystemsBaseline=function(self,io,run)calls[#calls+1]='capture';run.phase='READY';run.baseline=clone(run.currentTargets) end
 f.updateTrim=function(self)calls[#calls+1]='trim';self.trimStatus={levelIndicated=true};return true end
 f.applyCoarseSteamTrim=function(self,io,maps)calls[#calls+1]='coarse-trim';return maps end
 f.systemsAcquisitionControl=function(self,io,run)calls[#calls+1]='acquisition';run.acquisitionPidActive=true;self.verticalTarget=.25;run.lastDesiredRatio=1.01;return 1.01 end
 f.systemsControlTargets=function(self,io,run)
  calls[#calls+1]='allocation';local maps=clone(run.currentTargets)
  for _,q in ipairs({'FL','FR','BL','BR'})do maps[q].bulk=maps[q].bulk+1 end
  return maps,1,false,{curve='CHARACTERIZATION',demandProgress={},capacityProgress={},capacityLimited={},fastBoost={}}
 end
 f.systemsHoldTargets=function(self,io,run)calls[#calls+1]='hold';run.lastDesiredRatio=1;return clone(run.currentTargets) end
 f.rememberHoverOffset=function()end;f.rememberLevelBias=function()end
 local io={config=CONFIG,nodes={},vessel={valid=true,uuid='ship',mass=150000,altitude=250,verticalSpeed=.1,
  environment={gravity={y=-11},airPressure=.5}},commandWasApplied=function()return case.ack==true end}
 for i,q in ipairs({'FL','FR','BL','BR'}) do
  io.nodes[q]={boot='boot',systemsStage='control',systemsProbeReady=true,steamCount=1,
   lastReceivedSeq=case.rejected and i or nil,lastAppliedSeq=case.ack and i or nil,
   faults=case.rejected and {'SYSTEMS_PROBE_REQUIRED'} or {},balloon={lift=75000,fillFraction=.3},
   providers={bulk={controlRole='bulk',minimumNonzeroTarget=50,maxTarget=100000,gasOutput=50000,gasOutputValid=true,
    targetAmount=50000,targetValid=true,signalValid=true,signalStrength=15,boilerEfficiency=1,boilerEfficiencyValid=true},
    fine={controlRole='fine',minimumNonzeroTarget=5,maxTarget=200,targetAmount=20,targetValid=true,signalValid=true,signalStrength=15}}}
  s.currentTargets[q]={bulk=50000,fine=20};s.baseline[q]=clone(s.currentTargets[q]);s.probeTargets[q]=clone(s.currentTargets[q]);
  s.controlStartTargets[q]=clone(s.currentTargets[q]);s.coarseTrimApplied[q]={};s.providerRoles[q]={bulk='bulk',fine='fine'};s.boots[q]='boot'
  if case.pending then
   s.pending=s.pending or {};s.pending[q]={seq=i,targets={bulk=50001,fine=20},sentAt=case.timeout and 40 or 99.8}
   s.batchTargets=s.batchTargets or {};s.batchTargets[q]=clone(s.pending[q].targets);s.batchStage=case.pendingStage or 'control'
  end
 end
 if case.expired then io.nodes.FL.systemsStage=nil;io.nodes.FL.systemsProbeReady=false end
 io.sendSystemsCommand=function(self,q,maps,stage)
  seq=seq+1;sent[#sent+1]={q=q,targets=clone(maps),stage=stage,at=now,seq=seq};return true,seq
 end
 f:updateSystems(io,now)
 TRACES[#TRACES+1]=clone({case=case,calls=calls,sent=sent,stopped=stopped,reason=f.reason,phase=s.phase,
  target=s.target,currentTargets=s.currentTargets,pending=s.pending,recovery=s.telemetryRecovery,snapshot=f.systemsSnapshot,
  outerI=f.outer.i,innerI=f.inner.i,lastPidAt=s.lastPidAt,lastControlAt=s.lastControlAt,
  lastTargetAppliedAt=s.lastTargetAppliedAt,baseline=s.baseline})
end
""")
    return python_value(lua.globals().TRACES)


class ControlStageTests(unittest.TestCase):
    def test_vessel_readings_and_call_order_are_preserved(self):
        expected=json.loads((project.ROOT/'tests/fixtures/control-stage-baseline.json').read_bytes())['ioCases']
        self.assertEqual(expected,io_traces())

    def test_provider_target_maps_and_remainders_are_preserved(self):
        expected=json.loads((project.ROOT/'tests/fixtures/control-stage-baseline.json').read_bytes())['targetCases']
        self.assertEqual(expected,target_traces())

    def test_recovery_commands_and_retained_maps_are_preserved(self):
        expected=json.loads((project.ROOT/'tests/fixtures/control-stage-baseline.json').read_bytes())['recoveryCases']
        self.assertEqual(expected,recovery_traces())

    def test_systems_phase_dispatch_and_commands_are_preserved(self):
        expected=json.loads((project.ROOT/'tests/fixtures/control-stage-baseline.json').read_bytes())['systemsCases']
        self.assertEqual(expected,systems_traces())

    def test_existing_control_and_replay_traces_are_preserved(self):
        FlightModelTests().test_closed_loop_maintained_acquisition_and_hold()
        FlightModelTests().test_longitudinal_loop_uses_maintained_thrust()
        RecordingTests().test_recorded_input_source_bundle_trace()
        baseline=json.loads((project.ROOT/'tests/fixtures/control-stage-baseline.json').read_bytes())
        def compare(expected,actual,path):
            if isinstance(expected,dict):
                self.assertEqual(set(expected),set(actual),path)
                for key in expected:compare(expected[key],actual[key],path+'.'+key)
            elif isinstance(expected,list):
                self.assertEqual(len(expected),len(actual),path)
                for i,(a,b) in enumerate(zip(expected,actual)):compare(a,b,path+'['+str(i)+']')
            elif isinstance(expected,(int,float)) and not isinstance(expected,bool):
                self.assertTrue(math.isclose(expected,actual,rel_tol=1e-10,abs_tol=1e-8),
                                path+': '+str(expected)+' != '+str(actual))
            else:self.assertEqual(expected,actual,path)
        for name,expected in baseline['traces'].items():
            compare(expected,json.loads((project.ROOT/'output/tests'/name).read_bytes()),name)


# ======================================================================
# From test_leveling_boost: Large-tilt leveling boost, the tilt warning and RESET LEVELING, run against the current Flight module.
# ======================================================================
import json
import unittest

import project
from tests import test_state as persistence
from tests import test_state as modes
from tests.test_builder import table

LEVELING_HARNESS = r'''
local function nodes(heights)
 local result={}
 for _,q in ipairs({"FL","FR","BL","BR"}) do
  result[q]={lastSeen=10,altitude={sensorWorldY=heights[q]},
   providers={probe={controlRole="fine",maxTarget=1000},vent={controlRole="bulk",gasType="steam",maxTarget=2000,minimumNonzeroTarget=1}}}
 end
 return result
end
-- Roll is (FL+BL-FR-BR)/4 blocks: the left side sits `roll` blocks above the right.
function leveled(seconds,roll,boostMax)
 local io,f=setup()
 f.config.level_boost_max=boostMax
 f.systemsRun={phase="READY",airborne=true}
 io.nodes=nodes({FL=160+roll,BL=160+roll,FR=160-roll,BR=160-roll})
 io.nodeFresh=function() return true end
 local baseline={FL={probe=100},FR={probe=100},BL={probe=100},BR={probe=100}}
 local now=10
 for _=1,seconds do
  now=now+1
  for _,q in ipairs({"FL","FR","BL","BR"}) do io.nodes[q].lastSeen=now end
  assert(f:updateTrim(io,baseline,1,1,now))
 end
 return io,f,now
end
'''


class LevelingBoostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        persistence.PersistenceTests.setUpClass()
        cls.config = json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes())

    def run_case(self, body):
        lua = persistence.PersistenceTests().runtime(False)
        lua.globals().CONFIG = table(lua, self.config)
        lua.execute(modes.fixture_source() + "\n" + LEVELING_HARNESS + body)

    def test_large_tilt_builds_steam_leveling_faster(self):
        self.run_case(r"""
local _,plain=leveled(60,2,1)
local _,boosted=leveled(60,2,10)
local a,b=math.abs(plain.coarseSteamTrim.roll),math.abs(boosted.coarseSteamTrim.roll)
assert(a>0 and b>3*a,"boosted "..b.." against plain "..a)
assert(boosted.trimStatus.rollBoost==4,"2 blocks over a 0.5-block start gives 4x: "..tostring(boosted.trimStatus.rollBoost))
assert(boosted.trimStatus.pitchBoost==1,"pitch stays level")
local _,small=leveled(60,0.3,10)
assert(small.trimStatus.rollBoost==1,"tilt inside the start keeps the base rate")
""")

    def test_tilt_warning_after_two_minutes(self):
        self.run_case(r"""
local _,f=leveled(110,2,10)
assert(f.trimStatus.levelingWarning==nil)
_,f=leveled(125,2,10)
assert(f.trimStatus.levelingWarning=="TILT UNCORRECTED 2 MIN: CHECK LOAD OR RESET LEVELING",tostring(f.trimStatus.levelingWarning))
""")

    def test_reset_leveling_returns_to_saved_bias(self):
        self.run_case(r"""
local io,f,now=leveled(60,2,10)
assert(math.abs(f.coarseSteamTrimIntegral.roll)>1)
f.levelBias={roll=5,pitch=-2}
local ok,why=f:resetLeveling(io,now)
assert(ok and why=="LEVELING RESET TO SAVED BIAS",tostring(why))
assert(f.coarseSteamTrimIntegral.roll==5 and f.coarseSteamTrimIntegral.pitch==-2)
assert(f.rollTrim.i==0 and f.pitchTrim.i==0)
local applied=f.coarseSteamTrim.roll
assert(applied~=5,"the applied split moves at the slew rate")
f.levelBias=nil
ok,why=f:resetLeveling(io,now)
assert(ok and why=="LEVELING RESET TO ZERO" and f.coarseSteamTrimIntegral.roll==0)
f.systemsRun.phase="MAIN_LIFT"
ok,why=f:resetLeveling(io,now)
assert(not ok and why=="RESET LEVELING NEEDS START SYSTEMS READY")
""")


# ======================================================================
# From test_recovery: Current control/source selection and supervision boundaries with explicit dependencies.
# ======================================================================
import json
import unittest
import project
from tests import test_state as persistence
from tests import test_state as modes
from tests.test_builder import table

class RecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        persistence.PersistenceTests.setUpClass()
        cls.config=json.loads((project.ROOT/'source/core/avionics/config.json').read_bytes())

    def runtime(self):
        lua=persistence.PersistenceTests().runtime(False)
        lua.globals().CONFIG=table(lua,self.config)
        return lua

    def test_config_merge_keeps_disk_edits_zero_false_and_failed_write(self):
        self.runtime().execute(r"""
local p='/avionics/config.json'
CONFIG.cockpit.manual_yaw_sensitivity_percent=77
FILES[p]=textutils.serializeJSON(CONFIG)
local memory=textutils.unserializeJSON(FILES[p]);memory.cockpit.manual_yaw_sensitivity_percent=50
local ok,why,differed=Modules.Storage.saveConfigChanges(p,memory,{
 {path={'altitude_control','level_damping_gain'},value=0},
 {path={'thrust','manual_acceleration_enabled'},value=false}})
assert(ok,why);assert(differed)
local saved=textutils.unserializeJSON(FILES[p])
assert(saved.cockpit.manual_yaw_sensitivity_percent==77 and saved.altitude_control.level_damping_gain==0)
assert(saved.thrust.manual_acceleration_enabled==false)
local old=FILES[p]
assert(not Modules.Storage.saveConfigChanges(p,saved,{{path={'altitude_control','max_vertical_speed'},value=99}}))
assert(FILES[p]==old)
FAIL='write';FAILPATH=p..'.tmp'
assert(not Modules.Storage.saveConfigChanges(p,saved,{{path={'altitude_control','level_damping_gain'},value=1}}))
assert(FILES[p]==old)
""")

    def test_heading_center_hold_interruption_and_duplicate_samples(self):
        lua=self.runtime()
        lua.execute(modes.fixture_source()+r"""
local io,f,p,clock=setup();selected(io,f,p,clock)
local function update(t,both)
 sample(io,clock,t);io.inputs.raw.left_press=both and 15 or 0;io.inputs.raw.right_press=both and 15 or 0
 io.vessel.heading=45;f.controls:update(io,t)
end
for tick=0,14 do update(10+tick*.1,true) end
assert(f.controls.targets.heading==120)
update(11.4,true);assert(f.controls.targets.heading==120)
update(11.5,true);assert(f.controls.targets.heading==120)
update(11.6,true);assert(f.controls.targets.heading==45 and f.controls.centreLatch)
update(11.7,false);f.controls.targets.heading=120
for tick=0,8 do update(11.8+tick*.1,true) end
update(12.7,false)
for tick=0,14 do update(12.8+tick*.1,true) end
assert(f.controls.targets.heading==120,'interrupted hold starts a new interval')
update(14.4,true);assert(f.controls.targets.heading==45)
""")

    def test_pressure_selection_finite_hold_and_session_preference(self):
        source=(project.ROOT/'source/core/avionics/vessel_sources.lua').read_text()
        start=source.index('    local sablePressure=')
        end=source.index('    if gravity then',start)
        lua=self.runtime()
        lua.execute("function finite(v)return type(v)=='number' and v==v and math.abs(v)<math.huge end\nfunction choose(io,environment,pressure,now,y) local v={altitude=y};"+source[start:end]+";return environment end")
        lua.execute(r"""
local io={};local env=choose(io,{airPressure=.5},.2,10,250)
assert(env.airPressure==.5 and env.airPressureSource=='SABLE AERO')
env=choose(io,{},.2,20,251);assert(env.airPressureSource=='SABLE AERO (HELD)')
env=choose(io,{},.49,21,251);assert(env.airPressureSource=='ALTITUDE SENSOR')
env=choose(io,{},.2,41,251);assert(env.airPressureSource=='ALTITUDE SENSOR')
choose(io,{airPressure=.5},.2,50,250)
env=choose(io,{},.2,51,254);assert(env.airPressureSource=='ALTITUDE SENSOR')
io.pressurePreference='ALTITUDE SENSOR'
env=choose(io,{airPressure=.5},.2,52,250);assert(env.airPressureSource=='ALTITUDE SENSOR (PREFERRED)')
io={};env=choose(io,{airPressure=0/0},nil,10,250);assert(env.airPressure==nil)
""")

    def test_physics_monitor_dwell_alternate_and_invalid_measurement(self):
        self.runtime().execute(r"""
local monitor=require('avionics.physics_monitor').new()
local io={vessel={environment={airPressure=.2,airPressureSource='SABLE AERO',airPressureSensor=1,
 airPressureSable=.2,gravity={y=-11}}}}
local f={systemsRun={phase='READY',dynamics={actualRatio=.2,verticalAcceleration=0}}}
monitor:update(io,f,10);monitor:update(io,f,14.9);assert(not io.pressurePreference)
monitor:update(io,f,15);assert(io.pressurePreference=='ALTITUDE SENSOR')
io.pressurePreference=nil;f.systemsRun.dynamics.actualRatio=0/0
monitor:update(io,f,16);assert(not monitor.badSince and not io.pressurePreference)
""")

    def test_state_failover_grace_backlog_and_handback(self):
        source=(project.ROOT/'source/core/avionics/main.lua').read_text()
        notes=project.builder_module().source_notes
        frame=next(f for f in notes.functions(source) if f['name']=='io.stateFailoverCheck')
        block=source[frame['start']:frame['end']]
        # The worker-start/stop dependencies are observed; scheduling logic is maintained code.
        lua=self.runtime()
        lua.execute(r"""
io={stateLink={lastFrameAt=0}};bootAt=0;BOOT_GRACE=15;FAILOVER_AFTER=5;RECOVER_AFTER=5
failover={active=false};starts=0;stops=0
function coreLog()end
function startLocal(now,age) starts=starts+1;failover.active=true end
function stopLocal(now) stops=stops+1;failover.active=false end
""")
        lua.execute('io.stateFailoverCheck='+block)
        lua.execute(r"""
io.stateFailoverCheck(14.9);assert(starts==0)
io.eventLagSeconds=3;io.stateFailoverCheck(15);assert(starts==0)
io.eventLagSeconds=0;io.stateFailoverCheck(16);assert(starts==1)
for now=17,21 do io.stateLink.lastFrameAt=now;io.stateFailoverCheck(now) end
assert(stops==0)
io.stateLink.lastFrameAt=22;io.stateFailoverCheck(22);assert(stops==1)
failover.active=true;failover.flaps=2;failover.recoveringSince=nil
for now=30,49 do io.stateLink.lastFrameAt=now;io.stateFailoverCheck(now) end
assert(stops==1)
io.stateLink.lastFrameAt=50;io.stateFailoverCheck(50);assert(stops==2)
""")

    def test_low_pressure_altitude_bands_and_warning_precedence(self):
        source=project.source_files()['packages/heading/main/main.lua'].decode()
        start=source.index('local lowPressureActive=false')
        frame=next(f for f in project.builder_module().source_notes.functions(source) if f['name']=='altitudeHoldIndicator')
        lua=self.runtime()
        lua.execute("function sensorValid(v)return type(v.altitude)=='number' end\nRAW='READY';function altitudeHoldIndicatorRaw() return RAW,'white' end\nCLOCK=0;os.clock=function() return CLOCK end\n"+source[start:frame['end']]+"\nindicator=altitudeHoldIndicator")
        lua.execute(r"""
local s={vessel={altitude=284.9}};assert(indicator(s,false)=='READY')
s.vessel.altitude=285;local text,tone=indicator(s,false);assert(text=='LOW PRESS' and tone=='yellow')
s.vessel.altitude=284;assert(indicator(s,false)=='LOW PRESS')
s.vessel.altitude=283.9;assert(indicator(s,false)=='READY')
s.vessel.altitude=304.9;CLOCK=1;text,tone=indicator(s,false);assert(text=='LOW PRESS' and tone=='yellow')
s.vessel.altitude=305;CLOCK=0;text,tone=indicator(s,false);assert(text=='LOW PRESS' and tone=='red')
CLOCK=1;assert(indicator(s,false)=='DESCEND')
RAW='ABORTED';assert(indicator(s,false)=='ABORTED')
RAW='READY';assert(indicator(s,true)=='READY')
""")

    def test_closed_vent_still_reports_boiler_efficiency(self):
        lua=self.runtime()
        hardware=(project.ROOT/'source/library/packages/common/chamber-hardware.lua').read_bytes()
        lua.globals().Hardware=lua.execute(hardware.decode())
        lua.execute(r"""
local read=0
local api={hasType=function()return true end,getMethods=function()return {
 'getSignalStrength','getTargetAmount','setTargetAmount','getGasOutput','hasBalloon','getBoilerEfficiency'} end,
 call=function(name,method)
  if method=='getSignalStrength' then return 0 end
  if method=='getTargetAmount' then return 50 end
  if method=='getBoilerEfficiency' then read=read+1;return .8 end
  error('unexpected closed-vent call '..method)
 end}
local result=Hardware.lift.sampleConfigured({providers={{name='vent',controlRole='bulk',minTarget=0,
 minimumNonzeroTarget=50,maxTarget=100000}}},api)
assert(read==1 and result.providers.vent.boilerEfficiencyValid and result.providers.vent.boilerEfficiency==.8)
assert(result.providers.vent.signalStrength==0)
""")

    def test_start_waits_for_boilers_and_resumes_without_another_command(self):
        for bundled in (False, True):
            with self.subTest(bundled=bundled):
                lua=self.runtime()
                if bundled:
                    data=project.builder_module().bundling.pack({**persistence.PersistenceTests.sources,
                        '/avionics/main.lua':b"return require('avionics.flight')"},
                        persistence.PersistenceTests.loader,role='boiler-gate',entry='/avionics/main.lua')
                    lua.globals().Flight=lua.execute(data.decode())
                else:lua.execute("Flight=require('avionics.flight')")
                lua.execute(r"""
local f=Flight.new(CONFIG);f.controls=nil;f.systemsTarget=function()return 260 end
local writes=0
local io={config=CONFIG,vessel={valid=true,uuid='ship',at=100,altitude=250,verticalSpeed=0,
 mass=150000,environment={gravity={y=-11},airPressure=.5}},
 inputs={valid=true,at=100,raw={}},nodes={},nodeFresh=function()return true end,
 sendSystemsCommand=function()writes=writes+1 end,sendSystemsStop=function()writes=writes+1 end}
for _,q in ipairs({'FL','FR','BL','BR'})do
 io.nodes[q]={boot='boot',systemsStartReady=true,steamCount=1,providers={
 vent={controlRole='bulk',present=true,writable=true,targetValid=true,targetAmount=50000,
 signalValid=true,signalStrength=0,maxTarget=100000,minimumNonzeroTarget=50,
 boilerEfficiencyValid=true,boilerEfficiency=1},
 trim={controlRole='fine',present=true,writable=true,targetValid=true,targetAmount=5,
 signalValid=true,signalStrength=0,maxTarget=200,minimumNonzeroTarget=5}}}
end
assert(f:systemsPreflight(io,100))
for _,q in ipairs({'FL','FR','BL','BR'})do
 local vent=io.nodes[q].providers.vent
 for _,efficiency in ipairs({0,.5,.949,.95,.999,1.01})do
  vent.boilerEfficiency=efficiency
  assert(f:systemsPreflight(io,100))
  local ready,why=f:systemsBoilersReady(io)
  assert(not ready and why:find(q..'/vent',1,true) and why:find('BOILER EFFICIENCY',1,true),why)
 end
 vent.boilerEfficiency=1;vent.boilerEfficiencyValid=false
 assert(not f:systemsBoilersReady(io));vent.boilerEfficiencyValid=true
 assert(f:systemsBoilersReady(io))
 assert(vent.targetAmount==50000 and vent.signalStrength==0)
end
assert(writes==0)
local envelopes=0
f.systemsAirborneAtStart=function()return false end
f.beginSystemsBatch=function(self,io,stage,maps,at)
 assert(stage=='probe');writes=writes+1
 self.systemsRun.phase='VERIFYING';self.systemsRun.pending=nil;self.systemsRun.renewAt=at+10
end
f.systemsGuard=function()return true end
f.observeSystemsDynamics=function()end
f.balancedLiftModel=function()return {phase='AVAILABLE'} end
f.systemsEnvelopeReady=function()envelopes=envelopes+1;return false,'ENVELOPE WAIT' end
io.nodes.FL.providers.vent.boilerEfficiency=.5
assert(f:startSystems(io,100))
local run=f.systemsRun
-- The boiler wait is bounded at 120 s; stay inside that window.
for at=100,219 do
 f:updateSystems(io,at)
 assert(f.systemsRun==run and run.phase=='VERIFYING' and run.boilerWaiting)
 assert(f.systemsSnapshot.warning:find('LOW BOILER EFFICIENCY',1,true))
end
assert(envelopes==0 and io.nodes.FL.providers.vent.targetAmount==50000)
io.nodes.FL.providers.vent.boilerEfficiency=1
f:updateSystems(io,220)
assert(f.systemsRun==run and not run.boilerWaiting and envelopes==1)
assert(run.reason=='ENVELOPE WAIT')
""")

    def test_boiler_wait_ends_with_warning_start_or_refusal(self):
        lua=self.runtime()
        lua.execute("Flight=require('avionics.flight')")
        lua.execute(r"""
-- Build a started (VERIFYING) run whose gate sees the boiler readings set by setup(io).
local function scenario(setup)
 local f=Flight.new(CONFIG);f.controls=nil;f.systemsTarget=function()return 260 end
 local state={envelopes=0}
 local io={config=CONFIG,vessel={valid=true,uuid='ship',at=100,altitude=250,verticalSpeed=0,
  mass=150000,environment={gravity={y=-11},airPressure=.5}},
  inputs={valid=true,at=100,raw={}},nodes={},nodeFresh=function()return true end,
  sendSystemsCommand=function()end,sendSystemsStop=function()end}
 for _,q in ipairs({'FL','FR','BL','BR'})do
  io.nodes[q]={boot='boot',systemsStartReady=true,steamCount=1,providers={
   vent={controlRole='bulk',present=true,writable=true,targetValid=true,targetAmount=50000,
    signalValid=true,signalStrength=0,maxTarget=100000,minimumNonzeroTarget=50,
    boilerEfficiencyValid=true,boilerEfficiency=1},
   trim={controlRole='fine',present=true,writable=true,targetValid=true,targetAmount=5,
    signalValid=true,signalStrength=0,maxTarget=200,minimumNonzeroTarget=5}}}
 end
 f.systemsAirborneAtStart=function()return false end
 f.beginSystemsBatch=function(self,io,stage,maps,at)
  self.systemsRun.phase='VERIFYING';self.systemsRun.pending=nil;self.systemsRun.renewAt=at+10
 end
 f.systemsGuard=function()return true end
 f.observeSystemsDynamics=function()end
 f.balancedLiftModel=function()return {phase='AVAILABLE'} end
 f.systemsEnvelopeReady=function()state.envelopes=state.envelopes+1;return false,'ENVELOPE WAIT' end
 setup(io)
 assert(f:startSystems(io,100))
 return f,io,state
end
local function vent(io,q)return io.nodes[q].providers.vent end

-- A boiler at 50% is waited on for the whole window, then the start continues with a warning.
do
 local f,io,state=scenario(function(io)vent(io,'FL').boilerEfficiency=.5 end)
 local run=f.systemsRun
 for at=100,219 do
  f:updateSystems(io,at)
  assert(f.systemsRun==run and run.boilerWaiting and state.envelopes==0,at)
 end
 f:updateSystems(io,220)
 assert(f.systemsRun==run and not run.boilerWaiting and state.envelopes==1)
 assert(run.warning:find('BOILER BELOW 100% AFTER 120 S',1,true) and run.warning:find('FL/vent',1,true),run.warning)
 assert(run.reason=='ENVELOPE WAIT')
end

-- Exactly the 10% minimum continues; the lowest boiler below it is refused and named.
do
 local f,io,state=scenario(function(io)vent(io,'BR').boilerEfficiency=.10 end)
 for at=100,220 do f:updateSystems(io,at) end
 assert(f.systemsRun and state.envelopes==1)
end
do
 local f,io,state=scenario(function(io)
  vent(io,'FL').boilerEfficiency=.05;vent(io,'FR').boilerEfficiency=.016
 end)
 for at=100,219 do
  f:updateSystems(io,at)
  assert(f.systemsRun and f.systemsRun.boilerWaiting,at)
 end
 f:updateSystems(io,220)
 assert(f.systemsRun==nil and state.envelopes==0)
 assert(f.systemsSnapshot.phase=='ABORTED')
 assert(f.systemsSnapshot.reason=='START REFUSED: FR/vent BOILER 1.6% (MINIMUM 10%)',f.systemsSnapshot.reason)
 assert(f.systemsLastOutcome.reason==f.systemsSnapshot.reason)
 assert(f.systemsLastOutcome.abortDetails.boiler=='FR/vent BOILER 1.6% (MINIMUM 10%)')
 assert(f.systemsLastOutcome.abortDetails.boilerWaitedSeconds==120)
end

-- An unreadable boiler cannot be verified, so the start is refused after the wait.
do
 local f,io=scenario(function(io)vent(io,'BL').boilerEfficiencyValid=false end)
 for at=100,219 do f:updateSystems(io,at);assert(f.systemsRun,at) end
 f:updateSystems(io,220)
 assert(f.systemsRun==nil and f.systemsSnapshot.reason=='START REFUSED: BL/vent BOILER EFFICIENCY UNAVAILABLE',f.systemsSnapshot.reason)
end

-- Reaching 100% restarts the wait window for any later drop.
do
 local f,io,state=scenario(function(io)vent(io,'FL').boilerEfficiency=.02 end)
 for at=100,199 do f:updateSystems(io,at) end
 vent(io,'FL').boilerEfficiency=1
 f:updateSystems(io,200)
 assert(f.systemsRun and not f.systemsRun.boilerWaiting and state.envelopes==1)
 vent(io,'FL').boilerEfficiency=.02
 for at=201,319 do f:updateSystems(io,at);assert(f.systemsRun,at) end
 f:updateSystems(io,321)
 assert(f.systemsRun==nil and f.systemsSnapshot.phase=='ABORTED')
end
""")


# ======================================================================
# From test_bow_axis_lock: geometry.sable_bow_axis sets the Sable pose-frame bow; bow-axis learning is removed.
# ======================================================================
import json
import re
import unittest

import project


class BowAxisLockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = project.ROOT / "source/core/avionics"
        cls.config = json.loads((root / "config.json").read_bytes())
        cls.io = (root / "io.lua").read_text(encoding="utf-8")
        cls.sources = (root / "vessel_sources.lua").read_text(encoding="utf-8")
        cls.storage = (root / "storage.lua").read_text(encoding="utf-8")

    def test_amaryllis_bow_is_plus_x(self):
        self.assertEqual(self.config["geometry"]["sable_bow_axis"], {"x": 1, "y": 0, "z": 0})

    def test_core_attitude_uses_the_configured_axis_only(self):
        body = re.search(r"local function resolveVesselAttitude\(.*?\nend\n", self.io, re.S).group(0)
        self.assertIn('local attitudeAxisSource="CONFIGURED"', body)
        self.assertIn('"Sable pose / configured bow"', body)
        for removed in ("chamberAttitudeAxis", "attitudeAxisLatch", "HEADING MATCH", "CHAMBER HEIGHTS"):
            self.assertNotIn(removed, self.io)
        self.assertNotIn("attitude-axis.json", self.io)

    def test_vessel_sources_prefer_the_configured_axis(self):
        self.assertIn('p.attitudeAxisSource="CONFIGURED"', self.sources)
        self.assertNotIn("attitudeAxisLearned", self.sources)
        self.assertIn("local bow=lockedBow and {x=lockedBow.x,y=0,z=lockedBow.z} or (c and c.bow) or vec(p.attitudeBow)", self.sources)

    def test_config_validation_accepts_only_horizontal_unit_axes(self):
        self.assertIn('geometry.sable_bow_axis must be +X, -X, +Z or -Z in the Sable pose frame', self.storage)


class BowAxisLockSamplingTests(unittest.TestCase):
    def test_configured_axis_drives_heading_and_forward_speed_in_real_sampling(self):
        pass
        traces = io_traces({"x": 1, "y": 0, "z": 0})
        valid = [t["vessel"] for t in traces if t.get("vessel", {}).get("valid")]
        self.assertTrue(valid)
        for vessel in valid:
            self.assertEqual(vessel["attitudeAxisSource"], "CONFIGURED")
            self.assertEqual(vessel["attitudeBow"], {"x": 1, "y": 0, "z": 0})
            if "sableVelocity" in vessel and str(vessel.get("forwardSpeedSource", "")).startswith("Sable"):
                self.assertEqual(vessel["forwardSpeed"], vessel["sableVelocity"]["x"])


# ======================================================================
# From test_speed_source: Forward speed source and the selected-speed stall fix.
# ======================================================================
import json
import re
import unittest

import project
from tests import test_builder as support
from tests.test_builder import table

AVIONICS = project.ROOT / "source/core/avionics"


class ForwardSpeedSourceTests(unittest.TestCase):
    def compose(self, sensor_speed, sable=3.87, reader=None):
        lua, _ = support.native_runtime()
        sources = {"/avionics/" + p.name: p.read_text(encoding="utf-8") for p in AVIONICS.glob("*.lua")}
        lua.globals().SOURCES = table(lua, sources)
        lua.globals().CONFIG = table(lua, json.loads((AVIONICS / "config.json").read_bytes()))
        lua.globals().SENSOR = sensor_speed
        lua.globals().SABLE = sable
        lua.globals().READER = reader
        return lua.execute(r'''
local loaded={}
function require(n) if loaded[n] then return loaded[n] end;loaded[n]=assert(load(SOURCES["/"..n:gsub("%.","/")..".lua"],n))();return loaded[n] end
local S=require("avionics.vessel_sources")
local io={config=CONFIG,sensorBindings={velocity_sensors={"vx"}},hardwareFingerprint="f"}
local now=100
S.acceptPrimary(io,"uuid","ship",now)
S.acceptPrimary(io,"pose",{orientation={x=0,y=0,z=0,w=1},position={x=0,y=160,z=0},rotationPoint={x=0,y=0,z=0},scale={x=1,y=1,z=1}},now)
S.acceptPrimary(io,"com",{x=0,y=0,z=0},now)
if SABLE then S.acceptPrimary(io,"velocity",{x=SABLE,y=0,z=0},now,"core") end
if READER then S.acceptPrimary(io,"velocity",{x=READER,y=0,z=0},now+0.5,"reader") end
S.acceptPrimary(io,"mass",140000,now)
if SENSOR then io.fallbackReadings={["velocity:vx"]={value={axis="x",speed=SENSOR,name="vx"},at=now}} end
local v=S.compose(io,now+0.5)
return v.forwardSpeed,v.forwardSpeedSource,(v.sources or {}).mode,v.forwardSpeedSableCore,v.forwardSpeedSableReader,v.forwardSpeedSensor
''')

    def test_sable_velocity_sets_forward_speed(self):
        speed, source, mode, *_ = self.compose(6.26, sable=6.26)
        self.assertAlmostEqual(speed, 6.26)
        self.assertEqual(source, "SABLE")
        self.assertEqual(mode, "PRIMARY")

    def test_velocity_sensor_is_the_fallback(self):
        speed, source, *_ = self.compose(6.26, sable=None)
        self.assertAlmostEqual(speed, 6.26)
        self.assertEqual(source, "VELOCITY SENSOR")

    def test_core_reading_wins_over_a_newer_reader_reading(self):
        speed, source, _, core, reader, sensor = self.compose(6.0, sable=6.26, reader=3.87)
        self.assertAlmostEqual(speed, 6.26)
        self.assertAlmostEqual(core, 6.26)
        self.assertAlmostEqual(reader, 3.87)
        self.assertAlmostEqual(sensor, 6.0)

    def test_reader_fills_in_without_core_reading(self):
        speed, *_ = self.compose(None, sable=None, reader=3.87)
        self.assertAlmostEqual(speed, 3.87)


class SpeedStallTests(unittest.TestCase):
    def test_steady_speed_outside_the_band_still_integrates(self):
        text = (AVIONICS / "thrust.lua").read_text(encoding="utf-8")
        self.assertIn("loop.steadySpeedSeconds>=3", text)
        self.assertIn("math.abs(error)<=integrateBand or loop.steadySpeedSeconds>=3", text)


# ======================================================================
# From test_gas_mix_fix: Fix gas mix lag: core restarts each chamber's trim probe link (off, then back to its level).
# ======================================================================
import unittest

import project
from tests import test_builder as support
from tests.test_state import runtime, fixture_source

HARDWARE = (project.ROOT / "source/library/packages/common/chamber-hardware.lua").read_text(encoding="utf-8")
LINK = r'''
local Hardware=assert(load(SOURCE))().lift
LEVEL=...;WRITES={};WAITS={};READ_FAILS=0
local api={hasType=function() return true end,
    getMethods=function() return {"getLinkSignal","sendLinkSignal"} end,
    call=function(name,method,first,second,level)
        if method=="getLinkSignal" then
            if READ_FAILS>0 then return nil end
            return LEVEL
        end
        if method=="sendLinkSignal" then WRITES[#WRITES+1]=level;LEVEL=level;return true end
    end}
CONFIG={activationBridge="redstone_link_bridge_0",trimActivationFrequency={first="minecraft:blaze_rod",second="minecraft:coal"}}
function cycle() return Hardware.cycleProbeLink(CONFIG,api,1,function(s) WAITS[#WAITS+1]=s end) end
'''


class ProbeLinkCycleTests(unittest.TestCase):
    def lua(self, level):
        lua, _ = support.native_runtime()
        lua.globals().SOURCE = HARDWARE
        lua.execute(LINK, level)
        return lua

    def test_link_goes_off_then_back_to_its_level(self):
        lua = self.lua(15)
        ok, detail = lua.execute("return cycle()")
        self.assertTrue(ok, detail)
        self.assertEqual(detail, "PROBE RESTARTED")
        self.assertEqual(list(lua.globals().WRITES.values()), [0, 15])
        self.assertEqual(lua.globals().WAITS[1], 1)

    def test_link_that_was_off_stays_off(self):
        lua = self.lua(0)
        ok, detail = lua.execute("return cycle()")
        self.assertTrue(ok)
        self.assertIn("LEFT OFF", detail)
        self.assertEqual(len(lua.globals().WRITES), 0)

    def test_unreadable_link_is_refused_without_writing(self):
        lua = self.lua(15)
        ok, detail = lua.execute("READ_FAILS=1;return cycle()")
        self.assertFalse(ok)
        self.assertEqual(len(lua.globals().WRITES), 0)


CORE = r'''
local io,f,p,clock=setup()
local sent={}
io.nodes={};for _,q in ipairs({"FL","FR","BL","BR"}) do io.nodes[q]={boot="boot-"..q,id=({FL=14,FR=9,BL=13,BR=10})[q]} end
io.config.node_ids={FL=14,FR=9,BL=13,BR=10}
io.session="core-session"
function io:nodeFresh() return true end
function io:sendLiftMaintenance(q,operation) sent[#sent+1]=q..":"..operation;return true,#sent end
f.enabled=true;f.startupPending=nil;f.systemsRun=nil;f.tuningRun=nil;f.maintenanceJob=nil
local ok,why=f:maintenanceRequest(io,{type="maintenance_probe_cycle",scope="ALL"},10)
check(not ok and why=="DISENGAGE ALTITUDE CONTROL FIRST","altitude control must be off: "..tostring(why))
f.enabled=false
ok,why=f:maintenanceRequest(io,{type="maintenance_probe_cycle",scope="ALL"},10)
check(ok,why);check(sent[1]=="FL:probe_cycle","first chamber asked to restart its probe")
check(f.maintenanceStatus=="FL RESTARTING PROBE",f.maintenanceStatus)
for i,q in ipairs({"FL","FR","BL","BR"}) do
    local job=f.maintenanceJob
    check(f:maintenanceAck(io,io.config.node_ids[q],{v=1,kind="lift_maintenance_ack",session="core-session",seq=job.seq,
        operation="probe_cycle",quadrant=q,nodeBoot="boot-"..q,ok=true,detail="PROBE RESTARTED"},10+i),"ack "..q)
    f:updateMaintenance(io,10+i)
end
check(#sent==4 and sent[4]=="BR:probe_cycle","all four chambers in order")
check(f.maintenanceStatus=="GAS MIX FIX COMPLETE",tostring(f.maintenanceStatus))
check(f.maintenanceJob==nil,"job finished")
return checks
'''


class CoreGasMixFixTests(unittest.TestCase):
    def test_core_restarts_every_chamber_probe_in_turn(self):
        lua = runtime()
        self.assertGreater(lua.execute(fixture_source() + "\n" + CORE), 0)


PANEL = r'''
local Panel=assert(load(SOURCE))()
keys=keys or {up=200,down=208,pageUp=201,pageDown=209,backspace=14,escape=1}
QUEUED={}
os.queueEvent=function(name,value) QUEUED[#QUEUED+1]={name,value} end
CONTEXT={id=3,now=0,runtime={snapshot={altitudeControl={enabled=false},maintenance={}}}}
panel=Panel.new({pageRows=function() return {} end},{})
function screen() local f=panel:frame(CONTEXT,51,19);panel.links=f.links;return table.concat(f.text,"\n") end
function press(label)
    local f=panel:frame(CONTEXT,51,19)
    for _,link in ipairs(f.links) do
        local text=f.text[link.y]:sub(link.x,link.x+link.w-1)
        if text:find(label,1,true) then panel:action(link.action);return true end
    end
    error("no button "..label)
end
'''


class PanelGasMixTests(unittest.TestCase):
    def panel(self):
        lua, _ = support.native_runtime()
        lua.globals().SOURCE = (project.ROOT / "disk-builder/assets/panel-console.lua").read_text(encoding="utf-8")
        lua.execute(PANEL)
        return lua

    def test_tools_page_opens_the_fix_with_confirmation(self):
        lua = self.panel()
        lua.execute('panel:choose("tools")')
        self.assertIn("Fix gas mix lag >", lua.execute("return screen()"))
        lua.execute('press("Fix gas mix lag >")')
        text = lua.execute("return screen()")
        self.assertIn("FIX GAS MIX LAG", text)
        self.assertIn("Mixing Hot Air and Steam in balloons", text)
        self.assertIn("READY", text)
        lua.execute('press("Fix gas mix lag")')
        self.assertIn("Confirm", lua.execute("return screen()"))
        self.assertEqual(lua.execute("return #QUEUED"), 0, "nothing runs before confirmation")
        lua.execute('press("Confirm")')
        self.assertEqual(lua.execute("return QUEUED[1][1]"), "amaryllis_core_action")
        self.assertEqual(lua.execute("return QUEUED[1][2].type"), "maintenance_probe_cycle")

    def test_status_shows_refusal_and_progress(self):
        lua = self.panel()
        lua.execute('panel:choose("gasMix")')
        lua.execute('CONTEXT.runtime.snapshot.altitudeControl.enabled=true')
        self.assertIn("DISENGAGE ALTITUDE CONTROL FIRST", lua.execute("return screen()"))
        lua.execute('os.__amaryllisCoreAction={type="maintenance_probe_cycle",accepted=true};CONTEXT.runtime.snapshot.maintenance.status="BL RESTARTING PROBE"')
        self.assertIn("BL RESTARTING PROBE", lua.execute("return screen()"))
        lua.execute('os.__amaryllisCoreAction=nil')

    def test_core_runtime_runs_console_actions(self):
        text = (project.ROOT / "source/core/avionics/main.lua").read_text(encoding="utf-8")
        self.assertIn('event=="amaryllis_core_action"', text)
        self.assertIn("pcall(flight.request,flight,io,sender,now)", text)
        self.assertIn("os.__amaryllisCoreAction=", text)

    def test_tools_page_scrolls_when_buttons_do_not_fit(self):
        lua = self.panel()
        lua.execute('panel:choose("tools")')
        text = lua.execute("return screen()")
        self.assertIn("Shell >", text)
        self.assertIn("1-7 / 8", text)
        self.assertNotIn("Background services >", text)
        lua.execute('panel:input("key",keys.down)')
        text = lua.execute("return screen()")
        self.assertNotIn("Shell >", text)
        self.assertIn("Background services >", text)
        self.assertIn("2-8 / 8", text)
        lua.execute('panel:input("mouse_scroll",-1)')
        self.assertIn("Shell >", lua.execute("return screen()"))
        lua.execute('press("Fix gas mix lag >")')
        self.assertIn("FIX GAS MIX LAG", lua.execute("return screen()"))
        tall = lua.execute('panel:choose("tools");local f=panel:frame(CONTEXT,51,24);return table.concat(f.text,"\\n")')
        self.assertIn("Background services >", tall)
        self.assertNotIn("/ 8", tall)


# ======================================================================
# From test_strafe_balance: Front and back strafe balance: mixer scaling, registry clamp and shipped setting.
# ======================================================================
import json
import sys
import unittest

import project

sys.path.insert(0, str(project.ROOT / "tools"))
import config_registry as registry_tool  # noqa: E402

# Shared Lua prelude: a verified mixer with every group at full sideways gain,
# matching the copy that route and anchor authority build before balancing.
PRELUDE = r"""
local Thrust=require('avionics.thrust')
local Registry=require('avionics.config_registry')
local function mixer()
    local out={}
    for _,quad in ipairs({'lb','rb','ls','rs'}) do
        out[quad]={side_gain=1,side_sign=-1,yaw_gain=1,yaw_sign=(quad=='lb' or quad=='rb') and 1 or -1}
    end
    return out
end
local function near(a,b) return math.abs(a-b)<1e-9 end
"""


class StrafeBalanceTests(unittest.TestCase):
    def run_lua(self, body):
        lua = registry_tool.runtime()
        lua.execute(PRELUDE + body)

    def test_hundred_percent_leaves_all_groups_equal(self):
        self.run_lua(r"""
            local balanced=Thrust.balanceStrafe(mixer(),100)
            for _,quad in ipairs({'lb','rb','ls','rs'}) do assert(near(balanced[quad].side_gain,1),quad) end
        """)

    def test_below_hundred_reduces_only_the_front_pair(self):
        self.run_lua(r"""
            local balanced=Thrust.balanceStrafe(mixer(),60)
            for _,quad in ipairs({'lb','rb'}) do assert(near(balanced[quad].side_gain,0.6),quad) end
            for _,quad in ipairs({'ls','rs'}) do assert(near(balanced[quad].side_gain,1),quad) end
        """)

    def test_above_hundred_reduces_the_back_pair_and_stays_within_range(self):
        self.run_lua(r"""
            local balanced=Thrust.balanceStrafe(mixer(),150)
            for _,quad in ipairs({'lb','rb'}) do assert(near(balanced[quad].side_gain,1),quad) end
            for _,quad in ipairs({'ls','rs'}) do
                assert(near(balanced[quad].side_gain,1/1.5),quad)
                assert(balanced[quad].side_gain<=1)
            end
        """)

    def test_balance_leaves_yaw_gains_and_the_source_mixer_unchanged(self):
        self.run_lua(r"""
            local source=mixer()
            local balanced=Thrust.balanceStrafe(source,60)
            for _,quad in ipairs({'lb','rb','ls','rs'}) do
                assert(balanced[quad].yaw_gain==1 and balanced[quad].yaw_sign==source[quad].yaw_sign)
                assert(source[quad].side_gain==1,'configured mixer must not be modified')
            end
        """)

    def test_balanced_mixer_scales_front_strafe_output(self):
        self.run_lua(r"""
            local equal=Thrust.mixLateral(1,0,Thrust.balanceStrafe(mixer(),100))
            local reduced=Thrust.mixLateral(1,0,Thrust.balanceStrafe(mixer(),60))
            assert(near(equal['lateral-lb-s'],1) and near(equal['lateral-rb-s'],1))
            assert(near(reduced['lateral-lb-s'],0.6) and near(reduced['lateral-rb-s'],0.6))
            for _,drive in ipairs({'lateral-ls-s','lateral-rs-s'}) do
                assert(near(reduced[drive],1),drive)
            end
        """)

    def test_invalid_input_returns_the_mixer_unchanged(self):
        self.run_lua(r"""
            local source=mixer()
            assert(Thrust.balanceStrafe(source,0)==source)
            assert(Thrust.balanceStrafe(source,0/0)==source)
            assert(Thrust.balanceStrafe(nil,100)==nil)
        """)

    def test_registry_supplies_fallback_and_clamps(self):
        self.run_lua(r"""
            local id='thrust.front_back_strafe_percent'
            assert(Registry.number({},id)==100)
            assert(Registry.number({front_back_strafe_percent=80},id)==80)
            assert(Registry.number({front_back_strafe_percent=500},id)==150)
            assert(Registry.number({front_back_strafe_percent=1},id)==50)
        """)

    def test_shipped_value_is_equal_balance(self):
        config = json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes())
        self.assertEqual(config["thrust"]["front_back_strafe_percent"], 100)
        self.assertNotIn("front_left_strafe_percent", config["thrust"])


    def test_strafe_settings_live_under_cockpit_inputs(self):
        """The four cockpit strafe settings form the STRAFE SETTINGS group; page 2 keeps only the system buttons."""
        import re
        source = (project.ROOT / "source/core/avionics/flight.lua").read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r'field\("STRAFE SETTINGS"', source)), 4)
        self.assertNotIn('field("LATERAL"', source)
        ui = (project.ROOT / "source/library/packages/navigation/ui.lua").read_text(encoding="utf-8")
        self.assertNotIn('entry.group=="LATERAL"', ui)


# ======================================================================
# From test_thrust_readback: Thrust endpoint readback age while commands arrive during a controller pass.
# ======================================================================
import unittest

from lupa.lua52 import LuaRuntime
import project

COMMON = project.ROOT / "source/library/packages/common"
CASE = r'''
local source,role=...
__THRUST_TEST=true
local calls=0
package.preload["hardware"]=function() return {thrust={
    readShift=function(binding,allowed)
        calls=calls+1
        if calls==1 then STATE.writerToken=STATE.writerToken+1 end -- a command arrives mid-pass
        if allowed and not allowed() then return nil,"aborted" end
        return 0,nil,"incremental"
    end,
    writeShift=function() return true end, writeSafeZero=function() return true end,
}} end
package.loaded["hardware"]=nil
local Thrust=assert(load(source))()
local drives={}
for _,d in ipairs(Thrust.ROLE_DRIVES[role]) do drives[d]={maxLevel=256,rampPerSecond=.25} end
STATE=Thrust.newState({drives=drives,readbackStaleSeconds=1},role,"boot")
local bindings={};for d in pairs(drives) do bindings[d]={object={}} end
Thrust.controllerTick(STATE,STATE.config,bindings,os.clock(),.1)
local _,fresh=Thrust.readbackSnapshot(STATE,os.clock(),1)
return STATE.readbackSampleAt~=nil,fresh,calls
'''


class ReadbackDuringCommandTests(unittest.TestCase):
    def check(self, name, role):
        lua = LuaRuntime(unpack_returned_tuples=True)
        sampled, fresh, calls = lua.execute(CASE, (COMMON / name).read_text(encoding="utf-8"), role)
        self.assertTrue(sampled, "a command arriving mid-pass must not discard the completed readback")
        self.assertTrue(fresh)
        self.assertGreaterEqual(calls, 2, "every drive is read")

    def test_chamber_thrust_side_controller(self):
        self.check("chamber-thrust.lua", "thrust-ls")

    def test_front_thrust_controller(self):
        self.check("thrust-controller.lua", "thrust-lb")


# ======================================================================
# From test_propulsion_rejections: The core records why it refused a propulsion hello or status instead of dropping it silently.
# ======================================================================
import json
import sys
import unittest

import project

sys.path.insert(0, str(project.ROOT / "tools"))
import config_registry as registry_tool  # noqa: E402


class PropulsionRejectionTests(unittest.TestCase):
    def setUp(self):
        self.lua = registry_tool.runtime()
        self.lua.globals().CONFIG = registry_tool.lua_value(
            self.lua, json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes()))
        self.lua.execute(r"""
            Thrust = require("avionics.thrust")
            LOG = {}
            io = {session = "core-session", rednet = {send = function() return true end},
                  nowSeconds = function() return 10 end,
                  logState = function(self, key, issue) LOG[#LOG + 1] = {key = key, issue = issue} end}
            t = Thrust.new(CONFIG)
            t:setRegistry({["primary-left"] = 16, ["primary-right"] = 17}, io)
            hello = function(sender, role) return t:processMessage(io, sender,
                {v = 1, kind = "thrust_hello", role = role, endpointKind = "sensor", nodeBoot = "boot-1"},
                CONFIG.protocol, 10) end
        """)

    def test_hello_from_wrong_sender_is_recorded_and_logged(self):
        accepted, reason = self.lua.eval('hello(99, "primary-left")')
        self.assertFalse(accepted)
        self.assertEqual(reason, "SENDER #99 IS NOT FLEET ID #16")
        snapshot = self.lua.eval('t:unitSnapshot("primary-left", 10)')
        self.assertFalse(snapshot.discovered)
        self.assertIn("SENDER #99 IS NOT FLEET ID #16", snapshot.lastRejected.reason)
        self.assertEqual(snapshot.lastRejected.kind, "hello")
        log = self.lua.globals().LOG
        self.assertIn("SENDER #99", log[1].issue)

    def test_accepted_hello_clears_the_logged_refusal(self):
        self.lua.eval('hello(99, "primary-left")')
        self.assertTrue(self.lua.eval('hello(16, "primary-left")'))
        self.assertTrue(self.lua.eval('t:unitSnapshot("primary-left", 10)').discovered)
        log = self.lua.globals().LOG
        self.assertIsNone(log[len(log)].issue, "refusal not cleared after acceptance")

    def test_status_with_stale_session_is_recorded(self):
        self.assertTrue(self.lua.eval('hello(17, "primary-right")'))
        self.lua.execute(r"""
            t:processMessage(io, 17, {v = 1, kind = "thrust_status", session = "old-session", role = "primary-right",
                endpointKind = "sensor", nodeBoot = "boot-1", seq = 1, available = true, readings = {}, faults = {}},
                CONFIG.protocol, 10)
        """)
        snapshot = self.lua.eval('t:unitSnapshot("primary-right", 10)')
        self.assertEqual(snapshot.lastRejected.reason, "STALE CORE SESSION")
        self.assertEqual(snapshot.lastRejected.kind, "status")


# ======================================================================
# From test_auto_propulsion: START SYSTEMS enables propulsion by itself once the altitude hold has stayed settled.
# ======================================================================
import re
import unittest

import project
from tests import test_builder as support


class AutoPropulsionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = (project.ROOT / "source/core/avionics/flight.lua").read_text(encoding="utf-8")
        cls.function = re.search(r"function Flight:autoEnablePropulsion\(.*?\nend\n", text, re.S).group(0)
        cls.call = "pcall(self.autoEnablePropulsion,self,io,s,now)"
        cls.source = text

    def lua(self):
        lua, _ = support.native_runtime()
        lua.execute('''
Flight={}
local function finite(v) return type(v)=="number" and v==v and v~=math.huge and v~=-math.huge end
LOGS={};os.__amaryllisLog=function(m) LOGS[#LOGS+1]=m end
''' + self.function + '''
function make(enabled,accept)
  local io={vessel={altitude=160,verticalSpeed=0.02},config={thrust={enabled=enabled}},calls=0}
  io.thrust={config={thrust={enabled=enabled}}}
  function io.thrust:setEnabled(io2,now,controls,on)
    io.calls=io.calls+1
    if accept then self.config.thrust.enabled=on end
    return accept, accept and "PROPULSION ENABLED" or "RELEASE THROTTLE AND STEERING INPUTS"
  end
  local self={controls={},storage={},settingsDependencies={}}
  local s={phase="READY",target=160}
  return io,self,s
end
function tick(io,self,s,now) Flight.autoEnablePropulsion(self,io,s,now) end
''')
        return lua

    def test_enables_once_after_ten_settled_seconds(self):
        lua = self.lua()
        lua.execute('''
local io,self,s=make(false,true)
for t=0,9.5,0.5 do tick(io,self,s,t) end
assert(io.calls==0,"too early")
tick(io,self,s,10);assert(io.calls==1 and s.propulsionAutoDone,"should enable at 10 s")
for t=10.5,30,0.5 do tick(io,self,s,t) end
assert(io.calls==1,"must enable only once per run")
assert(#LOGS==1)
''')

    def test_unsettled_altitude_restarts_the_timer(self):
        lua = self.lua()
        lua.execute('''
local io,self,s=make(false,true)
for t=0,8 do tick(io,self,s,t) end
io.vessel.verticalSpeed=0.5;tick(io,self,s,9)
io.vessel.verticalSpeed=0.0
for t=10,19.5,0.5 do tick(io,self,s,t) end
assert(io.calls==0,"timer must restart after a disturbance")
tick(io,self,s,20);assert(io.calls==1)
''')

    def test_far_from_target_or_not_ready_never_enables(self):
        lua = self.lua()
        lua.execute('''
local io,self,s=make(false,true);io.vessel.altitude=157
for t=0,30 do tick(io,self,s,t) end
assert(io.calls==0)
local io2,self2,s2=make(false,true);s2.phase="MAIN_LIFT"
for t=0,30 do tick(io2,self2,s2,t) end
assert(io2.calls==0)
''')

    def test_already_enabled_propulsion_is_left_alone(self):
        lua = self.lua()
        lua.execute('''
local io,self,s=make(true,true)
for t=0,30 do tick(io,self,s,t) end
assert(io.calls==0 and s.propulsionAutoDone)
''')

    def test_rejected_attempts_retry_every_two_seconds_until_accepted(self):
        lua = self.lua()
        lua.execute('''
local io,self,s=make(false,false)
for t=0,10 do tick(io,self,s,t) end
assert(io.calls==1 and not s.propulsionAutoDone and s.propulsionAutoReason)
for t=10.5,15,0.5 do tick(io,self,s,t) end
assert(io.calls==3,"retries every 2 s, got "..io.calls)
''')

    def test_hook_runs_in_the_hold_phase_after_hover_learning(self):
        self.assertIn(self.call, self.source)
        hold = self.source.index("pcall(self.rememberHoverOffset,self,io.vessel,s,actualRatio,now)")
        self.assertLess(hold, self.source.index(self.call))


if __name__ == "__main__":
    import unittest
    unittest.main()
