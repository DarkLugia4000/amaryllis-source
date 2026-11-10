"""Disk, web and live-update installers."""

# ======================================================================
# From test_disk_setup: Real keyboard commissioning and assignment-reset transactions in isolated memory.
# ======================================================================
from pathlib import Path
import copy
import json
import tempfile
import unittest
import project
from tests.test_builder import native_runtime, table, python_value

ROOT = Path(__file__).resolve().parents[1]
HOME = ROOT / "disk-builder"
DISK_KEYS = {'left':203,'right':205,'up':200,'down':208,'enter':28,'escape':1,'numPadEnter':156}
_CACHE = ROOT / '.cache'
_CACHE.mkdir(exist_ok=True)
_MEDIA_TEMP = tempfile.TemporaryDirectory(prefix='disk-setup-', dir=_CACHE)
DISK_MEDIA, _ = project.builder_module().build(project.ROOT, Path(_MEDIA_TEMP.name))
DISK_MEDIA = DISK_MEDIA / 'media'
BIOS_PRINT = """
function print(...) end
function printError(...) end
"""

TERMINAL = r"""
screen={width=51,height=19,x=1,y=1,fg=1,bg=32768,rows={},foreground={},background={}}
local function color(c)for n=0,15 do if c==2^n then return("0123456789abcdef"):sub(n+1,n+1)end end;return"0"end
local function blank(y)
 screen.rows[y]=string.rep(" ",screen.width)
 screen.foreground[y]=string.rep(color(screen.fg),screen.width)
 screen.background[y]=string.rep(color(screen.bg),screen.width)
end
term={}
function term.getSize()return screen.width,screen.height end
function term.getCursorPos()return screen.x,screen.y end
function term.setCursorPos(x,y)screen.x,screen.y=x,y end
function term.setTextColor(c)screen.fg=c end
term.setTextColour=term.setTextColor
function term.setBackgroundColor(c)screen.bg=c end
function term.getTextColour()return screen.fg end
function term.isColour()return true end
function term.setCursorBlink()end
function term.clear()for y=1,screen.height do blank(y)end end
function term.write(text)
 text=tostring(text);local y=screen.y
 for n=1,#text do
  local x=screen.x+n-1
  if y>=1 and y<=screen.height and x>=1 and x<=screen.width then
   local function put(row,c)return row:sub(1,x-1)..c..row:sub(x+1)end
   screen.rows[y]=put(screen.rows[y],text:sub(n,n))
   screen.foreground[y]=put(screen.foreground[y],color(screen.fg))
   screen.background[y]=put(screen.background[y],color(screen.bg))
  end
 end
 screen.x=screen.x+#text
end
function term.scroll(n)
 for y=1,screen.height-n do
  screen.rows[y]=screen.rows[y+n];screen.foreground[y]=screen.foreground[y+n];screen.background[y]=screen.background[y+n]
 end
 for y=screen.height-n+1,screen.height do blank(y)end
end
term.clear()
colors={red=16384};expect=function()end
keys={left=203,right=205,up=200,down=208,enter=28,numPadEnter=156,escape=1}
os.pullEvent=function()
 local e,a=coroutine.yield("INPUT")
 if e=="terminate"then error("Terminated")end
 return e,a
end
read=function()error("Keyboard UI must not call read()")end
sleep=function()end
"""

class Fixture:
    def __init__(self,identity=27,assignments=None,local_role=None,imported=False,pending=False,disk=None,local_files=None,release_override=None):
        """Initialize the real installer with a terminal and isolated computer/disk records."""
        self.release=copy.deepcopy(release_override or json.loads((DISK_MEDIA/'release.json').read_bytes()))
        self.roles=self.release['roles'];self.id=identity
        files={('/disk/'+p.relative_to(DISK_MEDIA).as_posix()):p.read_bytes().decode('utf-8') for p in DISK_MEDIA.rglob('*')if p.is_file()}
        if disk is not None:files={k:v for k,v in disk.items()if k.startswith('/disk/')}
        self.lua,self.files=native_runtime(files)
        self.lua.execute(TERMINAL);self.lua.execute(BIOS_PRINT)
        self.labels=[]
        self.lua.globals().os.getComputerID=lambda:self.id
        self.lua.globals().os.getComputerLabel=lambda:self.labels[-1]if self.labels else self.roles.get(local_role or '',{}).get('label','')
        self.lua.globals().os.setComputerLabel=self.labels.append
        self.lua.globals().printError=self.lua.eval('printError')
        self.lua.globals().textutils=self.lua.table_from({
            'unserializeJSON':lambda raw:table(self.lua,json.loads(raw)),
            'serializeJSON':lambda value:json.dumps(python_value(value),sort_keys=True,separators=(',',':'))})
        self.lua.globals().shell=self.lua.table_from({'run':lambda *args:True})
        self.writes=[]
        original_open=self.lua.globals().fs.open
        def opened(path,mode):
            if mode in ('w','wb'):self.writes.append(path)
            return original_open(path,mode)
        self.lua.globals().fs.open=opened
        def move(a,b):
            assert b not in self.files,'fs.move must not overwrite an existing file'
            self.files[b]=self.files.pop(a)
        self.lua.globals().fs.move=move
        if disk is None:
            assigned={'core':{'id':0,'label':self.roles['core']['label']}}
            for role,cid in (assignments or {}).items():assigned[role]={'id':cid,'label':self.roles[role]['label']}
            self.files['/disk/deployment.json']=json.dumps({'schemaVersion':1,'releaseId':self.release['releaseId'],
                'assignmentRevision':0,'imported':imported,'computers':assigned})
        if local_role is not None:
            self.files['/amaryllis-install.json']=json.dumps({'releaseId':self.release['releaseId'],'role':local_role,'id':identity,'pending':pending})
            self.files['/config.json']=json.dumps({'target_role':'auto','core_id':0})
        self.files.update(local_files or {})
        self.lua.globals().setup=self.lua.execute((HOME/'assets/setup.lua').read_text(encoding='utf-8'))
        self.lua.execute("""
        co=coroutine.create(function()setup.main("/disk")end)
        function step(e,k)
            local ok,value=coroutine.resume(co,e,k);assert(ok,value)
            return coroutine.status(co)
        end
        """)
        self.lua.globals().step()

    def key(self,name,count=1):
        for _ in range(count):self.lua.globals().step('key',DISK_KEYS[name])
        return self
    def event(self,event,arg=None):
        self.lua.globals().step(event,arg);return self
    def text(self):
        return '\n'.join(python_value(self.lua.globals().screen)['rows'])
    def frame(self):
        return python_value(self.lua.globals().screen)
    def deployment(self):
        return json.loads(self.files['/disk/deployment.json'])
    def disk(self):
        return {k:v for k,v in self.files.items()if k.startswith('/disk/')}
    def local(self):
        return {k:v for k,v in self.files.items()if not k.startswith('/disk/')}
    def yes(self):
        return self.key('left').key('enter')

