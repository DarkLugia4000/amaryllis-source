"""Front and back strafe balance: mixer scaling, registry clamp and shipped setting."""
import json
import sys
import unittest

import project

sys.path.insert(0, str(project.ROOT / "tools"))
import config_registry as registry_tool  # noqa: E402

# Shared Lua prelude: a verified mixer with every group at full sideways gain,
# matching the copy that route and anchor authority build before balancing.
PRELUDE = r"""
local Thrust=require('avionics.thrust')
local Registry=require('avionics.config_registry')
local function mixer()
    local out={}
    for _,quad in ipairs({'lb','rb','ls','rs'}) do
        out[quad]={side_gain=1,side_sign=-1,yaw_gain=1,yaw_sign=(quad=='lb' or quad=='rb') and 1 or -1}
    end
    return out
end
local function near(a,b) return math.abs(a-b)<1e-9 end
"""


class StrafeBalanceTests(unittest.TestCase):
    def run_lua(self, body):
        lua = registry_tool.runtime()
        lua.execute(PRELUDE + body)

    def test_hundred_percent_leaves_all_groups_equal(self):
        self.run_lua(r"""
            local balanced=Thrust.balanceStrafe(mixer(),100)
            for _,quad in ipairs({'lb','rb','ls','rs'}) do assert(near(balanced[quad].side_gain,1),quad) end
        """)

    def test_below_hundred_reduces_only_the_front_pair(self):
        self.run_lua(r"""
            local balanced=Thrust.balanceStrafe(mixer(),60)
            for _,quad in ipairs({'lb','rb'}) do assert(near(balanced[quad].side_gain,0.6),quad) end
            for _,quad in ipairs({'ls','rs'}) do assert(near(balanced[quad].side_gain,1),quad) end
        """)

    def test_above_hundred_reduces_the_back_pair_and_stays_within_range(self):
        self.run_lua(r"""
            local balanced=Thrust.balanceStrafe(mixer(),150)
            for _,quad in ipairs({'lb','rb'}) do assert(near(balanced[quad].side_gain,1),quad) end
            for _,quad in ipairs({'ls','rs'}) do
                assert(near(balanced[quad].side_gain,1/1.5),quad)
                assert(balanced[quad].side_gain<=1)
            end
        """)

    def test_balance_leaves_yaw_gains_and_the_source_mixer_unchanged(self):
        self.run_lua(r"""
            local source=mixer()
            local balanced=Thrust.balanceStrafe(source,60)
            for _,quad in ipairs({'lb','rb','ls','rs'}) do
                assert(balanced[quad].yaw_gain==1 and balanced[quad].yaw_sign==source[quad].yaw_sign)
                assert(source[quad].side_gain==1,'configured mixer must not be modified')
            end
        """)

    def test_balanced_mixer_scales_front_strafe_output(self):
        self.run_lua(r"""
            local equal=Thrust.mixLateral(1,0,Thrust.balanceStrafe(mixer(),100))
            local reduced=Thrust.mixLateral(1,0,Thrust.balanceStrafe(mixer(),60))
            assert(near(equal['lateral-lb-s'],1) and near(equal['lateral-rb-s'],1))
            assert(near(reduced['lateral-lb-s'],0.6) and near(reduced['lateral-rb-s'],0.6))
            for _,drive in ipairs({'lateral-ls-s','lateral-rs-s'}) do
                assert(near(reduced[drive],1),drive)
            end
        """)

    def test_invalid_input_returns_the_mixer_unchanged(self):
        self.run_lua(r"""
            local source=mixer()
            assert(Thrust.balanceStrafe(source,0)==source)
            assert(Thrust.balanceStrafe(source,0/0)==source)
            assert(Thrust.balanceStrafe(nil,100)==nil)
        """)

    def test_registry_supplies_fallback_and_clamps(self):
        self.run_lua(r"""
            local id='thrust.front_back_strafe_percent'
            assert(Registry.number({},id)==100)
            assert(Registry.number({front_back_strafe_percent=80},id)==80)
            assert(Registry.number({front_back_strafe_percent=500},id)==150)
            assert(Registry.number({front_back_strafe_percent=1},id)==50)
        """)

    def test_shipped_value_is_equal_balance(self):
        config = json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes())
        self.assertEqual(config["thrust"]["front_back_strafe_percent"], 100)
        self.assertNotIn("front_left_strafe_percent", config["thrust"])


    def test_strafe_settings_live_under_cockpit_inputs(self):
        """The four cockpit strafe settings form the STRAFE SETTINGS group; page 2 keeps only the system buttons."""
        import re
        source = (project.ROOT / "source/core/avionics/flight.lua").read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r'field\("STRAFE SETTINGS"', source)), 4)
        self.assertNotIn('field("LATERAL"', source)
        ui = (project.ROOT / "source/library/packages/navigation/ui.lua").read_text(encoding="utf-8")
        self.assertNotIn('entry.group=="LATERAL"', ui)


if __name__ == "__main__":
    unittest.main()
