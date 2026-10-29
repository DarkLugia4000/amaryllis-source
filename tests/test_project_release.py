"""Project-source builds and transactional updates using disposable ships only."""
from pathlib import Path
import json
import shutil
import tempfile
import unittest
import zlib
from unittest.mock import patch
import project

ROOT = project.ROOT
b = project.builder_module()
import updater as u


class ProjectReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Build source-only media and seed a complete synthetic installed fleet."""
        cls.temp = tempfile.TemporaryDirectory(prefix="project-release-", dir=ROOT / ".cache")
        cls.work = Path(cls.temp.name).resolve()
        cls.output = cls.work / "releases"
        cls.output.mkdir()
        cls.media_parent, cls.report = b.build(ROOT, cls.output, project_source=True)
        cls.media, cls.release, cls.groups = u.read_media(cls.media_parent)
        cls.seed = cls.work / "seed/computercraft/computer"
        cls.seed.mkdir(parents=True)
        cls.registry = {"schemaVersion": 1, "computers": {}}
        roles = ["core", "state", *b.FOLDERS]
        for number, role in enumerate(roles, 600):
            cid = str(number)
            label = cls.release["roles"][role]["label"]
            cls.registry["computers"][role] = {"id": number, "label": label}
            if role in ("core", "state"):
                files = dict(cls.groups[role])
                cfg = json.loads(files["/avionics/config.json"])
                if role == "core":
                    cfg["computer_id"] = 600
                    cfg["thrust"]["enabled"] = True
                    cfg["ownerPID"] = {"gain": 0.731}
                else:
                    cfg.update(computerID=number, coreID=600)
                files["/avionics/config.json"] = u.encode(cfg)
            else:
                prefix = "/packages/" + b.FOLDERS[role] + "/"
                manifest = json.loads(cls.groups["library"][prefix + "manifest.json"])
                files = {"/avionics/main.lua": cls.groups["library"][prefix + "main.lua"],
                         "/avionics/config.json": cls.groups["library"][prefix + "config.json"],
                         "/avionics/common/console.lua": cls.groups["library"]["/packages/common/console.lua"],
                         "/startup.lua": cls.groups["bootstrap"]["/startup.lua"],
                         "/installer.lua": cls.groups["bootstrap"]["/installer.lua"],
                         "/config.json": u.encode({"core_id": 600, "target_role": "auto"})}
                rows = b"".join(path.encode() + b"\0" + str(len(files[path])).encode() + b"\0" +
                                f"{zlib.adler32(files[path]):08X}".encode() + b"\n" for path in manifest["files"])
                receipt = {"protocol": "amaryllis.install.v1", "role": role, "packageId": manifest["packageId"],
                           "version": manifest["version"], "manifestChecksum": f"{zlib.adler32(rows):08X}",
                           "computerID": number, "coreID": 600, "label": label, "installID": "install-1",
                           "clientSession": "client-1", "serverSession": "server-1", "coreSession": "core-1"}
                cfg = json.loads(files["/avionics/config.json"])
                cfg.update(role=role, install=receipt)
                files["/avionics/config.json"] = u.encode(cfg)
                status = {field: receipt[key] for key, field in u.RECEIPT_FIELDS.items()}
                status.update(hasInstalled=True, recoveryRequired=False, state="installed")
                files["/installer/status.json"] = u.encode(status)
            files["/amaryllis-install.json"] = u.encode({"releaseId": cls.release["releaseId"], "role": role,
                                                       "id": number, "pending": False})
            files["/avionics/data/restart.json"] = b'{"appliedTargets":{"fl":42000},"running":true}\n'
            files["/avionics/data/hover-offset.json"] = b'{"ownerLearning":0.739}\n'
            files["/avionics/obsolete.lua"] = b"return 'old program'\n"
            for name, data in files.items():
                target = cls.seed / cid / name.lstrip("/")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        (cls.seed / "600/fleet.json").write_bytes(u.encode(cls.registry))

    @classmethod
    def tearDownClass(cls):
        """Remove the verified test-owned directory and its generated releases."""
        assert cls.work.is_relative_to((ROOT / ".cache").resolve())
        cls.temp.cleanup()

    def project_copy(self, name):
        """Copy only maintained source into a disposable editable project."""
        root = self.work / name
        shutil.copytree(ROOT / "source", root / "source")
        return root

    def test_build_uses_no_world_fixture_and_matches_existing_program_payloads(self):
        """Verify production builds bypass test fixtures and preserve current flight code."""
        current = b.bundling.prepare(b.collect(project.fixture()), b.FOLDERS)
        for group in ("payload", "state", "library"):
            manifest_group = "core" if group == "payload" else group
            actual = dict(self.groups[manifest_group])
            expected = dict(current[group])
            if group == "payload":
                # build() replaces the loose catalog with the final bundled catalog.
                actual.pop("/installer/library.json")
                expected.pop("/installer/library.json")
            self.assertEqual(set(actual), set(expected))
            for name in actual:
                self.assertEqual(b.sha(actual[name]), b.sha(expected[name]), name)
        with patch.object(project, "fixture", side_effect=AssertionError("Production build used test fixture")):
            with patch.object(project.builder_module(), "build", return_value=(self.media_parent, self.report)) as build:
                project.build(self.output)
                self.assertEqual(build.call_args.args[0], ROOT)
                self.assertTrue(build.call_args.kwargs["project_source"])

    def test_release_records_source_and_excludes_synthetic_ids(self):
        """Verify release provenance is shared while source paths stay in the local report."""
        source = self.release["source"]
        self.assertEqual(source, self.report["source"])
        self.assertEqual(source["kind"], "project-source")
        self.assertEqual(len(source["sourceTreeSHA256"]), 64)
        self.assertNotIn(str(ROOT), json.dumps(self.release))
        self.assertNotIn("computer_id", json.loads(self.groups["core"]["/avionics/config.json"]))
        self.assertEqual(len(self.release["core"]), 5)
        self.assertEqual(len(self.release["state"]), 3)

    def test_edited_project_code_changes_media_without_reading_installed_code(self):
        """Verify a maintained Lua edit reaches the bundled installer and changes its identity."""
        root = self.project_copy("edited")
        path = root / "source/core/avionics/pid.lua"
        marker = b"\n-- Project-source authority integration marker.\n"
        path.write_bytes(path.read_bytes() + marker)
        release, report = b.build(root, self.output, project_source=True)
        _, manifest, groups = u.read_media(release)
        self.assertNotEqual(manifest["releaseId"], self.release["releaseId"])
        self.assertNotEqual(report["source"]["sourceTreeSHA256"], self.report["source"]["sourceTreeSHA256"])
        self.assertIn(marker, groups["core"]["/avionics/main.lua"])
        computers = self.work / "edited-target/computercraft/computer"
        shutil.copytree(self.seed, computers)
        core = computers / "600"
        plan = u.preview(core, release)
        self.assertEqual(len(plan.roles), 16)
        self.assertIn("Software: project source", plan.report())
        backup_parent = self.work / "backups"
        backup_parent.mkdir()
        backup = u.apply(plan, backup_parent, closed_ack=True, process_check=lambda path: None)
        self.assertEqual(u.current(plan), plan.after)
        self.assertEqual((core / "fleet.json").read_bytes(), u.encode(self.registry))
        self.assertIn(marker, (core / "avionics/main.lua").read_bytes())
        cfg = json.loads((core / "avionics/config.json").read_bytes())
        self.assertEqual(cfg["ownerPID"], {"gain": 0.731})
        self.assertTrue(cfg["thrust"]["enabled"])
        for cid in plan.roles:
            self.assertFalse((computers / cid / "avionics/obsolete.lua").exists())
            for name in ("restart.json", "hover-offset.json"):
                key = cid + "/avionics/data/" + name
                self.assertEqual(plan.before[key], plan.after[key])
            record = json.loads((computers / cid / "amaryllis-install.json").read_bytes())
            self.assertEqual(record["source"], manifest["source"])
        repeated = u.preview(core, release)
        self.assertEqual(repeated.before, repeated.after)
        u.restore(backup, closed_ack=True, process_check=lambda path: None)
        self.assertEqual(u.current(plan), plan.before)

    def test_source_changes_during_build_prevent_publication(self):
        """Reject an added Lua module after the source snapshot was captured."""
        root = self.project_copy("changing")
        collected = b.collect_project(root)
        (root / "source/core/avionics/added.lua").write_bytes(b"return true\n")
        with patch.object(b, "collect_project", return_value=collected):
            with self.assertRaisesRegex(b.BuildError, "Project inputs changed"):
                b.build(root, self.output, project_source=True)

    def test_packaged_source_revision_survives_without_git_and_detects_edits(self):
        """Keep packaged revision provenance and flag edits against its recorded fingerprint."""
        root = self.project_copy("packaged")
        source = b.collect_project(root)
        record = dict(source["provenance"], commit="a" * 40, dirty=False)
        (root / "source/revision.json").write_bytes(b.encode(record))
        self.assertEqual(b.collect_project(root)["provenance"], record)
        path = root / "source/core/avionics/pid.lua"
        path.write_bytes(path.read_bytes() + b"\n-- changed packaged source\n")
        modified = b.collect_project(root)["provenance"]
        self.assertEqual(modified["commit"], record["commit"])
        self.assertTrue(modified["dirty"])

    def test_project_update_command_builds_before_preview_without_applying(self):
        """Verify project update is a source build followed by a read-only target preview."""
        target = self.work / "command-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        before = {p.relative_to(target).as_posix(): p.read_bytes() for p in target.rglob("*") if p.is_file()}
        with patch.object(project, "build", return_value=self.media_parent) as build, patch("builtins.print"):
            plan = project.update(target / "600", self.output)
        build.assert_called_once_with(self.output)
        self.assertEqual(len(plan.roles), 16)
        after = {p.relative_to(target).as_posix(): p.read_bytes() for p in target.rglob("*") if p.is_file()}
        self.assertEqual(before, after)


    def test_fresh_install_records_project_revision_in_existing_journal(self):
        """Verify disk-based installation retains release provenance without another file."""
        from tests.test_disk_setup import Fixture
        disk = {"/disk/" + p.relative_to(self.media).as_posix(): p.read_bytes().decode("utf-8")
                for p in self.media.rglob("*") if p.is_file()}
        f = Fixture(identity=703, disk=disk, release_override=self.release)
        f.key("down").key("enter").yes()
        self.assertIn("Core installed", f.text())
        self.assertEqual(json.loads(f.files["/amaryllis-install.json"])["source"], self.release["source"])

    def test_project_gui_builds_before_opening_update_preview(self):
        """Exercise the actual Tk event loop and default project-to-update handoff."""
        import tkinter as tk
        from tkinter import messagebox
        import time
        root = tk.Tk()
        root.withdraw()
        def descendants(widget):
            return [item for child in widget.winfo_children() for item in [child] + descendants(child)]
        def exercise():
            widgets = descendants(root)
            modes = [w for w in widgets if w.winfo_class() == "TCombobox"]
            self.assertEqual(modes[0].get(), "Project source")
            entries = [w for w in widgets if w.winfo_class() == "TEntry"]
            self.assertEqual(entries[0].get(), str(ROOT))
            buttons = {str(w.cget("text")): w for w in widgets if w.winfo_class() == "TButton"}
            buttons["Update existing ship…"].invoke()
            deadline = time.monotonic() + 10
            while not update.called and time.monotonic() < deadline:
                root.update()
                time.sleep(0.01)
            update.assert_called_once_with(root, media=str(self.media))
            self.assertTrue(build.call_args.kwargs["project_source"])
            self.assertEqual(Path(build.call_args.args[0]), ROOT)
        try:
            with patch.object(tk, "Tk", return_value=root), patch.object(root, "mainloop", side_effect=exercise), \
                 patch.object(b, "build", return_value=(self.media_parent, self.report)) as build, \
                 patch.object(u, "open_dialog") as update, patch.object(messagebox, "showerror") as error:
                b.gui()
                error.assert_not_called()
        finally:
            for timer in root.tk.call("after", "info"):
                root.after_cancel(timer)
            root.destroy()


if __name__ == "__main__":
    unittest.main()