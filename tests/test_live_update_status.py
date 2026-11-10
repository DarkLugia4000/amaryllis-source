"""After a live update the running old installer rewrites status.json with the old release; the new console repairs it."""
import json
import re
import unittest

import project
from tests import test_runtime_bundling as support

INSTALL = {"role": "navigator", "packageId": "amaryllis.navigator", "label": "ama-bridge", "coreID": 3, "installID": "i-6",
           "clientSession": "c", "serverSession": "s", "coreSession": "k", "version": 13, "manifestChecksum": "NEW"}
STATUS = {"hasInstalled": True, "recoveryRequired": False, "state": "listening", "installedRole": "navigator",
          "installedPackageId": "amaryllis.navigator", "installedLabel": "ama-bridge", "installedComputerID": 6,
          "installedCoreID": 3, "installedInstallID": "i-6", "installedClientSession": "c", "installedServerSession": "s",
          "installedCoreSession": "k", "installedVersion": 13, "installedManifestChecksum": "OLD", "version": 13}


class LiveUpdateStatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = (project.ROOT / "source/library/packages/common/console.lua").read_text(encoding="utf-8")
        match = re.search(r"local function refreshLiveUpdateStatus\(.*?\nend\n", text, re.S)
        cls.function = match.group(0)

    def run_case(self, status, install=None):
        files = {"/installer/status.json": json.dumps(status)}
        lua, files = support.native_runtime(files)
        lua.globals().ENCODE = lambda value: json.dumps(support.python_value(value))
        lua.globals().LOGS = lua.table()
        lua.execute('''
textutils={serializeJSON=function(value) return ENCODE(value) end}
os.__amaryllisLog=function(message) LOGS[#LOGS+1]=message end
''' + self.function + "\nrefreshLiveUpdateStatus_fn=refreshLiveUpdateStatus")
        lua.globals().INSTALL = support.table(lua, install or INSTALL)
        lua.globals().STATUS = support.table(lua, status)
        lua.execute("RESULT=refreshLiveUpdateStatus_fn(INSTALL,STATUS,6)")
        return lua, files, support.python_value(lua.globals().RESULT), len(lua.globals().LOGS)

    def test_lagging_release_fields_are_refreshed_and_stored(self):
        lua, files, result, logs = self.run_case(dict(STATUS))
        self.assertEqual(result["installedManifestChecksum"], "NEW")
        self.assertEqual(json.loads(files["/installer/status.json"])["installedManifestChecksum"], "NEW")
        self.assertNotIn("/installer/status.json.tmp", files)
        self.assertEqual(logs, 1)

    def test_current_status_is_left_alone(self):
        _, files, result, logs = self.run_case(dict(STATUS, installedManifestChecksum="NEW"))
        self.assertEqual(result["installedManifestChecksum"], "NEW")
        self.assertEqual(logs, 0)

    def test_identity_or_recovery_differences_are_never_repaired(self):
        for change in ({"installedComputerID": 7}, {"installedInstallID": "other"}, {"installedCoreSession": "x"},
                       {"installedRole": "core"}, {"recoveryRequired": True}, {"state": "committing"}, {"hasInstalled": False}):
            with self.subTest(change=change):
                status = dict(STATUS, **change)
                _, files, result, logs = self.run_case(status)
                self.assertEqual(result["installedManifestChecksum"], "OLD")
                self.assertEqual(json.loads(files["/installer/status.json"])["installedManifestChecksum"], "OLD")
                self.assertEqual(logs, 0)