class ResetTests(unittest.TestCase):
    def core(self):
        """Create a complete registered fleet with retained program and lift records."""
        roles=json.loads((DISK_MEDIA/'release.json').read_bytes())['roles']
        assignments={role:number for number,role in enumerate(roles,40) if role!='core'}
        f=Fixture(identity=0,assignments=assignments,local_role='core')
        f.files['/fleet.json']=json.dumps({'schemaVersion':1,'computers':f.deployment()['computers']})
        f.files['/fleet.json.bak']=f.files['/fleet.json']
        f.files['/fleet.json.tmp']='old staging'
        f.files['/startup.lua']='return "retained startup"'
        f.files['/avionics/main.lua']='return "retained application"'
        f.files['/avionics/config.json']=json.dumps({'computer_id':0,'thrust':{'enabled':True}})
        f.files['/avionics/data/hover-offset.json']='retained learning'
        f.files['/avionics/data/restart.json']='retained lift checkpoint'
        f.files['/disk/role-repair.json']=json.dumps({'pending':True})
        f.lua.execute('peripheral=setmetatable({},{__index=function()error("Unexpected actuator access")end});redstone=peripheral')
        return f

    def reset(self,f):
        """Execute the actual reset API against the selected simulated core."""
        f.lua.globals().setup.unassignCore('/disk',table(f.lua,f.release),f.id)

    def test_core_action_is_red_and_confirmation_defaults_cancel(self):
        """Verify core action is red and confirmation defaults cancel."""
        f=self.core();f.key('down')
        self.assertIn('> Unassign core',f.text())
        row=next(i for i,r in enumerate(f.frame()['rows']) if '> Unassign core' in r)
        self.assertEqual(f.frame()['foreground'][row][3:16],'e'*13)
        before=dict(f.files);f.key('enter')
        self.assertIn('Reset installation?',f.text())
        self.assertIn('> CANCEL',f.text())
        self.assertIn('register all 16 computers again',' '.join(f.text().split()))
        f.key('enter')
        self.assertEqual(f.files,before)

    def test_confirmed_reset_clears_assignments_and_backups_preserving_lift_data(self):
        """Verify confirmed reset clears assignments and backups preserving lift data."""
        f=self.core();before=dict(f.files)
        f.key('down').key('enter').yes()
        self.assertIn('Installation reset',f.text())
        state=f.deployment()
        self.assertEqual(state['computers'],{})
        self.assertFalse(state['imported']);self.assertFalse(state['reset']['pending'])
        self.assertEqual(state['assignmentRevision'],0)
        for name in ('/fleet.json','/fleet.json.bak','/fleet.json.tmp','/disk/role-repair.json'):
            self.assertNotIn(name,f.files)
        for name,value in before.items():
            if name.startswith('/disk/') or name.startswith('/fleet.json'):continue
            self.assertEqual(f.files[name],value,name)
        f.key('enter');self.assertIn('Install core',f.text())
        self.assertNotIn('Unassign core',f.text())

    def test_core_install_is_single_use_but_interrupted_install_can_resume(self):
        """Verify core install is single use but interrupted install can resume."""
        f=self.core();before=dict(f.files)
        with self.assertRaisesRegex(Exception,'already assigned'):
            f.lua.globals().setup.installCore('/disk',table(f.lua,f.release),0)
        self.assertEqual(f.files,before)
        self.reset(f)
        f.lua.globals().setup.installCore('/disk',table(f.lua,f.release),0)
        for name in ('/startup.lua','/avionics/main.lua','/avionics/config.json','/avionics/data/restart.json'):
            self.assertEqual(f.files[name],before[name])
        self.assertEqual(f.deployment()['computers']['core']['id'],0)
        with self.assertRaisesRegex(Exception,'already assigned'):
            f.lua.globals().setup.installCore('/disk',table(f.lua,f.release),0)

    def test_wrong_computer_and_running_core_cannot_reset(self):
        """Verify wrong computer and running core cannot reset."""
        f=self.core();before=dict(f.files)
        with self.assertRaisesRegex(Exception,'Insert this disk into core #0'):
            f.lua.globals().setup.unassignCore('/disk',table(f.lua,f.release),27)
        f.lua.globals().os["__amaryllisFleetRegistry"]=f.lua.table()
        with self.assertRaisesRegex(Exception,"Close core's runtime"):
            self.reset(f)
        self.assertEqual(f.files,before)

    def test_read_only_disk_cannot_start_reset(self):
        f=self.core();before=dict(f.files)
        f.lua.globals().fs.isReadOnly=lambda p:p=='/disk'
        with self.assertRaisesRegex(Exception,'must be writable'):self.reset(f)
        self.assertEqual(f.files,before)

    def test_interrupted_reset_resumes_from_its_persisted_disk_record(self):
        """Verify interrupted reset resumes from its persisted disk record."""
        f=self.core();remove=f.lua.globals().fs.delete
        def fail_once(path):
            if path=='/fleet.json.bak':raise OSError('injected reset interruption')
            remove(path)
        f.lua.globals().fs.delete=fail_once
        with self.assertRaisesRegex(Exception,'injected reset interruption'):self.reset(f)
        self.assertTrue(f.deployment()['reset']['pending'])
        with self.assertRaisesRegex(Exception,'Finish resetting'):
            f.lua.globals().setup.installCore('/disk',table(f.lua,f.release),0)
        g=Fixture(identity=0,disk=f.disk(),local_files=f.local())
        self.assertIn('Resume installation reset',g.text())
        self.reset(g)
        self.assertFalse(g.deployment()['reset']['pending'])
        self.assertNotIn('/fleet.json.bak',g.files)

    def test_complete_existing_fleet_can_register_again_and_import(self):
        """Verify complete existing fleet can register again and import."""
        f=self.core();previous=copy.deepcopy(f.deployment()['computers'])
        self.reset(f)
        f.lua.globals().setup.installCore('/disk',table(f.lua,f.release),0)
        disk=f.disk()
        for role,entry in previous.items():
            if role=='core':continue
            retained={'/startup.lua':'retained startup','/avionics/main.lua':'retained program',
                '/avionics/config.json':'{"saved":true}','/avionics/data/calibration.json':'retained calibration'}
            g=Fixture(identity=entry['id'],local_role=role,disk=disk,local_files=retained)
            bootstrap=g.files['/config.json']
            g.lua.globals().setup.installAuxiliary('/disk',table(g.lua,g.release),role,entry['id'])
            for path,value in retained.items():self.assertEqual(g.files[path],value)
            self.assertEqual(g.files['/config.json'],bootstrap)
            disk=g.disk()
        f.files.update(disk)
        f.lua.globals().setup.importFleet('/disk',table(f.lua,f.release),0)
        self.assertEqual(json.loads(f.files['/fleet.json'])['computers'],previous)
        self.assertTrue(f.deployment()['imported'])
        self.assertNotIn('reset',f.deployment())

    def test_other_computer_directed_to_registered_core(self):
        f=Fixture();f.key('down')
        self.assertIn('Unassign core',f.text())
        self.assertIn('Insert this disk into core #0',f.text())
        before=dict(f.files);f.key('enter');self.assertEqual(f.files,before)


