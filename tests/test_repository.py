"""Repository portability and current-source packaging checks."""
import json
import unittest
import project
from tests.test_runtime_bundling import LuaRuntime, table

class RepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Collect current maintained sources from the project checkout."""
        cls.builder = project.builder_module()
        cls.source = cls.builder.collect_project(project.ROOT)
        cls.packed = cls.builder.bundling.prepare(cls.source, cls.builder.FOLDERS)

    def test_current_sources_compile_and_roundtrip(self):
        """Compile editable sources and verify their exact bundled recovery."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        compile = lua.eval('function(s,n)local f,e=load(s,"@"..n);return f~=nil,e end')
        for group in ("payload", "library"):
            for name, data in self.source[group].items():
                if name.endswith(".lua"):
                    ok, why = compile(data.decode(), name)
                    self.assertTrue(ok, str(why))
        expanded = self.builder.bundling.expand(self.packed["payload"], self.source["assets"]["runtime-loader.lua"])
        for name, data in self.source["payload"].items():
            if name.endswith(".lua"):
                expected = self.builder.bundling.server_overlay(data) if name == "/installer/server.lua" else data
                self.assertEqual(expanded[name], expected, name)

    def test_asset_backed_modules_have_one_editing_location(self):
        """Check that builder-owned modules are supplied from their maintained assets."""
        import json
        metadata = json.loads((project.ROOT / "source/baseline.json").read_bytes())
        files = project.source_files()
        for name, asset in metadata["assetBackedModules"].items():
            self.assertFalse((project.ROOT / "source/core" / name).exists())
            self.assertEqual(files[name], (project.HOME / "assets" / asset).read_bytes())

    def test_current_payload_count(self):
        """Keep the compact installed layout."""
        self.assertEqual(len(self.packed["payload"]), 5)
        self.assertEqual(len(self.packed["state"]), 3)
        for role, count in self.packed["bundleCounts"].items():
            if role not in ("core", "state"):
                self.assertEqual(count["after"], 3)

    def chamber_idle_runtime(self, quadrant, bundled=False):
        """Load a maintained chamber worker with controllable sampled hardware and probe outcomes."""
        prefix = "/packages/chamber/" + quadrant + "/"
        data = self.source["library"][prefix + "lift.lua"]
        if bundled:
            _, files = self.builder.bundling.unpack(self.packed["library"][prefix + "main.lua"],
                                                   self.source["assets"]["runtime-loader.lua"])
            data = files["/avionics/lift.lua"]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().LIFT_SOURCE = data.decode()
        lua.execute(r'''
NOW=10;os.clock=function() return NOW end
PROVIDERS={};PROBE_CALLS=0;SAMPLE_HOOK=nil;PROBE_ACTION=nil;ACTIVATION_VALID=true
H={localPeripheral=function() return {} end,
    isFiniteNumber=function(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end,
    sampleConfigured=function()
        if SAMPLE_HOOK then local f=SAMPLE_HOOK;SAMPLE_HOOK=nil;f() end
        return {providers=PROVIDERS,ready=true,faults={}}
    end,
    sampleBalloon=function() return {liftValid=true,lift=0} end,
    sampleAltitude=function() return {valid=true} end,
    sampleActivation=function() return {valid=ACTIVATION_VALID} end,
    startCompositionProbe=function(config,api,current)
        PROBE_CALLS=PROBE_CALLS+1
        if PROBE_ACTION then return PROBE_ACTION(current) end
        assert(current());return true,'PROBE_STARTED_WAITING_FOR_ENVELOPE'
    end}
require=function(name) assert(name=='hardware');return {lift=H} end
Main=assert(load(LIFT_SOURCE,'@chamber-lift'))('avionics.main')
function fresh()
    S={sourceConfig={},config={providers={},commandTimeoutSeconds=2},configValid=true,
        modemReady=true,armed=false,sessionGeneration=1,appliedTargets={bulk=1400,trim=5}}
    PROVIDERS={};PROBE_CALLS=0;PROBE_ACTION=nil;SAMPLE_HOOK=nil;ACTIVATION_VALID=true
end
function maintain() Main._test.maintainIdleProbe(S,{}) end
function status()
    Main._test.refreshSnapshot(S,{},NOW)
    return table.concat(S.faults,';')
end
function retained() assert(S.appliedTargets.bulk==1400 and S.appliedTargets.trim==5) end
fresh()
''')
        return lua

    def test_idle_probe_cancellation_retries_without_sticky_faults(self):
        """Supersede idle work during peripheral waits, retain newer faults, then recover on retry."""
        for quadrant in ("fl", "fr", "bl", "br"):
            for bundled in (False, True):
                with self.subTest(quadrant=quadrant, bundled=bundled):
                    lua = self.chamber_idle_runtime(quadrant, bundled)
                    lua.execute(r'''
S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_HARDWARE_GENERATION_CHANGED'
S.armed=true;maintain();assert(S.lastApplyFault==nil and PROBE_CALLS==0);retained()
fresh()
PROBE_ACTION=function(current)
    S.pendingCommand={seq=7};assert(not current())
    return false,'PROBE_HARDWARE_GENERATION_CHANGED'
end
maintain();assert(PROBE_CALLS==1 and S.lastApplyFault==nil);retained()
S.pendingCommand=nil;PROBE_ACTION=nil;maintain()
assert(PROBE_CALLS==2 and S.lastApplyFault==nil and not status():find('IDLE_PROBE_FAILED',1,true))
retained()
fresh()
PROBE_ACTION=function(current)
    S.sessionGeneration=S.sessionGeneration+1;assert(not current())
    return false,'PROBE_READ_FAILED'
end
maintain();assert(S.lastApplyFault==nil);retained()
fresh()
PROBE_ACTION=function(current)
    S.pendingCommand={seq=8};S.lastApplyFault='NEWER_COMMAND_FAULT';assert(not current())
    return false,'PROBE_HARDWARE_GENERATION_CHANGED'
end
maintain();assert(S.lastApplyFault=='NEWER_COMMAND_FAULT');retained()
fresh();SAMPLE_HOOK=function() S.pendingMaintenance={operation='inspect'} end
maintain();assert(PROBE_CALLS==0 and S.lastApplyFault==nil);retained()
''')

    def test_idle_probe_real_failures_clear_after_confirmed_recovery(self):
        """Keep current probe failures visible and clear only recovered probe-owned faults."""
        for quadrant in ("fl", "fr", "bl", "br"):
            for bundled in (False, True):
                with self.subTest(quadrant=quadrant, bundled=bundled):
                    lua = self.chamber_idle_runtime(quadrant, bundled)
                    lua.execute(r'''
PROBE_ACTION=function(current) assert(current());return false,'PROBE_BURNER_MISSING' end
maintain();assert(S.lastApplyFault=='IDLE_PROBE_FAILED:PROBE_BURNER_MISSING')
assert(status():find('IDLE_PROBE_FAILED:PROBE_BURNER_MISSING',1,true));retained()
PROBE_ACTION=nil;maintain()
assert(S.lastApplyFault==nil and not status():find('IDLE_PROBE_FAILED',1,true));retained()
S.lastApplyFault='UNRELATED_APPLY_FAULT';maintain()
assert(S.lastApplyFault=='UNRELATED_APPLY_FAULT');retained()
fresh();S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_READ_FAILED'
PROVIDERS={trim={controlRole='fine',signalValid=true,signalStrength=15,targetValid=true,
    targetAmount=5,maxTarget=500,minimumNonzeroTarget=5,activeValid=true,active=true}}
maintain();assert(S.lastApplyFault==nil and PROBE_CALLS==0);retained()
S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_READ_FAILED';ACTIVATION_VALID=false
maintain();assert(S.lastApplyFault=='IDLE_PROBE_FAILED:PROBE_READ_FAILED' and PROBE_CALLS==0);retained()
fresh();S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_BURNER_MISSING'
PROVIDERS={bulk={controlRole='bulk',signalValid=true,signalStrength=15,targetValid=true,targetAmount=1400}}
maintain();assert(S.lastApplyFault=='IDLE_PROBE_FAILED:PROBE_BURNER_MISSING' and PROBE_CALLS==0);retained()
fresh();S.emergencyStopLatched=true;maintain();assert(PROBE_CALLS==0);retained()
fresh();S.systemsLease={expires=20};maintain();assert(PROBE_CALLS==0);retained()
''')

    def propulsion_runtime(self):
        """Connect maintained core and endpoint protocols through a controllable simulated radio."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().CORE_SOURCE = self.source["payload"]["/avionics/thrust.lua"].decode()
        lua.globals().MATH_SOURCE = project.source_files()["avionics/mathx.lua"].decode()
        lua.globals().REGISTRY_SOURCE = project.source_files()["avionics/config_registry.lua"].decode()
        lua.globals().CONFIG = table(lua, json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes()))
        endpoints = {}
        for corner in ("lb", "rb", "ls", "rs"):
            folder = project.ROOT / "source/library/packages/thrust" / corner
            endpoints["thrust-" + corner] = {
                "source": project.source_files()["packages/thrust/" + corner + "/thrust.lua"].decode(),
                "config": json.loads((folder / "config.json").read_bytes()),
            }
        lua.globals().ENDPOINTS = table(lua, endpoints)
        lua.execute(r'''
NOW=10; DROP_COMMANDS=false; DROP_ALL=false; SENT={}; STATES={}; MODULES={}; IDS={}
os.clock=function() return NOW end
__THRUST_TEST=true
require=function(name)
    if name=="avionics.mathx" then return assert(load(MATH_SOURCE))() end
    if name=="avionics.config_registry" then return assert(load(REGISTRY_SOURCE))() end
    assert(name=="hardware")
    return {thrust={expectedShift=function(value,minimum,maximum)
        return math.floor(minimum+(maximum-minimum)*value+.5)
    end}}
end
Core=assert(load(CORE_SOURCE))(); core=Core.new(CONFIG)
io={session="lease-test-session",identityReady=true,vessel={},nowSeconds=function() return NOW end}
io.rednet={send=function(id,packet,protocol)
    SENT[#SENT+1]={id=id,packet=packet,at=NOW}
    if DROP_ALL or (DROP_COMMANDS and packet.kind=="thrust_command") then return true end
    local role=IDS[id]
    return MODULES[role].processPacket(STATES[role],0,packet,protocol,NOW)
end}
for index,role in ipairs(Core.CONTROLLERS) do
    local definition=ENDPOINTS[role]
    local endpoint=assert(load(definition.source))()
    definition.config.coreId=0
    local state=endpoint.newState(definition.config,role,"boot-"..role)
    state.configValid=true;state.bindingReady=true;state.writerEnabled=true
    state.enabled=true;state.ready=true;state.direction=1
    state.directionVerified=true;state.directionPhase="READY"
    MODULES[role]=endpoint;STATES[role]=state;IDS[index]=role
end
function hello()
    if DROP_ALL then return end
    for id,role in ipairs(Core.CONTROLLERS) do
        assert(core:acceptHello(io,id,{v=1,role=role,endpointKind="controller",
            nodeBoot=STATES[role].nodeBoot,drives=STATES[role].drives},NOW))
    end
end
function publish()
    for id,role in ipairs(Core.CONTROLLERS) do
        local state=STATES[role];local endpoint=MODULES[role]
        local targets=endpoint.targetsAt(state,NOW)
        local readbacks={}
        for _,drive in ipairs(state.drives) do
            readbacks[drive]={level=math.floor(math.abs(targets[drive])*256+.5),mode="incremental"}
        end
        endpoint.updateReadbacks(state,readbacks,NOW)
        state.readbackSampleAt=NOW
        if not DROP_ALL then assert(core:acceptStatus(io,id,endpoint.statusPacket(state,NOW),NOW)) end
    end
end
DEMAND={};for _,drive in ipairs(Core.DRIVES) do DEMAND[drive]=0 end
DEMAND["primary-left"]=.25;DEMAND["primary-right"]=.25
DEMAND["lateral-lb-p"]=.125
core.makeTargets=function() return DEMAND end
CONTROLS={available=true,modes={throttle="DIRECT",heading="MANUAL"},targets={speed=4,heading=90}}
function update()
    return core:update(io,NOW,CONTROLS)
end
hello();publish();assert(update());publish()
assert(STATES["thrust-lb"].leaseUntil==11)
''')
        return lua

    def test_propulsion_lease_recovers_after_repeated_lost_commands(self):
        """Expire all drive leases, keep dropping renewals, then recover without a reboot."""
        lua = self.propulsion_runtime()
        lua.execute(r'''
DROP_COMMANDS=true
for step=1,30 do
    NOW=10+step*.25
    hello();publish();assert(update())
end
local state=STATES["thrust-lb"]
assert(state.leaseUntil==false and state.reason=="COMMAND LEASE EXPIRED; RAMPING TO ZERO")
assert(state.desiredTargets["lateral-lb-p"]==0)
assert(core.controllers["thrust-lb"].commandRecovery.attempts>3)
local recovery=core:controllerSnapshot("thrust-lb",NOW).recovery
assert(recovery.state=="RETRYING ("..recovery.attempts..")")
assert(recovery.maximumAttempts==nil and recovery.failureAfterSeconds==nil)
local invalid={v=1,kind="thrust_command",role="thrust-lb",nodeBoot=state.nodeBoot,
    session="old-session",seq=1000,ttlSeconds=1,targets={['lateral-lb-p']=.5}}
assert(not MODULES["thrust-lb"].processPacket(state,0,invalid,CONFIG.protocol,NOW))
invalid.session=io.session;invalid.nodeBoot="old-boot"
assert(not MODULES["thrust-lb"].processPacket(state,0,invalid,CONFIG.protocol,NOW))
assert(state.leaseUntil==false and state.desiredTargets["lateral-lb-p"]==0)
local attempts=0
for _,sent in ipairs(SENT) do
    if sent.packet.kind=="thrust_command" and sent.at>11 then attempts=attempts+1 end
end
assert(attempts>3,"core must continue issuing commands after lease expiry")
DROP_COMMANDS=false;NOW=18;hello();publish();assert(update());publish()
for _,role in ipairs(Core.CONTROLLERS) do
    local current=STATES[role]
    assert(current.leaseUntil==19 and current.reason==nil and current.ackAccepted)
    assert(current.lastAppliedSeq==current.lastReceivedSeq)
    core:updateCommandRecovery(core.controllers[role],NOW)
    assert(core.controllers[role].commandRecovery==nil)
end
assert(state.desiredTargets["lateral-lb-p"]==.125)
assert(CONTROLS.targets.speed==4 and CONTROLS.targets.heading==90)
local seq=state.lastReceivedSeq;local deadline=state.leaseUntil
for _,sent in ipairs(SENT) do
    if sent.packet.role=="thrust-lb" and sent.packet.kind=="thrust_command" and sent.packet.seq<seq then
        assert(not MODULES["thrust-lb"].processPacket(state,0,sent.packet,CONFIG.protocol,NOW))
    end
end
assert(state.leaseUntil==deadline and state.lastReceivedSeq==seq)
''')

    def test_propulsion_recovers_after_session_gap_using_current_demand(self):
        """Reestablish a silent radio connection and renew the operator's current zero demand."""
        lua = self.propulsion_runtime()
        lua.execute(r'''
DROP_ALL=true
for step=1,32 do
    NOW=10+step*.25;publish();update()
end
assert(STATES["thrust-lb"].leaseUntil==false)
for drive in pairs(DEMAND) do DEMAND[drive]=0 end
DROP_ALL=false;NOW=19;hello();publish();assert(update());publish()
for _,role in ipairs(Core.CONTROLLERS) do
    local state=STATES[role]
    assert(state.leaseUntil==20 and state.ackAccepted)
    for _,value in pairs(state.desiredTargets) do assert(value==0) end
end
assert(core.active==false)
assert(CONTROLS.targets.speed==4 and CONTROLS.targets.heading==90)
''')

if __name__ == "__main__":
    unittest.main()
