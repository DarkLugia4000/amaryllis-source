"""Narrow, offline editor for three ComputerCraft TOML settings.

Keeps all unrelated bytes, creates a verified sibling backup, and atomically
replaces one explicitly selected file. Never invoked by an installer export.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, DecimalException
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
try:
    import tomllib
except ImportError:
    tomllib = None
import uuid

CAPACITY_MIN = 4_000_000
INTEGER_MAX = 2_147_483_647
KEYS = ("computer_space_limit", "floppy_space_limit", "execution.computer_threads")
LABELS = ("Computer capacity", "Disk capacity", "Execution threads")


class SettingsError(Exception):
    pass


def need(condition, message):
    if not condition:
        raise SettingsError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


# Validate the selected bounded configuration file and its parent path entries.
def safe_file(path):
    path = Path(path).expanduser().absolute()
    for item in (path, *path.parents):
        info = item.lstat()
        need(not item.is_symlink() and not (getattr(info, "st_file_attributes", 0) &
             getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 1024)), "Linked config paths are not supported.")
    need(path.is_file() and path.stat().st_size <= 1_048_576, "Choose a config file smaller than 1 MiB.")
    return path.resolve()


# Parse supported TOML capacity and execution-thread values.
def parse(data):
    need(tomllib is not None, "Python 3.11 or newer is required to validate TOML settings.")
    try:
        value = tomllib.loads(data.decode("utf-8-sig"))
        settings = {KEYS[0]: value[KEYS[0]], KEYS[1]: value[KEYS[1]], KEYS[2]: value["execution"]["computer_threads"]}
    except (UnicodeError, ValueError, KeyError, TypeError) as error:
        raise SettingsError("Unsupported or invalid ComputerCraft TOML: " + str(error)) from error
    for key in KEYS[:2]:
        need(type(settings[key]) is int and 1 <= settings[key] <= INTEGER_MAX, "Unsupported current capacity: " + key)
    need(type(settings[KEYS[2]]) is int and 1 <= settings[KEYS[2]] <= 64, "Computer Threads: Enter a value from 1 to 64.")
    return value, settings


def scope(path):
    if path.parent.name.lower() == "config":
        return "Detected instance config: Will affect all worlds using this instance."
    if path.parent.name.lower() == "serverconfig":
        return "Detected world or server config: " + str(path.parent.parent)
    return "Could not verify origin, ensure this is the config file belonging to a world or instance you wish to deploy Amaryllis in."


def load(path):
    path = safe_file(path)
    need(path.name.lower() == "computercraft-server.toml", "Select computercraft-server.toml; JSON and client settings are not supported.")
    data = path.read_bytes()
    document, settings = parse(data)
    return path, data, document, settings


@dataclass(frozen=True)
class Plan:
    path: Path
    before: bytes
    after: bytes
    old: dict
    new: dict

    # Format current and requested settings with their configuration scope.
    def preview(self):
        lines = [str(self.path), scope(self.path), ""]
        for key, label in zip(KEYS, LABELS):
            suffix = " bytes" if key != KEYS[2] else ""
            lines.append(f"{label}: {self.old[key]:,}{suffix} → {self.new[key]:,}{suffix}")
        lines += ["", "Installer creates a backup next to the file.",
                  "Ensure Minecraft or server is closed/stopped completely before applying."]
        return "\n".join(lines)


# Patch selected integer settings and verify all other TOML values are preserved.
def plan(path, desired):
    path, before, document, old = load(path)
    need(set(desired) == set(KEYS), "Specify only computer capacity, disk capacity and execution threads.")
    for key in KEYS[:2]:
        need(type(desired[key]) is int and max(CAPACITY_MIN, old[key]) <= desired[key] <= INTEGER_MAX,
             "Amaryllis requires at least 4 MB of computer capacity. Review values and try again.")
    need(type(desired[KEYS[2]]) is int and 1 <= desired[KEYS[2]] <= 64, "Computer Threads: Enter a value from 1 to 64.")
    section = ""
    found = set()
    lines = before.decode("utf-8-sig").splitlines(keepends=True)
    number = re.compile(r"^([ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*)([+-]?[0-9][0-9_]*)([ \t]*(?:#[^\r\n]*)?)(\r?\n)?$")
    for index, line in enumerate(lines):
        if line.lstrip().startswith("["):
            section = "execution" if re.fullmatch(r"[ \t]*\[execution\][ \t]*(?:#[^\r\n]*)?(?:\r?\n)?", line) else "other"
        match = number.fullmatch(line)
        if not match:
            continue
        key = ("execution." if section == "execution" else "") + match[2]
        if section == "other" or key not in desired:
            continue
        need(key not in found, "Ambiguous setting layout; edit this file manually: " + key)
        found.add(key)
        if desired[key] != old[key]:
            lines[index] = match[1] + str(desired[key]) + match[4] + (match[5] or "")
    need(found == set(KEYS), "Unsupported setting layout. Expected plain integer keys and an [execution] section.")
    after = (b"\xef\xbb\xbf" if before.startswith(b"\xef\xbb\xbf") else b"") + "".join(lines).encode("utf-8")
    updated, actual = parse(after)
    expected = dict(document)
    expected[KEYS[0]], expected[KEYS[1]] = desired[KEYS[0]], desired[KEYS[1]]
    expected["execution"] = {**document["execution"], "computer_threads": desired[KEYS[2]]}
    need(actual == desired and updated == expected, "Patch would affect unrelated TOML values; no changes were written.")
    return Plan(path, before, after, dict(old), dict(desired))


def java_processes_fallback():
    """Win32 process-name enumeration when WMI/CIM is restricted."""
    import ctypes
    from ctypes import wintypes
    class Entry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                    ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG), ("dwFlags", wintypes.DWORD),
                    ("szExeFile", wintypes.WCHAR * 260)]
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    for name in ("Process32FirstW", "Process32NextW"):
        function = getattr(kernel, name)
        function.argtypes = [wintypes.HANDLE, ctypes.POINTER(Entry)]
        function.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    need(snapshot not in (None, ctypes.c_void_p(-1).value), "Cannot inspect running processes. Please ensure Minecraft is not running.")
    try:
        entry = Entry();entry.dwSize = ctypes.sizeof(Entry)
        more = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        found = []
        while more:
            if entry.szExeFile.lower() in ("java.exe", "javaw.exe"):
                found.append(entry.th32ProcessID)
            more = kernel.Process32NextW(snapshot, ctypes.byref(entry))
        need(ctypes.get_last_error() == 18, "Process enumeration could not finish; changes refused.")
        return found
    finally:
        kernel.CloseHandle(snapshot)


def assert_game_closed(path):
    """Conservative process check, supplemented by the user's closed-game acknowledgement."""
    need(os.name == "nt", "Applying configuration is supported on Windows only.")
    query = "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); Get-CimInstance Win32_Process -Filter \"Name='java.exe' OR Name='javaw.exe'\" | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"
    try:
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", query],
                                capture_output=True, text=True, encoding="utf-8-sig", timeout=20, creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode != 0:raise ValueError("Process command-line lookup unavailable")
        processes = json.loads(result.stdout.strip()) if result.stdout.strip() else []
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        # The fallback cannot distinguish Minecraft from other Java software.
        # It permits an edit only when no Java executable is running at all.
        need(not java_processes_fallback(), "Java/Minecraft is running and detailed process inspection is unavailable. Close Minecraft/server and other Java programs before applying.")
        return
    if isinstance(processes, dict):
        processes = [processes]
    instance = str(path.parent.parent).replace("\\", "/").lower()
    for process in processes:
        command = process.get("CommandLine")
        need(isinstance(command, str) and command, "A Java process cannot be inspected. Close it before changing settings.")
        command = command.replace("\\", "/").lower()
        running = instance in command or any(v in command for v in ("net.minecraft", "minecraft.main", "forgeclient", "neoforge", "fabricmc.loader", "server.jar", "minecraft_server"))
        need(not running, "Minecraft/server appears to be running. Close it completely before applying settings.")