class KeyboardInstallerTests(unittest.TestCase):
    def test_left_right_pages_up_down_focus_and_wrap(self):
        """Verify left right pages up down focus and wrap."""
        f=Fixture();self.assertIn('< Setup  1/6 >',f.text())
        f.key('right');self.assertIn('< Chambers  2/6 >',f.text());self.assertIn('> chamber-fl',f.text())
        f.key('down');self.assertIn('> chamber-fr',f.text())
        f.key('right');self.assertIn('< Thrust  3/6 >',f.text())
        f.key('left');self.assertIn('> chamber-fr',f.text())
        f.key('left',2);self.assertIn('< Assignments  6/6 >',f.text())
        f.key('right');self.assertIn('< Setup  1/6 >',f.text())

    def test_char_input_does_not_choose_or_confirm(self):
        f=Fixture();before=dict(f.files)
        f.event('char','A').event('char','chamber-fl')
        self.assertIn('< Setup',f.text());self.assertEqual(f.files,before)
        f.key('right').key('enter');self.assertIn('> NO',f.text())
        f.event('char','YES').key('enter')
        self.assertEqual(f.files,before);self.assertEqual(f.writes,[])

    def test_confirmation_defaults_no_and_right_cancels(self):
        f=Fixture();before=dict(f.files)
        f.key('right').key('enter')
        self.assertIn('Register computer',f.text());self.assertIn('> NO',f.text())
        f.key('left');self.assertIn('> YES',f.text())
        f.key('right').key('enter');self.assertIn('< Chambers',f.text());self.assertEqual(f.files,before)

    def test_enter_confirms_selected_role_and_real_bootstrap_install(self):
        """Verify enter confirms selected role and real bootstrap install."""
        f=Fixture();f.key('right').key('down').key('enter').yes()
        self.assertIn('Computer registered',f.text())
        self.assertEqual(f.deployment()['computers']['chamber_fr']['id'],27)
        self.assertEqual(json.loads(f.files['/amaryllis-install.json'])['role'],'chamber_fr')
        self.assertFalse(json.loads(f.files['/amaryllis-install.json'])['pending'])
        self.assertIn('/installer/commissioning.lua',f.files)
        self.assertEqual(f.labels[-1],f.roles['chamber_fr']['label'])
        f.key('enter');self.assertIn('Already assigned to #27.',f.text())

    def test_assigned_chamber_is_gray_inspectable_and_cannot_activate(self):
        """Verify assigned chamber is gray inspectable and cannot activate."""
        f=Fixture(assignments={'chamber_fl':9});before=dict(f.files)
        f.key('right')
        self.assertIn('Already assigned to #9.',f.text())
        frame=f.frame()
        self.assertEqual(frame['foreground'][6][3:17],'7'*14)
        f.key('enter')
        self.assertIn('< Chambers',f.text());self.assertNotIn('Register computer',f.text())
        self.assertEqual(f.files,before);self.assertEqual(f.writes,[])
        f.key('down').key('enter');self.assertIn('Assign chamber-fr',f.text())

    def test_all_assigned_auxiliary_groups_prevent_duplicate_registration(self):
        roles=['chamber_fl','primary_l','navigator','state']
        for page,role in zip([1,2,3,4],roles):
            f=Fixture(assignments={role:33});f.key('right',page)
            self.assertIn('Already assigned to #33.',f.text())
            before=dict(f.files);f.key('enter');self.assertEqual(f.files,before);self.assertEqual(f.writes,[])

    def test_merged_assignments_list_has_all_expected_roles_ids_and_placeholders(self):
        """Verify merged assignments list has all expected roles ids and placeholders."""
        f=Fixture(assignments={'chamber_fl':9,'state':1})
        f.key('left');self.assertIn('< Assignments  6/6 >',f.text())
        self.assertIn('core',f.text());self.assertIn('#0',f.text());self.assertIn('chamber-fl',f.text())
        seen=set()
        names=set(['core','state','bridge','hdg-l','hdg-r','hdg-m','chamber-fl','chamber-fr','chamber-bl','chamber-br',
                   'primary-l','primary-r','thrust-lb','thrust-rb','thrust-ls','thrust-rs'])
        for _ in range(16):
            text=f.text()
            for name in names:
                if name in text:seen.add(name)
            f.key('down')
        self.assertEqual(seen,names);self.assertIn(' - ',f.text())
        self.assertIn('state',f.text());self.assertIn('#1',f.text())

    def test_unassigned_computer_cannot_relabel_other_computers_from_assignments(self):
        f=Fixture(assignments={'chamber_fl':9});before=dict(f.files)
        f.key('left').key('down',5).key('enter')
        self.assertIn('No local assignment',f.text());self.assertEqual(f.files,before)

    def test_one_computer_correction_uses_assignment_screen_and_keeps_bootstrap_trust(self):
        """Verify one computer correction uses assignment screen and keeps bootstrap trust."""
        f=Fixture(assignments={'thrust-lb':27},local_role='thrust-lb')
        trust=f.files['/config.json']
        f.key('left').key('down',5).key('enter')
        self.assertIn('Save assignment correction',f.text());self.assertIn('thrust-lb -> chamber-fl',f.text())
        f.yes()
        self.assertIn('Assignment correction',f.text())
        self.assertEqual(f.deployment()['computers']['chamber_fl']['id'],27)
        self.assertNotIn('thrust-lb',f.deployment()['computers'])
        self.assertEqual(json.loads(f.files['/amaryllis-install.json'])['role'],'chamber_fl')
        self.assertEqual(f.files['/config.json'],trust)
        self.assertFalse(json.loads(f.files['/disk/role-repair.json'])['pending'])

    def test_swap_requires_both_computers_and_can_finish_from_merged_screen(self):
        """Verify swap requires both computers and can finish from merged screen."""
        f=Fixture(assignments={'thrust-lb':27,'chamber_fl':28},local_role='thrust-lb')
        f.key('left').key('down',5).key('enter')
        self.assertIn('#28: chamber-fl -> thrust-lb',f.text())
        f.yes()
        self.assertTrue(json.loads(f.files['/disk/role-repair.json'])['pending'])
        self.assertEqual(f.deployment()['computers']['thrust-lb']['id'],27)
        g=Fixture(identity=28,local_role='chamber_fl',disk=f.disk())
        g.key('left').key('enter')
        self.assertIn('Assignment correction',g.text());self.assertIn('Apply correction',g.text())
        g.key('enter').yes()
        self.assertFalse(json.loads(g.files['/disk/role-repair.json'])['pending'])
        self.assertEqual(g.deployment()['computers']['chamber_fl']['id'],27)
        self.assertEqual(g.deployment()['computers']['thrust-lb']['id'],28)

    def test_imported_and_installed_assignments_stay_locked(self):
        for imported,existing in [(True,{}),(False,{'/avionics/main.lua':'return true'})]:
            f=Fixture(assignments={'thrust-lb':27},local_role='thrust-lb',imported=imported,local_files=existing)
            before=dict(f.files);f.key('left').key('down',5).key('enter')
            self.assertIn('Correction unavailable',f.text());self.assertEqual(f.files,before)

    def test_pending_registration_on_same_computer_can_resume(self):
        f=Fixture(assignments={'chamber_fl':27},local_role='chamber_fl',pending=True)
        f.key('right');self.assertIn('Resume this computer',f.text())
        f.key('enter').yes()
        self.assertFalse(json.loads(f.files['/amaryllis-install.json'])['pending'])
        self.assertIn('/startup.lua',f.files)

    def test_new_core_install_through_keyboard_ui_preserves_propulsion_disabled(self):
        """Verify new core install through keyboard ui preserves propulsion disabled."""
        f=Fixture(identity=0)
        deployment=f.deployment();deployment['computers']={}
        f.files['/disk/deployment.json']=json.dumps(deployment)
        f.key('down').key('enter').yes()
        self.assertIn('Core installed',f.text())
        cfg=json.loads(f.files['/avionics/config.json'])
        self.assertEqual(cfg['computer_id'],0);self.assertFalse(cfg['thrust']['enabled'])
        self.assertFalse(json.loads(f.files['/amaryllis-install.json'])['pending'])
        self.assertIn('/fleet.json',f.files)

    def test_state_reader_can_be_installed_from_its_page(self):
        f=Fixture();f.key('right',4).key('enter').yes()
        self.assertEqual(f.deployment()['computers']['state']['id'],27)
        self.assertEqual(json.loads(f.files['/avionics/config.json'])['role'],'state')
        self.assertIn('/startup.lua',f.files)

    def test_interrupted_registration_is_resumable_from_the_same_gray_role_page(self):
        """Verify interrupted registration is resumable from the same gray role page."""
        f=Fixture();opened=f.lua.globals().fs.open;fail=[True]
        def fail_startup(path,mode):
            if path=='/startup.lua.amaryllis-tmp'and mode=='w'and fail[0]:
                fail[0]=False
                return None,'simulated write failure'
            return opened(path,mode)
        f.lua.globals().fs.open=fail_startup
        f.key('right').key('enter').yes()
        self.assertIn('Action unavailable',f.text())
        self.assertTrue(json.loads(f.files['/amaryllis-install.json'])['pending'])
        f.key('enter');self.assertIn('Resume this computer',f.text())
        f.key('enter').yes()
        self.assertFalse(json.loads(f.files['/amaryllis-install.json'])['pending'])
        self.assertIn('/startup.lua',f.files)

    def test_pending_swap_cannot_be_cancelled_or_imported_half_complete(self):
        """Verify pending swap cannot be cancelled or imported half complete."""
        f=Fixture(assignments={'thrust-lb':27,'chamber_fl':28},local_role='thrust-lb')
        f.key('left').key('down',5).key('enter').yes()
        f.key('enter').key('enter')
        self.assertIn('Apply correction on this computer',f.text())
        before=f.disk();f.key('down').key('enter').yes()
        self.assertIn('Action unavailable',f.text());self.assertEqual(f.disk(),before)
        f.key('enter').key('escape')
        self.assertIn('< Setup',f.text())
        f.key('down',3).key('enter').yes()
        self.assertIn('Action unavailable',f.text());self.assertEqual(f.disk(),before)

    def test_escape_cancels_confirmation_returns_setup_then_leaves(self):
        f=Fixture();before=dict(f.files)
        f.key('right').key('enter').key('escape')
        self.assertIn('< Chambers',f.text());f.key('escape');self.assertIn('< Setup',f.text())
        f.key('escape');self.assertEqual(f.lua.eval('coroutine.status(co)'),'dead')
        self.assertEqual(f.files,before)

    def test_no_core_explains_registration_block(self):
        f=Fixture()
        deployment=f.deployment();deployment['computers']={}
        f.files['/disk/deployment.json']=json.dumps(deployment)
        f.key('right');self.assertIn('Install core first.',f.text())
        before=dict(f.files);f.key('enter');self.assertEqual(f.files,before)

    def test_term_resize_keeps_selection_and_assignment_scroll(self):
        f=Fixture();f.key('left').key('down',14)
        before=dict(f.files);f.lua.globals().screen.width=40
        f.event('term_resize');self.assertIn('thrust-rs',f.text())
        frame=f.frame();self.assertTrue(all(len(row)==40 for row in frame['rows']))
        self.assertEqual(f.files,before)


