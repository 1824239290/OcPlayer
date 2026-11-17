import importlib.util
import json
import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("monorepo_verifier", ROOT / "scripts/verify-monorepo.py")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class SwiftMigrationAuditTests(unittest.TestCase):
    def setUp(self):
        self.original = "100644 blob " + "a" * 40
        self.repaired = "100644 blob " + "b" * 40
        self.binding = "100644 blob " + "c" * 40
        self.manifest = {
            "validationCommit": "frozen-migration",
            "sources": {"apple": {"commit": "apple-baseline"}, "core": {"commit": "core-baseline"}},
            "swiftBinding": {
                "originalApplePath": "Packages/OcPlayerCore",
                "canonicalPath": "core/bindings/apple/OcPlayerCore",
                "identicalContentFiles": 1,
            },
        }
        self.follow_up = {
            "validationCommit": "frozen-migration",
            "authorization": "User requested the CI fixes",
            "swiftRepairs": [{
                "path": "apps/apple/App/Parser.swift",
                "before": self.original,
                "after": self.repaired,
                "reason": "Keep extensionless season and episode tokens",
            }],
        }
        self.current = {
            "apps/apple/App/Parser.swift": self.original,
            "core/bindings/apple/OcPlayerCore/Sources/Binding.swift": self.binding,
        }
        trees = {
            "apple-baseline": {
                "App/Parser.swift": self.original,
                "Packages/OcPlayerCore/Sources/Binding.swift": self.binding,
            },
            "core-baseline": {"bindings/apple/OcPlayerCore/Sources/Binding.swift": self.binding},
            "frozen-migration": dict(self.current),
        }
        self.addCleanup(patch.stopall)
        patch.object(VERIFIER, "tree_entries", side_effect=trees.__getitem__).start()
        patch.object(VERIFIER, "index_entries", side_effect=lambda: self.current).start()

    def test_frozen_snapshot_remains_unchanged_after_a_current_repair(self):
        self.current["apps/apple/App/Parser.swift"] = self.repaired
        result = VERIFIER.verify_unchanged_swift(self.manifest, revision="frozen-migration")
        self.assertEqual(result, {"unchangedAppleSwiftFiles": 1, "deduplicatedBindingFiles": 1})

    def test_only_the_exact_audited_repair_is_accepted(self):
        self.current["apps/apple/App/Parser.swift"] = self.repaired
        repairs = VERIFIER.approved_swift_repairs(self.manifest, self.follow_up)
        result = VERIFIER.verify_unchanged_swift(self.manifest, repairs=repairs)
        self.assertEqual(result["unchangedAppleSwiftFiles"], 0)
        self.assertEqual(result["deduplicatedBindingFiles"], 1)
        self.assertEqual(result["authorizedAppleSwiftRepairs"], self.follow_up["swiftRepairs"])

    def test_undeclared_change_is_rejected(self):
        self.current["apps/apple/App/Parser.swift"] = self.repaired
        with self.assertRaisesRegex(AssertionError, "exact audited repair"):
            VERIFIER.verify_unchanged_swift(self.manifest)

    def test_additional_content_change_is_rejected(self):
        self.current["apps/apple/App/Parser.swift"] = "100644 blob " + "d" * 40
        repairs = VERIFIER.approved_swift_repairs(self.manifest, self.follow_up)
        with self.assertRaisesRegex(AssertionError, "exact audited repair"):
            VERIFIER.verify_unchanged_swift(self.manifest, repairs=repairs)

    def test_original_source_metadata_cannot_be_rewritten(self):
        self.current["apps/apple/App/Parser.swift"] = self.repaired
        self.follow_up["swiftRepairs"][0]["before"] = self.binding
        repairs = VERIFIER.approved_swift_repairs(self.manifest, self.follow_up)
        with self.assertRaisesRegex(AssertionError, "original Apple source"):
            VERIFIER.verify_unchanged_swift(self.manifest, repairs=repairs)

    def test_binding_content_is_still_frozen(self):
        self.current["core/bindings/apple/OcPlayerCore/Sources/Binding.swift"] = self.repaired
        with self.assertRaisesRegex(AssertionError, "Canonical binding changed"):
            VERIFIER.verify_unchanged_swift(self.manifest)

    def test_nonexistent_source_cannot_be_whitelisted(self):
        self.follow_up["swiftRepairs"][0]["path"] = "apps/apple/App/Unknown.swift"
        repairs = VERIFIER.approved_swift_repairs(self.manifest, self.follow_up)
        with self.assertRaisesRegex(AssertionError, "outside the preserved Apple Swift"):
            VERIFIER.verify_unchanged_swift(self.manifest, repairs=repairs)

    def test_repairs_cannot_change_the_freeze_revision_or_file_modes(self):
        for field, value in [("validationCommit", "new-baseline"), ("after", "100755 blob " + "b" * 40)]:
            follow_up = deepcopy(self.follow_up)
            if field == "validationCommit":
                follow_up[field] = value
            else:
                follow_up["swiftRepairs"][0][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                VERIFIER.approved_swift_repairs(self.manifest, follow_up)

    def test_duplicate_and_out_of_scope_repairs_are_rejected(self):
        duplicate = deepcopy(self.follow_up)
        duplicate["swiftRepairs"] *= 2
        with self.assertRaisesRegex(AssertionError, "Duplicate Swift repair"):
            VERIFIER.approved_swift_repairs(self.manifest, duplicate)
        for path in ["core/bindings/apple/OcPlayerCore/Sources/Binding.swift",
                     "apps/apple/Packages/OcPlayerCore/Sources/Binding.swift",
                     "apps/apple/Packages/DanmakuKit/Package.swift"]:
            follow_up = deepcopy(self.follow_up)
            follow_up["swiftRepairs"][0]["path"] = path
            with self.subTest(path=path), self.assertRaises(AssertionError):
                VERIFIER.approved_swift_repairs(self.manifest, follow_up)

    def test_repository_audit_retains_the_original_validation_commit(self):
        manifest = json.loads((ROOT / "docs/migration/source-manifest.json").read_text(encoding="utf-8"))
        follow_up = json.loads((ROOT / "docs/migration/follow-up-repairs.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["validationCommit"], "6be4a6f380e77aa951fe47c4b0eeb9fb82265316")
        self.assertEqual(len(VERIFIER.approved_swift_repairs(manifest, follow_up)), 2)


if __name__ == "__main__":
    unittest.main()
