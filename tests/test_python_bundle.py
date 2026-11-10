"""The installer zip carries a Windows Python runtime that the helper launchers prefer."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import project

SPEC = importlib.util.spec_from_file_location("builder_python_bundle", project.ROOT / "disk-builder/builder.py")
builder = importlib.util.module_from_spec(SPEC)
sys.modules["builder_python_bundle"] = builder
SPEC.loader.exec_module(builder)


class PythonBundleTests(unittest.TestCase):
    def test_launchers_try_the_bundled_python_first(self):
        for script, gui in (("cc_settings.py", True), ("updater.py", False)):
            text = builder.helper_launcher(script, gui).decode()
            bundled = text.index("..\\python\\pythonw.exe")
            self.assertLess(bundled, text.index("pyw.exe"))
            self.assertIn('"%~dp0' + script + '"', text)
            self.assertTrue(text.startswith("@echo off\r\nsetlocal\r\n"))
            self.assertNotIn("\n", text.replace("\r\n", ""))
        self.assertNotIn("--gui", builder.helper_launcher("cc_settings.py", True).decode())

    def test_runtime_is_skipped_away_from_windows_python(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            result, note = builder.bundle_python_runtime(folder / "python", base=folder, windows=False)
            self.assertIsNone(result)
            self.assertIn("not bundled", note)
            self.assertFalse((folder / "python").exists())

    def test_runtime_copies_only_what_the_helpers_need(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "base"
            for name in ("python.exe", "pythonw.exe", "python312.dll", "vcruntime140.dll", "LICENSE.txt", "unins000.exe",
                         "DLLs/_tkinter.pyd", "DLLs/tcl86t.dll", "tcl/tcl8.6/init.tcl", "Lib/os.py", "Lib/test/test_x.py",
                         "Lib/site-packages/pkg.py", "Lib/__pycache__/os.pyc", "libs/python312.lib", "Scripts/pip.exe"):
                (base / name).parent.mkdir(parents=True, exist_ok=True)
                (base / name).write_bytes(b"x")
            ok = mock.Mock(returncode=0, stderr=b"")
            with mock.patch.object(builder.subprocess, "run", return_value=ok) as run:
                result, note = builder.bundle_python_runtime(Path(folder) / "python", base=base, windows=True)
            self.assertEqual(result, Path(folder) / "python")
            self.assertIn("bundled", note)
            self.assertIn("tkinter", run.call_args.args[0][-1])
            found = {p.relative_to(result).as_posix() for p in result.rglob("*") if p.is_file()}
            self.assertEqual(found, {"python.exe", "pythonw.exe", "python312.dll", "vcruntime140.dll", "LICENSE.txt",
                                     "DLLs/_tkinter.pyd", "DLLs/tcl86t.dll", "tcl/tcl8.6/init.tcl", "Lib/os.py"})

    def test_failed_tk_check_removes_the_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "base"
            for name in ("python.exe", "tcl/init.tcl"):
                (base / name).parent.mkdir(parents=True, exist_ok=True)
                (base / name).write_bytes(b"x")
            bad = mock.Mock(returncode=1, stderr=b"No module named tkinter")
            with mock.patch.object(builder.subprocess, "run", return_value=bad):
                result, note = builder.bundle_python_runtime(Path(folder) / "python", base=base, windows=True)
            self.assertIsNone(result)
            self.assertIn("tkinter", note)
            self.assertFalse((Path(folder) / "python").exists())


if __name__ == "__main__":
    unittest.main()
