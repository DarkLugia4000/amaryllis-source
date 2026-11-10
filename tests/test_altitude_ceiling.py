"""Altitude ceiling: the selector, restored targets and AP destinations stay at or below it."""
import unittest
from tests.test_persistent_modes import runtime, fixture_source

TESTS = {
'selector_stops_at_ceiling': r'''
local io,f,p,clock=setup()
local c=f.controls
check(io.config.altitude_control.altitude_ceiling==280,"shipped ceiling is Y 280")
c.targets.altitude=279.5
for i=1,40 do sample(io,clock,10+i*.25,{"altitude_up",15});c:update(io,10+i*.25) end
check(c.targets.altitude==280,"held ALT UP stops at the ceiling: "..tostring(c.targets.altitude))
''',
'target_above_ceiling_is_lowered': r'''
local io,f,p,clock=setup()
local c=f.controls
c.targets.altitude=300;sample(io,clock,11);c:update(io,11)
check(c.targets.altitude==280,"a target above the ceiling is lowered to it")
io.config.altitude_control.altitude_ceiling=250;sample(io,clock,12);c:update(io,12)
check(c.targets.altitude==250,"lowering the ceiling lowers the target")
io.config.altitude_control.altitude_ceiling=400;c.targets.altitude=330;sample(io,clock,13);c:update(io,13)
check(c.targets.altitude==330,"a ceiling above 314 allows higher targets")
''',
'ap_destination_capped': r'''
local io,f,p,clock=setup()
local ap=f:ensureAutopilot(io)
local ok,why=ap:edit(io,f.controls,{type="ap_edit",key="altitude",value=300},10)
check(ok,why);check(ap.draft.altitude==280,"destination altitude above the ceiling is set to it")
''',
'setting_and_validation': r'''
local Flight=require("avionics.flight")
local found
for _,field in ipairs(Flight._settingsFields) do if field.key=="altitude_ceiling" then found=field end end
check(found and found.group=="ALT PID","ceiling is edited on the ALT PID / LIMITS page")
local floor,maximum
for _,field in ipairs(Flight._settingsFields) do
  if field.key=="minimum_world_y" then floor=field end
  if field.key=="maximum_world_y" then maximum=field end
end
check(floor and floor.group=="ALT PID","Minimum target Y is on the ALT PID / LIMITS page")
check(maximum==nil,"Maximum target Y is no longer a setting")
local Storage=require("avionics.storage")
local config=clone(CONFIG);config.altitude_control.altitude_ceiling=config.altitude_control.minimum_world_y
local ok=Storage.validateConfig(config);check(not ok,"a ceiling at the minimum target Y is refused")
config.altitude_control.altitude_ceiling=280;ok=Storage.validateConfig(config);check(ok,"the shipped ceiling validates")
''',
}


class AltitudeCeilingTests(unittest.TestCase):
    """Each TESTS case runs on its own against the current control modules."""


for _name, _case in TESTS.items():
    def _run(self, case=_case):
        count = runtime().execute(fixture_source() + '\n' + case + '\nreturn checks')
        self.assertGreater(count, 0)
    setattr(AltitudeCeilingTests, 'test_' + _name, _run)

if __name__ == '__main__':
    unittest.main(verbosity=2)


class AltitudeTapeCeilingTests(unittest.TestCase):
    """The heading display's altitude tape leaves levels above core's ceiling blank."""

    def test_tape_blank_above_ceiling(self):
        import project
        from tests import test_runtime_bundling as support
        text = (project.ROOT / "source/library/packages/common/heading-main.lua").read_text(encoding="utf-8")
        start = text.index("local function finite(value)")
        end = text.index("-- Summary: Build and flush the selected cached display view.")
        lua, _ = support.native_runtime()
        rows = lua.execute("local timeout,pollInterval=2,0.25\nlocal config={}\n" + text[start:end] + r'''
local function tape(ceiling)
 local snap={vessel={valid=true,heading=90,forwardSpeed=2,altitude=277.9,verticalSpeed=0},
  targets={heading=90,speed=3,altitude=280},modes={heading='SEL',throttle='SEL'},
  altitudeControl={enabled=true,ceiling=ceiling}}
 local s=drawCenter(snap,57,12);local out={}
 for y=1,12 do out[#out+1]=table.concat(s.rows[y].chars) end
 return table.concat(out,"\n")
end
return tape(280).."\n#\n"..tape(nil)''')
        capped, uncapped = rows.split("\n#\n")
        self.assertIn("280", capped)
        self.assertNotIn("290", capped)
        self.assertNotIn("300", capped)
        self.assertIn("300", uncapped, "without a ceiling from core the tape shows every level")
