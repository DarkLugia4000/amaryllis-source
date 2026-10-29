"""Repository portability and current-source packaging checks."""
import unittest
import project
from tests.test_runtime_bundling import LuaRuntime

class RepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """Collect current maintained sources from a synthetic local fixture."""
        cls.builder = project.builder_module()
        cls.source = cls.builder.collect(project.fixture())
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

    def test_current_payload_count_and_fixture_boundary(self):
        """Keep the compact installed layout and fixture writes inside the cache."""
        self.assertEqual(len(self.packed["payload"]), 5)
        self.assertEqual(len(self.packed["state"]), 3)
        for role, count in self.packed["bundleCounts"].items():
            if role not in ("core", "state"):
                self.assertEqual(count["after"], 3)
        self.assertTrue(project.fixture().resolve().is_relative_to((project.ROOT / ".cache").resolve()))

if __name__ == "__main__":
    unittest.main()
