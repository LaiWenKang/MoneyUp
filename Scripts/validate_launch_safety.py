#!/usr/bin/env python3
"""Prevent synchronous Keychain/SQLCipher work on MoneyUp's launch actor."""

from __future__ import annotations

import sys
from pathlib import Path

from validate_accessible_errors import mask_comments_and_strings


ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = Path("App/MoneyUp/AppModelDependencies.swift")
LIFECYCLE = Path("App/MoneyUp/AppModelLifecycle.swift")
TEST = Path("Tests/MoneyUpAppTests/DatabaseStoreOpenerTests.swift")


def read(root: Path, relative: Path, errors: list[str]) -> str:
    try:
        return (root / relative).read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"cannot read {relative}: {error}")
        return ""


def between(source: str, start: str, end: str) -> str:
    start_index = source.find(start)
    if start_index < 0:
        return ""
    end_index = source.find(end, start_index + len(start))
    if end_index < 0:
        return source[start_index:]
    return source[start_index:end_index]


def require_all(
    source: str,
    fragments: tuple[str, ...],
    context: str,
    errors: list[str],
) -> None:
    for fragment in fragments:
        if fragment not in source:
            errors.append(f"{context} is missing {fragment}")


def validate(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    dependencies = mask_comments_and_strings(read(root, DEPENDENCIES, errors))
    lifecycle = mask_comments_and_strings(read(root, LIFECYCLE, errors))
    test_source = mask_comments_and_strings(read(root, TEST, errors))
    project = read(root, Path("project.yml"), errors)

    production = between(
        dependencies,
        "static let production: DatabaseStoreOpener = make(",
        "static func make(",
    )
    require_all(
        production,
        (
            "keyLoader:",
            "DatabaseKeyStore.loadOrCreateKey(databaseURL: databaseURL)",
            "storeFactory:",
            "EncryptedRecordStore(databaseURL: databaseURL, key: key)",
        ),
        "production database opener wiring",
        errors,
    )

    factory = between(
        dependencies,
        "static func make(",
        "static let productionWithKey:",
    )
    require_all(
        factory,
        (
            "keyLoader: @escaping DatabaseKeyLoader",
            "storeFactory: @escaping EncryptedDatabaseStoreFactory",
            "return try await Task.detached(priority: .userInitiated)",
            "var key = try keyLoader(databaseURL)",
            "defer { key.resetBytes(in: 0..<key.count) }",
            "store: try storeFactory(databaseURL, key)",
            "}.value",
        ),
        "detached database opener factory",
        errors,
    )

    erase_access = between(
        dependencies,
        "func isPendingWithoutBlockingLaunch()",
        "static let production = DataEraseIntentAccess(",
    )
    require_all(
        erase_access,
        (
            "let read = isPending",
            "return try await Task.detached(priority: .userInitiated)",
            "try read()",
            "}.value",
        ),
        "detached launch tombstone read",
        errors,
    )
    require_all(
        lifecycle,
        (
            "let dataEraseInspection = await inspectDataEraseIntent()",
            ".isPendingWithoutBlockingLaunch()",
            "try await openAndFinishStartupIncludingKeyCliffRecovery(",
        ),
        "AppModel launch sequence",
        errors,
    )

    app_root = root / "App" / "MoneyUp"
    key_load_sites = 0
    keychain_sites: dict[str, int] = {}
    if not app_root.is_dir():
        errors.append("App/MoneyUp source directory is missing")
    else:
        for path in app_root.rglob("*.swift"):
            masked = mask_comments_and_strings(path.read_text(encoding="utf-8"))
            key_load_sites += masked.count("DatabaseKeyStore.loadOrCreateKey(")
            count = masked.count("SecItemCopyMatching(")
            if count:
                keychain_sites[path.name] = count
    if key_load_sites != 1:
        errors.append(
            "authenticated database-key loading must have exactly one "
            f"production call site, found {key_load_sites}"
        )
    expected_keychain_sites = {
        "DatabaseKeyStore.swift": 2,
        "LockedCaptureStore.swift": 2,
    }
    if keychain_sites != expected_keychain_sites:
        errors.append(
            "SecItemCopyMatching inventory drifted: expected "
            f"{expected_keychain_sites}, found {keychain_sites}"
        )

    forbidden_launch_fragments = (
        "DatabaseKeyStore.loadOrCreateKey(",
        "SecItemCopyMatching(",
        "EncryptedRecordStore(",
    )
    for relative in (
        Path("App/MoneyUp/AppModelLifecycle.swift"),
        Path("App/MoneyUp/MoneyUpApp.swift"),
        Path("App/MoneyUp/AppModelKeyCliffRecovery.swift"),
    ):
        source = mask_comments_and_strings(read(root, relative, errors))
        for fragment in forbidden_launch_fragments:
            if fragment in source:
                errors.append(f"{relative} performs synchronous launch work: {fragment}")

    require_all(
        test_source,
        (
            "testAuthenticatedKeyAndSQLCipherOpenNeverRunOnMainThread",
            "testEraseTombstoneReadNeverRunsOnMainThreadDuringLaunch",
            "Thread.isMainThread",
            "onMainThread: false",
        ),
        "launch-safety executable regression coverage",
        errors,
    )
    if "DEBUG_INFORMATION_FORMAT: dwarf-with-dsym" not in project:
        errors.append("release builds must retain dSYM generation for symbolication")
    return errors


def main() -> None:
    errors = validate()
    if errors:
        for error in errors:
            print(f"launch-safety violation: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(
        "Validated detached launch Keychain/SQLCipher access, dSYM output, "
        "and executable main-thread regressions"
    )


if __name__ == "__main__":
    main()
