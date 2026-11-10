"""Persistent state, cockpit presets, altitude limits and settings."""

# ======================================================================
# From test_persistence: Current-source and bundled persistence transactions with filesystem fault injection.
# ======================================================================
import json
import unittest
import project
from tests.test_builder import LuaRuntime, table, python_value

HARNESS = r"""
FILES={}; FAIL=nil; FAILPATH=nil; CRASH=nil; FROZEN=false; SNAPSHOT=nil
local function operation(op,path)
    if FROZEN then error('filesystem interrupted') end
    if op==FAIL and (not FAILPATH or path==FAILPATH) then
        FAIL=nil; error('injected '..op..' '..path)
    end
    if op==CRASH then
        CRASH=nil; SNAPSHOT={};for k,v in pairs(FILES) do SNAPSHOT[k]=v end
        FROZEN=true;error('simulated power loss')
    end
end
fs={}
function fs.exists(p) operation('exists',p);return FILES[p]~=nil end
function fs.makeDir(p) operation('mkdir',p) end
function fs.getDir(p) return p:match('^(.*)/') or '' end
function fs.open(p,mode)
    operation('open-'..mode,p)
    if mode=='r' then
        if not FILES[p] then return nil,'missing '..p end
        return {readAll=function() operation('read',p);return FILES[p] end,close=function() end}
    end
    FILES[p]=''
    return {write=function(s) operation('write',p);FILES[p]=s end,
        close=function() operation('close',p) end}
end
function fs.delete(p) operation('delete',p);FILES[p]=nil end
function fs.move(a,b)
    operation('move',a)
    assert(FILES[a]~=nil,'missing move source '..a)
    assert(FILES[b]==nil,'move destination exists '..b)
    FILES[b]=FILES[a];FILES[a]=nil
    operation('moved',b)
end
function fs.getSize(p) return #assert(FILES[p]) end
function fs.isReadOnly() return false end
function fs.getFreeSpace() return 10000000 end
function fs.isDir() return false end
function fs.combine(a,b) return a:gsub('/+$','')..'/'..b:gsub('^/+','') end
textutils={serializeJSON=function(v) return encode(v) end,unserializeJSON=function(s) return decode(s) end}
os.getComputerID=function() return 0 end
os.epoch=function() return 10000 end
os.queueEvent=function() end
local function clone(v)
    if type(v)~='table' then return v end
    local r={};for k,x in pairs(v) do r[k]=clone(x) end;return r
end
function valid(v) return type(v)=='table' and type(v.gain)=='number' and v.gain>=.002 and v.gain<=.08 end
P='/avionics/data/speed-feedforward-v2.json'
STATE='/avionics/data/vessel-state.json'
OLD={gain=.022,bands={['1']=.024},unit='thrust_x_pressure_per_bps'}
NEW={gain=.03,bands={['1']=.032},unit='thrust_x_pressure_per_bps'}
function reset()
 FILES={};FILES[P]=textutils.serializeJSON(OLD);FILES[P..'.bak']=textutils.serializeJSON({gain=.02})
 FAIL=nil;FAILPATH=nil;CRASH=nil;FROZEN=false
 os.__amaryllisRemoteInstallLock=nil;os.__amaryllisRemotePermissions=nil
end
function thrust()
 local t=Modules.Thrust.new({thrust={speed_feedforward_per_bps=.031}})
 t:loadSpeedFeedforward();return t
end
function assertOld()
 local stored=Modules.Storage.readValidatedJson(P,valid)
 assert(stored and stored.gain==OLD.gain,'last valid learning survives')
end
DRIVE='disk';MOUNT='/disk'
peripheral={getNames=function() return {'drive'} end,hasType=function() return true end,
 wrap=function() return {isDiskPresent=function() return true end,hasData=function() return true end,
 getDiskID=function() return nil end,getDiskLabel=function() return 'remote' end,
 getMountPath=function() return MOUNT end} end}
disk={getMountPath=function() return MOUNT end,getID=function() return 9 end}
"""

