"""Thrust endpoint readback age while commands arrive during a controller pass."""
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


if __name__ == "__main__":
    unittest.main()
