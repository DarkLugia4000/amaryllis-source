"""The bridge request line names AP's request while AP is engaged."""
import re
import unittest

import project
from tests import test_runtime_bundling as support

STUBS = r'''
local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
local function thrustSnapshot(s) return s.thrust end
local function staleLabel(t) return t end
local function propulsionMode(s,t) return t.mode end
local function numberText(v,d,signed) return (signed and v>=0 and "+" or "")..string.format("%."..d.."f",v) end
local function speedTarget(s,t) return t.target end
local function propulsionInputPercent() return nil end
'''


class APRequestLabelTests(unittest.TestCase):
    def test_labels(self):
        text = (project.ROOT / "source/library/packages/navigation/ui.lua").read_text(encoding="utf-8")
        function = re.search(r"local function propulsionRequestText\(.*?\nend\n", text, re.S).group(0)
        lua, _ = support.native_runtime()
        lua.execute(STUBS + function + r'''
local settings={thrust={directRpmVerified=true}}
local function line(mode,ap) return (propulsionRequestText({autopilot={active=ap},settings=settings,
    thrust={mode=mode,target=4.5,request={directRpm=0}}},true)) end
assert(line("SEL",true)=="AP TARGET +4.50 b/s",line("SEL",true))
assert(line("SEL",false)=="SEL TARGET +4.50 b/s")
assert(line("DIRECT",true)=="AP RPM +0",line("DIRECT",true))
assert(line("DIRECT",false)=="REQ RPM +0")
''')


if __name__ == "__main__":
    unittest.main()
