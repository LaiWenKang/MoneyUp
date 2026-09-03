#!/usr/bin/env python3
"""Fail CI when release-critical privacy, localization, or icon assets drift."""

from __future__ import annotations

import csv
import hashlib
import json
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

from validate_architecture_fitness import scan_swift, type_declarations


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_LANGUAGES = {"en", "zh-Hans"}
SQLCIPHER_REVISION = "f879fffaaa3ad3541a77830daad4a28726dfa927"
CHECKOUT_ACTION_REVISION = "3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ARTIFACT_REVISION = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
XCODEGEN_VERSION = "2.46.0"
XCODEGEN_SHA256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
CI_XCODE_VERSION = "16.4"
CI_XCODE_BUILD = "16F6"
CI_IPHONESIMULATOR_SDK_VERSION = "18.5"
CI_PERFORMANCE_DEVICE_NAME = "iPhone 16 Pro"
CI_PERFORMANCE_RUNTIME_IDENTIFIER = (
    "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
)
SWIFT_TEST_TARGETS = (
    ("MoneyUpCoreTests", "core"),
    ("MoneyUpPersistenceTests", "persistence"),
    ("MoneyUpIntelligenceTests", "intelligence"),
    ("MoneyUpAppTests", "app-target"),
    ("MoneyUpPerformanceTests", "performance-target"),
)
EXPECTED_PERFORMANCE_XCTESTS = (
    "testFixtureContract",
    "testMeasureStoreOpenCloseBaseline",
    "testMeasureStoreLoadBaseline",
    "testMeasureSaveBaseline",
    "testMeasureHistoryPageAndQueryBaseline",
    "testMeasureExportBaseline",
    "testMeasureArchiveBaseline",
    "testMeasureRestoreBaseline",
    "testMeasureReceiptTextProcessingBaseline",
    "testMeasureProjectionBaseline",
    "testMeasureIntelligenceBaseline",
)
RELEASE_XCODE_VERSION = "26.6"
RELEASE_XCODE_BUILD = "17F113"
RELEASE_IPHONEOS_SDK_VERSION = "26.5"
TESTFLIGHT_CONTROL_ISSUE = 23
PRINTF_PLACEHOLDER = re.compile(
    r"%(?:(\d+)\$)?[-+# 0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|L|z|j|t|q)?([@diouxXfFeEgGaAcCsSp])"
)
LOCALIZED_STRING_REFERENCE = re.compile(
    r'(?:String\(localized:|AppLocalization\.string\()\s*"([^"]+)"'
)
SWIFTUI_LOCALIZED_REFERENCE = re.compile(
    r'(?:Text|Button|Label|Picker|Toggle|SecureField|TextField|Section|'
    r'NavigationLink|DisclosureGroup|LabeledContent|confirmationDialog|'
    r'navigationTitle|alert)\(\s*'
    r'"([A-Za-z0-9_.-]+)"'
)
ACCESSIBILITY_LOCALIZED_REFERENCE = re.compile(
    r'\.accessibility(?:Label|Hint)\(\s*"([A-Za-z0-9_.-]+)"'
)
HARD_CODED_CHART_DIMENSION = re.compile(r'\.value\(\s*"[^"]+"')


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def swift_without_comments(source: str) -> str:
    """Remove comments so invariant tokens cannot be satisfied by dead prose."""
    return re.sub(
        r"//[^\n]*|/\*.*?\*/",
        lambda match: "\n" * match.group(0).count("\n"),
        source,
        flags=re.DOTALL,
    )


def source_section(
    source: str,
    start: str,
    end: str,
) -> str:
    start_index = source.find(start)
    end_index = source.find(end, start_index + len(start))
    if start_index < 0 or end_index < 0:
        return ""
    return source[start_index:end_index]


def ordered_fragments_are_present(
    source: str,
    fragments: tuple[str, ...],
) -> bool:
    cursor = 0
    for fragment in fragments:
        position = source.find(fragment, cursor)
        if position < 0:
            return False
        cursor = position + len(fragment)
    return True


def security_recovery_invariant_violations(
    sources: dict[str, str],
) -> list[str]:
    """Return release-boundary violations for actual and mutated fixtures."""
    violations: list[str] = []
    key_cliff = swift_without_comments(sources["key_cliff"])
    key_store = swift_without_comments(sources["key_store"])
    transaction = swift_without_comments(sources["transaction"])
    restore = swift_without_comments(sources["restore"])
    data_safety = swift_without_comments(sources["data_safety"])
    portable = swift_without_comments(sources["portable"])
    widget_projection = swift_without_comments(sources["widget_projection"])
    widget_derived = swift_without_comments(sources["widget_derived"])
    intelligence = swift_without_comments(sources["intelligence"])
    lifecycle = swift_without_comments(sources["lifecycle"])
    ledger_validation = swift_without_comments(sources["ledger_validation"])
    tests = sources["tests"]
    accessible_tests = sources["accessible_tests"]

    recovery = source_section(
        key_cliff,
        "func recoverMissingDeviceBoundKey",
        "private func buildKeyCliffCandidate",
    )
    commit = source_section(
        key_cliff,
        "private func commitKeyCliffCandidate",
        "private func rollbackFailedKeyCliffCommit",
    )
    resume = source_section(
        key_cliff,
        "func openAndFinishStartupIncludingKeyCliffRecovery",
        "func recoverMissingDeviceBoundKey",
    )
    install = source_section(
        transaction,
        "static func installCandidate",
        "static func restoreOriginal",
    )
    completion = source_section(
        transaction,
        "static func complete(",
        "static func removeAll",
    )
    markerless_scavenge = source_section(
        transaction,
        "static func scavengeUncommittedCandidate",
        "static func prepareCandidateDirectory",
    )
    recovery_key_store = source_section(
        key_store,
        "static func storeRecoveryKey",
        "static func deleteKey",
    )
    mapped_key_error = source_section(
        key_store,
        "static func mappedError",
        "\n}",
    )
    for label, body in (
        ("initial key-cliff restore", recovery),
        ("key-cliff commit", commit),
        ("key-cliff startup resume", resume),
        ("key-cliff filesystem install", install),
        ("recovery-key store", recovery_key_store),
    ):
        if not body:
            violations.append(f"{label} function boundary is missing")

    if recovery_key_store and not ordered_fragments_are_present(
        recovery_key_store,
        (
            "requireDevicePasscodeForRecovery(",
            "storeKey(key, loadExistingOnDuplicate: false)",
        ),
    ):
        violations.append(
            "recovery-key storage must recheck passcode availability at the "
            "final Keychain boundary"
        )
    if "errSecPasscodeRequired" in key_store:
        violations.append(
            "device-key errors must not depend on a newer-SDK-only OSStatus"
        )
    if not all(token in mapped_key_error for token in (
        "errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed",
        "return .authenticationCancelled",
        "return .unexpectedStatus(status)",
    )):
        violations.append(
            "device-key errors must retain stable supported-SDK classification"
        )

    if recovery and (
        recovery.count("requireEmptyLockedCaptureInbox()") != 1
        or recovery.count("keyCliffHasSurvivingCiphertext(at: databaseURL)") != 1
        or not ordered_fragments_are_present(
            recovery,
            (
                "requireEmptyLockedCaptureInbox()",
                "keyCliffHasSurvivingCiphertext(at: databaseURL)",
                "RestoreArchiveStaging.verifiedCommitCopy",
                "keyCliffRecoveryKeyAccess.generate()",
                "prepareCandidateDirectory(",
                "buildKeyCliffCandidate(",
                "KeyCliffRecoveryTransaction.publishManifest",
                "commitKeyCliffCandidate(",
            ),
        )
    ):
        violations.append(
            "key-cliff restore must prove empty inbox and surviving ciphertext "
            "before ticket verification, key generation, and manifest mutation"
        )

    commit_order = (
        "keyCliffRecoveryKeyAccess.store",
        "KeyCliffRecoveryTransaction.installCandidate",
        "openDatabaseStoreWithKey(",
        "load(from: openedStore, mode: .restoreValidation)",
        "validateLoadedStartupBook",
        "requireEmptyLockedCaptureInbox()",
        ".afterKeyCliffValidationBeforeCompletion",
        "KeyCliffRecoveryTransaction.complete",
        "startupFailureKind = nil",
        "publishValidatedStartupBookAfterIrreversibleRecovery",
    )
    if commit and (
        commit.count("requireEmptyLockedCaptureInbox()") != 1
        or not ordered_fragments_are_present(commit, commit_order)
    ):
        violations.append(
            "key-cliff commit must recheck the inbox and complete the marker "
            "before nonthrowing authoritative publication"
        )

    resume_order = (
        "KeyCliffRecoveryTransaction.installCandidate",
        "openDatabaseStore(databaseURL)",
        "load(from: openedStore, mode: .restoreValidation)",
        "validateLoadedStartupBook",
        "requireEmptyLockedCaptureInbox()",
        ".afterKeyCliffValidationBeforeCompletion",
        "KeyCliffRecoveryTransaction.complete",
        "startupFailureKind = nil",
        "publishValidatedStartupBookAfterIrreversibleRecovery",
    )
    if resume and (
        resume.count("requireEmptyLockedCaptureInbox()") != 1
        or not ordered_fragments_are_present(resume, resume_order)
    ):
        violations.append(
            "key-cliff startup must install before opening, recheck the inbox, "
            "and complete before publication"
        )

    install_order = (
        "where manifest.originalArtifactMask",
        "moveItem(at: live, to: rollback)",
        "where manifest.candidateArtifactMask",
        "moveItem(at: candidate, to: live)",
    )
    if install and not ordered_fragments_are_present(install, install_order):
        violations.append(
            "key-cliff install must move every original artifact aside before "
            "moving any candidate artifact live"
        )

    completion_order = (
        "loadManifest(for: databaseURL)",
        "manifest.phase == .installing",
        "try removeCommitMarker(marker)",
        "try? cleanupMarkerlessDirectory(directory)",
    )
    if not completion or not ordered_fragments_are_present(
        completion,
        completion_order,
    ):
        violations.append(
            "key-cliff completion must atomically remove the installing marker "
            "before nonthrowing markerless-directory cleanup"
        )
    if completion and (
        completion.count("try removeCommitMarker(marker)") != 1
        or completion.count("try? cleanupMarkerlessDirectory(directory)") != 1
    ):
        violations.append(
            "key-cliff completion must have one throwing marker unlink and one "
            "best-effort post-commit cleanup"
        )

    if not markerless_scavenge or not ordered_fragments_are_present(
        markerless_scavenge,
        (
            "!hasPendingManifest(for: databaseURL)",
            "try? cleanupMarkerlessDirectory(directory)",
        ),
    ):
        violations.append(
            "markerless key-cliff residue cleanup must be exact and best-effort"
        )
    if "keyCliffRecoveryResidueScavenger(databaseURL)" not in resume:
        violations.append(
            "startup must attempt nonthrowing markerless residue scavenging"
        )

    for regression in (
        "testKeyCliffCompletionMarkerFailurePreservesRollbackAuthority",
        "testMarkerlessCompletionResidueScavengesAfterEveryPartialCleanup",
        "testStartupPublishesCandidateAfterPersistentMarkerlessCleanupFailure",
    ):
        if regression not in tests:
            violations.append(f"key-cliff completion regression is missing {regression}")

    debug_pattern = re.compile(
        r"(?ms)^[ \t]*#if[ \t]+DEBUG[ \t]*\n"
        r"(?P<body>.*?)^[ \t]*#endif[ \t]*$"
    )
    debug_blocks = list(debug_pattern.finditer(restore))
    if len(debug_blocks) != 1:
        violations.append("raw restore APIs must have one exact #if DEBUG block")
        production_restore = restore
    else:
        debug_body = debug_blocks[0].group("body")
        if re.search(r"(?m)^[ \t]*#(?:if|elseif|else)\b", debug_body):
            violations.append("raw restore DEBUG block must not expose another branch")
        for required in (
            "func restoreEncryptedBackup(_ data: Data",
            "func restoreEncryptedBackup(\n        from archiveURL",
        ):
            if required not in debug_body:
                violations.append(f"raw restore DEBUG block is missing {required}")
        production_restore = (
            restore[:debug_blocks[0].start()] + restore[debug_blocks[0].end():]
        )

    production_app = dict(sources["app_sources"])
    production_app["AppModelBackupRestore.swift"] = production_restore
    production_text = "\n".join(production_app.values())
    if len(re.findall(
        r"\brestoreEncryptedBackupAfterVerifiedTicket\b",
        production_text,
    )) != 2:
        violations.append(
            "verified restore primitive must have only its definition and "
            "reviewed-ticket call in production"
        )
    if production_text.count("RestorePreviewTicket(") != 1:
        violations.append("production must construct restore tickets only in preview")
    if len(re.findall(
        r"\bmodel\s*\.\s*restoreEncryptedBackup\s*\(\s*ticket\b",
        production_text,
    )) != 1:
        violations.append(
            "production must commit a restore ticket only from the confirmed UI"
        )

    refresh_intelligence = source_section(
        intelligence,
        "func refreshIntelligence()",
        "func waitForCurrentIntelligenceRefresh",
    )
    for label, source in (
        ("widget projection", widget_projection),
        ("unavailable widget projection", widget_derived),
        ("intelligence refresh", refresh_intelligence),
    ):
        if "!isBookReplacementInProgress" not in source:
            violations.append(f"{label} must reject cross-book publication")

    deep_link = source_section(
        lifecycle,
        "func handleDeepLink",
        "func routeLockSafeRequestIfPossible",
    )
    if not ordered_fragments_are_present(
        deep_link,
        (
            "guard !isBookReplacementInProgress",
            "startupFailureKind != .missingDeviceBoundKey",
            "hasPendingKeyCliffRecoveryTransaction()",
            "requestedQuickLogMode = mode",
        ),
    ):
        violations.append(
            "deep-link intent must be denied before routing across replacement"
        )

    replacement_finish = source_section(
        ledger_validation,
        "func finishBookReplacementMutation",
        "\n}",
    )
    if not ordered_fragments_are_present(
        replacement_finish,
        (
            "isBookReplacementInProgress = false",
            "case .ready:",
            "refreshBudgetWidgetSnapshot()",
            "refreshIntelligence()",
            "finishExclusiveDataLifecycleMutation()",
        ),
    ):
        violations.append(
            "replacement finish must clear suppression, publish one ready-book "
            "widget/intelligence state, then release lifecycle ownership"
        )

    if (
        "initialState: model.state" not in data_safety
        or "wasKeyCliffRecovery:" in data_safety
        or "testRestoreSuccessRouteFollowsTheSurvivingHierarchy"
        not in accessible_tests
    ):
        violations.append(
            "restore success routing must follow the surviving root hierarchy"
        )

    writer_order = (
        "replaceItemAt(",
        "options: [.usingNewMetadataOnly]",
        "try fileManager.setAttributes(",
        "[.posixPermissions: 0o600]",
        "committed = true",
    )
    if not ordered_fragments_are_present(portable, writer_order):
        violations.append(
            "archive replacement must adopt new private metadata and chmod "
            "the committed destination before success"
        )
    private_copy_test = source_section(
        tests,
        "func testRestoreArchivePrivateCopiesAreOwnerReadOnly",
        "func testStartupScavengesEveryDeterministicRestoreArchive",
    )
    if not all(token in private_copy_test for token in (
        "old-broad-destination",
        ".posixPermissions: 0o644",
        "posixPermissions(at: exportURL), 0o600",
        "unownedWritingSibling",
    )):
        violations.append(
            "private archive regression must replace a broad destination while "
            "preserving an unowned sibling"
        )

    restore_commit = source_section(
        restore,
        "func restoreEncryptedBackupAfterVerifiedTicket",
        "func beginRestoreMutation",
    )
    if not ordered_fragments_are_present(
        restore_commit,
        (
            "makeRestoreRollbackArchive(",
            "defer {",
            "removeRestoreTemporaryArchive(",
            "restoreRollbackDirectoryURL",
            ".beforeRestoreCommit",
        ),
    ):
        violations.append(
            "normal restore must own rollback-directory cleanup from creation "
            "through every success or rollback exit"
        )
    for test_name in (
        "testRestorePreviewReportsExactReplacementSummaryAndCommitsTicket",
        "testCancellationAfterRestoreCommitRecoversJournalIndexesAndBalance",
    ):
        test_body = source_section(tests, f"func {test_name}", "\n    @MainActor")
        if "restoreRollbackDirectoryURL" not in test_body:
            violations.append(f"rollback cleanup regression is missing {test_name}")

    for test_name in (
        "testStartupResumesKeyCliffCandidateBeforePublishingBook",
        "testStartupRejectsCaptureBeforeCompletingKeyCliffCandidate",
        "testKeyCliffFinalInboxRecheckRollsBackLateCaptureBeforePublication",
        "testKeyCliffPostCompletionInboxFailureKeepsAuthoritativeBookRetryable",
    ):
        if test_name not in tests:
            violations.append(f"key-cliff boundary regression is missing {test_name}")

    post_complete = source_section(
        sources["startup_publication"],
        "func publishValidatedStartupBookAfterIrreversibleRecovery",
        "func finishLoadedStartup",
    )
    ordinary_startup = sources["startup_publication"].split(
        "func finishLoadedStartup",
        1,
    )[-1]
    if (
        "async throws" in post_complete
        or not all(token in post_complete for token in (
            "catch",
            'recordRecoveryIssue("locked_captures/promotion-unavailable")',
            "state = .ready",
        ))
    ):
        violations.append(
            "post-complete capture publication must be nonthrowing, ready, "
            "and expose only the stable redacted retry code"
        )
    if (
        production_text.count(
            "publishValidatedStartupBookAfterIrreversibleRecovery"
        ) != 3
        or "try await publishValidatedStartupBook(" not in ordinary_startup
        or "publishValidatedStartupBookAfterIrreversibleRecovery"
        in ordinary_startup
        or "testOrdinaryStartupDoesNotSwallowUnexpectedCaptureFailure"
        not in tests
    ):
        violations.append(
            "ordinary startup must retain strict capture failures while only "
            "the two post-complete key-cliff sites use nonthrowing publication"
        )

    return violations


def replace_in_source_section(
    source: str,
    start: str,
    end: str,
    old: str,
    new: str,
) -> str:
    start_index = source.find(start)
    end_index = source.find(end, start_index + len(start))
    if start_index < 0 or end_index < 0:
        return source
    section = source[start_index:end_index]
    replaced = section.replace(old, new, 1)
    return source[:start_index] + replaced + source[end_index:]


