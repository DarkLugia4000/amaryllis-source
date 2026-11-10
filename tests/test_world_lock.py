"""Live updates: the updater works while the world is open and leaves the game's session.lock alone."""
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


if __name__ == "__main__":
    unittest.main()
