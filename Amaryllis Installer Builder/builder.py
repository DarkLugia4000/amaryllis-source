"""Build Amaryllis installation disks from maintained source or an explicit saved-ship export."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
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
LINKS = {"packages/chamber/bl/config.json": ("minecraft:dropper", "minecraft:hopper"),
         "packages/thrust/ls/config.json": ("minecraft:dropper", "minecraft:hopper"),
         "packages/chamber/br/config.json": ("minecraft:hopper", "minecraft:dropper"),
         "packages/thrust/rs/config.json": ("minecraft:hopper", "minecraft:dropper")}


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
    # The disposable role registry supplies the existing collector's source layout.
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
        source = collect(core, include_learning, lambda message: log(message) if not message.startswith("Found ") else None)
    source.update(core=root, computers=root, snapshot=snapshot, mediaSnapshot=None,
                  packageSource={"kind": "project-source"})
    source["provenance"] = project_revision(root, sha(encode(snapshot.inputs)))
    source["notes"] = [note for note in source["notes"] if not note.startswith("Package sources:")]
    source["notes"].append("Programs and defaults were read from the maintained project source.")
    log("Project source: " + str(root))
    log("Source fingerprint: " + source["provenance"]["sourceTreeSHA256"])
    return source


def default_project():
    """Find source beside the utility or at the repository root."""
    return next((path for path in (HOME.parent, HOME) if (path / "source/baseline.json").is_file()), None)


# Resolve the selected save or computer folder to its registered core.
def locate_core(selection):
    selected = Path(selection).expanduser().resolve()
    require(selected.is_dir(), "Choose an existing Minecraft save or core computer folder.")
    if (selected / "fleet.json").is_file() and (selected / "avionics/config.json").is_file():
        return selected, selected.parent
    candidates_root = next((p for p in (selected / "computercraft/computer", selected / "computer", selected)
                            if p.is_dir() and (p.name == "computer" or p == selected / "computercraft/computer")), None)
    require(candidates_root is not None, "No ComputerCraft computer folder was found in this selection.")
    candidates = []
    for p in candidates_root.iterdir():
        if not p.name.isdecimal() or not p.is_dir() or linked(p):
            continue
        if (p / "fleet.json").is_file() and (p / "avionics/config.json").is_file():
            candidates.append(p)
    require(candidates, "No Amaryllis core with fleet.json and avionics/config.json was found.")
    require(len(candidates) == 1, "Several core candidates were found. Select the intended computer folder directly: " +
            ", ".join(p.name for p in candidates))
    return candidates[0].resolve(), candidates_root.resolve()


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


# Validate library paths, checksums and per-role package identities.
def package_catalog(raw):
    require(len(raw) <= 65536, "Package catalog exceeds metadata limits.")
    catalog = decode(raw, "core package catalog")
    require(isinstance(catalog, dict), "Invalid core package catalog.")
    identity = dict(catalog);identity.pop("libraryId", None)
    require(catalog.get("schemaVersion") == 1 and catalog.get("libraryId") == sha(encode(identity)) and
            isinstance(catalog.get("files"), list) and 0 < len(catalog["files"]) <= 256 and
            isinstance(catalog.get("roles"), dict) and set(catalog["roles"]) == set(FOLDERS),
            "Core's package catalog is incomplete or damaged.")
    paths = set()
    for entry in catalog["files"]:
        require(isinstance(entry, dict), "Invalid package catalog entry.")
        path, obj = entry.get("path"), entry.get("object")
        require(isinstance(path, str) and re.fullmatch(r"/packages/[A-Za-z0-9_./-]+", path) and
                all(p not in ("", ".", "..") for p in path.split("/")[1:]) and path not in paths and
                isinstance(obj, str) and re.fullmatch(r"[0-9a-f]{64}", obj) and
                type(entry.get("bytes")) is int and 0 <= entry["bytes"] <= 4_000_000 and
                isinstance(entry.get("adler32"), str) and re.fullmatch(r"[0-9A-F]{8}", entry["adler32"]),
                "Unsafe or duplicate package catalog entry.")
        paths.add(path)
    for role, meta in catalog["roles"].items():
        require(isinstance(meta, dict) and set(meta) == {"packageId", "version"} and
                isinstance(meta["packageId"], str) and 1 <= len(meta["packageId"]) <= 64 and
                type(meta["version"]) is int and 1 <= meta["version"] <= 65535,
                f"Invalid catalog package identity: {role}.")
    return catalog


# Read and verify a selected installer library against core metadata.
def read_package_media(selection, raw):
    root = Path(selection).expanduser().resolve()
    if (root / "media/library.json").is_file():root /= "media"
    snapshot = Snapshot(root)
    require(snapshot.read(root / "library.json") == raw,
            "The selected installer library does not match this core's adopted library.")
    catalog = package_catalog(raw)
    result = {}
    for entry in catalog["files"]:
        data = snapshot.read(root / "objects" / entry["object"])
        require(sha(data) == entry["object"] and len(data) == entry["bytes"] and
                f"{zlib.adler32(data):08X}" == entry["adler32"], "Corrupt disk library object: " + entry["path"])
        result[entry["path"]] = data
    return result, snapshot


def discover_package_media(computers):
    """Bounded search of saved disks and the builder's usual installer locations."""
    roots = [computers.parent / "disk", HOME / "Installers", HOME.parent / "Installers",
             HOME.parent / "Amaryllis Installer Builder" / "Installers"]
    visited = set();budget = 2048
    for root in roots:
        pending = [(root, 0)]
        while pending and budget:
            path, depth = pending.pop();budget -= 1
            if not path.is_dir() or linked(path):continue
            resolved = path.resolve()
            if resolved in visited:continue
            visited.add(resolved)
            if (path / "library.json").is_file():yield path
            if depth >= 3:continue
            try:
                children = sorted(path.iterdir(), key=lambda p:p.name, reverse=True)
            except OSError:continue
            for child in children:
                if len(pending) >= budget:break
                if not child.name.startswith(".") and child.name not in ("objects", "Backups", "windows-update", "windows-settings"):
                    pending.append((child, depth + 1))


