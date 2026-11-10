"""Current-source AP capture, drift learning, propulsion and bundled display checks."""
import json
import unittest

import project
from tests.test_runtime_bundling import LuaRuntime, table, python_value, native_runtime
from tests.test_bridge_presentation import HARNESS as UI_HARNESS

ROOT = project.ROOT
REPORT = ROOT / "output/tests/ap-route-capture"

HARNESS = r"""
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
        lua.execute(HARNESS)
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
        from tests.test_persistent_modes import fixture_source
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

if __name__ == '__main__':
    unittest.main()
