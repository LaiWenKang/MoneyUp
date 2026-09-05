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


if __name__ == "__main__":
    unittest.main()
