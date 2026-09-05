from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import validate_launch_safety as launch_safety


class LaunchSafetyValidatorTests(unittest.TestCase):
    fixture_paths = (
        "project.yml",
        "App/MoneyUp/AppModelDependencies.swift",
        "App/MoneyUp/AppModelLifecycle.swift",
        "App/MoneyUp/MoneyUpApp.swift",
        "App/MoneyUp/AppModelKeyCliffRecovery.swift",
        "App/MoneyUp/DatabaseKeyStore.swift",
        "App/MoneyUp/LockedCaptureStore.swift",
        "Tests/MoneyUpAppTests/DatabaseStoreOpenerTests.swift",
    )

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        repository = SCRIPTS.parent
        for relative in self.fixture_paths:
            self.write(relative, (repository / relative).read_text(encoding="utf-8"))

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write(self, relative: str, content: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def mutate(self, relative: str, old: str, new: str) -> None:
        path = self.root / relative
        source = path.read_text(encoding="utf-8")
        self.assertIn(old, source)
        path.write_text(source.replace(old, new, 1), encoding="utf-8")

    def test_current_production_boundary_passes(self) -> None:
        self.assertEqual(launch_safety.validate(self.root), [])

    def test_rejects_database_open_without_detached_task(self) -> None:
        self.mutate(
            "App/MoneyUp/AppModelDependencies.swift",
            "return try await Task.detached(priority: .userInitiated)",
            "return try await Task(priority: .userInitiated)",
        )
        errors = launch_safety.validate(self.root)
        self.assertTrue(any("detached database opener" in error for error in errors))

    def test_rejects_direct_authenticated_key_load_in_lifecycle(self) -> None:
        self.mutate(
            "App/MoneyUp/AppModelLifecycle.swift",
            "func start() async -> Bool {",
            "func start() async -> Bool {\n"
            "        _ = try? DatabaseKeyStore.loadOrCreateKey(\n"
            "            databaseURL: Self.databaseURL()\n"
            "        )",
        )
        errors = launch_safety.validate(self.root)
        self.assertTrue(any("synchronous launch work" in error for error in errors))
        self.assertTrue(any("exactly one production call site" in error for error in errors))

    def test_rejects_synchronous_erase_tombstone_read(self) -> None:
        self.mutate(
            "App/MoneyUp/AppModelDependencies.swift",
            "return try await Task.detached(priority: .userInitiated)",
            "return try await Task(priority: .userInitiated)",
        )
        self.mutate(
            "App/MoneyUp/AppModelDependencies.swift",
            "return try await Task.detached(priority: .userInitiated)",
            "return try await Task(priority: .userInitiated)",
        )
        errors = launch_safety.validate(self.root)
        self.assertTrue(any("launch tombstone read" in error for error in errors))

    def test_rejects_unreviewed_keychain_query(self) -> None:
        self.write(
            "App/MoneyUp/UnreviewedKeychainRead.swift",
            "import Security\nfunc unsafeRead() { SecItemCopyMatching([:] as CFDictionary, nil) }\n",
        )
        errors = launch_safety.validate(self.root)
        self.assertTrue(any("SecItemCopyMatching inventory drifted" in error for error in errors))

    def test_rejects_removed_executable_thread_regression(self) -> None:
        self.mutate(
            "Tests/MoneyUpAppTests/DatabaseStoreOpenerTests.swift",
            "testAuthenticatedKeyAndSQLCipherOpenNeverRunOnMainThread",
            "testDatabaseOpen",
        )
        errors = launch_safety.validate(self.root)
        self.assertTrue(any("executable regression coverage" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
