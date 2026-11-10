"""Project-source build validation and failure-path tests. All edits are inside disposable project copies."""
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


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = tempfile.TemporaryDirectory(prefix="windows-builder-tests-", dir=HERE / ".cache")
        cls.base_path = Path(cls.base.name).resolve()
        assert cls.base_path.is_relative_to(HERE)

    @classmethod
    def tearDownClass(cls):
        # TemporaryDirectory owns only the checked, newly created fixture path.
        cls.base.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix="case-", dir=self.base_path))
        self.project = self.case / "project"
        shutil.copytree(HERE / "source", self.project / "source")
        self.core = self.project / "source/core"
        self.library = self.project / "source/library"
        self.calibration = self.project / "source/calibration"
        self.output = self.case / "exports"
        self.output.mkdir()

    def write_json(self, path, value):
        path.write_bytes(b.encode(value))

    def read_json(self, path):
        return json.loads(path.read_bytes())

    def hashes(self):
        return {str(p.relative_to(self.project)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.project.rglob("*") if p.is_file()}

    def test_missing_source_rejected_without_output(self):
        with self.assertRaises(b.BuildError):
            b.build(self.case / "missing", self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_incomplete_or_malformed_packages(self):
        path = self.library / "packages/navigation/manifest.json"
        original = self.read_json(path)
        for files in ([{}], [None], ["/avionics/../escape.lua"], ["/avionics/missing.lua"],
                      ["/avionics/config.json", "/avionics/config.json"]):
            value = copy.deepcopy(original)
            value["files"] = files
            self.write_json(path, value)
            with self.assertRaises(b.BuildError):
                b.collect_project(self.project)
        value = copy.deepcopy(original)
        value["role"] = "state"
        self.write_json(path, value)
        with self.assertRaisesRegex(b.BuildError, "Unsupported package manifest"):
            b.collect_project(self.project)

    def test_invalid_json(self):
        (self.core / "avionics/config.json").write_text('{"x":NaN}')
        with self.assertRaisesRegex(b.BuildError, "Invalid JSON"):
            b.collect_project(self.project)

    def test_destination_path_validation(self):
        for value in (None, {}, 5, "/avionics//x.lua", "/avionics/../x", "/avionics/C:x", "outside"):
            with self.assertRaises(b.BuildError):
                b.portable_path(value)

    def test_identity_removal_settings_preservation_and_runtime_exclusion(self):
        path = self.core / "avionics/config.json"
        config = self.read_json(path)
        config.update(computer_id=321, bridge_id=322, node_ids={"test": 333}, role_ids={"test": 334}, display_ids=[335])
        config["thrust"]["enabled"] = True
        config["commissioning"]["enabled"] = True
        config["altitude_control"]["builder_test_setting"] = 0.321
        self.write_json(path, config)
        for relative in ("avionics/data/checkpoint.json", "avionics/tests/example.lua"):
            p = self.core / relative
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("{}")
        result = b.collect_project(self.project)
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
        (self.calibration / "avionics/data/level-bias.json").unlink()
        with self.assertRaisesRegex(b.BuildError, "Only one learning"):
            b.collect_project(self.project)
        self.assertEqual(b.collect_project(self.project, False)["calibration"], {})

    def test_no_learning_is_supported(self):
        for path in b.LEARNING.values():
            (self.calibration / path.lstrip("/")).unlink()
        result = b.collect_project(self.project)
        self.assertEqual(result["calibration"], {})
        self.assertIn("No saved", result["notes"][0])

    def test_invalid_learning_fails_with_actionable_error(self):
        level = self.read_json(self.calibration / "avionics/data/level-bias.json")
        hover = self.read_json(self.calibration / "avionics/data/hover-offset.json")
        for invalid in ({}, {**level, "roll": 10001}, {**level, "roll": True}):
            with self.assertRaises(b.BuildError):
                b.validate_learning(hover, invalid)
        bad_hover = copy.deepcopy(hover)
        bad_hover["bands"]["0200"] = {"offset": 0, "samples": 1}
        with self.assertRaises(b.BuildError):
            b.validate_learning(bad_hover, level)

    def test_learning_is_from_project_calibration(self):
        path = self.calibration / "avionics/data/level-bias.json"
        level = self.read_json(path)
        level["roll"] = 12.345
        self.write_json(path, level)
        data = b.collect_project(self.project)["calibration"][b.LEARNING["level"]]
        self.assertEqual(json.loads(data)["roll"], 12.345)

    def test_output_inside_source_is_refused_without_source_changes(self):
        before = self.hashes()
        with self.assertRaisesRegex(b.BuildError, "outside editable source"):
            b.build(self.project, self.core)
        self.assertEqual(self.hashes(), before)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_asset_corruption_is_refused(self):
        fake_home = self.case / "utility"
        shutil.copytree(b.HOME / "assets", fake_home / "assets")
        for name in [p.name for p in b.HOME.glob("*.py")] + ["Start Builder.cmd"]:
            shutil.copy2(b.HOME / name, fake_home / name)
        (fake_home / "assets/setup.lua").write_text("broken")
        with patch.object(b, "HOME", fake_home), self.assertRaisesRegex(b.BuildError, "damaged"):
            b.build(self.project, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_snapshot_rechecks_parent_links(self):
        snap = b.Snapshot(self.core)
        snap.read(self.core / "startup.lua")
        real_linked = b.linked
        with patch.object(b, "linked", side_effect=lambda path: path == self.core / "startup.lua" or real_linked(path)):
            with self.assertRaisesRegex(b.BuildError, "linked"):
                snap.check_unchanged()

    def test_successful_exports_are_verified_private_and_never_overwritten(self):
        before = self.hashes()
        first, report = b.build(self.project, self.output)
        second, again = b.build(self.project, self.output)
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
            self.assertNotIn(str(self.project), archive.read("README.md").decode())
            self.assertIn("Software source: maintained project", archive.read("README.md").decode())
            self.assertEqual(archive.read("windows-settings/cc_settings.py"), (b.HOME / "cc_settings.py").read_bytes())
            self.assertIn(b"cc_settings.py", archive.read("windows-settings/Configure ComputerCraft.cmd"))
            self.assertFalse(any("cc_settings" in item["path"] for item in manifest["core"] + manifest["bootstrap"]))
        self.assertTrue((first / "build-report.json").is_file())
        self.assertFalse(report["validation"]["luaCompiled"])

    def test_without_learning_produces_no_calibration_group(self):
        result, report = b.build(self.project, self.output, False)
        manifest = json.loads((result / "media/release.json").read_bytes())
        self.assertNotIn("calibration", manifest)
        self.assertEqual(report["learningFiles"], 0)

    def test_core_progress_asset_is_exported_with_core(self):
        result, report = b.build(self.project, self.output)
        manifest = json.loads((result / "media/release.json").read_bytes())
        entries = {entry["path"]: entry for entry in manifest["core"]}
        def data(path):
            return (result / "media/objects" / entries[path]["object"]).read_bytes()
        self.assertFalse(any(p.startswith("/packages/") for p in entries))
        self.assertIn("/avionics/common/console.lua", entries)
        self.assertEqual([v[0] for v in b.source_notes.tokens(data("/installer/progress.lua").decode())],
                         [v[0] for v in b.source_notes.tokens((b.HOME / "assets/core-progress.lua").read_text())])
        self.assertEqual(report["builderOverrides"]["/installer/progress.lua"], b.sha(data("/installer/progress.lua")))

    def test_unsupported_installer_display_hooks_fail_before_output(self):
        (self.core / "installer/server.lua").write_text("return {}")
        with self.assertRaisesRegex(b.BuildError, "supported progress interface"):
            b.build(self.project, self.output)
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
            root.setvar(entries[0].cget("textvariable"), str(self.project))
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