CASES = {
 'combined_sections_survive_migration_and_alternating_saves': r"""
reset()
local s=Modules.Storage
local hover='/avionics/data/hover-offset.json'
local nav='/avionics/data/navigation.json'
local intent='/avionics/data/systems-intent.json'
FILES[hover]=textutils.serializeJSON({schemaVersion=1,bands={['160']={offset=.01}}})
assert(s.writeJson(nav,{schemaVersion=1,destination={x=1,z=2}}))
assert(s.writeJson(intent,{schemaVersion=1,active=true}))
assert(s.writeJson(P,NEW,nil,valid))
assert(s.readJson(hover).bands['160'].offset==.01)
assert(s.readJson(nav).destination.z==2 and s.readJson(intent).active)
assert(s.readJson(P).gain==NEW.gain and textutils.unserializeJSON(FILES[P]).gain==OLD.gain)
FILES[STATE]='broken'
assert(s.readJson(nav).destination.z==2 and not s.readJson(intent).active)
assert(s.writeJson(nav,{schemaVersion=1,destination={x=3,z=4}}))
assert(s.readJson(hover).bands['160'].offset==.01 and not s.readJson(intent).active)
""",
 'split_migrates_combined_state_and_keeps_pilot_file_independent': r"""
reset()
local s=Modules.Storage
local pilot='/avionics/data/control-presets.json'
local nav='/avionics/data/navigation.json'
local old='/avionics/data/persistent-state.json'
local pilotFile='/avionics/data/pilot-presets.json'
FILES[old]=textutils.serializeJSON({schemaVersion=1,sections={
 controlPresets={targets={speed=4}}, navigation={destination={x=1,z=2}}
},previous={}})
assert(s.readJson(pilot).targets.speed==4)
assert(s.writeJson(pilot,{targets={speed=5}}))
assert(not FILES[STATE])
assert(s.writeJson(P,NEW,nil,valid))
assert(s.readJson(nav).destination.z==2)
assert(s.readJson(pilot).targets.speed==5)
assert(not textutils.unserializeJSON(FILES[STATE]).sections.controlPresets)
assert(not textutils.unserializeJSON(FILES[pilotFile]).sections.navigation)
assert(textutils.unserializeJSON(FILES[old]).sections.controlPresets.targets.speed==4)
""",
'migration_preserves_inactive_authority_with_legacy_backup_only': r"""
reset()
local s=Modules.Storage
local intent='/avionics/data/systems-intent.json'
local remotes='/avionics/data/remotes.json'
FILES[intent..'.bak']=textutils.serializeJSON({schemaVersion=1,active=true})
FILES[remotes..'.remote-bak']=textutils.serializeJSON({schemaVersion=1,coreID=0,remotes={}})
assert(s.writeJson(P,NEW,nil,valid))
assert(s.readJson(intent)==nil)
local value,_,status=s.readJson(remotes)
assert(value==nil and status=='invalid')
""",
'learning_roundtrip': r"""
reset();local t=thrust();assert(t.speedFeedforward==.022 and t.speedFeedforwardBands[1]==.024)
assert(not t.speedFeedforwardLoadReason)
t:learnSpeedFeedforward(5,.06,100)
assert(not t.speedFeedforwardSaveReason)
local restarted=thrust();assert(restarted.speedFeedforward==t.speedFeedforward)
assert(restarted.speedFeedforwardBands[1]==t.speedFeedforwardBands[1])
assert(Modules.Storage.readJson(P..'.bak').gain==OLD.gain)
assert(not FILES[P..'.tmp'])
""",
'backup_validation_and_boundaries': r"""
for _,bad in ipairs({'broken','{}','{"gain":-1}','{"gain":0.03,"bands":{"16":0.03}}',
 '{"gain":0.03,"bands":{"1":999}}','{"gain":0.03,"unit":"other"}'}) do
 reset();FILES[P]=bad;FILES[P..'.bak']=textutils.serializeJSON(OLD)
 local t=thrust();assert(t.speedFeedforward==OLD.gain and t.speedFeedforwardLoadReason:find('recovered backup',1,true))
end
reset();FILES[P]=nil;FILES[P..'.bak']=textutils.serializeJSON(OLD);assert(thrust().speedFeedforward==OLD.gain)
for _,gain in ipairs({.002,.08}) do
 reset();FILES[P]=textutils.serializeJSON({gain=gain});assert(thrust().speedFeedforward==gain)
end
reset();FILES[P]='broken';FILES[P..'.bak']='broken'
assert(math.abs(thrust().speedFeedforward-.031*.55)<1e-12)
""",
'failed_learning_save_retains_memory_and_control': r"""
reset();local t=thrust();t.output=.37;t.direction=-1
FAIL='write';FAILPATH=STATE..'.tmp';t:learnSpeedFeedforward(5,.06,100)
assert(t.speedFeedforward>OLD.gain and t.speedFeedforwardBands[1]>.024)
assert(t.speedFeedforwardSaveReason and t.output==.37 and t.direction==-1)
assertOld()
t:learnSpeedFeedforward(5,.06,131);assert(not t.speedFeedforwardSaveReason)
assert(thrust().speedFeedforward==t.speedFeedforward)
""",
'write_failure_boundaries': r"""
for _,step in ipairs({{'mkdir','/avionics/data'},{'open-w',STATE..'.tmp'},{'write',STATE..'.tmp'},
 {'close',STATE..'.tmp'},{'read',STATE..'.tmp'},{'delete',STATE..'.bak'},{'move',STATE},{'move',STATE..'.tmp'}}) do
 reset();assert(Modules.Storage.writeJson(P,OLD,nil,valid));assert(Modules.Storage.writeJson(P,OLD,nil,valid))
 FAIL=step[1];FAILPATH=step[2]
 local ok=Modules.Storage.writeJson(P,NEW,nil,valid);assert(not ok,step[1])
 assertOld()
end
""",
'invalid_primary_never_replaces_valid_backup': r"""
reset();FILES[P]='broken';FILES[P..'.bak']=textutils.serializeJSON(OLD)
FAIL='move';FAILPATH=STATE..'.tmp'
assert(not Modules.Storage.writeJson(P,NEW,nil,valid));assertOld()
assert(Modules.Storage.readJson(P..'.bak').gain==OLD.gain)
assert(Modules.Storage.writeJson(P,NEW,nil,valid))
assert(Modules.Storage.readJson(P..'.bak').gain==OLD.gain)
""",
'existing_primary_read_error_aborts_before_rotation': r"""
reset();FILES[P..'.bak']=nil
local old=FILES[P];FAIL='read';FAILPATH=P
assert(not Modules.Storage.writeJson(P,NEW,nil,valid))
assert(FILES[P]==old and not FILES[P..'.bak']);assertOld()
""",
'interrupted_transaction_restarts_from_valid_data': r"""
for _,step in ipairs({'open-w','write','close','read','delete','move','moved'}) do
 reset();assert(Modules.Storage.writeJson(P,OLD,nil,valid));assert(Modules.Storage.writeJson(P,OLD,nil,valid));CRASH=step;pcall(Modules.Storage.writeJson,P,NEW,nil,valid)
 FROZEN=false;assertOld()
end
reset();assert(Modules.Storage.writeJson(P,OLD,nil,valid));CRASH='moved';pcall(Modules.Storage.writeJson,P,NEW,nil,valid)
FROZEN=false;assert(Modules.Storage.writeJson(P,NEW,nil,valid))
assert(thrust().speedFeedforward==NEW.gain)
""",
'readback_and_schema_rejection': r"""
reset();assert(not Modules.Storage.writeJson(P,{gain=-1},nil,valid));assertOld()
local original=fs.open
fs.open=function(p,m)
 local h=original(p,m)
 if m=='r' and p==STATE..'.tmp' then h.readAll=function() return '{"gain":-1}' end end
 return h
end
assert(not Modules.Storage.writeJson(P,NEW,nil,valid));assertOld()
""",
'destination_replacement_and_interrupted_rename': r"""
reset();local path='/disk/amaryllis-destinations.json'
FILES[path]=textutils.serializeJSON({schemaVersion=1,destinations={{name='Home',x=1,z=2}}})
local lib=Modules.Destinations.new();assert(lib:change('save',nil,{name='Port',x=3,z=4}))
assert(#lib.entries==2 and lib.entries[1].name=='Home')
FAIL='move';FAILPATH=path..'.tmp'
assert(not lib:change('rename',2,{name='Harbour'}))
assert(lib:refresh() and #lib.entries==2 and lib.entries[2].name=='Port')
assert(lib:change('rename',2,{name='Harbour'}))
assert(lib.entries[1].name=='Home' and lib.entries[2].name=='Harbour')
""",
}