# Recover editable auxiliary sources from registered installed computers.
def recover_package_library(payload, snap, registry, core, computers, loader, selection, log):
    raw = payload.get("/installer/library.json")
    require(isinstance(raw, bytes), "Core's package catalog is missing.")
    catalog = package_catalog(raw)
    if selection:
        result, snapshot = read_package_media(selection, raw)
        log("Using verified package-library override: " + str(snapshot.root))
        return result, snapshot, {"kind": "media-override", "path": str(snapshot.root)}

    # Recover the registered role payload using its trusted package metadata.
    def installed(role, expected, entries):
        record = registry[role];computer_id = record.get("id")
        require(type(computer_id) is int, "No installed computer is registered for " + role)
        folder = computers / str(computer_id)
        cfg = decode(snap.read(folder / "avionics/config.json"), role + " installed config")
        require(isinstance(cfg, dict), "Invalid installed configuration: " + role)
        receipt = cfg.get("install", {})
        require(isinstance(receipt, dict) and receipt.get("protocol") == "amaryllis.install.v1" and
                receipt.get("role") == role and cfg.get("role") == role and
                receipt.get("computerID") == computer_id and receipt.get("coreID") == int(core.name) and
                receipt.get("label") == record["label"] and
                all(receipt.get(k) == expected[k] for k in ("packageId", "version")),
                "Installed role, ID or package receipt does not match core: " + role)
        status = decode(snap.read(folder / "installer/status.json"), role + " installer status")
        fields = {"role":"installedRole", "packageId":"installedPackageId", "version":"installedVersion",
                  "installID":"installedInstallID", "manifestChecksum":"installedManifestChecksum",
                  "computerID":"installedComputerID", "coreID":"installedCoreID", "label":"installedLabel",
                  "clientSession":"installedClientSession", "serverSession":"installedServerSession",
                  "coreSession":"installedCoreSession"}
        require(isinstance(status, dict) and status.get("hasInstalled") is True and status.get("recoveryRequired") is False and
                status.get("state") not in ("committing", "recovery_required") and
                all(status.get(field) == receipt.get(key) and key in receipt for key,field in fields.items()),
                "Installed package is unfinished or its status conflicts with its receipt: " + role)
        checksum_rows = b"".join(p.encode() + b"\0" + str(e["bytes"]).encode() + b"\0" + e["adler32"].encode() + b"\n"
                                 for p,e in zip(bundling.PATHS, entries))
        require(str(receipt.get("manifestChecksum", "")).upper() == f"{zlib.adler32(checksum_rows):08X}",
                "Installed manifest receipt does not match core's package catalog: " + role)
        alias = snap.read(folder / "avionics/common/console.lua")
        require(sha(alias) == entries[2]["object"], "Installed console entry does not match core's catalog: " + role)
        return snap.read(folder / "avionics/main.lua")

    legacy_used = [False]
    # Load verified compatibility metadata for older installed packages.
    def legacy_metadata():
        hashes = decode((HOME / "assets/asset-hashes.json").read_bytes(), "builder assets")
        metadata = (HOME / "assets/legacy-package-metadata.json").read_bytes()
        require(sha(metadata) == hashes.get("legacy-package-metadata.json"), "Builder recovery metadata is damaged.")
        legacy = decode(metadata, "legacy package metadata")
        require(legacy.get("schemaVersion") == 1 and isinstance(legacy.get("objects"), dict), "Invalid recovery metadata.")
        legacy_used[0] = True
        return legacy["objects"]

    try:
        result = bundling.recover_library(catalog, FOLDERS, loader, installed, legacy_metadata)
        log("Recovered and verified all 14 auxiliary packages from the installed ship; previous installer media is not required.")
        return result, None, {"kind": "installed-fleet", "packages": len(FOLDERS),
                              "metadata": "builder-legacy-json" if legacy_used[0] else "embedded-in-bundles"}
    except (BuildError, ValueError, KeyError, TypeError, OSError) as error:
        recovery_error = str(error)
    for candidate in discover_package_media(computers):
        try:
            result, snapshot = read_package_media(candidate, raw)
        except (BuildError, ValueError, OSError):continue
        log("Automatically found and verified matching package media: " + str(snapshot.root))
        return result, snapshot, {"kind": "auto-media", "path": str(snapshot.root)}
    raise BuildError("Cannot recover this ship's complete package sources: " + recovery_error +
                     ". No matching media was found automatically. Restore the affected computer from backup, "
                     "or select matching installer media in the optional Package library override.")


def disk_server(server):
    """Add media availability to the existing transport's authority checkpoints."""
    # Already exported disk servers are rebuilt from their transport source below.
    text = server.decode("utf-8")
    if text.startswith("-- Removable package media v1\n"):
        return server
    replacements = [
        ('    local bundleCache=injected.bundleCache',
         '    local media\n    if not injected.fs then\n'
         '        media=assert(loadfile("/installer/media.lua",nil,_ENV))().new(deps.fs,peripheral,disk,textutils,sleep)\n'
         '        deps.fs=media.fs\n    end\n    local bundleCache=injected.bundleCache'),
        ('        else\n        modemCount = openModems(deps)',
         '        elseif media and not media:refresh() then\n'
         '            setState(deps,status,"waiting_for_media",media.issue)\n            deps.sleep(2)\n'
         '        else\n        modemCount = openModems(deps)'),
        ('or status.state=="paused" then setState', 'or status.state=="paused" or status.state=="waiting_for_media" then setState'),
        ('                            targetConfig.authorityCheck = function()',
         '                            local mediaGeneration=media and media.generation\n'
         '                            targetConfig.authorityCheck = function()\n'
         '                                if media and not media:valid(mediaGeneration) then return false,"installer disk removed or changed; transfer retired" end'),
        ('                                if pauseRequested(deps) then return false,"installer paused; package verification retired" end',
         '                                if media and not media:valid(mediaGeneration) then return false,"installer disk removed or changed; package verification retired" end\n'
         '                                if pauseRequested(deps) then return false,"installer paused; package verification retired" end'),
    ]
    for old, new in replacements:
        require(old in text, "Unsupported installer transport. Update the builder for this server version.")
        text = text.replace(old, new)
    return ("-- Removable package media v1\n" + text).encode()


