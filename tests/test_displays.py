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


class HeadingGraphicsTests(unittest.TestCase):
    """Exercise pixel writes and recovery against the production heading renderer."""

    def setUp(self):
        text = (project.ROOT / PATH).read_text(encoding="utf-8")
        start = text.index("local function finite(value)")
        end = text.index("local function say(message)")
        self.lua, _ = support.native_runtime()
        self.lua.execute("local timeout,pollInterval=2,0.25\nlocal config={}\n" +
                         text[start:end] + r'''
CFG=config
DRAW=drawToMonitor
LEAVE=leaveGraphics
PIXEL=Pixel
WRITES={}; MODES={}; BLITS=0; FROZEN=false; PIXEL_WIDTH=342; FAIL=false
MONITOR={
 getSize=function(mode) if mode then return PIXEL_WIDTH,90 end return 57,10 end,
 setGraphicsMode=function(mode) MODES[#MODES+1]=mode end,
 setFrozen=function(value) FROZEN=value end,
 drawPixels=function(x,y,rows)
  assert(x==0 and y>=0 and y+#rows<=90,'pixel bounds')
  for _,row in ipairs(rows)do
   assert(#row==PIXEL_WIDTH,'pixel row width')
   for i=1,#row do assert(row:byte(i)<=15,'mode 1 byte index') end
  end
  if FAIL then error('simulated peripheral failure') end
  WRITES[#WRITES+1]={x=x,y=y,rows=rows}
 end,
 setCursorPos=function()end,
 setBackgroundColor=function()end,
 clear=function()end,
 blit=function(text,fg,bg) assert(#text==#fg and #fg==#bg);BLITS=BLITS+1 end,
 write=function()BLITS=BLITS+1 end,
}
DISPLAY={monitor=MONITOR,display='center'}
SNAP={vessel={valid=true,heading=90,forwardSpeed=2,altitude=160,verticalSpeed=0},
 targets={heading=90,speed=3,altitude=160},modes={heading='SEL',throttle='SEL'},anchor='OFF'}
''')

    def test_batch_cache_resize_and_stale_frame(self):
        self.lua.execute('''
DRAW(DISPLAY,SNAP)
assert(#WRITES==1 and #WRITES[1].rows==90 and MODES[1]==1)
assert(not FROZEN and BLITS==0)
DRAW(DISPLAY,SNAP);assert(#WRITES==1 and #MODES==1,'unchanged frame sends no pixels')
PIXEL_WIDTH=348;DRAW(DISPLAY,SNAP)
assert(#WRITES==2 and #WRITES[2].rows==90,'resize repaints')
SNAP.displayStale=true;DRAW(DISPLAY,SNAP)
assert(#WRITES>2,'stale warning changes pixels')
assert(not FROZEN)
''')

    def test_graphics_failure_restores_text_and_stops_retrying(self):
        self.lua.execute('''
FAIL=true;DRAW(DISPLAY,SNAP)
assert(DISPLAY.graphicsFailed and MODES[#MODES]==0 and not FROZEN)
assert(BLITS>0 and DISPLAY.pixelRows==nil,'text frame replaces failed graphics')
local modes=#MODES;FAIL=false;DRAW(DISPLAY,SNAP)
assert(#MODES==modes and #WRITES==0,'failed backend waits for reattachment')
''')

    def test_missing_mod_and_explicit_text_use_existing_renderer(self):
        self.lua.execute('''
CFG.graphicsMode='text';DRAW(DISPLAY,SNAP)
assert(#MODES==0 and BLITS>0)
CFG.graphicsMode=nil;MONITOR.setGraphicsMode=nil;DISPLAY.previous=nil
DRAW(DISPLAY,SNAP);assert(#WRITES==0)
''')

    def test_exit_restores_text_and_clears_cached_frame(self):
        self.lua.execute('''
DRAW(DISPLAY,SNAP);assert(LEAVE(DISPLAY))
assert(MODES[#MODES]==0 and DISPLAY.pixelRows==nil and DISPLAY.previous==nil)
''')

    def test_native_tapes_keep_markers_and_handle_wrap_and_offscale_altitude(self):
        self.lua.execute('''
for _,glyph in pairs(PIXEL.font)do assert(#glyph==35,'five by seven font geometry')end
for _,pair in ipairs({'0O','1I','5S','8B'})do
 assert(PIXEL.font[pair:sub(1,1)]~=PIXEL.font[pair:sub(2,2)],'distinct instrument glyphs')
end
SNAP.targets.heading=0.1;SNAP.vessel.heading=359.9
SNAP.targets.altitude=290;SNAP.vessel.altitude=160
local image=assert(PIXEL.frame(SNAP,'center',57,10,342,90))
local rows=PIXEL.seal(image)
assert(#rows==90 and #rows[1]==342)
local gold,white=0,0
for _,row in ipairs(rows)do for x=1,#row do
 local byte=row:byte(x);if byte==4 then gold=gold+1 elseif byte==0 then white=white+1 end
end end
assert(gold>0 and white>0,'measured and target markers are both drawn')
SNAP.displayStale=true
assert(PIXEL.frame(SNAP,'center',57,10,342,90)==nil,'stale data uses existing warning renderer')
SNAP.displayStale=false;SNAP.fleetBoot={ready=false,phase='DISCOVERING'};SNAP.assembly={state='ASSEMBLED'}
assert(PIXEL.frame(SNAP,'center',57,10,342,90)==nil,'startup gates remain authoritative')
''')

    def test_flower_only_appears_for_fresh_disassembled_snapshot(self):
        self.lua.execute('''
SNAP.assembly={state='DISASSEMBLED'}
local image=assert(PIXEL.frame(SNAP,'center',57,10,342,90))
local purple=0
for _,row in ipairs(PIXEL.seal(image))do for x=1,#row do
 if row:byte(x)==10 then purple=purple+1 end
end end
assert(purple>100,'flower has visible purple petals')
SNAP.displayStale=true
assert(PIXEL.frame(SNAP,'center',57,10,342,90)==nil,'stale assembly cannot show fresh disassembled screen')
SNAP.displayStale=false;SNAP.assembly.state='UNKNOWN'
assert(PIXEL.frame(SNAP,'center',57,10,342,90)==nil,'unknown assembly retains its own warning')
''')

    def test_altitude_values_stay_above_and_below_tape(self):
        self.lua.execute('''
local original=PIXEL.text
local calls={}
PIXEL.text=function(image,x,y,value,index,scale,align,available)
 calls[#calls+1]={x=x,y=y,value=value,index=index,scale=scale,align=align}
 return original(image,x,y,value,index,scale,align,available)
end
SNAP.vessel.altitude=250.4
local lastY
for _,target in ipairs({270.4,250.4,230.4})do
 calls={};SNAP.targets.altitude=target
 assert(PIXEL.frame(SNAP,'center',57,10,342,90))
 local selected,current
 for _,call in ipairs(calls)do
  if call.value==string.format('%.1f',target)and call.index==4 then selected=call end
  if call.value=='250.4'and call.index==0 then current=call end
 end
 assert(selected and current,'both altitude values present')
 assert(not lastY or selected.y==lastY,'target readout stays below tape')
 assert(current.y<27 and selected.y>64,'current above tape and target below tape')
 assert(current.align=='center'and selected.align=='center'and current.x==selected.x,
  'altitude readouts share the section centre')
 lastY=selected.y
end
PIXEL.text=original
''')

    def test_native_heading_title_matches_selected_manual_and_ap_modes(self):
        self.lua.execute('''
local original=PIXEL.text
local title
PIXEL.text=function(image,x,y,value,index,scale,align,available)
 if x==5 and y==2 then title=value end
 return original(image,x,y,value,index,scale,align,available)
end
for mode,expected in pairs({SEL='SEL HDG',MANUAL=''})do
 SNAP.modes.heading=mode;SNAP.autopilot=nil
 assert(PIXEL.frame(SNAP,'center',57,10,342,90))
 assert(title==expected,'heading mode label')
end
SNAP.autopilot={active=true,state='DECEL',requestedHeading=90}
assert(PIXEL.frame(SNAP,'center',57,10,342,90))
assert(title=='AP - DECEL','AP state label')
PIXEL.text=original
''')

    def test_speedometer_retains_signed_and_above_scale_readouts(self):
        self.lua.execute('''
local original=PIXEL.text
local values={}
PIXEL.text=function(image,x,y,value,index,scale,align,available)
 values[value]=true
 return original(image,x,y,value,index,scale,align,available)
end
for _,speed in ipairs({0,28.5,-12.3,45.6})do
 local image=PIXEL.new(80,90);values={}
 PIXEL.speedometer(image,0,80,90,1,speed,29)
 assert(values[string.format('%.1f',speed)],'measured speed stays signed and unclamped')
 assert(values['b/s'],'speed unit visible')
end
values={};PIXEL.speedometer(PIXEL.new(80,90),0,80,90,1,nil,nil)
assert(values['--'],'invalid speed has no invented measurement')
PIXEL.text=original
''')

    def test_throttle_selector_uses_mode_specific_request_and_continuous_dividers(self):
        self.lua.execute('''
local original=PIXEL.text
local labels={}
PIXEL.text=function(image,x,y,value,index,scale,align,available)
 labels[value]=index
 return original(image,x,y,value,index,scale,align,available)
end
for _,case in ipairs({{'MANUAL','MAN THR','+0.12','b/s2'},
 {'SEL','SEL SPD','3.0','b/s'},{'DIRECT','DIR RPM','128','RPM'}})do
 labels={};SNAP.propulsion={mode=case[1],manualAcceleration=.12,directRpm=128}
 SNAP.modes.throttle=case[1]
 local image=assert(PIXEL.frame(SNAP,'center',57,10,342,90))
 assert(labels[case[2]] and labels[case[3]]==4 and labels[case[4]],'mode and selector units')
 for value in pairs(labels)do assert(not value:find('REQ ',1,true),'old request indicator removed')end
 local rows=PIXEL.seal(image)
 assert(rows[12]==string.rep(string.char(7),342),'upper divider continuous')
 assert(rows[80]:sub(1,69)==string.rep(string.char(7),69),'speed footer divider retained')
 assert(rows[80]:sub(71,274)==string.rep(string.char(15),204),'heading footer divider removed')
 assert(rows[80]:sub(275)==string.rep(string.char(7),68),'altitude footer divider retained')
end
PIXEL.text=original
''')

    def test_heading_transport_carries_requests_and_requires_verified_rpm(self):
        payload = (project.ROOT / 'source/core/avionics/display_payload.lua').read_text(encoding='utf-8')
        self.lua.globals().PAYLOAD = self.lua.execute(payload)
        self.lua.execute('''
local state={thrust={mode='DIRECT',request={manualAcceleration=.12,directRpm=128}},
 settings={thrust={directRpmVerified=false}}}
local packet=PAYLOAD.heading(state)
assert(packet.propulsion.mode=='DIRECT'and packet.propulsion.manualAcceleration==.12)
assert(packet.propulsion.directRpm==nil,'unverified rpm is withheld')
state.settings.thrust.directRpmVerified=true
assert(PAYLOAD.heading(state).propulsion.directRpm==128)
''')

    def test_ap_owns_header_and_colours_only_command_readouts_purple(self):
        self.lua.execute('''
local original=PIXEL.text
local labels={}
PIXEL.text=function(image,x,y,value,index,scale,align,available)
 labels[value]=index
 return original(image,x,y,value,index,scale,align,available)
end
SNAP.autopilot={active=true,state='CRUISE',requestedHeading=100,requestedSpeed=25,distance=3900,crossTrack=0}
SNAP.targets.altitude=215;SNAP.propulsion={mode='SEL'}
local rows=PIXEL.seal(assert(PIXEL.frame(SNAP,'center',57,10,342,90)))
local purple=0
for y=1,11 do for x=1,342 do
 local byte=rows[y]:byte(x)
 assert(byte==15 or byte==10,'header contains AP purple only')
 if byte==10 then purple=purple+1 end
end end
assert(purple>0 and labels['AP - CRUISE']==10)
assert(labels['100.0']==10 and labels['215.0']==10 and labels['25.0']==10,'AP targets purple')
assert(labels['160.0']==0,'measured altitude stays white')
SNAP.autopilot.active=false
labels={};PIXEL.frame(SNAP,'center',57,10,342,90)
assert(labels['AP - CRUISE']==nil and labels['215.0']==4,'pilot appearance restored')
PIXEL.text=original
''')

    def test_selected_strafe_scale_tracks_remaining_distance_and_ap_priority(self):
        self.lua.execute('''
local original=PIXEL.deviation
local called,value,colour,label
PIXEL.deviation=function(image,left,right,middle,height,small,remaining,index,detail)
 called=true;value=remaining;colour=index;label=detail
 return original(image,left,right,middle,height,small,remaining,index,detail)
end
SNAP.lateralControl={mode='SEL',active=true,state='MOVING'}
for _,remaining in ipairs({-25,-6.5,0,6.5,25})do
 SNAP.lateralControl.remaining=remaining;called=false
 assert(PIXEL.frame(SNAP,'center',57,10,342,90))
 assert(called and value==remaining and colour==4,'selected strafe distance and yellow marker')
 if remaining<0 then assert(label:find(' L ',1,true))end
 if remaining>0 then assert(label:find(' R ',1,true))end
end
SNAP.lateralControl.active=false;called=false
PIXEL.frame(SNAP,'center',57,10,342,90);assert(not called,'inactive strafe hides scale')
SNAP.lateralControl.active=true
SNAP.autopilot={active=true,state='CRUISE',crossTrack=-1.8,requestedHeading=90,requestedSpeed=20,distance=300}
PIXEL.frame(SNAP,'center',57,10,342,90)
assert(value==-1.8 and colour==0 and label:find('DEV ',1,true),'AP owns shared scale')
PIXEL.deviation=original
''')

    def test_native_layout_bounds_for_all_modes_and_monitor_sizes(self):
        self.lua.execute('''
for _,size in ipairs({{240,80},{342,90},{480,144},{684,180},{960,300}})do
 for _,heading in ipairs({0,0.1,180,359.9})do
  SNAP.vessel.heading=heading;SNAP.targets.heading=(heading+170)%360
  for _,mode in ipairs({'MANUAL','SEL','AP','RECOVERING'})do
   SNAP.modes.heading=mode
   SNAP.autopilot=(mode=='AP' or mode=='RECOVERING')and
    {active=true,state=mode=='AP'and'CRUISE'or'RECOVERING',requestedHeading=50,
     requestedSpeed=20,distance=3900,crossTrack=-11.8}or nil
   local image=assert(PIXEL.frame(SNAP,'center',57,10,size[1],size[2]))
   local rows=PIXEL.seal(image)
   assert(#rows==size[2])
   for _,row in ipairs(rows)do assert(#row==size[1])end
  end
 end
end
''')


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
label=bottom('OFF',{active=true,state='ACQ',cruiseSpeed=25,requestedSpeed=0})
assert(label:match("^REQ 0.0 b/s"),label)
label=bottom('OFF',{active=true,state='ACCEL',cruiseSpeed=25,requestedSpeed=4.5})
assert(label:match("^REQ 4.5 b/s"),label)
local retry=drawHorizontalHeading({
 vessel={valid=true,heading=90,forwardSpeed=2,altitude=160,verticalSpeed=0},
 autopilot={active=true,state='RETRYING (2)',requestedHeading=90,crossTrack=4,distance=50},
},57,10)
assert(retry.rows[1].fg[1]==color("yellow"),"AP retry uses the recovery color")
assert(table.concat(retry.rows[8].chars):find("WAITING FOR TELEMETRY",1,true))
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








class NavigatorGraphicsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.builder = project.builder_module()
        cls.source = cls.builder.collect_project(project.ROOT)
        cls.packed = cls.builder.bundling.prepare(cls.source, cls.builder.FOLDERS)

    def runtime(self):
        lua, _ = support.native_runtime()
        bundle = self.packed['library']['/packages/navigation/main.lua'].decode()
        lua.globals().UI = lua.execute(bundle, self.builder.bundling.MAGIC, '/avionics/ui.lua')
        lua.execute(NAV_PIXEL_HARNESS)
        return lua

    def test_all_pages_modes_and_editors_render_in_bounds(self):
        self.runtime().execute("""
for _,size in ipairs({{342,216},{456,288},{600,324}}) do
 for _,page in ipairs({'FLIGHT','NAV','SHIP','SETTINGS'}) do
  local ui,s,m=navFixture(size[1],size[2],page)
  for _,ship in ipairs({'LIFT','PROP','TRIM'}) do
   ui.shipView=ship;assert(ui:draw(s))
  end
  for _,mode in ipairs({'single','route'}) do
   ui.navSection='ADVANCED';ui.navMode=mode;assert(ui:draw(s))
  end
  ui:openEditor('x','X',704,{type='ap_edit',key='x'});assert(ui:draw(s))
  ui:openEditor('name','NAME','Harbour',{type='ap_edit',key='name'});assert(ui:draw(s))
 end
end
""")

    def test_current_and_next_waypoint_and_chevrons(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'NAV')
