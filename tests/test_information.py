"""Navigator information and assembly/identity regression scenarios."""
from pathlib import Path
import json,sys,unittest
ROOT=Path(__file__).resolve().parents[1];HOME=ROOT/'disk-builder'
sys.path.insert(0,str(HOME))
import builder
from tests.test_runtime_bundling import LuaRuntime,table
from tests.test_bridge_presentation import HARNESS
from tests.test_persistent_modes import fixture_source

_CACHE=None

def collected():
    global _CACHE
    if _CACHE is None:_CACHE=builder.collect_project(ROOT)
    return _CACHE

def runtime():
    source=collected()
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SOURCES=table(lua,{p:d.decode('utf-8')for p,d in source['payload'].items()if p.endswith('.lua')})
    lua.globals().CONFIG=table(lua,json.loads((ROOT/'source/core/avionics/config.json').read_bytes()))
    lua.execute('''
NOW=1;os.clock=function()return NOW end;os.__amaryllisLog=function()end
local loaded={}
function require(name)
 if loaded[name]~=nil then return loaded[name]end
 local path="/"..name:gsub("%.","/")..".lua"
 local source=assert(SOURCES[path],"missing "..path)
 local value=assert(load(source,"@"..path))()
 loaded[name]=value==nil and true or value;return loaded[name]
end
function check(value,label)assert(value,label)end
function clone(t)if type(t)~="table"then return t end;local r={};for k,v in pairs(t)do r[k]=clone(v)end;return r end
''')
    return lua

HEALTHY = """
function healthy(s)
 s.thrust={available=true,roles={},units={},
   manualAcceleration={available=true,mode="MANUAL"},headingControl={available=true,mode="MANUAL"}}
 for _,label in ipairs({"thrust-lb","thrust-rb","thrust-ls","thrust-rs"})do
  s.thrust.roles[label]={online=true,available=true,statusFresh=true,thrustControlState="RDY"}
 end
 for _,label in ipairs({"primary-left","primary-right"})do
  s.thrust.units[label]={online=true,available=true,statusFresh=true}
 end
end
"""