class CoreReachabilityTests(unittest.TestCase):
    """Validate auxiliary core-loss transitions independently of actuator services."""

    def runtime(self):
        lua, files = support.native_runtime({})
        lua.execute('''
NOW=100
os.clock=function() return NOW end
os.getComputerID=function() return 6 end
os.getComputerLabel=function() return 'bridge' end
os.queueEvent=function() end
''')
        text = (project.ROOT / 'source/library/packages/common/console.lua').read_text(encoding='utf-8')
        lua.globals().Console = lua.execute(text)
        lua.execute('''
REGISTRY={v=1,kind='fleet_registry',coreID=3,session='core-a',computers={
 core={id=3,label='ama-core'},navigator={id=6,label='bridge'}}}
function accept(sender)
 return Console.acceptRegistry(sender or 3,REGISTRY,'amaryllis.v1','navigator',6,3)
end
''')
        return lua

    def test_validated_core_traffic_times_out_and_recovers_without_touching_runtime(self):
        lua = self.runtime()
        lua.execute('''
assert(Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
assert(Console.connectionState(NOW,'core')==nil)
assert(not accept(9))
assert(Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
assert(accept())
local runtime={running=true,hardwareAvailable=true,faults={'LOCAL FAULT'},snapshot={lift=123}}
local capture={running=true,boot='node'}
local install={role='navigator',coreID=3,label='bridge',packageId='p',version=1}
NOW=110
assert(Console.roleStatus(install,capture,runtime,1).networkState=='CONNECTED')
NOW=110.01
local status=Console.roleStatus(install,capture,runtime,2)
assert(status.networkState=='CORE UNREACHABLE' and status.faultSummary=='CORE UNREACHABLE')
assert(runtime.snapshot.lift==123 and runtime.running and runtime.faults[1]=='LOCAL FAULT')
assert(not accept(9) and Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
REGISTRY.session='core-b';assert(accept())
assert(Console.connectionState(NOW,'navigator')=='CONNECTED')
REGISTRY.session='core-a';assert(not accept())
NOW=121
assert(Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
REGISTRY.session='core-b';assert(accept())
assert(Console.roleStatus(install,capture,runtime,3).faultSummary=='LOCAL FAULT')
''')

    def test_wired_context_freshness_and_local_fault_history(self):
        lua = self.runtime()
        lua.execute('''
os.__amaryllisCoreLink={transport='wired',coreID=3,receivedAt=100,timeout=10}
assert(Console.connectionState(110,'state')=='CONNECTED')
assert(Console.connectionState(111,'state')=='CORE UNREACHABLE')
local previous={saved={source='lift',reason='LOCAL FAULT'}}
local capture={runtimeFaults=previous}
NOW=111
Console._test.observeRuntimeFaults({faultSummary='dependent timeout'},capture,function() error('unexpected log') end)
assert(capture.runtimeFaults==previous)
os.__amaryllisCoreLink.receivedAt=111
assert(Console.connectionState(111,'state')=='CONNECTED')
''')

    def test_every_auxiliary_role_uses_the_same_connection_policy(self):
        lua = self.runtime()
        lua.execute('''
local roles={'navigator','state','heading-left','heading-main','heading-right',
 'chamber_fl','chamber_fr','chamber_bl','chamber_br',
 'primary_l','primary_r','thrust-lb','thrust-rb','thrust-ls','thrust-rs'}
for _,role in ipairs(roles) do
 assert(Console.connectionState(100,role)=='CORE UNREACHABLE',role)
end
assert(accept())
for _,role in ipairs(roles) do
 assert(Console.connectionState(110,role)=='CONNECTED',role)
 assert(Console.connectionState(110.1,role)=='CORE UNREACHABLE',role)
end
assert(not Console.acceptRegistry(3,REGISTRY,'wrong','navigator',6,3))
assert(os.__amaryllisCoreLink.receivedAt==100)
''')

    def test_chamber_child_fault_is_subordinate_to_core_loss(self):
        lua = self.runtime()
        lua.globals().Link = lua.execute((project.ROOT / 'source/library/packages/common/chamber_link.lua').read_text())
        lua.execute('''
os.startTimer=function() return 1 end
os.pullEventRaw=function() return coroutine.yield() end
local relay
parallel={waitForAll=function(first) relay=coroutine.create(first) end}
Link.parent({coreId=3,role='chamber_fl',quadrant='FL',relayChildRole='thrust-lb',label='chamber-fl'})
assert(coroutine.resume(relay))
assert(coroutine.resume(relay,'timer',1))
local child=os.__amaryllisRuntime.components.thrust
assert(child.controlState=='CORE UNREACHABLE' and child.faultSummary=='CORE UNREACHABLE')
assert(#child.faults==1 and child.faults[1]:find('COM UNRESPONSIVE',1,true))
os.__amaryllisCoreLink={receivedAt=NOW,timeout=10}
assert(coroutine.resume(relay,'timer',1))
assert(child.networkState=='CONNECTED' and child.controlState=='FAULT')
assert(child.faultSummary:find('COM UNRESPONSIVE',1,true))
''')


class AutoRebootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = (project.ROOT / "source/library/packages/common/console.lua").read_text(encoding="utf-8")
        cls.function = re.search(r"local function rebootForStatusMismatch\(.*?\nend\n", text, re.S).group(0)

    def lua(self, files):
        lua, files = support.native_runtime(files)
        lua.globals().ENCODE = lambda value: json.dumps(support.python_value(value))
        lua.globals().DECODE = lambda raw: support.table(lua, json.loads(raw))
        lua.execute('''
REBOOTS=0;NOW=1000000000;LOGS={}
textutils={serializeJSON=function(v) return ENCODE(v) end}
os.epoch=function() return NOW end
os.sleep=function() end
os.reboot=function() REBOOTS=REBOOTS+1 end
os.__amaryllisLog=function(m) LOGS[#LOGS+1]=m end
local function readJson(path)
  local h=fs.open(path,"r");if not h then return nil end
  return DECODE(h.readAll())
end
''' + self.function + "\nATTEMPT=rebootForStatusMismatch")
        return lua, files

    def test_two_automatic_reboots_per_hour_then_stops(self):
        lua, files = self.lua({})
        reason = "installed package receipt is not committed"
        results = [lua.eval("ATTEMPT")(reason) for _ in range(4)]
        self.assertEqual(results, [True, True, False, False])
        self.assertEqual(lua.globals().REBOOTS, 2)
        self.assertEqual(json.loads(files["/installer/auto-reboot.json"])["count"], 2)

    def test_counter_resets_after_an_hour(self):
        lua, files = self.lua({})
        reason = "installed package identity does not match its receipt"
        lua.eval("ATTEMPT")(reason); lua.eval("ATTEMPT")(reason)
        lua.execute("NOW=NOW+3600001")
        self.assertTrue(lua.eval("ATTEMPT")(reason))
        self.assertEqual(json.loads(files["/installer/auto-reboot.json"])["count"], 1)

    def test_other_reasons_never_reboot(self):
        lua, files = self.lua({})
        for reason in ("waiting for installed role package", "installed package receipt is invalid or recovery is pending", None):
            self.assertFalse(lua.eval("ATTEMPT")(reason))
        self.assertEqual(lua.globals().REBOOTS, 0)
        self.assertNotIn("/installer/auto-reboot.json", files)


if __name__ == "__main__":
    unittest.main()
