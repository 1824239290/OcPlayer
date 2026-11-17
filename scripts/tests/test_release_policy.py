import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleasePolicyTests(unittest.TestCase):
    def test_apple_packaging_uses_the_tested_commit(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("commit: ${{ steps.release-source.outputs.commit }}", workflow)
        self.assertEqual(workflow.count("ref: ${{ needs.tests.outputs.commit }}"), 2)
        self.assertNotIn('git checkout "$RELEASE_TAG"', workflow)

    def test_windows_releases_keep_apple_latest_unchanged(self):
        workflow = (ROOT / ".github/workflows/windows-release.yml").read_text(encoding="utf-8")
        commands = re.findall(r'^\s*gh release (?:create|edit) .+$', workflow, re.MULTILINE)
        self.assertEqual(len(commands), 2)
        for command in commands:
            self.assertIn("--latest=false", command)


if __name__ == "__main__":
    unittest.main()