CASES.update({
'remote_activation_and_pairing_preserved': r"""
reset();FILES['/avionics/remote_client.lua']='return 1';FILES['/avionics/remote_ap_client.lua']='return 2'
FILES['/disk/startup.lua']='print("original")'
local result=Modules.Remote.install(Modules.Remote.inspect('drive'))
assert(FILES['/disk/remote/original-startup.lua']=='print("original")')
local active=FILES['/disk/remote/active.json'];local cfg=FILES['/disk/amaryllis-remote.json']
local record=Modules.Storage.readJson('/avionics/data/remotes.json')
record.remotes[result.pairID].flightAllowed=true
assert(Modules.Storage.writeJson('/avionics/data/remotes.json',record))
FILES['/avionics/remote_client.lua']='return 3'
result=Modules.Remote.install(Modules.Remote.inspect('drive'))
local before=textutils.unserializeJSON(cfg)
local after=textutils.unserializeJSON(FILES['/disk/amaryllis-remote.json'])
assert(after.pairID==before.pairID and after.token==before.token and after.coreID==before.coreID)
if not BUNDLED then assert(FILES['/disk/remote/active.json']~=active) end
assert(Modules.Storage.readJson('/avionics/data/remotes.json').remotes[result.pairID].flightAllowed)
assert(os.__amaryllisRemotePermissions[result.pairID] and not os.__amaryllisRemoteInstallLock)
assert(FILES['/disk/remote/original-startup.lua']=='print("original")')
""",
'remote_failed_activation_restores_registry_and_permissions': r"""
reset();FILES['/avionics/remote_client.lua']='return 1';FILES['/avionics/remote_ap_client.lua']='return 2'
FILES['/disk/startup.lua']='original()'
local registry={schemaVersion=1,coreID=0,remotes={prior={token=string.rep('a',64),flightAllowed=true}}}
local old=textutils.serializeJSON(registry);FILES['/avionics/data/remotes.json']=old
os.__amaryllisRemotePermissions={prior=true}
FAIL='write';FAILPATH='/disk/remote/active.json.remote-tmp'
local ok=pcall(Modules.Remote.install,Modules.Remote.inspect('drive'));assert(not ok)
assert(FILES['/disk/startup.lua']=='original()' and not FILES['/disk/amaryllis-remote.json'])
assert(FILES['/avionics/data/remotes.json']==old and not os.__amaryllisRemoteInstallLock)
assert(Modules.Storage.readJson('/avionics/data/remotes.json').remotes.prior.flightAllowed)
local n=0;for _ in pairs(os.__amaryllisRemotePermissions) do n=n+1 end
assert(n==1 and os.__amaryllisRemotePermissions.prior,'restore in-memory permissions with registry')
""",
'remote_media_change_stops_before_activation': r"""
reset();FILES['/avionics/remote_client.lua']='return 1';FILES['/avionics/remote_ap_client.lua']='return 2'
FILES['/disk/startup.lua']='original()'
local move=fs.move
fs.move=function(a,b)
 move(a,b)
 if b:find('/remote/releases/',1,true) then FILES['/disk/remote/installing.json']='different medium' end
end
assert(not pcall(Modules.Remote.install,Modules.Remote.inspect('drive')))
assert(FILES['/disk/startup.lua']=='original()' and not FILES['/disk/remote/active.json'])
assert(FILES['/disk/remote/installing.json']=='different medium' and not os.__amaryllisRemoteInstallLock)
""",
})

class PersistenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources={('/'+k):v for k,v in project.source_files().items() if k.endswith('.lua') and k.startswith('avionics/')}
        cls.entry=b"return {Thrust=require('avionics.thrust'),Storage=require('avionics.storage'),Destinations=require('avionics.destinations'),Remote=require('avionics.remote_install')}"
        cls.loader=(project.HOME/'assets/runtime-loader.lua').read_bytes()
        cls.bundle=project.builder_module().bundling.pack({**cls.sources,'/avionics/main.lua':cls.entry},cls.loader,role='persistence-test',entry='/avionics/main.lua')

    def runtime(self,bundled):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.globals().BUNDLED=bundled
        lua.globals().encode=lambda v:json.dumps(python_value(v),allow_nan=False,separators=(',',':'))
        def decode(s):
            try:return table(lua,json.loads(s))
            except (ValueError,TypeError):return None
        lua.globals().decode=decode
        lua.execute(HARNESS)
        if bundled:
            lua.execute('Modules=assert(load(...))()',self.bundle.decode())
        else:
            lua.globals().SOURCES=table(lua,{k:v.decode() for k,v in self.sources.items()})
            lua.execute("local loaded={};function require(n) if loaded[n] then return loaded[n] end;loaded[n]=assert(load(assert(SOURCES['/'..n:gsub('%.','/')..'.lua'],n),'@'..n))();return loaded[n] end")
            lua.execute('Modules=assert(load(...))()',self.entry.decode())
        return lua

for name,body in CASES.items():
    def test(self,body=body):
        for bundled in (False,True):
            with self.subTest(bundled=bundled):self.runtime(bundled).execute(body)
    setattr(PersistenceTests,'test_'+name,test)


# ======================================================================
# From test_persistent_modes: Persistent pilot modes against real Flight, Controls, AP and Presets modules.
# ======================================================================
from pathlib import Path
import json,sys,unittest
ROOT=Path(__file__).resolve().parents[1];HOME=ROOT/'disk-builder'
sys.path.insert(0,str(HOME))
from tests.test_builder import LuaRuntime, table
BASE=ROOT/'source/core'
def sources():
 names=['controls.lua','autopilot.lua','anchor.lua','flight.lua','control_presets.lua','remote_ap.lua']
 return {'/avionics/'+name:(BASE/'avionics'/name).read_bytes()for name in names}
def fixture_source():
 """Load the isolated flight/control fixture used by the persistence cases."""
 return (ROOT/'tests/fixtures/flight-control.lua').read_text(encoding='utf-8')

