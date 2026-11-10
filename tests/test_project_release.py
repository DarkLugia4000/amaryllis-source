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
        cls.media_parent, cls.report = b.build(ROOT, cls.output)
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

    def test_shared_source_edits_reach_every_mapped_role(self):
        """Edit each canonical shared file once and verify every mapped role package receives it, and no other."""
        source = self.project_copy("shared-source-edit")
        mapping = json.loads((source / "source/baseline.json").read_bytes())["sharedModules"]
        probes = {}
        for number, canonical in enumerate(sorted(mapping)):
            probe = f'local __shared_source_probe_{number} = "{canonical}"\n'.encode()
            path = source / "source/library" / canonical
            path.write_bytes(probe + path.read_bytes())
            probes[canonical] = probe.strip()
        output = self.work / "shared-source-media"; output.mkdir()
        media_parent, _ = b.build(source, output)
        _, _, groups = u.read_media(media_parent)
        loader = (b.HOME / "assets/runtime-loader.lua").read_bytes()
        # Packaging bundles several sources into one file, so search decoded sources per role package.
        packages = {}
        for path, data in groups["library"].items():
            parts = path.strip("/").split("/")
            if parts[1] == "common":
                continue
            unpacked = b.bundling.unpack(data, loader)
            sources = unpacked[1].values() if unpacked else [data]
            packages.setdefault("/".join(parts[:3]), []).extend(sources)
        for canonical, members in mapping.items():
            # The canonical file itself is source only; role packages are the delivered copies.
            expected = {"/".join(member.split("/")[:3]) for member in members if member.split("/")[1] != "common"}
            found = {name for name, sources in packages.items() if any(probes[canonical] in s for s in sources)}
            with self.subTest(canonical=canonical):
                self.assertEqual(found, expected)

    def test_build_matches_collected_program_payloads(self):
        """Verify the project command builds the checkout and its media matches the collected payloads."""
        current = b.bundling.prepare(b.collect_project(ROOT), b.FOLDERS)
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
        with patch.object(project.builder_module(), "build", return_value=(self.media_parent, self.report)) as build:
            project.build(self.output)
            self.assertEqual(build.call_args.args[0], ROOT)

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
        release, report = b.build(root, self.output)
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
        backup = u.apply(plan, backup_parent)
        self.assertEqual(u.current(plan), plan.after)
        self.assertEqual((core / "fleet.json").read_bytes(), u.encode(self.registry))
        self.assertIn(marker, (core / "avionics/main.lua").read_bytes())
        cfg = json.loads((core / "avionics/config.json").read_bytes())
        self.assertEqual(cfg["ownerPID"], {"gain": 0.731})
        self.assertTrue(cfg["thrust"]["enabled"])
        for cid in plan.roles:
            self.assertFalse((computers / cid / "avionics/obsolete.lua").exists())
            for name in ("restart.json", "hover-offset.json"):
                self.assertTrue((computers / cid / "avionics/data" / name).is_file())
                self.assertNotIn(cid + "/avionics/data/" + name, plan.before)
            record = json.loads((computers / cid / "amaryllis-install.json").read_bytes())
            self.assertEqual(record["source"], manifest["source"])
        repeated = u.preview(core, release)
        self.assertEqual(repeated.before, repeated.after)
        u.restore(backup)
        self.assertEqual(u.current(plan), plan.before)

    def test_live_update_tolerates_files_running_computers_rewrite(self):
        """A running ship rewrites its status and data files between preview and apply; the update still succeeds."""
        root = self.project_copy("live")
        path = root / "source/core/avionics/pid.lua"
        marker = b"\n-- Live update integration marker.\n"
        path.write_bytes(path.read_bytes() + marker)
        release, _ = b.build(root, self.output)
        computers = self.work / "live-target/computercraft/computer"
        shutil.copytree(self.seed, computers)
        core = computers / "600"
        plan = u.preview(core, release)
        live = {}
        for cid in plan.roles:
            for name, data in (("installer/install_status.json", b'{"tick": 1}'), ("avionics/data/restart.json", b'{"boot": 7}')):
                target = computers / cid / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data); live[target] = data
        backups = self.work / "live-backups"
        backups.mkdir()
        backup = u.apply(plan, backups)
        self.assertIn(marker, (core / "avionics/main.lua").read_bytes())
        for target, data in live.items():
            self.assertEqual(target.read_bytes(), data, "runtime file was touched by the update")
        # Computers keep writing after the update; restore still works and leaves them alone.
        for target in live: target.write_bytes(b'{"tick": 2}')
        u.restore(backup)
        self.assertNotIn(marker, (core / "avionics/main.lua").read_bytes())
        for target in live: self.assertEqual(target.read_bytes(), b'{"tick": 2}')

    def test_edit_during_preview_names_the_changed_file(self):
        """A real program or settings edit after preview still stops the update and says which file."""
        root = self.project_copy("drift")
        release, _ = b.build(root, self.output)
        computers = self.work / "drift-target/computercraft/computer"
        shutil.copytree(self.seed, computers)
        core = computers / "600"
        plan = u.preview(core, release)
        (core / "avionics/config.json").write_bytes((core / "avionics/config.json").read_bytes() + b" ")
        backups = self.work / "drift-backups"
        backups.mkdir()
        with self.assertRaisesRegex(u.UpdateError, r"changed after preview \(600/avionics/config.json\)"):
            u.apply(plan, backups)

    def test_source_changes_during_build_prevent_publication(self):
        """Reject an added Lua module after the source snapshot was captured."""
        root = self.project_copy("changing")
        collected = b.collect_project(root)
        (root / "source/core/avionics/added.lua").write_bytes(b"return true\n")
        with patch.object(b, "collect_project", return_value=collected):
            with self.assertRaisesRegex(b.BuildError, "Project inputs changed"):
                b.build(root, self.output)

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

    def test_project_update_command_previews_source_without_exporting_installer(self):
        """Delegate project updates to source preview and leave target files unchanged."""
        target = self.work / "command-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        expected = u.preview(target / "600", self.media_parent)
        before = u.current(expected)
        with patch.object(project, "build", side_effect=AssertionError("Exported an installer")), \
             patch.object(u, "preview_project", return_value=expected) as preview, patch("builtins.print"):
            plan = project.update(target / "600", self.output)
        self.assertIs(plan, expected)
        self.assertEqual(preview.call_args.args, (target / "600", ROOT))
        self.assertEqual(preview.call_args.kwargs["workspace"], self.output)
        self.assertEqual(u.current(plan), before)

    def test_direct_source_update_applies_current_edits_and_cleans_staging(self):
        """Update from edited Lua, retain stored data, restore the backup and release temporary media."""
        source = self.project_copy("direct-source")
        path = source / "source/core/avionics/pid.lua"
        marker = b"\n-- Direct-source update integration marker.\n"
        path.write_bytes(path.read_bytes() + marker)
        target = self.work / "direct-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        workspace = self.work / "direct-workspace"
        plan = u.preview_project(target / "600", source, workspace=workspace)
        self.addCleanup(plan.close)
        stage = Path(plan._staging.name)
        self.assertEqual(plan.project_root, source)
        self.assertIn(marker, plan.after["600/avionics/main.lua"])
        self.assertEqual(u.current(plan), plan.before)
        self.assertFalse(list(stage.rglob("*.zip")))
        self.assertFalse(list(stage.rglob("windows-update")))
        self.assertFalse(list(stage.rglob("windows-settings")))
        self.assertIn(str(source), plan.report())
        backups = self.work / "direct-backups"; backups.mkdir()
        backup = u.apply(plan, backups)
        config = json.loads((target / "600/avionics/config.json").read_bytes())
        self.assertEqual(config["ownerPID"], {"gain": 0.731})
        self.assertEqual((target / "600/fleet.json").read_bytes(), u.encode(self.registry))
        for cid in plan.roles:
            self.assertFalse((target / cid / "avionics/obsolete.lua").exists())
            for name in ("restart.json", "hover-offset.json"):
                self.assertTrue((target / cid / "avionics/data" / name).is_file())
                self.assertNotIn(cid + "/avionics/data/" + name, plan.before)
        u.restore(backup)
        self.assertEqual(u.current(plan), plan.before)
        plan.close()
        self.assertFalse(stage.exists())
        self.assertEqual(list(workspace.iterdir()), [])
        self.assertTrue(backup.is_dir())

    def test_source_edit_after_preview_prevents_target_writes(self):
        """Reject changed source and a backup location inside temporary update files."""
        source = self.project_copy("source-edit-after-preview")
        target = self.work / "source-edit-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        plan = u.preview_project(target / "600", source, workspace=self.work / "source-edit-workspace")
        self.addCleanup(plan.close)
        for folder, message in ((source / "source", "outside editable"),
                                (Path(plan._staging.name), "outside the temporary")):
            with self.assertRaisesRegex(u.UpdateError, message):
                u.apply(plan, folder)
        path = source / "source/core/avionics/pid.lua"
        path.write_bytes(path.read_bytes() + b"\n-- Changed after review.\n")
        backups = self.work / "stale-backups"; backups.mkdir()
        with self.assertRaisesRegex(u.UpdateError, "Project source changed after preview"):
            u.apply(plan, backups)
        self.assertEqual(u.current(plan), plan.before)
        self.assertEqual(list(backups.iterdir()), [])

    def test_failed_source_preview_removes_temporary_payload(self):
        """Clean a prepared source payload when target validation refuses the update."""
        target = self.work / "invalid-source-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        fleet = dict(self.registry, computers=dict(self.registry["computers"]))
        fleet["computers"].pop("state")
        (target / "600/fleet.json").write_bytes(u.encode(fleet))
        workspace = self.work / "failed-source-workspace"
        before = {p.relative_to(target): p.read_bytes() for p in target.rglob("*") if p.is_file()}
        with self.assertRaisesRegex(u.UpdateError, "complete registered"):
            u.preview_project(target / "600", ROOT, workspace=workspace)
        self.assertEqual(list(workspace.iterdir()), [])
        self.assertEqual(before, {p.relative_to(target): p.read_bytes() for p in target.rglob("*") if p.is_file()})
        with patch.object(b, "build", side_effect=b.BuildError("Synthetic build error\nIncomplete output retained at: deleted-stage")):
            with self.assertRaisesRegex(u.UpdateError, "Source update could not be prepared: Synthetic build error") as error:
                u.preview_project(target / "600", ROOT, workspace=workspace)
        self.assertNotIn("retained at", str(error.exception))
        self.assertEqual(list(workspace.iterdir()), [])

    def test_updater_cli_defaults_to_source_and_keeps_explicit_media_support(self):
        """Select source in the checkout and retain the distributed-release CLI path."""
        import sys
        target = self.work / "cli-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        plan = u.preview(target / "600", self.media_parent)
        with patch.object(sys, "argv", ["updater.py", "--source", str(target / "600")]), \
             patch.object(u, "preview_project", return_value=plan) as source_preview, \
             patch.object(u, "preview", side_effect=AssertionError("Selected old media")), \
             patch.object(plan, "close") as close, patch("builtins.print"):
            u.main()
            source_preview.assert_called_once_with(Path(target / "600"), ROOT)
            close.assert_called_once()
        with patch.object(sys, "argv", ["updater.py", "--source", str(target / "600"), "--media", str(self.media)]), \
             patch.object(u, "preview_project", side_effect=AssertionError("Ignored explicit release")), \
             patch.object(u, "preview", return_value=plan) as media_preview, patch("builtins.print"):
            u.main()
            media_preview.assert_called_once_with(Path(target / "600"), self.media)


    def test_fresh_install_records_project_revision_in_existing_journal(self):
        """Verify disk-based installation retains release provenance without another file."""
        from tests.test_disk_setup import Fixture
        disk = {"/disk/" + p.relative_to(self.media).as_posix(): p.read_bytes().decode("utf-8")
                for p in self.media.rglob("*") if p.is_file()}
        f = Fixture(identity=703, disk=disk, release_override=self.release)
        f.key("down").key("enter").yes()
        self.assertIn("Core installed", f.text())
        self.assertEqual(json.loads(f.files["/amaryllis-install.json"])["source"], self.release["source"])

    def test_project_gui_opens_source_updater_without_exporting_installer(self):
        """Open the updater with source selected before any build or target write."""
        import tkinter as tk
        from tkinter import messagebox
        root = tk.Tk(); root.withdraw()
        def descendants(widget):
            return [item for child in widget.winfo_children() for item in [child] + descendants(child)]
        def exercise():
            widgets = descendants(root)
            entries = [w for w in widgets if w.winfo_class() == "TEntry"]
            self.assertEqual(root.getvar(entries[0].cget("textvariable")), str(ROOT))
            buttons = {str(w.cget("text")): w for w in widgets if w.winfo_class() == "TButton"}
            buttons["Update existing ship…"].invoke()
            update.assert_called_once_with(root, project=str(ROOT))
            build.assert_not_called()
        try:
            with patch.object(tk, "Tk", return_value=root), patch.object(root, "mainloop", side_effect=exercise), \
                 patch.object(b, "build") as build, patch.object(u, "open_dialog") as update, \
                 patch.object(messagebox, "showerror") as error:
                b.gui(); error.assert_not_called()
        finally:
            root.update_idletasks()
            for timer in root.tk.call("after", "info"): root.after_cancel(timer)
            root.destroy()

    def test_updater_gui_previews_source_and_releases_payload_after_apply(self):
        """Exercise source fields, preview, confirmation and cleanup through Tk callbacks."""
        import tkinter as tk
        from tkinter import messagebox
        import time
        target = self.work / "gui-source-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        plan = u.preview_project(target / "600", ROOT, workspace=self.work / "gui-source-workspace")
        self.addCleanup(plan.close)
        stage = Path(plan._staging.name)
        root = tk.Tk(); root.withdraw()
        def descendants(widget):
            return [item for child in widget.winfo_children() for item in [child] + descendants(child)]
        def wait_until(predicate):
            deadline = time.monotonic() + 10
            while not predicate() and time.monotonic() < deadline:
                root.update(); time.sleep(.01)
            self.assertTrue(predicate())
        try:
            with patch.object(u, "preview_project", return_value=plan) as preview, \
                 patch.object(u, "apply", return_value=self.work / "gui-backup") as apply, \
                 patch.object(messagebox, "askyesno", return_value=True), \
                 patch.object(messagebox, "showerror") as error:
                window = u.open_dialog(root, source=str(target / "600"))
                window.withdraw()
                widgets = descendants(window)
                labels = [str(w.cget("text")) for w in widgets if w.winfo_class() == "TLabel"]
                self.assertIn("Amaryllis project folder", labels)
                self.assertNotIn("Installer media folder", labels)
                entries = [w for w in widgets if w.winfo_class() == "TEntry"]
                self.assertEqual(entries[1].get(), str(ROOT))
                window.setvar(entries[2].cget("textvariable"), str(self.work))
                buttons = {str(w.cget("text")): w for w in widgets if w.winfo_class() == "TButton"}
                buttons["Preview update"].invoke()
                wait_until(lambda: window._amaryllis_update_state["plan"] is plan)
                preview.assert_called_once_with(str(target / "600"), str(ROOT))
                apply.assert_not_called()
                boxes = [w for w in widgets if w.winfo_class() == "TCheckbutton"]
                self.assertEqual(boxes, [])
                buttons["Apply update"].invoke()
                wait_until(lambda: not window._amaryllis_update_state["busy"])
                apply.assert_called_once_with(plan, self.work)
                self.assertFalse(stage.exists())
                error.assert_not_called()
                window.destroy()
        finally:
            root.update_idletasks()
            for timer in root.tk.call("after", "info"): root.after_cancel(timer)
            root.destroy()

    def test_standalone_gui_destroy_releases_source_payload(self):
        """Release source staging when the standalone updater window is destroyed."""
        import sys
        import tkinter as tk
        import time
        target = self.work / "gui-close-target/computercraft/computer"
        shutil.copytree(self.seed, target)
        plan = u.preview_project(target / "600", ROOT, workspace=self.work / "gui-close-workspace")
        self.addCleanup(plan.close)
        stage = Path(plan._staging.name)
        root = tk.Tk(); root.withdraw()
        def descendants(widget):
            return [item for child in widget.winfo_children() for item in [child] + descendants(child)]
        def exercise():
            window = next(w for w in root.winfo_children() if isinstance(w, tk.Toplevel))
            window.withdraw()
            buttons = {str(w.cget("text")): w for w in descendants(window) if w.winfo_class() == "TButton"}
            buttons["Preview update"].invoke()
            deadline = time.monotonic() + 10
            while window._amaryllis_update_state["plan"] is not plan and time.monotonic() < deadline:
                root.update(); time.sleep(.01)
            self.assertIs(window._amaryllis_update_state["plan"], plan)
            window.destroy()
            self.assertFalse(stage.exists())
        with patch.object(sys, "argv", ["updater.py", "--gui", "--source", str(target / "600")]), \
             patch.object(tk, "Tk", return_value=root), patch.object(root, "mainloop", side_effect=exercise), \
             patch.object(u, "preview_project", return_value=plan):
            u.main()


if __name__ == "__main__":
    unittest.main()
