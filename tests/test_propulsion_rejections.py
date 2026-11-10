"""The core records why it refused a propulsion hello or status instead of dropping it silently."""
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


if __name__ == "__main__":
    unittest.main()
