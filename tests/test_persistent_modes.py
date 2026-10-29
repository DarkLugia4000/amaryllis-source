"""Persistent pilot modes against real Flight, Controls, AP and Presets modules."""
from pathlib import Path
import ast,copy,json,sys,unittest
ROOT=Path(__file__).resolve().parents[1];HOME=ROOT/'disk-builder'
sys.path.insert(0,str(HOME))
import builder,presentation
from tests.test_runtime_bundling import LuaRuntime,table
from project import fixture
BASE=fixture("legacy")
def sources():
 names=['controls.lua','autopilot.lua','anchor.lua','flight.lua','control_presets.lua','remote_ap.lua']
 data={'/avionics/'+name:(BASE/'avionics'/name).read_bytes()for name in names}
 builder.control_persistence_overlays(data)
 return data
def fixture_source():
 """Load the isolated flight/control fixture used by current and compatibility cases."""
 return (ROOT/'tests/fixtures/flight-control.lua').read_text(encoding='utf-8')

TESTS={
'persist_before_ack':r'''
local io,f,p,clock=setup()
local ok,why=f:request(io,{type="cockpit_mode",axis="heading",mode="SEL"},10)
check(ok,why)
check(store[p.path]and store[p.path].modes.heading=="SEL","heading durable before mode acknowledgement")
ok,why=f:request(io,{type="cockpit_mode",axis="throttle",mode="SEL"},10)
check(ok,why)
check(store[p.path].modes.throttle=="SEL","speed mode durable before acknowledgement")
local n=writes;p:update(io,f,10.1);check(writes==n,"unchanged state does not rewrite disk")
''',
'core_reboot':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local disk=clone(store)
io,f,p,clock=setup(disk);f.enabled=false;f.systemsRun=nil
sample(io,clock,11);p:update(io,f,11)
check(f.controls.modes.heading=="SEL"and f.controls.modes.throttle=="SEL","SEL restored after core reboot")
check(f.controls.targets.heading==120 and f.controls.targets.speed==4,"both selected targets restored")
check(f.controls.targets.altitude==160,"selected altitude retained")
check(not f.enabled and p.awaitResume and f.controls.request==0,"restore does not start ship or apply lever demand")
''',
'navigator_reboot':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local c=f.controls
f:bridgeRequest(io,{boot="old-bridge",seq=1,action={type="cockpit_mode",axis="heading",mode="SEL"}},10)
f:bridgeRequest(io,{boot="new-bridge",seq=1,action={type="cockpit_mode",axis="heading",mode="SEL"}},10)
check(c.modes.heading=="SEL"and c.modes.throttle=="SEL","navigator reboot keeps core-owned modes")
check(c.targets.heading==120 and c.targets.speed==4,"navigator reboot keeps selected values")
''',
'faults':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local c=f.controls
io.inputs.valid=false;sample(io,clock,11);c:update(io,11);p:update(io,f,11)
check(c.modes.heading=="SEL"and c.modes.throttle=="SEL","input loss keeps modes")
check(c.targets.heading==120 and c.targets.speed==4,"input loss keeps targets")
io.identityReady=false;sample(io,clock,12);c:update(io,12);p:update(io,f,12)
check(c.request==0 and c.yaw==0,"identity fault clears live requests")
check(c.modes.heading=="SEL"and store[p.path].modes.heading=="SEL","identity fault cannot erase selection")
io.identityReady=true;io.inputs.valid=true
sample(io,clock,13,{"prop_forward",15});c.requireNeutral=true;c:update(io,13)
check(c.request==0 and c.requireNeutral,"held input cannot bypass recovery neutral gate")
sample(io,clock,14,{"prop_forward",0});c:update(io,14)
check(c.modes.heading=="SEL"and c.modes.throttle=="SEL","fresh recovery retains modes")
''',
'ap_fault':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local c=f.controls;local ap=f:ensureAutopilot(io)
ap.active=true;ap.state="CRUISE";c.request=1;c.yaw=.4
ap:cancel(io,c,"TELEMETRY FAILURE")
check(not ap.active and c.request==0 and c.yaw==0,"AP fault clears demands")
check(c.modes.heading=="SEL"and c.modes.throttle=="SEL","AP fault keeps pilot-selected modes")
check(c.targets.heading==120 and c.targets.speed==4,"AP fault keeps selected values")
check(c.requireNeutral and c.waitHeading and c.waitThrottle,"AP fault requires neutral handover")
p:update(io,f,10)
check(store[p.path].modes.heading=="SEL"and store[p.path].modes.throttle=="SEL","fault does not save MANUAL defaults")
''',
'anchor_release':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local anchor=Anchor.new(io.config);anchor.active=true;anchor.state="HOLD"
anchor:cancel(f.controls,"RELEASED")
check(f.controls.modes.heading=="SEL"and f.controls.modes.throttle=="SEL","anchor release does not force DIRECT")
check(f.controls.targets.speed==4 and f.controls.targets.heading==120,"anchor release keeps selections")
check(f.controls.requireNeutral and f.controls.waitThrottle,"anchor release requires neutral")
''',
'disconnect_sample':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local ap=f:ensureAutopilot(io);ap.active=true;io.autopilot=ap
sample(io,clock,11,{"ap_disconnect",15});f.controls:update(io,11)
check(not ap.active,"disconnect cancels AP")
check(f.controls.modes.heading=="SEL"and f.controls.modes.throttle=="SEL","disconnect keeps modes")
check(f.controls.targets.speed==4,"disconnect sample is not reused as zero-speed shortcut")
check(f.controls.request==0 and f.controls.waitThrottle,"disconnect returns at neutral boundary")
''',
'explicit_change':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local ok,why=f:request(io,{type="cockpit_mode",axis="heading",mode="MANUAL"},10)
check(ok,why);check(store[p.path].modes.heading=="MANUAL","explicit MANUAL persists immediately")
ok,why=f:request(io,{type="cockpit_mode",axis="throttle",mode="DIRECT"},10)
check(ok,why);check(store[p.path].modes.throttle=="DIRECT","explicit DIRECT persists immediately")
local disk=clone(store);io,f,p,clock=setup(disk)
sample(io,clock,11);p:update(io,f,11)
check(f.controls.modes.heading=="MANUAL"and f.controls.modes.throttle=="DIRECT","explicit choices survive reboot")
''',
'restore_neutral_and_identity':r'''
local io,f,p,clock=setup();selected(io,f,p,clock);local disk=clone(store)
io,f,p,clock=setup(clone(disk))
sample(io,clock,11,{"prop_forward",15});p:update(io,f,11)
check(p.pending and f.controls.request==0,"held lever delays restore")
sample(io,clock,12,{"prop_forward",0});p:update(io,f,12)
check(not p.pending and f.controls.modes.throttle=="SEL","neutral permits restore")
io,f,p,clock=setup(clone(disk));io.vessel.uuid="different-vessel"
sample(io,clock,11);p:update(io,f,11)
check(f.controls.modes.heading~="SEL","another vessel cannot inherit old heading authority")
''',
'save_retry':r'''
local io,f,p,clock=setup();fail=true
local ok=f:request(io,{type="cockpit_mode",axis="heading",mode="SEL"},10)
check(ok and p.saveError,"save failure visible without discarding chosen mode")
fail=false;sample(io,clock,11);p:update(io,f,11)
check(store[p.path].modes.heading=="SEL"and not p.saveError,"save retries and clears error")
''',
'finite_json_and_backup':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local document=clone(store[p.path]);document.targets.speed=0/0
check(not p:valid(document),"non-finite selected speed refused")
local disk={[p.path..".bak"]=clone(store[p.path])}
io,f,p,clock=setup(disk);sample(io,clock,11);p:update(io,f,11)
check(f.controls.modes.heading=="SEL","validated JSON backup can restore selection")
'''
}
def native_source():
 return fixture_source()+'\n'+''.join('do\n'+case+'\nend\n'for case in TESTS.values())+'\nreturn checks'
def runtime():
 lua=LuaRuntime(unpack_returned_tuples=True)
 lua.globals().CONFIG=table(lua,json.loads((BASE/'avionics/config.json').read_bytes()))
 lua.globals().package.path=(BASE/'?.lua').as_posix()+';'+lua.globals().package.path
 for path,body in sources().items():
  name='avionics.'+Path(path).stem
  lua.execute('local name,source=...;package.preload[name]=function()return assert(load(source))()end',name,body.decode('utf-8'))
 return lua
class PersistentModesTests(unittest.TestCase):
 def test_overlay_idempotence(self):
  data=sources();first=copy.deepcopy(data);builder.control_persistence_overlays(data);self.assertEqual(data,first)
 def test_unknown_source_refused(self):
  data=sources();data['/avionics/controls.lua']=b'return{}'
  with self.assertRaises(builder.BuildError):builder.control_persistence_overlays(data)
for name,case in TESTS.items():
 def run(self,case=case):
  lua=runtime();count=lua.execute(fixture_source()+'\n'+case+'\nreturn checks');self.assertGreater(count,0)
 setattr(PersistentModesTests,'test_'+name,run)
if __name__=='__main__':unittest.main(verbosity=2)
