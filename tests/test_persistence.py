"""Current-source and bundled persistence transactions with filesystem fault injection."""
import json
import unittest
import project
from tests.test_runtime_bundling import LuaRuntime, table, python_value

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

if __name__=='__main__':unittest.main()
