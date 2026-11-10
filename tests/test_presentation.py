"""Core console generation from the package console: Panel Home entry and remote fleet status."""
import unittest
import project


class Rejected(Exception):
    """Raised by the test require hook for unsupported source shapes."""


def require(condition, message):
    """Mirror the builder's require contract with a test-local exception."""
    if not condition:
        raise Rejected(message)


class PresentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.presentation = project.builder_module().presentation
        cls.files = {"/" + k: v for k, v in project.source_files().items()}
        assets = project.HOME / "assets"
        cls.panel = (assets / "panel-console.lua").read_bytes()
        cls.remote = (assets / "remote-panel.lua").read_bytes()

    def payload(self, console=None):
        """Return a core payload whose console starts from the package console, as in collection."""
        payload = dict(self.files)
        payload["/avionics/common/console.lua"] = console or payload["/packages/common/console.lua"]
        payload["/avionics/remote_client.lua"] = self.remote
        return payload

    def transform(self, payload):
        """Apply the core console generators in builder order."""
        self.presentation.apply_console(payload, self.panel, require)
        self.presentation.apply_remote(payload, self.remote, require)
        return payload

    def test_package_console_transforms_to_maintained_core_console(self):
        result = self.transform(self.payload())
        self.assertEqual(result["/avionics/common/console.lua"], self.files["/avionics/common/console.lua"])

    def test_unsupported_console_shape_rejected(self):
        console = self.files["/packages/common/console.lua"].replace(b"    local mode = arguments[1]\n", b"    local mode = nil\n")
        with self.assertRaisesRegex(Rejected, "Panel Home"):
            self.presentation.apply_console(self.payload(console), self.panel, require)

    def test_package_console_keeps_intended_differences(self):
        package = self.files["/packages/common/console.lua"]
        core = self.files["/avionics/common/console.lua"]
        self.assertNotIn(b'require("avionics.panel_console")', package)
        self.assertEqual(core.count(b'require("avionics.panel_console")'), 2)

    def test_unsupported_remote_callback_rejected(self):
        console = self.files["/packages/common/console.lua"].replace(b"        return {lines=result}\n", b"        return result\n")
        with self.assertRaisesRegex(Rejected, "remote status callback"):
            self.transform(self.payload(console))


if __name__ == "__main__":
    unittest.main()