def validate_security_recovery_mutation_gate() -> None:
    app_root = ROOT / "App" / "MoneyUp"
    sources = {
        "key_cliff": (
            app_root / "AppModelKeyCliffRecovery.swift"
        ).read_text(encoding="utf-8"),
        "key_store": (
            app_root / "DatabaseKeyStore.swift"
        ).read_text(encoding="utf-8"),
        "transaction": (
            app_root / "KeyCliffRecoveryTransaction.swift"
        ).read_text(encoding="utf-8"),
        "restore": (
            app_root / "AppModelBackupRestore.swift"
        ).read_text(encoding="utf-8"),
        "startup_publication": (
            app_root / "AppModelStartupPublication.swift"
        ).read_text(encoding="utf-8"),
        "data_safety": (
            app_root / "DataSafetyView.swift"
        ).read_text(encoding="utf-8"),
        "portable": (
            ROOT / "Sources/MoneyUpPersistence/PortableArchiveV2Validation.swift"
        ).read_text(encoding="utf-8"),
        "widget_projection": (
            app_root / "AppModelJournalProjection.swift"
        ).read_text(encoding="utf-8"),
        "widget_derived": (
            app_root / "AppModelJournalDerivedState.swift"
        ).read_text(encoding="utf-8"),
        "intelligence": (
            app_root / "AppModelIntelligence.swift"
        ).read_text(encoding="utf-8"),
        "lifecycle": (
            app_root / "AppModelLifecycle.swift"
        ).read_text(encoding="utf-8"),
        "ledger_validation": (
            app_root / "AppModelLedgerValidation.swift"
        ).read_text(encoding="utf-8"),
        "tests": (
            ROOT / "Tests/MoneyUpAppTests/AppModelTests.swift"
        ).read_text(encoding="utf-8"),
        "accessible_tests": (
            ROOT / "Tests/MoneyUpAppTests/AccessibleErrorPresentationTests.swift"
        ).read_text(encoding="utf-8"),
        "app_sources": {
            path.name: path.read_text(encoding="utf-8")
            for path in app_root.rglob("*.swift")
        },
    }
    actual = security_recovery_invariant_violations(sources)
    if actual:
        fail("security recovery invariant: " + "; ".join(actual))

    mutations: list[tuple[str, dict[str, str]]] = []

    def mutated(name: str, key: str, old: str, new: str) -> None:
        fixture = dict(sources)
        fixture[key] = sources[key].replace(old, new, 1)
        if key in {
            "data_safety",
            "intelligence",
            "lifecycle",
            "ledger_validation",
            "restore",
            "startup_publication",
            "widget_projection",
        }:
            app_sources = dict(sources["app_sources"])
            filename = {
                "data_safety": "DataSafetyView.swift",
                "intelligence": "AppModelIntelligence.swift",
                "lifecycle": "AppModelLifecycle.swift",
                "ledger_validation": "AppModelLedgerValidation.swift",
                "restore": "AppModelBackupRestore.swift",
                "startup_publication": "AppModelStartupPublication.swift",
                "widget_projection": "AppModelJournalProjection.swift",
            }[key]
            app_sources[filename] = fixture[key]
            fixture["app_sources"] = app_sources
        mutations.append((name, fixture))

    fixture = dict(sources)
    fixture["key_store"] = replace_in_source_section(
        sources["key_store"],
        "static func storeRecoveryKey",
        "static func deleteKey",
        "try requireDevicePasscodeForRecovery(",
        "try recoveryPasscodeRecheckWasRemoved(",
    )
    mutations.append(("final recovery-key passcode recheck", fixture))

    fixture = dict(sources)
    fixture["key_store"] = (
        sources["key_store"] + "\nlet errSecPasscodeRequired = unsupported\n"
    )
    mutations.append(("newer-SDK-only passcode status", fixture))

    for name, start, end, token in (
        (
            "initial inbox",
            "func recoverMissingDeviceBoundKey",
            "private func buildKeyCliffCandidate",
            "requireEmptyLockedCaptureInbox()",
        ),
        (
            "surviving ciphertext",
            "func recoverMissingDeviceBoundKey",
            "private func buildKeyCliffCandidate",
            "keyCliffHasSurvivingCiphertext(at: databaseURL)",
        ),
        (
            "final commit inbox",
            "private func commitKeyCliffCandidate",
            "private func rollbackFailedKeyCliffCommit",
            "requireEmptyLockedCaptureInbox()",
        ),
        (
            "resume inbox",
            "func openAndFinishStartupIncludingKeyCliffRecovery",
            "func recoverMissingDeviceBoundKey",
            "requireEmptyLockedCaptureInbox()",
        ),
    ):
        fixture = dict(sources)
        fixture["key_cliff"] = replace_in_source_section(
            sources["key_cliff"],
            start,
            end,
            token,
            "removedSecurityBoundary()",
        )
        mutations.append((name, fixture))

    fixture = dict(sources)
    resume = source_section(
        sources["key_cliff"],
        "func openAndFinishStartupIncludingKeyCliffRecovery",
        "func recoverMissingDeviceBoundKey",
    )
    swapped = resume.replace(
        "KeyCliffRecoveryTransaction.installCandidate",
        "__OPEN_DATABASE__",
        1,
    ).replace(
        "openDatabaseStore(databaseURL)",
        "KeyCliffRecoveryTransaction.installCandidate",
        1,
    ).replace("__OPEN_DATABASE__", "openDatabaseStore(databaseURL)", 1)
    fixture["key_cliff"] = sources["key_cliff"].replace(resume, swapped, 1)
    mutations.append(("install before open", fixture))

    fixture = dict(sources)
    fixture["transaction"] = sources["transaction"].replace(
        "manifest.originalArtifactMask",
        "__CANDIDATE_MASK__",
        1,
    ).replace(
        "manifest.candidateArtifactMask",
        "manifest.originalArtifactMask",
        1,
    ).replace("__CANDIDATE_MASK__", "manifest.candidateArtifactMask", 1)
    mutations.append(("original before candidate", fixture))

    fixture = dict(sources)
    fixture["transaction"] = replace_in_source_section(
        sources["transaction"],
        "static func complete(",
        "static func removeAll",
        "try removeCommitMarker(marker)",
        "try cleanupMarkerlessDirectory(directory)",
    )
    mutations.append(("marker-first key-cliff completion", fixture))

    fixture = dict(sources)
    completion = source_section(
        sources["transaction"],
        "static func complete(",
        "static func removeAll",
    )
    swapped = completion.replace(
        "try removeCommitMarker(marker)",
        "__REMOVE_MARKER__",
        1,
    ).replace(
        "try? cleanupMarkerlessDirectory(directory)",
        "try? removeCommitMarker(marker)",
        1,
    ).replace(
        "__REMOVE_MARKER__",
        "try cleanupMarkerlessDirectory(directory)",
        1,
    )
    fixture["transaction"] = sources["transaction"].replace(
        completion,
        swapped,
        1,
    )
    mutations.append(("cleanup before key-cliff marker", fixture))

    fixture = dict(sources)
    fixture["transaction"] = replace_in_source_section(
        sources["transaction"],
        "static func complete(",
        "static func removeAll",
        "try? cleanupMarkerlessDirectory(directory)",
        "try cleanupMarkerlessDirectory(directory)",
    )
    mutations.append(("throwing post-marker cleanup", fixture))

    fixture = dict(sources)
    fixture["transaction"] = replace_in_source_section(
        sources["transaction"],
        "static func scavengeUncommittedCandidate",
        "static func prepareCandidateDirectory",
        "!hasPendingManifest(for: databaseURL)",
        "hasPendingManifest(for: databaseURL)",
    )
    mutations.append(("markerless completion scavenger", fixture))

    fixture = dict(sources)
    fixture["transaction"] = replace_in_source_section(
        sources["transaction"],
        "static func scavengeUncommittedCandidate",
        "static func prepareCandidateDirectory",
        "try? cleanupMarkerlessDirectory(directory)",
        "try! cleanupMarkerlessDirectory(directory)",
    )
    mutations.append(("nonthrowing markerless residue cleanup", fixture))

    fixture = dict(sources)
    fixture["key_cliff"] = replace_in_source_section(
        sources["key_cliff"],
        "func openAndFinishStartupIncludingKeyCliffRecovery",
        "func recoverMissingDeviceBoundKey",
        "keyCliffRecoveryResidueScavenger(databaseURL)",
        "markerlessResidueWasIgnored(databaseURL)",
    )
    mutations.append(("startup markerless residue attempt", fixture))

    mutated(
        "exact DEBUG condition",
        "restore",
        "#if DEBUG",
        "#if DEBUG || !DEBUG",
    )
    mutated(
        "no DEBUG else",
        "restore",
        "    #endif",
        "    #else\n    func releaseBypass() {}\n    #endif",
    )

    fixture = dict(sources)
    app_sources = dict(sources["app_sources"])
    app_sources["DataSafetyView.swift"] += (
        "\nlet leakedPrimitive = "
        "AppModel.restoreEncryptedBackupAfterVerifiedTicket\n"
    )
    fixture["app_sources"] = app_sources
    mutations.append(("primitive method reference", fixture))

    fixture = dict(sources)
    app_sources = dict(sources["app_sources"])
    app_sources["DataSafetyView.swift"] += "\nlet forged = RestorePreviewTicket(\n"
    fixture["app_sources"] = app_sources
    mutations.append(("ticket construction", fixture))

    mutated(
        "cross-book widget guard",
        "widget_projection",
        "!isBookReplacementInProgress",
        "true",
    )
    mutated(
        "cross-book unavailable widget guard",
        "widget_derived",
        "!isBookReplacementInProgress",
        "true",
    )
    mutated(
        "cross-book intelligence guard",
        "intelligence",
        "!isBookReplacementInProgress",
        "true",
    )
    mutated(
        "cross-book deep-link guard",
        "lifecycle",
        "guard !isBookReplacementInProgress",
        "guard true",
    )
    mutated(
        "replacement finish publication order",
        "ledger_validation",
        "isBookReplacementInProgress = false",
        "replacementSuppressionWasNotCleared = true",
    )
    mutated(
        "generic recovery success route",
        "data_safety",
        "initialState: model.state",
        "wasKeyCliffRecovery: true",
    )
    mutated(
        "replacement metadata",
        "portable",
        "options: [.usingNewMetadataOnly]",
        "options: []",
    )
    mutated(
        "final archive chmod",
        "portable",
        "try fileManager.setAttributes(",
        "try fileManager.attributesOfItem(",
    )
    mutated(
        "rollback defer cleanup",
        "restore",
        "restoreRollbackDirectoryURL\n            )\n        }\n\n        await lifecycleHooks",
        "restoreCommitArchiveURL\n            )\n        }\n\n        await lifecycleHooks",
    )
    mutated(
        "ordinary startup strict publication",
        "startup_publication",
        "try await publishValidatedStartupBook(\n            in: openedStore",
        "await publishValidatedStartupBookAfterIrreversibleRecovery(\n"
        "            in: openedStore",
    )

    for name, fixture in mutations:
        if not security_recovery_invariant_violations(fixture):
            fail(f"security recovery validator mutation escaped: {name}")
    print(
        f"Validated security recovery invariants against {len(mutations)} "
        "adversarial mutations"
    )


def logical_book_boundary_invariant_violations(
    sources: dict[str, str],
) -> list[str]:
    """Return violations of the same-store logical-book read boundary."""
    violations: list[str] = []
    swift = {
        key: swift_without_comments(value)
        for key, value in sources.items()
        if key not in {"tests", "intelligence_tests"}
    }

    def section(key: str, start: str, end: str) -> str:
        return source_section(swift[key], start, end)

    token = section(
        "domain",
        "struct LogicalBookReadToken",
        "func beginLogicalBookRead",
    )
    begin_read = section(
        "domain",
        "func beginLogicalBookRead",
        "func ownsLogicalBookRead",
    )
    owns_read = section(
        "domain",
        "func ownsLogicalBookRead",
        "func requireLogicalBookRead",
    )
    finish_read = section(
        "domain",
        "func finishLogicalBookRead",
        "func requireStore",
    )
    if not all(fragment in token for fragment in (
        "let storeGeneration: Int",
        "let logicalBookRevision: UInt64",
    )):
        violations.append(
            "logical-book token must bind physical store and logical revision"
        )
    if not ordered_fragments_are_present(
        begin_read,
        (
            "guard !isBookReplacementInProgress",
            "let store",
            "storeGeneration: storeGeneration",
            "logicalBookRevision: logicalBookRevision",
        ),
    ):
        violations.append(
            "logical-book read admission must reject replacement and bind one store"
        )
    if not all(fragment in owns_read for fragment in (
        "!isBookReplacementInProgress",
        "token.storeGeneration == storeGeneration",
        "token.logicalBookRevision == logicalBookRevision",
        "store != nil",
    )):
        violations.append(
            "logical-book post-await authority must revalidate both revisions"
        )
    if not ordered_fragments_are_present(
        finish_read,
        (
            "lifecycleHooks.checkpoint(.afterBookScopedReadBeforeReturn)",
            "requireLogicalBookRead(token)",
        ),
    ):
        violations.append(
            "logical-book return helper must pause then revalidate authority"
        )

    model = swift["model"]
    if "var logicalBookRevision: UInt64 = 0" not in model:
        violations.append("AppModel is missing the monotonic logical-book revision")

    begin_restore = section(
        "restore",
        "func beginRestoreMutation()",
        "private func makeRestoreRollbackArchive",
    )
    restore_order = (
        "isBookReplacementInProgress = true",
        "logicalBookRevision &+= 1",
        "isWorking = true",
        "goalMutationBarrierClosed = true",
        "await waitForGoalMutationDrain()",
    )
    revision_prefix = begin_restore.split("logicalBookRevision &+= 1", 1)[0]
    if (
        not ordered_fragments_are_present(begin_restore, restore_order)
        or "await " in revision_prefix
    ):
        violations.append(
            "normal restore must revoke old reads synchronously before its first await"
        )

    finish_replacement = section(
        "ledger_validation",
        "func finishBookReplacementMutation",
        "\n}",
    )
    if not ordered_fragments_are_present(
        finish_replacement,
        (
            "isBookReplacementInProgress = false",
            "logicalBookRevision &+= 1",
            "switch state",
            "finishExclusiveDataLifecycleMutation()",
        ),
    ):
        violations.append(
            "replacement finish must publish a new readable revision before release"
        )
    clear_decoded = section(
        "validation",
        "func clearDecodedState()",
        "func validateLoadedBook",
    )
    if "logicalBookRevision &+= 1" not in clear_decoded:
        violations.append("clearing decoded state must revoke every retained read")

    def require_read_contract(
        label: str,
        key: str,
        start: str,
        end: str,
        direct_checks: int = 1,
    ) -> None:
        body = section(key, start, end)
        if not body:
            violations.append(f"{label} function boundary is missing")
            return
        if "beginLogicalBookRead()" not in body:
            violations.append(f"{label} must capture logical-book authority at entry")
        if body.count("requireLogicalBookRead(") < direct_checks:
            violations.append(
                f"{label} must revalidate immediately after every result-bearing await"
            )
        if "finishLogicalBookRead(" not in body:
            violations.append(f"{label} must revalidate before returning its result")

    for args in (
        (
            "history page",
            "history",
            "func historyPage(",
            "private func historyCursor",
            2,
        ),
        (
            "history summary",
            "history",
            "func historySummary(",
            "func calendarEntries",
            2,
        ),
        (
            "calendar entries",
            "history",
            "func calendarEntries",
            "func journalPostingEvents",
            0,
        ),
        (
            "journal posting events",
            "history",
            "func journalPostingEvents",
            "func matchingEntries",
            1,
        ),
        (
            "schedule matching entries",
            "history",
            "func matchingEntries",
            "func journalEntries",
            0,
        ),
        (
            "journal entry paging",
            "history",
            "func journalEntries",
            "func journalSnapshot",
            1,
        ),
        (
            "journal snapshot",
            "history",
            "func journalSnapshot",
            "func recordHistoryDecodeIssues",
            1,
        ),
        (
            "capture suggestion",
            "intelligence",
            "func indexedCaptureSuggestion",
            "func intelligenceHistoryEntries",
            1,
        ),
        (
            "intelligence history",
            "intelligence",
            "func intelligenceHistoryEntries",
            "private func date(fromIntelligenceDay",
            2,
        ),
        (
            "month-end projection",
            "projection",
            "func monthEndProjectionResult",
            "private func monthEndProjectionContext",
            1,
        ),
        (
            "budget suggestions",
            "budget",
            "func budgetLimitSuggestionsResult",
            "func applyBudgetSuggestions",
            1,
        ),
        (
            "receipt attachment",
            "attachment",
            "func receiptAttachment",
            "func deleteReceiptAttachment",
            1,
        ),
    ):
        require_read_contract(*args)

    receipt_analysis = section(
        "lifecycle",
        "func receiptAnalysis",
        "static func boundedReceiptLines",
    )
    if (
        "beginLogicalBookRead()" not in receipt_analysis
        or receipt_analysis.count("ownsLogicalBookRead(") < 2
        or "finishLogicalBookRead(" not in receipt_analysis
    ):
        violations.append(
            "receipt OCR must retain logical authority across recognition and parsing"
        )

    history_view = swift["history_view"]
    if not all(fragment in history_view for fragment in (
        "let logicalBookRevision: UInt64",
        "logicalBookRevision: model.logicalBookRevision",
        ".onChange(of: model.logicalBookRevision)",
        "selectedEntry = nil",
    )):
        violations.append("History retained paging state must be revision-scoped")

    calendar_view = swift["calendar_view"]
    if not all(fragment in calendar_view for fragment in (
        "let logicalBookRevision: UInt64",
        "logicalBookRevision: model.logicalBookRevision",
        ".onChange(of: model.logicalBookRevision)",
        "let expectedRevision = model.logicalBookRevision",
        "expectedRevision == model.logicalBookRevision",
        "scheduleMatchCandidates = [:]",
    )):
        violations.append("Calendar actuals and match candidates must be revision-scoped")

    quick_draft = section(
        "quick_draft",
        "func reloadDraftForLogicalBookReplacement",
        "func applyDraft",
    )
    if not ordered_fragments_are_present(
        quick_draft,
        (
            "hasRestoredDraft = false",
            "cancelReceiptProcessing()",
            "amountText = \"\"",
            "accountID = nil",
            "sourceCaptureID = nil",
            "lastSavedEntryID = nil",
            "guard !model.isBookReplacementInProgress",
            "model.state == .ready",
            "model.quickLogDraft",
            "hasRestoredDraft = true",
        ),
    ):
        violations.append(
            "Quick Log must revoke the old form and adopt only the published draft"
        )
    if not all(fragment in swift["quick_body"] for fragment in (
        ".onChange(of: model.logicalBookRevision)",
        "reloadDraftForLogicalBookReplacement()",
    )):
        violations.append("Quick Log must reload its persistent form on revision change")
    capture_view = section(
        "quick_capture",
        "func refreshCaptureSuggestions",
        "func cancelCaptureSuggestionLookup",
    )
    if not all(fragment in capture_view for fragment in (
        "let logicalBookRevision = model.logicalBookRevision",
        "logicalBookRevision == model.logicalBookRevision",
        "!model.isBookReplacementInProgress",
    )):
        violations.append("Quick Log capture suggestions must bind their launch revision")
    receipt_current = section(
        "quick_receipt",
        "func receiptScanIsCurrent",
        "func applyReceipt",
    )
    if not all(fragment in receipt_current for fragment in (
        "logicalBookRevision == model.logicalBookRevision",
        "!model.isBookReplacementInProgress",
        "model.state == .ready",
    )):
        violations.append("Quick Log receipt callbacks must bind their launch revision")

    attachment_view = swift["transaction_edit"]
    if not all(fragment in attachment_view for fragment in (
        ".onChange(of: model.logicalBookRevision)",
        "let logicalBookRevision = model.logicalBookRevision",
        "model.logicalBookRevision == logicalBookRevision",
        "!model.isBookReplacementInProgress",
    )):
        violations.append("receipt thumbnail publication must be revision-scoped")

    intelligence_history_view = swift["intelligence_history_view"]
    intelligence_view = swift["intelligence_view"]
    intelligence_projection_view = swift["intelligence_projection_view"]
    if not all(fragment in intelligence_history_view for fragment in (
        "let logicalBookRevision: UInt64",
        ".task(id: model.logicalBookRevision)",
        "revision == model.logicalBookRevision",
    )) or not all(fragment in intelligence_view for fragment in (
        ".onChange(of: model.logicalBookRevision)",
        "historySelection = nil",
        "scheduleSelection = nil",
        "logicalBookRevision: model.logicalBookRevision",
    )):
        violations.append("intelligence history routes must be revision-scoped")
    if not all(fragment in intelligence_projection_view for fragment in (
        ".task(id: model.logicalBookRevision)",
        "revision == model.logicalBookRevision",
        "!model.isBookReplacementInProgress",
    )):
        violations.append("intelligence projection view must reject stale publication")

    budget_patch = swift["budget"]
    budget_view = swift["budget_view"]
    if not all(fragment in budget_patch for fragment in (
        "let logicalBookRevision: UInt64",
        "expectedLogicalBookRevision == logicalBookRevision",
        "patch.logicalBookRevision == logicalBookRevision",
    )) or not all(fragment in budget_view for fragment in (
        "@State private var loadedLogicalBookRevision: UInt64?",
        ".task(id: model.logicalBookRevision)",
        ".onChange(of: model.logicalBookRevision)",
        "expectedLogicalBookRevision: loadedLogicalBookRevision",
    )):
        violations.append("budget suggestion apply and undo must bind the loaded book")

    data_safety = swift["data_safety"]
    if not ordered_fragments_are_present(
        data_safety,
        (
            ".onChange(of: model.logicalBookRevision)",
            "inventory = nil",
            "inventoryDocument = PrivacySafeDataInventoryDocument()",
        ),
    ):
        violations.append("post-restore Data Safety inventory must discard old counts")

    combined_tests = sources["tests"] + sources["intelligence_tests"]
    for regression in (
        "testLogicalBookRevisionRejectsPausedHistoryReadAcrossNormalRestore",
        "testLogicalBookRevisionRejectsPausedIntelligenceReadsAcrossNormalRestore",
        "testLogicalBookRevisionRejectsStaleBudgetPatch",
    ):
        if regression not in combined_tests:
            violations.append(f"logical-book regression is missing {regression}")

    return violations


def validate_logical_book_boundary_mutation_gate() -> None:
    app_root = ROOT / "App" / "MoneyUp"
    source_files = {
        "model": "AppModel.swift",
        "restore": "AppModelBackupRestore.swift",
        "domain": "AppModelDomainValidation.swift",
        "ledger_validation": "AppModelLedgerValidation.swift",
        "validation": "AppModelValidation.swift",
        "history": "AppModelHistoryQueries.swift",
        "intelligence": "AppModelIntelligence.swift",
        "projection": "AppModelIntelligenceProjection.swift",
        "budget": "AppModelBudgetSuggestions.swift",
        "attachment": "AppModelJournalEditing.swift",
        "lifecycle": "AppModelLifecycle.swift",
        "history_view": "HistoryView.swift",
        "calendar_view": "CalendarView.swift",
        "quick_draft": "QuickLogEntryDraft.swift",
        "quick_body": "QuickLogEntryBody.swift",
        "quick_capture": "QuickLogEntryCaptureSuggestions.swift",
        "quick_receipt": "QuickLogEntryReceipt.swift",
        "transaction_edit": "TransactionEditBody.swift",
        "intelligence_history_view": "IntelligenceHistoryReviewView.swift",
        "intelligence_view": "IntelligenceView.swift",
        "intelligence_projection_view": "IntelligenceProjectionView.swift",
        "budget_view": "BudgetSuggestionReviewView.swift",
        "data_safety": "DataSafetyView.swift",
    }
    sources = {
        key: (app_root / filename).read_text(encoding="utf-8")
        for key, filename in source_files.items()
    }
    sources["tests"] = (
        ROOT / "Tests/MoneyUpAppTests/AppModelTests.swift"
    ).read_text(encoding="utf-8")
    sources["intelligence_tests"] = (
        ROOT / "Tests/MoneyUpAppTests/AppModelIntelligenceTests.swift"
    ).read_text(encoding="utf-8")

    actual = logical_book_boundary_invariant_violations(sources)
    if actual:
        fail("logical-book boundary invariant: " + "; ".join(actual))

    mutations: list[tuple[str, dict[str, str]]] = []

    def mutated(name: str, key: str, old: str, new: str) -> None:
        if old not in sources[key]:
            fail(f"logical-book mutation fixture is stale: {name}")
        fixture = dict(sources)
        fixture[key] = sources[key].replace(old, new, 1)
        mutations.append((name, fixture))

    mutated(
        "token logical revision",
        "domain",
        "let logicalBookRevision: UInt64",
        "let unrelatedRevision: UInt64",
    )
    mutated(
        "read admission replacement guard",
        "domain",
        "guard !isBookReplacementInProgress,",
        "guard true,",
    )
    mutated(
        "post-await logical revision",
        "domain",
        "token.logicalBookRevision == logicalBookRevision",
        "true",
    )
    mutated(
        "return helper ordering",
        "domain",
        "await lifecycleHooks.checkpoint(.afterBookScopedReadBeforeReturn)\n"
        "        try requireLogicalBookRead(token)",
        "try requireLogicalBookRead(token)\n"
        "        await lifecycleHooks.checkpoint(.afterBookScopedReadBeforeReturn)",
    )
    restore_revision = "logicalBookRevision &+= 1"
    restore_suspension = "await waitForGoalMutationDrain()"
    if (
        restore_revision not in sources["restore"]
        or restore_suspension not in sources["restore"]
    ):
        fail("logical-book mutation fixture is stale: restore revocation")
    fixture = dict(sources)
    fixture["restore"] = sources["restore"].replace(
        restore_revision,
        "logicalBookRevisionWasDeferred = true",
        1,
    ).replace(
        restore_suspension,
        restore_suspension + "\n        logicalBookRevision &+= 1",
        1,
    )
    mutations.append(("restore revocation after suspension", fixture))
    mutated(
        "replacement finish revision",
        "ledger_validation",
        "logicalBookRevision &+= 1",
        "replacementRevisionWasNotPublished = true",
    )
    mutated(
        "decoded-state revocation",
        "validation",
        "logicalBookRevision &+= 1",
        "decodedStateRevisionWasNotRevoked = true",
    )
    mutated(
        "history page post-await check",
        "history",
        "try requireLogicalBookRead(read.token)",
        "try Task.checkCancellation()",
    )
    history_summary = source_section(
        sources["history"],
        "func historySummary(",
        "func calendarEntries",
    )
    if not history_summary:
        fail("logical-book mutation fixture is stale: history summary")
    mutated_summary = history_summary.replace(
        "try requireLogicalBookRead(read.token)",
        "try Task.checkCancellation()",
        1,
    )
    fixture = dict(sources)
    fixture["history"] = sources["history"].replace(
        history_summary,
        mutated_summary,
        1,
    )
    mutations.append(("history summary post-await check", fixture))
    mutated(
        "capture suggestion entry token",
        "intelligence",
        "let read = try? beginLogicalBookRead()",
        "let read = nil as (store: EncryptedRecordStore, "
        "token: LogicalBookReadToken)?",
    )
    intelligence_history = source_section(
        sources["intelligence"],
        "func intelligenceHistoryEntries",
        "private func date(fromIntelligenceDay",
    )
    if not intelligence_history:
        fail("logical-book mutation fixture is stale: intelligence history")
    fixture = dict(sources)
    fixture["intelligence"] = sources["intelligence"].replace(
        intelligence_history,
        intelligence_history.replace(
            "try requireLogicalBookRead(read.token)",
            "try Task.checkCancellation()",
            1,
        ),
        1,
    )
    mutations.append(("intelligence history post-await check", fixture))
    for name, key in (
        ("month-end projection post-await check", "projection"),
        ("budget suggestion post-await check", "budget"),
        ("receipt attachment post-await check", "attachment"),
    ):
        mutated(
            name,
            key,
            "try requireLogicalBookRead(read.token)",
            "try Task.checkCancellation()",
        )
    mutated(
        "Quick Log draft authority reset",
        "quick_draft",
        "hasRestoredDraft = false",
        "hasRestoredDraft = true",
    )
    mutated(
        "Quick Log undo identity reset",
        "quick_draft",
        "lastSavedEntryID = nil",
        "lastSavedEntryID = lastSavedEntryID",
    )
    mutated(
        "capture suggestion launch revision",
        "quick_capture",
        "logicalBookRevision == model.logicalBookRevision",
        "true",
    )
    mutated(
        "receipt callback launch revision",
        "quick_receipt",
        "logicalBookRevision == model.logicalBookRevision",
        "true",
    )
    mutated(
        "receipt thumbnail revision",
        "transaction_edit",
        "model.logicalBookRevision == logicalBookRevision",
        "true",
    )
    mutated(
        "History task identity revision",
        "history_view",
        "let logicalBookRevision: UInt64",
        "let staleBookRevision: UInt64",
    )
    mutated(
        "Calendar task identity revision",
        "calendar_view",
        "let logicalBookRevision: UInt64",
        "let staleBookRevision: UInt64",
    )
    mutated(
        "intelligence history selection revision",
        "intelligence_history_view",
        "let logicalBookRevision: UInt64",
        "let staleBookRevision: UInt64",
    )
    mutated(
        "budget apply revision",
        "budget",
        "expectedLogicalBookRevision == logicalBookRevision",
        "true",
    )
    mutated(
        "Data Safety inventory reset",
        "data_safety",
        "inventory = nil",
        "inventory = inventory",
    )
    for regression in (
        "testLogicalBookRevisionRejectsPausedHistoryReadAcrossNormalRestore",
        "testLogicalBookRevisionRejectsPausedIntelligenceReadsAcrossNormalRestore",
        "testLogicalBookRevisionRejectsStaleBudgetPatch",
    ):
        key = (
            "intelligence_tests"
            if regression in sources["intelligence_tests"]
            else "tests"
        )
        mutated(
            f"regression declaration {regression}",
            key,
            regression,
            "removedLogicalBookRegression",
        )

    for name, fixture in mutations:
        if not logical_book_boundary_invariant_violations(fixture):
            fail(f"logical-book boundary validator mutation escaped: {name}")
    print(
        f"Validated logical-book boundary against {len(mutations)} "
        "adversarial mutations"
    )