# ======================================================================
# From test_disk_launcher: The installer disk's startup.lua runs setup.lua the way ComputerCraft runs programs.
# ======================================================================
import unittest

from lupa.lua52 import LuaRuntime

import project

# ComputerCraft gives each program its own environment holding shell and multishell; _G does not
# have them, and loadfile() without an environment argument loads into _G.
HARNESS = r"""
fs = {getDir = function(p) return p:match("^(.*)/") or "" end,
      combine = function(a, b) return a .. "/" .. b end}
printError = function(message) ERROR = message end
local real_load = load
loadfile = function(path, mode, env)
    assert(path == "disk/setup.lua", "unexpected path " .. tostring(path))
    return real_load(SETUP, "@" .. path, "t", env or _G)
end
SETUP = [[
local Setup = {}
function Setup.main(media)
    STARTED = {media = media, shell = shell ~= nil and shell.run("/startup.lua")}
end
return Setup
]]
local program_env = setmetatable({shell = {
    getRunningProgram = function() return "disk/startup.lua" end,
    run = function(path) RAN = path; return true end,
}}, {__index = _G})
PROGRAM_ENV = program_env
LAUNCH = function(source) return assert(real_load(source, "@disk/startup.lua", "t", program_env))() end
"""


class DiskLauncherTests(unittest.TestCase):
    def test_setup_receives_the_program_shell(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HARNESS)
        lua.globals().LAUNCH((project.HOME / "assets/startup.lua").read_text(encoding="utf-8"))
        self.assertIsNone(lua.globals().ERROR)
        started = lua.globals().PROGRAM_ENV.STARTED or lua.globals().STARTED
        self.assertEqual(started.media, "disk")
        self.assertIs(started.shell, True, "setup.lua could not see shell")
        self.assertEqual(lua.globals().RAN, "/startup.lua")
        self.assertIsNone(lua.globals().shell, "the harness must not expose shell as a global")


# ======================================================================
# From test_disk_download: The web installer-disk downloader against a built media folder served as a fake web host.
# ======================================================================
from pathlib import Path
import json
import tempfile
import unittest

from lupa.lua52 import LuaRuntime
import project

ROOT = project.ROOT
b = project.builder_module()

# Minimal ComputerCraft surface: an in-memory filesystem, one disk drive mounted
# at /disk, http served from Python, scripted keyboard answers.
FAKES = r'''
local FILES,DIRS,OUT,ANSWERS,CAPACITY=...
local function norm(p) p=("/"..p):gsub("/+","/"):gsub("/$","");if p=="" then p="/" end;return p end
local function children(dir)
    local seen,list={},{};local prefix=dir=="/" and "/" or dir.."/"
    local function add(p) local rest=p:sub(#prefix+1);local name=rest:match("^[^/]+")
        if p:sub(1,#prefix)==prefix and name and not seen[name] then seen[name]=true;list[#list+1]=name end end
    for p in pairs(FILES) do add(p) end;for p in pairs(DIRS) do add(p) end
    table.sort(list);return list
end
fs={}
function fs.combine(a,b) return (norm(a.."/"..b):sub(2)) end
function fs.getDir(p) p=norm(p);return (p:match("^(.*)/[^/]*$") or ""):sub(2) end
function fs.exists(p) p=norm(p);return FILES[p]~=nil or DIRS[p]~=nil end
function fs.isDir(p) return DIRS[norm(p)]~=nil end
function fs.list(p) return children(norm(p)) end
function fs.makeDir(p) DIRS[norm(p)]=true end
function fs.getSize(p) return #(FILES[norm(p)] or "") end
local function used() local n=0;for p,d in pairs(FILES) do if p:sub(1,6)=="/disk/" then n=n+#d end end;return n end
function fs.getFreeSpace(p) return CAPACITY-used() end
function fs.delete(p) p=norm(p)
    for k in pairs(FILES) do if k==p or k:sub(1,#p+1)==p.."/" then FILES[k]=nil end end
    for k in pairs(DIRS) do if k==p or k:sub(1,#p+1)==p.."/" then DIRS[k]=nil end end
end
function fs.move(a,b) FILES[norm(b)]=FILES[norm(a)];FILES[norm(a)]=nil end
function fs.open(p,mode) p=norm(p)
    if mode:sub(1,1)=="r" then local d=FILES[p];if not d then return nil end
        return {readAll=function() return d end,close=function() end} end
    local parts={};return {write=function(s) parts[#parts+1]=s end,close=function() FILES[p]=table.concat(parts) end}
end
DIRS["/disk"]=true
peripheral={getNames=function() return {"left"} end,getType=function() return "drive" end}
local label
disk={hasData=function() return true end,getMountPath=function() return "disk" end,
    getLabel=function() return label end,setLabel=function(_,l) label=l end}
function print(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring((select(i,...))) end;OUT(table.concat(t," ")) end
function write(s) OUT(tostring(s)) end
function printError(s) OUT("ERROR "..tostring(s)) end
function read() return ANSWERS() end
function sleep() end
'''


class DiskDownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="disk-download-", dir=ROOT / ".cache")
        out = Path(cls.temp.name)
        result, _ = b.build(ROOT, out)
        cls.media = result / "media"
        cls.index = json.loads((cls.media / "download.json").read_bytes())
        cls.script = (cls.media / "download.lua").read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_download(self, disk=None, answers=(), capacity=10_000_000, corrupt=None, args=("ama/release",)):
        lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        files = lua.table_from({("/disk/" + k).encode(): v for k, v in (disk or {}).items()})
        dirs = lua.table_from({})
        output, queue, requests = [], list(answers), []
        def serve(url):
            url = url.decode()
            requests.append(url)
            prefix = "https://raw.githubusercontent.com/ama/release/main/media/"
            path = self.media / url.removeprefix(prefix)
            if not url.startswith(prefix) or not path.is_file():
                return 404, b""
            data = path.read_bytes()
            if corrupt and url.endswith(corrupt):
                data = data[:-1] + b"?"
            return 200, data
        lua.execute(FAKES, files, dirs, lambda s: output.append(s.decode()), lambda: queue.pop(0).encode(), capacity)
        g = lua.globals()
        g.SERVE = serve
        lua.execute(rb'''
http={get=function(request)
    local code,data=SERVE(request.url)
    return {getResponseCode=function() return code end,readAll=function() return data end,close=function() end}
end}
local cjson={}
textutils={unserializeJSON=function(s) return PYJSON(s) end,serializeJSON=function(t) return '{"base":"'..t.base..'"}' end}
''')
        def pyjson(s):
            def conv(v):
                if isinstance(v, dict):
                    return lua.table_from({k.encode(): conv(x) for k, x in v.items()})
                if isinstance(v, list):
                    return lua.table_from([conv(x) for x in v])
                return v.encode() if isinstance(v, str) else v
            try:
                return conv(json.loads(s))
            except ValueError:
                return None
        g.PYJSON = pyjson
        chunk = lua.eval("function(src,...) return assert(load(src,'=download.lua'))(...) end")
        chunk(self.script, *[a.encode() for a in args])
        disk_after = {k.decode().removeprefix("/disk/"): v for k, v in files.items()}
        return disk_after, "\n".join(output), requests

    def expected(self):
        return {f["path"]: (self.media / f["path"]).read_bytes() for f in self.index["files"]}

    def assert_complete(self, disk):
        for path, data in self.expected().items():
            self.assertEqual(disk.get(path), data, path)

    def test_index_lists_every_media_file_with_startup_last(self):
        listed = [f["path"] for f in self.index["files"]]
        on_disk = sorted(p.relative_to(self.media).as_posix() for p in self.media.rglob("*") if p.is_file())
        self.assertEqual(sorted(listed + ["download.json", "loader.lua"]), on_disk)
        self.assertEqual(listed[-1], "startup.lua")
        self.assertTrue(all(p.startswith("objects/") for p in listed[:-len(b.DOWNLOAD_LAST)]))
        self.assertEqual(listed[-len(b.DOWNLOAD_LAST):], list(b.DOWNLOAD_LAST))

    def test_blank_disk_becomes_a_complete_installer_disk(self):
        disk, out, _ = self.run_download()
        self.assert_complete(disk)
        self.assertIn("Disk ready: " + self.index["releaseId"], out)
        self.assertIn("download-source.json", disk)
        self.assertNotIn("ERROR", out)

    def test_corrupt_download_never_leaves_a_bootable_disk(self):
        bad = next(f["path"] for f in self.index["files"] if f["path"].startswith("objects/"))
        disk, out, _ = self.run_download(corrupt=bad)
        self.assertIn("Checksum mismatch", out)
        self.assertNotIn("startup.lua", disk)

    def test_too_small_disk_is_refused_before_writing(self):
        disk, out, _ = self.run_download(capacity=100_000)
        self.assertIn("floppy_space_limit", out)
        self.assertEqual(disk, {})

    def test_other_files_are_kept_on_cancel(self):
        disk, out, _ = self.run_download({"notes.txt": b"keep"}, answers=["2"])
        self.assertEqual(disk, {"notes.txt": b"keep"})
        self.assertIn("Cancelled", out)

    def test_other_files_are_erased_when_chosen(self):
        disk, _, _ = self.run_download({"notes.txt": b"x"}, answers=["1"])
        self.assertNotIn("notes.txt", disk)
        self.assert_complete(disk)

    def test_same_release_repair_keeps_progress_and_fetches_only_damage(self):
        disk = dict(self.expected())
        damaged = next(p for p in disk if p.startswith("objects/"))
        disk[damaged] = b"broken"
        disk["deployment.json"] = b'{"progress":1}'
        after, out, requests = self.run_download(disk, answers=["1"])
        self.assertIn("keeps progress", out)
        self.assert_complete(after)
        self.assertEqual(after["deployment.json"], b'{"progress":1}')
        fetched = [r.rsplit("/media/", 1)[1] for r in requests]
        self.assertEqual(sorted(fetched), sorted(["download.json", damaged, "startup.lua"]))

    def test_same_release_replace_clears_progress(self):
        disk = dict(self.expected());disk["deployment.json"] = b"{}"
        after, out, _ = self.run_download(disk, answers=["2"])
        self.assertIn("clears progress", out)
        self.assertNotIn("deployment.json", after)
        self.assert_complete(after)

    def test_other_release_with_progress_explains_and_waits_for_choice(self):
        disk = {"release.json": b'{"releaseId":"amaryllis-old"}', "role-repair.json": b"{}", "startup.lua": b"old"}
        after, out, _ = self.run_download(disk, answers=["2"])
        self.assertIn("amaryllis-old", out)
        self.assertIn("cleared by a new release", out)
        self.assertEqual(after["startup.lua"], b"old")

    def test_saved_address_is_used_on_later_runs(self):
        first, _, _ = self.run_download()
        _, out, requests = self.run_download(first, answers=["1"], args=())
        self.assertTrue(requests[0].startswith("https://raw.githubusercontent.com/ama/release/main/media/"))
        self.assertIn("Nothing to download", out)


# ======================================================================
# From test_web_setup: Web install: core and other computers run web-setup.lua against a built release served as a fake web host.
# ======================================================================
from pathlib import Path
import json
import tempfile
import unittest

import project
from tests.test_builder import native_runtime, table, python_value

ROOT = project.ROOT
BASE = "https://raw.githubusercontent.com/ama/release/0123456789abcdef0123456789abcdef01234567/media/"
_TEMP = tempfile.TemporaryDirectory(prefix="web-setup-", dir=ROOT / ".cache")
_RESULT, _ = project.builder_module().build(ROOT, Path(_TEMP.name))
WEB_MEDIA = _RESULT / "media"
WEB_KEYS = {"one": 2, "two": 3, "three": 4, "r": 19, "u": 22, "y": 21, "n": 49, "q": 16, "up": 200, "down": 208, "enter": 28, "backspace": 14}
WEB_CHARS = {"one": "1", "two": "2", "three": "3", "r": "r", "u": "u", "y": "y", "n": "n", "q": "q"}
KEY_Z = 44  # the key marked Y on a QWERTZ keyboard reports the US-layout position of Z

ENVIRONMENT = r"""
term.clearLine=function() local x,y=term.getCursorPos();term.setCursorPos(1,y);term.write(string.rep(" ",screen.width));term.setCursorPos(x,y) end
CLOCK=0
os.clock=function() return CLOCK end
os.queueEvent=function() end
local pull=os.pullEvent
os.pullEvent=function(filter)
    while true do
        local e,a,b,c=coroutine.yield("INPUT")
        if e=="terminate" then error("Terminated") end
        if not filter or e==filter then return e,a,b,c end
    end
end
os.reboot=function() REBOOTED=true;while true do coroutine.yield("REBOOT") end end
keys={one=2,two=3,three=4,r=19,u=22,y=21,n=49,q=16,up=200,down=208,enter=28,backspace=14,left=203,right=205,escape=1,numPadEnter=156}
colors={white=1,gray=128,cyan=512,yellow=16,red=16384,lime=32,black=32768}
peripheral={getNames=function() return {"top"} end,getType=function() return "modem" end}
rednet={open=function() end,
    send=function(to,message,protocol) NET_SEND(ID,to,message,protocol);return true end,
    broadcast=function(message,protocol) NET_SEND(ID,nil,message,protocol);return true end,
    receive=function(protocol,timeout)
        local sender,message=coroutine.yield("RECEIVE")
        if sender==nil then CLOCK=CLOCK+(timeout or 1) end
        return sender,message,protocol
    end}
http={get=function(request)
    local url=type(request)=="table" and request.url or request
    local code,data=SERVE(url)
    return {getResponseCode=function() return code end,readAll=function() return data end,close=function() end}
end}
"""


