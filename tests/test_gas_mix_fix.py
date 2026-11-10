"""Fix gas mix lag: core restarts each chamber's trim probe link (off, then back to its level)."""
import unittest

import project
from tests import test_runtime_bundling as support
from tests.test_persistent_modes import runtime, fixture_source

HARDWARE = (project.ROOT / "source/library/packages/common/chamber-hardware.lua").read_text(encoding="utf-8")
LINK = r'''
local Hardware=assert(load(SOURCE))().lift
LEVEL=...;WRITES={};WAITS={};READ_FAILS=0
local api={hasType=function() return true end,
    getMethods=function() return {"getLinkSignal","sendLinkSignal"} end,
    call=function(name,method,first,second,level)
        if method=="getLinkSignal" then
            if READ_FAILS>0 then return nil end
            return LEVEL
        end
        if method=="sendLinkSignal" then WRITES[#WRITES+1]=level;LEVEL=level;return true end
    end}
CONFIG={activationBridge="redstone_link_bridge_0",trimActivationFrequency={first="minecraft:blaze_rod",second="minecraft:coal"}}
function cycle() return Hardware.cycleProbeLink(CONFIG,api,1,function(s) WAITS[#WAITS+1]=s end) end
'''


class ProbeLinkCycleTests(unittest.TestCase):
    def lua(self, level):
        lua, _ = support.native_runtime()
        lua.globals().SOURCE = HARDWARE
        lua.execute(LINK, level)
        return lua

    def test_link_goes_off_then_back_to_its_level(self):
        lua = self.lua(15)
        ok, detail = lua.execute("return cycle()")
        self.assertTrue(ok, detail)
        self.assertEqual(detail, "PROBE RESTARTED")
        self.assertEqual(list(lua.globals().WRITES.values()), [0, 15])
        self.assertEqual(lua.globals().WAITS[1], 1)

    def test_link_that_was_off_stays_off(self):
        lua = self.lua(0)
        ok, detail = lua.execute("return cycle()")
        self.assertTrue(ok)
        self.assertIn("LEFT OFF", detail)
        self.assertEqual(len(lua.globals().WRITES), 0)

    def test_unreadable_link_is_refused_without_writing(self):
        lua = self.lua(15)
        ok, detail = lua.execute("READ_FAILS=1;return cycle()")
        self.assertFalse(ok)
        self.assertEqual(len(lua.globals().WRITES), 0)


CORE = r'''
local io,f,p,clock=setup()
local sent={}
io.nodes={};for _,q in ipairs({"FL","FR","BL","BR"}) do io.nodes[q]={boot="boot-"..q,id=({FL=14,FR=9,BL=13,BR=10})[q]} end
io.config.node_ids={FL=14,FR=9,BL=13,BR=10}
io.session="core-session"
function io:nodeFresh() return true end
function io:sendLiftMaintenance(q,operation) sent[#sent+1]=q..":"..operation;return true,#sent end
f.enabled=true;f.startupPending=nil;f.systemsRun=nil;f.tuningRun=nil;f.maintenanceJob=nil
local ok,why=f:maintenanceRequest(io,{type="maintenance_probe_cycle",scope="ALL"},10)
check(not ok and why=="DISENGAGE ALTITUDE CONTROL FIRST","altitude control must be off: "..tostring(why))
f.enabled=false
ok,why=f:maintenanceRequest(io,{type="maintenance_probe_cycle",scope="ALL"},10)
check(ok,why);check(sent[1]=="FL:probe_cycle","first chamber asked to restart its probe")
check(f.maintenanceStatus=="FL RESTARTING PROBE",f.maintenanceStatus)
for i,q in ipairs({"FL","FR","BL","BR"}) do
    local job=f.maintenanceJob
    check(f:maintenanceAck(io,io.config.node_ids[q],{v=1,kind="lift_maintenance_ack",session="core-session",seq=job.seq,
        operation="probe_cycle",quadrant=q,nodeBoot="boot-"..q,ok=true,detail="PROBE RESTARTED"},10+i),"ack "..q)
    f:updateMaintenance(io,10+i)
end
check(#sent==4 and sent[4]=="BR:probe_cycle","all four chambers in order")
check(f.maintenanceStatus=="GAS MIX FIX COMPLETE",tostring(f.maintenanceStatus))
check(f.maintenanceJob==nil,"job finished")
return checks
'''


