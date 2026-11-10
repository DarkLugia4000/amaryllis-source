"""Release builds, the updater and repository checks."""

# ======================================================================
# From test_project_release: Project-source builds and transactional updates using disposable ships only.
# ======================================================================
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
        from tests.test_installer import Fixture
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


# ======================================================================
# From test_world_lock: Live updates: the updater works while the world is open and leaves the game's session.lock alone.
# ======================================================================
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import project

sys.path.insert(0, str(project.HOME))
import updater as u  # noqa: E402

# Holds session.lock the way Minecraft does while a world is open: an exclusive lock over the file.
HOLDER = r"""
import os, sys
handle = open(sys.argv[1], "r+b")
if os.name == "nt":
    import msvcrt
    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 64)
else:
    import fcntl
    fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
print("locked", flush=True)
sys.stdin.read()
"""
# Tries to take the lock the way Minecraft does when opening a world; prints the outcome.
PROBE = r"""
import os, sys
handle = open(sys.argv[1], "r+b")
try:
    if os.name == "nt":
        import msvcrt
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 64)
    else:
        import fcntl
        fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("acquired")
except OSError:
    print("blocked")
"""


class WorldLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.save = Path(self.temp.name) / "World"
        self.core = self.save / "computercraft/computer/0"
        self.core.mkdir(parents=True)
        self.lock = self.save / "session.lock"
        self.lock.write_bytes("☃".encode("utf-8"))

    def hold(self):
        """Start a separate process that holds the world lock, as an open world does."""
        process = subprocess.Popen([sys.executable, "-c", HOLDER, str(self.lock)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (process.stdin.close(), process.wait(timeout=10), process.stdout.close()))
        self.assertEqual(process.stdout.readline().strip(), "locked")
        return process

    def probe(self):
        return subprocess.run([sys.executable, "-c", PROBE, str(self.lock)], capture_output=True, text=True,
                              timeout=20).stdout.strip()

    def test_update_proceeds_while_the_world_is_open(self):
        """Updates proceed while Minecraft holds session.lock, and leave the lock alone."""
        self.hold()

        class Plan:
            core = self.core
            computers = self.core.parent
            media = Path("media-elsewhere")

            def check_source(self):
                raise RuntimeError("reached the transaction")
        with self.assertRaisesRegex(RuntimeError, "reached the transaction"):
            u.apply(Plan(), self.temp.name)
        self.assertEqual(self.probe(), "blocked", "the updater must leave the game's lock alone")

    def test_closed_world_options_are_gone(self):
        for path in (project.HOME / "updater.py", project.ROOT / "project.py"):
            text = path.read_text(encoding="utf-8")
            for name in ("--require-closed", "--minecraft-closed", "hold_world", "require_closed"):
                self.assertNotIn(name, text, path.name)

    def test_volatile_runtime_files_are_excluded_from_snapshots(self):
        folder = self.core
        (folder / "installer").mkdir()
        (folder / "avionics/data").mkdir(parents=True)
        for name, data in (("installer/install_status.json", b"{}"), ("avionics/data/restart.json", b"1"),
                           ("avionics/config.json", b"{}"), ("installer/status.json", b"{}")):
            (folder / name).write_bytes(data)
        self.assertEqual(sorted(u.scan_computer(folder)), ["avionics/config.json", "installer/status.json"])

    def test_save_folder_for_server_and_singleplayer_layouts(self):
        self.assertEqual(u.save_folder(self.core.parent), self.save)
        server = Path(self.temp.name) / "server/world/computer"
        self.assertEqual(u.save_folder(server), server.parent)


# ======================================================================
# From test_repository: Repository portability and current-source packaging checks.
# ======================================================================
import json
import unittest
import project
from tests.test_builder import LuaRuntime, table

class RepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Collect current maintained sources from the project checkout."""
        cls.builder = project.builder_module()
        cls.source = cls.builder.collect_project(project.ROOT)
        cls.packed = cls.builder.bundling.prepare(cls.source, cls.builder.FOLDERS)

    def test_current_sources_compile_and_roundtrip(self):
        """Compile editable sources and verify their exact bundled recovery."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        compile = lua.eval('function(s,n)local f,e=load(s,"@"..n);return f~=nil,e end')
        for group in ("payload", "library"):
            for name, data in self.source[group].items():
                if name.endswith(".lua"):
                    ok, why = compile(data.decode(), name)
                    self.assertTrue(ok, str(why))
        expanded = self.builder.bundling.expand(self.packed["payload"], self.source["assets"]["runtime-loader.lua"])
        for name, data in self.source["payload"].items():
            if name.endswith(".lua"):
                expected = self.builder.bundling.server_overlay(data) if name == "/installer/server.lua" else data
                self.assertEqual(expanded[name], expected, name)

    def test_asset_backed_modules_have_one_editing_location(self):
        """Check that builder-owned modules are supplied from their maintained assets."""
        import json
        metadata = json.loads((project.ROOT / "source/baseline.json").read_bytes())
        files = project.source_files()
        for name, asset in metadata["assetBackedModules"].items():
            self.assertFalse((project.ROOT / "source/core" / name).exists())
            self.assertEqual(files[name], (project.HOME / "assets" / asset).read_bytes())

    def test_current_payload_count(self):
        """Keep the compact installed layout."""
        self.assertEqual(len(self.packed["payload"]), 5)
        self.assertEqual(len(self.packed["state"]), 3)
        for role, count in self.packed["bundleCounts"].items():
            if role not in ("core", "state"):
                self.assertEqual(count["after"], 3)

    def chamber_idle_runtime(self, quadrant, bundled=False):
        """Load a maintained chamber worker with controllable sampled hardware and probe outcomes."""
        prefix = "/packages/chamber/" + quadrant + "/"
        data = self.source["library"][prefix + "lift.lua"]
        if bundled:
            _, files = self.builder.bundling.unpack(self.packed["library"][prefix + "main.lua"],
                                                   self.source["assets"]["runtime-loader.lua"])
            data = files["/avionics/lift.lua"]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().LIFT_SOURCE = data.decode()
        lua.execute(r'''
NOW=10;os.clock=function() return NOW end
PROVIDERS={};PROBE_CALLS=0;SAMPLE_HOOK=nil;PROBE_ACTION=nil;ACTIVATION_VALID=true
H={localPeripheral=function() return {} end,
    isFiniteNumber=function(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end,
    sampleConfigured=function()
        if SAMPLE_HOOK then local f=SAMPLE_HOOK;SAMPLE_HOOK=nil;f() end
        return {providers=PROVIDERS,ready=true,faults={}}
    end,
    sampleBalloon=function() return {liftValid=true,lift=0} end,
    sampleAltitude=function() return {valid=true} end,
    sampleActivation=function() return {valid=ACTIVATION_VALID} end,
    startCompositionProbe=function(config,api,current)
        PROBE_CALLS=PROBE_CALLS+1
        if PROBE_ACTION then return PROBE_ACTION(current) end
        assert(current());return true,'PROBE_STARTED_WAITING_FOR_ENVELOPE'
    end}
require=function(name) assert(name=='hardware');return {lift=H} end
Main=assert(load(LIFT_SOURCE,'@chamber-lift'))('avionics.main')
function fresh()
    S={sourceConfig={},config={providers={},commandTimeoutSeconds=2},configValid=true,
        modemReady=true,armed=false,sessionGeneration=1,appliedTargets={bulk=1400,trim=5}}
    PROVIDERS={};PROBE_CALLS=0;PROBE_ACTION=nil;SAMPLE_HOOK=nil;ACTIVATION_VALID=true
end
function maintain() Main._test.maintainIdleProbe(S,{}) end
function status()
    Main._test.refreshSnapshot(S,{},NOW)
    return table.concat(S.faults,';')
end
function retained() assert(S.appliedTargets.bulk==1400 and S.appliedTargets.trim==5) end
fresh()
''')
        return lua

    def test_idle_probe_cancellation_retries_without_sticky_faults(self):
        """Supersede idle work during peripheral waits, retain newer faults, then recover on retry."""
        for quadrant in ("fl", "fr", "bl", "br"):
            for bundled in (False, True):
                with self.subTest(quadrant=quadrant, bundled=bundled):
                    lua = self.chamber_idle_runtime(quadrant, bundled)
                    lua.execute(r'''
S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_HARDWARE_GENERATION_CHANGED'
S.armed=true;maintain();assert(S.lastApplyFault==nil and PROBE_CALLS==0);retained()
fresh()
PROBE_ACTION=function(current)
    S.pendingCommand={seq=7};assert(not current())
    return false,'PROBE_HARDWARE_GENERATION_CHANGED'
end
maintain();assert(PROBE_CALLS==1 and S.lastApplyFault==nil);retained()
S.pendingCommand=nil;PROBE_ACTION=nil;maintain()
assert(PROBE_CALLS==2 and S.lastApplyFault==nil and not status():find('IDLE_PROBE_FAILED',1,true))
retained()
fresh()
PROBE_ACTION=function(current)
    S.sessionGeneration=S.sessionGeneration+1;assert(not current())
    return false,'PROBE_READ_FAILED'
end
maintain();assert(S.lastApplyFault==nil);retained()
fresh()
PROBE_ACTION=function(current)
    S.pendingCommand={seq=8};S.lastApplyFault='NEWER_COMMAND_FAULT';assert(not current())
    return false,'PROBE_HARDWARE_GENERATION_CHANGED'
end
maintain();assert(S.lastApplyFault=='NEWER_COMMAND_FAULT');retained()
fresh();SAMPLE_HOOK=function() S.pendingMaintenance={operation='inspect'} end
maintain();assert(PROBE_CALLS==0 and S.lastApplyFault==nil);retained()
''')

    def test_idle_probe_real_failures_clear_after_confirmed_recovery(self):
        """Keep current probe failures visible and clear only recovered probe-owned faults."""
        for quadrant in ("fl", "fr", "bl", "br"):
            for bundled in (False, True):
                with self.subTest(quadrant=quadrant, bundled=bundled):
                    lua = self.chamber_idle_runtime(quadrant, bundled)
                    lua.execute(r'''
PROBE_ACTION=function(current) assert(current());return false,'PROBE_BURNER_MISSING' end
maintain();assert(S.lastApplyFault=='IDLE_PROBE_FAILED:PROBE_BURNER_MISSING')
assert(status():find('IDLE_PROBE_FAILED:PROBE_BURNER_MISSING',1,true));retained()
PROBE_ACTION=nil;maintain()
assert(S.lastApplyFault==nil and not status():find('IDLE_PROBE_FAILED',1,true));retained()
S.lastApplyFault='UNRELATED_APPLY_FAULT';maintain()
assert(S.lastApplyFault=='UNRELATED_APPLY_FAULT');retained()
fresh();S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_READ_FAILED'
PROVIDERS={trim={controlRole='fine',signalValid=true,signalStrength=15,targetValid=true,
    targetAmount=5,maxTarget=500,minimumNonzeroTarget=5,activeValid=true,active=true}}
maintain();assert(S.lastApplyFault==nil and PROBE_CALLS==0);retained()
S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_READ_FAILED';ACTIVATION_VALID=false
maintain();assert(S.lastApplyFault=='IDLE_PROBE_FAILED:PROBE_READ_FAILED' and PROBE_CALLS==0);retained()
fresh();S.lastApplyFault='IDLE_PROBE_FAILED:PROBE_BURNER_MISSING'
PROVIDERS={bulk={controlRole='bulk',signalValid=true,signalStrength=15,targetValid=true,targetAmount=1400}}
maintain();assert(S.lastApplyFault=='IDLE_PROBE_FAILED:PROBE_BURNER_MISSING' and PROBE_CALLS==0);retained()
fresh();S.emergencyStopLatched=true;maintain();assert(PROBE_CALLS==0);retained()
fresh();S.systemsLease={expires=20};maintain();assert(PROBE_CALLS==0);retained()
''')

    def propulsion_runtime(self):
        """Connect maintained core and endpoint protocols through a controllable simulated radio."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().CORE_SOURCE = self.source["payload"]["/avionics/thrust.lua"].decode()
        lua.globals().MATH_SOURCE = project.source_files()["avionics/mathx.lua"].decode()
        lua.globals().REGISTRY_SOURCE = project.source_files()["avionics/config_registry.lua"].decode()
        lua.globals().CONFIG = table(lua, json.loads((project.ROOT / "source/core/avionics/config.json").read_bytes()))
        endpoints = {}
        for corner in ("lb", "rb", "ls", "rs"):
            folder = project.ROOT / "source/library/packages/thrust" / corner
            endpoints["thrust-" + corner] = {
                "source": project.source_files()["packages/thrust/" + corner + "/thrust.lua"].decode(),
                "config": json.loads((folder / "config.json").read_bytes()),
            }
        lua.globals().ENDPOINTS = table(lua, endpoints)
        lua.execute(r'''
NOW=10; DROP_COMMANDS=false; DROP_ALL=false; SENT={}; STATES={}; MODULES={}; IDS={}
os.clock=function() return NOW end
__THRUST_TEST=true
require=function(name)
    if name=="avionics.mathx" then return assert(load(MATH_SOURCE))() end
    if name=="avionics.config_registry" then return assert(load(REGISTRY_SOURCE))() end
    assert(name=="hardware")
    return {thrust={expectedShift=function(value,minimum,maximum)
        return math.floor(minimum+(maximum-minimum)*value+.5)
    end}}
end
Core=assert(load(CORE_SOURCE))(); core=Core.new(CONFIG)
io={session="lease-test-session",identityReady=true,vessel={},nowSeconds=function() return NOW end}
io.rednet={send=function(id,packet,protocol)
    SENT[#SENT+1]={id=id,packet=packet,at=NOW}
    if DROP_ALL or (DROP_COMMANDS and packet.kind=="thrust_command") then return true end
    local role=IDS[id]
    return MODULES[role].processPacket(STATES[role],0,packet,protocol,NOW)
end}
for index,role in ipairs(Core.CONTROLLERS) do
    local definition=ENDPOINTS[role]
    local endpoint=assert(load(definition.source))()
    definition.config.coreId=0
    local state=endpoint.newState(definition.config,role,"boot-"..role)
    state.configValid=true;state.bindingReady=true;state.writerEnabled=true
    state.enabled=true;state.ready=true;state.direction=1
    state.directionVerified=true;state.directionPhase="READY"
    MODULES[role]=endpoint;STATES[role]=state;IDS[index]=role
end
function hello()
    if DROP_ALL then return end
    for id,role in ipairs(Core.CONTROLLERS) do
        assert(core:acceptHello(io,id,{v=1,role=role,endpointKind="controller",
            nodeBoot=STATES[role].nodeBoot,drives=STATES[role].drives},NOW))
    end
end
function publish()
    for id,role in ipairs(Core.CONTROLLERS) do
        local state=STATES[role];local endpoint=MODULES[role]
        local targets=endpoint.targetsAt(state,NOW)
        local readbacks={}
        for _,drive in ipairs(state.drives) do
            readbacks[drive]={level=math.floor(math.abs(targets[drive])*256+.5),mode="incremental"}
        end
        endpoint.updateReadbacks(state,readbacks,NOW)
        state.readbackSampleAt=NOW
        if not DROP_ALL then assert(core:acceptStatus(io,id,endpoint.statusPacket(state,NOW),NOW)) end
    end
end
DEMAND={};for _,drive in ipairs(Core.DRIVES) do DEMAND[drive]=0 end
DEMAND["primary-left"]=.25;DEMAND["primary-right"]=.25
DEMAND["lateral-lb-p"]=.125
core.makeTargets=function() return DEMAND end
CONTROLS={available=true,modes={throttle="DIRECT",heading="MANUAL"},targets={speed=4,heading=90}}
function update()
    return core:update(io,NOW,CONTROLS)
end
hello();publish();assert(update());publish()
assert(STATES["thrust-lb"].leaseUntil==11)
''')
        return lua

    def test_propulsion_lease_recovers_after_repeated_lost_commands(self):
        """Expire all drive leases, keep dropping renewals, then recover without a reboot."""
        lua = self.propulsion_runtime()
        lua.execute(r'''
DROP_COMMANDS=true
for step=1,30 do
    NOW=10+step*.25
    hello();publish();assert(update())
end
local state=STATES["thrust-lb"]
assert(state.leaseUntil==false and state.reason=="COMMAND LEASE EXPIRED; RAMPING TO ZERO")
assert(state.desiredTargets["lateral-lb-p"]==0)
assert(core.controllers["thrust-lb"].commandRecovery.attempts>3)
local recovery=core:controllerSnapshot("thrust-lb",NOW).recovery
assert(recovery.state=="RETRYING ("..recovery.attempts..")")
assert(recovery.maximumAttempts==nil and recovery.failureAfterSeconds==nil)
local invalid={v=1,kind="thrust_command",role="thrust-lb",nodeBoot=state.nodeBoot,
    session="old-session",seq=1000,ttlSeconds=1,targets={['lateral-lb-p']=.5}}
assert(not MODULES["thrust-lb"].processPacket(state,0,invalid,CONFIG.protocol,NOW))
invalid.session=io.session;invalid.nodeBoot="old-boot"
assert(not MODULES["thrust-lb"].processPacket(state,0,invalid,CONFIG.protocol,NOW))
assert(state.leaseUntil==false and state.desiredTargets["lateral-lb-p"]==0)
local attempts=0
for _,sent in ipairs(SENT) do
    if sent.packet.kind=="thrust_command" and sent.at>11 then attempts=attempts+1 end
end
assert(attempts>3,"core must continue issuing commands after lease expiry")
DROP_COMMANDS=false;NOW=18;hello();publish();assert(update());publish()
for _,role in ipairs(Core.CONTROLLERS) do
    local current=STATES[role]
    assert(current.leaseUntil==19 and current.reason==nil and current.ackAccepted)
    assert(current.lastAppliedSeq==current.lastReceivedSeq)
    core:updateCommandRecovery(core.controllers[role],NOW)
    assert(core.controllers[role].commandRecovery==nil)
end
assert(state.desiredTargets["lateral-lb-p"]==.125)
assert(CONTROLS.targets.speed==4 and CONTROLS.targets.heading==90)
local seq=state.lastReceivedSeq;local deadline=state.leaseUntil
for _,sent in ipairs(SENT) do
    if sent.packet.role=="thrust-lb" and sent.packet.kind=="thrust_command" and sent.packet.seq<seq then
        assert(not MODULES["thrust-lb"].processPacket(state,0,sent.packet,CONFIG.protocol,NOW))
    end
end
assert(state.leaseUntil==deadline and state.lastReceivedSeq==seq)
''')

    def test_propulsion_recovers_after_session_gap_using_current_demand(self):
        """Reestablish a silent radio connection and renew the operator's current zero demand."""
        lua = self.propulsion_runtime()
        lua.execute(r'''
DROP_ALL=true
for step=1,32 do
    NOW=10+step*.25;publish();update()
end
assert(STATES["thrust-lb"].leaseUntil==false)
for drive in pairs(DEMAND) do DEMAND[drive]=0 end
DROP_ALL=false;NOW=19;hello();publish();assert(update());publish()
for _,role in ipairs(Core.CONTROLLERS) do
    local state=STATES[role]
    assert(state.leaseUntil==20 and state.ackAccepted)
    for _,value in pairs(state.desiredTargets) do assert(value==0) end
end
assert(core.active==false)
assert(CONTROLS.targets.speed==4 and CONTROLS.targets.heading==90)
''')


# ======================================================================
# From test_source_integrity: Explicit package-family guards at source and builder entry points.
# ======================================================================
import unittest
import project

class SourceIntegrityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.notes=project.builder_module().source_notes
        cls.files=project.source_files()

    def test_all_eleven_families_and_nine_links(self):
        self.assertEqual(self.notes.validate_package_families(self.files),11)
        self.assertEqual(len(self.notes.PACKAGE_FAMILIES['chamber-link']),9)

    def test_cross_group_executable_drift_rejected(self):
        for path in self.notes.PACKAGE_FAMILIES['chamber-link']:
            with self.subTest(path=path):
                changed=dict(self.files);changed[path]+=b'\nreturn 99\n'
                with self.assertRaisesRegex(ValueError,'chamber-link.*token'):
                    self.notes.validate_package_families(changed)

    def test_comments_allowed_except_normalized_families(self):
        changed=dict(self.files);path=self.notes.PACKAGE_FAMILIES['heading-main'][0]
        changed[path]=b'-- additional purpose detail\n'+changed[path]
        self.assertEqual(self.notes.validate_package_families(changed),11)
        for name in self.notes.BYTE_IDENTICAL_FAMILIES:
            changed=dict(self.files);path=self.notes.PACKAGE_FAMILIES[name][0]
            changed[path]=b'-- inconsistent header\n'+changed[path]
            with self.assertRaisesRegex(ValueError,'normalized comments/bytes'):
                self.notes.validate_package_families(changed)

    def test_missing_family_member_rejected(self):
        changed=dict(self.files);del changed['packages/common/chamber_link.lua']
        with self.assertRaisesRegex(ValueError,'missing packages/common/chamber_link'):
            self.notes.validate_package_families(changed)

    def test_core_console_matches_generated_package_console(self):
        """Reject direct edits to the generated core console copy."""
        import tempfile, shutil
        from pathlib import Path
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "checkout"
            shutil.copytree(project.ROOT / "source", root / "source")
            path = root / "source/core/avionics/common/console.lua"
            path.write_bytes(path.read_bytes() + b"\n-- direct core edit\n")
            with self.assertRaisesRegex(Exception, "differs from the console generated"):
                project.builder_module().collect_project(root)


    def test_runtime_global_catalogue_matches_source(self):
        """Every os.__amaryllis* name in maintained source and assets is documented, and vice versa."""
        import re
        names = set()
        roots = [project.ROOT / "source", project.HOME / "assets"]
        for root in roots:
            for path in root.rglob("*.lua"):
                data = path.read_bytes()
                names.update(re.findall(rb"os\.(__amaryllis\w+)", data))
                names.update(re.findall(rb'RuntimeState\.(?:get|set)\("(__amaryllis\w+)"', data))
        names = {name.decode() for name in names}
        catalogue = (project.ROOT / "docs/architecture/RUNTIME-GLOBALS.md").read_text(encoding="utf-8")
        documented = set(re.findall(r"^\| `(__amaryllis\w+)`", catalogue, re.M))
        self.assertEqual(sorted(names - documented), [], "undocumented runtime globals")
        self.assertEqual(sorted(documented - names), [], "documented runtime globals no longer in source")

    def test_worker_accessor_preserves_shared_identity_and_direct_os_interoperation(self):
        """Old direct writers and separately loaded accessors share the same os values."""
        from tests.test_builder import LuaRuntime
        source = self.files["avionics/runtime_state.lua"].decode()
        for bundled in (False, True):
            with self.subTest(bundled=bundled):
                lua = LuaRuntime(unpack_returned_tuples=True)
                lua.execute("fs={exists=function()return false end}")
                if bundled:
                    b = project.builder_module()
                    source_data = b.bundling.pack({
                        "/avionics/main.lua": b"return require('avionics.runtime_state')",
                        "/avionics/runtime_state.lua": source.encode()},
                        (project.HOME / "assets/runtime-loader.lua").read_bytes(),
                        role="runtime-state-test", entry="/avionics/main.lua")
                    lua.globals().Shared = lua.execute(source_data.decode())
                else:
                    lua.globals().Shared = lua.execute(source)
                lua.globals().Other = lua.execute(source)
                lua.execute('''
local key='__amaryllisSamplingContext'
local first={owner='first'};os[key]=first
assert(Shared.get(key)==first and Other.get(key)==first)
local second={owner='second'};Shared.set(key,second)
assert(os[key]==second and Other.get(key)==second and Shared.get(key)~=first)
Other.set(key,nil);assert(os[key]==nil and Shared.get(key)==nil)
''')

    def test_worker_entry_points_keep_current_owner_checks_in_source_and_bundle(self):
        """Actual main entry points execute current owners and reject obsolete owner tokens."""
        from tests.test_builder import LuaRuntime
        for bundled in (False, True):
            with self.subTest(bundled=bundled):
                files = {"/avionics/main.lua": self.files["avionics/main.lua"],
                         "/avionics/runtime_state.lua": self.files["avionics/runtime_state.lua"]}
                lua = LuaRuntime(unpack_returned_tuples=True)
                lua.execute("fs={exists=function()return false end}")
                if bundled:
                    files["/avionics/main.lua"] = project.builder_module().bundling.pack(files,
                        (project.HOME / "assets/runtime-loader.lua").read_bytes(),
                        role="worker-entry-test", entry="/avionics/main.lua")
                else:
                    lua.globals().Shared = lua.execute(files["/avionics/runtime_state.lua"].decode())
                    lua.execute("require=function(name) assert(name=='avionics.runtime_state');return Shared end")
                lua.globals().MAIN = files["/avionics/main.lua"].decode()
                lua.execute('''
for _,item in ipairs({{'propulsion-worker','Propulsion'}, {'debug-worker','Debug'},
                     {'sampler','Sampling'}, {'failover-sampler','Failover'}})do
 local called=0;local run=function()called=called+1 end
 local context={owner='current',run=run,jobs={vessel=run}}
 local key='__amaryllis'..item[2]..'Context';os[key]=context
 local entry=assert(load(MAIN))
 if context.jobs and (item[1]=='sampler' or item[1]=='failover-sampler')then
  entry(item[1],'vessel','current')
  assert(not pcall(entry,item[1],'vessel','obsolete'))
 else
  entry(item[1],'current');assert(not pcall(entry,item[1],'obsolete'))
 end
 assert(called==1 and os[key]==context)
 os[key]=nil
end
''')

    def test_every_test_module_is_in_the_project_suite(self):
        """A test file left out of project.SUITES would never run in project.py test or CI."""
        modules = {"tests." + path.stem for path in (project.ROOT / "tests").glob("test_*.py")}
        self.assertEqual(sorted(modules - set(project.SUITES)), [])

    def test_no_program_reseeds_the_shared_random_generator(self):
        """rednet takes message IDs from math.random and drops recently seen IDs; reseeding makes computers collide."""
        import re
        offenders = []
        for root in (project.ROOT / "source", project.HOME / "assets"):
            for path in root.rglob("*.lua"):
                for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    code = line.split("--", 1)[0]
                    if re.search(r"\bmath\.randomseed\s*\(", code):
                        offenders.append(f"{path.relative_to(project.ROOT)}:{number}")
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    import unittest
    unittest.main()