def chart_render_guard_errors(
    analysis_source: str,
    view_source: str,
    theme_source: str,
) -> list[str]:
    """Return violations that make effective chart contrast uncertifiable.

    The numerical palette checks prove contrast only when the rendered data
    geometry reaches the canvas at full opacity. Keep the source side closed:
    both charts must consume the reviewed semantic tokens directly, and no
    parent, helper, modifier, or alternate color construction may weaken them.
    """
    errors: list[str] = []

    def braced_block(
        source: str,
        start_token: str,
        label: str,
    ) -> str:
        try:
            start = source.index(start_token)
        except ValueError:
            errors.append(f"cannot locate the {label} declaration")
            return ""

        opening = source.find("{", start)
        if opening < 0:
            errors.append(f"cannot locate the {label} opening brace")
            return ""

        depth = 0
        index = opening
        state = "code"
        block_comment_depth = 0
        while index < len(source):
            current = source[index]
            following = source[index + 1] if index + 1 < len(source) else ""
            if state == "line-comment":
                if current == "\n":
                    state = "code"
            elif state == "block-comment":
                if current == "/" and following == "*":
                    block_comment_depth += 1
                    index += 1
                elif current == "*" and following == "/":
                    block_comment_depth -= 1
                    index += 1
                    if block_comment_depth == 0:
                        state = "code"
            elif state == "string":
                if current == "\\":
                    index += 1
                elif current == '"':
                    state = "code"
            else:
                if current == "/" and following == "/":
                    state = "line-comment"
                    index += 1
                elif current == "/" and following == "*":
                    state = "block-comment"
                    block_comment_depth = 1
                    index += 1
                elif current == '"':
                    state = "string"
                elif current == "{":
                    depth += 1
                elif current == "}":
                    depth -= 1
                    if depth == 0:
                        return source[start:index + 1]
            index += 1

        errors.append(f"cannot locate the {label} closing brace")
        return ""

    def compact(source: str) -> str:
        source = re.sub(r"//[^\n]*", "", source)
        source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
        return re.sub(r"\s+", "", source)

    def block_body(source: str) -> str:
        opening = source.find("{")
        return source[opening + 1:-1] if opening >= 0 and source.endswith("}") else ""

    flow_chart = braced_block(
        analysis_source,
        "private func cashFlowChart(",
        "cash-flow chart",
    )
    category_chart = braced_block(
        view_source,
        "func categoryChart(",
        "category chart",
    )
    category_color = braced_block(
        analysis_source,
        "func categoryChartColor(",
        "category color policy",
    )
    chart_palette = braced_block(
        theme_source,
        "enum MoneyUpChartPalette",
        "chart palette",
    )
    selection_policy = braced_block(
        theme_source,
        "enum MoneyUpChartSelectionPolicy",
        "chart selection policy",
    )
    cash_flow_card = braced_block(
        analysis_source,
        "func cashFlowCard(",
        "cash-flow card",
    )
    category_card = braced_block(
        view_source,
        "func categoryCard(",
        "category card",
    )
    insights_body = braced_block(
        view_source,
        "var body: some View",
        "Insights body",
    )

    flow_marks = braced_block(
        flow_chart,
        "ForEach(points) { point in",
        "cash-flow marks",
    )
    category_marks = braced_block(
        category_chart,
        "ForEach(points) { point in",
        "category marks",
    )
    for label, source in (
        ("cash-flow", flow_marks),
        ("category", category_marks),
    ):
        if ".opacity(" in source:
            errors.append(
                f"{label} data geometry must remain fully opaque; "
                "selection needs a non-opacity encoding"
            )

    selections = (
        (
            "cash-flow",
            braced_block(
                flow_chart,
                "if let selectedFlowMonth {",
                "cash-flow selection rule",
            ),
        ),
        (
            "category",
            braced_block(
                category_chart,
                "if let selectedCategoryKey {",
                "category selection rule",
            ),
        ),
    )
    for label, source in selections:
        for policy_member in ("lineWidth", "dash"):
            snippet = f"MoneyUpChartSelectionPolicy.{policy_member}"
            if snippet not in source:
                errors.append(
                    f"{label} selection must use the shared "
                    f"{policy_member} policy"
                )
        if ".foregroundStyle(Color.primary)" not in source:
            errors.append(f"{label} selection must retain a primary-color stroke")

    flow_compact = compact(flow_chart)
    category_compact = compact(category_chart)
    if not compact(block_body(flow_chart)).startswith("Chart{"):
        errors.append("cash-flow chart must remain the direct render root")
    if not compact(block_body(category_chart)).startswith("Chart{"):
        errors.append("category chart must remain the direct render root")

    expected_flow_data_style = (
        '.foregroundStyle(by:.value(AppLocalization.string('
        '"chart.dimension.flow"),point.series))'
    )
    expected_flow_scale = (
        '.chartForegroundStyleScale([AppLocalization.string('
        '"transaction.income"):MoneyUpChartPalette.income,'
        'AppLocalization.string("transaction.expense"):'
        'MoneyUpChartPalette.expense])'
    )
    expected_category_style = (
        ".foregroundStyle(categoryChartColor(point,in:points))"
    )
    if flow_compact.count(expected_flow_data_style) != 1:
        errors.append("cash-flow marks lost their certified palette lookup")
    if flow_compact.count(expected_flow_scale) != 1:
        errors.append("cash-flow style scale lost its certified direct mappings")
    if category_compact.count(expected_category_style) != 1:
        errors.append("category marks lost their certified color policy")
    if compact(cash_flow_card).count("cashFlowChart(report,points:points)") != 1:
        errors.append("cash-flow chart lost its direct card render call")
    if compact(category_card).count("categoryChart(points)") != 1:
        errors.append("category chart lost its direct card render call")
    if compact(insights_body).count("cashFlowCard(report)") != 1:
        errors.append("cash-flow card lost its direct Insights render call")
    if compact(insights_body).count("categoryCard(report)") != 1:
        errors.append("category card lost its direct Insights render call")

    expected_period_style = ".foregroundStyle(Color.primary.opacity(0.45))"
    expected_selection_style = ".foregroundStyle(Color.primary)"
    expected_annotation_style = ".foregroundStyle(.secondary)"
    if flow_compact.count(expected_period_style) != 2:
        errors.append("cash-flow period rules drifted from their reviewed style")
    if flow_compact.count(expected_selection_style) != 1:
        errors.append("cash-flow selection rule drifted from primary")
    if flow_compact.count(".foregroundStyle(") != 4:
        errors.append("cash-flow chart contains an uncertified foreground style")
    if category_compact.count(expected_selection_style) != 1:
        errors.append("category selection rule drifted from primary")
    if category_compact.count(expected_annotation_style) != 1:
        errors.append("category amount annotation drifted from secondary text")
    if category_compact.count(".foregroundStyle(") != 3:
        errors.append("category chart contains an uncertified foreground style")

    expected_category_color_body = (
        "guardletindex=points.firstIndex(where:"
        "{$0.selectionKey==point.selectionKey})else{"
        "returnMoneyUpChartPalette.color(at:0)}"
        "returnMoneyUpChartPalette.color(at:index)"
    )
    if compact(block_body(category_color)) != expected_category_color_body:
        errors.append("category color helper is not the certified direct index mapping")

    palette_compact = compact(chart_palette)
    expected_order = (
        "staticletordered:[Color]=[.moneyUpChartSeries1,"
        ".moneyUpChartSeries2,.moneyUpChartSeries3,.moneyUpChartSeries4,"
        ".moneyUpChartSeries5,.moneyUpChartSeries6]"
    )
    if palette_compact.count(expected_order) != 1:
        errors.append("chart palette order is not the certified six-token sequence")
    for declaration in (
        "staticletincome=Color.moneyUpChartSeries1",
        "staticletexpense=Color.moneyUpChartSeries2",
    ):
        if palette_compact.count(declaration) != 1:
            errors.append(f"chart palette mapping is missing {declaration}")
    palette_lookup = braced_block(
        chart_palette,
        "static func color(at index: Int)",
        "chart palette lookup",
    )
    if compact(block_body(palette_lookup)) != "ordered[index%ordered.count]":
        errors.append("chart palette lookup is not the certified direct lookup")

    selection_body = compact(block_body(selection_policy))
    number_literal = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
    line_width_match = re.search(
        rf"staticletlineWidth:CGFloat=({number_literal})",
        selection_body,
    )
    dash_match = re.search(
        r"staticletdash:\[CGFloat\]=\[(.*?)\]",
        selection_body,
    )
    if line_width_match is None:
        errors.append("chart selection line width must be a numeric CGFloat literal")
    elif float(line_width_match.group(1)) <= 0:
        errors.append("chart selection line width must be greater than zero")
    if dash_match is None:
        errors.append("chart selection dash must be a literal CGFloat array")
    else:
        dash_literals = dash_match.group(1).split(",") if dash_match.group(1) else []
        if not dash_literals:
            errors.append("chart selection dash must be non-empty")
        elif any(
            re.fullmatch(number_literal, literal) is None
            or float(literal) <= 0
            for literal in dash_literals
        ):
            errors.append("chart selection dash segments must be positive literals")
    if (
        line_width_match is not None
        and dash_match is not None
        and selection_body
        != line_width_match.group(0) + dash_match.group(0)
    ):
        errors.append("chart selection policy contains an uncertified declaration")
    for index in range(1, 7):
        declaration = re.compile(
            rf'^\s*static let moneyUpChartSeries{index} = '
            rf'Color\("ChartSeries{index}"\)\s*$',
            re.MULTILINE,
        )
        if declaration.search(theme_source) is None:
            errors.append(
                f"ChartSeries{index} token is not a direct opaque asset color"
            )

    # The two 45%-opacity period rules are annotations, not data geometry.
    # Remove only those exact reviewed occurrences before rejecting every
    # alpha/effect path capable of weakening marks or changing their canvas.
    reviewed_flow = flow_chart
    if reviewed_flow.count("Color.primary.opacity(0.45)") == 2:
        reviewed_flow = reviewed_flow.replace(
            "Color.primary.opacity(0.45)",
            "Color.primary",
        )
    unsafe_effects = {
        "opacity modifier": r"\.opacity\s*\(",
        "alpha-bearing initializer": r"\b(?:alpha|opacity)\s*:",
        "UIKit alpha conversion": r"\.withAlphaComponent\s*\(",
        "unreviewed modifier": r"\.modifier\s*\(",
        "blend mode": r"\.blendMode\s*\(",
        "mask": r"\.mask\s*[({]",
        "visual effect": (
            r"\.(?:blur|brightness|colorEffect|colorMultiply|compositingGroup|"
            r"contrast|drawingGroup|grayscale|hueRotation|layerEffect|"
            r"luminanceToAlpha|saturation|visualEffect)\s*\("
        ),
        "uncertified canvas": r"\.(?:background|chartBackground|chartPlotStyle)\s*[({]",
        "covering overlay": r"\.overlay\s*[({]",
    }
    for label, source in (
        ("cash-flow chart", reviewed_flow),
        ("category chart", category_chart),
        ("category color helper", category_color),
        ("chart palette", chart_palette),
        ("cash-flow card", cash_flow_card),
        ("category card", category_card),
        (
            "Insights parent",
            insights_body.replace(
                ".background { MoneyUpBackdrop() }",
                "",
            ),
        ),
    ):
        for effect, pattern in unsafe_effects.items():
            if re.search(pattern, source):
                errors.append(f"{label} contains an uncertified {effect}")

    allowed_chart_calls = {
        "accessibilityHidden",
        "accessibilityHint",
        "accessibilityLabel",
        "accessibilityValue",
        "addingTimeInterval",
        "annotation",
        "as",
        "chartForegroundStyleScale",
        "chartLegend",
        "chartXAxis",
        "chartXSelection",
        "chartYAxis",
        "chartYScale",
        "chartYSelection",
        "cornerRadius",
        "first",
        "font",
        "foregroundStyle",
        "frame",
        "lineStyle",
        "map",
        "position",
        "string",
        "value",
    }
    for label, source in (
        ("cash-flow", reviewed_flow),
        ("category", category_chart),
    ):
        calls = set(re.findall(r"\.([A-Za-z_]\w*)\s*\(", source))
        unknown_calls = sorted(calls - allowed_chart_calls)
        if unknown_calls:
            errors.append(
                f"{label} chart contains uncertified helper/modifier calls: "
                f"{unknown_calls}"
            )
    return errors


def feedback_primitive_guard_errors(source: str) -> list[str]:
    """Return violations that can detach or broaden consequential haptics."""
    compact_source = re.sub(r"//[^\n]*", "", source)
    compact_source = re.sub(r"/\*.*?\*/", "", compact_source, flags=re.DOTALL)
    compact_source = re.sub(r"\s+", "", compact_source)
    errors: list[str] = []
    required_once = {
        "structurally attached trigger modifier": (
            "self.sensoryFeedback(trigger:trigger){oldTrigger,newTriggerin"
        ),
        "trigger-transition resolver": (
            "MoneyUpFeedback.haptic(for:event,previousTrigger:oldTrigger,"
            "currentTrigger:newTrigger,visibleStatus:visibleStatus)"
        ),
        "unchanged-trigger suppression": (
            "guardpreviousTrigger!=currentTriggerelse{return.none}"
        ),
    }
    for label, declaration in required_once.items():
        if compact_source.count(declaration) != 1:
            errors.append(f"feedback lost its {label}")
    if "@ViewBuilderfuncmoneyUpFeedback" in compact_source:
        errors.append("feedback modifier must not branch itself out of the view tree")
    return errors


def collect_string_units(
    payload: object, path: tuple[str, ...] = ()
) -> dict[tuple[str, ...], dict[str, object]]:
    """Return every stringUnit leaf, including plural and device variations."""
    units: dict[tuple[str, ...], dict[str, object]] = {}
    if isinstance(payload, dict):
        if "stringUnit" in payload:
            unit = payload["stringUnit"]
            if not isinstance(unit, dict):
                fail(f"invalid stringUnit at {'/'.join(path) or '<root>'}")
            units[path] = unit
        for key, value in payload.items():
            if key != "stringUnit" and isinstance(value, (dict, list)):
                units.update(collect_string_units(value, (*path, str(key))))
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            if isinstance(value, (dict, list)):
                units.update(collect_string_units(value, (*path, str(index))))
    return units


def placeholder_signature(value: str) -> tuple[tuple[int, str], ...]:
    """Normalize printf argument positions so translated text may reorder them."""
    implicit_position = 0
    signature: list[tuple[int, str]] = []
    for match in PRINTF_PLACEHOLDER.finditer(value.replace("%%", "")):
        explicit_position = match.group(1)
        if explicit_position is None:
            implicit_position += 1
            position = implicit_position
        else:
            position = int(explicit_position)
        signature.append((position, match.group(2)))
    return tuple(sorted(signature))