MODE_TESTS={
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
check(not c.requireNeutral,"AP fault hands the levers over at their position")
p:update(io,f,10)
check(store[p.path].modes.heading=="SEL"and store[p.path].modes.throttle=="SEL","fault does not save MANUAL defaults")
''',
'anchor_release':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local anchor=Anchor.new(io.config);anchor.active=true;anchor.state="HOLD"
anchor:cancel(f.controls,"RELEASED")
check(f.controls.modes.heading=="SEL"and f.controls.modes.throttle=="SEL","anchor release does not force DIRECT")
check(f.controls.targets.speed==4 and f.controls.targets.heading==120,"anchor release keeps selections")
check(f.controls.requireNeutral,"anchor release requires neutral")
''',
'disconnect_sample':r'''
local io,f,p,clock=setup();selected(io,f,p,clock)
local ap=f:ensureAutopilot(io);ap.active=true;io.autopilot=ap
sample(io,clock,11,{"ap_disconnect",15});f.controls:update(io,11)
check(not ap.active,"disconnect cancels AP")
check(f.controls.modes.heading=="SEL"and f.controls.modes.throttle=="SEL","disconnect keeps modes")
check(f.controls.targets.speed==4,"disconnect sample is not reused as zero-speed shortcut")
check(f.controls.request==0 and f.controls.disconnectLatch,"held disconnect click is latched")
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
'restore_and_identity':r'''
local io,f,p,clock=setup();selected(io,f,p,clock);local disk=clone(store)
io,f,p,clock=setup(clone(disk))
sample(io,clock,11,{"prop_forward",15});p:update(io,f,11)
check(not p.pending and f.controls.modes.throttle=="SEL","restore applies with the lever held")
io,f,p,clock=setup(clone(disk));io.vessel.uuid="different-vessel";io.vessel.heading=275;io.vessel.forwardSpeed=1.5;io.vessel.altitude=140
f.enabled=false;f.systemsRun=nil
sample(io,clock,11);p:update(io,f,11)
check(f.controls.modes.heading=="SEL"and f.controls.modes.throttle=="SEL","a new vessel ID keeps both modes")
check(f.controls.targets.heading==275 and f.controls.targets.speed==1.5,"a new vessel ID rereads SEL targets")
check(f.controls.targets.altitude==140,"a new vessel ID rereads the altitude target")
check(p.awaitResume and f.controls.request==0,"reread SEL is still held until START SYSTEMS is READY")
io,f,p,clock=setup(clone(disk));io.localID=36
sample(io,clock,11);p:update(io,f,11)
check(f.controls.modes.heading~="SEL","another core computer cannot inherit the saved modes")
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
 return fixture_source()+'\n'+''.join('do\n'+case+'\nend\n'for case in MODE_TESTS.values())+'\nreturn checks'
def runtime():
 lua=LuaRuntime(unpack_returned_tuples=True)
 lua.globals().CONFIG=table(lua,json.loads((BASE/'avionics/config.json').read_bytes()))
 lua.globals().package.path=(BASE/'?.lua').as_posix()+';'+lua.globals().package.path
 for path,body in sources().items():
  name='avionics.'+Path(path).stem
  lua.execute('local name,source=...;package.preload[name]=function()return assert(load(source))()end',name,body.decode('utf-8'))
 return lua
class PersistentModesTests(unittest.TestCase):
 """Each TESTS case runs as its own test against the current control modules."""
for name,case in MODE_TESTS.items():
 def run(self,case=case):
  lua=runtime();count=lua.execute(fixture_source()+'\n'+case+'\nreturn checks');self.assertGreater(count,0)
 setattr(PersistentModesTests,'test_'+name,run)


# ======================================================================
# From test_altitude_ceiling: Altitude ceiling: the selector, restored targets and AP destinations stay at or below it.
# ======================================================================
import unittest

CEILING_TESTS = {
'selector_stops_at_ceiling': r'''
local io,f,p,clock=setup()
local c=f.controls
check(io.config.altitude_control.altitude_ceiling==280,"shipped ceiling is Y 280")
c.targets.altitude=279.5
for i=1,40 do sample(io,clock,10+i*.25,{"altitude_up",15});c:update(io,10+i*.25) end
check(c.targets.altitude==280,"held ALT UP stops at the ceiling: "..tostring(c.targets.altitude))
''',
'target_above_ceiling_is_lowered': r'''
local io,f,p,clock=setup()
local c=f.controls
c.targets.altitude=300;sample(io,clock,11);c:update(io,11)
check(c.targets.altitude==280,"a target above the ceiling is lowered to it")
io.config.altitude_control.altitude_ceiling=250;sample(io,clock,12);c:update(io,12)
check(c.targets.altitude==250,"lowering the ceiling lowers the target")
io.config.altitude_control.altitude_ceiling=400;c.targets.altitude=330;sample(io,clock,13);c:update(io,13)
check(c.targets.altitude==330,"a ceiling above 314 allows higher targets")
''',
'ap_destination_capped': r'''
local io,f,p,clock=setup()
local ap=f:ensureAutopilot(io)
local ok,why=ap:edit(io,f.controls,{type="ap_edit",key="altitude",value=300},10)
check(ok,why);check(ap.draft.altitude==280,"destination altitude above the ceiling is set to it")
''',
'setting_and_validation': r'''
local Flight=require("avionics.flight")
local found
for _,field in ipairs(Flight._settingsFields) do if field.key=="altitude_ceiling" then found=field end end
check(found and found.group=="ALT PID","ceiling is edited on the ALT PID / LIMITS page")
local floor,maximum
for _,field in ipairs(Flight._settingsFields) do
  if field.key=="minimum_world_y" then floor=field end
  if field.key=="maximum_world_y" then maximum=field end
end
check(floor and floor.group=="ALT PID","Minimum target Y is on the ALT PID / LIMITS page")
check(maximum==nil,"Maximum target Y is no longer a setting")
local Storage=require("avionics.storage")
local config=clone(CONFIG);config.altitude_control.altitude_ceiling=config.altitude_control.minimum_world_y
local ok=Storage.validateConfig(config);check(not ok,"a ceiling at the minimum target Y is refused")
config.altitude_control.altitude_ceiling=280;ok=Storage.validateConfig(config);check(ok,"the shipped ceiling validates")
''',
}


class AltitudeCeilingTests(unittest.TestCase):
    """Each TESTS case runs on its own against the current control modules."""


for _name, _case in CEILING_TESTS.items():
    def _run(self, case=_case):
        count = runtime().execute(fixture_source() + '\n' + case + '\nreturn checks')
        self.assertGreater(count, 0)
    setattr(AltitudeCeilingTests, 'test_' + _name, _run)



class AltitudeTapeCeilingTests(unittest.TestCase):
    """The heading display's altitude tape leaves levels above core's ceiling blank."""

    def test_tape_blank_above_ceiling(self):
        import project
        from tests import test_builder as support
        text = (project.ROOT / "source/library/packages/common/heading-main.lua").read_text(encoding="utf-8")
        start = text.index("local function finite(value)")
        end = text.index("-- Summary: Build and flush the selected cached display view.")
        lua, _ = support.native_runtime()
        rows = lua.execute("local timeout,pollInterval=2,0.25\nlocal config={}\n" + text[start:end] + r'''
local function tape(ceiling)
 local snap={vessel={valid=true,heading=90,forwardSpeed=2,altitude=277.9,verticalSpeed=0},
  targets={heading=90,speed=3,altitude=280},modes={heading='SEL',throttle='SEL'},
  altitudeControl={enabled=true,ceiling=ceiling}}
 local s=drawCenter(snap,57,12);local out={}
 for y=1,12 do out[#out+1]=table.concat(s.rows[y].chars) end
 return table.concat(out,"\n")
end
return tape(280).."\n#\n"..tape(nil)''')
        capped, uncapped = rows.split("\n#\n")
        self.assertIn("280", capped)
        self.assertNotIn("290", capped)
        self.assertNotIn("300", capped)
        self.assertIn("300", uncapped, "without a ceiling from core the tape shows every level")


# ======================================================================
# From test_lever_handover: Cockpit levers act at their position after a handover; only the anchor release waits for neutral.
# ======================================================================
import json
import re
import unittest

import project
from tests import test_builder as support
from tests.test_builder import table


class LeverHandoverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        PersistenceTests.setUpClass()
        cls.config = json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes())

    def run_case(self, body):
        lua = PersistenceTests().runtime(False)
        lua.globals().CONFIG = table(lua, self.config)
        lua.execute(fixture_source() + "\n" + body)

    def test_mode_change_acts_at_lever_position_and_warns_briefly(self):
        self.run_case(r"""
local io,f,p,clock=setup()
local c=f.controls
sample(io,clock,10)
assert(c:mode(io,{axis="throttle",mode="DIRECT"},10))
sample(io,clock,10.2,{"prop_forward",15});c:update(io,10.2)
assert(c.request==1,"held throttle acts at once: "..tostring(c.request))
local snap={targets={}};c:decorate(snap)
assert(snap.cockpitControl.thrustNotNeutral==true,"warning shown after the handover")
assert(snap.cockpitControl.headingWaitingForNeutral==nil)
sample(io,clock,13.5,{"prop_forward",15});c:update(io,13.5)
snap={targets={}};c:decorate(snap)
assert(snap.cockpitControl.thrustNotNeutral==false,"warning clears after 3 s")
assert(c.request==1)
""")

    def test_neutral_lever_at_handover_raises_no_warning(self):
        self.run_case(r"""
local io,f,p,clock=setup()
local c=f.controls
sample(io,clock,10)
assert(c:mode(io,{axis="throttle",mode="DIRECT"},10))
sample(io,clock,10.2);c:update(io,10.2)
local snap={targets={}};c:decorate(snap)
assert(snap.cockpitControl.thrustNotNeutral==false)
sample(io,clock,10.4,{"prop_forward",15});c:update(io,10.4)
snap={targets={}};c:decorate(snap)
assert(c.request==1 and snap.cockpitControl.thrustNotNeutral==false,"a later push is ordinary input")
""")

    def test_lever_data_return_acts_without_neutral_gate(self):
        self.run_case(r"""
local io,f,p,clock=setup()
local c=f.controls
sample(io,clock,10);assert(c:mode(io,{axis="throttle",mode="DIRECT"},10));c:update(io,10)
io.inputs.valid=false;c:update(io,10.2)
assert(c.leversAvailable==false and not c.requireNeutral)
io.inputs.valid=true;sample(io,clock,10.4,{"prop_forward",15});c:update(io,10.4)
assert(c.request==1,"returning lever acts at its position")
""")

    def test_anchor_release_still_waits_for_neutral(self):
        self.run_case(r"""
local io,f,p,clock=setup()
local c=f.controls
sample(io,clock,10);assert(c:mode(io,{axis="throttle",mode="DIRECT"},10))
local anchor=Anchor.new(io.config);anchor.active=true;anchor.state="HOLD"
anchor:cancel(c,"ANCHOR RELEASED")
sample(io,clock,10.2,{"prop_forward",15});c:update(io,10.2)
assert(c.request==0 and c.requireNeutral,"anchor release holds levers")
assert(c.reason=="ANCHOR RELEASED: SET PROP_FORWARD TO NEUTRAL",tostring(c.reason))
sample(io,clock,10.4,{"prop_forward",0});c:update(io,10.4)
assert(not c.requireNeutral and c.reason==nil)
sample(io,clock,10.6,{"prop_forward",15});c:update(io,10.6)
assert(c.request==1)
""")

    def test_disconnect_click_that_ends_autopilot_is_latched(self):
        self.run_case(r"""
local io,f,p,clock=setup();selected(io,f,p,clock)
local c=f.controls
local ap=f:ensureAutopilot(io);ap.active=true;io.autopilot=ap
sample(io,clock,11,{"ap_disconnect",15});c:update(io,11)
assert(not ap.active and c.disconnectLatch)
sample(io,clock,11.2,{"ap_disconnect",15});c:update(io,11.2)
assert(c.targets.speed==4,"held click after disengaging keeps the selected speed")
sample(io,clock,11.4,{"ap_disconnect",0});c:update(io,11.4)
assert(not c.disconnectLatch)
sample(io,clock,11.6,{"ap_disconnect",15});c:update(io,11.6)
assert(c.targets.speed==0,"a new click is the zero-speed shortcut")
""")


class PropulsionStartGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.thrust = (project.ROOT / "source/core/avionics/thrust.lua").read_text(encoding="utf-8")
        cls.flight = (project.ROOT / "source/core/avionics/flight.lua").read_text(encoding="utf-8")

    def extract(self, text, name):
        return re.search(r"function " + re.escape(name) + r"\(.*?\nend\n", text, re.S).group(0)

    def test_enable_waits_for_systems_ready(self):
        lua, _ = support.native_runtime()
        lua.execute("Thrust={}\nlocal function copy(v) if type(v)~='table' then return v end local r={} for k,x in pairs(v) do r[k]=copy(x) end return r end\n"
                    + self.extract(self.thrust, "Thrust:setEnabled") + r"""
local t={config={thrust={enabled=false}},stopped=nil}
function t:activationReady() return true end
function t:stop(io,reason) self.stopped=reason end
function t:resetSpeedLoop() end function t:resetManualAccelerationLoop() end function t:resetHeadingLoop() end
setmetatable(t,{__index=Thrust})
local storage={validateConfig=function() return true end,saveConfigChanges=function(path,config,changes) SAVED=changes[1].value return true end}
local io={config={thrust={enabled=false}}}
local controls={holds={},noteHandover=function(self) self.noted=true end}
local ok,why=t:setEnabled(io,0,controls,true,storage,{})
assert(not ok and why=="START SYSTEMS NOT READY",tostring(why))
io.systemsReady=true
ok,why=t:setEnabled(io,0,controls,true,storage,{})
assert(ok and why=="PROPULSION ENABLED" and SAVED==true and controls.noted)
ok,why=t:setEnabled(io,0,controls,false,storage,{},"PROPULSION OFF UNTIL START SYSTEMS READY")
assert(ok and SAVED==false and t.stopped=="PROPULSION OFF UNTIL START SYSTEMS READY")
""")

    def test_stop_systems_saves_propulsion_off(self):
        lua, _ = support.native_runtime()
        lua.execute("Flight={}\nlocal function logOperationIssue() end\n"
                    + self.extract(self.flight, "Flight:disablePropulsionForStop") + r"""
local calls,cancelled={},{}
local thrust={config={thrust={enabled=true}}}
function thrust:setEnabled(io,now,controls,enabled,storage,deps,reason)
  calls[#calls+1]={enabled=enabled,reason=reason};self.config.thrust.enabled=enabled;return true
end
local self={controls={},storage={},settingsDependencies={}}
local io={thrust=thrust,autopilot={cancel=function(_,io,c,why) cancelled[#cancelled+1]=why end},
  positionAnchor={cancel=function(_,c,why) cancelled[#cancelled+1]=why end}}
Flight.disablePropulsionForStop(self,io,1)
assert(#calls==1 and calls[1].enabled==false and calls[1].reason=="PROPULSION OFF: SYSTEMS STOPPED")
assert(#cancelled==2,"AP and the anchor are cancelled")
Flight.disablePropulsionForStop(self,io,2)
assert(#calls==1,"already off: nothing saved again")
""")
        start = self.flight.index("function Flight:startSystems(")
        start_end = self.flight.index("\nfunction ", start + 10)
        self.assertNotIn("disablePropulsion", self.flight[start:start_end], "START SYSTEMS keeps the saved state")
        confirm = self.flight.index("function Flight:confirmShutdown(")
        confirm_end = self.flight.index("\nfunction ", confirm + 10)
        self.assertIn("self:disablePropulsionForStop(io,now)", self.flight[confirm:confirm_end])
        self.assertNotIn("disablePropulsion", (project.ROOT / "source/core/avionics/restart.lua").read_text(encoding="utf-8"))


