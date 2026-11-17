import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ci_paths import classify_paths


class PathSelectionTests(unittest.TestCase):
    def test_documentation_only(self):
        self.assertEqual(classify_paths(["README.md", "core/docs/audit.md", "core/docs/validation/test.log"]),
                         {"core": False, "apple": False, "windows": False})

    def test_core_change_checks_all_consumers(self):
        self.assertEqual(classify_paths(["core/bindings/apple/OcPlayerCore/Package.swift"]),
                         {"core": True, "apple": True, "windows": True})

    def test_command_inventory_is_not_documentation_only(self):
        self.assertTrue(all(classify_paths(["core/docs/public-command-inventory.json"]).values()))

    def test_apple_change(self):
        self.assertEqual(classify_paths(["apps/apple/Config/Erika.version"]),
                         {"core": False, "apple": True, "windows": False})

    def test_windows_change(self):
        self.assertEqual(classify_paths(["apps/windows/Directory.Build.props"]),
                         {"core": False, "apple": False, "windows": True})

    def test_shared_workflow_checks_all_platforms(self):
        self.assertTrue(all(classify_paths([".github/workflows/test.yml"]).values()))


if __name__ == "__main__":
    unittest.main()