class Computer:
    def __init__(self, network, identity, files=None):
        self.network, self.id = network, identity
        self.lua, self.files = native_runtime(files or {})
        self.inbox, self.requests = [], []
        network[identity] = self
        g = self.lua.globals()
        self.lua.execute(TERMINAL)
        self.lua.execute(ENVIRONMENT)
        g.ID = identity
        g.os.getComputerID = lambda: identity
        self.labels = []
        g.os.setComputerLabel = self.labels.append
        g.os.getComputerLabel = lambda: self.labels[-1] if self.labels else None
        g.print = lambda *a: None
        g.printError = lambda *a: self.errors.append(" ".join(str(x) for x in a))
        self.errors = []
        g.textutils = self.lua.table_from({
            "unserializeJSON": lambda raw: self.decode(raw),
            "serializeJSON": lambda value: json.dumps(python_value(value), sort_keys=True, separators=(",", ":"))})
        g.SERVE = self.serve
        g.NET_SEND = self.send
        original_delete = g.fs.delete
        def delete(path):
            for name in [n for n in self.files if n == path or n.startswith(path.rstrip("/") + "/")]:
                self.files.pop(name)
        g.fs.delete = delete
        source = (WEB_MEDIA / "web-setup.lua").read_bytes().decode("utf-8")
        g.SOURCE = source
        self.lua.execute('co=coroutine.create(function(...) assert(load(SOURCE,"=web-setup.lua",nil,_ENV))(...) end)')
        self.state = self.resume(BASE)

    def decode(self, raw):
        try:
            return table(self.lua, json.loads(raw))
        except ValueError:
            return None

    def serve(self, url):
        self.requests.append(url)
        if not url.startswith(BASE):
            return 404, ""
        path = WEB_MEDIA / url[len(BASE):]
        return (200, path.read_bytes().decode("utf-8")) if path.is_file() else (404, "")

    def send(self, sender, to, message, protocol):
        value = python_value(message)
        targets = [to] if to is not None else [n for n in self.network if n != sender]
        for target in targets:
            if target in self.network:
                self.network[target].inbox.append((sender, value, protocol))

    def resume(self, *args):
        result = self.lua.eval("function(...) return coroutine.resume(co,...) end")(*args)
        ok, value = (result if isinstance(result, tuple) else (result, None))[:2]
        assert ok, value
        assert not self.errors, self.errors
        return value or "DONE"

    def run(self, timeout=False):
        """Advance until the computer waits for input; a wait for a message times out only when allowed."""
        for _ in range(500):
            if self.state == "RECEIVE":
                if self.inbox:
                    sender, value, _ = self.inbox.pop(0)
                    self.state = self.resume(sender, table(self.lua, value))
                elif timeout:
                    self.state = self.resume(None);timeout = False
                else:
                    return self
            elif self.state == "INPUT" and self.inbox:
                sender, value, protocol = self.inbox.pop(0)
                self.state = self.resume("rednet_message", sender, table(self.lua, value), protocol)
            else:
                return self
        raise AssertionError("computer did not settle")

    def key(self, *names):
        """Press keys as ComputerCraft reports them: a "key" event, then a "char" event for printable keys."""
        for name in names:
            self.press(WEB_KEYS[name], WEB_CHARS.get(name))
        return self

    def press(self, code, char=None):
        """Send one physical key code and, when given, the character it typed."""
        assert self.state == "INPUT", self.state
        self.state = self.resume("key", code)
        if char is not None:
            assert self.state == "INPUT", self.state
            self.state = self.resume("char", char)
        settle(self.network)
        return self

    def json(self, path):
        return json.loads(self.files[path])

    def text(self):
        return "\n".join(python_value(self.lua.globals().screen)["rows"])


def settle(network):
    """Deliver messages until every computer is idle; a waiting receive times out only on a quiet network."""
    for _ in range(500):
        busy = False
        for computer in list(network.values()):
            before = (computer.state, len(computer.inbox), computer.lua.globals().CLOCK)
            computer.run()
            busy = busy or (computer.state, len(computer.inbox), computer.lua.globals().CLOCK) != before
        if busy:
            continue
        waiting = [c for c in network.values() if c.state == "RECEIVE"]
        if not waiting:
            return
        for computer in waiting:
            computer.run(timeout=True)
    raise AssertionError("network did not settle")


class WebSetupTests(unittest.TestCase):
    def core(self):
        network = {}
        core = Computer(network, 0)
        core.key("one", "y")
        self.assertIn("1/16 registered", core.text())
        return network, core

    def test_letters_follow_the_typed_character_on_any_layout(self):
        network = {}
        core = Computer(network, 0)
        core.key("one")
        self.assertIn("Install core on computer #0? (y/n)", core.text())
        core.press(WEB_KEYS["y"], "z")  # QWERTZ: the key at the US Y position types z
        self.assertIn("Install core on computer #0? (y/n)", core.text())
        core.press(KEY_Z, "y")          # QWERTZ: the key marked Y reports keys.z and types y
        self.assertIn("1/16 registered", core.text())

    def test_core_installs_from_the_web_and_opens_registration(self):
        _, core = self.core()
        journal = core.json("/amaryllis-install.json")
        self.assertEqual((journal["role"], journal["id"], journal["pending"]), ("core", 0, False))
        self.assertEqual(core.json("/installer/web/source.json")["base"], BASE)
        self.assertIn("/avionics/main.lua", core.files)
        self.assertEqual(core.json("/installer/web/deployment.json")["computers"]["core"]["id"], 0)
        self.assertTrue(all(r.startswith(BASE) for r in core.requests))
        self.assertIn("/installer/web/web-setup.lua", core.files["/startup.lua"], "core boots into registration until import")
        self.assertIn("/installer/web/core-startup.lua", core.files)

    def test_computer_finds_core_registers_and_installs_its_receiver(self):
        network, core = self.core()
        node = Computer(network, 5)
        node.key("two")
        settle(network)
        self.assertIn("REGISTER #5 WITH CORE #0", node.text())
        node.key("enter", "y")  # first role in the list
        first = json.loads((WEB_MEDIA / "release.json").read_text())["roleOrder"][0]
        self.assertIn("Registered as " + first, node.text())
        node.key("enter")
        self.assertTrue(node.lua.globals().REBOOTED)
        self.assertEqual(core.json("/installer/web/deployment.json")["computers"][first]["id"], 5)
        self.assertEqual(node.json("/config.json")["core_id"], 0)
        self.assertEqual(node.json("/amaryllis-install.json")["role"], first)
        self.assertIn("/installer.lua", node.files)
        self.assertFalse(any(p.startswith("/amaryllis-web") for p in node.files))
        self.assertIn("#5 registered as " + first, core.text())

    def test_taken_role_is_refused_on_the_computer(self):
        network, core = self.core()
        Computer(network, 5).key("two").key("enter", "y", "enter")
        other = Computer(network, 6)
        other.key("two", "enter")
        self.assertIn("Role taken", other.text())

    def test_registered_computer_moves_to_another_role_before_import(self):
        network, core = self.core()
        order = json.loads((WEB_MEDIA / "release.json").read_text())["roleOrder"]
        first = Computer(network, 5).key("two").key("enter", "y", "enter")
        again = Computer(network, 5, dict(first.files))
        again.key("two", "down", "enter", "y")
        self.assertIn("Role changed", again.text())
        computers = core.json("/installer/web/deployment.json")["computers"]
        self.assertNotIn(order[0], computers)
        self.assertEqual(computers[order[1]]["id"], 5)
        self.assertEqual(again.json("/amaryllis-install.json")["role"], order[1])

    def test_core_imports_once_every_role_is_registered(self):
        network, core = self.core()
        order = json.loads((WEB_MEDIA / "release.json").read_text())["roleOrder"]
        for number, _ in enumerate(order):
            Computer(network, 10 + number).key("two").key(*(["down"] * number), "enter", "y", "enter")
        self.assertIn("16/16 registered", core.text())
        core.key("enter", "y")
        self.assertIn("Assignments imported", core.text())
        core.key("enter")
        self.assertTrue(core.lua.globals().REBOOTED)
        self.assertNotIn("web-setup", core.files["/startup.lua"], "core's own startup is back after import")
        self.assertNotIn("/installer/web/core-startup.lua", core.files)
        fleet = core.json("/fleet.json")["computers"]
        self.assertEqual({r: fleet[r]["id"] for r in order}, {r: 10 + n for n, r in enumerate(order)})

    def test_core_rerun_continues_registration_on_its_pinned_release(self):
        network, core = self.core()
        again = Computer({}, 0, dict(core.files))
        self.assertIn("1/16 registered", again.text())


