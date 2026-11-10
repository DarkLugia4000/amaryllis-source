"""Forward speed source and the selected-speed stall fix."""
import json
import re
import unittest

import project
from tests import test_runtime_bundling as support
from tests.test_runtime_bundling import table

ROOT = project.ROOT / "source/core/avionics"


class ForwardSpeedSourceTests(unittest.TestCase):
    def compose(self, sensor_speed, sable=3.87, reader=None):
        lua, _ = support.native_runtime()
        sources = {"/avionics/" + p.name: p.read_text(encoding="utf-8") for p in ROOT.glob("*.lua")}
        lua.globals().SOURCES = table(lua, sources)
        lua.globals().CONFIG = table(lua, json.loads((ROOT / "config.json").read_bytes()))
        lua.globals().SENSOR = sensor_speed
        lua.globals().SABLE = sable
        lua.globals().READER = reader
        return lua.execute(r'''
local loaded={}
function require(n) if loaded[n] then return loaded[n] end;loaded[n]=assert(load(SOURCES["/"..n:gsub("%.","/")..".lua"],n))();return loaded[n] end
local S=require("avionics.vessel_sources")
local io={config=CONFIG,sensorBindings={velocity_sensors={"vx"}},hardwareFingerprint="f"}
local now=100
S.acceptPrimary(io,"uuid","ship",now)
S.acceptPrimary(io,"pose",{orientation={x=0,y=0,z=0,w=1},position={x=0,y=160,z=0},rotationPoint={x=0,y=0,z=0},scale={x=1,y=1,z=1}},now)
S.acceptPrimary(io,"com",{x=0,y=0,z=0},now)
if SABLE then S.acceptPrimary(io,"velocity",{x=SABLE,y=0,z=0},now,"core") end
if READER then S.acceptPrimary(io,"velocity",{x=READER,y=0,z=0},now+0.5,"reader") end
S.acceptPrimary(io,"mass",140000,now)
if SENSOR then io.fallbackReadings={["velocity:vx"]={value={axis="x",speed=SENSOR,name="vx"},at=now}} end
local v=S.compose(io,now+0.5)
return v.forwardSpeed,v.forwardSpeedSource,(v.sources or {}).mode,v.forwardSpeedSableCore,v.forwardSpeedSableReader,v.forwardSpeedSensor
''')

    def test_sable_velocity_sets_forward_speed(self):
        speed, source, mode, *_ = self.compose(6.26, sable=6.26)
        self.assertAlmostEqual(speed, 6.26)
        self.assertEqual(source, "SABLE")
        self.assertEqual(mode, "PRIMARY")

    def test_velocity_sensor_is_the_fallback(self):
        speed, source, *_ = self.compose(6.26, sable=None)
        self.assertAlmostEqual(speed, 6.26)
        self.assertEqual(source, "VELOCITY SENSOR")

    def test_core_reading_wins_over_a_newer_reader_reading(self):
        speed, source, _, core, reader, sensor = self.compose(6.0, sable=6.26, reader=3.87)
        self.assertAlmostEqual(speed, 6.26)
        self.assertAlmostEqual(core, 6.26)
        self.assertAlmostEqual(reader, 3.87)
        self.assertAlmostEqual(sensor, 6.0)

    def test_reader_fills_in_without_core_reading(self):
        speed, *_ = self.compose(None, sable=None, reader=3.87)
        self.assertAlmostEqual(speed, 3.87)


class SpeedStallTests(unittest.TestCase):
    def test_steady_speed_outside_the_band_still_integrates(self):
        text = (ROOT / "thrust.lua").read_text(encoding="utf-8")
        self.assertIn("loop.steadySpeedSeconds>=3", text)
        self.assertIn("math.abs(error)<=integrateBand or loop.steadySpeedSeconds>=3", text)


if __name__ == "__main__":
    unittest.main()