s.autopilot.active=true;s.autopilot.state='CRUISE'
s.autopilot.route={kind='waypoints',index=1,entries={{name='ONE',x=1,z=2},{name='TWO',x=3,z=4}}}
assert(ui:draw(s));assert(hasText('ONE') and hasText('NEXT TWO'))
assert(hasText('AP - CRUISE') and not hasText('SYSTEMS ONLINE'))
assert(not hasText('ENGAGE AP') and not hasText('MAIN'))
s.autopilot.route.index=2;assert(ui:draw(s));assert(hasText('TWO') and not hasText('NEXT '))
""")

    def test_stale_actions_and_resize_are_rejected(self):
        self.runtime().execute("""
local ui,s,m=navFixture(342,216,'NAV');assert(ui:draw(s))
s.displayStale=true
assert(ui:touch(100,183,s)==nil)
s.displayStale=false;assert(ui:draw(s));m.width=456
assert(ui:touch(100,183,s)==nil,'resize invalidates old hit regions')
""")

    def test_kill_modal_captures_touch_and_expires(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'SHIP');assert(ui:draw(s))
ui.systemsMenu=true;assert(ui:draw(s))
assert(hasText('KILL LIFT') and not hasText('RECOVER LIFT'))
ui:touch(250,101,s);assert(ui.killReview)
assert(ui:draw(s));assert(hasText('Locks Systems until disarmed.'))
assert(ui:touch(100,200,s)==nil,'modal captures footer')
s.displayStale=true;assert(ui:touch(240,170,s)==nil)
s.displayStale=false;NOW=12;assert(ui:draw(s));assert(not ui.killReview)
ui.killReview=NOW;assert(ui:draw(s))
local action=ui:touch(240,170,s);assert(action.type=='emergency_kill_lift')
""")

    def test_editor_commit_and_route_order_controls(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'NAV')