class WebUndoTests(unittest.TestCase):
    def registered(self):
        network = {}
        core = Computer(network, 0).key("one", "y")
        order = json.loads((WEB_MEDIA / "release.json").read_text())["roleOrder"]
        nodes = [Computer(network, 10 + n).key("two").key(*(["down"] * n), "enter", "y", "enter") for n in range(len(order))]
        return network, core, nodes, order

    def test_reset_after_import_clears_assignments_and_computers_keep_their_programs(self):
        network, core, nodes, order = self.registered()
        core.key("enter", "y", "enter")
        rerun = Computer(network, 0, dict(core.files))
        rerun.key("r", "y")
        self.assertIn("Resetting installation", rerun.text())
        rerun.key("enter")
        self.assertIn("web-setup", rerun.files["/startup.lua"], "core restarts into registration")
        network.pop(0)
        booted = Computer(network, 0, dict(rerun.files))
        state = booted.json("/installer/web/deployment.json")
        self.assertEqual(list(state["computers"]), ["core"])
        self.assertEqual(state["reset"]["previous"][order[0]]["id"], 10)
        self.assertNotIn("/installer/web/reset-pending.json", booted.files)
        again = Computer(network, 10, dict(nodes[0].files))
        again.key("two", "enter", "y")
        self.assertIn("Existing programs and settings kept", again.text())
        self.assertEqual(booted.json("/installer/web/deployment.json")["computers"][order[0]]["id"], 10)

    def test_uninstall_core_before_import_removes_its_files(self):
        network = {}
        core = Computer(network, 0).key("one", "y", "u", "y")
        self.assertIn("Core uninstalled", core.text())
        self.assertEqual([p for p in core.files if not p.startswith("/rom")], [])

    def test_uninstall_is_refused_after_import(self):
        network, core, _, _ = self.registered()
        core.key("enter", "y", "enter")
        rerun = Computer(network, 0, dict(core.files)).key("u")
        self.assertIn("Reset installation (R) before uninstalling core", rerun.text())
        self.assertIn("/avionics/main.lua", rerun.files)

    def test_computer_removes_its_registration_and_core_clears_the_role(self):
        network, core = {}, None
        core = Computer(network, 0).key("one", "y")
        node = Computer(network, 5).key("two").key("enter", "y", "enter")
        first = json.loads((WEB_MEDIA / "release.json").read_text())["roleOrder"][0]
        network.pop(5)
        rerun = Computer(network, 5, dict(node.files))
        self.assertIn("3  Remove this computer's registration (" + first + ")", rerun.text())
        rerun.key("three", "y")
        self.assertIn("Registration removed", rerun.text())
        self.assertFalse(any(p in rerun.files for p in ("/startup.lua", "/config.json", "/amaryllis-install.json", "/installer.lua")))
        self.assertNotIn(first, core.json("/installer/web/deployment.json")["computers"])

    def test_state_reader_registration_can_be_removed(self):
        network = {}
        core = Computer(network, 0).key("one", "y")
        order = json.loads((WEB_MEDIA / "release.json").read_text())["roleOrder"]
        state = Computer(network, 7).key("two").key(*(["down"] * order.index("state")), "enter", "y", "enter")
        self.assertIn("/avionics/config.json", state.files)
        network.pop(7)
        rerun = Computer(network, 7, dict(state.files)).key("three", "y")
        self.assertFalse(any(p.startswith("/avionics") for p in rerun.files))
        self.assertNotIn("state", core.json("/installer/web/deployment.json")["computers"])


class CoreWebMediaTests(unittest.TestCase):
    def test_core_serves_packages_from_its_web_release(self):
        lua, files = native_runtime({
            "/installer/library.json": (WEB_MEDIA / "library.json").read_bytes().decode("utf-8"),
            "/installer/web/source.json": json.dumps({"base": BASE}),
        })
        catalog = json.loads((WEB_MEDIA / "library.json").read_text())
        entry = catalog["files"][0]
        served = []
        def get(request):
            url = request["url"]
            served.append(url)
            data = (WEB_MEDIA / url[len(BASE):]).read_bytes().decode("utf-8")
            return lua.table_from({"getResponseCode": lambda: 200, "readAll": lambda: data, "close": lambda: None})
        lua.globals().HTTP = lua.table_from({"get": get})
        lua.globals().SOURCE = (ROOT / "disk-builder/assets/core-media.lua").read_text(encoding="utf-8")
        lua.globals().JSON = lua.table_from({"unserializeJSON": lambda raw: table(lua, json.loads(raw))})
        data = lua.execute(r'''
local Media=assert(load(SOURCE))()
local media=Media.new(fs,{getNames=function() return {} end},{},JSON,function() end,HTTP)
assert(media:refresh(),"web media is available")
local h=assert(media.fs.open(...,"r"))
return h.readAll()
''', entry["path"])
        self.assertEqual(data, (WEB_MEDIA / ("objects/" + entry["object"])).read_bytes().decode("utf-8"))
        self.assertEqual(served, [BASE + "objects/" + entry["object"]])

    def test_checked_web_package_is_cached_between_requests(self):
        lua, files = native_runtime({
            "/installer/library.json": (WEB_MEDIA / "library.json").read_bytes().decode("utf-8"),
            "/installer/web/source.json": json.dumps({"base": BASE}),
        })
        entry = json.loads((WEB_MEDIA / "library.json").read_text())["files"][0]
        lua.globals().HTTP = lua.table_from({"get": lambda request: None})
        lua.globals().SOURCE = (ROOT / "disk-builder/assets/core-media.lua").read_text(encoding="utf-8")
        lua.globals().CACHE = (ROOT / "source/core/installer/bundle_cache.lua").read_text(encoding="utf-8")
        lua.globals().JSON = lua.table_from({"unserializeJSON": lambda raw: table(lua, json.loads(raw))})
        loads = lua.execute(r'''
local Media=assert(load(SOURCE))()
local media=Media.new(fs,{getNames=function() return {} end},{},JSON,function() end,HTTP)
assert(media:refresh(),"web media is available")
local clock=0
local cache=assert(load(CACHE))().new(media.fs,function() return clock end)
local loads=0
local function loader() loads=loads+1;return {totalBytes=10} end
for request=1,3 do
  clock=clock+10  -- past the cache's 5 s recheck window, so the fingerprint decides
  assert(cache:get("role",{...},loader))
end
return loads
''', entry["path"])
        self.assertEqual(loads, 1, "a checked web package is reused while the release is unchanged")


# ======================================================================
# From test_live_update_status: After a live update the running old installer rewrites status.json with the old release; the new console repairs it.
# ======================================================================
import json
import re
import unittest

import project
from tests import test_builder as support

INSTALL = {"role": "navigator", "packageId": "amaryllis.navigator", "label": "ama-bridge", "coreID": 3, "installID": "i-6",
           "clientSession": "c", "serverSession": "s", "coreSession": "k", "version": 13, "manifestChecksum": "NEW"}
STATUS = {"hasInstalled": True, "recoveryRequired": False, "state": "listening", "installedRole": "navigator",
          "installedPackageId": "amaryllis.navigator", "installedLabel": "ama-bridge", "installedComputerID": 6,
          "installedCoreID": 3, "installedInstallID": "i-6", "installedClientSession": "c", "installedServerSession": "s",
          "installedCoreSession": "k", "installedVersion": 13, "installedManifestChecksum": "OLD", "version": 13}


class LiveUpdateStatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = (project.ROOT / "source/library/packages/common/console.lua").read_text(encoding="utf-8")
        match = re.search(r"local function refreshLiveUpdateStatus\(.*?\nend\n", text, re.S)
        cls.function = match.group(0)

    def run_case(self, status, install=None):
        files = {"/installer/status.json": json.dumps(status)}
        lua, files = support.native_runtime(files)
        lua.globals().ENCODE = lambda value: json.dumps(support.python_value(value))
        lua.globals().LOGS = lua.table()
        lua.execute('''
textutils={serializeJSON=function(value) return ENCODE(value) end}
os.__amaryllisLog=function(message) LOGS[#LOGS+1]=message end
''' + self.function + "\nrefreshLiveUpdateStatus_fn=refreshLiveUpdateStatus")
        lua.globals().INSTALL = support.table(lua, install or INSTALL)
        lua.globals().STATUS = support.table(lua, status)
        lua.execute("RESULT=refreshLiveUpdateStatus_fn(INSTALL,STATUS,6)")
        return lua, files, support.python_value(lua.globals().RESULT), len(lua.globals().LOGS)

    def test_lagging_release_fields_are_refreshed_and_stored(self):
        lua, files, result, logs = self.run_case(dict(STATUS))
        self.assertEqual(result["installedManifestChecksum"], "NEW")
        self.assertEqual(json.loads(files["/installer/status.json"])["installedManifestChecksum"], "NEW")
        self.assertNotIn("/installer/status.json.tmp", files)
        self.assertEqual(logs, 1)

    def test_current_status_is_left_alone(self):
        _, files, result, logs = self.run_case(dict(STATUS, installedManifestChecksum="NEW"))
        self.assertEqual(result["installedManifestChecksum"], "NEW")
        self.assertEqual(logs, 0)

    def test_identity_or_recovery_differences_are_never_repaired(self):
        for change in ({"installedComputerID": 7}, {"installedInstallID": "other"}, {"installedCoreSession": "x"},
                       {"installedRole": "core"}, {"recoveryRequired": True}, {"state": "committing"}, {"hasInstalled": False}):
            with self.subTest(change=change):
                status = dict(STATUS, **change)
                _, files, result, logs = self.run_case(status)
                self.assertEqual(result["installedManifestChecksum"], "OLD")
                self.assertEqual(json.loads(files["/installer/status.json"])["installedManifestChecksum"], "OLD")
                self.assertEqual(logs, 0)