class InformationTests(unittest.TestCase):
    def test_assembly_sequence_timeout_and_retention(self):
        lua=runtime()
        lua.execute('''
local IO=require("avionics.io");local clock=10
local r=setmetatable({config={network={sensor_stale_seconds=3}},localID=1,
 nowSeconds=function()return clock end,primaryReadings={},assemblyTrack={error="unreadable"}},{__index=IO})
local ok,_,a=r:assemblyGate(clock);check(ok and not a.verified and not a.warning,"unknown stays open")
clock=309;ok,_,a=r:assemblyGate(clock);check(ok and not a.warning,"before five minutes")
clock=310;ok,_,a=r:assemblyGate(clock);check(ok and a.warning and a.unverifiedSeconds==300,"five-minute warning")
clock=600;ok,_,a=r:assemblyGate(clock);check(ok and a.warning,"continued uncertainty stays open")
r.primaryReadings.uuid={value="ship",at=clock}
ok,_,a=r:assemblyGate(clock);check(ok and a.verified and not a.warning,"fresh Sable clears warning")
r.assemblyTrack={definite=false,definiteAt=clock}
ok,_,a=r:assemblyGate(clock);check(ok and a.verified,"fresh Sable wins first check")
r.primaryReadings={};ok,_,a=r:assemblyGate(clock);check(not ok and a.state=="DISASSEMBLED","explicit false locks")
clock=604;ok,_,a=r:assemblyGate(clock);check(ok and a.state~="DISASSEMBLED","stale false is uncertain")
r.assemblyTrack={definite=true,definiteAt=clock}
ok,_,a=r:assemblyGate(clock);check(ok and a.verified,"assembler true verifies fallback")
''')

    def test_configured_modded_frequencies(self):
        lua=runtime()
        lua.execute('''
local Storage=require("avionics.storage");local c=clone(CONFIG)
c.input_frequencies.left_press={"example:some/item","other:frequency"}
local ok,why=Storage.validateConfig(c);check(ok,why)
for _,value in ipairs({"missingcolon",":empty","empty:","a:b:c"})do
 c.input_frequencies.left_press={value,"other:item"}
 check(not Storage.validateConfig(c),"invalid shape "..value)
end
c.input_frequencies.left_press=clone(c.input_frequencies.left_lift)
check(not Storage.validateConfig(c),"duplicate pair")
''')

    def test_uuid_adoption_preserves_intent_and_control_values(self):
        lua=runtime()
        lua.execute(fixture_source()+'''
local io,f,p,clock=setup()
f.uuid="vessel";f.controls.uuid="vessel";f.controls.targets={heading=123,speed=4,altitude=170}
f.controls.modes={heading="SEL",throttle="SEL"}
f.systemsRun={uuid="vessel",phase="READY",target=170,currentTargets={FL={vent=123}}}
f.systemsRetainedRun=clone(f.systemsRun)
io.autopilot={uuid="vessel",active=true};io.positionAnchor={uuid="vessel",active=false}
io.vessel.uuid="new-vessel";io.vessel.valid=true;io.vessel.at=10
io.primaryReadings={uuid={value="new-vessel",at=10}}
io.assemblyTrack={error="unreadable"}
f:adoptVesselIdentity(io,10)
check(f.uuid=="new-vessel" and f.systemsRun.uuid=="new-vessel","run adoption")
check(f.controls.uuid=="new-vessel" and io.autopilot.uuid=="new-vessel","dependent association")
check(f.controls.modes.heading=="SEL" and f.controls.targets.altitude==170,"pilot selections retained")
check(f.systemsRun.currentTargets.FL.vent==123 and io.autopilot.active,"retained operation")
io.primaryReadings.uuid={value="old-packet",at=1};io.vessel.uuid="old-packet"
f:adoptVesselIdentity(io,10);check(f.uuid=="new-vessel","stale identity rejected")
''')

    def test_retry_state_keeps_retrying_and_counts_cycles(self):
        lua=runtime()
        lua.execute('''
local AP=require("avionics.autopilot");local Anchor=require("avionics.anchor")
for _,class in ipairs({AP,Anchor})do
 local obj=setmetatable({active=true,config={thrust={enabled=true}},since=nil},{__index=class})
 local io={identityReady=false,vessel={at=1}}
 obj:update(io,1,{});check(obj.state=="RETRYING (1)","first attempt")
 obj:update(io,1.1,{});check(obj.state=="RETRYING (1)","same observations deferred")
 obj:update(io,3,{});check(obj.state=="RETRYING (2)","second scheduled attempt")
 obj:update(io,400,{});check(obj.state=="RETRYING (3)","no elapsed failure verdict")
end
local Recovery=require("avionics.telemetry_recovery");local f={};local s={phase="READY",target=170}
Recovery.suspend(f,s,1,"missing");s.telemetryRecovery.attemptCount=7
Recovery.suspend(f,s,400,"missing")
check(f.systemsSnapshot.recovery.state=="RETRYING (7)" and not s.telemetryRecovery.failed,"lift count continues")
''')


    def test_initial_acquisition_lifecycle_uses_actual_decorator(self):
        lua=runtime()
        lua.execute(fixture_source()+'''
local io,f,p,clock=setup()
f.systemsRun={phase="VENT_IGNITION",target=160,currentTargets={}}
f.systemsSnapshot={phase="VENT_IGNITION",active=true}
f.initialAcquisitionTarget=160;f.controls.targets.altitude=160
local function phase()
 local s={targets={},nodes={},updatedAt=10};f:decorate(s,io,10);return s.systemsStartup.displayPhase
end
check(phase()=="OPENING STEAM VENTS","opening label")
f.systemsRun.phase="MAIN_LIFT";check(phase()=="STATIC INFLATION","initial fill")
f.systemsRun.launchStartedAt=8;f.systemsRun.launchDurationSeconds=10
f.systemsRun.launchMotionVerified=true
check(phase()=="CAPTURING PITCH ZERO","settling wins over movement")
f.systemsRun.launchComplete=true;check(phase()=="ACQUIRING SEL ALT","initial ascent")
f.controls.targets.altitude=180;check(phase()=="READY","accepted target edit ends acquisition")
f.controls.targets.altitude=160;check(phase()=="READY","returning target stays ready")
f.initialAcquisitionEnded=false;f.systemsRun.airborneStart=true
check(phase()=="READY","airborne adoption")
f.initialAcquisitionEnded=true;f.systemsRun.phase="SUSPENDED"
check(phase()=="SUSPENDED","recovery keeps its own phase")
f.systemsRun.phase="PROBING";check(phase()=="PROBING","verification keeps its own phase")
''')

    def test_source_ordering_and_assembler_freshness(self):
        lua=runtime()
        lua.execute('''
local S=require("avionics.vessel_sources")
local io={config={network={sensor_stale_seconds=3}},hardwareFingerprint="x",
 primaryReadings={},fallbackReadings={}}
S.acceptPrimary(io,"uuid","new",10)
S.acceptPrimary(io,"uuid","old",9);check(io.primaryReadings.uuid.value=="new","older UUID rejected")
S.acceptPrimary(io,"uuid","same-time-change",10);check(io.primaryReadings.uuid.value=="new","equal-time change rejected")
io.assemblyTrack={definite=false,definiteAt=10}
local v=S.compose(io,10);check(v.uuid=="new" and v.reason~="VESSEL DISASSEMBLED","Sable precedes false")
io.primaryReadings={};io.assemblyTrack={definite=false,definiteAt=1}
v=S.compose(io,10);check(v.uuid=="new" and v.reason~="VESSEL DISASSEMBLED","stale false retains identity")
io.assemblyTrack={definite=false,definiteAt=10}
v=S.compose(io,10);check(v.reason=="VESSEL DISASSEMBLED","fresh explicit false")
''')

    def test_heading_transport_and_documentation_equivalence(self):
        lua=runtime()
        lua.execute('''
local P=require("avionics.display_payload")
local value=P.heading({systemsStartup={phase="MAIN_LIFT",displayPhase="READY"}})
check(value.systemsStartup.displayPhase=="READY","heading receives display phase")
''')
        source=collected()
        for side in ("left","right","main"):
            text=source["library"]["/packages/heading/"+side+"/main.lua"].decode()
            self.assertIn('labels[systems.displayPhase]',text)
            self.assertNotIn('"HOLD OFF"',text)
        for mapping in (source["payload"],source["library"]):
            stripped=dict(mapping)
            builder.information.strip_notes(stripped)
            for path,data in mapping.items():
                if path.endswith(".lua"):
                    self.assertEqual([x[0] for x in builder.source_notes.tokens(data.decode())],
                                     [x[0] for x in builder.source_notes.tokens(stripped[path].decode())],path)
        self.assertTrue(source["sourceDocumentation"])
        self.assertTrue(all(x["summarized"]==x["majorFunctions"] for x in source["sourceDocumentation"]))


