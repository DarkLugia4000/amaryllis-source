"""Every navigator settings page reaches GENERAL through BACK, whatever its group is named."""
import re
import unittest

import project
from tests import test_runtime_bundling as support


class SettingsNavigationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ui = (project.ROOT / "source/library/packages/navigation/ui.lua").read_text(encoding="utf-8")
        core = "".join((project.ROOT / "source/core/avionics" / name).read_text(encoding="utf-8")
                       for name in ("flight.lua", "input_tuning.lua"))
        block = re.search(r"local SETTINGS_PAGES=\{.*?\} -- end SETTINGS_PAGES", cls.ui, re.S).group(0)
        lua, _ = support.native_runtime()
        lua.execute(block.replace("local SETTINGS_PAGES", "SETTINGS_PAGES"))
        table = lua.globals().SETTINGS_PAGES
        cls.pages = {key: dict(value.items()) for key, value in table.items()}
        cls.views = set(re.findall(r'view\("([A-Z ]+)"\)', cls.ui))
        cls.groups = set(re.findall(r'field\("([A-Z ]+)"', core)) | {"PROPULSION"}

    def parent(self, page):
        return self.pages.get(page, {}).get("parent", "GENERAL")

    def test_every_page_returns_to_general_without_loops(self):
        for page in sorted(self.views | self.groups | set(self.pages)):
            seen, current = [], page
            while current != "GENERAL":
                self.assertNotIn(current, seen, f"BACK loop from {page}: {seen}")
                seen.append(current)
                current = self.parent(current)
            self.assertLessEqual(len(seen), 4, f"{page} takes {len(seen)} BACK presses")

    def test_parents_are_real_pages(self):
        for page, info in self.pages.items():
            parent = info.get("parent")
            self.assertTrue(parent == "GENERAL" or parent in self.views, f"{page} has unknown parent {parent}")

    def test_cockpit_input_pages_return_to_cockpit_inputs(self):
        for group in ("SEL HEADING", "SEL THROTTLE", "INPUT ALTITUDE", "STRAFE SETTINGS"):
            self.assertIn(group, self.groups)
            self.assertIn(group, self.views)
            self.assertEqual(self.parent(group), "TARGET")

    def test_back_uses_the_table(self):
        self.assertIn('view((SETTINGS_PAGES[sub] or {}).parent or "GENERAL")', self.ui)
        self.assertNotIn('sub:match("^INPUT")', self.ui)
        self.assertNotIn('sub:match("^PROP")', self.ui)


if __name__ == "__main__":
    unittest.main()
