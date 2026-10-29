"""Offline, transactional replacement of an existing registered Amaryllis fleet."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import uuid
import zlib

HOME = Path(__file__).resolve().parent
FOLDERS = {"navigator": "navigation", **{f"heading-{x}": f"heading/{x}" for x in ("left", "right", "main")},
           **{f"chamber_{x}": f"chamber/{x}" for x in ("fl", "fr", "bl", "br")},
           **{f"primary_{x}": f"primary/{'left' if x == 'l' else 'right'}" for x in ("l", "r")},
           **{f"thrust-{x}": f"thrust/{x}" for x in ("lb", "rb", "ls", "rs")}}
ROLES = {"core", "state", *FOLDERS}
LEGACY_LAUNCHER_SHA256 = "c81acc02b1cc88599c499021fb4082ae05db22a72a418b19be937dde595d9e61"
RECEIPT_FIELDS = {"role": "installedRole", "packageId": "installedPackageId", "version": "installedVersion",
                  "manifestChecksum": "installedManifestChecksum", "computerID": "installedComputerID",
                  "coreID": "installedCoreID", "label": "installedLabel", "installID": "installedInstallID",
                  "clientSession": "installedClientSession", "serverSession": "installedServerSession",
                  "coreSession": "installedCoreSession"}


class UpdateError(Exception):
    pass


def need(value, message):
    if not value:
        raise UpdateError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encode(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True, allow_nan=False) + "\n").encode()


# Decode JSON while rejecting duplicate keys and invalid values.
def decode(data, label):
    def pairs(items):
        result = {}
        for key, value in items:
            need(key not in result, f"Duplicate JSON key in {label}: {key}")
            result[key] = value
        return result
    try:
        return json.loads(data.decode("utf-8-sig"), object_pairs_hook=pairs,
                          parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
    except (ValueError, UnicodeError) as error:
        raise UpdateError(f"Invalid JSON in {label}: {error}") from error


# Validate an existing path entry and its reparse-point attributes.
def unlinked_entry(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    need(not stat.S_ISLNK(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 1024),
         f"Linked paths are not supported: {path}")
    return info


def unlinked(path):
    """Check every existing ancestor, including junctions outside the selected root."""
    for item in (path, *path.parents):
        unlinked_entry(item)


def safe(relative):
    need(isinstance(relative, str) and re.fullmatch(r"[A-Za-z0-9_. /-]+", relative), "Unsafe file path")
    parts = relative.split("/")
    need(all(p and p not in (".", "..") and p == p.strip() and not p.endswith(".") for p in parts), "Unsafe file path")
    need(not any(p.lower() in (".agents", ".git", "agents.md") for p in parts), "Protected instruction/repository path")
    need(not any(re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", p) for p in parts), "Reserved Windows path")
    return relative


# Read a bounded computer tree and reject linked or unsupported entries.
def scan(root):
    unlinked(root)
    need(root.is_dir(), f"Missing folder: {root}")
    result = {}
    folded = set()
    for base, dirs, names in os.walk(root, followlinks=False):
        information = {}
        for name in dirs + names:
            path = Path(base) / name
            # Each walked parent has already been checked. One lstat per child
            # preserves link rejection without re-reading every ancestor per file.
            information[name] = unlinked_entry(path)
            need(information[name] is not None, f"File changed during snapshot: {path}")
            relative = safe(path.relative_to(root).as_posix())
            need(relative.lower() not in folded, f"Case-conflicting paths: {relative}")
            folded.add(relative.lower())
        for name in names:
            path = Path(base) / name
            need(stat.S_ISREG(information[name].st_mode) and information[name].st_size <= 16_000_000, f"Unsupported file: {path}")
            result[path.relative_to(root).as_posix()] = path.read_bytes()
    need(sum(map(len, result.values())) <= 128_000_000, "Computer snapshot exceeds 128 MB")
    return result


def merged(defaults, stored):
    """Retain every stored value, adding defaults only for absent settings."""
    need(isinstance(defaults, dict) and isinstance(stored, dict), "Configuration must be an object")
    result = copy.deepcopy(defaults)
    for key, value in stored.items():
        result[key] = merged(result[key], value) if isinstance(result.get(key), dict) and isinstance(value, dict) else copy.deepcopy(value)
    return result


def current_launcher():
    path = HOME / "assets/bootstrap-launcher.lua"; unlinked(path)
    hashes = decode((HOME / "assets/asset-hashes.json").read_bytes(), "builder assets")
    data = path.read_bytes()
    need(sha(data) == hashes.get("bootstrap-launcher.lua"), "Startup launcher support asset is damaged")
    return data


# Resolve the selected ship and its registered core computer.
def locate(selection):
    selected = Path(selection).expanduser().absolute()
    unlinked(selected)
    if (selected / "fleet.json").is_file():
        return selected, selected.parent
    root = next((p for p in (selected / "computercraft/computer", selected / "computer", selected)
                 if p.is_dir() and (p.name == "computer" or p == selected / "computercraft/computer")), None)
    need(root, "Select the save, its computercraft/computer folder, or its numeric core folder")
    unlinked(root)
    cores = [p for p in root.iterdir() if p.name.isdecimal() and (p / "fleet.json").is_file()]
    need(len(cores) == 1, "Select the intended numeric core folder; the selection has zero or several cores")
    unlinked(cores[0])
    return cores[0], root


# Verify release metadata and every referenced installer object.
def read_media(selection):
    root = Path(selection).expanduser().absolute()
    unlinked(root)
    if (root / "media/release.json").is_file():
        root /= "media"
    need((root / "release.json").is_file(), "Choose the new installer's media folder or its parent")
    unlinked(root / "release.json")
    release = decode((root / "release.json").read_bytes(), "release.json")
    need(release.get("schemaVersion") == 1 and set(release.get("roles", {})) == ROLES, "Unsupported release roles/schema")
    identity = dict(release); identity.pop("releaseId", None)
    need(release.get("releaseId") == "amaryllis-" + sha(json.dumps(identity, sort_keys=True).encode())[:12], "Release identity mismatch")
    groups = {}
    for group in ("core", "state", "bootstrap", "library"):
        entries = release.get(group)
        need(isinstance(entries, list) and 0 < len(entries) <= 256, f"Invalid {group} manifest")
        output = {}; folded = set()
        for entry in entries:
            path, digest = entry.get("path"), entry.get("object")
            need(isinstance(path, str) and path.startswith("/"), "Invalid release path")
            safe(path[1:])
            need(path.lower() not in folded, "Duplicate release destination")
            folded.add(path.lower())
            need(re.fullmatch(r"[0-9a-f]{64}", str(digest)), "Invalid object identity")
            file = root / "objects" / digest; unlinked(file)
            need(file.is_file() and file.stat().st_size <= 4_000_000, f"Missing/oversized object: {digest}")
            data = file.read_bytes()
            need(type(entry.get("bytes")) is int and len(data) == entry["bytes"] and sha(data) == digest
                 and f"{zlib.adler32(data):08X}" == entry.get("adler32"), f"Damaged object: {path}")
            output[path] = data
        groups[group] = output
    need(set(groups["bootstrap"]) == {"/startup.lua", "/installer.lua", "/installer/commissioning.lua"}, "Unsupported bootstrap layout")
    need(set(groups["core"]) == {"/startup.lua", "/avionics/main.lua", "/avionics/config.json", "/installer/config.json", "/installer/library.json"}, "Updater requires a bundled core release")
    need(set(groups["state"]) == {"/startup.lua", "/avionics/main.lua", "/avionics/config.json"}, "Updater requires a bundled state release")
    unlinked(root / "library.json")
    catalog_bytes = (root / "library.json").read_bytes()
    catalog = decode(catalog_bytes, "library.json")
    catalog_identity = dict(catalog); catalog_identity.pop("libraryId", None)
    need(catalog.get("schemaVersion") == 1 and catalog.get("libraryId") == release.get("libraryId")
         and catalog["libraryId"] == sha(encode(catalog_identity)) and catalog.get("files") == release["library"]
         and groups["core"]["/installer/library.json"] == catalog_bytes, "Catalog does not match release")
    # Verify bundle framing and embedded source hashes without executing any Lua.
    import bundling
    loader = (HOME / "assets/runtime-loader.lua").read_bytes()
    for group, role in (("core", "core"), ("state", "state")):
        item = bundling.unpack(groups[group]["/avionics/main.lua"], loader)
        need(item and item[0]["role"] == role, f"Invalid {role} bundle")
    expected_library = set()
    for role, folder in FOLDERS.items():
        prefix = "/packages/" + folder + "/"
        expected_library.update(prefix + p for p in ("main.lua", "config.json", "manifest.json"))
        manifest = decode(groups["library"].get(prefix + "manifest.json", b""), role + " manifest")
        need(manifest.get("role") == role and type(manifest.get("version")) is int and manifest["version"] >= 2
             and manifest.get("files") == ["/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua"], "Unsupported package layout")
        need(catalog["roles"].get(role) == {k: manifest[k] for k in ("packageId", "version")}, "Catalog package mismatch")
        item = bundling.unpack(groups["library"][prefix + "main.lua"], loader)
        need(item and item[0]["role"] == "auxiliary", f"Invalid bundle for {role}")
    expected_library.add("/packages/common/console.lua")
    need(set(groups["library"]) == expected_library, "Unexpected package library destinations")
    return root, release, groups


def managed(path):
    """These are the installer's reserved program namespaces. Data stays writable."""
    if path.startswith("packages/"):
        return True
    if path.startswith("avionics/data/"):
        return False
    if path.startswith(("installer/stage/", "installer/backup/")):
        return True
    if path.startswith(("avionics/", "installer/")) and re.search(r"\.lua(?:\.(?:bak|tmp|amaryllis-backup|amaryllis-stage))?$", path):
        return True
    return path in {"startup.lua", "startup.lua.bak", "startup.lua.tmp", "installer.lua", "installer.lua.bak", "installer.lua.tmp",
                    "avionics/config.json.bak", "avionics/config.json.tmp", "installer/status.json.bak", "installer/status.json.tmp",
                    "avionics/config.json.amaryllis-backup", "installer/config.json.bak", "installer/config.json.tmp",
                    "installer/library.json.amaryllis-backup", "installer/library.json.amaryllis-stage",
                    "installer/library.json.bak", "installer/library.json.tmp", "installer/install_status.json",
                    "installer/paused", "installer/reinstall", "installer/commissioning.json"}