def lift_recovery_overlays(payload):
    """Recover communication/lease loss using verified retained lift intent."""
    path = "/avionics/flight.lua"
    flight = payload[path].decode("utf-8")
    marker = "-- Recoverable lift handshake v1"
    if marker in flight:
        return
    def change(old, new, label):
        nonlocal flight
        require(flight.count(old) == 1,
                f"Unsupported {label} for lift recovery. Update the builder for this source version.")
        flight = flight.replace(old, new, 1)
    change('''        local ok,seq=io:sendSystemsCommand(q,targets,s.batchStage)''',
        '''        local commandStage=s.telemetryRecovery and s.recoveryStages and s.recoveryStages[q] or s.batchStage
        local ok,seq=io:sendSystemsCommand(q,targets,commandStage)''', "lift batch sender")
    change('''s.pending[q]={q=q,seq=seq,targets=targets,stage=s.batchStage,sentAt=now,boot=s.boots[q]}''',
        '''s.pending[q]={q=q,seq=seq,targets=targets,stage=commandStage,sentAt=now,boot=s.boots[q]}''', "lift pending stage")
    change('''                local expectedStage=stage''',
        '''                local expectedStage=pending.stage or stage''', "recovery stage readback")
    change('''                if stage=="probe" and not leaseExpired then''',
        '''                if expectedStage=="probe" and not leaseExpired then''', "probe activation readback")
    change('''    local function sendRecoveryBatch(stage,maps,coarse)
        if stage=="probe" then
            maps=recoveryProbeMaps(io,maps)
            recovery.probeTargets=copyMaps(maps)
        end''',
        '''    local function sendRecoveryBatch(stage,maps,coarse)
        s.recoveryStages=nil
        if stage=="probe" then
            maps=recoveryProbeMaps(io,maps)
            s.recoveryStages={}
            for _,q in ipairs(QUADS) do
                local node=io.nodes[q]
                -- A valid control owner cannot accept a probe. Keep its exact
                -- observed map and renew control while expired peers re-probe.
                if node.systemsStage=="control" and node.systemsProbeReady==true then
                    local actual,reason=TelemetryRecovery.readTargetMap(node,
                        recovery.targetMaps and recovery.targetMaps[q],s.providerRoles[q])
                    if not actual then return wait(q.." "..tostring(reason),false) end
                    maps[q]=actual;s.recoveryStages[q]="control"
                end
            end
            recovery.probeTargets=copyMaps(maps)
        end''', "mixed chamber recovery")
    change('''            if stage=="control" and node.systemsStage==nil and node.systemsProbeReady~=true then''',
        '''            if node.systemsStage==nil and node.systemsProbeReady~=true and
                (stage=="control" or (pending and now-pending.sentAt>=SYSTEMS_ACK_TIMEOUT_SECONDS)) then''',
        "expired recovery probe")
    change('''    s.lastSystemsUpdateAt=now
    self:observeSystemsDynamics(io,s,now)''',
        '''    s.lastSystemsUpdateAt=now
    -- A fresh node may have lost its renewable lease before the command's
    -- rejection arrives. Re-probe using the retained run instead of waiting
    -- for a matching rejected sequence or letting an ACK timeout abort it.
    if s.batchStage=="control" or s.phase=="READY" or s.phase=="BUILDING_LIFT" then
        for _,q in ipairs(QUADS) do
            local node=io.nodes[q]
            if node.systemsStage==nil and node.systemsProbeReady~=true then
                TelemetryRecovery.suspend(self,s,now,q.." LIFT CONTROL LEASE LOST")
                self:updateSystemsRecovery(io,now,s);return
            end
        end
    end
    self:observeSystemsDynamics(io,s,now)''', "normal control lease loss")
    change('''                    self:stopSystems(io,q.." SYSTEMS COMMAND ACK TIMEOUT",now);return''',
        '''                    TelemetryRecovery.suspend(self,s,now,q.." SYSTEMS COMMAND ACK TIMEOUT")
                    self:updateSystemsRecovery(io,now,s);return''', "normal lift acknowledgement timeout")
    payload[path] = (marker + "\n" + flight).encode("utf-8")


def vessel_recovery_overlays(payload):
    """Separate unavailable telemetry from fresh, confirmed vessel changes."""
    flight_path = "/avionics/flight.lua"
    recovery_path = "/avionics/telemetry_recovery.lua"
    flight = payload[flight_path].decode("utf-8")
    recovery = payload[recovery_path].decode("utf-8")
    marker = "-- Recoverable vessel telemetry v1"
    if marker in flight and marker in recovery:
        return
    require(marker not in flight and marker not in recovery,
            "Incomplete vessel recovery patch. Restore matching core files before export.")
    def change(text, old, new, label):
        require(text.count(old) == 1,
                f"Unsupported {label} for vessel recovery. Update the builder for this source version.")
        return text.replace(old, new, 1)
    recovery = change(recovery, 'function Recovery.nodeBootState(io,s,q,now,flight)',
        '''-- An unavailable UUID is not evidence of another vessel. Do not
-- authorize writes until a fresh complete sample confirms the retained UUID.
function Recovery.vesselState(io,s,now)
    local vessel=io and io.vessel
    local stale=io and io.config and io.config.network and io.config.network.sensor_stale_seconds
    if not s or type(s.uuid)~="string" or #s.uuid==0 then
        return "terminal","RETAINED VESSEL IDENTITY UNAVAILABLE"
    end
    if type(vessel)~="table" or not closeEnoughFresh(now,vessel.at,stale) then
        return "wait","VESSEL TELEMETRY STALE"
    end
    if type(vessel.uuid)~="string" or #vessel.uuid==0 then
        return "wait","VESSEL IDENTITY UNAVAILABLE"
    end
    if vessel.valid~=true then return "wait","VESSEL TELEMETRY INCOMPLETE" end
    if vessel.uuid~=s.uuid then return "terminal","VESSEL IDENTITY CHANGED" end
    if not finite(vessel.altitude) or not finite(vessel.verticalSpeed) then
        return "wait","VESSEL TELEMETRY INCOMPLETE"
    end
    return "trusted"
end

function Recovery.nodeBootState(io,s,q,now,flight)''', "vessel evidence classifier")
    recovery = change(recovery, '''    local vessel=io.vessel or {}
    local stale=io.config.network and io.config.network.sensor_stale_seconds
    if vessel.uuid~=s.uuid then return "terminal","VESSEL IDENTITY CHANGED" end
    if vessel.valid~=true or not closeEnoughFresh(now,vessel.at,stale) or
        not finite(vessel.altitude) or not finite(vessel.verticalSpeed) then
        return "wait","VESSEL SENSOR STALE / IDENTITY CHANGED"
    end''',
        '''    local vesselState,vesselReason=Recovery.vesselState(io,s,now)
    if vesselState~="trusted" then return vesselState,vesselReason end''', "rebound vessel validation")
    recovery = change(recovery, '''    if reason=="VESSEL SENSOR STALE / IDENTITY CHANGED" then
        if not s or vessel.uuid~=s.uuid then return false end
        local stale=io and io.config and io.config.network and io.config.network.sensor_stale_seconds
        return vessel.valid~=true or not closeEnoughFresh(now,vessel.at,stale) or
            not finite(vessel.altitude) or not finite(vessel.verticalSpeed)
    end''',
        '''    if reason=="VESSEL SENSOR STALE / IDENTITY CHANGED" or reason=="VESSEL TELEMETRY STALE" or
        reason=="VESSEL IDENTITY UNAVAILABLE" or reason=="VESSEL TELEMETRY INCOMPLETE" then
        return Recovery.vesselState(io,s,now)=="wait"
    end''', "transient vessel classification")
    flight = change(flight, '''    if not v or v.valid~=true or v.uuid~=s.uuid or not freshAt(now,v.at,stale) or
        not finite(v.altitude) or not finite(v.verticalSpeed) then return false,"VESSEL SENSOR STALE / IDENTITY CHANGED" end''',
        '''    local vesselState,vesselReason=TelemetryRecovery.vesselState(io,s,now)
    if vesselState~="trusted" then return false,vesselReason end''', "flight vessel guard")
    flight = change(flight, '''    local maps,mapReason,coarse=TelemetryRecovery.reconcileTargetMaps(s,io.nodes,trustedRebinds)
    if not maps then return nil,mapReason end''',
        '''    -- A command may have applied to only some providers before the
    -- abort. Recover core's retained intent, not an unexplained observed map.
    -- The guards above verify identity/bindings; this helper checks the exact
    -- provider allowlist and target bounds before recovery re-applies it.
    local maps,mapReason,coarse=TelemetryRecovery.authoritativeTargetMaps(s,io.nodes)
    if not maps then return nil,mapReason end''', "retained abort target recovery")
    payload[flight_path] = (marker+"\n"+flight).encode("utf-8")
    payload[recovery_path] = (marker+"\n"+recovery).encode("utf-8")


