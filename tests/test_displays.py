"""Bridge, heading-display and core-console presentation."""

# ======================================================================
# From test_bridge_presentation: Implementation 1: production bundled UI input, modal and wording checks.
# ======================================================================
import hashlib
import json
from pathlib import Path
import unittest

from tests import test_builder as support

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'output/tests/bridge-presentation'

HARNESS = r'''
NOW=1;os.clock=function()return NOW end;keys={escape=1}
function check(ok,why)assert(ok,why)end
function clone(t)if type(t)~='table'then return t end;local r={};for k,v in pairs(t)do r[k]=clone(v)end;return r end
function fixture(width,height,page)
 local m={getSize=function()return width or 57,height or 24 end,setCursorPos=function()end,
  blit=function(a,b,c)assert(#a==#b and #b==#c)end,setTextScale=function()end}
 local ui=assert(UI.new(m,{role='main'}));ui.page=page or 'FLIGHT'
 local s={updatedAt=1,dataFresh=true,displayStale=false,stale=false,
  assembly={state='ASSEMBLED'},fleetBoot={ready=true},
  vessel={valid=true,uuid='ship',altitude=160,verticalSpeed=.02,heading=57.7,pitch=0,roll=0,
   mass=200000,forwardSpeed=0,geometryVerified=true,velocityFrameVerified=true},
  modes={heading='MANUAL',throttle='MANUAL',lateral='MANUAL'},targets={altitude=160,speed=0},
  cockpitControl={available=true},inputs={valid=true,raw={}},
  altitudeControl={enabled=false,available=true},systemsStartup={available=true,active=false,phase='IDLE'},
  systemsRestart={available=false,reason='START SYSTEMS FIRST'},emergencyLift={latched=false},
  settings={entries={}},nodes={},debugMode={enabled=false,state='IDLE'}}
 for _,q in ipairs({'FL','FR','BL','BR'})do s.nodes[q]={online=true,thrustControlState='RDY',liftControlState='CMD',providers={},
  balloon={hasBalloon=true,hasBalloonValid=true,gasMixValid=true,gasMix={steam=33333},lift=50000,liftValid=true}}end
 local function draw()
  s.page=ui.page;local ok,why=ui:draw(s);assert(ok,why);return ui.previous
 end
 local function open()
  draw();assert(ui:touch(width or 57,3,s)==nil,'opening Options must not issue a command');assert(ui.systemsMenu)
  return draw()
 end
 local function region(kind)
  for _,r in ipairs(ui.systemsMenuRegions or {})do if r.action.type==kind then return r end end
  error('missing menu action '..kind)
 end
 local function choose(kind)
  local r=region(kind);return ui:touch(r.x1,r.y1,s)
 end
 local function capture(name)
  draw();local rows,fg,bg={},{},{}
  for y,row in ipairs(ui.previous.rows)do rows[y]=row.text;fg[y]=row.foreground;bg[y]=row.background end
  CAPTURES[name]={text=rows,foreground=fg,background=bg,width=width or 57,height=height or 24,
   page=ui.page,phase=s.systemsStartup.phase,simulatedSeconds=NOW}
 end
 return ui,s,draw,open,choose,region,capture
end
function running(s)
 s.systemsStartup={available=false,active=true,phase='READY',target=160}
 s.systemsRestart={available=true};s.altitudeControl.enabled=true
end
'''


class BridgePresentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = support.bundled_builder.collect_project(support.SOURCE)
        cls.ui_source = cls.source['library']['/packages/navigation/ui.lua']
        # Packing in memory tests the same production loader/file layout, without
        # creating a distributable installer or writing any live computer files.
        cls.source = support.bundle.prepare(cls.source, support.bundled_builder.FOLDERS)
        cls.bundle = cls.source['library']['/packages/navigation/main.lua'].decode()
        cls.captures = {}

    def setUp(self):
        self.lua, _ = support.native_runtime()
        self.lua.globals().UI = self.lua.execute(self.bundle, support.bundle.MAGIC, '/avionics/ui.lua')
        self.lua.globals().CAPTURES = self.lua.table()
        self.lua.execute(HARNESS)

    def run_lua(self, source):
        self.lua.execute(source)

    def test_idle_menu_start_and_header(self):
        self.run_lua('''
local ui,s,draw,open,choose,r,capture=fixture()
draw();check(ui.previous.rows[2].text:find('SYSTEMS',1,true),'Systems header')
check(not ui.previous.rows[2].text:find('ALTITUDE TARGET',1,true),'old header removed')
check(not ui.previous.rows[4].text:find('KILL LIFT',1,true),'old kill button removed')
check(ui:touch(1,4,s)==nil and ui.killReview==nil,'old kill location has no action')
capture('01-options-closed');open();capture('02-options-idle')
check(r('start_systems').enabled and not r('systems_stop').enabled,'idle availability')
local a=choose('start_systems');check(a and a.type=='start_systems' and not ui.systemsMenu,'start action')
''')

    def test_running_menu_stop_restart_and_disabled_start(self):
        self.run_lua('''
local ui,s,draw,open,choose,r,capture=fixture();running(s);open();capture('03-options-running')
check(not r('start_systems').enabled and r('systems_stop').enabled and r('restart_systems').enabled,'running availability')
check(choose('start_systems')==nil and ui.systemsMenu and ui.systemsMenuNotice,'disabled action explains reason')
local a=choose('systems_stop');check(a and a.type=='systems_stop','stop requests existing confirmation')
open();a=choose('restart_systems');check(a and a.type=='restart_systems','restart action')
''')

    def test_starting_menu_availability(self):
        self.run_lua('''
local ui,s,draw,open,choose,r,capture=fixture();s.systemsStartup={active=true,available=false,phase='PROBING'}
open();capture('04-options-starting')
check(not r('start_systems').enabled and r('systems_stop').enabled and not r('restart_systems').enabled,'starting availability')
''')

    def test_outside_touch_dismissed_without_click_through(self):
        self.run_lua('''
local ui,s,draw,open=fixture();open();local nav=ui.tabs[2]
check(ui:touch(nav.x1,nav.y1,s)==nil and not ui.systemsMenu,'outside tap consumed')
local a=ui:touch(nav.x1,nav.y1,s);check(a and a.type=='page' and a.page=='NAV','second tap navigates')
open();check(ui:touch(57,3,s)==nil and not ui.systemsMenu,'trigger closes menu')
''')

    def test_raw_touch_snapshot_revalidates_stale_and_changed_state(self):
        self.run_lua('''
local ui,s,draw,open,choose,r,capture=fixture();open()
s.dataFresh=false;s.displayStale=true;s.stale=true
check(choose('start_systems')==nil and ui.systemsMenuNotice:find('FRESH',1,true),'stale selection rejected without redraw')
draw();capture('05-options-stale')
for _,entry in ipairs(ui.systemsMenuRegions)do check(not entry.enabled,'all stale commands disabled')end
s.dataFresh=true;s.displayStale=false;s.stale=false;s.systemsStartup.available=false;s.systemsStartup.active=true
check(choose('start_systems')==nil,'new active state rejects previously drawn start')
''')

    def test_fleet_and_assembly_preserve_stop_and_kill(self):
        self.run_lua('''
for _,gate in ipairs({'fleet','assembly'})do
 local ui,s,draw,open,choose,r=fixture();running(s)
 if gate=='fleet'then s.fleetBoot.ready=false else s.assembly.state='UNKNOWN' end
 open();check(not r('start_systems').enabled and not r('restart_systems').enabled,'authority gates retained')
 check(r('systems_stop').enabled and r('emergency_kill_lift').enabled,'stop and kill remain accessible')
end
''')

    def test_kill_confirmation_cancel_confirm_stale_timeout_on_all_pages(self):
        self.run_lua('''
for _,page in ipairs({'FLIGHT','NAV','SHIP','SETTINGS'})do
 local ui,s,draw,open,choose,r,capture=fixture(57,24,page);running(s);open()
 check(choose('emergency_kill_lift')==nil and ui.killReview and not ui.systemsMenu,'kill selection only opens review')
 draw();if page=='FLIGHT'then capture('06-kill-confirmation')end
 for y=6,20 do check(ui.previous.rows[y].text:sub(1,1)==' ','confirmation clears old edge glyphs')end
 local cancel,confirm
 for _,button in ipairs(ui.killRegions)do if button.confirm then confirm=button else cancel=button end end
 check(ui:touch(cancel.x1,cancel.y1,s)==nil and not ui.killReview,'kill cancellation')
 open();choose('emergency_kill_lift');draw();local a=ui:touch(confirm.x1,confirm.y1,s)
 check(a and a.type=='emergency_kill_lift','explicit confirmation emits original kill command')
 open();choose('emergency_kill_lift');draw();s.dataFresh=false;s.displayStale=true;s.stale=true
 check(ui:touch(confirm.x1,confirm.y1,s)==nil,'stale confirm cannot issue kill')
 s.dataFresh=true;s.displayStale=false;s.stale=false
 open();choose('emergency_kill_lift');NOW=12;draw();check(not ui.killReview,'confirmation expires');NOW=1
end
''')

    def test_latched_disarm_and_pending_kill_states(self):
        self.run_lua('''
local ui,s,draw,open,choose,r,capture=fixture();s.emergencyLift={latched=true,complete=true,phase='KILL CONFIRMED'}
open();capture('07-options-kill-latched')
check(not r('start_systems').enabled and r('disarm_lift_kill').enabled,'kill latch blocks start and exposes disarm')
local a=choose('disarm_lift_kill');check(a and a.type=='disarm_lift_kill','existing disarm action preserved')
s.emergencyLift={latched=true,disarming=true};open();check(not r('disarm_lift_kill').enabled,'pending disarm cannot duplicate')
for _,phase in ipairs({'KILLING','KILL INCOMPLETE'})do
 ui.systemsMenu=nil;s.emergencyLift={phase=phase,pending=phase=='KILLING'};open()
 check(r('emergency_kill_lift').enabled==(phase=='KILL INCOMPLETE'),'pending blocked, incomplete kill retryable')
end
''')

    def test_stop_and_kill_dialogs_have_priority(self):
        self.run_lua('''
local ui,s,draw,open,choose,r,capture=fixture();running(s);open();s.systemsStopReview={token='test-review'}
draw();capture('08-stop-confirmation');check(not ui.systemsMenu,'stop review closes menu')
check(ui:touch(57,3,s)==nil and not ui.systemsMenu,'Options cannot bypass stop review')
for _,button in ipairs(ui.stopRegions)do
 local a=ui:touch(button.x1,button.y1,s)
 check(a and a.type==button.action.type and a.token=='test-review','stop dialog preserves confirmation token')
end
s.systemsStopReview=nil;open();choose('emergency_kill_lift');draw()
check(ui:touch(57,3,s)==nil and ui.killReview and not ui.systemsMenu,'Options cannot bypass kill review')
''')

    def test_escape_small_screen_and_resize(self):
        self.run_lua('''
local ui,s,draw,open=fixture();open();ui:input('key',keys.escape);check(not ui.systemsMenu,'Escape dismisses')
open();ui.monitor.getSize=function()return 56,23 end;draw();check(not ui.systemsMenu,'small-screen reset')
ui.monitor.getSize=function()return 80,30 end;draw();ui:touch(80,3,s);draw()
check(ui.systemsMenuRegions[1].x2==79,'resize updates menu bounds')
''')

    def test_wording_and_wrapped_debug_text(self):
        self.run_lua('''
local ui,s,draw,open,choose,r,capture=fixture();draw()
check(ui.previous.rows[14].text:find('V/S +0.02 b/s',1,true),'V/S label and measured value')
check(ui.previous.rows[6].text:find('^ BOW ^',1,true),'orientation label')
ui.page='SETTINGS';ui.settingsView='DEBUG';draw();capture('09-debug-wording')
local text='';for _,row in ipairs(ui.previous.rows)do text=text..' '..row.text end;text=text:gsub('%s+',' ')
check(text:find("Use an empty disk in one of core's disk drives.",1,true),'disk instruction')
check(text:find('Logs are located under /amaryllis-logs/ directory on the disk.',1,true),'full wrapped log location')
check(not text:find('Installer disks are refused.',1,true),'old instruction removed')
ui.settingsView='DISPLAY';draw();capture('10-display-wording')
for _,row in ipairs(ui.previous.rows)do check(not row.text:find('fixed 57 x 24',1,true),'layout specification removed')end
''')

    def test_menu_layout_across_pages_and_monitor_sizes(self):
        self.run_lua('''
for _,size in ipairs({{57,24},{80,30},{100,36}})do for _,page in ipairs({'FLIGHT','NAV','SHIP','SETTINGS'})do
 local ui,s,draw,open=fixture(size[1],size[2],page);open()
 for _,r in ipairs(ui.systemsMenuRegions)do check(r.x1>=1 and r.x2<=size[1] and r.y1>=1 and r.y2<=size[2],'menu bounds')end
 for _,row in ipairs(ui.previous.rows)do check(#row.text==size[1] and #row.foreground==size[1] and #row.background==size[1],'complete surface')end
end end
''')

    def tearDown(self):
        self.captures.update(support.python_value(self.lua.globals().CAPTURES))

    @classmethod
    def tearDownClass(cls):
        REPORT.mkdir(parents=True,exist_ok=True)
        (REPORT/'screens.json').write_text(json.dumps(cls.captures,indent=2)+'\n')
        (REPORT/'bridge-ui.lua').write_bytes(cls.ui_source)
        (REPORT/'identity.json').write_text(json.dumps({'builderVersion':support.bundled_builder.VERSION,
            'uiSHA256':hashlib.sha256(cls.ui_source).hexdigest(),'liveSaveModified':False,
            'installerBuiltForDistribution':False,'bridgePackageVersion':cls.source['versions']['navigator']},indent=2)+'\n')