# Check an installed receipt against the fleet role and core assignment.
def valid_receipt(before, role, computer_id, core_id, label):
    config = decode(before.get("avionics/config.json", b""), role + " config")
    receipt = config.get("install", {})
    status = decode(before.get("installer/status.json", b""), role + " installer status")
    need(receipt.get("protocol") == "amaryllis.install.v1" and receipt.get("role") == role
         and receipt.get("computerID") == computer_id and receipt.get("coreID") == core_id
         and receipt.get("label") == label and type(receipt.get("version")) is int and receipt["version"] >= 2,
         f"{role} has an incomplete or conflicting installed receipt; repair its installation first")
    need(status.get("hasInstalled") is True and status.get("recoveryRequired") is False
         and status.get("state") not in ("committing", "recovery_required"), f"{role} has an unfinished installation")
    for key, field in RECEIPT_FIELDS.items():
        need(key in receipt and status.get(field) == receipt[key], f"{role} receipt/status mismatch: {key}")
    for field in ("clientSession", "serverSession", "coreSession", "installID"):
        need(isinstance(receipt[field], str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", receipt[field]), f"Invalid {role} receipt token")
    return config, receipt, status


class Plan:
    def __init__(self, core, computers, media, release):
        self.core, self.computers, self.media, self.release = core, computers, media, release
        self.before, self.after, self.roles = {}, {}, {}
        self.operation = "update"

    # Format the operation, per-computer file changes and preserved-data counts.
    def report(self):
        rows = []
        for key in sorted(self.before, key=lambda p: (int(p.split('/')[0]), p)):
            old, new = self.before[key], self.after.get(key)
            action = "Remove" if new is None else "Keep" if new == old else "Replace"
            rows.append(f"{action:7} #{key}")
        rows += [f"Add     #{key}" for key in sorted(self.after.keys() - self.before.keys())]
        counts = {k: sum(row.startswith(k) for row in rows) for k in ("Add", "Replace", "Remove", "Keep")}
        heading = "Startup launcher repair" if self.operation == "repair-startup" else "Existing ship update"
        return (f"{heading}: {self.release['releaseId']}\nTarget: {self.computers}\n"
                f"Computers: {len(self.roles)} | " + " | ".join(f"{k}: {v}" for k, v in counts.items()) +
                "\nStored settings and all avionics/data files are retained.\n"
                "Old program files are backed up outside the save, then replaced/removed.\n\n" + "\n".join(rows))


# Compute replacement files while preserving stored configuration and data.
def preview(selection, media_selection):
    core, computers = locate(selection)
    need(not (computers / ".amaryllis-update.json").exists(),
         "An update transaction needs recovery. Keep Minecraft closed and use Restore backup with the folder named in .amaryllis-update.json")
    media, release, groups = read_media(media_selection)
    need(not media.is_relative_to(computers) and not computers.is_relative_to(media), "Installer media must be outside computer folders")
    fleet = decode((core / "fleet.json").read_bytes(), "fleet.json")
    registered = fleet.get("computers")
    need(isinstance(registered, dict) and set(registered) == ROLES, "Fleet must contain the complete registered 16-computer installation")
    ids = [r.get("id") for r in registered.values()]
    need(all(type(i) is int and i >= 0 for i in ids) and len(set(ids)) == len(ids), "Missing or duplicate registered computer IDs")
    core_id = registered["core"]["id"]
    need(core.name == str(core_id), "Core folder does not match fleet registry")
    plan = Plan(core, computers, media, release)
    for role, record in registered.items():
        need(isinstance(record.get("label"), str) and record["label"] == release["roles"][role]["label"], f"Fleet label differs for {role}")
        computer_id = record["id"]; folder = computers / str(computer_id)
        before = scan(folder)
        need(not any(p.startswith("installer/commit.json") for p in before), f"#{computer_id} has an unfinished commit; repair it first")
        journal = decode(before.get("amaryllis-install.json", b""), f"#{computer_id} installation record")
        need(journal.get("pending") is False and journal.get("role") == role and journal.get("id") == computer_id,
             f"#{computer_id} registration conflicts with {role}")
        need("startup.lua" in before and ("avionics/main.lua" in before or role == "state" and "avionics/state_reader.lua" in before), f"#{computer_id} is missing its installed program")
        after = {p: d for p, d in before.items() if not managed(p)}
        if role in ("core", "state"):
            replacements = dict(groups[role])
            for path in ("/avionics/config.json", "/installer/config.json"):
                if path in replacements:
                    need(path[1:] in before, f"#{computer_id} is missing {path}")
                    defaults = decode(replacements[path], path)
                    settings = merged(defaults, decode(before[path[1:]], path))
                    if path == "/installer/config.json":
                        for key in ("max_file_bytes", "max_total_bytes"):
                            settings[key] = max(settings[key], defaults[key])
                    replacements[path] = encode(settings)
            if role == "core":
                cfg = decode(replacements["/avionics/config.json"], "core config")
                need(cfg.get("computer_id", core_id) == core_id, "Core config identity conflicts with fleet")
        else:
            config, receipt, status = valid_receipt(before, role, computer_id, core_id, record["label"])
            prefix = "/packages/" + FOLDERS[role] + "/"
            manifest = decode(groups["library"][prefix + "manifest.json"], role)
            need(manifest["packageId"] == receipt["packageId"] and manifest["version"] >= receipt["version"],
                 f"Package identity changed or version would decrease for {role}")
            replacements = {"/avionics/main.lua": groups["library"][prefix + "main.lua"],
                            "/avionics/config.json": groups["library"][prefix + "config.json"],
                            "/avionics/common/console.lua": groups["library"]["/packages/common/console.lua"],
                            "/startup.lua": groups["bootstrap"]["/startup.lua"], "/installer.lua": groups["bootstrap"]["/installer.lua"]}
            if sha(replacements["/startup.lua"]) == LEGACY_LAUNCHER_SHA256:
                replacements["/startup.lua"] = current_launcher()
            # Checksum describes the release payload in the server's fixed manifest order.
            checksum_rows = b"".join(p.encode() + b"\0" + str(len(replacements[p])).encode() + b"\0" +
                                     f"{zlib.adler32(replacements[p]):08X}".encode() + b"\n" for p in manifest["files"])
            receipt = dict(receipt, version=manifest["version"], manifestChecksum=f"{zlib.adler32(checksum_rows):08X}")
            config = merged(decode(replacements["/avionics/config.json"], role), config)
            config["install"] = receipt
            replacements["/avionics/config.json"] = encode(config)
            for key, field in RECEIPT_FIELDS.items():
                status[field] = receipt[key]
            status.update(state="installed", hasInstalled=True, recoveryRequired=False, version=receipt["version"],
                          activePackageVersion=receipt["version"], activePackageId=receipt["packageId"])
            # Retain real historical sessions. Live control still requires a fresh core binding.
            replacements["/installer/status.json"] = encode(status)
            trust = decode(before.get("config.json", b""), role + " bootstrap config")
            need(trust.get("core_id") == core_id and trust.get("target_role", "auto") in ("auto", role), f"#{computer_id} bootstrap trust conflicts")
            trust["maxFileBytes"] = max(trust.get("maxFileBytes", 0), 524288)
            trust["maxTotalBytes"] = max(trust.get("maxTotalBytes", 0), 1048576)
            replacements["/config.json"] = encode(trust)
        for path, data in replacements.items():
            after[path[1:]] = data
        journal.update(releaseId=release["releaseId"])
        after["amaryllis-install.json"] = encode(journal)
        # Local learning, recovery files and arbitrary user files remain byte-for-byte.
        plan.before.update({f"{computer_id}/{p}": d for p, d in before.items()})
        plan.after.update({f"{computer_id}/{p}": d for p, d in after.items()})
        plan.roles[str(computer_id)] = role
    return plan


# Prepare the supported launcher replacement for registered fleet computers.
def preview_startup_repair(selection):
    core, computers = locate(selection)
    need(not (computers / ".amaryllis-update.json").exists(), "An update transaction needs recovery first")
    fleet = decode((core / "fleet.json").read_bytes(), "fleet.json").get("computers", {})
    need(set(fleet) == ROLES, "A complete registered fleet is required")
    ids = [r.get("id") for r in fleet.values()]
    need(all(type(i) is int and i >= 0 for i in ids) and len(set(ids)) == 16, "Invalid or duplicate registered computer IDs")
    need(core.name == str(fleet["core"]["id"]), "Core identity mismatch")
    replacement = current_launcher()
    plan = Plan(core, computers, HOME / "assets", {"releaseId": "startup-launcher-repair-v1"})
    plan.operation = "repair-startup"
    for role, record in fleet.items():
        cid = str(record["id"]); before = scan(computers / cid)
        journal = decode(before.get("amaryllis-install.json", b""), role + " registration")
        need(journal.get("id") == record["id"] and journal.get("role") == role and journal.get("pending") is False,
             f"Conflicting registration for #{cid}")
        after = dict(before)
        if role in FOLDERS:
            installed = before.get("startup.lua", b"")
            need(sha(installed) == LEGACY_LAUNCHER_SHA256 or installed == replacement,
                 f"#{cid} has a different startup program; targeted repair refused")
            after["startup.lua"] = replacement
        plan.roles[cid] = role
        plan.before.update({f"{cid}/{p}": d for p, d in before.items()})
        plan.after.update({f"{cid}/{p}": d for p, d in after.items()})
    return plan


def current(plan):
    return {f"{cid}/{p}": d for cid in plan.roles for p, d in scan(plan.computers / cid).items()}


# Flush a temporary sibling file and atomically replace its target.
def atomic_write(path, data, transaction=None):
    unlinked(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if transaction:
        temporary = str(path.parent / (".amaryllis-write-" + transaction + ".tmp"))
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    else:
        fd, temporary = tempfile.mkstemp(prefix=".amaryllis-write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data); handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prune(root, folders):
    for name in sorted(folders, key=lambda p: len(p.split('/')), reverse=True):
        path = root / name
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()


def hash_map(files):
    return {p: sha(data) for p, data in files.items()}


def closed_check(path):
    import cc_settings
    cc_settings.assert_game_closed(path)


# Back up the verified fleet, commit the preview and roll back interrupted writes.
def apply(plan, backup_parent, *, closed_ack=False, process_check=closed_check, fault=None):
    need(closed_ack is True, "Save and fully close Minecraft before applying the update")
    parent = Path(backup_parent).expanduser().absolute()
    unlinked(parent)
    # Keep backups/staging outside the whole save and installer source.
    save = plan.computers.parent.parent if plan.computers.parent.name == "computercraft" else plan.computers.parent
    need(parent.is_dir() and not parent.is_relative_to(save) and not parent.is_relative_to(plan.media),
         "Choose an existing backup folder outside the Minecraft save and installer media")
    process_check(plan.core)
    need(current(plan) == plan.before, "Computer files changed after preview. Preview again")
    fresh = preview_startup_repair(plan.core) if plan.operation == "repair-startup" else preview(plan.core, plan.media)
    need(fresh.before == plan.before and fresh.after == plan.after, "Installer/target changed after preview")
    required = sum(map(len, plan.before.values())) + sum(map(len, plan.after.values())) + 1_000_000
    need(shutil.disk_usage(parent).free > required and shutil.disk_usage(plan.computers).free > sum(map(len, plan.after.values())) + 1_000_000,
         "Insufficient free space for verified backup and staged replacement")
    backup = parent / ("Amaryllis-update-" + datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    backup.mkdir()
    for area, files in (("before", plan.before), ("after", plan.after)):
        for relative, data in files.items():
            atomic_write(backup / area / safe(relative), data)
        need(scan(backup / area) == files, f"{area} backup/staging verification failed")
    changed = sorted(p for p in plan.before.keys() | plan.after.keys() if plan.before.get(p) != plan.after.get(p))
    journal = {"schemaVersion": 1, "target": str(plan.computers), "core": plan.core.name,
               "transaction": uuid.uuid4().hex,
               "releaseId": plan.release["releaseId"], "roles": plan.roles, "phase": "prepared",
               "createdAtUTC": datetime.now(timezone.utc).isoformat(), "before": hash_map(plan.before),
               "after": hash_map(plan.after), "changed": changed}
    journal_path = backup / "update.json"
    atomic_write(journal_path, encode(journal))
    (backup / "preview.txt").write_text(plan.report(), encoding="utf-8")
    process_check(plan.core)
    need(current(plan) == plan.before, "Target changed while preparing the backup. No computer files were changed")
    marker = plan.computers / ".amaryllis-update.json"
    unlinked(marker)
    try:
        with marker.open("xb") as handle:
            handle.write(encode({"backup": str(backup), "releaseId": plan.release["releaseId"]}))
            handle.flush(); os.fsync(handle.fileno())
    except FileExistsError as error:
        raise UpdateError("Another update is in progress or needs recovery") from error
    try:
        journal["phase"] = "applying"; atomic_write(journal_path, encode(journal))
        # Startup files go last; Minecraft remains closed throughout the transaction.
        for index, relative in enumerate(sorted(changed, key=lambda p: (p.endswith("/startup.lua"), p))):
            target = plan.computers / relative; unlinked(target)
            if relative in plan.after:
                atomic_write(target, (backup / "after" / relative).read_bytes(), journal["transaction"])
            elif target.exists():
                target.unlink()
            if fault:
                fault(index, relative)
        need(current(plan) == plan.after, "Final installation verification failed")
        folders = {str(Path(p).parent).replace("\\", "/") for p in changed if p not in plan.after}
        folders |= {str(Path(p).parent).replace("\\", "/") for p in folders}
        prune(plan.computers, folders)
        journal["phase"] = "applied"; atomic_write(journal_path, encode(journal))
        marker.unlink()
    except Exception as error:
        try:
            restore(backup, closed_ack=True, process_check=process_check)
        except Exception as recovery_error:
            raise UpdateError(f"Update stopped: {error}. Recovery required: {backup}. {recovery_error}") from error
        raise UpdateError(f"Update stopped and the previous installation was restored. Backup: {backup}. {error}") from error
    # Replacement staging is disposable after commit. Retain only the old files
    # and both hash maps needed to verify a future restore.
    discard_stage(backup, plan.after)
    return backup


# Verify the expected staging path and remove its temporary transaction files.
def discard_stage(backup, expected):
    stage = backup / "after"; unlinked(stage)
    need(stage.absolute().is_relative_to(backup.absolute()), "Invalid staging directory")
    if not stage.exists(): return
    directories = {str(Path(p).parent).replace("\\", "/") for p in expected}
    for path in list(directories):
        directories.update(str(p).replace("\\", "/") for p in Path(path).parents if str(p) != ".")
    for relative in expected:
        path = stage / safe(relative); unlinked(path)
        if path.is_file(): path.unlink()
    prune(stage, directories)
    if not any(stage.iterdir()): stage.rmdir()


# Verify a backup and restore its exact recorded computer files.
def restore(selection, *, closed_ack=False, process_check=closed_check):
    need(closed_ack is True, "Fully close Minecraft before restoring")
    backup = Path(selection).expanduser().absolute(); unlinked(backup)
    record = decode((backup / "update.json").read_bytes(), "update backup")
    need(record.get("schemaVersion") == 1 and record.get("phase") in ("prepared", "applying", "applied", "restoring", "restored"), "Unsupported backup journal")
    need(re.fullmatch(r"[0-9a-f]{32}", str(record.get("transaction"))), "Invalid backup transaction")
    target = Path(record["target"]); unlinked(target)
    need(target.is_absolute() and not backup.is_relative_to(target) and not target.is_relative_to(backup), "Invalid backup target")
    roles = record["roles"]
    need(set(roles.values()) == ROLES and all(re.fullmatch(r"0|[1-9][0-9]*", cid) for cid in roles), "Invalid backup fleet")
    need(record.get("core") in roles and roles[record["core"]] == "core", "Invalid backup core")
    marker = target / ".amaryllis-update.json"; unlinked(marker)
    if marker.exists():
        need(decode(marker.read_bytes(), "update marker").get("backup") == str(backup), "A different update transaction needs recovery first")
    before = scan(backup / "before")
    need(hash_map(before) == record["before"], "Damaged before backup")
    for area in ("before", "after"):
        need(isinstance(record[area], dict) and all(safe(p).split('/')[0] in roles and re.fullmatch(r"[0-9a-f]{64}", digest)
                                                  for p, digest in record[area].items()), "Invalid backup destination/hash")
    # Restore uses only the verified original snapshot. Replacement staging may
    # already be partly discarded when recovering an interrupted final cleanup.
    changed = sorted(p for p in record["before"].keys() | record["after"].keys() if record["before"].get(p) != record["after"].get(p))
    need(changed == record["changed"], "Backup change list mismatch")
    process_check(target / record["core"])
    actual = {f"{cid}/{p}": d for cid in roles for p, d in scan(target / cid).items()}
    temporary_paths = {(Path(p).parent / (".amaryllis-write-" + record["transaction"] + ".tmp")).as_posix() for p in changed}
    leftovers = actual.keys() & temporary_paths
    for relative in leftovers: actual.pop(relative)
    actual_hashes = hash_map(actual)
    need(not (actual_hashes.keys() - (record["before"].keys() | record["after"].keys())), "New files exist in the target. Restore refused to protect newer changes")
    for p in record["before"].keys() | record["after"].keys():
        need(actual_hashes.get(p) in (record["before"].get(p), record["after"].get(p)), f"Newer edits detected: {p}. Restore refused")
    if not marker.exists():
        try:
            with marker.open("xb") as handle:
                handle.write(encode({"backup": str(backup), "releaseId": record["releaseId"]}))
                handle.flush(); os.fsync(handle.fileno())
        except FileExistsError as error:
            raise UpdateError("Another update started during restore validation") from error
    record["phase"] = "restoring"; atomic_write(backup / "update.json", encode(record))
    for relative in leftovers: (target / relative).unlink()
    for relative in sorted(changed, key=lambda p: (p.endswith("/startup.lua"), p)):
        path = target / relative; unlinked(path)
        if relative in before:
            atomic_write(path, before[relative], record["transaction"])
        elif path.exists():
            path.unlink()
    need({f"{cid}/{p}": d for cid in roles for p, d in scan(target / cid).items()} == before, "Restore verification failed")
    record["phase"] = "restored"; atomic_write(backup / "update.json", encode(record))
    if marker.exists(): marker.unlink()
    discard_stage(backup, record["after"])
    return target


# Create the update preview, commit and backup-restore interface.
def open_dialog(parent, source="", media=""):
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox
    window = tk.Toplevel(parent); window.title("Update existing Amaryllis"); window.geometry("940x760")
    frame = ttk.Frame(window, padding=18); frame.pack(fill="both", expand=True)
    ttk.Label(frame, text="Update existing ship", font=("Segoe UI", 17, "bold")).pack(anchor="w")
    ttk.Label(frame, text="Replaces installed programs, removes obsolete files and retains stored settings and learning.", wraplength=850).pack(anchor="w", pady=(4, 12))
    variables = [tk.StringVar(value=source), tk.StringVar(value=media), tk.StringVar(value=str(HOME / "Backups"))]
    for label, variable in zip(("Target Minecraft save or core folder", "New installer media folder", "Backup folder outside the save"), variables):
        ttk.Label(frame, text=label).pack(anchor="w")
        row = ttk.Frame(frame); row.pack(fill="x", pady=(3, 10))
        ttk.Entry(row, textvariable=variable).pack(side="left", fill="x", expand=True)
        def choose(v=variable):
            selected = filedialog.askdirectory(parent=window, initialdir=v.get() if Path(v.get()).is_dir() else str(HOME))
            if selected: v.set(selected)
        ttk.Button(row, text="Browse…", command=choose).pack(side="right", padx=(8, 0))
    closed = tk.BooleanVar(value=False)
    ttk.Checkbutton(frame, text="I have saved and fully closed Minecraft", variable=closed).pack(anchor="w", pady=6)
    row = ttk.Frame(frame); row.pack(fill="x")
    text = tk.Text(frame, wrap="none", font=("Consolas", 10)); text.pack(fill="both", expand=True, pady=10)
    bar = ttk.Scrollbar(text, command=text.yview); bar.pack(side="right", fill="y"); text.configure(yscrollcommand=bar.set)
    text.configure(state="disabled")
    state = {"plan": None, "inputs": None, "busy": False}
    window._amaryllis_update_state = state
    def show(value):
        text.configure(state="normal"); text.delete("1.0", "end"); text.insert("end", value); text.configure(state="disabled")
    import queue, threading
    events = queue.Queue()
    # Start one background update operation and publish its result to the UI queue.
    def run(action):
        if state["busy"]: return
        state["busy"] = True
        for button in buttons: button.configure(state="disabled")
        def work():
            try: events.put(("ok", action()))
            except Exception as error: events.put(("error", str(error)))
        threading.Thread(target=work, daemon=True).start()
    def make_preview():
        state["plan"] = None
        inputs = tuple(v.get() for v in variables)
        def work():
            plan = preview(inputs[0], inputs[1]); return ("preview", plan, inputs)
        run(work)
    def make_repair_preview():
        state["plan"] = None
        inputs = tuple(v.get() for v in variables)
        run(lambda: ("preview", preview_startup_repair(inputs[0]), inputs))
    # Review the preview and submit the acknowledged offline update.
    def update():
        plan = state["plan"]
        if not plan or state["inputs"] != tuple(v.get() for v in variables):
            messagebox.showerror("Preview required", "Preview the current choices before applying", parent=window); return
        if not closed.get():
            messagebox.showerror("Close Minecraft", "Save and fully close Minecraft, then select the checkbox", parent=window); return
        parent_path = Path(variables[2].get())
        if parent_path == HOME / "Backups": parent_path.mkdir(exist_ok=True)
        if not messagebox.askyesno("Apply reviewed update", "Replace the files shown in the preview and save a verified backup?", parent=window): return
        run(lambda: ("applied", apply(plan, parent_path, closed_ack=True)))
    def recover():
        selected = filedialog.askdirectory(parent=window, title="Choose an Amaryllis-update backup folder")
        if not selected: return
        if not closed.get():
            messagebox.showerror("Close Minecraft", "Fully close Minecraft and select the checkbox before restoring", parent=window); return
        if messagebox.askyesno("Restore installation", "Restore the selected backup after checking for newer changes?", parent=window):
            run(lambda: ("restored", restore(selected, closed_ack=True)))
    buttons = [ttk.Button(row, text="Preview update", command=make_preview),
               ttk.Button(row, text="Preview startup repair", command=make_repair_preview),
               ttk.Button(row, text="Apply update", command=update), ttk.Button(row, text="Restore backup…", command=recover)]
    for button in buttons: button.pack(side="left", padx=(0, 8))
    # Consume update-worker events and refresh buttons, logs and results.
    def poll():
        while not events.empty():
            kind, value = events.get_nowait(); state["busy"] = False
            for button in buttons: button.configure(state="normal")
            if kind == "error":
                state["plan"] = None; show(value); messagebox.showerror("Update could not complete", value, parent=window)
            elif value[0] == "preview":
                state["plan"], state["inputs"] = value[1:]; show(value[1].report())
            else:
                state["plan"] = None
                show(("Update complete and verified.\nBackup: " if value[0] == "applied" else "Backup restored and verified.\nTarget: ") + str(value[1]) +
                     "\n\nLoad the world. The existing computers will use the replacement programs.\nKeep the matching installer disk for later installation or repair.")
        window.after(100, poll)
    def close():
        if state["busy"]: messagebox.showinfo("Operation in progress", "Let the current operation finish before closing", parent=window)
        else: window.destroy()
    window.protocol("WM_DELETE_WINDOW", close); window.after(100, poll)
    if parent.winfo_viewable(): window.transient(parent)
    return window


# Dispatch preview, update and restore command-line operations.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gui", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--media", type=Path)
    parser.add_argument("--apply", action="store_true", help="Apply the previewed replacement with a verified backup")
    parser.add_argument("--backup", type=Path, help="Existing backup parent outside the save")
    parser.add_argument("--restore", type=Path, help="Restore/recover a transaction backup folder")
    parser.add_argument("--repair-startup", action="store_true", help="Replace the known faulty auxiliary launcher only")
    parser.add_argument("--minecraft-closed", action="store_true")
    args = parser.parse_args()
    if args.gui or not any((args.source, args.media, args.restore)):
        import tkinter as tk
        root = tk.Tk(); root.withdraw()
        default_media = str(HOME.parent / "media") if (HOME.parent / "media/release.json").is_file() else ""
        window = open_dialog(root, str(args.source or ""), str(args.media or default_media))
        window.bind("<Destroy>", lambda event: root.destroy() if event.widget == window else None)
        root.mainloop(); return
    if args.restore:
        print(restore(args.restore, closed_ack=args.minecraft_closed)); return
    need(args.source and (args.media or args.repair_startup), "--source and --media are required for a full update")
    plan = preview_startup_repair(args.source) if args.repair_startup else preview(args.source, args.media); print(plan.report())
    if args.apply:
        need(args.backup, "--backup is required when applying")
        print("Verified backup:", apply(plan, args.backup, closed_ack=args.minecraft_closed))


if __name__ == "__main__":
    try: main()
    except Exception as error:
        if "--gui" in __import__("sys").argv:
            try:
                import ctypes
                ctypes.windll.user32.MessageBoxW(0, str(error), "Amaryllis updater", 16)
            except Exception: pass
        raise SystemExit("Update failed: " + str(error))