# ======================================================================
# From test_config_registry: Settings registry agrees with config.json, Storage.validateConfig, the settings editor and inline fallbacks.
# ======================================================================
import copy
import json
import math
import sys
import unittest

import project

sys.path.insert(0, str(project.ROOT / "tools"))
import config_registry as registry_tool  # noqa: E402

# Shipped tables that are validated as a group rather than as individual settings.
GROUPED = ("lateral_mixer.", "verified_gas_lift_strengths.", "primary_rpm_limits.", "acceleration_drive_limits.")
# Settings whose accepted bounds depend on another setting, so the bound itself is not probed alone.
CROSS_FIELD = {"altitude_control.minimum_world_y", "altitude_control.altitude_ceiling",
               "altitude_control.startup_max_vertical_speed", "altitude_control.startup_vertical_speed_limit",
               "thrust.command_ttl_seconds"}
# Expressions replaced by Registry.number in Delivery 5, copied verbatim from the previous source.
REPLACED = {
    "altitude_control.vertical_drag_support_per_bps":
        "finite(c.vertical_drag_support_per_bps) and clamp(c.vertical_drag_support_per_bps,0,0.05) or 0.019",
    "thrust.zero_brake_stop_bps": "finite(c.zero_brake_stop_bps) and math.max(0,c.zero_brake_stop_bps) or 2",
    "thrust.zero_brake_gain": "finite(c.zero_brake_gain) and clamp(c.zero_brake_gain,0,1) or 0.06",
    "thrust.drag_time_constant_seconds":
        "finite(c.drag_time_constant_seconds) and clamp(c.drag_time_constant_seconds,1,60) or 5.5",
    "thrust.speed_lead_seconds": "finite(c.speed_lead_seconds) and math.max(0,math.min(5,c.speed_lead_seconds)) or 2",
    "thrust.speed_integrate_band_bps": "finite(c.speed_integrate_band_bps) and c.speed_integrate_band_bps or 2",
    "thrust.speed_trim_down_limit": "finite(c.speed_trim_down_limit) and clamp(c.speed_trim_down_limit,0,1) or 0.3",
    "thrust.reverse_brake_margin_bps":
        "finite(c.reverse_brake_margin_bps) and math.max(0,c.reverse_brake_margin_bps) or math.huge",
    "thrust.speed_feedforward_per_bps": "finite(c.speed_feedforward_per_bps) and c.speed_feedforward_per_bps or 0.031",
    "thrust.zero_hold_capture_speed": "finite(c.zero_hold_capture_speed) and math.max(0,c.zero_hold_capture_speed) or 0.1",
}


class ConfigRegistryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entries = registry_tool.registry()
        cls.by_id = {e["section"] + "." + e["path"]: e for e in cls.entries}
        cls.config = json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes())
        cls.lua = registry_tool.runtime()
        cls.storage = cls.lua.eval('require("avionics.storage")')
        cls.registry = cls.lua.eval('require("avionics.config_registry")')

    def valid(self, config):
        result = self.storage.validateConfig(registry_tool.lua_value(self.lua, config))
        return (result[0] if isinstance(result, tuple) else result) is True

    def edited(self, entry, value, remove=False):
        config = copy.deepcopy(self.config)
        node = config[entry["section"]]
        parts = entry["path"].split(".")
        for key in parts[:-1]:
            node = node[key]
        if remove:
            del node[parts[-1]]
        else:
            node[parts[-1]] = value
        return config

    def test_ids_are_unique_and_cover_shipped_settings(self):
        self.assertEqual(len(self.by_id), len(self.entries))
        for (section, path), value in registry_tool.shipped().items():
            if path.startswith(GROUPED):
                continue
            with self.subTest(setting=section + "." + path):
                self.assertIn(section + "." + path, self.by_id)
        code_read = registry_tool.fallbacks()
        for identifier, entry in self.by_id.items():
            shipped = (entry["section"], entry["path"]) in registry_tool.shipped()
            with self.subTest(setting=identifier):
                self.assertTrue(shipped or (entry["section"], entry["path"]) in code_read,
                                "registered setting is neither shipped nor read by the control code")

    def test_shipped_values_satisfy_registry(self):
        for (section, path), value in registry_tool.shipped().items():
            entry = self.by_id.get(section + "." + path)
            if entry is None:
                continue
            with self.subTest(setting=section + "." + path):
                accepted = self.registry.check(registry_tool.lua_value(self.lua, entry), value)
                self.assertIs(accepted[0] if isinstance(accepted, tuple) else accepted, True)

    def test_schema_bounds_match_config_validation(self):
        self.assertTrue(self.valid(self.config))
        for identifier, entry in self.by_id.items():
            if entry["bound"] != "schema" or entry["kind"] == "boolean":
                continue
            with self.subTest(setting=identifier):
                step = 1 if entry["kind"] == "integer" else 1e-6
                if "min" in entry:
                    self.assertFalse(self.valid(self.edited(entry, entry["min"] - step)), "below minimum accepted")
                    if identifier not in CROSS_FIELD:
                        self.assertEqual(self.valid(self.edited(entry, entry["min"])), not entry.get("minExclusive"))
                if "max" in entry and identifier not in CROSS_FIELD:
                    self.assertFalse(self.valid(self.edited(entry, entry["max"] + step)), "above maximum accepted")
                    if identifier not in CROSS_FIELD:
                        self.assertEqual(self.valid(self.edited(entry, entry["max"])), not entry.get("maxExclusive"))
                if entry["kind"] == "integer" and "min" in entry and entry.get("max", math.inf) > entry["min"]:
                    self.assertFalse(self.valid(self.edited(entry, entry["min"] + 0.5)), "fraction accepted")

    def test_required_flags_match_config_validation(self):
        for identifier, entry in self.by_id.items():
            if (entry["section"], entry["path"]) not in registry_tool.shipped():
                self.assertFalse(entry.get("required", False), identifier)
                continue
            with self.subTest(setting=identifier):
                self.assertEqual(not self.valid(self.edited(entry, None, remove=True)), entry.get("required", False))

    def test_fallbacks_match_the_control_code(self):
        found = registry_tool.fallbacks()
        for (section, path), values in found.items():
            entry = self.by_id.get(section + "." + path)
            if entry is None:
                continue
            with self.subTest(setting=section + "." + path):
                inline = {v for v in values if v is not None}
                if None in values:
                    self.assertNotEqual(entry["bound"], "schema")
                    self.assertEqual(len(entry["fallbacks"]), 1)
                    self.assertEqual(inline, set(), "setting read both inline and through the registry")
                else:
                    self.assertEqual(inline, set(entry.get("fallbacks", [])))
        for identifier, entry in self.by_id.items():
            if entry.get("fallbacks"):
                with self.subTest(setting=identifier):
                    self.assertIn((entry["section"], entry["path"]), found, "registered fallback no longer used")

    def test_registry_number_reproduces_replaced_expressions(self):
        lua = registry_tool.runtime()
        lua.execute("Mathx=require('avionics.mathx');finite=Mathx.finite;clamp=Mathx.clamp;"
                    "Registry=require('avionics.config_registry')")
        samples = ["nil", "0/0", "math.huge", "-math.huge", "'3'", "-100", "-1", "0", "0.004", "0.019", "0.5",
                   "1", "2.5", "5", "7", "60", "100", "1e9"]
        for identifier, expression in REPLACED.items():
            key = identifier.split(".", 1)[1]
            for sample in samples:
                with self.subTest(setting=identifier, value=sample):
                    old, new = lua.execute(
                        f"local c={{{key}={sample}}};return ({expression}),Registry.number(c,'{identifier}')")
                    self.assertEqual(old, new)

    def test_settings_editor_ranges_fit_registry_bounds(self):
        lua = registry_tool.runtime()
        fields = lua.execute("""
            local Flight=require('avionics.flight')
            local out={}
            for _,f in ipairs(Flight._settingsFields or {}) do
                out[#out+1]={path=table.concat(f.path,'.'),min=f.min,max=f.max}
            end
            return out""")
        fields = [dict(f.items()) for f in fields.values()]
        self.assertTrue(fields, "settings editor fields are not exposed for checking")
        checked = 0
        for field in fields:
            entry = self.by_id.get(field["path"])
            if entry is None or entry["kind"] == "boolean":
                continue
            checked += 1
            with self.subTest(setting=field["path"]):
                for value in (field["min"], field["max"]):
                    accepted = self.registry.check(registry_tool.lua_value(self.lua, entry), value)
                    self.assertIs(accepted[0] if isinstance(accepted, tuple) else accepted, True,
                                  f"editor allows {value}, registry rejects it")
        self.assertGreater(checked, 30)

    def test_merge_save_rejects_out_of_bound_registered_edits(self):
        lua = registry_tool.runtime()
        lua.globals().CONFIG = registry_tool.lua_value(lua, self.config)
        lua.execute(r"""
            FILES={}
            local function encode(v) return textutils_encode(v) end
            fs={exists=function(p) return FILES[p]~=nil end,makeDir=function() end,getDir=function(p) return p:match('^(.*)/') or '' end,
                open=function(p,m)
                    if m=='r' then if not FILES[p] then return nil end
                        return {readAll=function() return FILES[p] end,close=function() end} end
                    FILES[p]='';return {write=function(s) FILES[p]=s end,close=function() end} end,
                delete=function(p) FILES[p]=nil end,move=function(a,b) FILES[b]=FILES[a];FILES[a]=nil end,
                getSize=function(p) return #FILES[p] end,isReadOnly=function() return false end,
                getFreeSpace=function() return 1e7 end,isDir=function() return false end}
        """)
        lua.globals().py_encode = lambda v: json.dumps(_python(v))
        lua.globals().py_decode = lambda s: registry_tool.lua_value(lua, json.loads(s))
        lua.execute("textutils={serializeJSON=function(v) return py_encode(v) end,"
                    "unserializeJSON=function(s) return py_decode(s) end}")
        lua.globals().FILES["/avionics/config.json"] = json.dumps(self.config)
        save = lua.eval("function(changes) local S=require('avionics.storage');"
                        "return S.saveConfigChanges('/avionics/config.json',CONFIG,changes) end")

        def run(path, value):
            changes = lua.table_from([lua.table_from({"path": lua.table_from(path.split(".")), "value": value})])
            result = save(changes)
            return result if isinstance(result, tuple) else (result,)

        before = lua.globals().FILES["/avionics/config.json"]
        ok, reason = run("thrust.zero_brake_gain", 2)[:2]
        self.assertFalse(ok)
        self.assertIn("THRUST.ZERO_BRAKE_GAIN", reason)
        self.assertEqual(lua.globals().FILES["/avionics/config.json"], before)
        ok, reason = run("altitude_control.launch_settle_seconds", 2.5)[:2]
        self.assertFalse(ok)
        self.assertIn("WHOLE NUMBER", reason)
        self.assertTrue(run("altitude_control.level_damping_gain", 0)[0])
        self.assertTrue(run("thrust.manual_acceleration_enabled", False)[0])
        saved = json.loads(lua.globals().FILES["/avionics/config.json"])
        self.assertEqual(saved["altitude_control"]["level_damping_gain"], 0)
        self.assertIs(saved["thrust"]["manual_acceleration_enabled"], False)
        self.assertTrue(run("thrust.zero_brake_gain", 0.08)[0])
        self.assertEqual(json.loads(lua.globals().FILES["/avionics/config.json"])["thrust"]["zero_brake_gain"], 0.08)

    def test_tuning_reference_tables_are_generated_from_registry(self):
        text = registry_tool.REFERENCE.read_text(encoding="utf-8")
        start = text.index(registry_tool.BEGIN)
        end = text.index(registry_tool.END) + len(registry_tool.END)
        self.assertEqual(text[start:end], registry_tool.render(),
                         "run: python tools/config_registry.py --write")


