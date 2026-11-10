"""Cockpit levers act at their position after a handover; only the anchor release waits for neutral."""
import json
import re
import unittest

import project
from tests import test_persistence as persistence
from tests import test_persistent_modes as modes
from tests import test_runtime_bundling as support
from tests.test_runtime_bundling import table


class LeverHandoverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        persistence.PersistenceTests.setUpClass()
        cls.config = json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes())

    def run_case(self, body):
        lua = persistence.PersistenceTests().runtime(False)
        lua.globals().CONFIG = table(lua, self.config)
        lua.execute(modes.fixture_source() + "\n" + body)

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


if __name__ == "__main__":
    unittest.main()
