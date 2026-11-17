import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class MigrationGateTests(unittest.TestCase):
    def test_public_inventory_still_blocks_apple_success(self):
        script = (ROOT / "core/Scripts/verify-macos.sh").read_text(encoding="utf-8")
        inventory = "python3 tests/public_command_contract.py"
        self.assertEqual(script.count(inventory), 1)
        self.assertLess(script.index("Scripts/embed-macos-core.sh"), script.index(inventory))
        self.assertLess(script.index(inventory), script.index('echo "macOS build and package checks passed'))
        self.assertIn("set -euo pipefail", script)
        self.assertNotRegex(script, r"public_command_contract\.py[^\n]*(?:\|\| true|; true)")

    def test_windows_core_failure_remains_a_required_step(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text(encoding="utf-8")
        self.assertLess(workflow.index("Verify self-contained MSI packaging"),
                        workflow.index("Verify Core ABI and C# SDK"))
        self.assertEqual(workflow.count("./scripts/verify-core.ps1 -Configuration release"), 1)
        self.assertNotIn("continue-on-error", workflow)

    def test_apple_migration_packages_do_not_publish(self):
        workflow = (ROOT / ".github/workflows/test.yml").read_text(encoding="utf-8")
        packaging = workflow.split("  apple-packaging:\n", 1)[1].split("\n  windows:\n", 1)[0]
        self.assertIn("github.ref == 'refs/heads/codex/monorepo-migration'", packaging)
        self.assertIn("platform: [macos, ios]", packaging)
        self.assertIn("./scripts/package-${PACKAGE_PLATFORM}.sh", packaging)
        self.assertIn("shasum -a 256 -c SHA256SUMS.txt", packaging)
        self.assertIn("shasum -a 256 -c SHA256SUMS-ios.txt", packaging)
        self.assertNotRegex(packaging, r"gh release|git (?:push|tag)|contents: write")

    def test_aggregate_requires_migration_packages(self):
        workflow = (ROOT / ".github/workflows/test.yml").read_text(encoding="utf-8")
        checks = workflow.split("  checks:\n", 1)[1]
        needs = re.search(r"needs: \[([^\]]+)\]", checks).group(1)
        self.assertIn("apple-packaging", needs)
        self.assertIn("assert results['apple-packaging']['result'] == 'success'", checks)
        self.assertIn("if: always()", checks)


if __name__ == "__main__":
    unittest.main()
