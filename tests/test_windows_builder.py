"""Export and failure-path tests. All mutations are inside isolated workspace fixtures."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("windows_builder", HERE / "disk-builder/builder.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
# These regression cases inspect the editable/loose export format explicitly.
# Bundled exports and their receiver/loader behavior are covered separately.
_build = b.build
def build_loose(*args, **kwargs):
    kwargs["bundle"] = False
    return _build(*args, **kwargs)
b.build = build_loose
from project import fixture
SOURCE = fixture("legacy")


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = b.collect(SOURCE)
        cls.base = tempfile.TemporaryDirectory(prefix="windows-builder-tests-", dir=HERE)
        cls.base_path = Path(cls.base.name).resolve()
        assert cls.base_path.is_relative_to(HERE)
        cls.seed = cls.base_path / "seed"
        cls.seed_core = cls.seed / "computercraft/computer/321"
        cls.seed_core.mkdir(parents=True)
        old_core = cls.original["core"]
        for path, data in cls.original["snapshot"].files.items():
            if path.is_relative_to(old_core):
                target = cls.seed_core / path.relative_to(old_core)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        fleet = json.loads((cls.seed_core / "fleet.json").read_text())
        for index, role in enumerate(["core"] + b.ROLES, start=321):
            fleet["computers"][role]["id"] = index
        cls.seed_fleet = fleet
        (cls.seed_core / "fleet.json").write_bytes(b.encode(fleet))
        nav = cls.seed / "computercraft/computer/322"
        nav.mkdir()
        (nav / "installer.lua").write_bytes(cls.original["assets"]["installer.lua"])

    @classmethod
    def tearDownClass(cls):
        # TemporaryDirectory owns only the checked, newly created fixture path.
        cls.base.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix="case-", dir=self.base_path))
        self.save = self.case / "save"
        shutil.copytree(self.seed, self.save)
        self.core = self.save / "computercraft/computer/321"
        self.output = self.case / "exports"
        self.output.mkdir()

    def write_json(self, relative, value):
        (self.core / relative).write_bytes(b.encode(value))

    def read_json(self, relative):
        return json.loads((self.core / relative).read_bytes())

    def hashes(self):
        return {str(p.relative_to(self.save)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.save.rglob("*") if p.is_file()}

    def test_source_detection_uses_registry_not_hardcoded_ids(self):
        for selection in (self.save, self.save / "computercraft", self.core.parent, self.core):
            self.assertEqual(b.locate_core(selection)[0], self.core)
        result = b.collect(self.save)
        self.assertEqual(result["core"].name, "321")
        self.assertEqual(len(result["versions"]), 14)

    def test_ambiguous_core_requires_explicit_selection(self):
        second = self.core.parent / "999"
        (second / "avionics").mkdir(parents=True)
        (second / "fleet.json").write_bytes((self.core / "fleet.json").read_bytes())
        (second / "avionics/config.json").write_bytes((self.core / "avionics/config.json").read_bytes())
        with self.assertRaisesRegex(b.BuildError, "Several core"):
            b.collect(self.save)
        self.assertEqual(b.collect(self.core)["core"], self.core)

    def test_missing_source_rejected_without_output(self):
        with self.assertRaises(b.BuildError):
            b.build(self.case / "missing", self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_invalid_registry_records(self):
        for invalid in (None, [], "core", {"id": 999}):
            fleet = copy.deepcopy(self.seed_fleet)
            fleet["computers"]["core"] = invalid
            self.write_json("fleet.json", fleet)
            with self.assertRaises(b.BuildError):
                b.collect(self.save)

    def test_duplicate_ids_and_labels_and_incomplete_roles(self):
        for change in ("id", "label", "missing"):
            fleet = copy.deepcopy(self.seed_fleet)
            if change == "missing":
                del fleet["computers"]["state"]
            else:
                fleet["computers"]["state"][change] = fleet["computers"]["core"][change]
            self.write_json("fleet.json", fleet)
            with self.assertRaises(b.BuildError):
                b.collect(self.save)

    def test_incomplete_or_malformed_packages(self):
        path = "packages/navigation/manifest.json"
        original = self.read_json(path)
        for files in ([{}], [None], ["/avionics/../escape.lua"], ["/avionics/missing.lua"],
                      ["/avionics/config.json", "/avionics/config.json"]):
            value = copy.deepcopy(original)
            value["files"] = files
            self.write_json(path, value)
            with self.assertRaises(b.BuildError):
                b.collect(self.save)
        value = copy.deepcopy(original)
        value["role"] = "state"
        self.write_json(path, value)
        with self.assertRaisesRegex(b.BuildError, "Unsupported package manifest"):
            b.collect(self.save)

    def test_invalid_json(self):
        (self.core / "avionics/config.json").write_text('{"x":NaN}')
        with self.assertRaisesRegex(b.BuildError, "Invalid JSON"):
            b.collect(self.save)

    def test_destination_path_validation(self):
        for value in (None, {}, 5, "/avionics//x.lua", "/avionics/../x", "/avionics/C:x", "outside"):
            with self.assertRaises(b.BuildError):
                b.portable_path(value)

    def test_identity_removal_settings_preservation_and_runtime_exclusion(self):
        config = self.read_json("avionics/config.json")
        config.update(computer_id=321, bridge_id=322, node_ids={"test": 333}, role_ids={"test": 334}, display_ids=[335])
        config["thrust"]["enabled"] = True
        config["commissioning"]["enabled"] = True
        config["altitude_control"]["builder_test_setting"] = 0.321
        self.write_json("avionics/config.json", config)
        for path in ("avionics/data/checkpoint.json", "avionics/data/remotes.json", "avionics/tests/example.lua"):
            p = self.core / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("not an export")
        result = b.collect(self.save)
        portable = json.loads(result["payload"]["/avionics/config.json"])
        self.assertEqual(portable["altitude_control"], config["altitude_control"])
        for field in ("computer_id", "bridge_id", "node_ids", "role_ids", "display_ids"):
            self.assertNotIn(field, portable)
        self.assertFalse(portable["thrust"]["enabled"])
        self.assertFalse(portable["commissioning"]["enabled"])
        self.assertTrue(portable["hardware"]["discover"])
        self.assertFalse(any("/data/" in p or "/tests/" in p for p in result["payload"]))
        self.assertEqual(set(result["calibration"]), set(b.LEARNING.values()))

    def test_partial_learning_can_be_explicitly_excluded(self):
        (self.core / "avionics/data/level-bias.json").unlink()
        with self.assertRaisesRegex(b.BuildError, "Only one learning"):
            b.collect(self.save)
        self.assertEqual(b.collect(self.save, False)["calibration"], {})

    def test_no_learning_is_supported(self):
        for path in b.LEARNING.values():
            (self.core / path.lstrip("/")).unlink()
        result = b.collect(self.save)
        self.assertEqual(result["calibration"], {})
        self.assertIn("No saved", result["notes"][0])

    def test_invalid_learning_fails_with_actionable_error(self):
        level = self.read_json("avionics/data/level-bias.json")
        hover = self.read_json("avionics/data/hover-offset.json")
        for invalid in ({}, {**level, "roll": 10001}, {**level, "roll": True}):
            with self.assertRaises(b.BuildError):
                b.validate_learning(hover, invalid)
        bad_hover = copy.deepcopy(hover)
        bad_hover["bands"]["0200"] = {"offset": 0, "samples": 1}
        with self.assertRaises(b.BuildError):
            b.validate_learning(bad_hover, level)

    def test_learning_is_from_selected_core(self):
        level = self.read_json("avionics/data/level-bias.json")
        level["roll"] = 12.345
        self.write_json("avionics/data/level-bias.json", level)
        data = b.collect(self.save)["calibration"][b.LEARNING["level"]]
        self.assertEqual(json.loads(data)["roll"], 12.345)

    def test_output_inside_save_is_refused_without_source_changes(self):
        before = self.hashes()
        with self.assertRaisesRegex(b.BuildError, "outside the selected Minecraft save"):
            b.build(self.save, self.core)
        self.assertEqual(self.hashes(), before)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_asset_corruption_is_refused(self):
        fake_home = self.case / "utility"
        shutil.copytree(b.HOME / "assets", fake_home / "assets")
        (fake_home / "assets/setup.lua").write_text("broken")
        with patch.object(b, "HOME", fake_home), self.assertRaisesRegex(b.BuildError, "damaged"):
            b.build(self.save, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_snapshot_rechecks_parent_links(self):
        snap = b.Snapshot(self.core.parent)
        snap.read(self.core / "startup.lua")
        real_linked = b.linked
        with patch.object(b, "linked", side_effect=lambda path: path == self.core or real_linked(path)):
            with self.assertRaisesRegex(b.BuildError, "linked"):
                snap.check_unchanged()

    def test_source_change_leaves_incomplete_output_only(self):
        def changed(snapshot):
            (self.core / "startup.lua").write_text("changed by fixture")
            actual_check(snapshot)
        actual_check = b.Snapshot.check_unchanged
        with patch.object(b.Snapshot, "check_unchanged", changed):
            with self.assertRaisesRegex(b.BuildError, "Source changed"):
                b.build(self.save, self.output)
        outputs = list(self.output.iterdir())
        self.assertEqual(len(outputs), 1)
        self.assertIn("INCOMPLETE", outputs[0].name)
        self.assertTrue((outputs[0] / "INCOMPLETE.txt").is_file())

    def test_successful_exports_are_verified_private_and_never_overwritten(self):
        before = self.hashes()
        first, report = b.build(self.save, self.output)
        second, again = b.build(self.save, self.output)
        self.assertNotEqual(first, second)
        self.assertEqual(report["releaseId"], again["releaseId"])
        self.assertEqual(self.hashes(), before)
        self.assertFalse((first / "INCOMPLETE.txt").exists())
        self.assertEqual(report["learningFiles"], 2)
        with zipfile.ZipFile(first / "amaryllis-installer.zip") as archive:
            self.assertNotIn("build-report.json", archive.namelist())
            self.assertIsNone(archive.testzip())
            manifest = json.loads(archive.read("media/release.json"))
            self.assertTrue(all(set(role) == {"label"} for role in manifest["roles"].values()))
            self.assertNotIn(str(self.core), archive.read("README.md").decode())
            self.assertEqual(archive.read("windows-settings/cc_settings.py"), (b.HOME / "cc_settings.py").read_bytes())
            self.assertIn(b"cc_settings.py", archive.read("windows-settings/Configure ComputerCraft.cmd"))
            self.assertFalse(any("cc_settings" in item["path"] for item in manifest["core"] + manifest["bootstrap"]))
        self.assertTrue((first / "build-report.json").is_file())
        self.assertFalse(report["validation"]["luaCompiled"])

    def test_without_learning_produces_no_calibration_group(self):
        result, report = b.build(self.save, self.output, False)
        manifest = json.loads((result / "media/release.json").read_bytes())
        self.assertNotIn("calibration", manifest)
        self.assertEqual(report["learningFiles"], 0)

    def test_slim_core_rebuild_requires_matching_disk_and_keeps_library_off_core(self):
        result, report = b.build(self.save, self.output)
        manifest = json.loads((result / "media/release.json").read_bytes())
        # Apply the exported core only to this owned fixture, keeping its local registry.
        package_path = (self.core / "packages").resolve()
        self.assertTrue(package_path.is_relative_to(self.case.resolve()))
        shutil.rmtree(package_path)
        for entry in manifest["core"]:
            target = self.core / entry["path"].lstrip("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((result / "media/objects" / entry["object"]).read_bytes())
        with self.assertRaisesRegex(b.BuildError, "matching installer media"):
            b.collect(self.save)
        rebuilt = b.collect(self.save, library=result)
        self.assertFalse(any(p.startswith("/packages/") for p in rebuilt["payload"]))
        self.assertEqual(rebuilt["library"], self.original["library"])
        self.assertEqual(len(rebuilt["catalog"]["roles"]), 14)
        again, again_report = b.build(self.save, self.output, library=result)
        self.assertEqual(report["libraryBytes"], again_report["libraryBytes"])
        self.assertLess(again_report["corePayloadBytes"], 1_600_000)
        entry = manifest["library"][0]
        (result / "media/objects" / entry["object"]).write_text("damaged")
        with self.assertRaisesRegex(b.BuildError, "Corrupt disk library"):
            b.collect(self.save, library=result)

    def test_bootstrap_fallback(self):
        (self.core.parent / "322/installer.lua").unlink()
        result = b.collect(self.save)
        self.assertTrue(any("tested compatible" in note for note in result["notes"]))

    def test_identity_warning_is_advisory_and_exported_with_core_and_bridge(self):
        result = b.collect(self.save)
        self.assertIn("/avionics/identity_watch.lua", result["payload"])
        main = result["payload"]["/avionics/main.lua"]
        self.assertLess(main.index(b"pcall(io.observeIdentityClaim"), main.index(b"inbox:push(from,payload"))
        io = result["payload"]["/avionics/io.lua"]
        self.assertIn(b"identityConflict=self.identityWatch", io)
        self.assertIn(b"identityEpochMs=ok and epochMs or nil", io)
        self.assertNotIn(b"identityConflict.active then self.identityReady", io)
        expected = {p: (self.core/p.lstrip('/')).read_bytes() for p in
                    ["/avionics/flight.lua", "/avionics/telemetry_recovery.lua",
                     "/avionics/controls.lua", "/avionics/autopilot.lua",
                     "/avionics/anchor.lua", "/avionics/remote_ap.lua"]}
        b.lift_recovery_overlays(expected)
        b.vessel_recovery_overlays(expected)
        # Account for the separately verified persistent-selection overlay.
        b.control_persistence_overlays(expected)
        # Isolate the identity overlay from the separate information revision.
        expected.update({p: (self.core/p.lstrip('/')).read_bytes() for p in
                         ["/avionics/io.lua", "/avionics/main.lua", "/packages/navigation/ui.lua"]})
        before_flight=expected["/avionics/flight.lua"]
        b.identity_overlays(expected,result["assets"])
        self.assertEqual(expected["/avionics/flight.lua"],before_flight)
        self.assertEqual([v[0] for v in b.source_notes.tokens(result["payload"]["/avionics/pid.lua"].decode())], [v[0] for v in b.source_notes.tokens((self.core/"avionics/pid.lua").read_text())])
        ui = result["library"]["/packages/navigation/ui.lua"]
        self.assertIn(b"Identity conflict bridge warning v1", ui)

    def test_unsupported_identity_receiver_refused_before_output(self):
        path = self.core/"avionics/main.lua"
        path.write_bytes(path.read_bytes().replace(b"inbox:push(from,payload", b"differentInbox:push(from,payload"))
        with self.assertRaisesRegex(b.BuildError, "core radio receiver"):
            b.build(self.save, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_lift_recovery_is_exported_and_idempotent(self):
        result = b.collect(self.save)
        flight = result["payload"]["/avionics/flight.lua"]
        self.assertIn(b"-- Recoverable lift handshake v1", flight)
        self.assertIn(b"s.recoveryStages[q]", flight)
        self.assertIn(b'TelemetryRecovery.suspend(self,s,now,q.." SYSTEMS COMMAND ACK TIMEOUT")', flight)
        b.lift_recovery_overlays(result["payload"])
        self.assertEqual(flight, result["payload"]["/avionics/flight.lua"])

    def test_vessel_recovery_is_exported_and_idempotent(self):
        result = b.collect(self.save)
        before = {p: result["payload"][p] for p in
                  ["/avionics/flight.lua", "/avionics/telemetry_recovery.lua"]}
        self.assertIn(b"Recovery.vesselState(io,s,now)", before["/avionics/telemetry_recovery.lua"])
        self.assertIn(b"TelemetryRecovery.authoritativeTargetMaps(s,io.nodes)", before["/avionics/flight.lua"])
        b.vessel_recovery_overlays(result["payload"])
        self.assertEqual(before, {p: result["payload"][p] for p in before})

    def test_unsupported_vessel_recovery_source_refused_before_output(self):
        path = self.core/"avionics/telemetry_recovery.lua"
        source = path.read_bytes()
        if b"-- Recoverable vessel telemetry v1" in source:
            source = source.replace(b"-- Recoverable vessel telemetry v1\n", b"", 1)
        else:
            source = source.replace(b"function Recovery.nodeBootState(io,s,q,now,flight)", b"function Recovery.otherBootState(io,s,q,now,flight)")
        path.write_bytes(source)
        with self.assertRaisesRegex(b.BuildError, "vessel recovery|vessel evidence classifier"):
            b.build(self.save, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_unsupported_lift_recovery_source_refused_before_output(self):
        path = self.core/"avionics/flight.lua"
        flight = path.read_bytes()
        if b"-- Recoverable lift handshake v1" in flight:
            # The selected live source may already include this builder patch.
            # Remove its marker and break the matching newer hook instead.
            flight = flight.replace(b"-- Recoverable lift handshake v1\n", b"", 1)
            flight = flight.replace(b"local commandStage=s.telemetryRecovery", b"local brokenStage=s.telemetryRecovery", 1)
            expected = "lift batch sender"
        else:
            flight = flight.replace(b"local expectedStage=stage", b"local unexpectedStage=stage")
            expected = "recovery stage readback"
        path.write_bytes(flight)
        with self.assertRaisesRegex(b.BuildError, expected):
            b.build(self.save, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_core_progress_overlay_keeps_transport_source(self):
        source_server = (self.core / "installer/server.lua").read_bytes()
        result, report = b.build(self.save, self.output)
        manifest = json.loads((result / "media/release.json").read_bytes())
        entries = {entry["path"]: entry for entry in manifest["core"]}
        def data(path):
            return (result / "media/objects" / entries[path]["object"]).read_bytes()
        self.assertEqual([v[0] for v in b.source_notes.tokens(data("/installer/server.lua").decode())], [v[0] for v in b.source_notes.tokens(b.disk_server(source_server).decode())])
        self.assertFalse(any(p.startswith("/packages/") for p in entries))
        self.assertIn("/avionics/common/console.lua", entries)
        self.assertEqual([v[0] for v in b.source_notes.tokens(data("/installer/progress.lua").decode())], [v[0] for v in b.source_notes.tokens((b.HOME / "assets/core-progress.lua").read_text())])
        self.assertEqual(report["builderOverrides"]["/installer/progress.lua"], b.sha(data("/installer/progress.lua")))

    def test_unsupported_installer_display_hooks_fail_before_output(self):
        (self.core / "installer/server.lua").write_text("return {}")
        with self.assertRaisesRegex(b.BuildError, "supported progress interface"):
            b.build(self.save, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_gui_build_with_real_tk_event_loop(self):
        import tkinter as tk
        from tkinter import messagebox
        real_tk = tk.Tk
        root = real_tk()
        root.withdraw()
        def descendants(widget):
            return [item for child in widget.winfo_children() for item in [child] + descendants(child)]
        def run_hidden():
            widgets = descendants(root)
            entries = [w for w in widgets if w.winfo_class() == "TEntry"]
            self.assertEqual(len(entries), 1)
            self.assertEqual(root.title(), "Amaryllis Disk Builder " + b.VERSION)
            modes = [w for w in widgets if w.winfo_class() == "TCombobox"]
            modes[0].set("Saved ship export")
            modes[0].event_generate("<<ComboboxSelected>>")
            root.setvar(entries[0].cget("textvariable"), str(self.save))
            buttons = {str(w.cget("text")): w for w in widgets if w.winfo_class() == "TButton"}
            buttons["Build installer"].invoke()
            deadline = time.monotonic() + 20
            while str(buttons["Open result"].cget("state")) == "disabled" and time.monotonic() < deadline:
                root.update()
                time.sleep(.01)
            self.assertEqual(str(buttons["Open result"].cget("state")), "normal")
            self.assertEqual(str(buttons["Build installer"].cget("state")), "normal")
            self.assertEqual(len(list(self.output.glob("Amaryllis-*"))), 1)
        try:
            with patch.object(b, "DEFAULT_OUTPUT", self.output), \
                 patch.object(tk, "Tk", return_value=root), patch.object(root, "mainloop", side_effect=run_hidden), \
                 patch.object(messagebox, "showerror") as error:
                b.gui()
                error.assert_not_called()
        finally:
            for timer in root.tk.call("after", "info"):
                root.after_cancel(timer)
            root.destroy()


if __name__ == "__main__":
    unittest.main(verbosity=2)