def identity_overlays(payload, assets):
    """Advisory receiver-side monitoring, without touching control decisions."""
    payload["/avionics/identity_watch.lua"] = assets["identity-watch.lua"]
    io = payload["/avionics/io.lua"].decode("utf-8")
    main = payload["/avionics/main.lua"].decode("utf-8")
    ui = payload["/packages/navigation/ui.lua"].decode("utf-8")
    def change(text, old, new, label):
        require(text.count(old) == 1, f"Unsupported {label} for identity warnings. Update the builder for this source version.")
        return text.replace(old, new, 1)
    if "-- Identity conflict advisory v1" not in io:
        io = '-- Identity conflict advisory v1\nlocal IdentityWatch=require("avionics.identity_watch")\n' + io
        io = change(io, '    self.session = dependencies.session or newSession(id or self.fleet.coreID,self.os)',
            '    self.identityWatch=IdentityWatch.new()\n'
            '    local epochOK,epochMs=pcall(function()return self.os.epoch("utc")end)\n'
            '    self.identityStartedEpochMs=epochOK and epochMs or nil\n'
            '    self.session = dependencies.session or newSession(id or self.fleet.coreID,self.os)', 'core identity initialization')
        io = change(io, '''function IO:registryPacket()
    return {v=1,kind="fleet_registry",coreID=self.config.computer_id,session=self.session,
        computers=Fleet.clone(self.computers or {})}
end''', '''function IO:registryPacket()
    self.identityRegistrySeq=((self.identityRegistrySeq or 0)%2147483647)+1
    local ok,epochMs=pcall(function()return self.os.epoch("utc")end)
    local uuid=self.vessel and self.vessel.uuid
    return {v=1,kind="fleet_registry",coreID=self.config.computer_id,session=self.session,
        identitySeq=self.identityRegistrySeq,identityEpochMs=ok and epochMs or nil,
        identityVesselUUID=boundedString(uuid,128) and uuid or nil,
        computers=Fleet.clone(self.computers or {})}
end

function IO:observeIdentityClaim(sender,message,protocol,now,epochMs)
    if self.identityWatch then return self.identityWatch:observe(self,sender,message,protocol,now,epochMs) end
end''', 'registry publication')
        io = change(io, '        targets = {}, anchor = "OFF", ap = "UNAVAILABLE", throttleApplied = nil, faults = {},',
            '        targets = {}, anchor = "OFF", ap = "UNAVAILABLE", throttleApplied = nil, faults = {},\n'
            '        identityConflict=self.identityWatch and self.identityWatch:snapshot(now) or {active=false},', 'core status snapshot')
        io = change(io, '    for role,report in pairs(self.roleReports or {}) do',
            '    self:logState("identityConflict",state.identityConflict.active and state.identityConflict.text or nil)\n'
            '    for role,report in pairs(self.roleReports or {}) do', 'identity warning log')
    if "-- Identity conflict receiver v1" not in main:
        main = change(main,
            '            inbox:push(from,payload,channel,io:nowSeconds(),os.epoch("utc"))',
            '            -- Identity conflict receiver v1: observe before routine coalescing; never yield.\n'
            '            local receivedAt,receivedEpoch=io:nowSeconds(),os.epoch("utc")\n'
            '            pcall(io.observeIdentityClaim,io,from,payload,channel,receivedAt,receivedEpoch)\n'
            '            inbox:push(from,payload,channel,receivedAt,receivedEpoch)', 'core radio receiver')
        main = change(main, '    local vessel, rows = snapshot.vessel or {}, {}',
            '    local vessel, rows = snapshot.vessel or {}, {}\n'
            '    local conflict=snapshot.identityConflict or {}\n'
            '    if conflict.active then\n'
            '        rows[#rows+1]="IDENTITY WARNING: "..clean(conflict.text)\n'
            '        rows[#rows+1]=clean(conflict.detail)\n'
            '        for _,alert in ipairs(conflict.alerts or {}) do\n'
            '            rows[#rows+1]="#"..tostring(alert.id).." "..clean(alert.role)..": "..clean(alert.detail)\n'
            '            if alert.localIdentity then rows[#rows+1]="  Local: "..clean(alert.localIdentity) end\n'
            '            for _,claim in ipairs(alert.claims or {}) do\n'
            '                rows[#rows+1]="  Seen: "..clean(claim.identity).." / seq "..clean(claim.sequence)\n'
            '            end\n'
            '        end\n'
            '    end', 'core monitor')
    if "-- Identity conflict bridge warning v1" not in ui:
        ui = change(ui, 'local function firstThrustIssue(snapshot, live)\n    if not live then return "THRUST STATUS STALE" end',
            'local function firstThrustIssue(snapshot, live)\n    if not live then return "THRUST STATUS STALE" end\n'
            '    -- Identity conflict bridge warning v1\n'
            '    local conflict=snapshot.identityConflict or {}\n'
            '    if conflict.active then return conflict.text end', 'bridge status line')
        ui = change(ui, '        if assembly then offer(assembly.reason or ("VESSEL "..tostring(assembly.state)),"red") end',
            '        if assembly then offer(assembly.reason or ("VESSEL "..tostring(assembly.state)),"red") end\n'
            '        local conflict=snapshot.identityConflict or {}\n'
            '        if live and conflict.active then offer(conflict.text,"red") end', 'bridge flight warning')
        ui = change(ui, '    if #faults > 0 then\n        faultText, faultTone = clampText(faults[1], surface.width - 4), "red"',
            '    local conflict=snapshot.identityConflict or {}\n'
            '    if live and conflict.active then\n'
            '        faultText,faultTone=clampText(conflict.text,surface.width-4),"red"\n'
            '    elseif #faults > 0 then\n        faultText, faultTone = clampText(faults[1], surface.width - 4), "red"', 'bridge ship warning')
    payload["/avionics/io.lua"] = io.encode()
    payload["/avionics/main.lua"] = main.encode()
    payload["/packages/navigation/ui.lua"] = ui.encode()