def _python(value):
    """Convert a Lua table to JSON-compatible Python values, treating 1..n keys as arrays."""
    if hasattr(value, "items"):
        items = dict(value.items())
        if items and all(isinstance(k, int) for k in items) and sorted(items) == list(range(1, len(items) + 1)):
            return [_python(items[i]) for i in range(1, len(items) + 1)]
        return {k: _python(v) for k, v in items.items()}
    return value


# ======================================================================
# From test_settings_navigation: Every navigator settings page reaches GENERAL through BACK, whatever its group is named.
# ======================================================================
import re
import unittest

import project
from tests import test_builder as support


class SettingsNavigationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ui = (project.ROOT / "source/library/packages/navigation/ui.lua").read_text(encoding="utf-8")
        core = "".join((project.ROOT / "source/core/avionics" / name).read_text(encoding="utf-8")
                       for name in ("flight.lua", "input_tuning.lua"))
        block = re.search(r"local SETTINGS_PAGES=\{.*?\} -- end SETTINGS_PAGES", cls.ui, re.S).group(0)
        lua, _ = support.native_runtime()
        lua.execute(block.replace("local SETTINGS_PAGES", "SETTINGS_PAGES"))
        table = lua.globals().SETTINGS_PAGES
        cls.pages = {key: dict(value.items()) for key, value in table.items()}
        cls.views = set(re.findall(r'view\("([A-Z ]+)"\)', cls.ui))
        cls.groups = set(re.findall(r'field\("([A-Z ]+)"', core)) | {"PROPULSION"}

    def parent(self, page):
        return self.pages.get(page, {}).get("parent", "GENERAL")

    def test_every_page_returns_to_general_without_loops(self):
        for page in sorted(self.views | self.groups | set(self.pages)):
            seen, current = [], page
            while current != "GENERAL":
                self.assertNotIn(current, seen, f"BACK loop from {page}: {seen}")
                seen.append(current)
                current = self.parent(current)
            self.assertLessEqual(len(seen), 4, f"{page} takes {len(seen)} BACK presses")

    def test_parents_are_real_pages(self):
        for page, info in self.pages.items():
            parent = info.get("parent")
            self.assertTrue(parent == "GENERAL" or parent in self.views, f"{page} has unknown parent {parent}")

    def test_cockpit_input_pages_return_to_cockpit_inputs(self):
        for group in ("SEL HEADING", "SEL THROTTLE", "INPUT ALTITUDE", "STRAFE SETTINGS"):
            self.assertIn(group, self.groups)
            self.assertIn(group, self.views)
            self.assertEqual(self.parent(group), "TARGET")

    def test_back_uses_the_table(self):
        self.assertIn('view((SETTINGS_PAGES[sub] or {}).parent or "GENERAL")', self.ui)
        self.assertNotIn('sub:match("^INPUT")', self.ui)
        self.assertNotIn('sub:match("^PROP")', self.ui)


if __name__ == "__main__":
    import unittest
    unittest.main()