ui:openEditor('x','X',0,{type='ap_edit',key='x'})
ui:editorKey('CLEAR');ui:editorKey('-');ui:editorKey('7')
local a=ui:editorKey('SAVE');assert(a.type=='ap_edit' and a.value==-7)
ui.navSection='ADVANCED';ui.navMode='route';assert(ui:draw(s))
assert(hasText('START ROUTE') and not hasText('START HERE'))
a=ui:touch(100,184,s);assert(a.type=='ap_route_engage' and a.index==nil)
""")

    def test_emergency_and_mode_actions_revalidate_current_locks(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'FLIGHT');assert(ui:draw(s))
s.fleetBoot={ready=false,reason='COMMISSIONING'}
assert(ui:activate({type='cockpit_mode',axis='heading',mode='SEL'},s)==nil)
assert(ui:activate({type='systems_stop'},s).type=='systems_stop')
s.emergencyLift={pending=true}
assert(ui:activate({type='emergency_kill_lift'},s)==nil)
s.emergencyLift={latched=true,disarming=true}
assert(ui:activate({type='disarm_lift_kill'},s)==nil)
s.fleetBoot={ready=true};s.emergencyLift={}
s.autopilot.active=true
assert(ui:activate({type='cockpit_mode',axis='heading',mode='MANUAL'},s)==nil)
assert(ui:activate({type='ap_disengage'},s).type=='ap_disengage')
""")

    def test_dropdown_captures_background_and_sensor_validity(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'FLIGHT');ui.systemsMenu=true;assert(ui:draw(s))
