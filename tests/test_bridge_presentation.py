"""Implementation 1: production bundled UI input, modal and wording checks."""
import hashlib
import json
from pathlib import Path
import unittest

from tests import test_runtime_bundling as support

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
        cls.source = support.b.collect_project(support.SOURCE)
        cls.ui_source = cls.source['library']['/packages/navigation/ui.lua']
        # Packing in memory tests the same production loader/file layout, without
        # creating a distributable installer or writing any live computer files.
        cls.source = support.bundle.prepare(cls.source, support.b.FOLDERS)
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
        (REPORT/'identity.json').write_text(json.dumps({'builderVersion':support.b.VERSION,
            'uiSHA256':hashlib.sha256(cls.ui_source).hexdigest(),'liveSaveModified':False,
            'installerBuiltForDistribution':False,'bridgePackageVersion':cls.source['versions']['navigator']},indent=2)+'\n')


if __name__=='__main__':
    unittest.main(verbosity=2)