class CoreGasMixFixTests(unittest.TestCase):
    def test_core_restarts_every_chamber_probe_in_turn(self):
        lua = runtime()
        self.assertGreater(lua.execute(fixture_source() + "\n" + CORE), 0)


PANEL = r'''
local Panel=assert(load(SOURCE))()
keys=keys or {up=200,down=208,pageUp=201,pageDown=209,backspace=14,escape=1}
QUEUED={}
os.queueEvent=function(name,value) QUEUED[#QUEUED+1]={name,value} end
CONTEXT={id=3,now=0,runtime={snapshot={altitudeControl={enabled=false},maintenance={}}}}
panel=Panel.new({pageRows=function() return {} end},{})
function screen() local f=panel:frame(CONTEXT,51,19);panel.links=f.links;return table.concat(f.text,"\n") end
function press(label)
    local f=panel:frame(CONTEXT,51,19)
    for _,link in ipairs(f.links) do
        local text=f.text[link.y]:sub(link.x,link.x+link.w-1)
        if text:find(label,1,true) then panel:action(link.action);return true end
    end
    error("no button "..label)
end
'''


class PanelGasMixTests(unittest.TestCase):
    def panel(self):
        lua, _ = support.native_runtime()
        lua.globals().SOURCE = (project.ROOT / "disk-builder/assets/panel-console.lua").read_text(encoding="utf-8")
        lua.execute(PANEL)
        return lua

    def test_tools_page_opens_the_fix_with_confirmation(self):
        lua = self.panel()
        lua.execute('panel:choose("tools")')
        self.assertIn("Fix gas mix lag >", lua.execute("return screen()"))
        lua.execute('press("Fix gas mix lag >")')
        text = lua.execute("return screen()")
        self.assertIn("FIX GAS MIX LAG", text)
        self.assertIn("Mixing Hot Air and Steam in balloons", text)
        self.assertIn("READY", text)
        lua.execute('press("Fix gas mix lag")')
        self.assertIn("Confirm", lua.execute("return screen()"))
        self.assertEqual(lua.execute("return #QUEUED"), 0, "nothing runs before confirmation")
        lua.execute('press("Confirm")')
        self.assertEqual(lua.execute("return QUEUED[1][1]"), "amaryllis_core_action")
        self.assertEqual(lua.execute("return QUEUED[1][2].type"), "maintenance_probe_cycle")

    def test_status_shows_refusal_and_progress(self):
        lua = self.panel()
        lua.execute('panel:choose("gasMix")')
        lua.execute('CONTEXT.runtime.snapshot.altitudeControl.enabled=true')
        self.assertIn("DISENGAGE ALTITUDE CONTROL FIRST", lua.execute("return screen()"))
        lua.execute('os.__amaryllisCoreAction={type="maintenance_probe_cycle",accepted=true};CONTEXT.runtime.snapshot.maintenance.status="BL RESTARTING PROBE"')
        self.assertIn("BL RESTARTING PROBE", lua.execute("return screen()"))
        lua.execute('os.__amaryllisCoreAction=nil')

    def test_core_runtime_runs_console_actions(self):
        text = (project.ROOT / "source/core/avionics/main.lua").read_text(encoding="utf-8")
        self.assertIn('event=="amaryllis_core_action"', text)
        self.assertIn("pcall(flight.request,flight,io,sender,now)", text)
        self.assertIn("os.__amaryllisCoreAction=", text)

    def test_tools_page_scrolls_when_buttons_do_not_fit(self):
        lua = self.panel()
        lua.execute('panel:choose("tools")')
        text = lua.execute("return screen()")
        self.assertIn("Shell >", text)
        self.assertIn("1-7 / 8", text)
        self.assertNotIn("Background services >", text)
        lua.execute('panel:input("key",keys.down)')
        text = lua.execute("return screen()")
        self.assertNotIn("Shell >", text)
        self.assertIn("Background services >", text)
        self.assertIn("2-8 / 8", text)
        lua.execute('panel:input("mouse_scroll",-1)')
        self.assertIn("Shell >", lua.execute("return screen()"))
        lua.execute('press("Fix gas mix lag >")')
        self.assertIn("FIX GAS MIX LAG", lua.execute("return screen()"))
        tall = lua.execute('panel:choose("tools");local f=panel:frame(CONTEXT,51,24);return table.concat(f.text,"\\n")')
        self.assertIn("Background services >", tall)
        self.assertNotIn("/ 8", tall)


if __name__ == "__main__":
    unittest.main()