assert(ui:touch(40,207,s)==nil and not ui.systemsMenu,'outside click closes without activating footer')
s.vessel.validFields={heading=false};assert(ui:draw(s));assert(hasText('HDG --'))
s.faults={'FL CHECK BOILER'};assert(ui:draw(s));assert(hasText('FL CHECK BOILER'))
s.page='SETTINGS';ui.settingsView='GENERAL';assert(ui:draw(s))
assert(hasText('FL CHECK BOILER'))
""")

    def test_settings_pagination_preserves_all_groups(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'SETTINGS')
s.settings={entries={}}
for i=1,11 do s.settings.entries[i]={group='PROPULSION',key='P'..i,label='P'..i,value=i,min=0,max=100,step=1} end
ui.settingsView='PROPULSION';assert(ui:draw(s));assert(ui.settingsPageSize==3)
ui:activate({localAction='settings_page',count=11},s);assert(ui.settingsOffset==3)
assert(ui:draw(s));assert(hasText('P4') and hasText('P6') and not hasText('P3'))
ui.settingsView='TARGET';assert(ui:draw(s));assert(hasText('GENERAL LIMITS'))
ui.settingsView='PID';assert(ui:draw(s));assert(hasText('TRIM PID'))
ui.settingsView='NAV';assert(ui:draw(s));assert(hasText('DIGITAL ANCHOR'))
ui.settingsView='ANCHOR';s.anchorControl={available=true,point={x=12,z=13},horizontalSpeed=.2}
assert(ui:draw(s));assert(hasText('ENGAGE ANCHOR') and hasText('X 12.0 Z 13.0'))
""")

    def test_small_or_unsupported_monitors_fail_explicitly(self):
        self.runtime().execute("""
local ui,s=navFixture(240,80,'FLIGHT');local ok,why=ui:draw(s)
assert(not ok and why=='NAVIGATOR NEEDS 342 X 216 PIXELS')
local renderer,reason=UI.new({getSize=function()return 57,24 end},{})
assert(renderer==nil and reason=='NAVIGATOR REQUIRES CC: GRAPHICS')
""")

    def test_speed_trend_and_propeller_follow_fresh_samples(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'FLIGHT')
