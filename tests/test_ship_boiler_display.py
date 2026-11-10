"""Ship page chamber headers show each chamber's lowest measured boiler efficiency."""
import unittest

import project
from tests import test_bridge_presentation as bridge
from tests import test_runtime_bundling as support


class ShipBoilerDisplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = support.b.collect_project(project.ROOT)
        source = support.bundle.prepare(source, support.b.FOLDERS)
        cls.bundle = source['library']['/packages/navigation/main.lua'].decode()

    def setUp(self):
        self.lua, _ = support.native_runtime()
        self.lua.globals().UI = self.lua.execute(self.bundle, support.bundle.MAGIC, '/avionics/ui.lua')
        self.lua.globals().CAPTURES = self.lua.table()
        self.lua.execute(bridge.HARNESS)

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


if __name__ == '__main__':
    unittest.main()