# ======================================================================
# From test_presentation: Core console generation from the package console: Panel Home entry and remote fleet status.
# ======================================================================
import unittest
import project


class Rejected(Exception):
    """Raised by the test require hook for unsupported source shapes."""


def require(condition, message):
    """Mirror the builder's require contract with a test-local exception."""
    if not condition:
        raise Rejected(message)


class PresentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.presentation = project.builder_module().presentation
        cls.files = {"/" + k: v for k, v in project.source_files().items()}
        assets = project.HOME / "assets"
        cls.panel = (assets / "panel-console.lua").read_bytes()
        cls.remote = (assets / "remote-panel.lua").read_bytes()

    def payload(self, console=None):
        """Return a core payload whose console starts from the package console, as in collection."""
        payload = dict(self.files)
        payload["/avionics/common/console.lua"] = console or payload["/packages/common/console.lua"]
        payload["/avionics/remote_client.lua"] = self.remote
        return payload

    def transform(self, payload):
        """Apply the core console generators in builder order."""
        self.presentation.apply_console(payload, self.panel, require)
        self.presentation.apply_remote(payload, self.remote, require)
        return payload

    def test_package_console_transforms_to_maintained_core_console(self):
        result = self.transform(self.payload())
        self.assertEqual(result["/avionics/common/console.lua"], self.files["/avionics/common/console.lua"])

    def test_unsupported_console_shape_rejected(self):
        console = self.files["/packages/common/console.lua"].replace(b"    local mode = arguments[1]\n", b"    local mode = nil\n")
        with self.assertRaisesRegex(Rejected, "Panel Home"):
            self.presentation.apply_console(self.payload(console), self.panel, require)

    def test_package_console_keeps_intended_differences(self):
        package = self.files["/packages/common/console.lua"]
        core = self.files["/avionics/common/console.lua"]
        self.assertNotIn(b'require("avionics.panel_console")', package)
        self.assertEqual(core.count(b'require("avionics.panel_console")'), 2)

    def test_unsupported_remote_callback_rejected(self):
        console = self.files["/packages/common/console.lua"].replace(b"        return {lines=result}\n", b"        return result\n")
        with self.assertRaisesRegex(Rejected, "remote status callback"):
            self.transform(self.payload(console))


