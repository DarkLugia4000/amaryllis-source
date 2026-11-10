"""A vent without a balloon points at the boiler when the trim probe still sees one."""
import re
import unittest

import project
from tests import test_runtime_bundling as support


class VentBalloonHintTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = (project.ROOT / "source/core/avionics/flight.lua").read_text(encoding="utf-8")
        cls.function = re.search(r"function Flight:ventBalloonIssue\(.*?\nend\n", text, re.S).group(0)
        cls.text = text

    def run_case(self, body):
        lua, _ = support.native_runtime()
        lua.execute("Flight={}\n" + self.function + body)

    def test_probe_sees_balloon_points_at_boiler(self):
        self.run_case('''
local n={balloon={source="probe",hasBalloonValid=true,hasBalloon=true},providers={probe={controlRole="fine"}}}
local text=Flight:ventBalloonIssue(n,"BR","vent3")
assert(text=="BR VENT vent3 FAIL; CHECK BOILER",text)
''')

    def test_no_attached_balloon_comes_only_from_the_probe(self):
        self.run_case('''
local n={balloon={source="probe",hasBalloonValid=true,hasBalloon=false},providers={probe={controlRole="fine"},vent3={gasOutputValid=true,attached=false}}}
assert(Flight:ventBalloonIssue(n,"BR","vent3")=="BR PROBE FAIL: CHECK BALLOON INTEGRITY")
''')

    def test_unconfirmed_vent_faults_resolve_to_the_boiler(self):
        self.run_case('''
local noLift={balloon={source="probe",hasBalloonValid=false},providers={probe={controlRole="fine"},vent3={gasOutputValid=false}}}
assert(Flight:ventBalloonIssue(noLift,"BR","vent3")=="BR VENT vent3 LIFT FAIL; CHECK BOILER")
local ventSource={balloon={source="vent1",hasBalloonValid=true,hasBalloon=false},providers={vent1={controlRole="bulk",gasOutputValid=true}}}
local text=Flight:ventBalloonIssue(ventSource,"BR","vent1")
assert(text=="CHAMBER BR UNCONFIRMED; CHECK PROBE; CHECK BOILER",text)
assert(Flight:ventBalloonIssue({},"BR","vent3")=="CHAMBER BR UNCONFIRMED; CHECK PROBE; CHECK BOILER")
''')

    def test_both_vent_checks_use_the_hint(self):
        self.assertEqual(self.text.count("self:ventBalloonIssue(n,q,name)"), 1)
        self.assertEqual(self.text.count('q.." PROBE FAIL: CHECK BALLOON INTEGRITY"'), 2)
        self.assertIn("self:ventBalloonIssue(n,q,source)", self.text)


class ChamberProviderFaultTests(unittest.TestCase):
    """The chamber computers word vent and probe faults the same way as the core."""

    def test_hardware_wording(self):
        for name in ("chamber-hardware.lua", "thrust-hardware.lua"):
            text = (project.ROOT / "source/library/packages/common" / name).read_text(encoding="utf-8")
            self.assertIn('" LIFT FAIL; CHECK BOILER"', text)
            self.assertIn('" FAIL: CHECK BALLOON INTEGRITY"', text)
            self.assertIn('"BULK VENTS GIVE NO BALLOON READING; CHECK BOILER"', text)
            self.assertNotIn("balloon attachment is not verified\",not probeActive", text)

    def test_parser_keeps_vent_faults_as_worded(self):
        text = (project.ROOT / "source/library/packages/common/chamber-lift.lua").read_text(encoding="utf-8")
        function = re.search(r"local function addProviderFaults\(.*?\nend\n", text, re.S).group(0)
        lua, _ = support.native_runtime()
        lua.execute("local function addFault(list,f) list[#list+1]=f end\n" + function.replace("local function addProviderFaults", "function addProviderFaults") + '''
local snap={faults={"VENT v1 LIFT FAIL; CHECK BOILER","PROVIDER_UNREADY:v2"},
  providers={v1={error="provider is inactive; provider reports no attached balloon"},v2={error="missing getGasOutput"}}}
local out={};addProviderFaults(out,snap,{})
assert(out[1]=="VENT v1 LIFT FAIL; CHECK BOILER",out[1])
assert(out[2]=="PROVIDER_UNREADY:v2 | missing getGasOutput",out[2])
out={};addProviderFaults(out,snap,{v1=true});assert(#out==1,"suppressed vent is skipped")
''')


class NavigatorAndKillCheckTests(unittest.TestCase):
    def test_boiler_checks_are_yellow_on_the_navigator(self):
        text = (project.ROOT / "source/library/packages/navigation/ui.lua").read_text(encoding="utf-8")
        self.assertIn('tostring(fault):find("CHECK BOILER",1,true) then return "yellow" end', text)
        self.assertIn('faultTone = tostring(faults[1]):find("CHECK BOILER",1,true) and "yellow" or "red"', text)
        self.assertIn('tostring(fault),reportedTone(fault),"core")', text)
        self.assertIn("tostring(fault),reportedTone(fault),source)", text)

    def test_kill_check_follows_the_probe_rule(self):
        text = (project.ROOT / "source/core/avionics/io.lua").read_text(encoding="utf-8")
        function = re.search(r"function IO:emergencyLiftStopStateVerified\(.*?\nend\n", text, re.S).group(0)
        self.assertNotIn("ATTACHED BALLOON STATUS NOT VERIFIED", function)
        self.assertNotIn("FINE PROBE ATTACHMENT NOT VERIFIED", function)
        lua, _ = support.native_runtime()
        lua.execute("IO={}\nlocal function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end\n"
                    "local function integer(v,a,b) return type(v)=='number' and v%1==0 and v>=a and v<=b end\n"
                    "local function text(v) return tostring(v) end\nlocal function steamCount() return 1 end\n" + function + '''
local function make(source,hasBalloon,probeAttached)
  local node={boot="b",emergencyStopMode="BULK_OFF_PROBE_ON",emergencyStopLatched=true,emergencyStopVerified=true,armed=false,
    balloon={source=source,hasBalloonValid=true,hasBalloon=hasBalloon,gasMixValid=true,liftValid=true,lift=1},
    providers={vent={present=true,targetValid=true,targetAmount=0,signalValid=true,signalStrength=0,controlRole="bulk"},
      probe={present=true,targetValid=true,targetAmount=5,minimumNonzeroTarget=5,signalValid=true,signalStrength=15,
        controlRole="fine",attachedValid=true,attached=probeAttached}}}
  return {nodes={FR=node},nodeFresh=function() return true end}
end
local ok,why=IO.emergencyLiftStopStateVerified(make("vent",false,true),"FR","b",0)
assert(why~="FR PROBE FAIL: CHECK BALLOON INTEGRITY" and not tostring(why):find("UNCONFIRMED",1,true),"a vent reading is not decisive: "..tostring(why))
ok,why=IO.emergencyLiftStopStateVerified(make("probe",false,true),"FR","b",0)
assert(why=="FR PROBE FAIL: CHECK BALLOON INTEGRITY",tostring(why))
ok,why=IO.emergencyLiftStopStateVerified(make("vent",true,false),"FR","b",0)
assert(why=="FR PROBE FAIL: CHECK BALLOON INTEGRITY",tostring(why))
local io=make("vent",true,true);io.nodes.FR.balloon.liftValid=false
ok,why=IO.emergencyLiftStopStateVerified(io,"FR","b",0)
assert(why=="CHAMBER FR UNCONFIRMED; CHECK PROBE",tostring(why))
''')


if __name__ == "__main__":
    unittest.main()