def validate_localizations() -> None:
    catalogs = sorted((ROOT / "App").rglob("*.xcstrings"))
    if not catalogs:
        fail("no string catalogs found")

    app_root = ROOT / "App" / "MoneyUp"
    app_catalogs = sorted(app_root.rglob("*.xcstrings"))
    if [path.relative_to(app_root).as_posix() for path in app_catalogs] != [
        "Resources/AppShortcuts.xcstrings",
        "Resources/Localizable.xcstrings",
    ]:
        fail(
            "app strings must remain in Localizable.xcstrings, with only the "
            "reviewed AppShortcuts.xcstrings phrase catalog beside it"
        )

    widget_root = ROOT / "App" / "MoneyUpWidget"
    widget_catalogs = sorted(widget_root.rglob("*.xcstrings"))
    if [path.relative_to(widget_root).as_posix() for path in widget_catalogs] != [
        "Localizable.xcstrings"
    ]:
        fail("widget strings must remain in the default Localizable.xcstrings table")

    checked = 0
    for catalog in catalogs:
        try:
            payload = json.loads(catalog.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            fail(f"cannot parse {catalog.relative_to(ROOT)}: {error}")

        for key, entry in payload.get("strings", {}).items():
            checked += 1
            localizations = entry.get("localizations", {})
            missing = REQUIRED_LANGUAGES - set(localizations)
            if missing:
                fail(
                    f"{catalog.relative_to(ROOT)}:{key} is missing "
                    + ", ".join(sorted(missing))
                )
            language_units = {
                language: collect_string_units(localizations[language])
                for language in REQUIRED_LANGUAGES
            }
            expected_paths = set(language_units["en"])
            if not expected_paths:
                fail(f"{catalog.relative_to(ROOT)}:{key} has no English string unit")
            for language in REQUIRED_LANGUAGES:
                actual_paths = set(language_units[language])
                if actual_paths != expected_paths:
                    fail(
                        f"{catalog.relative_to(ROOT)}:{key} has mismatched "
                        f"{language} variation paths"
                    )
                for unit_path, unit in language_units[language].items():
                    value = unit.get("value")
                    if (
                        unit.get("state") != "translated"
                        or not isinstance(value, str)
                        or not value.strip()
                    ):
                        path_text = "/".join(unit_path) or "default"
                        fail(
                            f"{catalog.relative_to(ROOT)}:{key}:{path_text} has "
                            f"an incomplete {language} translation"
                        )
            for unit_path in expected_paths:
                english = language_units["en"][unit_path]["value"]
                mandarin = language_units["zh-Hans"][unit_path]["value"]
                if placeholder_signature(english) != placeholder_signature(mandarin):
                    path_text = "/".join(unit_path) or "default"
                    fail(
                        f"{catalog.relative_to(ROOT)}:{key}:{path_text} has "
                        "mismatched printf placeholders"
                    )

    print(f"Validated {checked} bilingual strings in {len(catalogs)} catalogs")

    catalog_keys = {
        catalog: set(json.loads(catalog.read_text(encoding="utf-8"))["strings"])
        for catalog in catalogs
    }
    source_catalogs = (
        (
            app_root,
            catalog_keys[app_root / "Resources" / "Localizable.xcstrings"],
        ),
        (
            widget_root,
            catalog_keys[widget_root / "Localizable.xcstrings"],
        ),
    )
    for source_root, keys in source_catalogs:
        for source in source_root.rglob("*.swift"):
            text = source.read_text(encoding="utf-8")
            referenced = {
                match.group(1)
                for pattern in (
                    LOCALIZED_STRING_REFERENCE,
                    SWIFTUI_LOCALIZED_REFERENCE,
                    ACCESSIBILITY_LOCALIZED_REFERENCE,
                )
                for match in pattern.finditer(text)
            }
            missing = sorted(referenced - keys)
            if missing:
                fail(
                    f"{source.relative_to(ROOT)} references missing localized "
                    f"key(s): {', '.join(missing)}"
                )
            if HARD_CODED_CHART_DIMENSION.search(text):
                fail(
                    f"{source.relative_to(ROOT)} contains a hard-coded chart "
                    "dimension; use AppLocalization.string(_:)"
                )
    print("Validated literal Swift localization references")


def validate_offline_runtime_boundary() -> None:
    forbidden_runtime_symbols = (
        "import Network",
        "import WebKit",
        "URLSession",
        "NWConnection",
        "WKWebView",
        "CFNetwork",
        "Network.framework",
        "Alamofire",
        "Moya",
    )
    for source_root in (ROOT / "App", ROOT / "Sources"):
        for source in source_root.rglob("*.swift"):
            text = source.read_text(encoding="utf-8")
            matches = [
                symbol for symbol in forbidden_runtime_symbols if symbol in text
            ]
            if matches:
                fail(
                    f"{source.relative_to(ROOT)} crosses the reviewed offline "
                    f"runtime boundary: {', '.join(matches)}"
                )
    print("Validated offline runtime boundary")


def validate_key_cliff_recovery_boundary() -> None:
    key_store = (ROOT / "App/MoneyUp/DatabaseKeyStore.swift").read_text(
        encoding="utf-8"
    )
    lifecycle = (ROOT / "App/MoneyUp/AppModelLifecycle.swift").read_text(
        encoding="utf-8"
    )
    restore = (ROOT / "App/MoneyUp/AppModelBackupRestore.swift").read_text(
        encoding="utf-8"
    )
    key_cliff_restore = (
        ROOT / "App/MoneyUp/AppModelKeyCliffRecovery.swift"
    ).read_text(encoding="utf-8")
    restore_preview = (
        ROOT / "App/MoneyUp/AppModelRestorePreview.swift"
    ).read_text(encoding="utf-8")
    preview_type = (ROOT / "App/MoneyUp/RestorePreview.swift").read_text(
        encoding="utf-8"
    )
    startup_publication = (
        ROOT / "App/MoneyUp/AppModelStartupPublication.swift"
    ).read_text(encoding="utf-8")
    ledger_validation = (
        ROOT / "App/MoneyUp/AppModelLedgerValidation.swift"
    ).read_text(encoding="utf-8")
    widget_projection = (
        ROOT / "App/MoneyUp/AppModelJournalProjection.swift"
    ).read_text(encoding="utf-8")
    intelligence = (
        ROOT / "App/MoneyUp/AppModelIntelligence.swift"
    ).read_text(encoding="utf-8")
    recovery_sources = restore + key_cliff_restore
    transaction = (
        ROOT / "App/MoneyUp/KeyCliffRecoveryTransaction.swift"
    ).read_text(encoding="utf-8")

    for declaration in [
        "case missingDeviceBoundKey",
        "DatabaseKeyCreationPolicy.mayCreateKey",
        "throw DatabaseKeyStoreError.missingDeviceBoundKey",
        "kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly",
        "kSecAttrSynchronizable as String] = false",
        "requireDevicePasscodeForRecovery()",
        ".deviceOwnerAuthentication",
        "throw DatabaseKeyStoreError.devicePasscodeRequired",
    ]:
        if declaration not in key_store:
            fail(f"device-key lifecycle is missing {declaration}")

    recovery_key_store = source_section(
        swift_without_comments(key_store),
        "static func storeRecoveryKey",
        "static func deleteKey",
    )
    if not ordered_fragments_are_present(
        recovery_key_store,
        (
            "requireDevicePasscodeForRecovery(",
            "storeKey(key, loadExistingOnDuplicate: false)",
        ),
    ):
        fail("device-key lifecycle is missing the final passcode recheck")
    if "errSecPasscodeRequired" in key_store:
        fail("device-key lifecycle uses a newer-SDK-only passcode status")

    for declaration in [
        "startupFailureKind = .missingDeviceBoundKey",
        "KeyCliffRecoveryTransaction.hasPendingManifest",
        "KeyCliffRecoveryTransaction.installCandidate",
        "KeyCliffRecoveryTransaction.restoreOriginal",
    ]:
        if declaration not in lifecycle + key_cliff_restore:
            fail(f"key-cliff startup recovery is missing {declaration}")

    required_restore = [
        "RestoreArchiveStaging.verifiedCommitCopy",
        "keyCliffRecoveryKeyAccess.generate()",
        "prepareCandidateDirectory(",
        "validateRestoreCandidate(",
        "KeyCliffRecoveryTransaction.publishManifest",
        "keyCliffRecoveryKeyAccess.store",
        "KeyCliffRecoveryTransaction.installCandidate",
        "KeyCliffRecoveryTransaction.beginRollback",
        "keyCliffRecoveryKeyAccess.delete",
        "KeyCliffRecoveryTransaction.restoreOriginal",
    ]
    for declaration in required_restore:
        if declaration not in recovery_sources:
            fail(f"keyless archive recovery is missing {declaration}")
    recovery_body = key_cliff_restore[
        key_cliff_restore.find("func recoverMissingDeviceBoundKey") :
        key_cliff_restore.find("private func buildKeyCliffCandidate")
    ]
    commit_body = key_cliff_restore[
        key_cliff_restore.find("private func commitKeyCliffCandidate") :
        key_cliff_restore.find("private func rollbackFailedKeyCliffCommit")
    ]
    rollback_body = key_cliff_restore[
        key_cliff_restore.find("private func rollbackFailedKeyCliffCommit") :
        key_cliff_restore.find("private func keyCliffLiveDatabaseURL")
    ]
    recovery_order = [
        "RestoreArchiveStaging.verifiedCommitCopy",
        "keyCliffRecoveryKeyAccess.generate()",
        "prepareCandidateDirectory(",
        "buildKeyCliffCandidate(",
        "KeyCliffRecoveryTransaction.publishManifest",
        "commitKeyCliffCandidate(",
    ]
    recovery_positions = [recovery_body.find(item) for item in recovery_order]
    commit_positions = [
        commit_body.find("keyCliffRecoveryKeyAccess.store"),
        commit_body.find("KeyCliffRecoveryTransaction.installCandidate"),
        commit_body.find("load(from: openedStore, mode: .restoreValidation)"),
        commit_body.find("validateLoadedStartupBook"),
        commit_body.find("requireEmptyLockedCaptureInbox()"),
        commit_body.find(".afterKeyCliffValidationBeforeCompletion"),
        commit_body.find("KeyCliffRecoveryTransaction.complete"),
        commit_body.find("startupFailureKind = nil"),
        commit_body.find(
            "publishValidatedStartupBookAfterIrreversibleRecovery"
        ),
    ]
    rollback_positions = [
        rollback_body.find("KeyCliffRecoveryTransaction.beginRollback"),
        rollback_body.find("keyCliffRecoveryKeyAccess.delete"),
        rollback_body.find("KeyCliffRecoveryTransaction.restoreOriginal"),
    ]
    if any(position < 0 for position in (
        recovery_positions + commit_positions + rollback_positions
    )) or not (
        recovery_positions == sorted(recovery_positions)
        and commit_positions == sorted(commit_positions)
        and rollback_positions == sorted(rollback_positions)
    ):
        fail("key-cliff recovery must validate before durable key/file mutation")

    startup_body = key_cliff_restore[
        key_cliff_restore.find(
            "func openAndFinishStartupIncludingKeyCliffRecovery"
        ) : key_cliff_restore.find("func recoverMissingDeviceBoundKey")
    ]
    resume_order = (
        "load(from: openedStore, mode: .restoreValidation)",
        "validateLoadedStartupBook",
        "requireEmptyLockedCaptureInbox()",
        ".afterKeyCliffValidationBeforeCompletion",
        "KeyCliffRecoveryTransaction.complete",
        "startupFailureKind = nil",
        "publishValidatedStartupBookAfterIrreversibleRecovery",
    )
    resume_positions = [startup_body.find(item) for item in resume_order]
    if any(position < 0 for position in resume_positions) or (
        resume_positions != sorted(resume_positions)
    ):
        fail("key-cliff resume must publish only after validation and completion")
    normal_load = "try await load(from: openedStore)"
    if normal_load not in startup_body or "finishLoadedStartup" not in startup_body:
        fail("ordinary startup must retain recovering-mode load semantics")

    for declaration, source in (
        ("UserDefaults.standard.set(", startup_publication),
        ("locked_captures/promotion-unavailable", startup_publication),
        ("if !isBookReplacementInProgress", startup_publication),
        ("func finishBookReplacementMutation", ledger_validation),
        ("refreshBudgetWidgetSnapshot()", ledger_validation),
        ("refreshIntelligence()", ledger_validation),
        ("!isBookReplacementInProgress", widget_projection),
        ("!isBookReplacementInProgress", intelligence),
    ):
        if declaration not in source:
            fail(f"authoritative post-restore publication is missing {declaration}")

    raw_restore = restore[
        restore.find("func restoreEncryptedBackup(\n        from archiveURL") :
        restore.find("private func restoreEncryptedBackupIntoLiveStore")
    ]
    ticket_restore = restore_preview[
        restore_preview.find("func restoreEncryptedBackup(\n        _ ticket") :
        restore_preview.find("private func restorePreviewCurrentBook")
    ]
    for declaration in (
        "throw AppModelError.restorePreviewRequired",
        "case inaccessible",
        "let current: CurrentBook",
    ):
        source = raw_restore if declaration.startswith("throw") else preview_type
        if declaration not in source:
            fail(f"key-cliff preview boundary is missing {declaration}")
    if "recoverMissingDeviceBoundKey" in raw_restore:
        fail("raw archive restore must not bypass key-cliff preview authority")
    debug_start = restore.find("#if DEBUG")
    raw_start = restore.find("func restoreEncryptedBackup(_ data: Data")
    debug_end = restore.find("#endif", raw_start)
    verified_primitive = restore.find(
        "func restoreEncryptedBackupAfterVerifiedTicket"
    )
    if not (
        0 <= debug_start < raw_start < debug_end < verified_primitive
    ):
        fail("raw restore compatibility APIs must be absent from release builds")
    for declaration in (
        "startupFailureKind == .missingDeviceBoundKey",
        "recoverMissingDeviceBoundKey(",
        "return",
        "beginRestoreMutation()",
    ):
        if declaration not in ticket_restore:
            fail(f"ticket restore routing is missing {declaration}")
    if ticket_restore.find("recoverMissingDeviceBoundKey(") > ticket_restore.find(
        "beginRestoreMutation()"
    ):
        fail("key-cliff ticket must route before normal live-store preparation")
    app_sources = {
        path: path.read_text(encoding="utf-8")
        for path in (ROOT / "App/MoneyUp").rglob("*.swift")
    }
    backup_path = ROOT / "App/MoneyUp/AppModelBackupRestore.swift"
    app_sources[backup_path] = restore[:debug_start] + restore[
        debug_end + len("#endif"):
    ]
    verified_calls = sum(
        source.count("restoreEncryptedBackupAfterVerifiedTicket(")
        for source in app_sources.values()
    )
    if verified_calls != 2:
        fail("verified restore primitive must have one definition and one ticket call")

    for declaration in [
        "originalArtifactMask",
        "candidateArtifactMask",
        "phase",
        "static func installCandidate",
        "static func beginRollback",
        "static func restoreOriginal",
        "static func scavengeUncommittedCandidate",
    ]:
        if declaration not in transaction:
            fail(f"key-cliff filesystem transaction is missing {declaration}")
    manifest_block = transaction[
        transaction.find("struct KeyCliffRecoveryManifest") :
        transaction.find("enum KeyCliffRecoveryTransaction")
    ]
    manifest_fields = set(
        re.findall(r"^\s+let\s+([A-Za-z0-9_]+):", manifest_block, re.MULTILINE)
    )
    if manifest_fields != {
        "version",
        "originalArtifactMask",
        "candidateArtifactMask",
        "phase",
    }:
        fail("key-cliff manifest must contain only non-secret artifact masks")

    print("Validated key-cliff recovery and rollback boundary")


def validate_restore_preview_boundary() -> None:
    model_path = ROOT / "App" / "MoneyUp" / "AppModelRestorePreview.swift"
    preview_path = ROOT / "App" / "MoneyUp" / "RestorePreview.swift"
    restore_path = ROOT / "App" / "MoneyUp" / "AppModelBackupRestore.swift"
    lifecycle_path = ROOT / "App" / "MoneyUp" / "AppModelLifecycle.swift"
    view_path = ROOT / "App" / "MoneyUp" / "RestorePreviewConfirmationView.swift"
    safety_path = ROOT / "App" / "MoneyUp" / "DataSafetyView.swift"
    root_path = ROOT / "App" / "MoneyUp" / "RootView.swift"
    startup_path = ROOT / "App" / "MoneyUp" / "AppModelStartupPublication.swift"
    ledger_validation_path = (
        ROOT / "App" / "MoneyUp" / "AppModelLedgerValidation.swift"
    )
    journal_projection_path = (
        ROOT / "App" / "MoneyUp" / "AppModelJournalProjection.swift"
    )
    journal_derived_path = (
        ROOT / "App" / "MoneyUp" / "AppModelJournalDerivedState.swift"
    )
    intelligence_path = ROOT / "App" / "MoneyUp" / "AppModelIntelligence.swift"
    bounded_reader_path = ROOT / "App" / "MoneyUp" / "BoundedFileReader.swift"
    portable_writer_path = (
        ROOT / "Sources" / "MoneyUpPersistence"
        / "PortableArchiveV2Validation.swift"
    )
    tests_path = ROOT / "Tests" / "MoneyUpAppTests" / "AppModelTests.swift"
    accessible_tests_path = (
        ROOT / "Tests" / "MoneyUpAppTests"
        / "AccessibleErrorPresentationTests.swift"
    )
    model = model_path.read_text(encoding="utf-8")
    preview = preview_path.read_text(encoding="utf-8")
    restore = restore_path.read_text(encoding="utf-8")
    lifecycle = lifecycle_path.read_text(encoding="utf-8")
    view = view_path.read_text(encoding="utf-8")
    safety = safety_path.read_text(encoding="utf-8")
    root_view = root_path.read_text(encoding="utf-8")
    startup = startup_path.read_text(encoding="utf-8")
    ledger_validation = ledger_validation_path.read_text(encoding="utf-8")
    journal_projection = journal_projection_path.read_text(encoding="utf-8")
    journal_derived = journal_derived_path.read_text(encoding="utf-8")
    intelligence = intelligence_path.read_text(encoding="utf-8")
    bounded_reader = bounded_reader_path.read_text(encoding="utf-8")
    portable_writer = portable_writer_path.read_text(encoding="utf-8")
    tests = tests_path.read_text(encoding="utf-8")
    accessible_tests = accessible_tests_path.read_text(encoding="utf-8")

    preview_prepare = model.split(
        "func prepareEncryptedRestorePreview", 1
    )[1].split("func restoreEncryptedBackup", 1)[0]
    for forbidden in (
        "finishPendingQuickLogDraftWrite",
        "flushQuickLogDraftForBackup",
    ):
        if forbidden in preview_prepare:
            fail(f"restore preview preparation must remain read-only: {forbidden}")

    restore_prepare = restore.split("private func prepareRestore", 1)[1].split(
        "private func validateAndPublishRestoredBook", 1
    )[0]
    validation_index = restore_prepare.find("validateRestoreCandidateInIsolation")
    flush_index = restore_prepare.find("flushQuickLogDraftForBackup")
    if validation_index < 0 or flush_index < 0 or validation_index > flush_index:
        fail("restore must authenticate and validate before flushing the live draft")

    required_by_source = {
        preview_path: (
            "let byteCount: Int",
            "let sha256: Data",
            "enum CurrentBook",
            "case inaccessible",
            "let current: CurrentBook",
        ),
        model_path: (
            "fingerprint == ticket.archiveFingerprint",
            "[.posixPermissions: 0o400]",
            "restorePreviewValidationArchiveURL",
            "restoreStagedArchiveURL",
            "restoreCommitArchiveURL",
            "restoreRollbackArchiveURL",
            "restoreRollbackDirectoryURL",
            "return .inaccessible",
            "guard store == nil, case .failed = state",
            "let quickActionBoundaryEpoch = try beginRestoreMutation()",
            "finishBookReplacementMutation()",
            "quickActionRouteBroker.endAuthoritativeBoundary(",
            "await finishBeginningRestoreMutation()",
        ),
        restore_path: (
            "isBookReplacementInProgress = true",
            "requestedQuickLogMode = nil",
            "intelligenceService.cancelPendingWork()",
            "let quickActionBoundaryEpoch = try beginRestoreMutation()",
            "finishBookReplacementMutation()",
            "quickActionRouteBroker.endAuthoritativeBoundary(",
            "await finishBeginningRestoreMutation()",
            "restoreRollbackArchiveURL",
            "restoreRollbackDirectoryURL",
            "[.posixPermissions: 0o700]",
            "[.posixPermissions: 0o400]",
        ),
        lifecycle_path: (
            "scavengeRestorePreviewArtifacts()",
            "!isBookReplacementInProgress",
        ),
        safety_path: (
            "[.posixPermissions: 0o400]",
            ".moneyUpOperationErrorAlert(message: $errorMessage)",
            "@AccessibilityFocusState private var successMessageIsFocused",
            ".accessibilityFocused($successMessageIsFocused)",
            "RestoreCompletionAccessibilityRoute",
            "queueRestoreCompletionForReadyHierarchy",
            "clearRestoreCompletionForReadyHierarchy",
            "restorePresentation.queue(",
            ".failure(safeUserMessage(",
            "onDismiss: presentRestoreResultAfterSheetDismissal",
        ),
        root_path: (
            "UIAccessibility.post(",
            "notification: .announcement",
            "takeRestoreCompletionForReadyHierarchy",
            ".onChange(of: model.pendingRestoreCompletionAnnouncement)",
        ),
        startup_path: (
            "pendingRestoreCompletionAnnouncement = completion",
            "guard state == .ready else { return nil }",
            "pendingRestoreCompletionAnnouncement = nil",
        ),
        ledger_validation_path: (
            "func finishBookReplacementMutation()",
            "isBookReplacementInProgress = false",
            "refreshBudgetWidgetSnapshot()",
            "refreshIntelligence()",
        ),
        journal_projection_path: ("!isBookReplacementInProgress",),
        journal_derived_path: ("!isBookReplacementInProgress",),
        intelligence_path: ("!isBookReplacementInProgress",),
        portable_writer_path: (
            r'".moneyup-archive-\(UUID().uuidString).tmp"',
            "attributes: [.posixPermissions: 0o600]",
            "options: [.usingNewMetadataOnly]",
            "try fileManager.setAttributes(",
        ),
        bounded_reader_path: ("attributes: [.posixPermissions: 0o600]",),
        view_path: (
            "ForEach(currencies, id: \\.self)",
            "book.reportingTimeZoneIdentifier",
            "preview.current.availableSummary",
            '"restore.preview.current_inaccessible"',
            '"recovery.key_cliff.confirm_action"',
            '"recovery.key_cliff.confirm_detail"',
        ),
    }
    source_text = {
        model_path: model,
        preview_path: preview,
        restore_path: restore,
        lifecycle_path: lifecycle,
        safety_path: safety,
        root_path: root_view,
        startup_path: startup,
        ledger_validation_path: ledger_validation,
        journal_projection_path: journal_projection,
        journal_derived_path: journal_derived,
        intelligence_path: intelligence,
        bounded_reader_path: bounded_reader,
        portable_writer_path: portable_writer,
        view_path: view,
    }
    for path, declarations in required_by_source.items():
        for declaration in declarations:
            if declaration not in source_text[path]:
                fail(
                    f"{path.relative_to(ROOT)} is missing restore invariant "
                    f"{declaration}"
                )
    if ".prefix(12)" in view:
        fail("restore preview must not hide currency identities behind truncation")
    if "preview.current.storedRecordCount" in view:
        fail("restore preview must not treat an inaccessible current book as zero")

    for test_name in (
        "testRestorePreviewCancelWrongPasswordAndTamperNeverFlushInMemoryDraft",
        "testRestorePreviewSameLengthDigestMismatchCannotReachLiveReplacement",
        "testRestoreArchivePrivateCopiesAreOwnerReadOnly",
        "testStartupScavengesEveryDeterministicRestoreArchive",
        "testRestorePreviewDateSpanUsesEachBookReportingZone",
        "testKeyCliffRestoreRejectsThenCancelsWithoutMutationAndCommitsValidArchive",
        "testKeyCliffFinalInboxRecheckRollsBackLateCaptureBeforePublication",
        "testStartupResumesKeyCliffCandidateBeforePublishingBook",
        "testStartupRejectsCaptureBeforeCompletingKeyCliffCandidate",
        "testKeyCliffPostCompletionInboxFailureKeepsAuthoritativeBookRetryable",
    ):
        if test_name not in tests:
            fail(f"restore preview regression is missing {test_name}")
    if (
        "testRestoreAnnouncementSurvivesEitherReadyAppearanceOrderingOnce"
        not in accessible_tests
    ):
        fail("restore completion announcement ordering regression is missing")
    print("Validated read-only, byte-bound, private restore preview boundary")


def validate_test_declaration_accounting() -> None:
    test_root = ROOT / "Tests"
    suites = (
        "MoneyUpCoreTests",
        "MoneyUpPersistenceTests",
        "MoneyUpIntelligenceTests",
        "MoneyUpAppTests",
        "MoneyUpPerformanceTests",
    )
    xctest_pattern = re.compile(r"^\s*func\s+test[A-Za-z0-9_]*\s*\(", re.MULTILINE)
    swift_test_pattern = re.compile(r"^\s*@Test(?:\s|\()", re.MULTILINE)
    totals: dict[str, int] = {}
    xctest_total = 0
    swift_test_total = 0
    for suite in suites:
        source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((test_root / suite).rglob("*.swift"))
        )
        xctest_count = len(xctest_pattern.findall(source))
        swift_test_count = len(swift_test_pattern.findall(source))
        totals[suite] = xctest_count + swift_test_count
        xctest_total += xctest_count
        swift_test_total += swift_test_count

    matrix = (ROOT / "docs/REQUIREMENTS_TEST_MATRIX.md").read_text(
        encoding="utf-8"
    )
    accounting = re.search(
        r"Declared automated tests in source after this review: \*\*(\d+)\*\* "
        r"\((\d+)\s+core,\s+(\d+)\s+persistence,\s+"
        r"(\d+)\s+intelligence,\s+(\d+)\s+app-target, and\s+"
        r"(\d+)\s+performance-target\s+declarations;.*?"
        r"\*\*(\d+)\*\* are XCTest.*?remaining (\d+) are Swift Testing",
        matrix,
        re.DOTALL,
    )
    if accounting is None:
        fail("requirements matrix test accounting is missing or malformed")
    declared = tuple(int(value) for value in accounting.groups())
    actual = (
        sum(totals.values()),
        totals["MoneyUpCoreTests"],
        totals["MoneyUpPersistenceTests"],
        totals["MoneyUpIntelligenceTests"],
        totals["MoneyUpAppTests"],
        totals["MoneyUpPerformanceTests"],
        xctest_total,
        swift_test_total,
    )
    if declared != actual:
        fail(
            "requirements matrix test accounting is stale: "
            f"declared {declared}, actual {actual}"
        )
    print(
        f"Validated dynamic test accounting: {actual[0]} declarations "
        f"({actual[6]} XCTest, {actual[7]} Swift Testing)"
    )


def validate_privacy_manifest() -> None:
    manifests = {
        ROOT / "App" / "MoneyUp" / "PrivacyInfo.xcprivacy": {
            "CA92.1",
            "1C8F.1",
        },
        ROOT / "App" / "MoneyUpWidget" / "PrivacyInfo.xcprivacy": {
            "1C8F.1",
        },
    }
    for manifest_path, expected_reasons in manifests.items():
        try:
            with manifest_path.open("rb") as file:
                manifest = plistlib.load(file)
        except (OSError, plistlib.InvalidFileException) as error:
            fail(
                f"cannot parse {manifest_path.relative_to(ROOT)} privacy "
                f"manifest: {error}"
            )

        owner = manifest_path.parent.name
        if manifest.get("NSPrivacyTracking") is not False:
            fail(f"{owner} privacy manifest must declare tracking disabled")
        if manifest.get("NSPrivacyCollectedDataTypes") != []:
            fail(
                f"{owner} privacy manifest must match MoneyUp's "
                "no-data-collection architecture"
            )
        if manifest.get("NSPrivacyTrackingDomains") != []:
            fail(f"{owner} privacy manifest must not declare tracking domains")

        accessed = manifest.get("NSPrivacyAccessedAPITypes")
        if not isinstance(accessed, list) or len(accessed) != 1:
            fail(
                f"{owner} privacy manifest must declare exactly the reviewed "
                "UserDefaults API"
            )

        user_defaults = accessed[0]
        if (
            not isinstance(user_defaults, dict)
            or user_defaults.get("NSPrivacyAccessedAPIType")
            != "NSPrivacyAccessedAPICategoryUserDefaults"
        ):
            fail(
                f"{owner} privacy manifest must declare exactly the reviewed "
                "UserDefaults API"
            )

        reasons = user_defaults.get("NSPrivacyAccessedAPITypeReasons")
        if (
            not isinstance(reasons, list)
            or not all(isinstance(reason, str) for reason in reasons)
            or len(reasons) != len(expected_reasons)
            or set(reasons) != expected_reasons
        ):
            fail(
                f"{owner} privacy manifest must declare exactly UserDefaults "
                f"reasons {', '.join(sorted(expected_reasons))}"
            )

    print("Validated app and widget PrivacyInfo.xcprivacy files")