def control_persistence_overlays(payload):
    """Retain explicit heading/throttle selections across automatic handovers."""
    # Apply a supported persistent-selection revision or accept its existing result.
    def change(path, old, new, label, count=1):
        text=payload[path].decode("utf-8")
        if new in text:
            require(text.count(new)==count and text.count(old)==count*new.count(old),
                    "Partial persistent-mode overlay: "+label)
            return
        require(text.count(old)==count,"Unsupported persistent-mode source: "+label)
        payload[path]=text.replace(old,new).encode("utf-8")
    change("/avionics/autopilot.lua",
           '        controls.modes.throttle="MANUAL";controls.modes.heading="MANUAL"',
           '''        -- Keep the pilot's selections; only live authority is handed back.
        controls.requireNeutral=true;controls.waitThrottle=true;controls.waitHeading=true''',
           "AP handover")
    change("/avionics/anchor.lua",
           '        controls.modes.throttle="DIRECT";controls.request=0',
           '''        -- Preserve the pilot's selected throttle mode and target.
        controls.request=0;controls.yaw=0;controls.requireNeutral=true;controls.waitHeading=true''',
           "anchor handover")
    change("/avionics/controls.lua",
           '        io.autopilot:cancel(io,self,"PILOT DISENGAGED AUTOPILOT; MANUAL CONTROL")\n        anchorActive=io.positionAnchor and io.positionAnchor.active',
           '''        io.autopilot:cancel(io,self,"PILOT DISENGAGED AUTOPILOT; SELECTED MODES RETAINED")
        return -- Do not consume the disconnect sample again as a manual command.''',
           "disconnect neutral boundary")
    change("/avionics/flight.lua",
           '        if ok and io.controlPresets then io.controlPresets:cancelRestore() end',
           '''        if ok and io.controlPresets then
            io.controlPresets:cancelRestore()
            -- Persist the explicit selection before its acknowledgement.
            io.controlPresets:update(io,self,now)
        end''',
           "durable mode acknowledgement",2)
    for path in ("/avionics/flight.lua","/avionics/autopilot.lua","/avionics/remote_ap.lua"):
        text=payload[path].decode("utf-8").replace("MANUAL CONTROL","SELECTED MODES RETAINED")
        payload[path]=text.encode("utf-8")
    for path in ("/avionics/anchor.lua","/avionics/flight.lua"):
        text=payload[path].decode("utf-8").replace("DIRECT THROTTLE REQUIRES NEUTRAL","SELECTED MODE RETAINED; NEUTRAL REQUIRED")
        text=text.replace("-- Release means a neutral handover, never restoring a nonzero SEL\n        -- target or immediately applying a lever held during anchoring.",
                          "-- Release preserves selection and requires a neutral-input handover.")
        payload[path]=text.encode("utf-8")
    path="/avionics/controls.lua"
    text=payload[path].decode("utf-8").replace("-- interpreted and nothing accumulates. clear() drops SEL modes and",
                                            "-- interpreted and nothing accumulates. clear() retains selections and")
    payload[path]=text.encode("utf-8")

