"""Characterization traces and offline cost measurements for staged control extraction."""
import json
import math
import statistics
import time
import unittest
import project
from tests import test_flight_model as model
from tests import test_recordings as recordings
from tests import test_autopilot as autopilot
from tests import test_persistence as persistence
from tests.test_runtime_bundling import table, python_value


def benchmark(label, repeats=5, samples=1500):
    """Measure repeated selected-speed calculations with identical synthetic inputs."""
    autopilot.AutopilotTests.setUpClass()
    timings=[];allocations=[];checksums=[]
    for _ in range(repeats):
        lua=autopilot.AutopilotTests().runtime()
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
        model.FlightModelTests().test_closed_loop_maintained_acquisition_and_hold()
        model.FlightModelTests().test_longitudinal_loop_uses_maintained_thrust()
        recordings.RecordingTests().test_recorded_input_source_bundle_trace()
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

if __name__=='__main__':unittest.main()