s.vessel.at=1;local trend=ui:speedTrend(s);assert(trend=='--')
s.vessel.at=2;s.vessel.forwardSpeed=5;trend=ui:speedTrend(s);assert(trend=='UP')
local slope=ui.speedSlope;ui:speedTrend(s);assert(ui.speedSlope==slope,'same sample retains trend')
s.displayStale=true;trend=ui:speedTrend(s);assert(trend=='--' and ui.speedSlope==nil)
s.displayStale=false;s.thrust={units={['primary-left']={online=true,statusFresh=true,readings={{speedRaw=128,validity={speedRaw=true}}}}}}
assert(ui:draw(s));NOW=2;assert(ui:draw(s));local angle=ui.propellerAngles.left;assert(angle>0)
s.thrust.units['primary-left'].statusFresh=false;NOW=3;assert(ui:draw(s));assert(ui.propellerAngles.left==angle)
""")

    def test_flight_chambers_separate_readiness_and_control_states(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'FLIGHT')
s.nodes={FL={online=true,ready=true,thrustControlState='RDY',liftControlState='CMD',faults={}}}
assert(ui:draw(s));assert(hasText('ONLINE') and hasText('THR RDY') and hasText('LIFT CMD'))
assert(hasText('GAS '))
s.nodes.FL.liftControlState='FAULT';s.nodes.FL.ready=false
assert(ui:draw(s));assert(hasText('LIFT FAULT'))
s.displayStale=true;assert(ui:draw(s));assert(hasText('OFFLINE') and hasText('THR FAULT') and not hasText('THR RDY'))
""")

    def test_flight_gas_uses_balloon_inventory_instead_of_provider_flow(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'FLIGHT')
s.nodes={FL={online=true,ready=true,thrustControlState='RDY',liftControlState='CMD',
 balloon={hasBalloonValid=true,hasBalloon=true,gasMixValid=true,gasMixAmount=38285},
 providers={steam={gasOutputValid=true,gasOutput=.12,targetValid=true,targetAmount=40000}}}}
