"""Current control/source selection and supervision boundaries with explicit dependencies."""
import json
import unittest
import project
from tests import test_persistence as persistence
from tests import test_persistent_modes as modes
from tests.test_runtime_bundling import table

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

if __name__=='__main__':unittest.main()
