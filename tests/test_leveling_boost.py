"""Large-tilt leveling boost, the tilt warning and RESET LEVELING, run against the current Flight module."""
import json
import unittest

import project
from tests import test_persistence as persistence
from tests import test_persistent_modes as modes
from tests.test_runtime_bundling import table

HARNESS = r'''
local function nodes(heights)
 local result={}
 for _,q in ipairs({"FL","FR","BL","BR"}) do
  result[q]={lastSeen=10,altitude={sensorWorldY=heights[q]},
   providers={probe={controlRole="fine",maxTarget=1000},vent={controlRole="bulk",gasType="steam",maxTarget=2000,minimumNonzeroTarget=1}}}
 end
 return result
end
-- Roll is (FL+BL-FR-BR)/4 blocks: the left side sits `roll` blocks above the right.
function leveled(seconds,roll,boostMax)
 local io,f=setup()
 f.config.level_boost_max=boostMax
 f.systemsRun={phase="READY",airborne=true}
 io.nodes=nodes({FL=160+roll,BL=160+roll,FR=160-roll,BR=160-roll})
 io.nodeFresh=function() return true end
 local baseline={FL={probe=100},FR={probe=100},BL={probe=100},BR={probe=100}}
 local now=10
 for _=1,seconds do
  now=now+1
  for _,q in ipairs({"FL","FR","BL","BR"}) do io.nodes[q].lastSeen=now end
  assert(f:updateTrim(io,baseline,1,1,now))
 end
 return io,f,now
end
'''


class LevelingBoostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        persistence.PersistenceTests.setUpClass()
        cls.config = json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes())

    def run_case(self, body):
        lua = persistence.PersistenceTests().runtime(False)
        lua.globals().CONFIG = table(lua, self.config)
        lua.execute(modes.fixture_source() + "\n" + HARNESS + body)

    def test_large_tilt_builds_steam_leveling_faster(self):
        self.run_case(r"""
local _,plain=leveled(60,2,1)
local _,boosted=leveled(60,2,10)
local a,b=math.abs(plain.coarseSteamTrim.roll),math.abs(boosted.coarseSteamTrim.roll)
assert(a>0 and b>3*a,"boosted "..b.." against plain "..a)
assert(boosted.trimStatus.rollBoost==4,"2 blocks over a 0.5-block start gives 4x: "..tostring(boosted.trimStatus.rollBoost))
assert(boosted.trimStatus.pitchBoost==1,"pitch stays level")
local _,small=leveled(60,0.3,10)
assert(small.trimStatus.rollBoost==1,"tilt inside the start keeps the base rate")
""")

    def test_tilt_warning_after_two_minutes(self):
        self.run_case(r"""
local _,f=leveled(110,2,10)
assert(f.trimStatus.levelingWarning==nil)
_,f=leveled(125,2,10)
assert(f.trimStatus.levelingWarning=="TILT UNCORRECTED 2 MIN: CHECK LOAD OR RESET LEVELING",tostring(f.trimStatus.levelingWarning))
""")

    def test_reset_leveling_returns_to_saved_bias(self):
        self.run_case(r"""
local io,f,now=leveled(60,2,10)
assert(math.abs(f.coarseSteamTrimIntegral.roll)>1)
f.levelBias={roll=5,pitch=-2}
local ok,why=f:resetLeveling(io,now)
assert(ok and why=="LEVELING RESET TO SAVED BIAS",tostring(why))
assert(f.coarseSteamTrimIntegral.roll==5 and f.coarseSteamTrimIntegral.pitch==-2)
assert(f.rollTrim.i==0 and f.pitchTrim.i==0)
local applied=f.coarseSteamTrim.roll
assert(applied~=5,"the applied split moves at the slew rate")
f.levelBias=nil
ok,why=f:resetLeveling(io,now)
assert(ok and why=="LEVELING RESET TO ZERO" and f.coarseSteamTrimIntegral.roll==0)
f.systemsRun.phase="MAIN_LIFT"
ok,why=f:resetLeveling(io,now)
assert(not ok and why=="RESET LEVELING NEEDS START SYSTEMS READY")
""")


if __name__ == "__main__":
    unittest.main()
