"""Web install: core and other computers run web-setup.lua against a built release served as a fake web host."""
from pathlib import Path
import json
import tempfile
import unittest

import project
from tests.test_runtime_bundling import native_runtime, table, python_value
from tests.test_disk_setup import TERMINAL

ROOT = project.ROOT
BASE = "https://raw.githubusercontent.com/ama/release/0123456789abcdef0123456789abcdef01234567/media/"
_TEMP = tempfile.TemporaryDirectory(prefix="web-setup-", dir=ROOT / ".cache")
_RESULT, _ = project.builder_module().build(ROOT, Path(_TEMP.name))
MEDIA = _RESULT / "media"
KEYS = {"one": 2, "two": 3, "three": 4, "r": 19, "u": 22, "y": 21, "n": 49, "q": 16, "up": 200, "down": 208, "enter": 28, "backspace": 14}

ENVIRONMENT = r"""
term.clearLine=function() local x,y=term.getCursorPos();term.setCursorPos(1,y);term.write(string.rep(" ",screen.width));term.setCursorPos(x,y) end
CLOCK=0
os.clock=function() return CLOCK end
os.queueEvent=function() end
local pull=os.pullEvent
os.pullEvent=function(filter)
    while true do
        local e,a,b,c=coroutine.yield("INPUT")
        if e=="terminate" then error("Terminated") end
        if not filter or e==filter then return e,a,b,c end
    end
end
os.reboot=function() REBOOTED=true;while true do coroutine.yield("REBOOT") end end
keys={one=2,two=3,three=4,r=19,u=22,y=21,n=49,q=16,up=200,down=208,enter=28,backspace=14,left=203,right=205,escape=1,numPadEnter=156}
colors={white=1,gray=128,cyan=512,yellow=16,red=16384,lime=32,black=32768}
peripheral={getNames=function() return {"top"} end,getType=function() return "modem" end}
rednet={open=function() end,
    send=function(to,message,protocol) NET_SEND(ID,to,message,protocol);return true end,
    broadcast=function(message,protocol) NET_SEND(ID,nil,message,protocol);return true end,
    receive=function(protocol,timeout)
        local sender,message=coroutine.yield("RECEIVE")
        if sender==nil then CLOCK=CLOCK+(timeout or 1) end
        return sender,message,protocol
    end}
http={get=function(request)
    local url=type(request)=="table" and request.url or request
    local code,data=SERVE(url)
    return {getResponseCode=function() return code end,readAll=function() return data end,close=function() end}
end}
"""


class Computer:
    def __init__(self, network, identity, files=None):
        self.network, self.id = network, identity
        self.lua, self.files = native_runtime(files or {})
        self.inbox, self.requests = [], []
        network[identity] = self
        g = self.lua.globals()
        self.lua.execute(TERMINAL)
        self.lua.execute(ENVIRONMENT)
        g.ID = identity
        g.os.getComputerID = lambda: identity
        self.labels = []
        g.os.setComputerLabel = self.labels.append
        g.os.getComputerLabel = lambda: self.labels[-1] if self.labels else None
        g.print = lambda *a: None
        g.printError = lambda *a: self.errors.append(" ".join(str(x) for x in a))
        self.errors = []
        g.textutils = self.lua.table_from({
            "unserializeJSON": lambda raw: self.decode(raw),
            "serializeJSON": lambda value: json.dumps(python_value(value), sort_keys=True, separators=(",", ":"))})
        g.SERVE = self.serve
        g.NET_SEND = self.send
        original_delete = g.fs.delete
        def delete(path):
            for name in [n for n in self.files if n == path or n.startswith(path.rstrip("/") + "/")]:
                self.files.pop(name)
        g.fs.delete = delete
        source = (MEDIA / "web-setup.lua").read_bytes().decode("utf-8")
        g.SOURCE = source
        self.lua.execute('co=coroutine.create(function(...) assert(load(SOURCE,"=web-setup.lua",nil,_ENV))(...) end)')
        self.state = self.resume(BASE)

    def decode(self, raw):
        try:
            return table(self.lua, json.loads(raw))
        except ValueError:
            return None

    def serve(self, url):
        self.requests.append(url)
        if not url.startswith(BASE):
            return 404, ""
        path = MEDIA / url[len(BASE):]
        return (200, path.read_bytes().decode("utf-8")) if path.is_file() else (404, "")

    def send(self, sender, to, message, protocol):
        value = python_value(message)
        targets = [to] if to is not None else [n for n in self.network if n != sender]
        for target in targets:
            if target in self.network:
                self.network[target].inbox.append((sender, value, protocol))

    def resume(self, *args):
        result = self.lua.eval("function(...) return coroutine.resume(co,...) end")(*args)
        ok, value = (result if isinstance(result, tuple) else (result, None))[:2]
        assert ok, value
        assert not self.errors, self.errors
        return value or "DONE"

    def run(self, timeout=False):
        """Advance until the computer waits for input; a wait for a message times out only when allowed."""
        for _ in range(500):
            if self.state == "RECEIVE":
                if self.inbox:
                    sender, value, _ = self.inbox.pop(0)
                    self.state = self.resume(sender, table(self.lua, value))
                elif timeout:
                    self.state = self.resume(None);timeout = False
                else:
                    return self
            elif self.state == "INPUT" and self.inbox:
                sender, value, protocol = self.inbox.pop(0)
                self.state = self.resume("rednet_message", sender, table(self.lua, value), protocol)
            else:
                return self
        raise AssertionError("computer did not settle")

    def key(self, *names):
        for name in names:
            assert self.state == "INPUT", self.state
            self.state = self.resume("key", KEYS[name])
            settle(self.network)
        return self

    def json(self, path):
        return json.loads(self.files[path])

    def text(self):
        return "\n".join(python_value(self.lua.globals().screen)["rows"])