# Validate source files, apply guarded revisions and collect portable payloads.
def collect(selection, include_learning=True, log=lambda s: None, library=None):
    core, computers = locate_core(selection)
    require(core.name.isdecimal(), "The selected core folder must be its numeric ComputerCraft ID folder.")
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
    log(f"Found {registry['core']['label']} (computer #{core.name}).")
    loader = (HOME / "assets/runtime-loader.lua").read_bytes()
    asset_hashes = decode((HOME / "assets/asset-hashes.json").read_bytes(), "builder assets")
    require(sha(loader) == asset_hashes.get("runtime-loader.lua"), "Builder runtime loader changed or is damaged.")
    payload = {}
    for directory in ("avionics", "packages", "installer"):
        root = core / directory
        if directory == "packages" and not root.exists():
            continue
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
                    if relative.startswith("packages/") and name == "config.json":
                        require(not any(k in value for k in ("install", "coreId", "computerId", "computer_id")),
                                f"Package config contains installation-specific identity: {relative}. Export clean core package sources.")
                    if relative in LINKS:
                        link = value["primaryDirection"]["link"]
                        link["itemID1"], link["itemID2"] = LINKS[relative]
                        data = encode(value)
                payload["/" + relative] = data
    payload["/startup.lua"] = snap.read(core / "startup.lua")
    try:
        payload = bundling.expand(payload, loader)
        if "/installer/server.lua" in payload:
            payload["/installer/server.lua"] = bundling.server_source(payload["/installer/server.lua"])
    except (ValueError, KeyError, TypeError) as error:
        raise BuildError("Cannot recover editable core source from bundle: " + str(error)) from error
    media_snapshot = None
    package_source = {"kind": "core-library"}
    if not any(p.startswith("/packages/") for p in payload):
        recovered, media_snapshot, package_source = recover_package_library(
            payload, snap, registry, core, computers, loader, library, log)
        payload.update(recovered)
    try:
        library_files = {p: d for p, d in payload.items() if p.startswith("/packages/")}
        if library_files:
            recovered = bundling.library_source(library_files, FOLDERS, loader)
            payload = {p: d for p, d in payload.items() if not p.startswith("/packages/")}
            payload.update(recovered)
    except (ValueError, KeyError, TypeError) as error:
        raise BuildError("Cannot recover editable auxiliary source from bundle: " + str(error)) from error
    information.strip_notes(payload)
    source_notes.revise(payload, reverse=True)
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
    for name in ("setup.lua", "startup.lua", "auxiliary-startup.lua", "bootstrap-launcher.lua", "installer.lua", "core-progress.lua", "core-media.lua", "identity-watch.lua", "runtime-loader.lua", "systems-menu.lua", "panel-console.lua", "remote-panel.lua"):
        data = (HOME / "assets" / name).read_bytes()
        require(sha(data) == assets_manifest.get(name), f"Builder support file changed or is damaged: {name}. Restore the utility's assets folder.")
        assets[name] = data
    server = payload["/installer/server.lua"]
    require(b'"/installer/progress.lua"' in server and b"deps.progress:setFleet(fleet,ROLE_FILES)" in server and
            b"deps.progress:update(status)" in server and b"deps.progress:draw(status)" in server,
            "Core installer does not expose the supported progress interface. Update the builder for this installer version.")
    payload["/installer/progress.lua"] = assets["core-progress.lua"]
    payload["/installer/server.lua"] = disk_server(server)
    payload["/installer/media.lua"] = assets["core-media.lua"]
    lift_recovery_overlays(payload)
    vessel_recovery_overlays(payload)
    identity_overlays(payload, assets)
    if presentation.apply(payload, assets["systems-menu.lua"], require):
        manifest_path="/packages/navigation/manifest.json"
        nav_manifest=decode(payload[manifest_path],"bridge package manifest")
        require(nav_manifest["version"]<65535,"Bridge package version cannot be advanced for the Systems menu.")
        nav_manifest["version"]+=1
        payload[manifest_path]=encode(nav_manifest)
        versions["navigator"]=nav_manifest["version"]
    information.apply(payload)
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
    presentation.apply_remote_transient(payload, require)
    presentation.apply_remote_reads(payload, require)
    control_persistence_overlays(payload)
    # Keep the core header consistent with retained-intent automatic resumption.
    payload["/avionics/main.lua"] = payload["/avionics/main.lua"].replace(
        b'-- authority. Only an explicitly saved, one-shot systems restart resumes it.',
        b'-- authority. Retained running intent can resume after validation; coordinated\n-- restarts also restore their explicit one-shot checkpoint.')
    startup = payload["/startup.lua"]
    require(b'/packages/common/console.lua' in startup or b'/avionics/common/console.lua' in startup, "Unsupported core startup console path.")
    payload["/startup.lua"] = startup.replace(b'/packages/common/console.lua', b'/avionics/common/console.lua')
    io = payload["/avionics/io.lua"]
    # Correct legacy assembly comments in exported IO without changing Lua statements.
    io = io.replace(b'--   missing/failed/stale   UNKNOWN, gate stays closed',
                    b'--   missing/failed/stale   ASSEMBLED but unverified, gate stays open')
    io = io.replace(b'-- that answer only expires after network.sensor_stale_seconds without\n-- another definite read. This stops a single bad read flickering the gate.',
                    b'-- Fresh Sable association takes precedence over a fresh assembler result.\n-- Unresolved verification keeps the gate open and warns after five minutes.\n-- Applied lift settings remain retained through verification uncertainty.')
    io = io.replace(b'    -- Assembly uncertainty has three six-second retry windows. This is\n    -- independent of ordinary sensor freshness; explicit false never waits.',
                    b'    -- Three six-second windows describe assembly verification age only.\n    -- Expiry leaves the gate open but unverified; it does not stop systems.\n    -- Explicit false blocks immediately until a later true reading.')
    if b'-- Disk-library role metadata' not in io:
        old = b'    for role,path in pairs(ROLE_MANIFESTS) do\n        local manifest\n'
        require(old in io and b'        if manifest then self.expectedPackages[role]' in io,
                "Unsupported core role-version lookup. Update the builder for this IO version.")
        start = io.index(old)
        end = io.index(b'        if manifest then self.expectedPackages[role]', start)
        io = io[:start] + b'''    -- Disk-library role metadata remains local when media is removed.
    local catalog
    if self.fs and self.json then
        local ok,handle=pcall(self.fs.open,"/installer/library.json","r")
        if not ok or not handle then ok,handle=pcall(self.fs.open,"/installer/library.json.amaryllis-backup","r") end
        if ok and handle then
            local readOK,raw=pcall(handle.readAll);pcall(handle.close)
            if readOK and type(raw)=="string" and #raw<=65536 then
                local decoded,value=pcall(self.json.unserializeJSON,raw)
                if decoded and type(value)=="table" and value.schemaVersion==1 and type(value.roles)=="table" then catalog=value end
            end
        end
    end
    for role,path in pairs(ROLE_MANIFESTS) do
        local manifest=catalog and catalog.roles[role]
        if type(manifest)~="table" or not boundedString(manifest.packageId,64) or not integer(manifest.version,1,65535) then manifest=nil end
''' + io[end:]
        io = re.sub(rb'"/packages/[^"\r\n]+/manifest.json"', b'"/installer/library.json"', io)
    payload["/avionics/io.lua"] = io
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
    notes.append("Package sources: " + package_source["kind"] + ".")
    notes.append("Auxiliary package programs remain on removable media; core retains its console and trusted version metadata.")
    notes.append("Included Systems Options dropdown, retained lift-kill confirmation/disarm controls and approved bridge wording changes.")
    notes.append("Included advisory duplicate-ID detection on existing core/session and role-boot traffic; flight authority is unchanged.")
    notes.append("Included automatic retained-lift recovery for expired probe/control leases and missed command acknowledgements.")
    notes.append("Missing/stale vessel identity now waits for fresh validation; abort recovery restores core's retained target intent after hardware checks.")
    nav_id = registry["navigator"].get("id")
    installed_client = computers / str(nav_id) / "installer.lua" if nav_id is not None else None
    if installed_client and installed_client.is_file():
        client = snap.read(installed_client)
        require(b"amaryllis.install.v1" in client, "Navigator's bootstrap installer is not recognized.")
        assets["installer.lua"] = client
        notes.append("Auxiliary bootstrap copied from the registered navigator.")
    else:
        notes.append("Navigator bootstrap was unavailable; included the utility's tested compatible bootstrap.")
    log(f"Validated {len(payload)} core files and {len(versions)} auxiliary packages.")
    return {"core": core, "computers": computers, "snapshot": snap, "payload": payload, "state": state_payload,
            "calibration": calibration, "assets": assets, "roles": {r: {"label": v["label"]} for r, v in registry.items()},
            "versions": versions, "notes": notes, "library": package_library, "catalog": catalog,
            "mediaSnapshot": media_snapshot, "packageSource": package_source,
            "sourceDocumentation": core_notes + library_notes}


