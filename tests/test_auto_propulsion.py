"""START SYSTEMS enables propulsion by itself once the altitude hold has stayed settled."""
import re
import unittest

import project
from tests import test_runtime_bundling as support


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
    unittest.main()
