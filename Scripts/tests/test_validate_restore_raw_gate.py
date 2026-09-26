from __future__ import annotations

import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import validate_release_assets as release_assets


class RestoreRawRecordGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.restore = self.read("App/MoneyUp/AppModelBackupRestore.swift")
        self.validator = self.read(
            "App/MoneyUp/RestoreCandidateIdentityValidator.swift"
        )
        self.store = self.read(
            "Sources/MoneyUpPersistence/EncryptedRecordStoreDiagnostics.swift"
        )
        self.connection = self.read(
            "Sources/MoneyUpPersistence/SQLCipherConnectionReceipts.swift"
        )

    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def errors(
        self,
        *,
        restore: str | None = None,
        validator: str | None = None,
        store: str | None = None,
        connection: str | None = None,
    ) -> list[str]:
        return release_assets.restore_raw_record_gate_errors(
            restore or self.restore,
            validator or self.validator,
            store or self.store,
            connection or self.connection,
        )

    def test_current_production_restore_gate_passes(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_rejects_raw_validation_moved_after_model_load(self) -> None:
        call = "try await RestoreCandidateValidator.validateStoredRecords("
        self.assertIn(call, self.restore)
        mutated = self.restore.replace(call, "try await validationModel.load(", 1)
        self.assertTrue(any("before AppModel load" in error for error in self.errors(
            restore=mutated
        )))

    def test_rejects_snapshot_materialization_in_candidate_path(self) -> None:
        marker = "let archiveMetadata = try await store.restorePortableArchive("
        self.assertIn(marker, self.restore)
        mutated = self.restore.replace(
            marker,
            "let rawSnapshot = try await store.snapshot()\n"
            "        let archiveMetadata = try await store.restorePortableArchive(",
            1,
        )
        self.assertTrue(any("must not materialize" in error for error in self.errors(
            restore=mutated
        )))

    def test_rejects_missing_cancellation_from_sql_cursor(self) -> None:
        marker = "try Task.checkCancellation()"
        reducer_start = self.connection.index("func reduceAllRecords<State>(")
        marker_index = self.connection.index(marker, reducer_start)
        mutated = (
            self.connection[:marker_index]
            + "_ = Task.isCancelled"
            + self.connection[marker_index + len(marker):]
        )
        self.assertTrue(any("Task.checkCancellation" in error for error in self.errors(
            connection=mutated
        )))


class RestoreDamagePolicyRuleTests(unittest.TestCase):
    """A restore keeps damaged rows set aside only as its preview showed."""

    SOURCES = {
        "preview": "App/MoneyUp/RestorePreview.swift",
        "preview_model": "App/MoneyUp/AppModelRestorePreview.swift",
        "restore": "App/MoneyUp/AppModelBackupRestore.swift",
        "recovery": "App/MoneyUp/AppModelRecovery.swift",
        "key_cliff": "App/MoneyUp/AppModelKeyCliffRecovery.swift",
        "validator": "App/MoneyUp/RestoreCandidateIdentityValidator.swift",
    }

    def setUp(self) -> None:
        self.sources = {
            name: (ROOT / path).read_text(encoding="utf-8")
            for name, path in self.SOURCES.items()
        }

    def errors(self, **mutated: str) -> list[str]:
        sources = {**self.sources, **mutated}
        return release_assets.restore_damage_policy_errors(
            sources["preview"],
            sources["preview_model"],
            sources["restore"],
            sources["recovery"],
            sources["key_cliff"],
            sources["validator"],
        )

    def mutate(self, name: str, old: str, new: str) -> str:
        source = self.sources[name]
        self.assertIn(old, source)
        mutated = source.replace(old, new, 1)
        self.assertNotEqual(mutated, source)
        return mutated

    def assertRejected(self, fragment: str, **mutated: str) -> None:
        errors = self.errors(**mutated)
        self.assertTrue(
            any(fragment in error for error in errors),
            f"expected {fragment!r} in {errors}",
        )

    def test_current_production_policy_passes(self) -> None:
        self.assertEqual(self.errors(), [])

    def test_rejects_a_preview_that_cannot_report_damage(self) -> None:
        self.assertRejected(
            "only the restore preview may report",
            preview_model=self.mutate("preview_model", "damage: .report", "damage: .reject"),
        )

    def test_rejects_a_commit_that_reports_instead_of_confirming(self) -> None:
        self.assertRejected(
            "only the restore preview may report",
            preview_model=self.mutate(
                "preview_model", "damage: ticket.damagePolicy", "damage: .report"
            ),
        )

    def test_rejects_a_key_cliff_manifest_without_the_confirmed_count(self) -> None:
        self.assertRejected(
            "setAsideRecordCount: damage.confirmedCount",
            key_cliff=self.mutate(
                "key_cliff",
                "setAsideRecordCount: damage.confirmedCount",
                "setAsideRecordCount: 0",
            ),
        )

    def test_rejects_a_resume_that_ignores_the_manifest_count(self) -> None:
        self.assertRejected(
            "resumed key-cliff install",
            key_cliff=self.mutate(
                "key_cliff",
                "let damage = try KeyCliffRecoveryTransaction.damagePolicy(for: databaseURL)",
                "let damage = RestoreDamagePolicy.report",
            ),
        )

    def test_rejects_a_load_that_stops_enforcing_the_count(self) -> None:
        self.assertRejected(
            "enforce the damage policy on load",
            recovery=self.mutate(
                "recovery", "damage.verifiedSetAsideCount(", "damage.hashValue.distance("
            ),
        )

    def test_rejects_skipping_the_relationship_gate_for_complete_books(self) -> None:
        self.assertRejected(
            "strict relationship gate",
            restore=self.mutate(
                "restore",
                "guard setAsideCount == 0 else { return nil }",
                "guard setAsideCount >= 0 else { return nil }",
            ),
        )

    def test_rejects_setting_aside_limit_violations(self) -> None:
        self.assertRejected(
            "!(error is AppModelError)",
            validator=self.mutate("validator", "&& !(error is AppModelError)", ""),
        )

    def test_rejects_relaxing_work_limits(self) -> None:
        self.assertRejected(
            "work limits must never relax",
            validator=self.mutate(
                "validator",
                "                    decoder: workDecoder,\n",
                "                    decoder: workDecoder,\n"
                "                    damage: damage,\n",
            ),
        )

    def test_rejects_setting_aside_a_damaged_profile(self) -> None:
        self.assertRejected(
            "restore damage policy is missing",
            preview=self.mutate(
                "preview", "case .profile, .journalEntryRevisions,", "case .journalEntryRevisions,"
            ),
        )


if __name__ == "__main__":
    unittest.main()