def validate_info_plist_localizations() -> None:
    expected = {
        "en": {
            "NSFaceIDUsageDescription": "Unlock your private MoneyUp financial data.",
            "UTTypeDescription": "MoneyUp Encrypted Backup",
        },
        "zh-Hans": {
            "NSFaceIDUsageDescription": "解锁你在 MoneyUp 中的私密财务数据。",
            "UTTypeDescription": "MoneyUp 加密备份",
        },
    }
    for language, declarations in expected.items():
        path = ROOT / "App" / "MoneyUp" / f"{language}.lproj" / "InfoPlist.strings"
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            fail(f"cannot read {path.relative_to(ROOT)}: {error}")
        for key, value in declarations.items():
            declaration = f'"{key}" = "{value}";'
            if declaration not in text:
                fail(f"{path.relative_to(ROOT)} must localize {key}")
    print("Validated bilingual Info.plist user-facing strings")


def png_metadata(path: Path) -> tuple[int, int, int, bool]:
    try:
        data = path.read_bytes()
    except OSError as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")
    if (
        len(data) < 33
        or data[:8] != b"\x89PNG\r\n\x1a\n"
        or data[12:16] != b"IHDR"
        or struct.unpack(">I", data[8:12])[0] != 13
    ):
        fail(f"{path.relative_to(ROOT)} is not a valid PNG")
    width, height = struct.unpack(">II", data[16:24])
    color_type = data[25]
    has_transparency_chunk = False
    offset = 8
    while offset + 12 <= len(data):
        chunk_length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_end = offset + 12 + chunk_length
        if chunk_end > len(data):
            fail(f"{path.relative_to(ROOT)} has a truncated PNG chunk")
        chunk_type = data[offset + 4 : offset + 8]
        if chunk_type == b"tRNS":
            has_transparency_chunk = True
        offset = chunk_end
        if chunk_type == b"IEND":
            break
    return width, height, color_type, has_transparency_chunk


