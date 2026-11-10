"""geometry.sable_bow_axis sets the Sable pose-frame bow; bow-axis learning is removed."""
import json
import re
import unittest

import project


class BowAxisLockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = project.ROOT / "source/core/avionics"
        cls.config = json.loads((root / "config.json").read_bytes())
        cls.io = (root / "io.lua").read_text(encoding="utf-8")
        cls.sources = (root / "vessel_sources.lua").read_text(encoding="utf-8")
        cls.storage = (root / "storage.lua").read_text(encoding="utf-8")

    def test_amaryllis_bow_is_plus_x(self):
        self.assertEqual(self.config["geometry"]["sable_bow_axis"], {"x": 1, "y": 0, "z": 0})

    def test_core_attitude_uses_the_configured_axis_only(self):
        body = re.search(r"local function resolveVesselAttitude\(.*?\nend\n", self.io, re.S).group(0)
        self.assertIn('local attitudeAxisSource="CONFIGURED"', body)
        self.assertIn('"Sable pose / configured bow"', body)
        for removed in ("chamberAttitudeAxis", "attitudeAxisLatch", "HEADING MATCH", "CHAMBER HEIGHTS"):
            self.assertNotIn(removed, self.io)
        self.assertNotIn("attitude-axis.json", self.io)

    def test_vessel_sources_prefer_the_configured_axis(self):
        self.assertIn('p.attitudeAxisSource="CONFIGURED"', self.sources)
        self.assertNotIn("attitudeAxisLearned", self.sources)
        self.assertIn("local bow=lockedBow and {x=lockedBow.x,y=0,z=lockedBow.z} or (c and c.bow) or vec(p.attitudeBow)", self.sources)

    def test_config_validation_accepts_only_horizontal_unit_axes(self):
        self.assertIn('geometry.sable_bow_axis must be +X, -X, +Z or -Z in the Sable pose frame', self.storage)


class BowAxisLockSamplingTests(unittest.TestCase):
    def test_configured_axis_drives_heading_and_forward_speed_in_real_sampling(self):
        from tests import test_control_stages as stages
        traces = stages.io_traces({"x": 1, "y": 0, "z": 0})
        valid = [t["vessel"] for t in traces if t.get("vessel", {}).get("valid")]
        self.assertTrue(valid)
        for vessel in valid:
            self.assertEqual(vessel["attitudeAxisSource"], "CONFIGURED")
            self.assertEqual(vessel["attitudeBow"], {"x": 1, "y": 0, "z": 0})
            if "sableVelocity" in vessel and str(vessel.get("forwardSpeedSource", "")).startswith("Sable"):
                self.assertEqual(vessel["forwardSpeed"], vessel["sableVelocity"]["x"])


if __name__ == "__main__":
    unittest.main()
