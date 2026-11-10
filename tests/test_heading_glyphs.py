"""Heading display text: single-cell delta and degree glyphs, and the ANCHORED bottom-left label."""
import re
import unittest

import project
from tests import test_runtime_bundling as support

PATH = "source/library/packages/common/heading-main.lua"


class HeadingGlyphTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (project.ROOT / PATH).read_text(encoding="utf-8")

    def section(self):
        start = self.text.index("local GLYPH = {")
        end = self.text.index("\nend\n", self.text.index("function GLYPH.width")) + 5
        put_start = self.text.index("local function put(")
        put_end = self.text.index("\n-- Summary: Wrap message words", put_start)
        return self.text[start:end] + self.text[put_start:put_end] + "\n"

    def run_lua(self, body):
        lua, _ = support.native_runtime()
        lua.execute("local function color(name) return name end\n" + self.section() + body)

    def test_glyphs_are_single_cells_and_other_text_is_replaced(self):
        self.run_lua(r'''
local readout="HDG "..GLYPH.DELTA.." ".."+12.5"..GLYPH.DEGREE
assert(GLYPH.width(readout)==12,GLYPH.width(readout))
local cells=GLYPH.cells(readout)
assert(cells[5]=="\206\148" and cells[12]=="\194\176")
assert(safeText("A\226\134\146B\7")=="A?B?","other characters each become one ?: "..safeText("A\226\134\146B\7"))
local surface={width=13,height=1,rows={{chars={},fg={},bg={}}}}
for x=1,13 do surface.rows[1].chars[x]=" " end
put(surface,13-GLYPH.width(readout)+1,1,readout,"white")
assert(table.concat(surface.rows[1].chars)==" "..readout,"right-aligned by cells")
''')

    def test_heading_readout_and_plain_row_fallback(self):
        self.assertIn('"HDG "..GLYPH.DELTA.." "..shown(shortestDelta(current,target),1,true)..GLYPH.DEGREE', self.text)
        self.assertNotIn('"RATE "', self.text, "the manual-heading yaw-rate readout is removed")
        self.assertIn("put(surface,width-GLYPH.width(readout)+1,2,readout", self.text)
        self.assertNotIn('"ERROR "', self.text)
        self.assertIn('type(displayObject.monitor.blit) == "function" and #text == surface.width', self.text)


class HeadingAnchorLabelTests(unittest.TestCase):
    def test_anchor_owns_the_bottom_left_until_released(self):
        text = (project.ROOT / PATH).read_text(encoding="utf-8")
        start = text.index("local function finite(value)")
        end = text.index("-- Summary: Build and flush the selected cached display view.")
        lua, _ = support.native_runtime()
        lua.execute("local timeout,pollInterval=2,0.25\nlocal config={}\n" + text[start:end] + r'''
local function bottom(anchor,ap)
 local snap={vessel={valid=true,heading=90,forwardSpeed=2,altitude=160,verticalSpeed=0},
  targets={heading=90,speed=3,altitude=160},modes={heading='SEL',throttle='SEL'},anchor=anchor,autopilot=ap}
 local s=drawHorizontalHeading(snap,57,10)
 return table.concat(s.rows[10].chars,"",1,20),s.rows[10].fg[1]
end
local label,tone=bottom('ANCHORED')
assert(label:match("^ANCHORED ") and tone==color("yellow"),label)
label,tone=bottom('BRAKING',{active=true,state='CRUISE',cruiseSpeed=3,distance=40,crossTrack=0})
assert(label:match("^ANCHORED ") and tone==color("yellow"),"supersedes REQ and DIST: "..label)
label=bottom('OFF');assert(label:match("^REQ 3.0 b/s"),label)
''')


class HeadingDestinationNameTests(unittest.TestCase):
    def test_long_destination_names_end_in_two_dots(self):
        text = (project.ROOT / PATH).read_text(encoding="utf-8")
        start = text.index("local function finite(value)")
        end = text.index("-- Summary: Build and flush the selected cached display view.")
        lua, _ = support.native_runtime()
        lua.execute("local timeout,pollInterval=2,0.25\nlocal config={}\n" + text[start:end] + r'''
local function top(name,width)
 local snap={vessel={valid=true,heading=90,forwardSpeed=2,altitude=160,verticalSpeed=0},targets={heading=90,speed=3,altitude=160},
  modes={heading='SEL',throttle='SEL'},anchor='OFF',autopilot={active=true,state='CRUISE',destinationName=name,cruiseSpeed=3,distance=40,crossTrack=0}}
 return table.concat(drawHorizontalHeading(snap,width,10).rows[1].chars)
end
local row=top("3000000, -3000000",30)
assert(row:find(" 3000000.. ",1,true),"a long name keeps its start and ends in two dots: "..row)
row=top("12, 34",30)
assert(row:find(" 12, 34 ",1,true),"a short name is shown whole: "..row)
''')


if __name__ == "__main__":
    unittest.main()