# Describe the generated media, setup procedure and update helper.
def installer_readme(manifest, report):
    state = report.get("source", {}).get("dirty")
    edits = "yes" if state is True else "no" if state is False else "unknown"
    return (f"# Amaryllis installer {manifest['releaseId']}\n\n"
            + ("Software source: maintained project\n"
               f"Revision: {report['source']['commit'] or 'unversioned source snapshot'}\n"
               f"Includes uncommitted changes: {edits}\n"
               f"Source fingerprint: {report['source']['sourceTreeSHA256']}\n\n" if report.get("source") else "Software source: saved-ship export\n\n") +
            "Copy the contents of media/ to an empty, writable ComputerCraft installer disk.\n"
            f"Allow at least {report['minimumMediaCapacityBytes']:,} bytes of disk capacity and 4,000,000 bytes per computer.\n\n"
            "To prepare a Windows Minecraft instance, open windows-settings/Configure ComputerCraft.cmd.\n"
            "It previews capacity/thread edits, requires Minecraft/server closed, and backs up the selected\n"
            "computercraft-server.toml. These Windows helpers do not go onto the in-game disk.\n\n"
            "For an existing ship, save and fully close Minecraft. Run windows-update/Update Amaryllis.cmd,\n"
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
               "separate. Media remains useful for installation and repair; complete ships can rebuild without it.\n\n" if report.get("bundling") else "") +
            "Watch core's Installation page for the package roster, current file, transfer percentage,\n"
            "verification and faults. It announces completion after all 14 wireless packages verify.\n"
            "The state reader uses direct disk setup; check its wired link separately.\n\n"
            "Auxiliary programs stay on this removable disk, not on core. Remove it after\n"
            "installation; flight keeps working and Installation waits for media. Insert\n"
            "it again for auxiliary repair. Choose Adopt auxiliary package library in Setup,\n"
            "with core stopped; it verifies all objects and requires the same core runtime.\n"
            "Use the Windows updater for core/state replacement and loose-file migration.\n"
            "Keep this disk or media for installation and repair. Complete supported ships can rebuild without it.\n\n"
            "If included, saved hover/level defaults seed missing core learning files only.\n"
            "Different loads or balloon layouts may need further settling and learning.\n\n"
            "This export contains saved source files. File/package checks do not establish\n"
            "which code was running in-game, compile Lua, or certify flight behavior.\n")