# Flush a temporary file and replace the selected configuration atomically.
def atomic_replace(path, data):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=path.name + ".amaryllis-", suffix=".tmp", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        need(temporary.read_bytes() == data, "Staged config failed verification.")
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


# Verify the preview, require a closed game, back up and commit settings.
def apply(change, closed_ack=False):
    need(closed_ack is True, "Ensure Minecraft is not running before applying.")
    # Re-plan so even an altered/stale Plan cannot write unrelated settings.
    current = plan(change.path, change.new)
    need(current.before == change.before and current.after == change.after, "Config has changed since preview. Please load settings again.")
    if change.before == change.after:
        return None
    assert_game_closed(change.path)
    need(change.path.read_bytes() == change.before, "Config changed during the process check. Preview again.")
    token = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    stem = change.path.name + ".amaryllis-" + token
    backup, report = change.path.with_name(stem + ".bak"), change.path.with_name(stem + ".json")
    with backup.open("xb") as handle:
        handle.write(change.before)
        handle.flush()
        os.fsync(handle.fileno())
    need(backup.read_bytes() == change.before, "Backup verification failed; original config was not replaced.")
    record = {"schemaVersion": 1, "fileName": change.path.name, "backupName": backup.name,
              "beforeSHA256": digest(change.before), "afterSHA256": digest(change.after), "old": change.old, "new": change.new}
    with report.open("x", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    need(change.path.read_bytes() == change.before, "Config has changed before replacement. Backup retained; preview again.")
    atomic_replace(change.path, change.after)
    need(change.path.read_bytes() == change.after, "Final config changed unexpectedly. Inspect the saved backup before proceeding.")
    return backup


# Verify settings-backup metadata and return its original file contents.
def backup_info(backup):
    backup = safe_file(backup)
    need(re.fullmatch(r"computercraft-server\.toml\.amaryllis-\d{8}-\d{6}-[0-9a-f]{8}\.bak", backup.name) is not None,
         "Choose a ComputerCraft backup created by this utility.")
    report = safe_file(backup.with_suffix(".json"))
    record = json.loads(report.read_text(encoding="utf-8"))
    need(record.get("schemaVersion") == 1 and record.get("fileName") == "computercraft-server.toml" and
         record.get("backupName") == backup.name, "Backup record does not match this config.")
    original = backup.read_bytes()
    need(digest(original) == record.get("beforeSHA256"), "Backup hash does not match; restore refused.")
    parse(original)
    target = safe_file(backup.parent / "computercraft-server.toml")
    need(digest(target.read_bytes()) in (record["beforeSHA256"], record["afterSHA256"]),
         "Settings changed after this backup. Restore would overwrite newer edits; merge manually instead.")
    return target, original, record


# Verify the closed-game state and restore a selected settings backup.
def restore(backup, closed_ack=False):
    need(closed_ack is True, "Confirm Minecraft/server is fully closed before restoring.")
    target, original, record = backup_info(backup)
    assert_game_closed(target)
    current = digest(target.read_bytes())
    need(current in (record["beforeSHA256"], record["afterSHA256"]), "Config changed during the process check; restore refused.")
    if current != record["beforeSHA256"]:
        atomic_replace(target, original)
    need(target.read_bytes() == original, "Restored config failed verification.")
    return target


# Parse the UI capacity entry into a bounded byte count.
def megabytes(text):
    try:
        value = Decimal(text.strip()) * 1_000_000
        need(value.is_finite() and value == value.to_integral_value(), "Enter whole bytes, with at most six decimal places in MB.")
        need(0 <= value <= INTEGER_MAX, "Capacity must fit ComputerCraft's signed integer setting.")
        return int(value)
    except (DecimalException, ValueError) as error:
        raise SettingsError("Enter a capacity in MB, for example 4 or 8.") from error


# Find ComputerCraft server configuration files near the selected ship.
def find_configs(source):
    selected = Path(source).expanduser().absolute()
    candidates = []
    for parent in (selected, *selected.parents):
        if parent.name == "computercraft":
            candidates.append(parent.parent / "serverconfig/computercraft-server.toml")
        if parent.name == "saves":
            candidates.append(parent.parent / "config/computercraft-server.toml")
    candidates.append(selected / "serverconfig/computercraft-server.toml")
    return list(dict.fromkeys(p for p in candidates if p.is_file()))


# Create the configuration selection, preview, apply and restore interface.
def open_dialog(parent=None, source=""):
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
    window = tk.Toplevel(parent) if parent is not None else tk.Tk()
    window.title("ComputerCraft settings")
    window.geometry("800x690");window.minsize(710, 640)
    if parent is not None:window.transient(parent)
    frame = ttk.Frame(window, padding=20);frame.pack(fill="both", expand=True)
    def hint(text, **spacing):
        label = ttk.Label(frame, text=text, wraplength=740, justify="left")
        label.pack(anchor="w", fill="x", **spacing)
        label.bind("<Configure>", lambda event: label.configure(wraplength=max(1, event.width)))
    ttk.Label(frame, text="ComputerCraft settings", font=("Segoe UI", 17, "bold")).pack(anchor="w")
    hint("Amaryllis's operation requires some \"additional\" capacity from CC. Ensure your device is capable of supporting the settings below, then apply them to your instance.", pady=(4, 12))
    candidates = find_configs(source) if source else []
    filename = tk.StringVar(value=str(candidates[0]) if len(candidates) == 1 else "")
    row = ttk.Frame(frame);row.pack(fill="x")
    ttk.Entry(row, textvariable=filename).pack(side="left", fill="x", expand=True)
    form = ttk.Frame(frame);form.pack(fill="x", pady=12)
    computer, disk, threads = tk.StringVar(), tk.StringVar(), tk.StringVar()
    for index, (label, variable) in enumerate((("Computer capacity (MB)", computer), ("Disk capacity (MB)", disk), ("Execution threads", threads))):
        ttk.Label(form, text=label).grid(row=index, column=0, sticky="w", pady=4)
        if variable is threads:
            ttk.Combobox(form, textvariable=variable, values=(1, 2, 4, 8, 16, 32, 64), width=17).grid(row=index, column=1, padx=12)
        else:
            ttk.Entry(form, textvariable=variable, width=20).grid(row=index, column=1, padx=12)
    hint("Capacities can only increase and must meet 4 MB.")
    hint("Threads start at the current value. Extra threads can affect lag and mod compatibility.", pady=(5, 10))
    closed = tk.BooleanVar(value=False)
    ttk.Checkbutton(frame, text="Minecraft / the server is fully closed", variable=closed).pack(anchor="w")
    preview = tk.Text(frame, height=13, wrap="word", state="disabled", font=("Segoe UI", 10))
    preview.pack(fill="both", expand=True, pady=12)
    state = {"plan": None, "loaded": None}
    def show(text):
        preview.configure(state="normal");preview.delete("1.0", "end");preview.insert("1.0", text);preview.configure(state="disabled")
    def failed(error):
        messagebox.showerror("ComputerCraft settings", str(error), parent=window)
    def invalidate(*args):
        state["plan"] = None
        apply_button.configure(state="disabled")
    # Read the chosen configuration and populate its editable settings.
    def load_file():
        try:
            path, raw, document, settings = load(filename.get())
            filename.set(str(path));state["loaded"] = (path, raw)
            computer.set(str(Decimal(max(CAPACITY_MIN, settings[KEYS[0]])) / 1_000_000))
            disk.set(str(Decimal(max(CAPACITY_MIN, settings[KEYS[1]])) / 1_000_000))
            threads.set(str(settings[KEYS[2]]))
            show(str(path) + "\n" + scope(path) + "\n\nLoaded current settings. Preview changes before applying.")
        except Exception as error:
            state["loaded"] = None;failed(error)
    def browse():
        value = filedialog.askopenfilename(parent=window, initialdir=str(candidates[0].parent) if candidates else None,
            filetypes=[("ComputerCraft server config", "computercraft-server.toml")])
        if value:
            filename.set(value);load_file()
    # Validate entered values and display the exact settings change.
    def make_preview():
        try:
            need(state["loaded"] is not None and Path(filename.get()) == state["loaded"][0], "Load the selected file first.")
            proposed = plan(filename.get(), {KEYS[0]: megabytes(computer.get()), KEYS[1]: megabytes(disk.get()), KEYS[2]: int(threads.get())})
            need(proposed.before == state["loaded"][1], "The file changed since loading. Load it again.")
            state["plan"] = proposed;show(proposed.preview())
            apply_button.configure(state="normal" if proposed.before != proposed.after else "disabled")
            if proposed.before == proposed.after:show(proposed.preview() + "\n\nNo changes are needed.")
        except Exception as error:invalidate();failed(error)
    # Review and apply the current configuration plan.
    def apply_file():
        try:
            need(state["plan"] is not None, "Preview the changes first.")
            need(closed.get(), "Close Minecraft/server fully and tick the confirmation first.")
            if not messagebox.askyesno("Apply these settings?", state["plan"].preview(), parent=window):return
            backup = apply(state["plan"], closed.get());invalidate()
            show("Settings saved and verified. Restart Minecraft/server.\n\nBackup:\n" + str(backup))
            state["loaded"] = None
        except Exception as error:invalidate();failed(error)
    # Select, review and restore a verified settings backup.
    def restore_file():
        try:
            need(closed.get(), "Close Minecraft/server fully and tick the confirmation first.")
            selected = filedialog.askopenfilename(parent=window, title="Choose an Amaryllis config backup", filetypes=[("Configuration backup", "*.bak")])
            if not selected:return
            target, data, record = backup_info(selected)
            if not messagebox.askyesno("Restore previous settings?", str(target) + "\n\nRestore the exact backed-up file? Previous capacity and thread limits will return.", parent=window):return
            restore(selected, closed.get());invalidate();state["loaded"] = None
            show("Previous settings restored and verified:\n" + str(target))
        except Exception as error:failed(error)
    buttons = ttk.Frame(frame);buttons.pack(fill="x")
    ttk.Button(row, text="Browse…", command=browse).pack(side="right", padx=(8, 0))
    ttk.Button(buttons, text="Load settings", command=load_file).pack(side="left")
    ttk.Button(buttons, text="Preview changes", command=make_preview).pack(side="left", padx=6)
    apply_button = ttk.Button(buttons, text="Apply settings", command=apply_file, state="disabled");apply_button.pack(side="left")
    ttk.Button(buttons, text="Restore backup…", command=restore_file).pack(side="left", padx=6)
    ttk.Button(buttons, text="Close", command=window.destroy).pack(side="right")
    for variable in (filename, computer, disk, threads):variable.trace_add("write", invalidate)
    if len(candidates) == 1:load_file()
    if parent is not None:window.grab_set()
    return window


if __name__ == "__main__":
    try:
        need(tomllib is not None, "Python 3.11 or newer with Tcl/Tk is required.")
        open_dialog().mainloop()
    except Exception as error:
        import sys
        if os.name == "nt":
            import ctypes
            ctypes.windll.user32.MessageBoxW(0, str(error), "ComputerCraft settings", 16)
        else:
            print(str(error), file=sys.stderr)
        sys.exit(1)