class InformationUiTests(unittest.TestCase):
    def setUp(self):
        self.lua=runtime()
        self.lua.globals().UI=self.lua.execute(collected()['library']['/packages/navigation/ui.lua'].decode())
        self.lua.globals().CAPTURES=self.lua.table()
        self.lua.execute(HARNESS)
        self.lua.execute(HEALTHY)


    def run_lua(self,source):return self.lua.execute(source)

    def test_kill_colours_specific_progress(self):
        self.run_lua('''
local ui,s,draw=fixture()
local states={
 {phase="KILLING",pending=true,latched=true,want="KILL LIFT PENDING",color="4"},
 {phase="KILL INCOMPLETE",latched=true,want="KILL LIFT INCOMPLETE",color="4"},
 {phase="KILL CONFIRMED",latched=true,complete=true,want="KILL LIFT ARMED; DISARM BEFORE START",color="e"},
 {phase="DISARMING",latched=true,disarming=true,want="DISARMING KILL; SYSTEMS STOPPED",color="4"}}
for _,v in ipairs(states)do
 s.emergencyLift=v;draw();local row=ui.previous.rows[21]
 check(row.text:find(v.want,1,true),v.want);check(row.foreground:sub(2,2)==v.color,"kill colour")
end
''')

    def test_warning_rotation_click_and_parent_back(self):
        self.run_lua('''
local ui,s,draw=fixture()
s.bridgeRequest={status="QUEUED",queuedCount=2}
s.assembly.warning="ASSEMBLY UNVERIFIED; OPERATOR CHECK REQUIRED"
draw();local seen={}
for n=1,8 do NOW=NOW+3;draw();seen[ui.warningRegion.id]=true end
check(seen["assembly-unverified"] and seen["command"],"equal warnings rotate")
local touched=ui.warningRegion.id
check(ui:touch(3,21,s)==nil and ui.issuesOpen,"plain text opens locally")
draw();check(ui.issueFocus==touched,"focus drawn issue")
check(ui.previous.rows[5].text:find("CURRENT ISSUES",1,true),"issues title")
ui:touch(3,5,s);check(not ui.issuesOpen and ui.page=="FLIGHT","Back returns to Flight")
ui.page="SETTINGS";ui.settingsView="GENERAL";draw()
check(ui:touch(3,16,s)==nil and ui.issuesOpen,"Settings issues entry")
ui:touch(3,5,s);check(ui.page=="SETTINGS" and ui.settingsView=="GENERAL","Back returns to Settings")
''')

    def test_severity_preemption_and_resolved_issue_removal(self):
        self.run_lua('''
local ui,s,draw=fixture();s.bridgeRequest={status="QUEUED"}
s.emergencyLift={latched=true,complete=true};draw()
check(ui.warningRegion.id=="kill","red preempts")
NOW=10;draw();check(ui.warningRegion.id=="kill","yellow does not replace red")
s.emergencyLift={};draw()
for _,item in ipairs(ui.currentIssues)do check(item.id~="kill","resolved removed")end
''')

    def test_assembly_retry_not_visible_and_overflow_navigation(self):
        self.run_lua('''
local ui,s,draw=fixture()
s.assembly.unverifiedSeconds=299;draw()
for _,item in ipairs(ui.currentIssues)do check(item.id~="assembly-unverified","routine uncertainty hidden")end
s.assembly.warning="ASSEMBLY UNVERIFIED; OPERATOR CHECK REQUIRED";draw()
for _,item in ipairs(ui.currentIssues)do if item.id=="assembly-unverified"then check(item.tone=="yellow","operator warning yellow")end end
''')

    def test_startup_labels_and_alt_offline(self):
        self.run_lua('''
local ui,s,draw=fixture();running(s)
for _,phase in ipairs({"OPENING STEAM VENTS","STATIC INFLATION","CAPTURING PITCH ZERO","ACQUIRING SEL ALT"})do
 s.systemsStartup.phase="MAIN_LIFT";s.systemsStartup.displayPhase=phase;draw()
 check(ui.previous.rows[20].text:find(phase,1,true),"startup "..phase)
end
''')


    def test_issue_pagination_and_empty_state(self):
        self.run_lua('''
local ui,s,draw=fixture()
s.faults={"ISSUE ONE","ISSUE TWO","ISSUE THREE","ISSUE FOUR","ISSUE FIVE","ISSUE SIX"}
draw();ui:touch(3,21,s);draw()
check(ui.previous.rows[20].text:find("/2",1,true),"multiple issue pages")
ui:touch(40,19,s);draw();check(ui.issuesOffset==4,"next page")
check(ui.previous.rows[6].text:find("ISSUE FIVE",1,true),"fifth issue visible")
ui:touch(20,19,s);draw();check(ui.issuesOffset==0,"previous page")
s.faults={};healthy(s);draw()
check(ui.previous.rows[10].text:find("NO CURRENT ISSUES",1,true),"empty state")
''')


    def test_issue_identity_survives_reordered_fault_list(self):
        self.run_lua("""
local ui,s,draw=fixture();healthy(s);s.faults={"FIRST FAULT","SECOND FAULT"};draw()
local id=ui.warningRegion.id
NOW=3;s.faults={"SECOND FAULT","FIRST FAULT"};draw()
check(ui.warningRegion.id==id,"same issue survives list reordering")
check(ui.issueAges[id]==1,"issue age retained")
ui:touch(3,21,s);draw()
local found=false
for _,item in ipairs(ui.currentIssues)do
 if item.id==ui.issueFocus then check(item.text=="FIRST FAULT","focus follows displayed warning");found=true end
end
check(found,"focused issue remains in list")
""")

    def test_disassembled_vessel_shows_only_that_issue(self):
        self.run_lua("""
local ui,s,draw=fixture();healthy(s)
local message="VESSEL DISASSEMBLED: physics_assembler_1.isAssembled() = false"
s.assembly={state="DISASSEMBLED",assembled=false,message=message,reason="physics_assembler_1.isAssembled() = false"}
s.faults={message,"VESSEL DISASSEMBLED","CHAMBER FL SILENT 12 S; CHECK POWER AND LINK"}
draw()
check(#ui.currentIssues==1,"one issue, found "..#ui.currentIssues)
check(ui.currentIssues[1].id=="assembly-lock" and ui.currentIssues[1].text=="ASSEMBLE VESSEL TO ENABLE CONTROLS","the assembly instruction")
check(ui.currentIssues[1].detail==message,"the assembly check's message is the detail")
check(ui.previous.rows[21].text:find("ASSEMBLE VESSEL TO ENABLE CONTROLS",1,true),"bottom line")
local page={}
for y=5,20 do page[#page+1]=ui.previous.rows[y].text end
page=table.concat(page," ")
check(page:find("Core module reports physics assembler is not engaged.",1,true),"panel explains the cause")
check(page:find("Please assemble the vessel",1,true) and page:find("Previous gas levels will be carried over.",1,true),"panel instruction")
check(ui.previous.rows[9].text:find("Core module reports",1,true),"cause on row 9")
check(ui.previous.rows[13].text:find("Please assemble the vessel to enable controls.",1,true),"instruction on row 13")
check(ui.previous.rows[14].text:find("Previous gas levels will be carried over.",1,true),"gas levels on row 14")
for _,old in ipairs({"Source: physics","Blocked:","Applied lift ceilings","Nothing resumes","isAssembled() = false","Lift maintenance"}) do
 check(not page:find(old,1,true),"removed: "..old)
end
s.assembly={state="ASSEMBLED",assembled=true};draw()
local listed=false
for _,item in ipairs(ui.currentIssues)do if item.text:find("CHAMBER FL SILENT",1,true)then listed=true end end
check(listed,"other faults return once assembled")
""")

if __name__=='__main__':unittest.main(verbosity=2)