# Export, verify and package a new installer in a unique output folder.
def build(selection, output_parent, include_learning=True, log=lambda s: None, library=None, bundle=True, *, project_source=False):
    source = collect_project(selection, include_learning, log) if project_source else collect(selection, include_learning, log, library)
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
        # Fresh receivers need the bundled-layout allowlist, even when the source
        # ship still has an older installed bootstrap client.
        source["assets"] = dict(source["assets"])
        source["assets"]["installer.lua"] = (HOME / "assets/installer.lua").read_bytes()
    # Document the final commissioning copies after bootstrap selection.
    exported_assets={"/disk/"+name:source["assets"][name] for name in
                     ("setup.lua","startup.lua","installer.lua","bootstrap-launcher.lua","auxiliary-startup.lua")}
    information.strip_notes(exported_assets)
    installer_notes,_=source_notes.annotate(exported_assets)
    source["assets"]=dict(source["assets"])
    for path,data in exported_assets.items():source["assets"][path.removeprefix("/disk/")]=data
    source["sourceDocumentation"].extend(installer_notes)
    parent = Path(output_parent).expanduser().resolve()
    require(parent.is_dir(), "Choose an existing output folder.")
    # Protect the entire selected save, not just its core subfolder.
    if not project_source:
        protected = source["computers"].parent.parent
        require(not parent.is_relative_to(protected), "Output must be outside the selected Minecraft save.")
    else:
        require(not parent.is_relative_to(source["core"] / "source"), "Output must be outside editable source folders.")
    require(not source["mediaSnapshot"] or not parent.is_relative_to(source["mediaSnapshot"].root),
            "Output must be outside the selected package media folder.")
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
        if project_source:
            manifest["source"] = source["provenance"]
        manifest["releaseId"] = "amaryllis-" + sha(json.dumps(manifest, sort_keys=True).encode())[:12]
        (media / "release.json").write_bytes(encode(manifest))
        (media / "library.json").write_bytes(encode(source["catalog"]))
        for name in ("setup.lua", "startup.lua"):
            (media / name).write_bytes(source["assets"][name])
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
                  "sourceFiles": source["snapshot"].inputs if project_source else {
                      str(p.relative_to(source["computers"])): sha(d) for p, d in source["snapshot"].files.items()},
                  "builderOverrides": {path: sha(source["payload"][path]) for path in
                      ("/installer/progress.lua", "/installer/server.lua", "/installer/media.lua", "/avionics/io.lua",
                       "/avionics/main.lua", "/avionics/identity_watch.lua", "/startup.lua") if path in source["payload"]},
                  "bundling": source.get("bundleCounts"),
                  "validation": {"objects": True, "sourceStable": True, "archive": True,
                                 "luaCompiled": False, "inGameAcceptance": False}}
        if project_source:
            report["source"] = source["provenance"]
        if not bundle:
            report["builderOverrides"]["/packages/navigation/ui.lua"] = sha(source["library"]["/packages/navigation/ui.lua"])
        (staging / "README.md").write_text(installer_readme(manifest, report), encoding="utf-8")
        helper = staging / "windows-settings"
        helper.mkdir()
        (helper / "cc_settings.py").write_bytes((HOME / "cc_settings.py").read_bytes())
        launcher = (HOME / "Start Builder.cmd").read_bytes().replace(b"builder.py", b"cc_settings.py").replace(b" --gui", b"")
        (helper / "Configure ComputerCraft.cmd").write_bytes(launcher)
        (helper / "README.md").write_text(
            "# ComputerCraft settings helper\n\n"
            "Run Configure ComputerCraft.cmd on Windows, using Python 3.11+ with Tcl/Tk.\n"
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
        update_launcher = (HOME / "Start Builder.cmd").read_bytes().replace(b"builder.py", b"updater.py")
        (update_helper / "Update Amaryllis.cmd").write_bytes(update_launcher)
        (update_helper / "README.md").write_text(
            "# Update an existing Amaryllis\n\nSave and fully close Minecraft. Run Update Amaryllis.cmd.\n"
            "Select the existing save or its numeric core folder. The new media folder is selected automatically.\n"
            "Choose a backup folder outside the save, preview the file changes, then apply the update.\n"
            "All 16 registered computers are updated together. Stored settings and avionics/data are retained.\n"
            "Old managed programs and core's package library are removed after a verified external backup.\n"
            "Load the world after completion. Media remains useful for installation or repair.\n"
            "Restore backup checks for newer edits before restoring. If interrupted, keep Minecraft closed\n"
            "and select the transaction's Amaryllis-update folder using Restore backup.\n"
            "This helper requires Windows and Python 3.11+ with Tcl/Tk. Keep windows-update on Windows.\n", encoding="utf-8")
        for group in (manifest["core"], manifest["state"], manifest["bootstrap"], manifest["library"], manifest.get("calibration", {}).get("files", [])):
            for entry in group:
                data = (objects / entry["object"]).read_bytes()
                require(sha(data) == entry["object"] and len(data) == entry["bytes"] and
                        f"{zlib.adler32(data):08X}" == entry["adler32"], "Output object verification failed.")
        share_files = {"README.md": (staging / "README.md").read_bytes(),
                       **{p.relative_to(staging).as_posix(): p.read_bytes()
                          for folder in (media, helper, update_helper) for p in folder.rglob("*") if p.is_file()}}
        archive_path = staging / "amaryllis-installer.zip"
        with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, data in sorted(share_files.items()):archive.writestr(name, data)
        with zipfile.ZipFile(archive_path) as archive:
            require(archive.testzip() is None and set(archive.namelist()) == set(share_files) and
                    all(archive.read(n) == d for n, d in share_files.items()), "ZIP verification failed.")
        source["snapshot"].check_unchanged()
        if source["mediaSnapshot"]:
            source["mediaSnapshot"].check_unchanged()
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
    description=ttk.Label(frame, text="Creates an installation disk from an existing Amaryllis to be used to commission a future blueprint.", wraplength=740, justify="left")
    description.pack(anchor="w", fill="x", pady=(4, 20))
    description.bind("<Configure>", lambda event: description.configure(wraplength=max(1,event.width)))
    project = default_project()
    mode = tk.StringVar(value="Project source" if project else "Saved ship export")
    source = tk.StringVar(value=str(project) if project else "");learning = tk.BooleanVar(value=True)
    ttk.Label(frame, text="Software source").pack(anchor="w")
    mode_box = ttk.Combobox(frame, textvariable=mode, values=("Project source", "Saved ship export"), state="readonly")
    mode_box.pack(fill="x", pady=(5, 12))
    source_label = tk.StringVar()
    def choose(variable):
        value = filedialog.askdirectory(parent=root, initialdir=variable.get() or str(Path.home()))
        if value:variable.set(value)
    def field(label, variable):
        ttk.Label(frame, textvariable=label).pack(anchor="w")
        row = ttk.Frame(frame);row.pack(fill="x", pady=(5, 15))
        ttk.Entry(row, textvariable=variable).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Browse…", command=lambda: choose(variable)).pack(side="right", padx=(8, 0))
    field(source_label, source)
    learning_button = ttk.Checkbutton(frame, variable=learning)
    learning_button.pack(anchor="w")
    def source_mode_changed(event=None):
        """Explain whether programs come from the project or a saved installation."""
        authoritative = mode.get() == "Project source"
        source_label.set("Amaryllis project folder" if authoritative else "Select a save with an extant and configured A.E.V Amaryllis")
        description.configure(text="Builds an installation disk or an existing-ship update from the maintained project source." if authoritative else
                              "Creates an installation disk from an existing Amaryllis to be used to commission a future blueprint.")
        learning_button.configure(text="Include shipped hover and leveling defaults" if authoritative else
                                  "Include this ship’s saved hover and leveling corrections")
        if event is not None:
            source.set(str(project) if authoritative and project else "")
    mode_box.bind("<<ComboboxSelected>>", source_mode_changed)
    source_mode_changed()
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
        if mode.get() == "Project source":
            start(for_update=True)
            return
        import updater
        updater.open_dialog(root, source.get())
    update_button = ttk.Button(update_row, text="Update existing ship…", command=update_ship)
    update_button.pack(side="left")
    ttk.Label(frame, textvariable=status).pack(anchor="w")
    text = tk.Text(frame, height=10, wrap="word", font=("Segoe UI", 10), state="disabled", background="#f5f7fa", relief="flat")
    text.pack(fill="both", expand=True, pady=(8, 0))
    import queue
    events = queue.Queue();last_result = [None];busy = [False]
    def append(message):
        text.configure(state="normal");text.insert("end", message + "\n");text.see("end");text.configure(state="disabled")
    def worker(selected, destination, include, authoritative, for_update):
        try:events.put(("update" if for_update else "done", build(selected, destination, include,
                         lambda line: events.put(("log", line)), project_source=authoritative)))
        except Exception as error:events.put(("error", build_error_details(error)))
    # Validate the selected paths and launch a single background build.
    def start(for_update=False):
        if busy[0]:return
        if not source.get().strip():messagebox.showerror("Choose a source", "Select the project folder or source save first.", parent=root);return
        destination = DEFAULT_OUTPUT
        try:
            # Only create the utility's default output folder automatically.
            destination.mkdir(exist_ok=True)
        except OSError as error:messagebox.showerror("Output folder", str(error), parent=root);return
        busy[0] = True;button.configure(state="disabled");open_button.configure(state="disabled");settings_button.configure(state="disabled");update_button.configure(state="disabled");status.set("Reading and validating…")
        text.configure(state="normal");text.delete("1.0", "end");text.configure(state="disabled")
        append("Builder "+VERSION+" | Python "+sys.version.split()[0]+" | "+sys.executable)
        mode_box.configure(state="disabled")
        threading.Thread(target=worker, args=(source.get(), str(destination), learning.get(), mode.get()=="Project source", for_update), daemon=True).start()
    # Deliver worker progress and completion results to the Tk interface.
    def poll():
        while not events.empty():
            kind, value = events.get_nowait()
            if kind == "log":append(value)
            elif kind in ("done", "update"):
                result, report = value;last_result[0] = result;busy[0] = False;button.configure(state="normal");open_button.configure(state="normal");settings_button.configure(state="normal");update_button.configure(state="normal")
                status.set("Installation disk created and verified")
                append(f"Saved to: {result}");append(f"Share: amaryllis-installer.zip | Required disk space: {report['minimumMediaCapacityBytes']:,} bytes")
                mode_box.configure(state="readonly")
                if report.get("source"):
                    revision=report["source"]
                    append("Source revision: " + (revision["commit"] or "unversioned source snapshot") +
                           (" (includes uncommitted changes)" if revision["dirty"] else ""))
                if kind == "update":
                    import updater
                    updater.open_dialog(root, media=str(result / "media"))
            else:
                busy[0] = False;button.configure(state="normal");settings_button.configure(state="normal");update_button.configure(state="normal");status.set("Build could not be completed");append(value)
                messagebox.showerror("Build could not be completed", value, parent=root)
                mode_box.configure(state="readonly")
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
    parser.add_argument("--source", type=Path, help="Minecraft save, computercraft/computer folder, or core computer folder")
    parser.add_argument("--project", type=Path, help="Build maintained source from this Amaryllis project folder")
    parser.add_argument("--output", type=Path, help="Existing parent folder for a new installer")
    parser.add_argument("--without-learning", action="store_true")
    parser.add_argument("--loose", action="store_true", help="Export separate Lua source files instead of runtime bundles")
    parser.add_argument("--library", type=Path, help="Optional matching installer media override; otherwise recover from the ship or discover media automatically")
    args = parser.parse_args()
    if args.gui or (args.source is None and args.project is None and args.output is None):gui();return
    if (args.source is None) == (args.project is None) or args.output is None:
        parser.error("Choose exactly one of --project or --source, and supply --output")
    if args.project and args.library:
        parser.error("--library applies to saved-ship exports only")
    path, report = build(args.project or args.source, args.output, not args.without_learning, print, args.library,
                         bundle=not args.loose, project_source=args.project is not None)
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