def png_alpha_coverage(path: Path) -> tuple[int, int, int, int]:
    """Return alpha extrema and fully transparent/opaque pixel counts.

    Release illustrations are normalized to non-interlaced 8-bit RGBA PNGs.
    Decoding their scanline filters here keeps the CI gate dependency-free and
    rejects files that merely declare an unused alpha channel.
    """
    data = path.read_bytes()
    width, height = struct.unpack(">II", data[16:24])
    bit_depth = data[24]
    color_type = data[25]
    interlace = data[28]
    if bit_depth != 8 or color_type not in {4, 6} or interlace != 0:
        fail(
            f"{path.relative_to(ROOT)} must be a non-interlaced 8-bit "
            "grayscale-alpha or RGBA PNG"
        )

    compressed = bytearray()
    offset = 8
    while offset + 12 <= len(data):
        chunk_length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + chunk_length]
        if chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        offset += 12 + chunk_length
        if chunk_type == b"IEND":
            break

    try:
        scanlines = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        fail(f"cannot decode {path.relative_to(ROOT)} alpha data: {error}")

    bytes_per_pixel = 4 if color_type == 6 else 2
    alpha_offset = bytes_per_pixel - 1
    row_bytes = width * bytes_per_pixel
    expected_bytes = height * (row_bytes + 1)
    if len(scanlines) != expected_bytes:
        fail(f"{path.relative_to(ROOT)} has unexpected PNG scanline data")

    previous = bytearray(row_bytes)
    alpha_values: list[int] = []
    cursor = 0
    for _ in range(height):
        filter_type = scanlines[cursor]
        cursor += 1
        raw = scanlines[cursor : cursor + row_bytes]
        cursor += row_bytes
        reconstructed = bytearray(row_bytes)
        for index, value in enumerate(raw):
            left = reconstructed[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            up = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = up
            elif filter_type == 3:
                predictor = (left + up) // 2
            elif filter_type == 4:
                estimate = left + up - upper_left
                left_distance = abs(estimate - left)
                up_distance = abs(estimate - up)
                upper_left_distance = abs(estimate - upper_left)
                predictor = (
                    left
                    if left_distance <= up_distance and left_distance <= upper_left_distance
                    else up if up_distance <= upper_left_distance else upper_left
                )
            else:
                fail(f"{path.relative_to(ROOT)} uses unsupported PNG filter {filter_type}")
            reconstructed[index] = (value + predictor) & 0xFF
        alpha_values.extend(reconstructed[alpha_offset::bytes_per_pixel])
        previous = reconstructed

    return (
        min(alpha_values),
        max(alpha_values),
        sum(value == 0 for value in alpha_values),
        sum(value == 255 for value in alpha_values),
    )


def validate_icons() -> None:
    icon_directory = (
        ROOT / "App" / "MoneyUp" / "Assets.xcassets" / "AppIcon.appiconset"
    )
    required = ["AppIcon.png", "AppIcon-Dark.png", "AppIcon-Tinted.png"]
    for name in required:
        path = icon_directory / name
        width, height, color_type, has_transparency_chunk = png_metadata(path)
        if (width, height) != (1024, 1024):
            fail(f"{path.relative_to(ROOT)} must be 1024 by 1024 pixels")
        if color_type in {4, 6} or has_transparency_chunk:
            fail(f"{path.relative_to(ROOT)} must not contain an alpha channel")

    contents_path = icon_directory / "Contents.json"
    try:
        contents = json.loads(contents_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse app icon Contents.json: {error}")

    expected_appearances = {
        "AppIcon.png": None,
        "AppIcon-Dark.png": "dark",
        "AppIcon-Tinted.png": "tinted",
    }
    images = contents.get("images", [])
    if not isinstance(images, list) or len(images) != len(expected_appearances):
        fail("app icon Contents.json must define default, dark, and tinted slots")
    for image in images:
        filename = image.get("filename")
        if filename not in expected_appearances:
            fail(f"unexpected app icon slot: {filename!r}")
        if (
            image.get("idiom") != "universal"
            or image.get("platform") != "ios"
            or image.get("size") != "1024x1024"
        ):
            fail(f"invalid App Store icon metadata for {filename}")
        appearances = image.get("appearances")
        expected = expected_appearances[filename]
        if expected is None and appearances is not None:
            fail("default AppIcon.png must not declare an appearance")
        if expected is not None and appearances != [
            {"appearance": "luminosity", "value": expected}
        ]:
            fail(f"invalid {expected} appearance metadata for {filename}")
    print("Validated default, dark, and tinted app icons")

    mark_directory = (
        ROOT / "App" / "MoneyUp" / "Assets.xcassets" / "MoneyUpBrandMark.imageset"
    )
    expected_marks = {
        "MoneyUpBrandMark.png": (384, 384, "1x"),
        "MoneyUpBrandMark@2x.png": (768, 768, "2x"),
        "MoneyUpBrandMark@3x.png": (1152, 1152, "3x"),
    }
    for name, (expected_width, expected_height, _) in expected_marks.items():
        path = mark_directory / name
        width, height, color_type, _ = png_metadata(path)
        if (width, height) != (expected_width, expected_height):
            fail(
                f"{path.relative_to(ROOT)} must be "
                f"{expected_width} by {expected_height} pixels"
            )
        if color_type not in {4, 6}:
            fail(f"{path.relative_to(ROOT)} must preserve a transparent mask")

    mark_contents_path = mark_directory / "Contents.json"
    try:
        mark_contents = json.loads(mark_contents_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse horned-money mark Contents.json: {error}")
    mark_images = mark_contents.get("images", [])
    actual_marks = {
        item.get("filename"): item.get("scale")
        for item in mark_images
        if item.get("filename") is not None
    }
    expected_scales = {
        name: scale for name, (_, _, scale) in expected_marks.items()
    }
    if actual_marks != expected_scales:
        fail(f"invalid horned-money mark slots: {actual_marks}")
    template_intent = mark_contents.get("properties", {}).get(
        "template-rendering-intent"
    )
    if template_intent != "template":
        fail("the shared horned-money mark must render as a semantic template")
    print("Validated shared horned-money brand mark")

    widget_mark_directory = (
        ROOT / "App" / "MoneyUpWidget" / "Assets.xcassets"
        / "MoneyUpBrandMark.imageset"
    )
    for name in expected_marks:
        app_path = mark_directory / name
        widget_path = widget_mark_directory / name
        if not widget_path.is_file() or widget_path.read_bytes() != app_path.read_bytes():
            fail(f"widget horned-money mark drifted from the app asset: {name}")

    illustrations = {
        "MoneyUpMoneyWorld": "MoneyUpMoneyWorld",
        "MoneyUpScenarioStudio": "MoneyUpScenarioStudio",
    }
    expected_illustration_sizes = {
        "": (256, 256, "1x", None),
        "@2x": (512, 512, "2x", None),
        "@3x": (768, 768, "3x", None),
        "-Dark": (256, 256, "1x", "dark"),
        "-Dark@2x": (512, 512, "2x", "dark"),
        "-Dark@3x": (768, 768, "3x", "dark"),
    }
    app_assets = ROOT / "App" / "MoneyUp" / "Assets.xcassets"
    for asset_name, filename_stem in illustrations.items():
        directory = app_assets / f"{asset_name}.imageset"
        expected_slots: dict[str, tuple[str, str | None]] = {}
        for suffix, (expected_width, expected_height, scale, appearance) in (
            expected_illustration_sizes.items()
        ):
            name = f"{filename_stem}{suffix}.png"
            expected_slots[name] = (scale, appearance)
            width, height, color_type, has_transparency = png_metadata(
                directory / name
            )
            if (width, height) != (expected_width, expected_height):
                fail(
                    f"{(directory / name).relative_to(ROOT)} must be "
                    f"{expected_width} by {expected_height} pixels"
                )
            if color_type not in {4, 6} and not has_transparency:
                fail(f"{name} must preserve a genuine transparent cutout")
            minimum_alpha, maximum_alpha, transparent, opaque = png_alpha_coverage(
                directory / name
            )
            pixel_count = expected_width * expected_height
            if (
                minimum_alpha != 0
                or maximum_alpha != 255
                or transparent < pixel_count // 20
                or opaque < pixel_count // 20
            ):
                fail(
                    f"{name} must contain substantial fully transparent and "
                    "fully opaque regions"
                )
        try:
            payload = json.loads(
                (directory / "Contents.json").read_text(encoding="utf-8")
            )
        except (OSError, json.JSONDecodeError) as error:
            fail(f"cannot parse {asset_name} Contents.json: {error}")
        actual_slots = {
            item.get("filename"): (
                item.get("scale"),
                (
                    item.get("appearances", [{}])[0].get("value")
                    if item.get("appearances")
                    else None
                ),
            )
            for item in payload.get("images", [])
            if item.get("filename") is not None
        }
        if actual_slots != expected_slots:
            fail(f"invalid {asset_name} illustration slots: {actual_slots}")
    print("Validated adaptive 3D illustration assets and widget brand mark")


def validate_brand_palette() -> None:
    assets = ROOT / "App" / "MoneyUp" / "Assets.xcassets"
    light_normal = ("light", "normal")
    dark_normal = ("dark", "normal")
    light_high = ("light", "high")
    dark_high = ("dark", "high")
    slots = (light_normal, dark_normal, light_high, dark_high)

    # Exact reviewed normal slots. The dark action was refined once to clear
    # every real app canvas while all other normal slots remain byte-stable.
    approved_normal = {
        "AccentColor": {light_normal: "#34785F", dark_normal: "#82CEAE"},
        "BrandAction": {light_normal: "#34785F", dark_normal: "#347F60"},
        "BrandBackground": {light_normal: "#F7F9F6", dark_normal: "#101512"},
        "BrandMist": {light_normal: "#D4EAD8", dark_normal: "#3C6349"},
        "BrandSurface": {light_normal: "#EEF4F0", dark_normal: "#18211D"},
        "BrandSurfaceElevated": {
            light_normal: "#FAFBF9",
            dark_normal: "#202923",
        },
    }
    high_contrast = {
        "AccentColor": {light_high: "#1F6047", dark_high: "#A4E7CA"},
        "BrandAction": {light_high: "#245F49", dark_high: "#377B61"},
        "BrandBackground": {light_high: "#FCFDFB", dark_high: "#080B09"},
        "BrandMist": {light_high: "#B8D9C4", dark_high: "#557D64"},
        "BrandSurface": {light_high: "#E7EDE8", dark_high: "#121A16"},
        "BrandSurfaceElevated": {
            light_high: "#F3F6F2",
            dark_high: "#17201B",
        },
    }
    chart_rows = [
        ("#117733", "#59C69B", "#075F29", "#7EE0B2"),
        ("#1F6680", "#68B7D0", "#00536D", "#8AD7EE"),
        ("#8C6500", "#E0B44C", "#725000", "#FFD071"),
        ("#7A3E9D", "#C68BE0", "#633080", "#E2A9F5"),
        ("#A53F5B", "#E7899D", "#8B2947", "#FFA8B8"),
        ("#332288", "#9A8EE0", "#24126E", "#B9AEFF"),
    ]
    expected: dict[str, dict[tuple[str, str], str]] = {}
    for name in approved_normal:
        expected[name] = approved_normal[name] | high_contrast[name]
    for index, row in enumerate(chart_rows, start=1):
        expected[f"ChartSeries{index}"] = dict(zip(slots, row))

    discovered = {
        path.parent.stem
        for path in assets.glob("*.colorset/Contents.json")
    }
    if discovered != set(expected):
        fail(
            "semantic colorset registry drifted: "
            f"missing {sorted(set(expected) - discovered)}, "
            f"unexpected {sorted(discovered - set(expected))}"
        )

    actual_palette: dict[str, dict[tuple[str, str], str]] = {}
    for name, expected_slots in expected.items():
        path = assets / f"{name}.colorset" / "Contents.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            fail(f"cannot parse semantic brand asset {name}: {error}")
        actual: dict[tuple[str, str], str] = {}
        for item in payload.get("colors", []):
            if item.get("idiom") != "universal":
                fail(f"{name} colors must use the universal idiom")
            appearance = "light"
            contrast_level = "normal"
            seen_appearances: set[str] = set()
            appearances = item.get("appearances", [])
            if not isinstance(appearances, list):
                fail(f"{name} appearances must be an array")
            for entry in appearances:
                if not isinstance(entry, dict):
                    fail(f"{name} contains an invalid appearance entry")
                key = entry.get("appearance")
                value = entry.get("value")
                if key in seen_appearances:
                    fail(f"{name} repeats the {key} appearance")
                seen_appearances.add(str(key))
                if (key, value) == ("luminosity", "dark"):
                    appearance = "dark"
                elif (key, value) == ("contrast", "high"):
                    contrast_level = "high"
                else:
                    fail(f"{name} contains unsupported appearance {key}={value}")
            slot = (appearance, contrast_level)
            if slot in actual:
                fail(f"{name} repeats the {slot} color slot")
            color = item.get("color", {})
            if color.get("color-space") != "srgb":
                fail(f"{name} must use explicit sRGB colors")
            components = item.get("color", {}).get("components", {})
            try:
                if abs(float(components["alpha"]) - 1) > 0.0001:
                    raise ValueError("non-opaque alpha")
                channels = [components[channel] for channel in ("red", "green", "blue")]
                if any(
                    not isinstance(value, str)
                    or re.fullmatch(r"(?:0x)?[0-9A-Fa-f]{2}", value) is None
                    for value in channels
                ):
                    raise ValueError("non-hex channel")
                red, green, blue = (int(value, 16) for value in channels)
            except (KeyError, TypeError, ValueError):
                fail(f"{name} must use opaque hexadecimal sRGB components")
            actual[slot] = f"#{red:02X}{green:02X}{blue:02X}"
        if actual != expected_slots:
            fail(f"{name} drifted from its approved keyed palette: {actual}")
        if name in approved_normal and any(
            actual[slot] != frozen
            for slot, frozen in approved_normal[name].items()
        ):
            fail(f"{name} changed an approved normal-contrast value")
        if any(color in {"#FFFFFF", "#000000"} for color in actual.values()):
            fail(f"{name} must not use pure white or pure black")
        actual_palette[name] = actual

    def linear_rgb(color: str) -> tuple[float, float, float]:
        components = tuple(
            int(color[index:index + 2], 16) / 255
            for index in (1, 3, 5)
        )
        return tuple(
            value / 12.92
            if value <= 0.04045
            else ((value + 0.055) / 1.055) ** 2.4
            for value in components
        )

    def relative_luminance(color: str) -> float:
        red, green, blue = linear_rgb(color)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue

    def contrast(first: str, second: str) -> float:
        first_luminance = relative_luminance(first)
        second_luminance = relative_luminance(second)
        lighter = max(first_luminance, second_luminance)
        darker = min(first_luminance, second_luminance)
        return (lighter + 0.05) / (darker + 0.05)

    for slot in slots:
        canvases = [
            actual_palette[name][slot]
            for name in (
                "BrandBackground",
                "BrandSurface",
                "BrandSurfaceElevated",
            )
        ]
        meaningful = [actual_palette["AccentColor"][slot]] + [
            actual_palette[f"ChartSeries{index}"][slot]
            for index in range(1, 7)
        ]
        for color in meaningful:
            for canvas in canvases:
                if contrast(color, canvas) < 3:
                    fail(
                        f"meaningful graphical color {color} is below 3:1 "
                        f"against {canvas} in {slot}"
                    )
        action = actual_palette["BrandAction"][slot]
        if contrast(action, "#FFFFFF") < 4.5:
            fail(f"BrandAction does not support a white foreground in {slot}: {action}")
        for canvas_name, canvas in zip(
            ("BrandBackground", "BrandSurface", "BrandSurfaceElevated"),
            canvases,
        ):
            if contrast(action, canvas) < 3:
                fail(
                    f"BrandAction is below 3:1 against {canvas_name} "
                    f"{canvas} in {slot}"
                )

    # Replay the pre-fix dark action as an in-memory mutation. It must fail on
    # the actual elevated canvas or this guard no longer catches the regression.
    old_dark_action = "#34785F"
    dark_elevated = actual_palette["BrandSurfaceElevated"][dark_normal]
    if contrast(old_dark_action, dark_elevated) >= 3:
        fail("BrandAction dark-canvas mutation self-test no longer fails")

    def composite_srgb(
        foreground: str,
        background: str,
        opacity: float,
    ) -> str:
        """Return the final sRGB pixel after source-over alpha compositing."""
        if not 0 <= opacity <= 1:
            raise ValueError("opacity must be between zero and one")
        foreground_channels = [
            int(foreground[index:index + 2], 16)
            for index in (1, 3, 5)
        ]
        background_channels = [
            int(background[index:index + 2], 16)
            for index in (1, 3, 5)
        ]
        rendered = [
            round(front * opacity + back * (1 - opacity))
            for front, back in zip(foreground_channels, background_channels)
        ]
        return "#" + "".join(f"{channel:02X}" for channel in rendered)

    # Source guards below prove that actual BarMark opacity is 1. Validate the
    # resulting pixels, not only the uncomposited asset colors, against every
    # chart canvas. The deliberately weakened 0.34 mutation must fail this
    # same rendered-state threshold or the guardrail is not testing the bug.
    opacity_mutation_failures = 0
    for slot in slots:
        canvases = [
            actual_palette[name][slot]
            for name in (
                "BrandBackground",
                "BrandSurface",
                "BrandSurfaceElevated",
            )
        ]
        series = [
            actual_palette[f"ChartSeries{index}"][slot]
            for index in range(1, 7)
        ]
        for color in series:
            for canvas in canvases:
                rendered = composite_srgb(color, canvas, opacity=1)
                if contrast(rendered, canvas) < 3:
                    fail(
                        f"rendered chart geometry {rendered} is below 3:1 "
                        f"against {canvas} in {slot}"
                    )
                weakened = composite_srgb(color, canvas, opacity=0.34)
                if contrast(weakened, canvas) < 3:
                    opacity_mutation_failures += 1
    if opacity_mutation_failures == 0:
        fail("chart opacity mutation self-test no longer exercises a 3:1 failure")

    def lab(linear: tuple[float, float, float]) -> tuple[float, float, float]:
        red, green, blue = linear
        x = (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / 0.95047
        y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue
        z = (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / 1.08883

        def pivot(value: float) -> float:
            return (
                value ** (1 / 3)
                if value > 216 / 24389
                else (24389 / 27 * value + 16) / 116
            )

        x_value, y_value, z_value = (pivot(value) for value in (x, y, z))
        return (
            116 * y_value - 16,
            500 * (x_value - y_value),
            200 * (y_value - z_value),
        )

    def delta_e(first: tuple[float, float, float], second: tuple[float, float, float]) -> float:
        return sum((left - right) ** 2 for left, right in zip(first, second)) ** 0.5

    simulations = {
        "protan": (
            (0.152286, 1.052583, -0.204868),
            (0.114503, 0.786281, 0.099216),
            (-0.003882, -0.048116, 1.051998),
        ),
        "deutan": (
            (0.367322, 0.860646, -0.227968),
            (0.280085, 0.672501, 0.047413),
            (-0.011820, 0.042940, 0.968881),
        ),
    }

    def simulated_lab(
        color: str,
        matrix: tuple[tuple[float, float, float], ...] | None,
    ) -> tuple[float, float, float]:
        source = linear_rgb(color)
        if matrix is None:
            return lab(source)
        simulated = tuple(
            min(1.0, max(0.0, sum(row[index] * source[index] for index in range(3))))
            for row in matrix
        )
        return lab(simulated)

    # This is a deliberately conservative automated heuristic, not a claim of
    # clinical perception equivalence. Labels and geometry remain mandatory.
    for slot in slots:
        series = [
            actual_palette[f"ChartSeries{index}"][slot]
            for index in range(1, 7)
        ]
        for simulation, matrix in {"standard": None, **simulations}.items():
            values = [simulated_lab(color, matrix) for color in series]
            for index, first in enumerate(values):
                difference = delta_e(first, values[(index + 1) % len(values)])
                if difference < 30:
                    fail(
                        f"adjacent chart series {index + 1}/"
                        f"{(index + 1) % len(values) + 1} are too similar "
                        f"in {slot} under {simulation} simulation: {difference:.1f}"
                    )

    widget_source = (
        ROOT / "App" / "MoneyUpWidget" / "MoneyUpWidget.swift"
    ).read_text(encoding="utf-8")
    if "colors: [Color.moneyUpAction, Color.moneyUpActionDeep]" not in widget_source:
        fail("widget action gradient must keep every white-bearing stop contrast-safe")
    widget_palette = {
        "moneyUpSoftGreen": {
            light_normal: "#34785F",
            dark_normal: "#82CEAE",
            light_high: "#1F6047",
            dark_high: "#A4E7CA",
        },
        "moneyUpAction": {
            light_normal: "#34785F",
            dark_normal: "#347F60",
            light_high: "#245F49",
            dark_high: "#377B61",
        },
        "moneyUpActionDeep": {
            light_normal: "#255C48",
            dark_normal: "#255C48",
            light_high: "#174A37",
            dark_high: "#32765B",
        },
        "moneyUpWidgetBackground": {
            light_normal: "#F7F9F6",
            dark_normal: "#18211D",
            light_high: "#FCFDFB",
            dark_high: "#121A16",
        },
    }

    def ui_color_return(color: str) -> str:
        red, green, blue = (int(color[index:index + 2], 16) for index in (1, 3, 5))
        return (
            "returnUIColor("
            f"red:{red}.0/255.0,"
            f"green:{green}.0/255.0,"
            f"blue:{blue}.0/255.0,alpha:1)"
        )

    token_positions = {
        name: widget_source.index(f"static let {name}")
        for name in widget_palette
    }
    ordered_tokens = list(widget_palette)
    for token_index, name in enumerate(ordered_tokens):
        start = token_positions[name]
        end = (
            token_positions[ordered_tokens[token_index + 1]]
            if token_index + 1 < len(ordered_tokens)
            else widget_source.index("private struct MoneyUpQuickActionsWidget")
        )
        block = widget_source[start:end]
        compact_block = re.sub(r"\s+", "", block)
        colors = widget_palette[name]
        expected_provider = (
            f"staticlet{name}=Color(uiColor:UIColor{{traitsin"
            "iftraits.accessibilityContrast==.high{"
            "iftraits.userInterfaceStyle==.dark{"
            f"{ui_color_return(colors[dark_high])}}}"
            f"{ui_color_return(colors[light_high])}}}"
        )
        if colors[dark_normal] != colors[light_normal]:
            expected_provider += (
                "iftraits.userInterfaceStyle==.dark{"
                f"{ui_color_return(colors[dark_normal])}}}"
            )
        expected_provider += f"{ui_color_return(colors[light_normal])}}})"
        if expected_provider not in compact_block:
            fail(
                f"widget semantic token {name} lost an appearance/contrast-keyed color"
            )

    widget_slots = {
        slot: (
            widget_palette["moneyUpAction"][slot],
            widget_palette["moneyUpActionDeep"][slot],
            widget_palette["moneyUpWidgetBackground"][slot],
        )
        for slot in slots
    }
    for slot, (action, deep_action, background) in widget_slots.items():
        for stop in (action, deep_action):
            if contrast(stop, "#FFFFFF") < 4.5:
                fail(f"widget action stop {stop} is unsafe behind white in {slot}")
        if contrast(action, background) < 3:
            fail(f"widget action token is not distinguishable from its canvas in {slot}")

    if (assets / "GoldAccent.colorset" / "Contents.json").exists():
        fail("the retired gold accent must not return to the primary palette")
    if not (ROOT / "Scripts" / "generate_brand_icons.py").is_file():
        fail("app icon artwork must remain reproducible")
    theme = (ROOT / "App" / "MoneyUp" / "MoneyUpTheme.swift").read_text(
        encoding="utf-8"
    )
    if 'Image("MoneyUpBrandMark")' not in theme:
        fail("in-app brand surfaces must use the shared horned-money mark")
    if "MoneyUpGrowthMark" in theme or 'Image(systemName: "arrow.up.right")' in theme:
        fail("the retired three-bar/up-arrow brand mark must not return")
    for index in range(1, 7):
        if f'static let moneyUpChartSeries{index} = Color("ChartSeries{index}")' not in theme:
            fail(f"ChartSeries{index} must have an ordered semantic Color token")
    if "static let ordered: [Color]" not in theme:
        fail("chart series tokens must expose a stable order")

    insights_view_source = (
        ROOT / "App" / "MoneyUp" / "InsightsView.swift"
    ).read_text(encoding="utf-8")
    insights_analysis_source = (
        ROOT / "App" / "MoneyUp" / "InsightsAnalysis.swift"
    ).read_text(encoding="utf-8")
    insights_source = insights_view_source + "\n" + insights_analysis_source
    render_guard_errors = chart_render_guard_errors(
        insights_analysis_source,
        insights_view_source,
        theme,
    )
    if render_guard_errors:
        fail("; ".join(render_guard_errors))

    def mutated(source: str, anchor: str, replacement: str, label: str) -> str:
        result = source.replace(anchor, replacement, 1)
        if result == source:
            fail(f"cannot construct {label} chart mutation self-test")
        return result

    def require_mutation_rejected(
        label: str,
        analysis: str = insights_analysis_source,
        view: str = insights_view_source,
        theme_source: str = theme,
    ) -> None:
        if not chart_render_guard_errors(analysis, view, theme_source):
            fail(f"chart render guard accepted {label} mutation")

    flow_opacity_anchor = ".cornerRadius(point.kind == .income ? 5 : 0)"
    require_mutation_rejected(
        "cash-flow mark opacity",
        analysis=mutated(
            insights_analysis_source,
            flow_opacity_anchor,
            flow_opacity_anchor + "\n                .opacity(0.34)",
            "cash-flow mark opacity",
        ),
    )
    category_style_anchor = ".foregroundStyle(categoryChartColor(point, in: points))"
    require_mutation_rejected(
        "category mark opacity",
        view=mutated(
            insights_view_source,
            category_style_anchor,
            category_style_anchor + "\n                .opacity(0.34)",
            "category mark opacity",
        ),
    )

    category_return_anchor = "return MoneyUpChartPalette.color(at: index)"
    require_mutation_rejected(
        "category helper opacity",
        analysis=mutated(
            insights_analysis_source,
            category_return_anchor,
            category_return_anchor + ".opacity(0.34)",
            "category helper opacity",
        ),
    )
    require_mutation_rejected(
        "category helper alternate alpha color",
        analysis=mutated(
            insights_analysis_source,
            category_return_anchor,
            (
                "return Color(red: 0.1, green: 0.2, blue: 0.3, "
                "opacity: 0.34)"
            ),
            "category helper alternate alpha color",
        ),
    )
    require_mutation_rejected(
        "category helper indirection",
        view=mutated(
            insights_view_source,
            "categoryChartColor(point, in: points)",
            "uncertifiedCategoryChartColor(point, in: points)",
            "category helper indirection",
        ),
    )

    flow_scale_mappings = (
        (
            "income",
            'AppLocalization.string("transaction.income"): '
            "MoneyUpChartPalette.income,",
        ),
        (
            "expense",
            'AppLocalization.string("transaction.expense"): '
            "MoneyUpChartPalette.expense",
        ),
    )
    for label, anchor in flow_scale_mappings:
        require_mutation_rejected(
            f"cash-flow {label} style-scale opacity",
            analysis=mutated(
                insights_analysis_source,
                anchor,
                anchor.replace(
                    f"MoneyUpChartPalette.{label}",
                    f"MoneyUpChartPalette.{label}.opacity(0.34)",
                ),
                f"cash-flow {label} style-scale opacity",
            ),
        )

    flow_frame_anchor = ".frame(height: 240)"
    category_frame_anchor = ".frame(height: max(190, CGFloat(points.count) * 34))"
    require_mutation_rejected(
        "cash-flow parent opacity",
        analysis=mutated(
            insights_analysis_source,
            flow_frame_anchor,
            ".opacity(0.34)\n        " + flow_frame_anchor,
            "cash-flow parent opacity",
        ),
    )
    require_mutation_rejected(
        "category parent opacity",
        view=mutated(
            insights_view_source,
            category_frame_anchor,
            ".opacity(0.34)\n        " + category_frame_anchor,
            "category parent opacity",
        ),
    )
    require_mutation_rejected(
        "cash-flow card-call opacity",
        analysis=mutated(
            insights_analysis_source,
            "cashFlowChart(report, points: points)",
            "cashFlowChart(report, points: points).opacity(0.34)",
            "cash-flow card-call opacity",
        ),
    )
    require_mutation_rejected(
        "category card-call opacity",
        view=mutated(
            insights_view_source,
            "categoryChart(points)",
            "categoryChart(points).opacity(0.34)",
            "category card-call opacity",
        ),
    )
    require_mutation_rejected(
        "cash-flow Insights-parent opacity",
        view=mutated(
            insights_view_source,
            "cashFlowCard(report)",
            "cashFlowCard(report).opacity(0.34)",
            "cash-flow Insights-parent opacity",
        ),
    )
    require_mutation_rejected(
        "category Insights-parent opacity",
        view=mutated(
            insights_view_source,
            "categoryCard(report)",
            "categoryCard(report).opacity(0.34)",
            "category Insights-parent opacity",
        ),
    )
    require_mutation_rejected(
        "cash-flow parent modifier",
        analysis=mutated(
            insights_analysis_source,
            flow_frame_anchor,
            ".modifier(UncertifiedChartModifier())\n        " + flow_frame_anchor,
            "cash-flow parent modifier",
        ),
    )

    group_mutation = mutated(
        insights_analysis_source,
        "        Chart {\n",
        "        Group {\n            Chart {\n",
        "cash-flow parent group",
    )
    group_mutation = mutated(
        group_mutation,
        "        }\n        .frame(height: 240)",
        "            }\n        }\n        .opacity(0.34)\n        .frame(height: 240)",
        "cash-flow parent group opacity",
    )
    require_mutation_rejected(
        "cash-flow parent group opacity",
        analysis=group_mutation,
    )

    token_anchor = 'static let moneyUpChartSeries1 = Color("ChartSeries1")'
    require_mutation_rejected(
        "palette token opacity",
        theme_source=mutated(
            theme,
            token_anchor,
            token_anchor + ".opacity(0.34)",
            "palette token opacity",
        ),
    )

    for label, source_name, source in (
        ("cash-flow line width", "analysis", insights_analysis_source),
        ("category line width", "view", insights_view_source),
        ("cash-flow dash", "analysis", insights_analysis_source),
        ("category dash", "view", insights_view_source),
    ):
        policy_member = "lineWidth" if "line width" in label else "dash"
        policy_anchor = f"MoneyUpChartSelectionPolicy.{policy_member}"
        selection_mutation = mutated(
            source,
            policy_anchor,
            "1" if policy_member == "lineWidth" else "[]",
            label,
        )
        require_mutation_rejected(
            label,
            analysis=(
                selection_mutation
                if source_name == "analysis"
                else insights_analysis_source
            ),
            view=(
                selection_mutation
                if source_name == "view"
                else insights_view_source
            ),
        )

    require_mutation_rejected(
        "selection policy zero line width",
        theme_source=mutated(
            theme,
            "static let lineWidth: CGFloat = 2",
            "static let lineWidth: CGFloat = 0",
            "selection policy zero line width",
        ),
    )
    require_mutation_rejected(
        "selection policy empty dash",
        theme_source=mutated(
            theme,
            "static let dash: [CGFloat] = [3, 3]",
            "static let dash: [CGFloat] = []",
            "selection policy empty dash",
        ),
    )
    require_mutation_rejected(
        "selection policy zero dash segment",
        theme_source=mutated(
            theme,
            "static let dash: [CGFloat] = [3, 3]",
            "static let dash: [CGFloat] = [3, 0]",
            "selection policy zero dash segment",
        ),
    )

    non_color_encodings = {
        "income symbol": 'case .income: "plus.rectangle.fill"',
        "expense symbol": 'case .expense: "minus.rectangle"',
        "flow shape": ".cornerRadius(point.kind == .income ? 5 : 0)",
        "flow grouping": ".position(",
        "flow accessible value": ".accessibilityValue(formattedMoney(point.money))",
        "category label": "Text(point.name)",
        "category amount annotation": ".annotation(position: .trailing)",
        "ordered category color": "categoryChartColor(point, in: points)",
        "flow selection rule": "if let selectedFlowMonth {",
        "category selection rule": "if let selectedCategoryKey {",
    }
    for encoding, snippet in non_color_encodings.items():
        if snippet not in insights_source:
            fail(f"chart color requires retained non-color {encoding} encoding")
    if (
        "MoneyUpChartPalette.income" not in insights_source
        or "MoneyUpChartPalette.expense" not in insights_source
    ):
        fail("cash-flow series must use the ordered semantic chart palette")
    try:
        category_color_start = insights_analysis_source.index(
            "func categoryChartColor("
        )
        category_color_end = insights_analysis_source.index(
            "func flowChartSummary(",
            category_color_start,
        )
    except ValueError:
        fail("cannot locate the category chart color policy")
    category_color_source = insights_analysis_source[
        category_color_start:category_color_end
    ]
    if (
        "point.isAggregate" in category_color_source
        or "return .secondary" in category_color_source
        or category_color_source.count("MoneyUpChartPalette.color(at:") != 2
    ):
        fail("every category bar, including Other, must use a validated palette slot")
    for path in (ROOT / "App" / "MoneyUp").glob("*.swift"):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if ".buttonStyle(.borderedProminent)" not in line:
                continue
            nearby = "\n".join(lines[index + 1:index + 5])
            if ".tint(.moneyUpAction)" not in nearby:
                fail(
                    f"{path.relative_to(ROOT)}:{index + 1} prominent action "
                    "must use the contrast-safe BrandAction token"
                )
    print("Validated appearance/contrast-keyed semantic and chart palette")


def validate_design_primitive_usage() -> None:
    app_root = ROOT / "App" / "MoneyUp"
    feedback_path = app_root / "MoneyUpFeedback.swift"
    for path in app_root.glob("*.swift"):
        if path == feedback_path:
            continue
        if "sensoryFeedback(" in path.read_text(encoding="utf-8"):
            fail(
                f"{path.relative_to(ROOT)} bypasses the governed "
                "MoneyUpFeedback boundary"
            )

    feedback_source = feedback_path.read_text(encoding="utf-8")
    feedback_errors = feedback_primitive_guard_errors(feedback_source)
    if feedback_errors:
        fail("; ".join(feedback_errors))
    if "policy.requiresVisibleStatus || visibleStatus" not in feedback_source:
        fail("feedback visible-status policy guard is missing")

    def require_feedback_mutation_rejected(
        label: str,
        anchor: str,
        replacement: str,
    ) -> None:
        mutation = feedback_source.replace(anchor, replacement, 1)
        if mutation == feedback_source:
            fail(f"cannot construct {label} feedback mutation self-test")
        if not feedback_primitive_guard_errors(mutation):
            fail(f"feedback guard accepted {label} mutation")

    require_feedback_mutation_rejected(
        "detached modifier",
        "self.sensoryFeedback(trigger: trigger)",
        "self",
    )
    require_feedback_mutation_rejected(
        "unobserved old trigger",
        "previousTrigger: oldTrigger",
        "previousTrigger: newTrigger",
    )
    require_feedback_mutation_rejected(
        "unconditional visible status",
        "currentTrigger: newTrigger,\n                visibleStatus: visibleStatus",
        "currentTrigger: newTrigger,\n                visibleStatus: true",
    )

    theme_source = (app_root / "MoneyUpTheme.swift").read_text(encoding="utf-8")
    for declaration in [
        "if reduceTransparency {",
        "borderStyle: .solid",
        "case .solid:",
        "Color.primary.opacity(appearance.primaryBorderOpacity)",
    ]:
        if declaration not in theme_source:
            fail(f"Reduce Transparency card policy is missing {declaration}")

    typography_source = (app_root / "MoneyUpTypography.swift").read_text(
        encoding="utf-8"
    )
    for declaration in [
        "for: .financialValue",
        "if motion == .immediate { transaction.animation = nil }",
        "usesMonospacedDigits: policy.usesMonospacedDigits",
    ]:
        if declaration not in typography_source:
            fail(f"financial-value runtime policy is missing {declaration}")

    quick_log_source = "\n".join(
        (app_root / name).read_text(encoding="utf-8")
        for name in (
            "QuickLogEntryBody.swift",
            "QuickLogEntryCommit.swift",
            "LockedQuickCaptureView.swift",
        )
    )
    for declaration in [
        ".moneyUpFeedback(",
        "MoneyUpMotion.confirmationTransition(",
        "MoneyUpMotion.animation(",
    ]:
        if declaration not in quick_log_source:
            fail(f"Quick Log primitive adoption is missing {declaration}")
    if "QuickLogMotionPolicy" in quick_log_source:
        fail("Quick Log must not shadow the governed MoneyUpMotion policy")
    print("Validated governed visual, motion, and feedback primitive usage")


def validate_release_traceability() -> None:
    targets = (
        "MoneyUpCoreTests",
        "MoneyUpPersistenceTests",
        "MoneyUpIntelligenceTests",
        "MoneyUpAppTests",
        "MoneyUpPerformanceTests",
    )
    actual: dict[str, tuple[int, int]] = {}
    for target in targets:
        source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "Tests" / target).glob("*.swift"))
        )
        actual[target] = (
            len(re.findall(r"^\s*func\s+test\w*\s*\(", source, re.MULTILINE)),
            len(re.findall(r"^\s*@Test\b", source, re.MULTILINE)),
        )

    matrix = (ROOT / "docs" / "REQUIREMENTS_TEST_MATRIX.md").read_text(
        encoding="utf-8"
    )
    declared = re.search(
        r"Declared automated tests in source after this review: \*\*(\d+)\*\* "
        r"\((\d+) core, (\d+)\s+persistence, (\d+) intelligence, (\d+) "
        r"app-target, and (\d+) performance-target\s+declarations",
        matrix,
    )
    declaration_kinds = re.search(
        r"\*\*(\d+)\*\* are XCTest\s+functions named `test\.\.\.`; "
        r"the\s+remaining (\d+) are Swift Testing `@Test`",
        matrix,
    )
    if declared is None or declaration_kinds is None:
        fail("test-count traceability format drifted")
    target_totals = tuple(sum(actual[target]) for target in targets)
    xctest_total = sum(counts[0] for counts in actual.values())
    swift_testing_total = sum(counts[1] for counts in actual.values())
    declared_values = tuple(int(value) for value in declared.groups())
    expected_values = (sum(target_totals), *target_totals)
    if declared_values != expected_values:
        fail(
            "declared per-target test accounting drifted: "
            f"document {declared_values}, source {expected_values}"
        )
    declared_kinds_values = tuple(
        int(value) for value in declaration_kinds.groups()
    )
    if declared_kinds_values != (xctest_total, swift_testing_total):
        fail(
            "declared test-kind accounting drifted: "
            f"document {declared_kinds_values}, "
            f"source {(xctest_total, swift_testing_total)}"
        )

    golden = (ROOT / "docs" / "GOLDEN_TRACEABILITY.md").read_text(
        encoding="utf-8"
    )
    for identifier in (
        "W6-PRIM",
        "W6-MOTION",
        "W6-KEY",
        "W6-CHART",
        "W6-WIDGET",
    ):
        row = f"| {identifier} |"
        if row not in matrix or row not in golden:
            fail(f"W6 acceptance traceability is missing {identifier}")
    print("Validated exact test accounting and W6 acceptance traceability")


def validate_public_documents() -> None:
    for name in [
        "PRIVACY.md",
        "SUPPORT.md",
        "docs/APPLE_SETUP.md",
        "docs/LAUNCH_PLAN.md",
        "docs/FIRST_TEST.md",
    ]:
        path = ROOT / name
        if not path.is_file() or path.stat().st_size < 200:
            fail(f"missing or incomplete release document: {name}")
        text = path.read_text(encoding="utf-8")
        if "TODO" in text or "TBD" in text:
            fail(f"release document still contains a placeholder: {name}")
    print("Validated public policy, support, launch, and tester documents")


def validate_release_fixture_generator() -> None:
    script = ROOT / "Scripts" / "generate_release_fixture.py"
    if not script.is_file():
        fail("release-scale fixture generator is missing")

    with tempfile.TemporaryDirectory(prefix="moneyup-release-fixture-") as directory:
        first = Path(directory) / "first.csv"
        second = Path(directory) / "second.csv"
        command = [
            sys.executable,
            str(script),
            "--entries",
            "10000",
            "--output",
        ]
        try:
            subprocess.run(
                [*command, str(first)],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [*command, str(second)],
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"cannot generate release-scale fixture: {error}")

        if first.read_bytes() != second.read_bytes():
            fail("release-scale fixture is not deterministic")
        expected_release_hash = (
            "d8525ca07b554e0d8a2d9e23cb24ed8010495148527e95560f3c5b319ce859ea"
        )
        if hashlib.sha256(first.read_bytes()).hexdigest() != expected_release_hash:
            fail("default release fixture bytes drifted")
        if first.stat().st_size >= 10_000_000:
            fail("10,000-entry fixture exceeds the app's 10 MB import limit")

        with first.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            rows = list(reader)
        expected_headers = ["id", "date", "kind", "amount", "payee", "note"]
        if reader.fieldnames != expected_headers:
            fail(f"release fixture has unexpected headers: {reader.fieldnames}")
        if len(rows) != 10_000:
            fail(f"release fixture contains {len(rows)} rows instead of 10,000")
        if rows[0]["id"] != "moneyup-release-fixture-00001":
            fail("release fixture first identity drifted")
        if rows[-1]["id"] != "moneyup-release-fixture-10000":
            fail("release fixture last identity drifted")
        if len({row["id"] for row in rows}) != len(rows):
            fail("release fixture identities must be unique")
        if len({row["date"] for row in rows}) != len(rows):
            fail("release fixture timestamps must be unique")
        if any(row["kind"] != "expense" for row in rows):
            fail("release fixture must use the reviewed expense-only shape")
        if any(
            re.fullmatch(r"[1-9][0-9]*\.[0-9]{2}", row["amount"]) is None
            for row in rows
        ):
            fail("release fixture contains an invalid amount")

        intelligence_first = Path(directory) / "intelligence-first.csv"
        intelligence_second = Path(directory) / "intelligence-second.csv"
        oracle_first = Path(directory) / "oracle-first.json"
        oracle_second = Path(directory) / "oracle-second.json"
        intelligence_command = [
            sys.executable,
            str(script),
            "--profile",
            "intelligence",
            "--entries",
            "10000",
        ]
        try:
            subprocess.run(
                [
                    *intelligence_command,
                    "--output", str(intelligence_first),
                    "--oracle", str(oracle_first),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [
                    *intelligence_command,
                    "--output", str(intelligence_second),
                    "--oracle", str(oracle_second),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"cannot generate intelligence fixture: {error}")
        if intelligence_first.read_bytes() != intelligence_second.read_bytes():
            fail("intelligence fixture is not deterministic")
        if oracle_first.read_bytes() != oracle_second.read_bytes():
            fail("intelligence oracle is not deterministic")
        expected_intelligence_hash = (
            "92fe646bbcc7e52fc11a340266a194d3d18b1b147ef70ff53ffab1026a495df5"
        )
        expected_oracle_hash = (
            "4c33ed9e0b8082a6c5af936fe7399195c30f4045a01583bad5c6eaccd6945fa5"
        )
        if (
            hashlib.sha256(intelligence_first.read_bytes()).hexdigest()
            != expected_intelligence_hash
        ):
            fail("intelligence logical CSV payload digest drifted")
        if (
            hashlib.sha256(oracle_first.read_bytes()).hexdigest()
            != expected_oracle_hash
        ):
            fail("intelligence oracle digest drifted")
        committed_oracle = (
            ROOT / "Tests" / "MoneyUpIntelligenceTests" / "Fixtures"
            / "MoneyUp-Intelligence-Oracle.json"
        )
        if not committed_oracle.is_file():
            fail("committed intelligence oracle is missing")
        if committed_oracle.read_bytes() != oracle_first.read_bytes():
            fail("committed intelligence oracle drifted from its generator")
        with intelligence_first.open(
            "r", encoding="utf-8", newline=""
        ) as handle:
            intelligence_reader = csv.DictReader(handle)
            intelligence_rows = list(intelligence_reader)
        expected_intelligence_headers = [
            "id", "day", "kind", "amount", "currency", "payee_key",
            "account_id", "category_id", "secondary_category_id",
            "destination_account_id", "shape", "scenario",
        ]
        if intelligence_reader.fieldnames != expected_intelligence_headers:
            fail("intelligence fixture headers drifted")
        if len(intelligence_rows) != 10_000:
            fail("intelligence fixture must contain exactly 10,000 rows")
        if len({row["id"] for row in intelligence_rows}) != 10_000:
            fail("intelligence fixture identities must be unique")
        if {row["currency"] for row in intelligence_rows} != {
            "KWD", "SGD", "USD"
        }:
            fail("intelligence fixture must contain exactly three currencies")
        if not {"refund", "transfer"}.issubset({
            row["kind"] for row in intelligence_rows
        }):
            fail("intelligence fixture is missing refund or transfer rows")
        if not {"single", "split", "transfer"}.issubset({
            row["shape"] for row in intelligence_rows
        }):
            fail("intelligence fixture is missing a reviewed transaction shape")
        oracle = json.loads(oracle_first.read_text(encoding="utf-8"))
        if oracle.get("profile") != "intelligence-v1":
            fail("intelligence oracle profile drifted")
        if oracle.get("profile_entry_count") != 10_000:
            fail("intelligence oracle count drifted")
        if len(oracle.get("expected_findings", [])) != 6:
            fail("intelligence oracle must plant exactly six positive findings")
        expected_kinds = {
            "recurrence", "lapsed_subscription", "price_increase",
            "possible_duplicate", "category_anomaly",
        }
        if {
            item.get("kind") for item in oracle["expected_findings"]
        } != expected_kinds:
            fail("intelligence oracle finding kinds drifted")
        planted = oracle.get("planted_rows", [])
        if intelligence_rows[:len(planted)] != planted:
            fail("intelligence fixture no longer begins with its planted oracle")
        if len(oracle.get("negative_scenarios", [])) != 3:
            fail("intelligence oracle negative cases drifted")

    runbook = (ROOT / "docs" / "FIRST_TEST.md").read_text(encoding="utf-8")
    for declaration in [
        "Scripts/generate_release_fixture.py",
        "10,000",
        "20 long-lived schedules",
        "Data inventory",
        "--profile intelligence",
        "MoneyUp-Intelligence-Oracle.json",
        "three currencies",
    ]:
        if declaration not in runbook:
            fail(f"first-test runbook is missing release-fixture step: {declaration}")
    print("Validated deterministic 10,000-entry release fixture and runbook")


def validate_project_configuration() -> None:
    path = ROOT / "project.yml"
    try:
        spec = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read project.yml: {error}")

    if "SWIFT_EMIT_LOC_STRINGS: YES" not in spec:
        fail("project.yml must enable compiler extraction of Swift strings")
    if "SWIFT_TREAT_WARNINGS_AS_ERRORS: YES" not in spec:
        fail("project.yml must treat app and widget warnings as errors")
    if "DEBUG_INFORMATION_FORMAT: dwarf-with-dsym" not in spec:
        fail("project.yml must emit dSYMs for release crash diagnosis")
    if "UIColorName: BrandBackground" not in spec:
        fail("the launch screen must use the adaptive non-pure brand background")
    if spec.count("CODE_SIGN_STYLE: Automatic") != 2:
        fail(
            "MoneyUp and MoneyUpWidget must use automatic signing"
        )
    if "CODE_SIGN_IDENTITY:" in spec:
        fail(
            "automatic signing must not force a code-sign identity; "
            "Apple Distribution signing occurs during export"
        )
    entitlement_contract = {
        "App/MoneyUp/MoneyUp.entitlements": "App/MoneyUp/MoneyUp.entitlements",
        "App/MoneyUpWidget/MoneyUpWidget.entitlements": (
            "App/MoneyUpWidget/MoneyUpWidget.entitlements"
        ),
    }
    discovered_entitlements = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "App").rglob("*.entitlements")
    }
    if discovered_entitlements != set(entitlement_contract):
        fail(
            "only the reviewed app/widget App Group entitlements may ship: "
            f"{sorted(discovered_entitlements)}"
        )
    for relative_path, declared_path in entitlement_contract.items():
        if f"CODE_SIGN_ENTITLEMENTS: {declared_path}" not in spec:
            fail(f"project.yml does not sign with {declared_path}")
        with (ROOT / relative_path).open("rb") as handle:
            entitlement = plistlib.load(handle)
        if entitlement != {
            "com.apple.security.application-groups": [
                "group.com.laiwenkang.MoneyUp"
            ]
        }:
            fail(f"unexpected capability in {relative_path}")
    if "SystemCapabilities" in spec or re.search(
        r"^\s+capabilities:\s*$", spec, re.MULTILINE
    ):
        fail(
            "Xcode capabilities require a signing-flow review before the "
            "unsigned archive path can be used"
        )

    lines = spec.splitlines()
    try:
        start = lines.index("  MoneyUpWidget:") + 1
    except ValueError:
        fail("project.yml does not define MoneyUpWidget")
    end = len(lines)
    for index in range(start, len(lines)):
        line = lines[index]
        indentation = len(line) - len(line.lstrip(" "))
        if line.strip() and indentation < 4:
            end = index
            break
    widget = "\n".join(lines[start:end])
    required = [
        "CFBundleShortVersionString: $(MARKETING_VERSION)",
        "CFBundleVersion: $(CURRENT_PROJECT_VERSION)",
        "CODE_SIGN_STYLE: Automatic",
        "APPLICATION_EXTENSION_API_ONLY: YES",
    ]
    for declaration in required:
        if declaration not in widget:
            fail(f"MoneyUpWidget is missing {declaration}")

    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    if f'revision: "{SQLCIPHER_REVISION}"' not in package:
        fail("SQLCipher.swift must remain pinned to its reviewed commit")
    if package.count(".package(") != 1:
        fail("SQLCipher.swift must remain the only runtime package dependency")

    performance_target_match = re.search(
        r"(?ms)^  MoneyUpPerformanceTests:\n"
        r"(?P<body>.*?)(?=^  [A-Za-z][A-Za-z0-9]*:\n|^schemes:\n)",
        spec,
    )
    if performance_target_match is None:
        fail("project.yml must define the MoneyUpPerformanceTests target")
    performance_target = performance_target_match.group("body")
    for declaration in [
        "type: bundle.unit-test",
        "platform: iOS",
        "path: Tests/MoneyUpPerformanceTests",
        (
            "path: Tests/MoneyUpIntelligenceTests/Fixtures/"
            "MoneyUp-Intelligence-Oracle.json"
        ),
        "buildPhase: resources",
        "product: MoneyUpCore",
        "product: MoneyUpPersistence",
        "product: MoneyUpIntelligence",
        "TEST_HOST: \"\"",
        "BUNDLE_LOADER: \"\"",
    ]:
        if declaration not in performance_target:
            fail(f"MoneyUpPerformanceTests is missing {declaration}")
    if "target: MoneyUp" in performance_target:
        fail("Release performance tests must not enable app @testable imports")

    performance_scheme_match = re.search(
        r"(?ms)^  MoneyUpPerformance:\n(?P<body>.*)\Z",
        spec,
    )
    if performance_scheme_match is None:
        fail("project.yml must define the MoneyUpPerformance scheme")
    performance_scheme = performance_scheme_match.group("body")
    for declaration in [
        "MoneyUpPerformanceTests: [test]",
        "config: Release",
        "gatherCoverageData: false",
        "name: MoneyUpPerformanceTests",
        "parallelizable: false",
        "randomExecutionOrder: false",
    ]:
        if declaration not in performance_scheme:
            fail(f"MoneyUpPerformance scheme is missing {declaration}")

    print(
        "Validated app/widget signing and the serial Release performance target"
    )


def validate_performance_baseline() -> None:
    root = ROOT / "Tests" / "MoneyUpPerformanceTests"
    required_files = {
        "MoneyUpPerformanceTests.swift",
        "PerformanceAsync.swift",
        "PerformanceFixture.swift",
        "PerformanceIntelligenceCorpus.swift",
        "PerformanceOperations.swift",
    }
    discovered = {path.name for path in root.glob("*.swift")}
    if discovered != required_files:
        fail(
            "performance harness files drifted: "
            f"expected {sorted(required_files)}, found {sorted(discovered)}"
        )
    source = "\n".join(
        (root / name).read_text(encoding="utf-8")
        for name in sorted(required_files)
    )
    for declaration in [
        "static let journalEntryCount = 10_000",
        "static let scheduledTransactionCount = 20",
        "static let measurementIterationCount = 3",
        "static let measurementInvocationCount = measurementIterationCount + 1",
        "try ScheduledTransaction(",
        "BudgetEntryAttribution",
        "XCTClockMetric()",
        "XCTCPUMetric()",
        "XCTMemoryMetric()",
        "XCTStorageMetric()",
        "measure(metrics: metrics, options: options)",
        "testMeasureStoreOpenCloseBaseline",
        "testMeasureStoreLoadBaseline",
        "testMeasureSaveBaseline",
        "testMeasureHistoryPageAndQueryBaseline",
        "testMeasureExportBaseline",
        "testMeasureArchiveBaseline",
        "testMeasureRestoreBaseline",
        "testMeasureReceiptTextProcessingBaseline",
        "testMeasureProjectionBaseline",
        "testMeasureIntelligenceBaseline",
        "MoneyUpPerformanceFixture.json",
        'oracle.profile == "intelligence-v1"',
        "PerformanceIntelligenceCorpus.oracleSHA256",
        "PerformanceIntelligenceCorpus.logicalCSVPayloadSHA256",
        "intelligence.findings == corpus.expectedFindingSignatures",
        "intelligence.excludedEntryCount == 0",
        "validatePersistedOperationShapes",
        "preflight.postingEventCount",
        "preflight.amountCandidates.first",
    ]:
        if declaration not in source:
            fail(f"performance harness is missing {declaration}")
    for forbidden in [
        "baselineAverage",
        "XCTAssertLessThan",
        "XCTAssertLessThanOrEqual",
        "maximumMemory",
        "memoryCeiling",
    ]:
        if forbidden in source:
            fail(
                "performance baseline must record measurements without an "
                f"invented ceiling: {forbidden}"
            )

    tests = (root / "MoneyUpPerformanceTests.swift").read_text(encoding="utf-8")
    actual_performance_tests = xctest_method_names(source)
    if actual_performance_tests != EXPECTED_PERFORMANCE_XCTESTS:
        fail(
            "performance XCTest inventory drifted: expected "
            f"{EXPECTED_PERFORMANCE_XCTESTS}, found {actual_performance_tests}"
        )
    if re.search(
        r"(?<![A-Za-z0-9_])@Test\b",
        scan_swift(source).masked,
    ):
        fail("performance target must use only the reviewed XCTest inventory")
    open_close_match = re.search(
        r"(?ms)func testMeasureStoreOpenCloseBaseline\(\) throws \{"
        r"(?P<body>.*?)^    \}",
        tests,
    )
    if open_close_match is None:
        fail("performance harness is missing the store open+close measurement")
    open_close = open_close_match.group("body")
    for declaration in [
        "let store = try fixture.openStore",
        "await store.close()",
    ]:
        if declaration not in open_close:
            fail(f"store open+close measurement is missing {declaration}")
    if "stores.append" in open_close or "var stores:" in open_close:
        fail("store open+close measurement must not retain prior stores")

    document_path = ROOT / "docs" / "PERFORMANCE_BASELINE.md"
    if not document_path.is_file():
        fail("performance baseline evidence guide is missing")
    document = document_path.read_text(encoding="utf-8")
    for declaration in [
        "10,000",
        "20 schedules",
        "clock, CPU, memory, and logical storage-write",
        "iPhone 16 Pro",
        "iOS 18.5",
        "physical-device gates remain open",
        "no absolute memory ceiling",
        "MoneyUpPerformanceTests.xcresult",
        "performance-metrics.json",
        "performance-evidence-manifest.json",
        "intelligence-v1",
    ]:
        if declaration not in document:
            fail(f"performance baseline guide is missing {declaration}")
    print(
        "Validated logical/domain performance fixture and observational "
        "measurement contract"
    )


def xctest_method_names(source: str) -> tuple[str, ...]:
    scan = scan_swift(source)
    declarations = type_declarations(scan)
    test_case_names = {
        declaration.name.split(".")[-1]
        for declaration in declarations
        if declaration.kind == "class"
        and re.search(r"\bXCTestCase\b", declaration.header)
    }
    owner_declarations = {
        declaration
        for declaration in declarations
        if (
            declaration.kind == "class"
            and declaration.name.split(".")[-1] in test_case_names
        ) or (
            declaration.kind == "extension"
            and declaration.name.split(".")[-1] in test_case_names
        )
    }
    method_pattern = re.compile(
        r"(?m)^[ \t]*"
        r"(?:@[A-Za-z_][A-Za-z0-9_.]*(?:\([^\n]*\))?[ \t]+)*"
        r"func[ \t]+(test[A-Za-z0-9_]*)[ \t]*\("
    )
    names: list[str] = []
    for match in method_pattern.finditer(scan.masked):
        containing = [
            declaration
            for declaration in declarations
            if declaration.opening < match.start() < declaration.closing
        ]
        if not containing:
            continue
        innermost = min(
            containing,
            key=lambda declaration: declaration.closing - declaration.opening,
        )
        if innermost in owner_declarations:
            names.append(match.group(1))
    return tuple(names)


def swift_test_declaration_counts(target: str) -> tuple[int, int]:
    root = ROOT / "Tests" / target
    source = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted(root.rglob("*.swift"))
    )
    masked = scan_swift(source).masked
    xctest_count = len(xctest_method_names(source))
    swift_testing_count = len(re.findall(
        r"(?<![A-Za-z0-9_])@Test\b",
        masked,
    ))
    return xctest_count, swift_testing_count


def validate_test_declaration_inventory() -> None:
    expected_targets = {target for target, _ in SWIFT_TEST_TARGETS}
    discovered_targets = {
        path.name
        for path in (ROOT / "Tests").iterdir()
        if path.is_dir() and any(path.rglob("*.swift"))
    }
    if discovered_targets != expected_targets:
        fail(
            "Swift test-target inventory drifted: expected "
            f"{sorted(expected_targets)}, found {sorted(discovered_targets)}"
        )
    counts = {
        label: swift_test_declaration_counts(target)
        for target, label in SWIFT_TEST_TARGETS
    }
    target_totals = {
        label: xctest + swift_testing
        for label, (xctest, swift_testing) in counts.items()
    }
    total = sum(target_totals.values())
    xctest_total = sum(value[0] for value in counts.values())
    swift_testing_total = sum(value[1] for value in counts.values())

    document_path = ROOT / "docs" / "REQUIREMENTS_TEST_MATRIX.md"
    document = document_path.read_text(encoding="utf-8")
    declared = re.search(
        r"Declared automated tests in source after this review: \*\*(\d+)\*\* "
        r"\((\d+)\s+core,\s+(\d+)\s+persistence,\s+"
        r"(\d+)\s+intelligence,\s+(\d+)\s+app-target, and\s+"
        r"(\d+)\s+performance-target\s+declarations;",
        document,
    )
    kinds = re.search(
        r"those declarations, \*\*(\d+)\*\* are XCTest functions named "
        r"`test\.\.\.`; the\s+remaining (\d+) are Swift Testing `@Test` "
        r"declarations in MoneyUpCore\.",
        document,
    )
    if declared is None or kinds is None:
        fail("requirements matrix test-declaration inventory is unreadable")
    documented = tuple(map(int, (*declared.groups(), *kinds.groups())))
    actual = (
        total,
        target_totals["core"],
        target_totals["persistence"],
        target_totals["intelligence"],
        target_totals["app-target"],
        target_totals["performance-target"],
        xctest_total,
        swift_testing_total,
    )
    if documented != actual:
        fail(
            "requirements matrix test-declaration inventory drifted: "
            f"expected {actual}, found {documented}"
        )
    if counts["core"][1] != swift_testing_total:
        fail("Swift Testing declarations must remain confined to MoneyUpCore")
    print(
        f"Validated {total} declared Swift tests: {xctest_total} XCTest and "
        f"{swift_testing_total} Swift Testing declarations"
    )


def validate_swift_structure() -> None:
    validator = ROOT / "Scripts" / "validate_swift_structure.py"
    result = subprocess.run(
        [sys.executable, str(validator)],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"Swift structure validation failed:\n{detail}")
    print(result.stdout.strip())


def validate_architecture_fitness() -> None:
    validator = ROOT / "Scripts" / "validate_architecture_fitness.py"
    result = subprocess.run(
        [sys.executable, str(validator)],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"Architecture fitness validation failed:\n{detail}")
    print(result.stdout.strip())


def validate_performance_signposts() -> None:
    validator = ROOT / "Scripts" / "validate_performance_signposts.py"
    result = subprocess.run(
        [sys.executable, str(validator)],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"performance-signpost validation failed:\n{detail}")
    print(result.stdout.strip())


def validate_accessible_errors() -> None:
    validator = ROOT / "Scripts" / "validate_accessible_errors.py"
    result = subprocess.run(
        [sys.executable, str(validator)],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"Accessible error validation failed:\n{detail}")
    print(result.stdout.strip())


def validate_platform_actions() -> None:
    validator = ROOT / "Scripts" / "validate_platform_actions.py"
    result = subprocess.run(
        [sys.executable, str(validator)],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"platform-action validation failed:\n{detail}")
    print(result.stdout.strip())


def workflow_step(workflow: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      - name: {re.escape(name)}\n"
        r"(?P<body>.*?)(?=^      - name: |\Z)",
        workflow,
    )
    if match is None:
        fail(f"workflow is missing the {name!r} step")
    return match.group("body")


def validate_action_revisions(workflow: str, workflow_name: str) -> None:
    expected = {
        "actions/checkout": CHECKOUT_ACTION_REVISION,
        "actions/upload-artifact": UPLOAD_ARTIFACT_REVISION,
    }
    for action, revision in expected.items():
        references = re.findall(rf"{re.escape(action)}@([^\s#]+)", workflow)
        if action == "actions/upload-artifact" and not references:
            fail(f"{workflow_name} must retain test or release evidence")
        if action == "actions/checkout" and not references:
            fail(f"{workflow_name} must check out its source candidate")
        if any(reference != revision for reference in references):
            fail(
                f"{workflow_name} must pin every {action} use to reviewed "
                f"commit {revision}"
            )


def validate_ci_workflow() -> None:
    path = ROOT / ".github" / "workflows" / "ci.yml"
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read CI workflow: {error}")

    validate_action_revisions(workflow, "CI workflow")
    required = [
        f"XCODEGEN_VERSION: {XCODEGEN_VERSION}",
        f"XCODEGEN_SHA256: {XCODEGEN_SHA256}",
        f'CI_XCODE_VERSION: "{CI_XCODE_VERSION}"',
        f"CI_XCODE_BUILD: {CI_XCODE_BUILD}",
        (
            "CI_IPHONESIMULATOR_SDK_VERSION: "
            f'"{CI_IPHONESIMULATOR_SDK_VERSION}"'
        ),
        "runs-on: macos-15",
        "Enforce Swift structure limits",
        "python3 Scripts/validate_swift_structure.py",
        "Test architecture fitness validator",
        "python3 -m unittest discover -s Scripts/tests",
        "-p 'test_validate_architecture_fitness.py'",
        "Enforce architecture fitness",
        "python3 Scripts/validate_architecture_fitness.py",
        "Enforce accessible error presentation",
        "python3 Scripts/validate_accessible_errors.py",
        "DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer",
        "Verify the exact CI Xcode toolchain",
        "Verify the exact CI Xcode and simulator SDK",
        "XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip",
        "shasum -a 256 -c -",
        "swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "-enableCodeCoverage YES",
        "-resultBundlePath \"$RESULT_BUNDLE\"",
        "core-tests.log",
        "core-persistence-coverage.json",
        "app-model-coverage.json",
        "${{ runner.temp }}/MoneyUpTests.xcresult",
        f"PERFORMANCE_DEVICE_NAME: {CI_PERFORMANCE_DEVICE_NAME}",
        (
            "PERFORMANCE_RUNTIME_IDENTIFIER: "
            f"{CI_PERFORMANCE_RUNTIME_IDENTIFIER}"
        ),
        "iPhone Simulator performance baseline",
        "MoneyUpPerformanceTests.xcresult",
        "performance-environment.json",
        "performance-evidence-manifest.json",
        "performance-metrics.json",
        "performance-summary.json",
        "iphone-simulator-performance-baseline",
        '"total_invocation_count": 4',
        '"corpus_profile": "intelligence-v1"',
        '"store_open_close"',
        (
            '"logical_csv_payload_sha256":\n'
            '                  "92fe646bbcc7e52fc11a340266a194d3d18b1b147ef70ff53ffab1026a495df5"'
        ),
        (
            '"oracle_sha256":\n'
            '                  "4c33ed9e0b8082a6c5af936fe7399195c30f4045a01583bad5c6eaccd6945fa5"'
        ),
        '"physical_device_gates": "open"',
        "if: ${{ always() }}",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"CI workflow is missing {declaration}")

    if workflow.count("runs-on: macos-15") != 3:
        fail("all three Swift CI jobs must run on the reviewed macos-15 image")
    if workflow.count(
        "DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer"
    ) != 3:
        fail("all three Swift CI jobs must select the reviewed Xcode 16.4 bundle")

    core_toolchain = workflow_step(workflow, "Verify the exact CI Xcode toolchain")
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '"$XCODE_VERSION_LINE" != "Xcode $CI_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $CI_XCODE_BUILD"',
    ]:
        if declaration not in core_toolchain:
            fail(f"CI core toolchain check is missing {declaration}")

    ios_toolchain = workflow_step(
        workflow, "Verify the exact CI Xcode and simulator SDK"
    )
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '"$XCODE_VERSION_LINE" != "Xcode $CI_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $CI_XCODE_BUILD"',
        '"$SDK_VERSION" != "$CI_IPHONESIMULATOR_SDK_VERSION"',
        "xcrun --sdk iphonesimulator --show-sdk-version",
    ]:
        if declaration not in ios_toolchain:
            fail(f"CI simulator toolchain check is missing {declaration}")

    for wildcard in [
        f"{CI_XCODE_VERSION}*",
        f"{CI_IPHONESIMULATOR_SDK_VERSION}*",
    ]:
        if wildcard in workflow:
            fail(f"CI toolchain checks must use exact equality, not {wildcard}")

    performance_toolchain = workflow_step(
        workflow, "Verify the exact performance toolchain and runtime"
    )
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '"$XCODE_VERSION_LINE" != "Xcode $CI_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $CI_XCODE_BUILD"',
        '"$SDK_VERSION" != "$CI_IPHONESIMULATOR_SDK_VERSION"',
        "xcrun simctl list runtimes available --json",
        'runtime.get("identifier") == expected',
        'matches[0].get("version") != "18.5"',
    ]:
        if declaration not in performance_toolchain:
            fail(f"performance toolchain check is missing {declaration}")

    simulator_selection = workflow_step(
        workflow, "Select and boot the exact iPhone 16 Pro iOS 18.5 Simulator"
    )
    for declaration in [
        '"$PERFORMANCE_RUNTIME_IDENTIFIER" "$PERFORMANCE_DEVICE_NAME"',
        'device.get("name") == name',
        'json.load(source)["devices"].get(runtime, [])',
        'xcrun simctl erase "$SIMULATOR_UDID"',
        'xcrun simctl boot "$SIMULATOR_UDID"',
        'xcrun simctl bootstatus "$SIMULATOR_UDID" -b',
        "PERFORMANCE_SIMULATOR_UDID=",
    ]:
        if declaration not in simulator_selection:
            fail(f"performance simulator selection is missing {declaration}")

    performance_run = workflow_step(
        workflow, "Run serial Release performance baseline"
    )
    for declaration in [
        "-scheme MoneyUpPerformance",
        "-configuration Release",
        'platform=iOS Simulator,id=$PERFORMANCE_SIMULATOR_UDID',
        "-only-testing:MoneyUpPerformanceTests",
        "-parallel-testing-enabled NO",
        "-maximum-parallel-testing-workers 1",
        "-enableCodeCoverage NO",
        '-resultBundlePath "$RESULT_BUNDLE"',
        "performance-tests.log",
    ]:
        if declaration not in performance_run:
            fail(f"performance test run is missing {declaration}")

    evidence_export = workflow_step(
        workflow, "Export machine-readable performance evidence"
    )
    for declaration in [
        "if: ${{ always() }}",
        "xcresulttool get test-results summary",
        "xcresulttool get test-results metrics",
        "performance-summary.json",
        "performance-evidence-manifest.json",
        "performance-metrics.json",
        "python3 -m json.tool",
        "python3 -m json.tool performance-environment.json",
        "python3 -m json.tool performance-runtimes.json",
        "python3 -m json.tool performance-evidence-manifest.json",
        'test -s "$evidence_file"',
        'result_bundle.is_dir()',
        "test -s performance-tests.log",
    ]:
        if declaration not in evidence_export:
            fail(f"performance evidence export is missing {declaration}")

    evidence_retention = workflow_step(
        workflow, "Preserve performance baseline evidence"
    )
    for declaration in [
        "if: ${{ always() }}",
        "actions/upload-artifact@",
        "iphone-simulator-performance-baseline",
        "performance-environment.json",
        "performance-evidence-manifest.json",
        "performance-metrics.json",
        "performance-summary.json",
        "${{ runner.temp }}/MoneyUpPerformanceTests.xcresult",
        "if-no-files-found: error",
    ]:
        if declaration not in evidence_retention:
            fail(f"performance evidence retention is missing {declaration}")

    if workflow.count("Install checksum-verified XcodeGen") != 2:
        fail("both iOS CI jobs must install checksum-verified XcodeGen")
    print(
        "Validated exact CI toolchain, immutable tools, warnings-as-errors, "
        "serial performance execution, and test evidence"
    )


