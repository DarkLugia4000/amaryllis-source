"""Stale data is named with its age once it has been stale for more than 10 s."""
import re
import unittest

import project
from tests import test_runtime_bundling as support

FINITE = "local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end\n"


def extract(path, name):
    text = (project.ROOT / path).read_text(encoding="utf-8")
    return re.search(r"function " + re.escape(name) + r"\(.*?\nend\n", text, re.S).group(0), text


class StaleStatusTextTests(unittest.TestCase):
    def lua(self, prefix, function, body):
        lua, _ = support.native_runtime()
        lua.execute(prefix + FINITE + function + body)

    def test_silent_chamber_is_named_after_ten_seconds_with_its_age(self):
        function, text = extract("source/core/avionics/io.lua", "IO:staleStatusText")
        self.lua("IO={STALE_NOTICE_SECONDS=10}\n", function, r'''
local io={}
assert(IO.staleStatusText(io,"FL",8,100)==nil,"no fault inside 10 s")
assert(IO.staleStatusText(io,"FL",12.4,100)=="CHAMBER FL SILENT 12 S; CHECK POWER AND LINK")
''')
        self.assertIn("{ self:staleStatusText(quadrant, age, now) }", text)
        self.assertNotIn('"STALE STATUS"', text)
        self.assertNotIn('" LIFT STATUS STALE"', text)

    def test_chamber_unheard_since_core_start_counts_from_first_snapshot(self):
        function, _ = extract("source/core/avionics/io.lua", "IO:staleStatusText")
        self.lua("IO={STALE_NOTICE_SECONDS=10}\n", function, r'''
local io={}
assert(IO.staleStatusText(io,"BR",nil,50)==nil)
assert(IO.staleStatusText(io,"BR",nil,58)==nil)
assert(IO.staleStatusText(io,"BR",nil,62)=="CHAMBER BR SILENT SINCE CORE START (12 S); CHECK POWER AND LINK")
assert(IO.staleStatusText(io,"BR",1,63)==nil and io.silentSince.BR==nil,"a fresh status resets the count")
''')

    def test_propulsion_roles_are_named_with_age(self):
        function, text = extract("source/core/avionics/thrust.lua", "Thrust.staleText")
        self.lua("Thrust={STALE_NOTICE_SECONDS=10}\n", function, r'''
assert(Thrust.staleText("THRUST-LB","STATUS",6)=="WAITING FOR THRUST-LB STATUS")
assert(Thrust.staleText("THRUST-LB","STATUS",14.2)=="THRUST-LB STATUS STALE 14 S")
assert(Thrust.staleText("PRIMARY-LEFT","READBACK",nil)=="PRIMARY-LEFT READBACK UNAVAILABLE")
''')
        for old in ('"STATUS STALE"', '"NO STATUS"', '"CONTROLLER STATUS STALE"', '"CONTROLLER READBACK STALE"'):
            self.assertNotIn(old, text)

    def test_navigator_stale_labels_wait_ten_seconds(self):
        text = (project.ROOT / "source/library/packages/navigation/ui.lua").read_text(encoding="utf-8")
        start = text.index("local STALE_NOTICE_SECONDS")
        end = text.index("\nend\n", start) + 5
        lua, _ = support.native_runtime()
        lua.execute(FINITE + text[start:end].replace("local displayAge = nil", "displayAge = nil") + r'''
displayAge=4
local label,tone=staleLabel("HDG STATUS");assert(label=="WAITING FOR CORE" and tone=="yellow")
displayAge=12.6
label,tone=staleLabel("HDG STATUS");assert(label=="CORE UNREACHABLE 13 S" and tone=="yellow",label)
''')
        for old in ('"COCKPIT STALE"', '"HDG STATUS STALE"', '"THRUST STATUS STALE"', '"FAULT STATUS STALE"'):
            self.assertNotIn(old, text)
        self.assertIn("displayAge = snapshot.displayAgeSeconds", text)


if __name__ == "__main__":
    unittest.main()