def settle(network):
    """Deliver messages until every computer is idle; a waiting receive times out only on a quiet network."""
    for _ in range(500):
        busy = False
        for computer in list(network.values()):
            before = (computer.state, len(computer.inbox), computer.lua.globals().CLOCK)
            computer.run()
            busy = busy or (computer.state, len(computer.inbox), computer.lua.globals().CLOCK) != before
        if busy:
            continue
        waiting = [c for c in network.values() if c.state == "RECEIVE"]
        if not waiting:
            return
        for computer in waiting:
            computer.run(timeout=True)
    raise AssertionError("network did not settle")


class WebSetupTests(unittest.TestCase):
    def core(self):
        network = {}
        core = Computer(network, 0)
        core.key("one", "y")
        self.assertIn("1/16 registered", core.text())
        return network, core

    def test_core_installs_from_the_web_and_opens_registration(self):
        _, core = self.core()
        journal = core.json("/amaryllis-install.json")
        self.assertEqual((journal["role"], journal["id"], journal["pending"]), ("core", 0, False))
        self.assertEqual(core.json("/installer/web/source.json")["base"], BASE)
        self.assertIn("/avionics/main.lua", core.files)
        self.assertEqual(core.json("/installer/web/deployment.json")["computers"]["core"]["id"], 0)
        self.assertTrue(all(r.startswith(BASE) for r in core.requests))
        self.assertIn("/installer/web/web-setup.lua", core.files["/startup.lua"], "core boots into registration until import")
        self.assertIn("/installer/web/core-startup.lua", core.files)

    def test_computer_finds_core_registers_and_installs_its_receiver(self):
        network, core = self.core()
        node = Computer(network, 5)
        node.key("two")
        settle(network)
        self.assertIn("REGISTER #5 WITH CORE #0", node.text())
        node.key("enter", "y")  # first role in the list
        first = json.loads((MEDIA / "release.json").read_text())["roleOrder"][0]
        self.assertIn("Registered as " + first, node.text())
        node.key("enter")
        self.assertTrue(node.lua.globals().REBOOTED)
        self.assertEqual(core.json("/installer/web/deployment.json")["computers"][first]["id"], 5)
        self.assertEqual(node.json("/config.json")["core_id"], 0)
        self.assertEqual(node.json("/amaryllis-install.json")["role"], first)
        self.assertIn("/installer.lua", node.files)
        self.assertFalse(any(p.startswith("/amaryllis-web") for p in node.files))
        self.assertIn("#5 registered as " + first, core.text())

    def test_taken_role_is_refused_on_the_computer(self):
        network, core = self.core()
        Computer(network, 5).key("two").key("enter", "y", "enter")
        other = Computer(network, 6)
        other.key("two", "enter")
        self.assertIn("Role taken", other.text())

    def test_registered_computer_moves_to_another_role_before_import(self):
        network, core = self.core()
        order = json.loads((MEDIA / "release.json").read_text())["roleOrder"]
        first = Computer(network, 5).key("two").key("enter", "y", "enter")
        again = Computer(network, 5, dict(first.files))
        again.key("two", "down", "enter", "y")
        self.assertIn("Role changed", again.text())
        computers = core.json("/installer/web/deployment.json")["computers"]
        self.assertNotIn(order[0], computers)
        self.assertEqual(computers[order[1]]["id"], 5)
        self.assertEqual(again.json("/amaryllis-install.json")["role"], order[1])

    def test_core_imports_once_every_role_is_registered(self):
        network, core = self.core()
        order = json.loads((MEDIA / "release.json").read_text())["roleOrder"]
        for number, _ in enumerate(order):
            Computer(network, 10 + number).key("two").key(*(["down"] * number), "enter", "y", "enter")
        self.assertIn("16/16 registered", core.text())
        core.key("enter", "y")
        self.assertIn("Assignments imported", core.text())
        core.key("enter")
        self.assertTrue(core.lua.globals().REBOOTED)
        self.assertNotIn("web-setup", core.files["/startup.lua"], "core's own startup is back after import")
        self.assertNotIn("/installer/web/core-startup.lua", core.files)
        fleet = core.json("/fleet.json")["computers"]
        self.assertEqual({r: fleet[r]["id"] for r in order}, {r: 10 + n for n, r in enumerate(order)})

    def test_core_rerun_continues_registration_on_its_pinned_release(self):
        network, core = self.core()
        again = Computer({}, 0, dict(core.files))
        self.assertIn("1/16 registered", again.text())


