"""Real keyboard commissioning and assignment-reset transactions in isolated memory."""
from pathlib import Path
import copy
import json
import tempfile
import unittest
import project
from tests.test_runtime_bundling import native_runtime, table, python_value

ROOT = Path(__file__).resolve().parents[1]
HOME = ROOT / "disk-builder"
KEYS = {'left':203,'right':205,'up':200,'down':208,'enter':28,'escape':1,'numPadEnter':156}
_CACHE = ROOT / '.cache'
_CACHE.mkdir(exist_ok=True)
_MEDIA_TEMP = tempfile.TemporaryDirectory(prefix='disk-setup-', dir=_CACHE)
MEDIA, _ = project.builder_module().build(project.ROOT, Path(_MEDIA_TEMP.name))
MEDIA = MEDIA / 'media'
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
        self.release=copy.deepcopy(release_override or json.loads((MEDIA/'release.json').read_bytes()))
        self.roles=self.release['roles'];self.id=identity
        files={('/disk/'+p.relative_to(MEDIA).as_posix()):p.read_bytes().decode('utf-8') for p in MEDIA.rglob('*')if p.is_file()}
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
        for _ in range(count):self.lua.globals().step('key',KEYS[name])
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
        roles=json.loads((MEDIA/'release.json').read_bytes())['roles']
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