# ======================================================================
# From test_information: Navigator information and assembly/identity regression scenarios.
# ======================================================================
from pathlib import Path
import json,sys,unittest
ROOT=Path(__file__).resolve().parents[1];HOME=ROOT/'disk-builder'
sys.path.insert(0,str(HOME))
import builder
from tests.test_builder import LuaRuntime, table
from tests.test_state import fixture_source

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
s.assembly.retainedGasM3={FL=12400,BL=0}
s.nodes.FL.providers.probe={controlRole="fine",present=true,attachedValid=true,attached=true}
s.modes={heading="SEL",throttle="DIRECT",lateral="SEL"}
s.systemsRestart.available=true
s.faults={message,"VESSEL DISASSEMBLED","CHAMBER FL SILENT 12 S; CHECK POWER AND LINK"}
draw()
check(#ui.currentIssues==1,"one issue, found "..#ui.currentIssues)
check(ui.currentIssues[1].id=="assembly-lock" and ui.currentIssues[1].text=="ASSEMBLE VESSEL TO ENABLE CONTROLS","the assembly instruction")
check(ui.currentIssues[1].detail==message,"the assembly check's message is the detail")
check(ui.previous.rows[21].text:find("ASSEMBLE VESSEL TO ENABLE CONTROLS",1,true),"bottom line")
local page={}
for y=5,20 do page[#page+1]=ui.previous.rows[y].text end
page=table.concat(page," ")
check(ui.page=="STATUS" and #ui.tabs==2,"disassembly opens Status with two tabs")
for y=5,7 do
 local bg=ui.previous.rows[y].background
 check(bg:sub(4,5)=="fe" and bg:sub(53,54)=="ef","banner is three rows with side margins")
end
check(ui.previous.rows[9].text:find("CHAMBER STATUS",1,true),"chamber heading")
local probes=ui.previous.rows[11]
local fl=assert(probes.text:find("FL PROBE",1,true))
local fr=assert(probes.text:find("FR NO PROBE",1,true))
check(probes.foreground:sub(fl,fl+7)==string.rep("d",8),"confirmed probe is green")
check(probes.foreground:sub(fr,fr+10)==string.rep("e",11),"unconfirmed probe is red")
check(ui.previous.rows[12].text:find("GAS 12400 m3") and ui.previous.rows[12].text:find("GAS N/A"),"stored and missing gas")
check(ui.previous.rows[15].text:find("GAS 0 m3"),"zero is a stored value")
check(ui.previous.rows[18].text:find("Please assemble the vessel to enable controls.",1,true),"assembly instruction")
local modes=ui.previous.rows[3]
local sel=assert(modes.text:find("SEL"))
local direct=assert(modes.text:find("DIRECT"))
check(modes.foreground:sub(sel,sel)=="9" and modes.foreground:sub(direct,direct)=="9","saved modes are cyan text")
check(modes.background:sub(sel,sel)=="f" and ui:touch(sel,3,s)==nil,"saved modes are read only")
check(modes.text:find("SYSTEMS LOCKED",1,true),"Status has the locked global bar")
check(not ui.previous.rows[4].text:find("STRAFE"),"strafe hidden")
for _,old in ipairs({"Source: physics","Blocked:","Applied lift ceilings","Nothing resumes","isAssembled() = false","Lift maintenance"}) do
 check(not page:find(old,1,true),"removed: "..old)
end
check(ui:touch(45,23,s)==nil,"Settings tab stays local");draw()
check(ui.page=="SETTINGS","Settings opens")
ui.systemsMenu=true;draw()
check(ui.previous.rows[3].text==modes.text,"Settings shares the same locked bar")
check(not ui.systemsMenu and ui:touch(50,3,s)==nil and not ui.systemsMenu,"locked bar closes and blocks Options")
ui:touch(40,18,s);draw()
check(ui.settingsView=="SYSTEMS","normal Settings page navigation")
local disabled=0
for _,region in ipairs(ui.settingsRegions) do
 if region.action.type=="start_systems" or region.action.type=="restart_systems" then
  check(not region.enabled and ui:touch(region.x1,region.y1,s)==nil,"systems action is disabled")
  disabled=disabled+1
 end
end
check(disabled==2,"both systems actions rendered")
check(ui:touch(10,23,s)==nil,"Status tab stays local");draw()
check(ui.page=="STATUS","Status returns")
s.assembly={state="ASSEMBLED",assembled=true};ui.page="FLIGHT";draw()
check(#ui.tabs==4 and ui.page=="FLIGHT","reassembly restores normal tabs")
check(ui.previous.rows[3].text:find("Options [v]",1,true),"active bar returns after reassembly")
check(ui:touch(50,3,s)==nil and ui.systemsMenu,"Options opens after reassembly")
ui.systemsMenu=nil
local listed=false
for _,item in ipairs(ui.currentIssues)do if item.text:find("CHAMBER FL SILENT",1,true)then listed=true end end
check(listed,"other faults return once assembled")
s.page="SETTINGS";ui.settingsView="SYSTEMS";assert(ui:draw(s))
check(ui:touch(2,16,s).type=="start_systems" and ui:touch(29,16,s).type=="restart_systems","normal action eligibility returns")
""")

    def test_disassembly_gas_uses_retained_recovery_targets(self):
        self.run_lua("""
local Flight=require("avionics.flight")
local f=setmetatable({systemsIntentActive=true,systemsRetainedRun={
 phase="READY",currentTargets={FL={vent=10},FR={vent=0},BL={vent=2}},
 pending={FL={targets={vent=12,probe=5}}},
 batchTargets={FL={vent=14,probe=5}},
 providerRoles={FL={vent="bulk",probe="fine"},BL={vent="bulk",probe="fine"}},
}},{__index=Flight})
local gas=f:retainedAssemblyGas()
check(gas.FL==19 and gas.FR==0 and gas.BL==nil and gas.BR==nil,"batch, zero and incomplete maps")
f.systemsRetainedRun.telemetryRecovery={targetMaps={FL={vent=25,probe=5}}}
gas=f:retainedAssemblyGas()
check(gas.FL==30 and gas.FR==nil,"recovery map supersedes the batch")
f.systemsIntentActive=false
check(f:retainedAssemblyGas()==nil,"stopped systems omit old gas targets")
local function provider(role,amount)
 return {controlRole=role,targetAmount=amount,targetValid=true,present=true}
end
local chamber={steamCount=2,providers={
 a=provider("bulk",4200),b=provider("bulk",4100),probe=provider("fine",5),
}}
local io={nodes={FL=chamber,FR=chamber,BL={steamCount=2,providers=chamber.providers}},
 nodeFresh=function(_,q)return q~="FR" end}
gas=f:retainedAssemblyGas(io,1)
check(gas.FL==8305 and gas.FR==nil and gas.BR==nil,"read persisted ceilings after stop")
chamber.providers.b.targetValid=false
check(f:retainedAssemblyGas(io,1)==nil,"incomplete readback stays unavailable")
f.restart={saved={run={currentTargets={FL={a=4400,b=4300,probe=5}}}}}
gas=f:retainedAssemblyGas(io,1)
check(gas.FL==8705 and gas.BL==nil,"pending restart uses its saved targets")
""")


# ======================================================================
# From test_heading_glyphs: Heading display text: single-cell delta and degree glyphs, and the ANCHORED bottom-left label.
# ======================================================================
import re
import unittest

import project
from tests import test_builder as support

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


# ======================================================================
# From test_ship_boiler_display: Ship page chamber headers show each chamber's lowest measured boiler efficiency.
# ======================================================================
import unittest

import project
from tests import test_builder as support


class ShipBoilerDisplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = support.bundled_builder.collect_project(project.ROOT)
        source = support.bundle.prepare(source, support.bundled_builder.FOLDERS)
        cls.bundle = source['library']['/packages/navigation/main.lua'].decode()

    def setUp(self):
        self.lua, _ = support.native_runtime()
        self.lua.globals().UI = self.lua.execute(self.bundle, support.bundle.MAGIC, '/avionics/ui.lua')
        self.lua.globals().CAPTURES = self.lua.table()
        self.lua.execute(HARNESS)

    def test_chamber_headers_show_lowest_bulk_boiler_rounded_down(self):
        for width, height in ((57, 24), (80, 30), (100, 36)):
            with self.subTest(size=(width, height)):
                self.lua.execute('''
local ui,s,draw=fixture(%d,%d,'SHIP');running(s)
-- Fine (trim) providers are ignored; the lowest valid bulk vent sets the chamber value.
local readings={FL={1,0.4},FR={0.016},BL={0.996},BR={}}
for q,list in pairs(readings)do
 local providers={trim={controlRole='fine',boilerEfficiencyValid=true,boilerEfficiency=0}}
 for i,e in ipairs(list)do providers['vent'..i]={controlRole='bulk',boilerEfficiencyValid=true,boilerEfficiency=e} end
 if q=='BR' then providers.vent1={controlRole='bulk',boilerEfficiencyValid=false} end
 s.nodes[q].providers=providers
end
draw()
local text={}
for y=1,%d do text[#text+1]=ui.previous.rows[y].text end
local all=table.concat(text,'\\n')
check(all:find('FL ONLINE  BOILER 40%%',1,true),'lowest FL bulk vent')
check(all:find('FR ONLINE  BOILER 1%%',1,true),'FR reading rounds down')
check(all:find('BL ONLINE  BOILER 99%%',1,true),'0.996 is not shown as 100%%')
check(all:find('BR ONLINE  BOILER --',1,true),'invalid reading shows no value')
''' % (width, height, height))

    def test_full_efficiency_shows_100_percent(self):
        self.lua.execute('''
local ui,s,draw=fixture(57,24,'SHIP');running(s)
for _,q in ipairs({'FL','FR','BL','BR'})do
 s.nodes[q].providers={vent={controlRole='bulk',boilerEfficiencyValid=true,boilerEfficiency=1}}
end
draw()
local all={}
for y=1,24 do all[#all+1]=ui.previous.rows[y].text end
check(table.concat(all,'\\n'):find('FL ONLINE  BOILER 100%',1,true),'full efficiency')
''')


    def test_lease_warnings_become_one_yellow_core_stall_notice(self):
        """A lost command or control lease recovers by itself, so the navigator only reports a yellow core stall."""
        for fault, shown, colour in (('COMMAND LEASE EXPIRED; RAMPING TO ZERO', 'CORE STALL; RESOLVING', '4'),
                                     ('LB LIFT CONTROL LEASE LOST', 'CORE STALL; RESOLVING', '4'),
                                     ('SHAFT BROKEN', 'SHAFT BROKEN', 'e')):
            with self.subTest(fault=fault):
                self.lua.globals().FAULT = fault
                self.lua.globals().SHOWN = shown
                self.lua.globals().COLOUR = colour
                self.lua.execute('''
local ui,s,draw=fixture(57,24,'SHIP');running(s)
s.faults={FAULT}
draw()
local found=false
for y=1,24 do
 local row=ui.previous.rows[y]
 local at=row.text:find(SHOWN,1,true)
 if at then
  found=true
  check(row.foreground:sub(at,at)==COLOUR,'colour of '..FAULT..' was '..row.foreground:sub(at,at))
 end
end
check(found,'warning not shown: '..SHOWN)

check(not table.concat((function() local t={} for y=1,24 do t[#t+1]=ui.previous.rows[y].text end return t end)(),'\\n'):find('LEASE',1,true) or SHOWN=='x','lease wording leaked')
''')


    def test_cockpit_inputs_menu_names_and_order(self):
        """Settings page 1 offers COCKPIT INPUTS; its menu lists the four setting pages top to bottom."""
        self.lua.execute('''
local ui,s,draw=fixture(57,24,'SHIP');running(s)
local function screen() local t={} for y=1,24 do t[#t+1]=ui.previous.rows[y].text end return table.concat(t,'\\n') end
ui.page='SETTINGS';ui.settingsView='GENERAL';draw()
check(screen():find('COCKPIT INPUTS',1,true) and not screen():find('INPUT TUNING',1,true),'general page button')
ui.settingsView='TARGET';draw()
local all=screen()
local last=0
for _,name in ipairs({'COCKPIT INPUTS','SEL HEADING SETTINGS','SEL THROTTLE SETTINGS','ALTITUDE SELECTOR SETTINGS','STRAFE SETTINGS'}) do
 local at=all:find(name,last+1,true)
 check(at,'missing or out of order: '..name);last=at or last
end
for _,old in ipairs({'SELECTED HEADING INPUT','SELECTED SPEED INPUT','ALTITUDE TARGET INPUT','INPUT TUNING'}) do check(not all:find(old,1,true),'old name still shown: '..old) end
for view,title in pairs({['SEL HEADING']='SEL HEADING SETTINGS',['SEL THROTTLE']='SEL THROTTLE SETTINGS',
  ['INPUT ALTITUDE']='ALTITUDE SELECTOR SETTINGS',['STRAFE SETTINGS']='STRAFE SETTINGS'}) do
 ui.settingsView=view;draw();check(screen():find(title,1,true),'page title '..title)
end
''')


    def test_propulsion_lateral_heading_does_not_overlap_first_thrust_row(self):
        for width, height in ((57, 24), (80, 30), (100, 36)):
            with self.subTest(size=(width, height)):
                self.lua.execute('''
local ui,s,draw=fixture(%d,%d,'SHIP');running(s)
ui.shipView='PROP';draw()
local header,first
for y=1,%d do
 local row=ui.previous.rows[y].text
 if row:find('LATERALS / APPLIED',1,true) then header=y;check(not row:find('THRUST',1,true),'heading row also holds a thrust indicator: '..row) end
 if row:find('FL THRUST',1,true) then first=y end
end
check(header and first and first>header,'FL THRUST must sit below the LATERALS heading')
''' % (width, height, height))


    def test_main_engine_power_value_is_separated_from_its_label(self):
        for width, height in ((57, 24), (80, 30), (100, 36)):
            with self.subTest(size=(width, height)):
                self.lua.execute('''
local ui,s,draw=fixture(%d,%d,'FLIGHT');running(s);draw()
local found
for y=1,%d do
 local row=ui.previous.rows[y].text
 if row:find('MAIN ENG. POWER',1,true) then found=row end
end
check(found,'main engine power row missing')
check(found:find('MAIN ENG. POWER  UNAVAIL',1,true),'label and value need a space: '..found)
''' % (width, height, height))


    def test_flight_chamber_header_reads_chambers(self):
        for width, height in ((57, 24), (80, 30), (100, 36)):
            with self.subTest(size=(width, height)):
                self.lua.execute('''
local ui,s,draw=fixture(%d,%d,'FLIGHT');running(s);draw()
local all={}
for y=1,%d do all[#all+1]=ui.previous.rows[y].text end
local text=table.concat(all,'\\n')
check(text:find('CHAMBERS',1,true),'chamber header missing')
check(not text:find('TARGET  LIFT',1,true),'old header still shown')
''' % (width, height, height))


# ======================================================================
# From test_stale_status_text: Stale data is named with its age once it has been stale for more than 10 s.
# ======================================================================
import re
import unittest

import project
from tests import test_builder as support

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


# ======================================================================
# From test_supervision_text: Propulsion stops with a message that says how long the core supervisor has been silent.
# ======================================================================
import unittest

import project
from tests import test_builder as support


class SupervisionTextTests(unittest.TestCase):
    def worker(self):
        lua, _ = support.native_runtime()
        source = (project.ROOT / "source/core/avionics/propulsion_worker.lua").read_text(encoding="utf-8")
        lua.execute("W=(function()\n" + source + "\nend)()")
        return lua

    def test_messages_name_the_cause(self):
        lua = self.worker()
        lua.execute('''
assert(W.supervisionText(10,nil)=="CORE SUPERVISION NEVER REPORTED; CHECK CORE")
assert(W.supervisionText(10,12)=="CORE SUPERVISION CLOCK WENT BACKWARDS; CHECK CORE")
assert(W.supervisionText(15,10)=="WAITING FOR CORE SUPERVISION")
assert(W.supervisionText(22.4,10)=="CORE SUPERVISION SILENT 12 S; SERVER LAG OR CORE STALL")
''')

    def test_step_stops_propulsion_with_that_text(self):
        lua = self.worker()
        lua.execute('''
local reason
local io={thrust={stop=function(self,io,r) reason=r end}}
W.step(io,{},22,10)
assert(reason=="CORE SUPERVISION SILENT 12 S; SERVER LAG OR CORE STALL",reason)
reason=nil;W.step(io,{},20,nil)
assert(reason=="CORE SUPERVISION NEVER REPORTED; CHECK CORE",reason)
''')


# ======================================================================
# From test_vent_balloon_hint: A vent without a balloon points at the boiler when the trim probe still sees one.
# ======================================================================
import re
import unittest

import project
from tests import test_builder as support


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


# ======================================================================
# From test_ap_request_labels: The bridge request line names AP's request while AP is engaged.
# ======================================================================
import re
import unittest

import project
from tests import test_builder as support

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
    import unittest
    unittest.main()