class CoreReachabilityTests(unittest.TestCase):
    """Validate auxiliary core-loss transitions independently of actuator services."""

    def runtime(self):
        lua, files = support.native_runtime({})
        lua.execute('''
NOW=100
os.clock=function() return NOW end
os.getComputerID=function() return 6 end
os.getComputerLabel=function() return 'bridge' end
os.queueEvent=function() end
''')
        text = (project.ROOT / 'source/library/packages/common/console.lua').read_text(encoding='utf-8')
        lua.globals().Console = lua.execute(text)
        lua.execute('''
REGISTRY={v=1,kind='fleet_registry',coreID=3,session='core-a',computers={
 core={id=3,label='ama-core'},navigator={id=6,label='bridge'}}}
function accept(sender)
 return Console.acceptRegistry(sender or 3,REGISTRY,'amaryllis.v1','navigator',6,3)
end
''')
        return lua

    def test_validated_core_traffic_times_out_and_recovers_without_touching_runtime(self):
        lua = self.runtime()
        lua.execute('''
assert(Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
assert(Console.connectionState(NOW,'core')==nil)
assert(not accept(9))
assert(Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
assert(accept())
local runtime={running=true,hardwareAvailable=true,faults={'LOCAL FAULT'},snapshot={lift=123}}
local capture={running=true,boot='node'}
local install={role='navigator',coreID=3,label='bridge',packageId='p',version=1}
NOW=110
assert(Console.roleStatus(install,capture,runtime,1).networkState=='CONNECTED')
NOW=110.01
local status=Console.roleStatus(install,capture,runtime,2)
assert(status.networkState=='CORE UNREACHABLE' and status.faultSummary=='CORE UNREACHABLE')
assert(runtime.snapshot.lift==123 and runtime.running and runtime.faults[1]=='LOCAL FAULT')
assert(not accept(9) and Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
REGISTRY.session='core-b';assert(accept())
assert(Console.connectionState(NOW,'navigator')=='CONNECTED')
REGISTRY.session='core-a';assert(not accept())
NOW=121
assert(Console.connectionState(NOW,'navigator')=='CORE UNREACHABLE')
REGISTRY.session='core-b';assert(accept())
assert(Console.roleStatus(install,capture,runtime,3).faultSummary=='LOCAL FAULT')
''')

    def test_wired_context_freshness_and_local_fault_history(self):
        lua = self.runtime()
        lua.execute('''
os.__amaryllisCoreLink={transport='wired',coreID=3,receivedAt=100,timeout=10}
assert(Console.connectionState(110,'state')=='CONNECTED')
assert(Console.connectionState(111,'state')=='CORE UNREACHABLE')
local previous={saved={source='lift',reason='LOCAL FAULT'}}
local capture={runtimeFaults=previous}
NOW=111
Console._test.observeRuntimeFaults({faultSummary='dependent timeout'},capture,function() error('unexpected log') end)
assert(capture.runtimeFaults==previous)
os.__amaryllisCoreLink.receivedAt=111
assert(Console.connectionState(111,'state')=='CONNECTED')
''')

    def test_every_auxiliary_role_uses_the_same_connection_policy(self):
        lua = self.runtime()
        lua.execute('''
local roles={'navigator','state','heading-left','heading-main','heading-right',
 'chamber_fl','chamber_fr','chamber_bl','chamber_br',
 'primary_l','primary_r','thrust-lb','thrust-rb','thrust-ls','thrust-rs'}
for _,role in ipairs(roles) do
 assert(Console.connectionState(100,role)=='CORE UNREACHABLE',role)
end
assert(accept())
for _,role in ipairs(roles) do
 assert(Console.connectionState(110,role)=='CONNECTED',role)
 assert(Console.connectionState(110.1,role)=='CORE UNREACHABLE',role)
end
assert(not Console.acceptRegistry(3,REGISTRY,'wrong','navigator',6,3))
assert(os.__amaryllisCoreLink.receivedAt==100)
''')

    def test_chamber_child_fault_is_subordinate_to_core_loss(self):
        lua = self.runtime()
        lua.globals().Link = lua.execute((project.ROOT / 'source/library/packages/common/chamber_link.lua').read_text())
        lua.execute('''
os.startTimer=function() return 1 end
os.pullEventRaw=function() return coroutine.yield() end
local relay
parallel={waitForAll=function(first) relay=coroutine.create(first) end}
Link.parent({coreId=3,role='chamber_fl',quadrant='FL',relayChildRole='thrust-lb',label='chamber-fl'})
assert(coroutine.resume(relay))
assert(coroutine.resume(relay,'timer',1))
local child=os.__amaryllisRuntime.components.thrust
assert(child.controlState=='CORE UNREACHABLE' and child.faultSummary=='CORE UNREACHABLE')
assert(#child.faults==1 and child.faults[1]:find('COM UNRESPONSIVE',1,true))
os.__amaryllisCoreLink={receivedAt=NOW,timeout=10}
assert(coroutine.resume(relay,'timer',1))
assert(child.networkState=='CONNECTED' and child.controlState=='FAULT')
assert(child.faultSummary:find('COM UNRESPONSIVE',1,true))
''')


class AutoRebootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = (project.ROOT / "source/library/packages/common/console.lua").read_text(encoding="utf-8")
        cls.function = re.search(r"local function rebootForStatusMismatch\(.*?\nend\n", text, re.S).group(0)

    def lua(self, files):
        lua, files = support.native_runtime(files)
        lua.globals().ENCODE = lambda value: json.dumps(support.python_value(value))
        lua.globals().DECODE = lambda raw: support.table(lua, json.loads(raw))
        lua.execute('''
REBOOTS=0;NOW=1000000000;LOGS={}
textutils={serializeJSON=function(v) return ENCODE(v) end}
os.epoch=function() return NOW end
os.sleep=function() end
os.reboot=function() REBOOTS=REBOOTS+1 end
os.__amaryllisLog=function(m) LOGS[#LOGS+1]=m end
local function readJson(path)
  local h=fs.open(path,"r");if not h then return nil end
  return DECODE(h.readAll())
end
''' + self.function + "\nATTEMPT=rebootForStatusMismatch")
        return lua, files

    def test_two_automatic_reboots_per_hour_then_stops(self):
        lua, files = self.lua({})
        reason = "installed package receipt is not committed"
        results = [lua.eval("ATTEMPT")(reason) for _ in range(4)]
        self.assertEqual(results, [True, True, False, False])
        self.assertEqual(lua.globals().REBOOTS, 2)
        self.assertEqual(json.loads(files["/installer/auto-reboot.json"])["count"], 2)

    def test_counter_resets_after_an_hour(self):
        lua, files = self.lua({})
        reason = "installed package identity does not match its receipt"
        lua.eval("ATTEMPT")(reason); lua.eval("ATTEMPT")(reason)
        lua.execute("NOW=NOW+3600001")
        self.assertTrue(lua.eval("ATTEMPT")(reason))
        self.assertEqual(json.loads(files["/installer/auto-reboot.json"])["count"], 1)

    def test_other_reasons_never_reboot(self):
        lua, files = self.lua({})
        for reason in ("waiting for installed role package", "installed package receipt is invalid or recovery is pending", None):
            self.assertFalse(lua.eval("ATTEMPT")(reason))
        self.assertEqual(lua.globals().REBOOTS, 0)
        self.assertNotIn("/installer/auto-reboot.json", files)


if __name__ == "__main__":
    import unittest
    unittest.main()
