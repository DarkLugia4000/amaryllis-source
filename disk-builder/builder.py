"""Build Amaryllis installation disks and update media from the maintained project source."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import subprocess
import tempfile
import threading
import uuid
import zipfile
import zlib

VERSION = "3.0.0"
HOME = Path(__file__).resolve().parent
DEFAULT_OUTPUT = HOME / "Installers"
_bundle_spec = importlib.util.spec_from_file_location("amaryllis_bundling", HOME / "bundling.py")
bundling = importlib.util.module_from_spec(_bundle_spec)
_bundle_spec.loader.exec_module(bundling)
_presentation_spec = importlib.util.spec_from_file_location("amaryllis_presentation", HOME / "presentation.py")
presentation = importlib.util.module_from_spec(_presentation_spec)
_presentation_spec.loader.exec_module(presentation)
_information_spec = importlib.util.spec_from_file_location("amaryllis_information", HOME / "information.py")
information = importlib.util.module_from_spec(_information_spec)
_information_spec.loader.exec_module(information)
_notes_spec = importlib.util.spec_from_file_location("amaryllis_source_notes", HOME / "source_notes.py")
source_notes = importlib.util.module_from_spec(_notes_spec)
_notes_spec.loader.exec_module(source_notes)
ROLES = ["navigator", "heading-left", "heading-right", "heading-main", "chamber_fl", "chamber_fr",
         "chamber_bl", "chamber_br", "primary_l", "primary_r", "thrust-lb", "thrust-rb", "thrust-ls", "thrust-rs", "state"]
FOLDERS = {"navigator": "navigation", **{f"heading-{v}": f"heading/{v}" for v in ("left", "right", "main")},
           **{f"chamber_{v}": f"chamber/{v}" for v in ("fl", "fr", "bl", "br")},
           **{f"primary_{v}": f"primary/{'left' if v=='l' else 'right'}" for v in ("l", "r")},
           **{f"thrust-{v}": f"thrust/{v}" for v in ("lb", "rb", "ls", "rs")}}
STATE_FILES = ["state_reader.lua", "state_wire.lua", "io.lua", "thrust.lua", "fleet.lua", "vessel_sources.lua",
               "storage.lua", "navigation_settings.lua", "input_tuning.lua", "sampling.lua", "diagnostics.lua", "cockpit_timing.lua"]
EXCLUDED_DIRS = {"data", "tests", "bundle", ".git", ".agents", "__pycache__"}
EXCLUDED_FILES = {"install_status.json", "fleet.json", "install-receipt.json", "deployment.json", "amaryllis-install.json"}
LEARNING = {"hover": "/avionics/data/hover-offset.json", "level": "/avionics/data/level-bias.json"}


class BuildError(Exception):
    """An actionable source, validation or output error."""


def require(condition, message):
    if not condition:
        raise BuildError(message)


def encode(value):
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()


def decode(data, label):
    try:
        return json.loads(data.decode("utf-8-sig"), parse_constant=lambda n: (_ for _ in ()).throw(ValueError(n)))
    except (ValueError, UnicodeError) as error:
        raise BuildError(f"Invalid JSON in {label}: {error}") from error


def sha(data):
    return hashlib.sha256(data).hexdigest()


def linked(path):
    info = path.lstat()
    return path.is_symlink() or bool(getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 1024))


class Snapshot:
    def __init__(self, root):
        self.root = root.resolve()
        self.files = {}

    # Read a bounded source file and record its content and path identity.
    def read(self, path):
        path = Path(path).absolute()
        require(path.resolve().is_relative_to(self.root), f"Source path leaves the selected computer folder: {path.name}")
        relative = path.relative_to(self.root)
        current = self.root
        for part in relative.parts:
            current /= part
            require(current.exists() and not linked(current), f"Missing or linked source item: {relative}")
        require(path.is_file(), f"Missing source file: {relative}")
        require(path.stat().st_size <= 4_000_000, f"Unexpectedly large source file: {relative}")
        data = path.read_bytes()
        if path in self.files:
            require(self.files[path] == data, f"Source changed while reading: {relative}. Retry after the edits finish.")
        self.files[path] = data
        return data

    def check_unchanged(self):
        for path in tuple(self.files):
            # Repeat path checks as well as byte checks in case a parent was replaced.
            self.read(path)


# Project source inputs and release provenance.
def project_inputs(root):
    """List maintained source and builder inputs that determine a project release."""
    root = Path(root).expanduser().absolute()
    require(root.is_dir() and not linked(root), "Choose an unlinked Amaryllis project folder.")
    paths = {"source/baseline.json": root / "source/baseline.json"}
    for group in ("core", "library", "calibration"):
        directory = root / "source" / group
        require(directory.is_dir() and not linked(directory), "Missing project source folder: " + group)
        for folder, directories, files in os.walk(directory, followlinks=False):
            require(all(not linked(Path(folder) / name) for name in directories), "Linked project source folder.")
            directories[:] = sorted(name for name in directories if not name.startswith("."))
            for name in sorted(files):
                path = Path(folder) / name
                if path.suffix in (".lua", ".json"):
                    paths[path.relative_to(root).as_posix()] = path
    for path in sorted(HOME.glob("*.py")):
        paths["builder/" + path.name] = path
    paths["builder/Start Builder.cmd"] = HOME / "Start Builder.cmd"
    paths["builder/assets/asset-hashes.json"] = HOME / "assets/asset-hashes.json"
    assets = decode((HOME / "assets/asset-hashes.json").read_bytes(), "builder assets")
    for name in assets:
        require(Path(name).name == name, "Invalid builder asset name.")
        paths["builder/assets/" + name] = HOME / "assets" / name
    return root.resolve(), paths


class ProjectSnapshot:
    """Retain real project inputs and reject edits or additions during packaging."""
    def __init__(self, root):
        self.root, paths = project_inputs(root)
        self.snapshots = {self.root: Snapshot(self.root), HOME: Snapshot(HOME)}
        self.files = {}
        self.inputs = {}
        for name, path in paths.items():
            owner = HOME if name.startswith("builder/") else self.root
            data = self.snapshots[owner].read(path)
            self.files[path] = data
            self.inputs[name] = sha(data)

    def check_unchanged(self):
        """Check both the input inventory and the bytes originally read."""
        _, paths = project_inputs(self.root)
        require(set(paths) == set(self.inputs), "Project inputs changed during the build. Build again.")
        for snapshot in self.snapshots.values():
            snapshot.check_unchanged()


def project_revision(root, tree_hash):
    """Describe Git revision and edits, retaining packaged provenance without Git."""
    revision = {"kind": "project-source", "commit": None, "dirty": None, "sourceTreeSHA256": tree_hash}
    try:
        def git(*arguments):
            return subprocess.run(["git", "-C", str(root), *arguments], check=True,
                                  capture_output=True, text=True, timeout=10).stdout.strip()
        if Path(git("rev-parse", "--show-toplevel")).resolve() == root:
            revision["commit"] = git("rev-parse", "HEAD")
            revision["dirty"] = bool(git("status", "--porcelain", "--untracked-files=normal"))
            return revision
    except (OSError, subprocess.SubprocessError):
        pass
    saved = root / "source/revision.json"
    if saved.is_file():
        record = decode(saved.read_bytes(), "packaged source revision")
        commit = record.get("commit")
        require(commit is None or re.fullmatch(r"[0-9a-f]{40,64}", str(commit)), "Invalid packaged source revision.")
        revision["commit"] = commit
        revision["dirty"] = record.get("dirty") if record.get("sourceTreeSHA256") == tree_hash else True
    return revision


def collect_project(selection, include_learning=True, log=lambda message: None):
    """Collect checkout software through a disposable adapter to the validated packager."""
    snapshot = ProjectSnapshot(selection)
    root = snapshot.root
    metadata = decode(snapshot.files[root / "source/baseline.json"], "source metadata")
    roles = metadata.get("roles", {})
    require(set(roles) == set(ROLES + ["core"]), "Project source must define all 16 computer roles.")
    files = {}
    for path, data in snapshot.files.items():
        if not path.is_relative_to(root / "source") or path.name in ("baseline.json", "revision.json"):
            continue
        parts = path.relative_to(root / "source").parts
        if parts[0] not in ("core", "library", "calibration"):
            continue
        destination = Path(*parts[1:]).as_posix()
        require(destination not in files, "Project source path collision: " + destination)
        files[destination] = data
    for destination, asset in metadata.get("assetBackedModules", {}).items():
        require(destination not in files and Path(asset).name == asset, "Invalid or duplicated asset-backed source.")
        require(destination.startswith(("avionics/", "installer/")) and ".." not in Path(destination).parts,
                "Unsafe project module destination.")
        files[destination] = snapshot.files[HOME / "assets" / asset]
    files = source_notes.expand_shared_modules(files, metadata.get("sharedModules", {}))
    source_notes.validate_package_families(files)
    # Stage the source as a core computer folder with a role registry, the layout collect() validates.
    work = HOME / ".cache"
    work.mkdir(exist_ok=True)
    require(not linked(work) and work.resolve().is_relative_to(HOME.resolve()), "Unsafe source staging folder.")
    with tempfile.TemporaryDirectory(prefix="source-", dir=work) as temporary:
        computers = Path(temporary) / "computercraft/computer"
        core = computers / "0"
        core.mkdir(parents=True)
        registry = {"schemaVersion": 1, "computers": {}}
        for number, (role, entry) in enumerate(roles.items()):
            registry["computers"][role] = {"id": number, "label": entry["label"]}
        core_id = registry["computers"]["core"]["id"]
        core = computers / str(core_id)
        core.mkdir(exist_ok=True)
        for name, data in files.items():
            path = core / name
            require(path.resolve().is_relative_to(core.resolve()), "Unsafe project source destination.")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (core / "fleet.json").write_bytes(encode(registry))
        source = collect(core, include_learning, log)
        # The core console is generated from the package console during collection.
        # Reject a maintained copy that differs, because direct edits to it would be discarded.
        generated = source["payload"].get("/avionics/common/console.lua")
        require(generated == files.get("avionics/common/console.lua"),
                "source/core/avionics/common/console.lua differs from the console generated from "
                "source/library/packages/common/console.lua. Edit the package console, then regenerate the core copy.")
    source.update(core=root, computers=root, snapshot=snapshot, packageSource={"kind": "project-source"})
    source["provenance"] = project_revision(root, sha(encode(snapshot.inputs)))
    source["notes"].append("Programs and defaults were read from the maintained project source.")
    log("Project source: " + str(root))
    log("Source fingerprint: " + source["provenance"]["sourceTreeSHA256"])
    return source


def default_project():
    """Find source beside the utility or at the repository root."""
    return next((path for path in (HOME.parent, HOME) if (path / "source/baseline.json").is_file()), None)


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


# Validate retained hover and leveling records before including calibration.
def validate_learning(hover, level):
    require(isinstance(level, dict) and set(level) == {"schemaVersion", "roll", "pitch"} and level["schemaVersion"] == 1,
            "The saved leveling file has an unsupported schema.")
    require(all(finite(level[k]) and abs(level[k]) <= 10000 for k in ("roll", "pitch")), "Saved leveling values are outside supported bounds.")
    require(isinstance(hover, dict) and set(hover) == {"schemaVersion", "bandBlocks", "bands"} and
            hover["schemaVersion"] == 1 and hover["bandBlocks"] == 20, "The saved hover file has an unsupported schema.")
    bands = hover["bands"]
    require(isinstance(bands, dict) and 1 <= len(bands) <= 64, "Saved hover data must contain 1 to 64 altitude bands.")
    for band, row in bands.items():
        require(isinstance(band, str) and re.fullmatch(r"-?\d+", band) is not None and str(int(band)) == band and
                -10240 <= int(band) <= 10240 and int(band) % 20 == 0, "Invalid saved hover altitude band.")
        require(isinstance(row, dict) and set(row) == {"offset", "samples"} and finite(row["offset"]) and abs(row["offset"]) <= .15 and
                type(row["samples"]) is int and 1 <= row["samples"] <= 1000, f"Invalid correction in hover band {band}.")


def portable_path(path):
    require(isinstance(path, str) and path.startswith("/avionics/") and "\\" not in path and ":" not in path and
            all(v not in ("", ".", "..") for v in path.split("/")[1:]), f"Unsupported package destination: {path}")
    return PurePosixPath(path)


def library_entries(mapping):
    return [{"path": p, "object": sha(d), "bytes": len(d), "adler32": f"{zlib.adler32(d):08X}"}
            for p, d in sorted(mapping.items())]


# Summary: Validate and package the staged project core: registry, programs, package manifests, learning and state reader files.
def collect(core, include_learning=True, log=lambda s: None):
    core = Path(core).resolve()
    computers = core.parent
    snap = Snapshot(computers)
    fleet = decode(snap.read(core / "fleet.json"), "fleet.json")
    require(isinstance(fleet, dict) and fleet.get("schemaVersion") == 1 and isinstance(fleet.get("computers"), dict), "Unsupported fleet registry.")
    registry = fleet["computers"]
    require(set(registry) == set(ROLES + ["core"]), "This builder expects the standard 16 Amaryllis roles. The registry is incomplete or has unsupported roles.")
    require(isinstance(registry["core"], dict) and registry["core"].get("id") == int(core.name),
            "Core's registry ID does not match the selected computer folder.")
    labels, ids = set(), set()
    for role, record in registry.items():
        require(isinstance(record, dict) and isinstance(record.get("label"), str) and
                re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", record["label"]) is not None, f"Invalid label for {role}.")
        require(record["label"] not in labels, "The fleet registry contains duplicate labels.")
        labels.add(record["label"])
        if record.get("id") is not None:
            require(type(record["id"]) is int and 0 <= record["id"] <= 65535 and record["id"] not in ids, "The fleet registry contains invalid or duplicate IDs.")
            ids.add(record["id"])
    loader = (HOME / "assets/runtime-loader.lua").read_bytes()
    asset_hashes = decode((HOME / "assets/asset-hashes.json").read_bytes(), "builder assets")
    require(sha(loader) == asset_hashes.get("runtime-loader.lua"), "Builder runtime loader changed or is damaged.")
    payload = {}
    for directory in ("avionics", "packages", "installer"):
        root = core / directory
        require(root.is_dir() and not linked(root), f"Required source folder is missing or linked: {directory}")
        for folder, dirs, files in os.walk(root, followlinks=False):
            for child in dirs:
                require(not linked(Path(folder) / child), f"Linked source folder is not supported: {child}")
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS and not d.startswith("."))
            for name in sorted(files):
                if name in EXCLUDED_FILES or name.startswith(".") or Path(name).suffix not in (".lua", ".json"):
                    continue
                path = Path(folder) / name
                relative = path.relative_to(core).as_posix()
                data = snap.read(path)
                if path.suffix == ".json":
                    value = decode(data, relative)
                    require(isinstance(value, dict), f"Expected a JSON object in {relative}.")
                payload["/" + relative] = data
    payload["/startup.lua"] = snap.read(core / "startup.lua")
    information.strip_notes(payload)
    for path, data in list(payload.items()):
        if path.startswith("/packages/") and path.endswith("/config.json"):
            value = decode(data, path)
            require(isinstance(value, dict) and not any(k in value for k in ("install", "coreId", "computerId", "computer_id")),
                    f"Package config contains installation-specific identity: {path}")
    for required in ("/avionics/main.lua", "/avionics/flight.lua", "/avionics/pid.lua", "/avionics/config.json", "/installer/server.lua"):
        require(required in payload, f"Missing core program file: {required}")
    config = decode(payload["/avionics/config.json"], "core configuration")
    require(config.get("schema_version") == 1 and config.get("role") == "core" and
            isinstance(config.get("altitude_control"), dict) and isinstance(config.get("thrust"), dict) and
            isinstance(config.get("commissioning"), dict), "Unsupported or incomplete core configuration.")
    for key in ("computer_id", "bridge_id", "node_ids", "display_ids", "role_ids"):
        config.pop(key, None)
    config["thrust"]["enabled"] = False
    config["hardware"] = {"discover": True, "main_monitor": "", "link_bridge": ""}
    config["commissioning"]["enabled"] = False
    payload["/avionics/config.json"] = encode(config)
    versions = {}
    for role, directory in FOLDERS.items():
        prefix = "/packages/" + directory + "/"
        require(prefix + "manifest.json" in payload, f"Package manifest missing for {role}.")
        manifest = decode(payload[prefix + "manifest.json"], role + " manifest")
        require(manifest.get("schemaVersion") == 1 and manifest.get("role") == role and
                type(manifest.get("version")) is int and 1 <= manifest["version"] <= 65535 and
                isinstance(manifest.get("packageId"), str) and 1 <= len(manifest["packageId"]) <= 64 and isinstance(manifest.get("files"), list),
                f"Unsupported package manifest for {role}.")
        require(1 <= len(manifest["files"]) <= 64 and all(isinstance(v, str) for v in manifest["files"]) and
                len(set(manifest["files"])) == len(manifest["files"]), f"Invalid package file list for {role}.")
        total, mapped = 0, set()
        for target in manifest["files"]:
            p = portable_path(target)
            source = {"/avionics/common/console.lua": "/packages/common/console.lua",
                      "/avionics/diagnostics.lua": "/packages/common/diagnostics.lua"}.get(target, prefix + p.name)
            require(source not in mapped, f"Package file mapping collides for {role}.")
            mapped.add(source)
            require(source in payload, f"Package {role} is incomplete: missing {p.name}.")
            require(len(payload[source]) <= 524288, f"Package file exceeds receiver limit: {role}/{p.name}")
            total += len(payload[source])
        require(total <= 1048576, f"Package {role} exceeds the receiver's total-size limit.")
        versions[role] = manifest["version"]
    calibration = {}
    notes = []
    if include_learning:
        paths = {k: core / v.lstrip("/") for k, v in LEARNING.items()}
        present = [p.exists() for p in paths.values()]
        if not any(present):
            notes.append("No saved hover/level learning was present. Fresh cores will learn it during flight.")
        else:
            require(all(present), "Only one learning file is present. Choose another save or turn off Include saved learning.")
            values = {k: decode(snap.read(p), p.name) for k, p in paths.items()}
            validate_learning(values["hover"], values["level"])
            calibration = {LEARNING[k]: encode(values[k]) for k in ("hover", "level")}
            notes.append(f"Included {len(values['hover']['bands'])} saved hover bands and roll/pitch leveling bias.")
    else:
        notes.append("Saved learning was intentionally excluded.")
    assets_manifest = decode((HOME / "assets/asset-hashes.json").read_bytes(), "builder assets")
    assets = {}
    for name in ("setup.lua", "startup.lua", "auxiliary-startup.lua", "bootstrap-launcher.lua", "installer.lua", "core-progress.lua", "core-media.lua", "runtime-loader.lua", "panel-console.lua", "remote-panel.lua", "disk-download.lua", "web-setup.lua", "pastebin-loader.lua"):
        data = (HOME / "assets" / name).read_bytes()
        require(sha(data) == assets_manifest.get(name), f"Builder support file changed or is damaged: {name}. Restore the utility's assets folder.")
        assets[name] = data
    server = payload["/installer/server.lua"]
    require(b'"/installer/progress.lua"' in server and b"deps.progress:setFleet(fleet,ROLE_FILES)" in server and
            b"deps.progress:update(status)" in server and b"deps.progress:draw(status)" in server,
            "Core installer does not expose the supported progress interface. Update the builder for this installer version.")
    payload["/installer/progress.lua"] = assets["core-progress.lua"]
    payload["/installer/media.lua"] = assets["core-media.lua"]
    package_library = {p: payload.pop(p) for p in list(payload) if p.startswith("/packages/")}
    library_notes,_ = source_notes.annotate(package_library)
    catalog = {"schemaVersion": 1, "files": library_entries(package_library), "roles": {
        role: {k: decode(package_library[f"/packages/{folder}/manifest.json"], role)[k] for k in ("packageId", "version")}
        for role, folder in FOLDERS.items()}}
    catalog["libraryId"] = sha(encode(catalog))
    require(len(encode(catalog)) <= 65536 and len(catalog["files"]) <= 256, "Package catalog exceeds core's bounded metadata limit.")
    payload["/installer/library.json"] = encode(catalog)
    payload["/avionics/common/console.lua"] = package_library["/packages/common/console.lua"]
    presentation.apply_console(payload, assets["panel-console.lua"], require)
    presentation.apply_remote(payload, assets["remote-panel.lua"], require)
    startup = payload["/startup.lua"]
    require(b'/avionics/common/console.lua' in startup, "Unsupported core startup console path.")
    core_notes,_ = source_notes.annotate(payload)
    # Resolve state dependencies from the final overlaid core source. This is
    # stable when rebuilding an installed bundle and includes newly added imports.
    state_names = set(STATE_FILES)
    pending = list(STATE_FILES)
    while pending:
        name = pending.pop()
        key = "/avionics/" + name
        require(key in payload, f"State reader dependency is missing: {name}")
        for module in re.findall(r'''require\s*\(?\s*["'](avionics\.[A-Za-z0-9_.]+)["']''', payload[key].decode("utf-8")):
            dep = module.removeprefix("avionics.").replace(".", "/") + ".lua"
            if dep not in state_names:
                state_names.add(dep);pending.append(dep)
    state_payload = {"/avionics/" + name: payload["/avionics/" + name] for name in sorted(state_names)}
    state_payload["/avionics/config.json"] = encode({"schemaVersion": 1, "role": "state", "label": registry["state"]["label"]})
    state_payload["/startup.lua"] = b'if multishell and shell.openTab then local t=shell.openTab("/avionics/state_reader.lua");multishell.setTitle(t,"ama-state") else shell.run("/avionics/state_reader.lua") end\n'
    notes.append("Auxiliary package programs remain on removable media; core retains its console and trusted version metadata.")
    log(f"Validated {len(payload)} core files and {len(versions)} auxiliary packages.")
    return {"core": core, "computers": computers, "snapshot": snap, "payload": payload, "state": state_payload,
            "calibration": calibration, "assets": assets, "roles": {r: {"label": v["label"]} for r, v in registry.items()},
            "versions": versions, "notes": notes, "library": package_library, "catalog": catalog,
            "sourceDocumentation": core_notes + library_notes}


# Describe the generated media, setup procedure and update helper.
PYTHON_RUNTIME_SKIP_DIRS = {"__pycache__", "site-packages", "test", "tests", "idlelib", "turtledemo", "ensurepip", "lib2to3"}


# Section: Windows helpers | Bundled Python runtime for the settings and update tools.
# Summary: Copy this Windows Python install, with Tcl/Tk, into a folder that the helper launchers can run.
def bundle_python_runtime(destination, base=None, windows=None):
    destination = Path(destination)
    base = Path(base or sys.base_prefix)
    if not (os.name == "nt" if windows is None else windows) or not (base / "python.exe").is_file() or not (base / "tcl").is_dir():
        return None, "Python was not bundled because this build did not run on a Windows Python with Tcl/Tk."
    def keep(directory, names):
        return [name for name in names if name in PYTHON_RUNTIME_SKIP_DIRS or name.lower().endswith((".pdb", ".lib", ".pyc"))]
    try:
        destination.mkdir(parents=True)
        for item in base.iterdir():
            lowered = item.name.lower()
            if item.is_dir() and lowered in ("dlls", "lib", "tcl"):
                shutil.copytree(item, destination / item.name, ignore=keep)
            elif item.is_file() and lowered.endswith((".exe", ".dll", ".txt")) and not lowered.startswith(("unins", "vcredist")):
                shutil.copy2(item, destination / item.name)
        check = subprocess.run([str(destination / "python.exe"), "-I", "-c",
                                "import sys, tkinter; tkinter.Tcl(); sys.exit(0 if sys.version_info >= (3, 11) else 1)"],
                               capture_output=True, timeout=30)
        if check.returncode != 0:
            raise RuntimeError(check.stderr.decode(errors="replace").strip() or "bundled Python failed its Tcl/Tk check")
    except BaseException as error:
        shutil.rmtree(destination, ignore_errors=True)
        return None, f"Python was not bundled: {error}"
    return destination, "Python " + sys.version.split()[0] + " with Tcl/Tk is bundled in the python folder."


# Section: Windows helpers | Bundled Python runtime for the settings and update tools.
# Summary: Build a helper launcher that prefers the bundled Python and falls back to the standard search.
def helper_launcher(script, remove_gui=False):
    original = (HOME / "Start Builder.cmd").read_bytes().replace(b"builder.py", script.encode())
    if remove_gui:
        original = original.replace(b" --gui", b"")
    lines = original.split(b"\r\n")
    bundled = [b'if exist "%~dp0..\\python\\pythonw.exe" (',
               b'    start "" "%~dp0..\\python\\pythonw.exe" "%~dp0' + script.encode() + b'"',
               b"    exit /b", b")"]
    return b"\r\n".join(lines[:2] + bundled + lines[2:])


def installer_readme(manifest, report):
    state = report["source"]["dirty"]
    edits = "yes" if state is True else "no" if state is False else "unknown"
    return (f"# Amaryllis installer {manifest['releaseId']}\n\n"
            + "Software source: maintained project\n"
            + f"Revision: {report['source']['commit'] or 'unversioned source snapshot'}\n"
            + f"Includes uncommitted changes: {edits}\n"
            + f"Source fingerprint: {report['source']['sourceTreeSHA256']}\n\n" +
            "Copy the contents of media/ to an empty, writable ComputerCraft installer disk.\n"
            f"Allow at least {report['minimumMediaCapacityBytes']:,} bytes of disk capacity and 4,000,000 bytes per computer.\n\n"
            "Web install: the GitHub release workflow publishes media/ on the release branch, and the\n"
            "Pastebin loader (media/loader.lua) runs web-setup.lua on each computer: install core first,\n"
            "then register every other computer with core over rednet, then import on core.\n"
            "To fill a floppy disk from the web instead, run media/download.lua with wget run.\n\n"
            "The python/ folder, when present, lets the Windows helpers run without a separate Python install.\n"
            "To prepare a Windows Minecraft instance, open windows-settings/Configure ComputerCraft.cmd.\n"
            "It previews capacity/thread edits, requires Minecraft/server closed, and backs up the selected\n"
            "computercraft-server.toml. These Windows helpers do not go onto the in-game disk.\n\n"
            "For an existing ship, run windows-update/Update Amaryllis.cmd (Minecraft may stay open),\n"
            "select the existing save and this media folder, then preview and apply the replacement.\n"
            "It updates all registered computers, retains stored settings and learning, backs up outside\n"
            "the save and removes obsolete managed programs. Use Restore backup for recovery.\n\n"
            "With the vessel disassembled and supported, boot from the disk or run /disk/startup.lua.\n"
            "Install core first,\n"
            "register the other roles with the same disk, then return it to core and import\n"
            "role assignments before starting core. Choose Start core with disk and leave the disk inserted.\n"
            "New IDs are assigned during installation.\n"
            "The installer starts with propulsion disabled and preserves existing installations.\n\n"
            "Setup shows your computer ID and computer names such as chamber-bl, thrust-rb,\n"
            "bridge and hdg-m, with confirmation before changes.\n"
            "Use Left/Right for pages, Up/Down to select and Enter to choose. Confirm with the YES/NO selector.\n"
            "Open Assignments to review registrations or correct a move/swap BEFORE core import.\n"
            "Visit every computer listed in a correction plan using the same disk. Import waits\n"
            "for completed corrections and all 16 roles. Already installed packages are not relabeled.\n"
            "On receiving auxiliaries the temporary setup screen removes itself after a verified\n"
            "package receipt; the normal updater and recovery records remain.\n\n"
            + ("Program modules are bundled per computer. Configuration and saved learning remain\n"
               "separate. Media remains useful for installation and repair.\n\n" if report.get("bundling") else "") +
            "Watch core's Installation page for the package roster, current file, transfer percentage,\n"
            "verification and faults. It announces completion after all 14 wireless packages verify.\n"
            "The state reader uses direct disk setup; check its wired link separately.\n\n"
            "Auxiliary programs stay on this removable disk, not on core. Remove it after\n"
            "installation; flight keeps working and Installation waits for media. Insert\n"
            "it again for auxiliary repair. Choose Adopt auxiliary package library in Setup,\n"
            "with core stopped; it verifies all objects and requires the same core runtime.\n"
            "Use the Windows updater for core/state replacement and loose-file migration.\n"
            "Keep this disk or media for installation and repair.\n\n"
            "If included, saved hover/level defaults seed missing core learning files only.\n"
            "Different loads or balloon layouts may need further settling and learning.\n\n"
            "This release contains the maintained project source. File/package checks do not establish\n"
            "which code was running in-game, compile Lua, or certify flight behavior.\n")


# Build verified runtime media and optionally export the distributable installer package.
# The web downloader (download.lua) fetches the media folder file by file in this
# order: objects first, the installer and manifests next, startup.lua last, so a
# disk boots only from a complete download. The index lists neither itself nor
# loader.lua, whose repository the release workflow fills in after the build.
DOWNLOAD_LAST = ("library.json", "setup.lua", "download.lua", "web-setup.lua", "release.json", "startup.lua")


def write_download_index(media, release_id):
    """Write media/download.json: every media file with its size and Adler-32, in download order."""
    def entry(path):
        data = (media / path).read_bytes()
        return {"path": path, "bytes": len(data), "adler32": f"{zlib.adler32(data):08X}"}
    objects = sorted("objects/" + p.name for p in (media / "objects").iterdir() if p.is_file())
    files = [entry(p) for p in objects] + [entry(p) for p in DOWNLOAD_LAST]
    (media / "download.json").write_bytes(encode({"schemaVersion": 1, "releaseId": release_id, "files": files}))


def build(selection, output_parent, include_learning=True, log=lambda s: None, bundle=True, *, installer_package=True):
    source = collect_project(selection, include_learning, log)
    if bundle:
        try:
            source = bundling.prepare(source, FOLDERS)
        except (ValueError, KeyError, TypeError) as error:
            raise BuildError("Cannot create runtime bundles: " + str(error)) from error
        catalog = {"schemaVersion": 1, "files": library_entries(source["library"]), "roles": {
            role: {k: decode(source["library"][f"/packages/{folder}/manifest.json"], role)[k] for k in ("packageId", "version")}
            for role, folder in FOLDERS.items()}}
        catalog["libraryId"] = sha(encode(catalog))
        require(len(encode(catalog)) <= 65536 and len(catalog["files"]) <= 256, "Bundled catalog exceeds metadata limits.")
        source["catalog"] = catalog
        source["payload"]["/installer/library.json"] = encode(catalog)
    # Document the final commissioning copies after bootstrap selection.
    exported_assets={"/disk/"+name:source["assets"][name] for name in
                     ("setup.lua","startup.lua","installer.lua","bootstrap-launcher.lua","auxiliary-startup.lua")}
    exported_assets["/disk/download.lua"]=source["assets"]["disk-download.lua"]
    exported_assets["/disk/web-setup.lua"]=source["assets"]["web-setup.lua"]
    information.strip_notes(exported_assets)
    installer_notes,_=source_notes.annotate(exported_assets)
    source["assets"]=dict(source["assets"])
    for path,data in exported_assets.items():
        name=path.removeprefix("/disk/");source["assets"]["disk-download.lua" if name=="download.lua" else name]=data
    source["sourceDocumentation"].extend(installer_notes)
    parent = Path(output_parent).expanduser().resolve()
    require(parent.is_dir(), "Choose an existing output folder.")
    require(not parent.is_relative_to(source["core"] / "source"), "Output must be outside editable source folders.")
    token = uuid.uuid4().hex[:8]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    staging = parent / f"Amaryllis-INCOMPLETE-{stamp}-{token}"
    staging.mkdir()
    (staging / "INCOMPLETE.txt").write_text("Build not verified. Do not use this installer.\n")
    try:
        media = staging / "media";objects = media / "objects";objects.mkdir(parents=True)
        def entries(mapping):
            out = []
            for path, data in sorted(mapping.items()):
                digest = sha(data);(objects / digest).write_bytes(data)
                out.append({"path": path, "object": digest, "bytes": len(data), "adler32": f"{zlib.adler32(data):08X}"})
            return out
        manifest = {"schemaVersion": 1, "roles": source["roles"], "roleOrder": ROLES,
                    "core": entries(source["payload"]), "state": entries(source["state"]),
                    "library": entries(source["library"]), "libraryId": source["catalog"]["libraryId"],
                    "bootstrap": entries({"/installer.lua": source["assets"]["installer.lua"],
                                          "/startup.lua": source["assets"]["bootstrap-launcher.lua"],
                                          "/installer/commissioning.lua": source["assets"]["auxiliary-startup.lua"]}),
                    "minimumComputerSpaceBytes": 4_000_000}
        if source["calibration"]:
            manifest["calibration"] = {"schemaVersion": 1, "name": "Amaryllis learned lift defaults",
                "capturedDate": datetime.now().date().isoformat(), "files": entries(source["calibration"])}
        # Bind commissioning scripts too, so changing the installer changes the release ID.
        manifest["installerScripts"] = {name: sha(source["assets"][name]) for name in ("setup.lua", "startup.lua")}
        manifest["source"] = source["provenance"]
        manifest["releaseId"] = "amaryllis-" + sha(json.dumps(manifest, sort_keys=True).encode())[:12]
        (media / "release.json").write_bytes(encode(manifest))
        (media / "library.json").write_bytes(encode(source["catalog"]))
        for name in ("setup.lua", "startup.lua"):
            (media / name).write_bytes(source["assets"][name])
        (media / "download.lua").write_bytes(source["assets"]["disk-download.lua"])
        # Web install: web-setup.lua runs on every computer; loader.lua is the Pastebin
        # text, its repository filled in by the GitHub Actions release workflow.
        (media / "web-setup.lua").write_bytes(source["assets"]["web-setup.lua"])
        (media / "loader.lua").write_bytes(source["assets"]["pastebin-loader.lua"])
        write_download_index(media, manifest["releaseId"])
        core_bytes = sum(e["bytes"] for e in manifest["core"]) + sum(len(d) for d in source["calibration"].values())
        require(core_bytes + 65536 < 4_000_000, "Core payload no longer fits the supported 4 MB installation budget.")
        media_bytes = sum(p.stat().st_size for p in media.rglob("*") if p.is_file())
        report = {"builderVersion": VERSION, "releaseId": manifest["releaseId"],
                  "builtAtUTC": datetime.now(timezone.utc).isoformat(), "sourceCore": str(source["core"]),
                  "coreFiles": len(manifest["core"]), "corePayloadBytes": core_bytes,
                  "libraryBytes": sum(len(d) for d in source["library"].values()),
                  "mediaBytes": media_bytes, "minimumMediaCapacityBytes": media_bytes + 16384,
                  "packageVersions": source["versions"], "learningFiles": len(source["calibration"]),
                  "notes": source["notes"], "packageSource": source["packageSource"],
                  "sourceFiles": source["snapshot"].inputs,
                  "builderOverrides": {path: sha(source["payload"][path]) for path in
                      ("/installer/progress.lua", "/installer/server.lua", "/installer/media.lua", "/avionics/io.lua",
                       "/avionics/main.lua", "/avionics/identity_watch.lua", "/startup.lua") if path in source["payload"]},
                  "bundling": source.get("bundleCounts"),
                  "validation": {"objects": True, "sourceStable": True, "archive": installer_package,
                                 "luaCompiled": False, "inGameAcceptance": False},
                  "source": source["provenance"]}
        if not bundle:
            report["builderOverrides"]["/packages/navigation/ui.lua"] = sha(source["library"]["/packages/navigation/ui.lua"])
        if installer_package:
            (staging / "README.md").write_text(installer_readme(manifest, report), encoding="utf-8")
            helper = staging / "windows-settings"
            helper.mkdir()
            (helper / "cc_settings.py").write_bytes((HOME / "cc_settings.py").read_bytes())
            (helper / "Configure ComputerCraft.cmd").write_bytes(helper_launcher("cc_settings.py", True))
            (helper / "README.md").write_text(
                "# ComputerCraft settings helper\n\n"
                "Run Configure ComputerCraft.cmd on Windows. It uses the python folder next to this one when present,\n"
                "otherwise Python 3.11+ with Tcl/Tk.\n"
                "Select the active computercraft-server.toml, load it, and preview capacity/thread\n"
                "changes. Capacities require at least 4 MB and can only increase. Threads start\n"
                "at the current value; higher counts can affect lag and mod compatibility.\n\n"
                "Close Minecraft/server fully before applying. The helper checks running Java\n"
                "processes too, but cannot identify every custom launcher. It changes only the\n"
                "two capacity values and execution.computer_threads. Other settings are preserved.\n"
                "A verified backup and hash record are saved beside the selected file. Restore\n"
                "backup returns the previous file and capacity limits, and refuses newer edits.\n\n"
                "An instance-wide config affects all worlds in that instance. Restart afterward.\n"
                "This helper does not update ship programs. Keep windows-settings on Windows;\n"
                "only the separate media folder belongs on the in-game installer disk.\n", encoding="utf-8")
            update_helper = staging / "windows-update"
            (update_helper / "assets").mkdir(parents=True)
            for name in ("updater.py", "bundling.py", "cc_settings.py"):
                (update_helper / name).write_bytes((HOME / name).read_bytes())
            (update_helper / "assets/runtime-loader.lua").write_bytes(source["assets"]["runtime-loader.lua"])
            for name in ("bootstrap-launcher.lua", "asset-hashes.json"):
                (update_helper / "assets" / name).write_bytes((HOME / "assets" / name).read_bytes())
            (update_helper / "Update Amaryllis.cmd").write_bytes(helper_launcher("updater.py"))
            python_folder, python_note = bundle_python_runtime(staging / "python")
            log(python_note)
            (update_helper / "README.md").write_text(
                "# Update an existing Amaryllis\n\nMinecraft may stay open. Run Update Amaryllis.cmd.\n"
                "Select the existing save or its numeric core folder. The new media folder is selected automatically.\n"
                "Choose a backup folder outside the save, preview the file changes, then apply the update.\n"
                "All 16 registered computers are updated together. Stored settings and avionics/data are retained.\n"
                "Old managed programs and core's package library are removed after a verified external backup.\n"
                "Reboot each computer (or load the world) to run the new programs. Media remains useful for installation or repair.\n"
                "Restore backup checks for newer edits before restoring. If interrupted, do not edit the computers\n"
                "and select the transaction's Amaryllis-update folder using Restore backup.\n"
                "This helper requires Windows. It uses the python folder next to this one when present, otherwise\n"
                "Python 3.11+ with Tcl/Tk. Keep windows-update on Windows.\n", encoding="utf-8")
        for group in (manifest["core"], manifest["state"], manifest["bootstrap"], manifest["library"], manifest.get("calibration", {}).get("files", [])):
            for entry in group:
                data = (objects / entry["object"]).read_bytes()
                require(sha(data) == entry["object"] and len(data) == entry["bytes"] and
                        f"{zlib.adler32(data):08X}" == entry["adler32"], "Output object verification failed.")
        if installer_package:
            share_files = {"README.md": (staging / "README.md").read_bytes(),
                           **{p.relative_to(staging).as_posix(): p.read_bytes()
                              for folder in (media, helper, update_helper, *([python_folder] if python_folder else []))
                              for p in folder.rglob("*") if p.is_file()}}
            archive_path = staging / "amaryllis-installer.zip"
            with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as archive:
                for name, data in sorted(share_files.items()):archive.writestr(name, data)
            with zipfile.ZipFile(archive_path) as archive:
                require(archive.testzip() is None and set(archive.namelist()) == set(share_files) and
                        all(archive.read(n) == d for n, d in share_files.items()), "ZIP verification failed.")
        source["snapshot"].check_unchanged()
        (staging / "build-report.json").write_bytes(encode(report))
        final = parent / f"Amaryllis-{stamp}-{manifest['releaseId'].removeprefix('amaryllis-')}-{token}"
        require(not final.exists(), "Output already exists. Choose a new output folder.")
        # Single file removed only after verification; failed folders remain labelled incomplete.
        (staging / "INCOMPLETE.txt").unlink()
        os.rename(staging, final)
        log("Build verified. No source files were changed.")
        for note in source["notes"]:log(note)
        return final, report
    except BaseException as error:
        try:
            (staging / "INCOMPLETE.txt").write_text("Do not use this output. Build failed: " + str(error) + "\n", encoding="utf-8")
        except OSError:
            pass
        raise BuildError(f"{error}\nIncomplete output retained at: {staging}") from error


def build_error_details(error):
    """Private support log; excludes source file contents and pairing data."""
    import traceback
    try:
        folder = HOME / "Logs"
        folder.mkdir(exist_ok=True)
        target = folder / ("build-error-" + datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8] + ".json")
        record = {"builderVersion": VERSION, "python": sys.version, "executable": sys.executable,
                  "message": str(error), "traceback": traceback.format_exc()}
        target.write_text(json.dumps(record, indent=2), encoding="utf-8")
        return str(error) + "\n\nDetails: " + str(target)
    except Exception:
        return str(error)


# Create the Windows build interface and its queued background operations.
def gui():
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
    root = tk.Tk();root.title("Amaryllis Disk Builder "+VERSION);root.geometry("800x780");root.minsize(700, 720)
    style = ttk.Style(root);style.theme_use("clam")
    style.configure("TLabel", font=("Segoe UI", 10));style.configure("TButton", font=("Segoe UI", 10), padding=7)
    style.configure("Title.TLabel", font=("Segoe UI", 19, "bold"))
    frame = ttk.Frame(root, padding=24);frame.pack(fill="both", expand=True)
    ttk.Label(frame, text="Amaryllis Disk Builder", style="Title.TLabel").pack(anchor="w")
    description=ttk.Label(frame, text="Builds an installation disk or an existing-ship update from the maintained project source.", wraplength=740, justify="left")
    description.pack(anchor="w", fill="x", pady=(4, 20))
    description.bind("<Configure>", lambda event: description.configure(wraplength=max(1,event.width)))
    project = default_project()
    source = tk.StringVar(value=str(project) if project else "");learning = tk.BooleanVar(value=True)
    def choose(variable):
        value = filedialog.askdirectory(parent=root, initialdir=variable.get() or str(Path.home()))
        if value:variable.set(value)
    ttk.Label(frame, text="Amaryllis project folder").pack(anchor="w")
    source_row = ttk.Frame(frame);source_row.pack(fill="x", pady=(5, 15))
    ttk.Entry(source_row, textvariable=source).pack(side="left", fill="x", expand=True)
    ttk.Button(source_row, text="Browse…", command=lambda: choose(source)).pack(side="right", padx=(8, 0))
    ttk.Checkbutton(frame, variable=learning, text="Include shipped hover and leveling defaults").pack(anchor="w")
    status = tk.StringVar(value="Ready")
    row = ttk.Frame(frame);row.pack(fill="x", pady=(0, 10))
    button = ttk.Button(row, text="Build installer");button.pack(side="left")
    open_button = ttk.Button(row, text="Open result", state="disabled");open_button.pack(side="left", padx=8)
    def settings():
        import cc_settings
        cc_settings.open_dialog(root, source.get())
    settings_button = ttk.Button(row, text="ComputerCraft settings…", command=settings);settings_button.pack(side="right")
    update_row = ttk.Frame(frame); update_row.pack(fill="x", pady=(0, 8))
    def update_ship():
        """Open a source-based updater without exporting an installation disk first."""
        import updater
        updater.open_dialog(root, project=source.get())
    update_button = ttk.Button(update_row, text="Update existing ship…", command=update_ship)
    update_button.pack(side="left")
    ttk.Label(frame, textvariable=status).pack(anchor="w")
    text = tk.Text(frame, height=10, wrap="word", font=("Segoe UI", 10), state="disabled", background="#f5f7fa", relief="flat")
    text.pack(fill="both", expand=True, pady=(8, 0))
    import queue
    events = queue.Queue();last_result = [None];busy = [False]
    def append(message):
        text.configure(state="normal");text.insert("end", message + "\n");text.see("end");text.configure(state="disabled")
    def worker(selected, destination, include):
        try:events.put(("done", build(selected, destination, include,
                         lambda line: events.put(("log", line)))))
        except Exception as error:events.put(("error", build_error_details(error)))
    # Validate the selected paths and launch a single background build.
    def start():
        if busy[0]:return
        if not source.get().strip():messagebox.showerror("Choose a source", "Select the Amaryllis project folder first.", parent=root);return
        destination = DEFAULT_OUTPUT
        try:
            # Only create the utility's default output folder automatically.
            destination.mkdir(exist_ok=True)
        except OSError as error:messagebox.showerror("Output folder", str(error), parent=root);return
        busy[0] = True;button.configure(state="disabled");open_button.configure(state="disabled");settings_button.configure(state="disabled");update_button.configure(state="disabled");status.set("Reading and validating…")
        text.configure(state="normal");text.delete("1.0", "end");text.configure(state="disabled")
        append("Builder "+VERSION+" | Python "+sys.version.split()[0]+" | "+sys.executable)
        threading.Thread(target=worker, args=(source.get(), str(destination), learning.get()), daemon=True).start()
    # Deliver worker progress and completion results to the Tk interface.
    def poll():
        while not events.empty():
            kind, value = events.get_nowait()
            if kind == "log":append(value)
            elif kind == "done":
                result, report = value;last_result[0] = result;busy[0] = False;button.configure(state="normal");open_button.configure(state="normal");settings_button.configure(state="normal");update_button.configure(state="normal")
                status.set("Installation disk created and verified")
                append(f"Saved to: {result}");append(f"Share: amaryllis-installer.zip | Required disk space: {report['minimumMediaCapacityBytes']:,} bytes")
                revision=report["source"]
                append("Source revision: " + (revision["commit"] or "unversioned source snapshot") +
                       (" (includes uncommitted changes)" if revision["dirty"] else ""))
            else:
                busy[0] = False;button.configure(state="normal");settings_button.configure(state="normal");update_button.configure(state="normal");status.set("Build could not be completed");append(value)
                messagebox.showerror("Build could not be completed", value, parent=root)
        root.after(100, poll)
    button.configure(command=start)
    open_button.configure(command=lambda: os.startfile(str(last_result[0])))
    def close():
        if busy[0] or any(getattr(w, "_amaryllis_update_state", {}).get("busy") for w in root.winfo_children()):
            messagebox.showinfo("Operation in progress", "Let the current operation finish before closing this window.", parent=root);return
        root.destroy()
    root.protocol("WM_DELETE_WINDOW", close);root.after(100, poll);root.mainloop()


# Dispatch command-line export options or open the builder interface.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gui", action="store_true")
    parser.add_argument("--project", type=Path, help="Amaryllis project folder to build")
    parser.add_argument("--output", type=Path, help="Existing parent folder for a new installer")
    parser.add_argument("--without-learning", action="store_true")
    parser.add_argument("--loose", action="store_true", help="Export separate Lua source files instead of runtime bundles")
    args = parser.parse_args()
    if args.gui or (args.project is None and args.output is None):gui();return
    if args.project is None or args.output is None:
        parser.error("Supply both --project and --output")
    path, report = build(args.project, args.output, not args.without_learning, print, bundle=not args.loose)
    print(path);print(json.dumps({"releaseId": report["releaseId"], "mediaBytes": report["mediaBytes"]}))


if __name__ == "__main__":
    try:
        require(sys.version_info >= (3, 11), "Python 3.11 or newer is required.")
        main()
    except Exception as error:
        if "--gui" in sys.argv or len(sys.argv) == 1:
            try:
                import ctypes
                ctypes.windll.user32.MessageBoxW(0, str(error) + "\n\nInstall Python 3.11+ with Tcl/Tk if the window cannot start.", "Amaryllis Disk Builder", 16)
            except Exception:
                pass
        else:
            print("Build failed: " + str(error), file=sys.stderr)
        sys.exit(1)