def validate_testflight_workflow() -> None:
    path = ROOT / ".github" / "workflows" / "testflight.yml"
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read TestFlight workflow: {error}")

    required = [
        "workflow_dispatch:",
        "expected_sha:",
        "Optional exact main commit required by an owner-command dispatch",
        "runs-on: macos-26",
        "environment: testflight",
        "cancel-in-progress: false",
        "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
        f'RELEASE_XCODE_VERSION: "{RELEASE_XCODE_VERSION}"',
        f"RELEASE_XCODE_BUILD: {RELEASE_XCODE_BUILD}",
        f'RELEASE_IPHONEOS_SDK_VERSION: "{RELEASE_IPHONEOS_SDK_VERSION}"',
        "toolchain_fingerprint: ${{ steps.release_toolchain.outputs.fingerprint }}",
        "runner_image_fingerprint: "
        "${{ steps.release_toolchain.outputs.runner_image }}",
        "PREFLIGHT_TOOLCHAIN_FINGERPRINT: "
        "${{ needs.preflight.outputs.toolchain_fingerprint }}",
        "PREFLIGHT_RUNNER_IMAGE_FINGERPRINT: "
        "${{ needs.preflight.outputs.runner_image_fingerprint }}",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        "method -string app-store-connect",
        "signingStyle -string automatic",
        "--validate-app",
        "--upload-app",
        "uploadSymbols -bool true",
        "Scripts/validate_built_bundle.py",
        "Seed and verify archive App Group entitlements",
        "codesign --verify",
        "embedded.mobileprovision",
        "get-task-allow",
        "ProvisionedDevices",
        "ProvisionsAllDevices",
        "-disableAutomaticPackageResolution",
        "actions/upload-artifact@",
        "ARCHIVE_ENCRYPTION_PASSWORD",
        "SOURCE_BUILD_NUMBER:",
        "APP_GROUP_ID: group.com.laiwenkang.MoneyUp",
        "Verify source candidate identity and App Group contract",
        "com.apple.security.application-groups",
        "distribution profile must authorize only",
        "signed entitlements must contain only",
        "IPA_SHA256",
        "IPA_RELATIVE_PATH",
        "RECOVERY_VERIFY_DIRECTORY",
        "MoneyUp-encrypted-release-recovery-",
        "MoneyUp-Release-Recovery-",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"TestFlight workflow is missing {declaration}")

    if workflow.count("runs-on: macos-26") != 2:
        fail("both TestFlight jobs must run on the reviewed macos-26 image")
    if workflow.count(
        "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer"
    ) != 1:
        fail("TestFlight must globally select the reviewed Xcode 26.6 bundle")
    if "needs: preflight" not in workflow:
        fail("the signing job must depend on its secretless preflight")

    authorization_body = workflow_step(
        workflow, "Require main and explicit upload confirmation"
    )
    for declaration in [
        '"$GITHUB_REF" != "refs/heads/main"',
        'EXPECTED_SHA: ${{ inputs.expected_sha }}',
        '! "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$',
        '"$GITHUB_SHA" != "$EXPECTED_SHA"',
        "Main moved after the owner command was authorized.",
        '"$OPERATION" == "upload"',
        '"$CONFIRMATION" != "UPLOAD"',
    ]:
        if declaration not in authorization_body:
            fail(f"TestFlight authorization step is missing {declaration}")

    release_toolchain = workflow_step(
        workflow, "Verify the exact Apple upload toolchain"
    )
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '${ImageOS:?GitHub runner ImageOS metadata is unavailable}',
        '${ImageVersion:?GitHub runner ImageVersion metadata is unavailable}',
        '"$XCODE_VERSION_LINE" != "Xcode $RELEASE_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $RELEASE_XCODE_BUILD"',
        '"$SDK_VERSION" != "$RELEASE_IPHONEOS_SDK_VERSION"',
        "xcrun --sdk iphoneos --show-sdk-version",
        "id: release_toolchain",
        (
            'TOOLCHAIN_FINGERPRINT="${XCODE_VERSION_LINE}|${XCODE_BUILD_LINE}'
            '|iphoneos-${SDK_VERSION}|${ImageOS}"'
        ),
        'RUNNER_IMAGE_FINGERPRINT="${ImageOS}|${ImageVersion}"',
        'echo "fingerprint=$TOOLCHAIN_FINGERPRINT" >> "$GITHUB_OUTPUT"',
        'echo "runner_image=$RUNNER_IMAGE_FINGERPRINT" >> "$GITHUB_OUTPUT"',
    ]:
        if declaration not in release_toolchain:
            fail(f"release preflight toolchain check is missing {declaration}")

    signing_toolchain = workflow_step(
        workflow, "Verify the preflighted Apple upload toolchain"
    )
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '${ImageOS:?GitHub runner ImageOS metadata is unavailable}',
        '${ImageVersion:?GitHub runner ImageVersion metadata is unavailable}',
        '"$XCODE_VERSION_LINE" != "Xcode $RELEASE_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $RELEASE_XCODE_BUILD"',
        '"$SDK_VERSION" != "$RELEASE_IPHONEOS_SDK_VERSION"',
        "xcrun --sdk iphoneos --show-sdk-version",
        (
            'TOOLCHAIN_FINGERPRINT="${XCODE_VERSION_LINE}|${XCODE_BUILD_LINE}'
            '|iphoneos-${SDK_VERSION}|${ImageOS}"'
        ),
        '[[ -z "$PREFLIGHT_RUNNER_IMAGE_FINGERPRINT" ]]',
        "Preflight runner-image provenance is unavailable.",
        '"$TOOLCHAIN_FINGERPRINT" != "$PREFLIGHT_TOOLCHAIN_FINGERPRINT"',
        'RUNNER_IMAGE_FINGERPRINT="${ImageOS}|${ImageVersion}"',
        'RELEASE_TOOLCHAIN_FINGERPRINT="${TOOLCHAIN_FINGERPRINT}|${ImageVersion}"',
        'echo "RELEASE_TOOLCHAIN_FINGERPRINT=$RELEASE_TOOLCHAIN_FINGERPRINT" '
        '>> "$GITHUB_ENV"',
        'printf -- \'- Preflight runner image: `%s`\\n\'',
        'printf -- \'- Signing runner image: `%s`\\n\'',
    ]:
        if declaration not in signing_toolchain:
            fail(f"release signing toolchain check is missing {declaration}")

    for weak_check in [
        f"{RELEASE_XCODE_VERSION}*",
        f"{RELEASE_IPHONEOS_SDK_VERSION}*",
        "ImageOS:-unknown",
        "ImageVersion:-unknown",
    ]:
        if weak_check in workflow:
            fail(f"release toolchain fingerprint must not use weak check {weak_check}")

    volatile_cross_job_fingerprint = (
        'TOOLCHAIN_FINGERPRINT="${XCODE_VERSION_LINE}|${XCODE_BUILD_LINE}'
        '|iphoneos-${SDK_VERSION}|${ImageOS}|${ImageVersion}"'
    )
    if volatile_cross_job_fingerprint in workflow:
        fail(
            "cross-job release toolchain identity must not include GitHub's "
            "rolling ImageVersion"
        )

    archive_body = workflow_step(workflow, "Create an unsigned release archive")
    for declaration in [
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "clean archive",
    ]:
        if declaration not in archive_body:
            fail(f"unsigned archive step is missing {declaration}")
    for declaration in [
        "-allowProvisioningUpdates",
        "-authenticationKey",
        "CODE_SIGN_STYLE=",
        "CODE_SIGN_IDENTITY=",
    ]:
        if declaration in archive_body:
            fail(f"unsigned archive step must not contain {declaration}")

    entitlement_body = workflow_step(
        workflow, "Seed and verify archive App Group entitlements"
    )
    for declaration in [
        "App/MoneyUpWidget/MoneyUpWidget.entitlements",
        "App/MoneyUp/MoneyUp.entitlements",
        "codesign --force --sign -",
        "codesign --verify",
        "com.apple.security.application-groups",
    ]:
        if declaration not in entitlement_body:
            fail(f"archive entitlement seed step is missing {declaration}")

    debug_symbols_body = workflow_step(workflow, "Verify archive debug symbols")
    for declaration in [
        "MoneyUp.app.dSYM",
        "MoneyUpWidget.appex.dSYM",
        '"$ARCHIVE_PATH/dSYMs/$DSYM_NAME"',
    ]:
        if declaration not in debug_symbols_body:
            fail(f"archive debug-symbol check is missing {declaration}")

    export_body = workflow_step(workflow, "Export an App Store Connect IPA")
    for declaration in [
        "method -string app-store-connect",
        "destination -string export",
        "signingStyle -string automatic",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        "-authenticationKeyID",
        "-authenticationKeyIssuerID",
        "expected exactly one exported IPA",
        "IPA_SHA256=",
        "IPA_RELATIVE_PATH=",
    ]:
        if declaration not in export_body:
            fail(f"App Store Connect export step is missing {declaration}")

    validation_body = workflow_step(workflow, "Ask Apple to validate the IPA")
    for declaration in ["--validate-app", '--file "$IPA_PATH"']:
        if declaration not in validation_body:
            fail(f"Apple validation step is missing {declaration}")

    recovery_name = "Encrypt and round-trip verify the exact release recovery bundle"
    recovery_body = workflow_step(workflow, recovery_name)
    for declaration in [
        '"$ARCHIVE_RELATIVE_PATH"',
        '"$EXPORT_RELATIVE_PATH"',
        (
            "${RELEASE_TOOLCHAIN_FINGERPRINT:?Verified release toolchain "
            "fingerprint is unavailable}"
        ),
        "tree_digest()",
        'digest.update(b"MoneyUp deterministic tree digest v1\\0")',
        "ordered = sorted(entries",
        "stat.S_IMODE",
        "stat.S_ISDIR",
        "stat.S_ISREG",
        "stat.S_ISLNK",
        "metadata.st_size",
        "os.readlink(path)",
        "while chunk := source.read(1024 * 1024)",
        'test -d "$ARCHIVE_PATH/dSYMs"',
        "DSYM_COUNT=",
        "if (( DSYM_COUNT < 1 ))",
        'ARCHIVE_TREE_SHA256="$(tree_digest "$ARCHIVE_PATH")"',
        'EXPORT_TREE_SHA256="$(tree_digest "$EXPORT_DIRECTORY")"',
        "Toolchain and runner image fingerprint: $RELEASE_TOOLCHAIN_FINGERPRINT",
        "IPA SHA-256: $IPA_SHA256",
        "Archive tree SHA-256: $ARCHIVE_TREE_SHA256",
        "Export tree SHA-256: $EXPORT_TREE_SHA256",
        "openssl enc -d -aes-256-cbc",
        'tar -C "$RECOVERY_VERIFY_DIRECTORY" -xzpf -',
        'RECOVERED_ARCHIVE_TREE_SHA256="$(tree_digest "$RECOVERED_ARCHIVE")"',
        'RECOVERED_EXPORT_TREE_SHA256="$(tree_digest "$RECOVERED_EXPORT")"',
        '"$RECOVERED_ARCHIVE_TREE_SHA256" != "$ARCHIVE_TREE_SHA256"',
        '"$RECOVERED_EXPORT_TREE_SHA256" != "$EXPORT_TREE_SHA256"',
        "RECOVERED_IPA_SHA256",
        'if ! cmp -s "$IPA_PATH" "$RECOVERED_IPA"',
        'grep -Fqx "IPA: $IPA_RELATIVE_PATH"',
        (
            'grep -Fqx "Toolchain and runner image fingerprint: '
            '$RELEASE_TOOLCHAIN_FINGERPRINT"'
        ),
        'grep -Fqx "Archive tree SHA-256: $ARCHIVE_TREE_SHA256"',
        'grep -Fqx "Export tree SHA-256: $EXPORT_TREE_SHA256"',
        "xcarchive tree (including dSYMs)",
        "export tree",
        "verified byte-for-byte",
    ]:
        if declaration not in recovery_body:
            fail(f"release recovery step is missing {declaration}")

    upload_only_condition = "if: ${{ inputs.operation == 'upload' }}"
    if upload_only_condition not in recovery_body:
        fail("release recovery creation must run only for an authorized upload")

    retention_name = "Retain the encrypted exact release recovery bundle"
    retention_body = workflow_step(workflow, retention_name)
    for declaration in [
        upload_only_condition,
        "actions/upload-artifact@",
        "MoneyUp-encrypted-release-recovery-",
        "if-no-files-found: error",
        "retention-days: 90",
    ]:
        if declaration not in retention_body:
            fail(f"release recovery retention step is missing {declaration}")

    upload_name = "Upload the exact validated IPA to TestFlight"
    upload_body = workflow_step(workflow, upload_name)
    for declaration in [
        upload_only_condition,
        "UPLOAD_IPA_SHA256",
        '"$UPLOAD_IPA_SHA256" != "$IPA_SHA256"',
        "--upload-app",
        '--file "$IPA_PATH"',
        '--apiKey "$ASC_KEY_ID"',
        '--apiIssuer "$ASC_ISSUER_ID"',
    ]:
        if declaration not in upload_body:
            fail(f"exact-IPA upload step is missing {declaration}")
    if "xcodebuild" in upload_body or "-exportArchive" in upload_body:
        fail("exact-IPA upload step must not rebuild or re-export the candidate")

    if workflow.count("-exportArchive") != 1:
        fail("TestFlight must export exactly one IPA and must not re-export for upload")
    for forbidden in [
        "destination -string upload",
        "UPLOAD_OPTIONS_PATH",
        "UPLOAD_DIRECTORY",
    ]:
        if forbidden in workflow:
            fail(f"TestFlight workflow must not create a second upload binary: {forbidden}")
    if workflow.count("--upload-app") != 1:
        fail("TestFlight must upload the validated IPA exactly once")

    key_step_position = workflow.find("- name: Materialize the App Store Connect key")
    entitlement_step_position = workflow.find(
        "- name: Seed and verify archive App Group entitlements"
    )
    export_step_position = workflow.find("- name: Export an App Store Connect IPA")
    if not entitlement_step_position < key_step_position < export_step_position:
        fail(
            "the App Store Connect key must be materialized after the archive "
            "entitlement checks and before export"
        )

    validation_step_position = workflow.find("- name: Ask Apple to validate the IPA")
    recovery_step_position = workflow.find(f"- name: {recovery_name}")
    retention_step_position = workflow.find(
        f"- name: {retention_name}"
    )
    upload_step_position = workflow.find(f"- name: {upload_name}")
    if not (
        export_step_position
        < validation_step_position
        < recovery_step_position
        < retention_step_position
        < upload_step_position
    ):
        fail(
            "TestFlight must validate one IPA, preserve its verified recovery "
            "bundle, and only then upload that same IPA"
        )

    validate_action_revisions(workflow, "TestFlight workflow")
    for declaration in [
        f"XCODEGEN_VERSION: {XCODEGEN_VERSION}",
        f"XCODEGEN_SHA256: {XCODEGEN_SHA256}",
        "XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip",
        "shasum -a 256 -c -",
    ]:
        if declaration not in workflow:
            fail(f"TestFlight workflow is missing immutable tool check {declaration}")

    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    project_version = re.search(
        r"^\s+MARKETING_VERSION:\s*([^\s#]+)", project, re.MULTILINE
    )
    workflow_version = re.search(
        r"^\s+MARKETING_VERSION:\s*([^\s#]+)", workflow, re.MULTILINE
    )
    if (
        project_version is None
        or workflow_version is None
        or project_version.group(1) != workflow_version.group(1)
    ):
        fail("TestFlight workflow marketing version must match project.yml")

    project_build = re.search(
        r"^\s+CURRENT_PROJECT_VERSION:\s*([^\s#]+)", project, re.MULTILINE
    )
    workflow_source_build = re.search(
        r"^\s+SOURCE_BUILD_NUMBER:\s*([^\s#]+)", workflow, re.MULTILINE
    )
    if (
        project_build is None
        or workflow_source_build is None
        or project_build.group(1) != workflow_source_build.group(1)
    ):
        fail("TestFlight workflow source build must match project.yml")

    print("Validated protected, pinned TestFlight distribution workflow structure")


