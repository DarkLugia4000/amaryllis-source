"""Propulsion stops with a message that says how long the core supervisor has been silent."""
import unittest

import project
from tests import test_runtime_bundling as support


class SupervisionTextTests(unittest.TestCase):
    def worker(self):
        lua, _ = support.native_runtime()
        source = (project.ROOT / "source/core/avionics/propulsion_worker.lua").read_text(encoding="utf-8")
        lua.execute("W=(function()\n" + source + "\nend)()")
        return lua

    def test_messages_name_the_cause(self):
        lua = self.worker()
        lua.execute('''
assert(W.supervisionText(10,nil)=="CORE SUPERVISION NEVER REPORTED; CHECK CORE")
assert(W.supervisionText(10,12)=="CORE SUPERVISION CLOCK WENT BACKWARDS; CHECK CORE")
assert(W.supervisionText(15,10)=="WAITING FOR CORE SUPERVISION")
assert(W.supervisionText(22.4,10)=="CORE SUPERVISION SILENT 12 S; SERVER LAG OR CORE STALL")
''')

    def test_step_stops_propulsion_with_that_text(self):
        lua = self.worker()
        lua.execute('''
local reason
local io={thrust={stop=function(self,io,r) reason=r end}}
W.step(io,{},22,10)
assert(reason=="CORE SUPERVISION SILENT 12 S; SERVER LAG OR CORE STALL",reason)
reason=nil;W.step(io,{},20,nil)
assert(reason=="CORE SUPERVISION NEVER REPORTED; CHECK CORE",reason)
''')


if __name__ == "__main__":
    unittest.main()