assert(ui:draw(s));assert(hasText('GAS 38285') and not hasText('GAS 0.12'))
s.nodes.FL.balloon.gasMixValid=false;assert(ui:draw(s));assert(not hasText('GAS 38285'))
s.nodes.FL.balloon.gasMixValid=true;s.nodes.FL.balloon.gasMixAmount=0
assert(ui:draw(s));assert(hasText('GAS 0'))
s.displayStale=true;assert(ui:draw(s));assert(not hasText('GAS 0'))
""")

    def test_engine_health_distinguishes_missing_and_temporary_loss(self):
        self.runtime().execute("""
local ui,s=navFixture(342,216,'FLIGHT')
s.thrust={units={['primary-left']={discovered=false},['primary-right']={discovered=true,online=false,statusFresh=false}}}
assert(ui:engineTone(s,'left')=='red' and ui:engineTone(s,'right')=='yellow')
assert(ui:draw(s))
s.displayStale=true;assert(ui:engineTone(s,'left')=='yellow')
s.displayStale=false;s.thrust.units['primary-left']={discovered=true,online=true,statusFresh=true,available=false,readings={}}
assert(ui:engineTone(s,'left')=='red')
s.thrust.units['primary-left']={discovered=true,online=true,statusFresh=true,available=true,readings={{speedRaw=0,validity={speedRaw=true}}}}
assert(ui:engineTone(s,'left')=='white','stopped engine remains healthy')
""")

    def test_header_and_frames_are_cached(self):
        self.runtime().execute("""
local ui,s,m=navFixture(342,216,'SHIP');assert(ui:draw(s))
assert(hasText('A.E.V. AMARYLLIS') and hasText('SYSTEMS ONLINE'))
local count=WRITES;assert(ui:draw(s));assert(WRITES==count)
ui:close();assert(MODE==0)
""")

NAV_PIXEL_HARNESS=r"""
NOW=1;os.clock=function()return NOW end
TEXTS={};WRITES=0;MODE=0
local original=UI.Pixel.text
UI.Pixel.text=function(self,x,y,value,...)
 TEXTS[#TEXTS+1]=tostring(value);return original(self,x,y,value,...)
end
function hasText(value)
 for _,text in ipairs(TEXTS) do if text:find(value,1,true) then return true end end
 return false
end
function navFixture(width,height,page)
 local m={width=width,height=height,getSize=function()return width,height end,
  setTextScale=function()end,setGraphicsMode=function(v)MODE=v end,setFrozen=function()end,
  setPaletteColor=function()end}
 m.getSize=function()return m.width,m.height end
 m.drawPixels=function(x,y,rows,w,h)
  WRITES=WRITES+1
  if type(rows)=='table' then
   assert(x>=0 and y>=0 and y+#rows<=m.height)
   for _,row in ipairs(rows) do assert(x+#row<=m.width);for i=1,#row do assert(row:byte(i)<=15)end end
  end
 end
 local ui=assert(UI.new(m,{}));ui.page=page
 local s={page=page,dataFresh=true,vessel={valid=true,heading=90,forwardSpeed=3,altitude=210,verticalSpeed=0,pitch=0,roll=0},
  systemsStartup={active=true,phase='READY',available=false},systemsRestart={available=true},
  modes={heading='SEL',throttle='SEL',lateral='MANUAL'},targets={heading=90,speed=3,altitude=210},
  cockpitControl={available=true},autopilot={active=false,available=true,destination={name='HOME',x=1,z=2,altitude=210,cruiseSpeed=3},
  library={writable=true,entries={{name='ONE',x=1,z=2},{name='TWO',x=3,z=4}}},
  playlist={{name='ONE',x=1,z=2,altitude=210,cruiseSpeed=3},{name='TWO',x=3,z=4,altitude=250,cruiseSpeed=5}}},faults={}}
 local oldDraw=ui.draw
 ui.draw=function(self,snapshot)TEXTS={};return oldDraw(self,snapshot)end
 return ui,s,m
end
"""


if __name__ == "__main__":
    unittest.main()