def validate_testflight_owner_command_workflow() -> None:
    path = ROOT / ".github" / "workflows" / "testflight-owner-command.yml"
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read TestFlight owner-command workflow: {error}")

    required = [
        "issue_comment:",
        "types: [created]",
        "actions: write",
        "contents: read",
        "cancel-in-progress: false",
        f"github.event.issue.number == {TESTFLIGHT_CONTROL_ISSUE}",
        "github.event.issue.pull_request == null",
        "github.actor == github.repository_owner",
        "github.event.comment.user.login == github.repository_owner",
        "github.event.comment.author_association == 'OWNER'",
        "github.event.comment.body == '/moneyup-testflight validate'",
        "github.event.comment.body == '/moneyup-testflight upload UPLOAD'",
        "runs-on: ubuntu-24.04",
        "timeout-minutes: 5",
        "GH_TOKEN: ${{ github.token }}",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"TestFlight owner-command workflow is missing {declaration}")

    for forbidden in [
        "pull_request_target:",
        "secrets.",
        "contents: write",
        "issues: write",
        "id-token: write",
        "actions/checkout@",
        "startsWith(",
        "contains(",
        "curl ",
        "wget ",
    ]:
        if forbidden in workflow:
            fail(
                "TestFlight owner-command workflow must not contain "
                f"{forbidden}"
            )

    resolve_body = workflow_step(
        workflow, "Resolve exact owner command and current main"
    )
    for declaration in [
        '"$GITHUB_ACTOR" != "$REPOSITORY_OWNER"',
        '"$COMMENT_AUTHOR" != "$REPOSITORY_OWNER"',
        '"$AUTHOR_ASSOCIATION" != "OWNER"',
        f'"$ISSUE_NUMBER" != "{TESTFLIGHT_CONTROL_ISSUE}"',
        'case "$COMMENT_BODY" in',
        '"/moneyup-testflight validate")',
        '"/moneyup-testflight upload UPLOAD")',
        "gh api --method GET",
        '"repos/$REPOSITORY/git/ref/heads/main"',
        "--jq '.object.sha'",
        '! "$MAIN_SHA" =~ ^[0-9a-f]{40}$',
        'echo "operation=$OPERATION" >> "$GITHUB_OUTPUT"',
        'echo "confirmation=$CONFIRMATION" >> "$GITHUB_OUTPUT"',
        'echo "expected_sha=$MAIN_SHA" >> "$GITHUB_OUTPUT"',
    ]:
        if declaration not in resolve_body:
            fail(f"owner-command resolution is missing {declaration}")

    dispatch_body = workflow_step(
        workflow, "Dispatch the pinned TestFlight workflow"
    )
    for declaration in [
        "workflow run testflight.yml",
        "--ref main",
        '--raw-field "operation=$OPERATION"',
        '--raw-field "expected_sha=$EXPECTED_SHA"',
        'if [[ "$OPERATION" == "upload" ]]',
        '--raw-field "confirmation=$CONFIRMATION"',
        'gh "${ARGS[@]}"',
    ]:
        if declaration not in dispatch_body:
            fail(f"owner-command dispatch is missing {declaration}")

    print("Validated owner-only, SHA-pinned TestFlight command workflow")


def main() -> None:
    validate_localizations()
    validate_offline_runtime_boundary()
    validate_security_recovery_mutation_gate()
    validate_logical_book_boundary_mutation_gate()
    validate_key_cliff_recovery_boundary()
    validate_restore_preview_boundary()
    validate_test_declaration_accounting()
    validate_privacy_manifest()
    validate_info_plist_localizations()
    validate_icons()
    validate_brand_palette()
    validate_design_primitive_usage()
    validate_release_traceability()
    validate_public_documents()
    validate_release_fixture_generator()
    validate_project_configuration()
    validate_performance_baseline()
    validate_test_declaration_inventory()
    validate_swift_structure()
    validate_architecture_fitness()
    validate_performance_signposts()
    validate_accessible_errors()
    validate_platform_actions()
    validate_ci_workflow()
    validate_testflight_workflow()
    validate_testflight_owner_command_workflow()
    print("Release asset validation passed")


if __name__ == "__main__":
    main()
