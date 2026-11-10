"""Settings registry agrees with config.json, Storage.validateConfig, the settings editor and inline fallbacks."""
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


if __name__ == "__main__":
    unittest.main()