class WebUndoTests(unittest.TestCase):
    def registered(self):
        network = {}
        core = Computer(network, 0).key("one", "y")
        order = json.loads((MEDIA / "release.json").read_text())["roleOrder"]
        nodes = [Computer(network, 10 + n).key("two").key(*(["down"] * n), "enter", "y", "enter") for n in range(len(order))]
        return network, core, nodes, order

    def test_reset_after_import_clears_assignments_and_computers_keep_their_programs(self):
        network, core, nodes, order = self.registered()
        core.key("enter", "y", "enter")
        rerun = Computer(network, 0, dict(core.files))
        rerun.key("r", "y")
        self.assertIn("Resetting installation", rerun.text())
        rerun.key("enter")
        self.assertIn("web-setup", rerun.files["/startup.lua"], "core restarts into registration")
        network.pop(0)
        booted = Computer(network, 0, dict(rerun.files))
        state = booted.json("/installer/web/deployment.json")
        self.assertEqual(list(state["computers"]), ["core"])
        self.assertEqual(state["reset"]["previous"][order[0]]["id"], 10)
        self.assertNotIn("/installer/web/reset-pending.json", booted.files)
        again = Computer(network, 10, dict(nodes[0].files))
        again.key("two", "enter", "y")
        self.assertIn("Existing programs and settings kept", again.text())
        self.assertEqual(booted.json("/installer/web/deployment.json")["computers"][order[0]]["id"], 10)

    def test_uninstall_core_before_import_removes_its_files(self):
        network = {}
        core = Computer(network, 0).key("one", "y", "u", "y")
        self.assertIn("Core uninstalled", core.text())
        self.assertEqual([p for p in core.files if not p.startswith("/rom")], [])

    def test_uninstall_is_refused_after_import(self):
        network, core, _, _ = self.registered()
        core.key("enter", "y", "enter")
        rerun = Computer(network, 0, dict(core.files)).key("u")
        self.assertIn("Reset installation (R) before uninstalling core", rerun.text())
        self.assertIn("/avionics/main.lua", rerun.files)

    def test_computer_removes_its_registration_and_core_clears_the_role(self):
        network, core = {}, None
        core = Computer(network, 0).key("one", "y")
        node = Computer(network, 5).key("two").key("enter", "y", "enter")
        first = json.loads((MEDIA / "release.json").read_text())["roleOrder"][0]
        network.pop(5)
        rerun = Computer(network, 5, dict(node.files))
        self.assertIn("3  Remove this computer's registration (" + first + ")", rerun.text())
        rerun.key("three", "y")
        self.assertIn("Registration removed", rerun.text())
        self.assertFalse(any(p in rerun.files for p in ("/startup.lua", "/config.json", "/amaryllis-install.json", "/installer.lua")))
        self.assertNotIn(first, core.json("/installer/web/deployment.json")["computers"])

    def test_state_reader_registration_can_be_removed(self):
        network = {}
        core = Computer(network, 0).key("one", "y")
        order = json.loads((MEDIA / "release.json").read_text())["roleOrder"]
        state = Computer(network, 7).key("two").key(*(["down"] * order.index("state")), "enter", "y", "enter")
        self.assertIn("/avionics/config.json", state.files)
        network.pop(7)
        rerun = Computer(network, 7, dict(state.files)).key("three", "y")
        self.assertFalse(any(p.startswith("/avionics") for p in rerun.files))
        self.assertNotIn("state", core.json("/installer/web/deployment.json")["computers"])


class CoreWebMediaTests(unittest.TestCase):
    def test_core_serves_packages_from_its_web_release(self):
        lua, files = native_runtime({
            "/installer/library.json": (MEDIA / "library.json").read_bytes().decode("utf-8"),
            "/installer/web/source.json": json.dumps({"base": BASE}),
        })
        catalog = json.loads((MEDIA / "library.json").read_text())
        entry = catalog["files"][0]
        served = []
        def get(request):
            url = request["url"]
            served.append(url)
            data = (MEDIA / url[len(BASE):]).read_bytes().decode("utf-8")
            return lua.table_from({"getResponseCode": lambda: 200, "readAll": lambda: data, "close": lambda: None})
        lua.globals().HTTP = lua.table_from({"get": get})
        lua.globals().SOURCE = (ROOT / "disk-builder/assets/core-media.lua").read_text(encoding="utf-8")
        lua.globals().JSON = lua.table_from({"unserializeJSON": lambda raw: table(lua, json.loads(raw))})
        data = lua.execute(r'''
local Media=assert(load(SOURCE))()
local media=Media.new(fs,{getNames=function() return {} end},{},JSON,function() end,HTTP)
assert(media:refresh(),"web media is available")
local h=assert(media.fs.open(...,"r"))
return h.readAll()
''', entry["path"])
        self.assertEqual(data, (MEDIA / ("objects/" + entry["object"])).read_bytes().decode("utf-8"))
        self.assertEqual(served, [BASE + "objects/" + entry["object"]])


if __name__ == "__main__":
    unittest.main()
