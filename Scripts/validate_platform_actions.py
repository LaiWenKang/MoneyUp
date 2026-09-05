#!/usr/bin/env python3
"""Validate MoneyUp's privacy-safe App Intent, widget, and control boundary."""

from __future__ import annotations

import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_BUNDLE_ID = "com.laiwenkang.MoneyUp"
TEST_BUNDLE_ID = "com.laiwenkang.MoneyUpTests"
PERFORMANCE_TEST_BUNDLE_ID = "com.laiwenkang.MoneyUpPerformanceTests"
WIDGET_BUNDLE_ID = "com.laiwenkang.MoneyUp.Widget"
APP_GROUP_ID = "group.com.laiwenkang.MoneyUp"
APP_GROUP_PAYLOAD_SHA256 = {
    "App/Shared/BudgetWidgetSnapshot.swift": (
        "9c2b7e85b89aecfabab955d8d81db1d22e80474b43236190960f9f4c283e4170"
    ),
}
LOCKED_CAPTURE_STORE_SHA256 = (
    "7421cac819be5c3b4cf7f3bc2ab52368dd526bdc9e372a60a44a7feeabde79b4"
)
SHARED_ACTION_SOURCE_SHA256 = (
    "fee3f0db239b9d60238747e2c4375529f3c66dfba8822b1b2e4528d543662260"
)
APP_ROUTER_SOURCE_SHA256 = (
    "4efedc06179e798945c1b654b475072d7ddbef7d48abdc239297f8c745220fb7"
)
PACKAGE_MANIFEST_SHA256 = (
    "47842f01189d9dba4167cd6d4f60d38dd05329367ee59d3adcc11359feb998de"
)
EXPECTED_ACTIONS = [
    ("expense", "expense", "moneyup://quick-log/expense"),
    ("income", "income", "moneyup://quick-log/income"),
    ("transfer", "transfer", "moneyup://quick-log/transfer"),
    ("refund", "refund", "moneyup://quick-log/refund"),
    ("smartEntry", "smartEntry", "moneyup://quick-log/smart-entry"),
    ("scanReceipt", "scanReceipt", "moneyup://quick-log/scan-receipt"),
]
EXPECTED_PHRASES = [
    r"Log an expense in \(.applicationName)",
    r"Log income in \(.applicationName)",
    r"Log a transfer in \(.applicationName)",
    r"Log a refund in \(.applicationName)",
    r"Open Smart Entry in \(.applicationName)",
    r"Choose a receipt in \(.applicationName)",
]
PLATFORM_LOCALIZATION_KEYS = {
    "platform_action.type",
    "platform_action.expense",
    "platform_action.income",
    "platform_action.transfer",
    "platform_action.refund",
    "platform_action.smart_entry",
    "platform_action.scan_receipt",
    "platform_action.unlock_required",
    "platform_action.capture_without_unlock",
    "platform_intent.open_quick_log.title",
    "platform_intent.open_quick_log.description",
    "platform_intent.open_quick_log.action",
}
PREFERENCE_NEUTRAL_CAPTURE_HINTS = (
    "Open MoneyUp to continue logging",
    "打开 MoneyUp 以继续记账",
)
CONTROL_LOCALIZATION_KEYS = {
    "control.quick_log.display_name",
    "control.quick_log.description",
}
SHORTCUT_LOCALIZATION_KEYS = {
    "shortcut.quick_log.expense",
    "shortcut.quick_log.income",
    "shortcut.quick_log.transfer",
    "shortcut.quick_log.refund",
    "shortcut.quick_log.smart_entry",
    "shortcut.quick_log.scan_receipt",
}
FORBIDDEN_ACTION_SYMBOLS = {
    "UserDefaults": "App Group or defaults writes",
    "suiteName": "App Group access",
    "FileManager": "file persistence",
    "FileHandle": "file persistence",
    "NSFileCoordinator": "file persistence",
    "OutputStream": "file persistence",
    "DispatchIO": "file persistence",
    "URL(fileURLWithPath:": "file persistence",
    "Data(contentsOf:": "file persistence",
    ".write(": "file persistence",
    "write(toFile:": "file persistence",
    "createFile(": "file persistence",
    "fopen(": "POSIX persistence",
    "open(": "POSIX persistence",
    "creat(": "POSIX persistence",
    "write(": "POSIX persistence",
    "pwrite(": "POSIX persistence",
    "mkdir(": "POSIX persistence",
    "rename(": "POSIX persistence",
    "unlink(": "POSIX persistence",
    "symlink(": "POSIX persistence",
    "truncate(": "POSIX persistence",
    "Darwin.": "POSIX persistence",
    "Glibc.": "POSIX persistence",
    "SecItem": "Keychain persistence",
    "Keychain": "Keychain persistence",
    "CFPreferences": "defaults persistence",
    "NSUbiquitousKeyValueStore": "cloud key-value persistence",
    "CoreData": "database persistence",
    "SwiftData": "database persistence",
    "ModelContainer": "database persistence",
    "SQLite": "database persistence",
    "GRDB": "database persistence",
    "Realm": "database persistence",
    "LockedCaptureStore": "locked-capture mutation",
    "saveLockedCapture": "direct locked-capture mutation",
    "MoneyUpPersistence": "persistence access",
    "CoreSpotlight": "Spotlight content",
    "ActivityKit": "Live Activity content",
    "UserNotifications": "notification content",
    "UNUserNotificationCenter": "notification content",
    "IntentDialog": "intent dialog",
    "OpenURLIntent": "direct URL intent",
    ".result(opensIntent:": "URL-opening intent result",
    ".result(value:": "intent return value",
    ".result(dialog:": "intent dialog result",
    "URLSession": "network exfiltration",
    "NSURLConnection": "network exfiltration",
    "Network.framework": "network exfiltration",
    "import Network": "network exfiltration",
    "NWConnection": "network exfiltration",
    "CFNetwork": "network exfiltration",
    "WebKit": "web exfiltration",
    "WKWebView": "web exfiltration",
    "UIPasteboard": "pasteboard exfiltration",
    "NSPasteboard": "pasteboard exfiltration",
    "Process(": "process exfiltration",
    "socket(": "socket exfiltration",
    "connect(": "socket exfiltration",
    "send(": "socket exfiltration",
    "sendto(": "socket exfiltration",
}
COMPILED_SWIFT_ROOTS = (
    "App/MoneyUp",
    "App/Shared",
    "App/MoneyUpWidget",
    "Sources",
)
IGNORED_SWIFT_INVENTORY_ROOTS = {
    ".build",
    ".git",
    ".swiftpm",
    "Tests",
    "worktrees",
}
APP_INTENTS_SOURCE_ALLOWLIST = {
    "App/MoneyUp/MoneyUpAppShortcuts.swift",
    "App/Shared/MoneyUpQuickAction.swift",
    "App/MoneyUpWidget/MoneyUpQuickLogControl.swift",
    "App/MoneyUpWidget/MoneyUpWidget.swift",
}
PLATFORM_REFERENCE_ALLOWLIST = APP_INTENTS_SOURCE_ALLOWLIST | {
    "App/MoneyUp/AppModel.swift",
    "App/MoneyUp/AppModelBackupRestore.swift",
    "App/MoneyUp/AppModelKeyCliffRecovery.swift",
    "App/MoneyUp/AppModelLifecycle.swift",
    "App/MoneyUp/AppModelQuickActionIngress.swift",
    "App/MoneyUp/AppModelRestorePreview.swift",
    "App/MoneyUp/AppModelSettings.swift",
    "App/MoneyUp/AppModelValidation.swift",
    "App/MoneyUp/LockedQuickCaptureView.swift",
    "App/MoneyUp/MoneyUpApp.swift",
    "App/MoneyUp/MoneyUpQuickActionRouting.swift",
    "App/MoneyUp/QuickLogEntryDraft.swift",
    "App/MoneyUp/QuickLogLaunchMode.swift",
    "App/MoneyUp/QuickLogSheet.swift",
    "App/MoneyUp/RootView.swift",
}
PLATFORM_REFERENCE_MARKERS = (
    "MoneyUpQuickAction",
    "quickActionRouteBroker",
    "needsAcknowledgementRetry",
    "QuickLogRouteRequest",
    "requestedQuickLogRequest",
    "presentedQuickLogRequest",
)
PLATFORM_SURFACE_INVENTORY = {
    r"\bstruct\s+OpenQuickLogIntent\s*:\s*AppIntent\b": {
        "App/Shared/MoneyUpQuickAction.swift": 1,
    },
    r"\bextension\s+OpenQuickLogIntent\s*:\s*ControlConfigurationIntent\b": {
        "App/Shared/MoneyUpQuickAction.swift": 1,
    },
    r"\bstruct\s+MoneyUpWidgetConfigurationIntent\s*:\s*WidgetConfigurationIntent\b": {
        "App/MoneyUpWidget/MoneyUpWidget.swift": 1,
    },
    r"\bstruct\s+MoneyUpAppShortcuts\s*:\s*AppShortcutsProvider\b": {
        "App/MoneyUp/MoneyUpAppShortcuts.swift": 1,
    },
    r"\bstruct\s+MoneyUpQuickLogControl\s*:\s*ControlWidget\b": {
        "App/MoneyUpWidget/MoneyUpQuickLogControl.swift": 1,
    },
    r"\bControlWidgetButton\s*\(": {
        "App/MoneyUpWidget/MoneyUpQuickLogControl.swift": 1,
    },
    r"\bButton\s*\(\s*intent\s*:": {
        "App/MoneyUpWidget/MoneyUpWidget.swift": 5,
    },
    r"\bAppShortcut\s*\(": {
        "App/MoneyUp/MoneyUpAppShortcuts.swift": 6,
    },
}
COMPILED_REFERENCE_INVENTORY = {
    r"\bMoneyUpQuickAction\b": {
        "App/MoneyUp/AppModelLifecycle.swift": 1,
        "App/MoneyUp/MoneyUpApp.swift": 1,
        "App/MoneyUp/QuickLogLaunchMode.swift": 1,
        "App/Shared/MoneyUpQuickAction.swift": 10,
        "App/MoneyUpWidget/MoneyUpWidget.swift": 12,
    },
    r"\bMoneyUpQuickActionRouteBroker\b": {
        "App/MoneyUp/AppModel.swift": 5,
        "App/MoneyUp/MoneyUpApp.swift": 1,
        "App/MoneyUp/MoneyUpQuickActionRouting.swift": 1,
        "App/Shared/MoneyUpQuickAction.swift": 3,
    },
    r"\bquickActionRouteBroker\b": {
        "App/MoneyUp/AppModel.swift": 12,
        "App/MoneyUp/AppModelKeyCliffRecovery.swift": 1,
        "App/MoneyUp/AppModelLifecycle.swift": 10,
        "App/MoneyUp/AppModelQuickActionIngress.swift": 2,
        "App/MoneyUp/MoneyUpApp.swift": 6,
        "App/MoneyUp/MoneyUpQuickActionRouting.swift": 2,
        "App/MoneyUp/RootView.swift": 3,
    },
    r"\bneedsAcknowledgementRetry\b": {
        "App/MoneyUp/AppModelQuickActionIngress.swift": 1,
        "App/Shared/MoneyUpQuickAction.swift": 1,
    },
    r"\bOpenQuickLogIntent\b": {
        "App/MoneyUp/MoneyUpAppShortcuts.swift": 6,
        "App/Shared/MoneyUpQuickAction.swift": 2,
        "App/MoneyUpWidget/MoneyUpQuickLogControl.swift": 1,
        "App/MoneyUpWidget/MoneyUpWidget.swift": 5,
    },
    r"\bQuickLogRouteRequest\b": {
        "App/MoneyUp/AppModel.swift": 3,
        "App/MoneyUp/AppModelLifecycle.swift": 3,
        "App/MoneyUp/AppModelQuickActionIngress.swift": 1,
        "App/MoneyUp/LockedQuickCaptureView.swift": 1,
        "App/MoneyUp/QuickLogEntryDraft.swift": 1,
        "App/MoneyUp/QuickLogLaunchMode.swift": 1,
        "App/MoneyUp/QuickLogSheet.swift": 5,
    },
    r"\brequestedQuickLogRequest\b": {
        "App/MoneyUp/AppModel.swift": 3,
        "App/MoneyUp/AppModelLifecycle.swift": 4,
        "App/MoneyUp/AppModelQuickActionIngress.swift": 3,
        "App/MoneyUp/LockedQuickCaptureView.swift": 1,
        "App/MoneyUp/MoneyUpApp.swift": 1,
        "App/MoneyUp/MoneyUpQuickActionRouting.swift": 1,
        "App/MoneyUp/RootView.swift": 3,
    },
    r"\bpresentedQuickLogRequest\b": {
        "App/MoneyUp/AppModel.swift": 2,
        "App/MoneyUp/AppModelLifecycle.swift": 5,
        "App/MoneyUp/AppModelQuickActionIngress.swift": 1,
        "App/MoneyUp/AppModelValidation.swift": 1,
        "App/MoneyUp/RootView.swift": 1,
    },
    r"\brequestedQuickLogMode\b": {
        "App/MoneyUp/AppModel.swift": 3,
        "App/MoneyUp/AppModelBackupRestore.swift": 1,
        "App/MoneyUp/AppModelKeyCliffRecovery.swift": 2,
        "App/MoneyUp/AppModelLifecycle.swift": 10,
        "App/MoneyUp/AppModelLockedCaptureRecovery.swift": 1,
        "App/MoneyUp/AppModelServices.swift": 5,
        "App/MoneyUp/MoneyUpQuickActionRouting.swift": 2,
    },
    r"\bQuickLogLaunchMode\b": {
        "App/MoneyUp/AppModel.swift": 1,
        "App/MoneyUp/AppModelLifecycle.swift": 2,
        "App/MoneyUp/AppModelLockedCaptureRecovery.swift": 1,
        "App/MoneyUp/AppModelServices.swift": 3,
        "App/MoneyUp/LockedQuickCaptureView.swift": 1,
        "App/MoneyUp/QuickLogEntryDraft.swift": 1,
        "App/MoneyUp/QuickLogLaunchMode.swift": 2,
    },
    r"moneyup://": {
        "App/Shared/MoneyUpQuickAction.swift": 6,
    },
    r"\bLink\s*\(": {
        "App/MoneyUp/PrivacyAndBetaView.swift": 2,
    },
    r"\.widgetURL\s*\(": {},
    r"\.onOpenURL\s*\{": {
        "App/MoneyUp/MoneyUpApp.swift": 1,
    },
}


def declaration_body(source: str, declaration: str) -> str | None:
    """Return a simple Swift declaration body, including nested braces."""
    start = source.find(declaration)
    if start < 0:
        return None
    opening = source.find("{", start + len(declaration))
    if opening < 0:
        return None
    depth = 1
    index = opening + 1
    while index < len(source) and depth:
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    if depth:
        return None
    return source[opening + 1 : index - 1]


def normalized_swift_body(source: str | None) -> str:
    if source is None:
        return ""
    without_comments = re.sub(
        r"//[^\n]*|/\*.*?\*/",
        "",
        source,
        flags=re.DOTALL,
    )
    return " ".join(without_comments.split())


def simple_switch_case_body(source: str | None, label: str) -> str | None:
    """Return one top-level simple enum case body from an isolated switch."""
    if source is None:
        return None
    match = re.search(
        rf"(?m)^\s*case\s+\.{re.escape(label)}\s*:\s*",
        source,
    )
    if match is None:
        return None
    following = re.search(
        r"(?m)^\s*(?:case\s+\.[A-Za-z][A-Za-z0-9]*\s*:|default\s*:)",
        source[match.end():],
    )
    end = len(source) if following is None else match.end() + following.start()
    return source[match.end():end]


def project_target_source_paths(project: str, target: str) -> list[str] | None:
    target_match = re.search(
        rf"(?ms)^  {re.escape(target)}:\n(?P<body>.*?)(?=^  [A-Za-z][^\n]*:\n|\Z)",
        project,
    )
    if target_match is None:
        return None
    source_match = re.search(
        r"(?ms)^    sources:\n(?P<body>.*?)(?=^    [A-Za-z][^\n]*:\n|\Z)",
        target_match.group("body"),
    )
    if source_match is None:
        return None
    source_lines = [
        line for line in source_match.group("body").splitlines() if line.strip()
    ]
    if any(
        re.fullmatch(r"      - path:\s*[^\s#]+\s*", line) is None
        for line in source_lines
    ):
        return None
    return [line.split(":", 1)[1].strip() for line in source_lines]


def validate_shared_action_source(source: str) -> list[str]:
    errors: list[str] = []
    if hashlib.sha256(source.encode("utf-8")).hexdigest() != (
        SHARED_ACTION_SOURCE_SHA256
    ):
        errors.append(
            "shared action file drifted from the exact broker/intent structural "
            "contract"
        )
    enum_body = declaration_body(source, "enum MoneyUpQuickAction")
    if enum_body is None:
        return ["shared MoneyUpQuickAction enum is missing or malformed"]

    cases = re.findall(
        r"(?m)^\s*case\s+([A-Za-z][A-Za-z0-9]*)\s*=\s*\"([^\"]+)\"\s*$",
        enum_body,
    )
    expected_raw_values = [(name, raw) for name, raw, _ in EXPECTED_ACTIONS]
    if cases != expected_raw_values:
        errors.append(
            "persisted MoneyUpQuickAction cases/raw values drifted: "
            f"expected {expected_raw_values}, found {cases}"
        )

    deep_link_body = declaration_body(enum_body, "var deepLink: URL")
    if deep_link_body is None:
        errors.append("quick-action URL generator is missing or malformed")
        urls: list[str] = []
    else:
        urls = re.findall(r'URL\(string:\s*"([^"]+)"\)!', deep_link_body)
    expected_urls = [url for _, _, url in EXPECTED_ACTIONS]
    if urls != expected_urls:
        errors.append(
            f"quick-action URL allowlist drifted: expected {expected_urls}, found {urls}"
        )
    for url in urls:
        if "?" in url or "#" in url or not url.startswith("moneyup://quick-log/"):
            errors.append(f"quick-action URL is not an exact path-only route: {url}")

    decoder = declaration_body(enum_body, "init?(exactDeepLink url: URL)")
    expected_decoder = (
        "guard url.baseURL == nil else { return nil } "
        "let literal = url.relativeString "
        "guard literal == url.absoluteString else { return nil } "
        "guard let action = Self.allCases.first(where: { "
        "$0.deepLink.absoluteString == literal }) else { return nil } "
        "self = action"
    )
    if decoder is None or " ".join(decoder.split()) != expected_decoder:
        errors.append(
            "quick-action URL decoder must remain the exact literal closed mapping"
        )
    elif (
        decoder.count("url.baseURL") != 1
        or decoder.count("url.relativeString") != 1
        or decoder.count("url.absoluteString") != 1
    ):
        errors.append(
            "quick-action URL decoder must reject base-relative input and compare "
            "the unmodified supplied and absolute strings once"
        )

    intent_body = declaration_body(source, "struct OpenQuickLogIntent")
    if intent_body is None:
        return [*errors, "OpenQuickLogIntent is missing or malformed"]
    parameter_declarations = re.findall(
        r"@Parameter\([^\n]*\)\s*\n\s*var\s+([A-Za-z][A-Za-z0-9]*)"
        r"\s*:\s*([A-Za-z][A-Za-z0-9]*)",
        intent_body,
    )
    if (
        intent_body.count("@Parameter") != 1
        or parameter_declarations != [("action", "MoneyUpQuickAction")]
    ):
        errors.append(
            "OpenQuickLogIntent must expose only action: MoneyUpQuickAction; "
            f"found {parameter_declarations}"
        )
    intent_properties = re.findall(
        r"(?m)^    (?:static\s+)?(?:private(?:\(set\))?\s+)?"
        r"(?:let|var)\s+([A-Za-z][A-Za-z0-9]*)",
        intent_body,
    )
    if intent_properties != [
        "title",
        "description",
        "openAppWhenRun",
        "supportedModes",
        "action",
    ]:
        errors.append(
            "OpenQuickLogIntent may declare only reviewed metadata and action; "
            f"found {intent_properties}"
        )
    intent_functions = re.findall(
        r"(?m)^    (?:@MainActor\s*\n    )?func\s+"
        r"([A-Za-z][A-Za-z0-9]*)",
        intent_body,
    )
    if intent_functions != ["perform"] or intent_body.count("    init(") != 2:
        errors.append("OpenQuickLogIntent may contain only two initializers and perform")
    required = [
        "init(action: MoneyUpQuickAction)",
        '@available(iOS, obsoleted: 26.0, message: "Replaced by supportedModes")',
        "static var openAppWhenRun: Bool { true }",
        "#if compiler(>=6.2)",
        "@available(iOS 26.0, *)",
        "static let supportedModes: IntentModes = [.foreground(.immediate)]",
        "@MainActor\n    func perform() async throws -> some IntentResult",
        "MoneyUpQuickActionRouteBroker.shared.submit(action)",
        "return .result()",
    ]
    for declaration in required:
        if declaration not in intent_body:
            errors.append(f"OpenQuickLogIntent is missing {declaration}")
    if "extension OpenQuickLogIntent: ControlConfigurationIntent {}" not in source:
        errors.append(
            "OpenQuickLogIntent must provide the shared control configuration"
        )
    perform = declaration_body(
        intent_body,
        "func perform() async throws -> some IntentResult",
    )
    if perform is None or " ".join(perform.split()) != (
        "guard MoneyUpQuickActionRouteBroker.shared.submit(action) else { "
        "throw MoneyUpQuickActionIngressError.unavailable } return .result()"
    ):
        errors.append(
            "OpenQuickLogIntent must durably admit before returning a payload-free result"
        )

    record_body = declaration_body(
        source,
        "struct MoneyUpQuickActionIngressRecord",
    )
    if record_body is None or " ".join(record_body.split()) != (
        "let token: UUID let action: MoneyUpQuickAction"
    ):
        errors.append(
            "durable ingress records may contain only an opaque token and closed action"
        )

    store_body = declaration_body(
        source,
        "final class MoneyUpQuickActionIngressFileStore",
    )
    store_required = [
        "static let currentSchemaVersion = 1",
        "static let maximumRecordCount = 16",
        "static let maximumPayloadByteCount = 4_096",
        'static let storageDirectoryName = "MoneyUpQuickActionIngress"',
        'static let fileName = "moneyup-quick-action-ingress-v1.json"',
        "var schemaVersion: Int",
        "var authorityToken: UUID",
        "var admission: MoneyUpQuickActionIngressAdmission",
        "var records: [MoneyUpQuickActionIngressRecord]",
        "expectedAuthorityToken: UUID?",
        "expectedAuthorityToken: UUID",
        "wasAbsent && expectedAuthorityToken == nil",
        "envelope.authorityToken == expectedAuthorityToken",
        "NSFileCoordinator(filePresenter: nil).coordinate(",
        "writingItemAt: fileURL",
        "options: .forReplacing",
        "data.count <= Self.maximumPayloadByteCount",
        "persisted == envelope",
        "coordinationError == nil || result.didApply",
        "func recoverOpenAfterValidatedLifecycle()",
        "wasAbsent || envelope.admission == .closed",
        "try encoder.encode(envelope) == data",
        "handle.read(",
        "let remaining = Self.maximumPayloadByteCount + 1 - data.count",
        "handle.read(upToCount: remaining)",
        ".atomic,",
        ".completeFileProtectionUntilFirstUserAuthentication",
        "resourceValues.isExcludedFromBackup = true",
        "try fileManager.setAttributes(",
        ".posixPermissions: 0o700",
        "Set(root.keys) == Set([",
        '"schemaVersion", "authorityToken", "admission", "records"',
        'Set($0.keys) == Set(["token", "action"])',
        "envelope.records.count <= maximumRecordCount",
        "Set(envelope.records.map(\\.token)).count",
        "envelope.admission == .open || envelope.records.isEmpty",
    ]
    if store_body is None:
        errors.append("bounded coordinated durable ingress store is missing")
    else:
        for declaration in store_required:
            if declaration not in store_body:
                errors.append(
                    "durable ingress store is missing reviewed contract "
                    + declaration
                )
        if store_body.count("NSFileCoordinator(filePresenter: nil).coordinate(") != 2:
            errors.append(
                "durable ingress must coordinate exactly one load and one mutation path"
            )
        if store_body.count(".write(") != 1:
            errors.append(
                "durable ingress must have one bounded atomic replacement write path"
            )
        if store_body.count(
            "envelope.authorityToken == expectedAuthorityToken"
        ) != 2:
            errors.append(
                "durable ingress append and acknowledgement must compare the "
                "producer's observed authority epoch"
            )
        if store_body.count("resourceValues.isExcludedFromBackup = true") != 1:
            errors.append(
                "durable ingress must be install-local and excluded from backup"
            )
        if store_body.count(".posixPermissions: 0o700") != 2:
            errors.append(
                "durable ingress must reassert private permissions on an existing directory"
            )
        recovery = declaration_body(
            store_body,
            "func recoverOpenAfterValidatedLifecycle()",
        )
        if normalized_swift_body(recovery) != (
            "mutate(resetUnavailable: true) { envelope, wasAbsent in "
            "guard wasAbsent || envelope.admission == .closed else { "
            "return false } envelope = .empty(admission: .open) return true }"
        ):
            errors.append(
                "validated ingress recovery must atomically preserve valid/open work "
                "and reset only absent, closed, or unreadable state"
            )
        for forbidden in (
            "UserDefaults",
            "suiteName",
            "SecItem",
            "Keychain",
            "MoneyUpPersistence",
            "URLSession",
            "Network.framework",
            "UIPasteboard",
            "NSPasteboard",
            "amount",
            "payee",
            "accountID",
            "entryID",
            "bookID",
            "note:",
        ):
            if forbidden in store_body:
                errors.append(
                    f"durable ingress crosses its data-free boundary: {forbidden}"
                )

    broker_body = declaration_body(source, "final class MoneyUpQuickActionRouteBroker")
    if (
        "@MainActor\n@Observable\nfinal class MoneyUpQuickActionRouteBroker"
        not in source
    ):
        errors.append("quick-action route broker must be main-actor observable state")
    if broker_body is None:
        errors.append("durable quick-action route broker is missing")
    else:
        broker_functions = re.findall(
            r"(?m)^    (?:@discardableResult\s*\n    )?func\s+"
            r"([A-Za-z][A-Za-z0-9]*)",
            broker_body,
        )
        if broker_functions != [
            "submit",
            "takePendingRecord",
            "ownsActiveDelivery",
            "needsAcknowledgementRetry",
            "acknowledge",
            "reloadDurableIngress",
            "discardAllPendingActions",
            "beginAuthoritativeBoundary",
            "endAuthoritativeBoundary",
            "reopenDurableAdmissionAfterAuthoritativeRecovery",
        ]:
            errors.append(
                "route broker may contain only the reviewed durable delivery, "
                "exact acknowledgement, and boundary methods"
            )
        broker_required = [
            "ingressStore: MoneyUpQuickActionIngressFileStore(",
            "BudgetWidgetSnapshotStore.appGroupIdentifier",
            "MoneyUpQuickActionIngressFileStore.maximumRecordCount",
            "private let ingressStore: (any MoneyUpQuickActionIngressStoring)?",
            "private var pendingRecords: [MoneyUpQuickActionIngressRecord] = []",
            "private var activeDeliveryToken: UUID?",
            "private var acknowledgedDeliveryToken: UUID?",
            "private var acknowledgementRetryToken: UUID?",
            "private var durableAuthorityToken: UUID?",
            "private var durableAdmissionBlocked = false",
            "private var nextBoundaryEpoch: UInt64 = 0",
            "private var activeBoundaryEpochs: Set<UInt64> = []",
            "private(set) var revision: UInt64 = 0",
            "private(set) var handoffGeneration: UInt64 = 0",
            "var pendingAction: MoneyUpQuickAction? { pendingRecords.first?.action }",
            "var pendingCount: Int { pendingRecords.count }",
            "var activeIngressToken: UUID? { activeDeliveryToken }",
            "var isAuthoritativeLifecycleBoundaryActive: Bool",
            "var isAuthoritativeBoundaryActive: Bool",
            "isAuthoritativeLifecycleBoundaryActive || durableAdmissionBlocked",
            "guard !isAuthoritativeLifecycleBoundaryActive else { return false }",
            "if ingressStore != nil",
            "reloadDurableIngress()",
            "guard !durableAdmissionBlocked else { return false }",
            "expectedAuthorityToken: durableAuthorityToken",
            "let expectedAuthorityToken = durableAuthorityToken",
            "snapshot.records.contains(record)",
            "activeDeliveryToken = record.token",
            "guard acknowledgedDeliveryToken == token else { return false }",
            "acknowledgementRetryToken = token",
            "acknowledgementRetryToken == token",
            "allowingCommittedCaptureReplay: Bool = false",
            "expectedAuthorityToken: durableAuthorityToken",
            "if allowingCommittedCaptureReplay",
            "return allowingCommittedCaptureReplay",
            "previousAuthorityToken == snapshot.authorityToken",
            "snapshot.records.first?.token == activeDeliveryToken",
            "!snapshot.records.contains(where:",
            "snapshot.authorityToken == nil",
            "previousAuthorityToken != nil",
            "let mutation = ingressStore.invalidateAndClose()",
            "durableAdmissionBlocked = true",
            "durableAdmissionBlocked || durableAuthorityToken == nil",
            "ingressStore.recoverOpenAfterValidatedLifecycle()",
            "preservingActiveDelivery: !mutation.didApply",
            "isOpen = snapshot.admission == .open",
            "durableAdmissionBlocked = !isOpen",
        ]
        for declaration in broker_required:
            if declaration not in broker_body:
                errors.append(f"route broker is missing {declaration}")
        submit = declaration_body(broker_body, "func submit(")
        if (
            submit is None
            or submit.count("reloadDurableIngress()") != 1
            or submit.find("guard !isAuthoritativeLifecycleBoundaryActive")
                > submit.find("reloadDurableIngress()")
            or submit.find("reloadDurableIngress()")
                > submit.find("guard !durableAdmissionBlocked")
        ):
            errors.append(
                "durable submission must refresh a long-lived producer before "
                "its final admission guard and authority-CAS append"
            )
        if broker_body.count(
            "previousAuthorityToken == snapshot.authorityToken"
        ) != 3:
            errors.append(
                "durable acknowledgement convergence must stay within the exact "
                "observed authority epoch"
            )
        if (
            "if previousAuthorityToken != snapshot.authorityToken {\n"
            "                acknowledgedDeliveryToken = nil\n"
            "                acknowledgementRetryToken = nil\n"
            "            }"
        ) not in broker_body:
            errors.append(
                "authority replacement must invalidate stale acknowledged and retry tokens"
            )
        boundary_end = declaration_body(
            broker_body,
            "func endAuthoritativeBoundary(_ epoch: UInt64)",
        )
        if normalized_swift_body(boundary_end) != (
            "guard activeBoundaryEpochs.remove(epoch) != nil else { return } "
            "revision &+= 1"
        ):
            errors.append(
                "ending a lifecycle epoch must never implicitly reopen durable admission"
            )
    for symbol, boundary in FORBIDDEN_ACTION_SYMBOLS.items():
        if symbol in intent_body:
            errors.append(f"intent body crosses {boundary}: {symbol}")
    return errors


def validate_app_routing_source(source: str) -> list[str]:
    errors: list[str] = []
    if "moneyup://" in source:
        errors.append("main scene must use the closed action URL mapping")
    required = [
        "MoneyUpQuickActionRouteBroker.shared",
        ".onOpenURL { url in\n                    routeDeepLink(url)\n                }",
        ".onChange(of: quickActionRouteBroker.revision)",
        ".onChange(of: model.isWorking)",
        ".onChange(of: model.isLifecycleMutationInProgress)",
        ".onChange(of: model.goalMutationBarrierClosed)",
        ".onChange(of: model.requestedQuickLogRequest)",
        ".task {\n                    quickActionRouteBroker.reloadDurableIngress()",
        "case .active:\n                        quickActionRouteBroker.reloadDurableIngress()",
        "quickActionRouteBroker.reloadDurableIngress()\n"
        "                    model.retryPresentedQuickActionAcknowledgement()",
        "quickActionRouteBroker.reloadDurableIngress()\n"
        "                        model.retryPresentedQuickActionAcknowledgement()",
        "routePendingQuickAction()\n                    await model.startAfterInitialRoutingWindow()",
    ]
    for declaration in required:
        if declaration not in source:
            errors.append(f"main scene is missing broker route gate {declaration}")

    route = declaration_body(source, "private func routePendingQuickAction()")
    if route is None or " ".join(route.split()) != (
        "let result = MoneyUpQuickActionRouting.routeNext( "
        "from: quickActionRouteBroker, into: model ) "
        "guard result == .requiresStart else { return } Task { await model.start() }"
    ):
        errors.append("main scene must drain at most one action through the strict router")
    deep_route = declaration_body(source, "private func routeDeepLink(_ url: URL)")
    if deep_route is None or " ".join(deep_route.split()) != (
        "guard let action = MoneyUpQuickAction(exactDeepLink: url) else { return } "
        "_ = quickActionRouteBroker.submit(action) "
        "routePendingQuickAction()"
    ):
        errors.append(
            "main scene deep-link handler must submit one closed action and always "
            "drain through the strict router, including at FIFO capacity"
        )
    for symbol, boundary in FORBIDDEN_ACTION_SYMBOLS.items():
        if symbol in source:
            errors.append(f"main scene route crosses {boundary}: {symbol}")
    return errors


def validate_root_handoff_source(source: str) -> list[str]:
    errors: list[str] = []
    required = [
        ".isAuthoritativeLifecycleBoundaryActive",
        ".id(model.quickActionRouteBroker.handoffGeneration)",
        "let request = model.requestedQuickLogRequest",
        "LockedQuickCaptureView(request: request)",
        ".id(request.id)",
        "launchRequest: model.presentedQuickLogRequest",
        "model.consumeQuickLogRequest(request)",
        ".onChange(of: model.requestedQuickLogRequest)",
        "model.presentQuickLogRequest(request)",
    ]
    for declaration in required:
        if declaration not in source:
            errors.append(f"RootView is missing generation-bound handoff {declaration}")
    if source.count(".id(model.quickActionRouteBroker.handoffGeneration)") != 2:
        errors.append("RootView must reset both boundary cover and ready UI by generation")
    if (
        "if model.quickActionRouteBroker\n"
        "            .isAuthoritativeBoundaryActive"
    ) in source:
        errors.append(
            "RootView must not hide locked/recovery UI for crash-closed ingress"
        )
    if "quickLogLaunchMode" in source or "logRequestSequence" in source:
        errors.append("RootView must not retain an unversioned quick-log launch")
    return errors


def validate_request_identity_source(source: str) -> list[str]:
    errors: list[str] = []
    required = [
        "struct QuickLogRouteRequest: Equatable, Identifiable, Sendable",
        "let id: UInt64",
        "let ingressToken: UUID",
        "let requiresIngressAcknowledgement: Bool",
        "let generation: UInt64",
        "let mode: QuickLogLaunchMode",
    ]
    for declaration in required:
        if declaration not in source:
            errors.append(f"quick-log request identity is missing {declaration}")
    action_mapping = declaration_body(
        source,
        "init(_ action: MoneyUpQuickAction)",
    )
    if action_mapping is None or " ".join(action_mapping.split()) != (
        "switch action { case .expense: self = .expense case .income: "
        "self = .income case .transfer: self = .transfer case .refund: "
        "self = .refund case .smartEntry: self = .smartEntry case "
        ".scanReceipt: self = .scanReceipt }"
    ):
        errors.append(
            "quick-log launch mode must map exhaustively from the closed action enum"
        )
    return errors


def validate_model_validation_handoff_source(source: str) -> list[str]:
    clear_state = declaration_body(source, "func clearDecodedState()")
    if clear_state is None or "presentedQuickLogRequest = nil" not in clear_state:
        return ["decoded-state clearing must invalidate the presented quick-log request"]
    return []


def validate_log_handoff_source(source: str) -> list[str]:
    errors: list[str] = []
    if source.count("let launchRequest: QuickLogRouteRequest?") != 2:
        errors.append("Log handoff must carry one exact request through both view layers")
    if source.count(
        "let onRequestHandled: @MainActor (QuickLogRouteRequest) -> Void"
    ) != 2:
        errors.append("Log acknowledgements must return the exact request token")
    for legacy in ("let launchMode:", "let requestSequence:", "handledRequestSequence"):
        if legacy in source:
            errors.append(f"Log handoff retains legacy unversioned state {legacy}")
    return errors


def validate_log_request_draft_source(source: str) -> list[str]:
    required = [
        "let launchRequest",
        "launchRequest.id != handledRequestID",
        "pendingLaunchRequest = launchRequest",
        "onRequestHandled(launchRequest)",
        "performLaunch(launchRequest.mode)",
    ]
    return [
        f"Log request draft handoff is missing {declaration}"
        for declaration in required
        if declaration not in source
    ]


def validate_log_request_body_source(source: str) -> list[str]:
    required = [
        ".onChange(of: launchRequest)",
        "if let request = pendingLaunchRequest",
        "guard let request = pendingLaunchRequest else { return }",
        "onRequestHandled(request)",
    ]
    errors = [
        f"Log request body handoff is missing {declaration}"
        for declaration in required
        if declaration not in source
    ]
    if "pendingLaunchMode" in source or ".onChange(of: requestSequence)" in source:
        errors.append("Log request body retains an unversioned pending launch")
    return errors


def validate_locked_handoff_source(source: str) -> list[str]:
    errors: list[str] = []
    required = [
        "let request: QuickLogRouteRequest",
        "private var mode: QuickLogLaunchMode { request.mode }",
        "model.consumeQuickLogRequest(request)",
        "request: request",
        "resumeCommittedLockedCaptureIfPresent(",
        "replayInspectionState = .failed",
        "guard model.requestedQuickLogRequest == request else { return }",
    ]
    for declaration in required:
        if declaration not in source:
            errors.append(f"locked capture handoff is missing {declaration}")
    if source.count("model.consumeQuickLogRequest(request)") != 2:
        errors.append("locked capture must acknowledge the exact request on both exits")
    if source.count("request: request") != 3:
        errors.append(
            "locked capture must bind both saves and replay inspection to the "
            "exact request"
        )
    return errors


def validate_model_quick_action_ingress_source(source: str) -> list[str]:
    errors: list[str] = []
    resume = declaration_body(
        source,
        "func resumeCommittedLockedCaptureIfPresent(",
    )
    normalized_resume = normalized_swift_body(resume)
    for declaration in (
        "request.requiresIngressAcknowledgement",
        "requestedQuickLogRequest == request",
        "state == .locked",
        "canPresentLockedQuickCapture",
        "let captures = try await lockedCaptureStore.all()",
        "$0.id == request.ingressToken",
        "allowingCommittedCaptureReplay: true",
    ):
        if declaration not in normalized_resume:
            errors.append(
                "locked-capture replay recovery is missing " + declaration
            )
    if normalized_resume.count("requestedQuickLogRequest == request") != 2:
        errors.append(
            "locked-capture replay must revalidate exact request ownership "
            "after the inbox read"
        )
    retry = declaration_body(
        source,
        "func retryPresentedQuickActionAcknowledgement()",
    )
    if retry is None or normalized_swift_body(retry) != (
        "guard let request = requestedQuickLogRequest, "
        "request.requiresIngressAcknowledgement, "
        "quickActionRouteBroker.needsAcknowledgementRetry( token: "
        "request.ingressToken ), "
        "presentedQuickLogRequest == request else { return } "
        "consumeQuickLogRequest(request)"
    ):
        errors.append(
            "scene retry must target only an exact acknowledgement that already failed"
        )
    return errors


def validate_app_router_source(source: str) -> list[str]:
    errors: list[str] = []
    if hashlib.sha256(source.encode("utf-8")).hexdigest() != (
        APP_ROUTER_SOURCE_SHA256
    ):
        errors.append(
            "app router file drifted from the exact disposition/routing "
            "structural contract"
        )
    disposition = declaration_body(
        source,
        "var quickActionRoutingDisposition: MoneyUpQuickActionRoutingDisposition",
    )
    if disposition is None or " ".join(disposition.split()) != (
        "guard !quickActionRouteBroker.isAuthoritativeBoundaryActive, "
        "!goalMutationBarrierClosed else { return .denyAuthoritatively } do { "
        "guard try dataEraseIntent.isPending() "
        "== false else { return .denyAuthoritatively } } catch { return "
        ".denyAuthoritatively } guard !isBookReplacementInProgress, "
        "startupFailureKind != .missingDeviceBoundKey, (try? "
        "hasPendingKeyCliffRecoveryTransaction()) == false else { return "
        ".denyAuthoritatively } guard !isLifecycleMutationInProgress, !isWorking, "
        "!lockedCaptureWriteInProgress, requestedQuickLogMode == nil else { "
        "return .deferTransiently } return .route"
    ):
        errors.append(
            "AppModel routing disposition must deny book replacement or erase "
            "authority before deferring same-book lifecycle work and fail closed"
        )
    route = declaration_body(source, "static func routeNext(")
    if route is None or " ".join(route.split()) != (
        "guard broker.pendingAction != nil else { return .idle } "
        "guard broker === model.quickActionRouteBroker else { "
        "broker.discardAllPendingActions() return .discarded } "
        "switch model.quickActionRoutingDisposition { case .denyAuthoritatively: "
        "broker.discardAllPendingActions() return .discarded case "
        ".deferTransiently: return .deferred case .route: break } guard let record "
        "= broker.takePendingRecord() "
        "else { return .idle } guard model.handleDeepLink(record.action.deepLink) "
        "else { broker.discardAllPendingActions() return .discarded } guard "
        "model.requestedQuickLogMode != nil, model.requestedQuickLogRequest?"
        ".ingressToken == record.token else { "
        "broker.discardAllPendingActions() return .discarded } guard "
        "model.state == .locked, !model.isLockSafeQuickCaptureRequested else { "
        "return .routed } return .requiresStart"
    ):
        errors.append(
            "app router must discard every post-dequeue authoritative denial, "
            "defer transient work, and begin at most one durable delivery"
        )
    if source.count("record.action.deepLink") != 1:
        errors.append("app router must be the only consumer of the action URL mapping")
    if source.count("broker.takePendingRecord()") != 1:
        errors.append("app router must begin at most one delivery per routing pass")
    if source.count("broker.discardAllPendingActions()") != 4:
        errors.append(
            "app router must clear the whole FIFO on dependency mismatch, "
            "pre-dequeue denial, or either post-dequeue denial"
        )
    for symbol, boundary in FORBIDDEN_ACTION_SYMBOLS.items():
        if symbol in source:
            errors.append(f"app router crosses {boundary}: {symbol}")
    return errors


def validate_boundary_lifecycle_sources(
    model_source: str,
    lifecycle_source: str,
    settings_source: str,
    restore_source: str,
) -> list[str]:
    errors: list[str] = []
    normalized_model = " ".join(model_source.split())
    model_required = [
        "let quickActionRouteBroker: MoneyUpQuickActionRouteBroker",
        "quickActionRouteBroker: MoneyUpQuickActionRouteBroker = .shared",
        "quickActionRouteBroker: MoneyUpQuickActionRouteBroker = "
        "MoneyUpQuickActionRouteBroker()",
        "private(set) var requestedQuickLogRequest: QuickLogRouteRequest?",
        "var presentedQuickLogRequest: QuickLogRouteRequest?",
        "generation: quickActionRouteBroker.handoffGeneration",
        "guard newValue == nil || "
        "!quickActionRouteBroker.isAuthoritativeBoundaryActive else",
    ]
    for declaration in model_required:
        if declaration not in normalized_model:
            errors.append(
                "AppModel quick-action broker dependency is missing " + declaration
            )
    requested_mode = declaration_body(
        model_source,
        "var requestedQuickLogMode: QuickLogLaunchMode?",
    )
    if requested_mode is None or " ".join(requested_mode.split()) != (
        "get { services.capture.requestedQuickLogMode } set { guard newValue == nil "
        "|| !quickActionRouteBroker.isAuthoritativeBoundaryActive else { return } "
        "services.capture.requestedQuickLogMode = newValue guard let newValue else { "
        "requestedQuickLogRequest = nil presentedQuickLogRequest = nil return } "
        "nextQuickLogRequestID &+= 1 "
        "requestedQuickLogRequest = QuickLogRouteRequest( id: nextQuickLogRequestID, "
        "ingressToken: quickActionRouteBroker.activeIngressToken ?? UUID(), "
        "requiresIngressAcknowledgement: "
        "quickActionRouteBroker.activeIngressToken != nil, "
        "generation: quickActionRouteBroker.handoffGeneration, mode: newValue ) }"
    ):
        errors.append(
            "AppModel request setter must bind the active stable token, generation, "
            "and durable acknowledgement requirement"
        )
    if model_source.count(
        "self.quickActionRouteBroker = quickActionRouteBroker"
    ) != 2:
        errors.append(
            "production and injected AppModel initializers must retain their "
            "quick-action broker"
        )
    if model_source.count(
        "quickActionRouteBroker = MoneyUpQuickActionRouteBroker()"
    ) != 1:
        errors.append(
            "restore validation must own one isolated quick-action broker"
        )

    erase = declaration_body(settings_source, "func eraseAllDataAndRestart() async")
    normalized_erase = "" if erase is None else " ".join(erase.split())
    erase_boundary = (
        "guard let quickActionBoundaryEpoch = "
        "beginEraseQuickActionBoundary() else { return } "
        "var quickActionRecoveryWasValidated = false defer { "
        "finishQuickActionBoundary( quickActionBoundaryEpoch, "
        "validatedRecovery: quickActionRecoveryWasValidated ) } "
        "isWorking = true"
    )
    if erase is None or erase_boundary not in normalized_erase:
        errors.append(
            "erase must synchronously begin and defer-balance the broker boundary "
            "before lifecycle state changes"
        )
    elif (
        erase.count("beginEraseQuickActionBoundary()") != 1
        or erase.count("quickActionRouteBroker.beginAuthoritativeBoundary()") != 0
        or erase.count("finishQuickActionBoundary(") != 1
        or erase.count("quickActionRecoveryWasValidated =") != 2
        or erase.count("endAuthoritativeBoundary(") != 0
    ):
        errors.append(
            "erase must own one success-qualified broker boundary"
        )
    erase_boundary_helper = declaration_body(
        settings_source,
        "private func beginEraseQuickActionBoundary() -> UInt64?",
    )
    if erase_boundary_helper is None or " ".join(
        erase_boundary_helper.split()
    ) != (
        "do { return try beginAuthoritativeQuickActionBoundary() } catch { "
        "state = .failed(safeUserMessage(for: error, context: .save)) return nil }"
    ):
        errors.append(
            "erase must abort before mutation if durable admission cannot close"
        )
    erase_restart = declaration_body(
        settings_source,
        "private func finishSuccessfulEraseAndRestartIfNeeded() async -> Bool",
    )
    if normalized_swift_body(erase_restart) != (
        "guard restartAfterErase else { state = .onboarding "
        "finishExclusiveDataLifecycleMutation() return true } "
        "finishExclusiveDataLifecycleMutation() return await start()"
    ):
        errors.append(
            "erase restart must carry startup validation independently of its "
            "final ready, onboarding, or deferred-lock UI state"
        )

    restore = declaration_body(
        restore_source,
        "private func restoreEncryptedBackupIntoLiveStore(",
    )
    normalized_restore = "" if restore is None else " ".join(restore.split())
    restore_boundary = (
        "let quickActionBoundaryEpoch = try beginRestoreMutation() "
        "var quickActionRecoveryWasValidated = false defer { "
        "finishBookReplacementMutation() finishQuickActionBoundary( "
        "quickActionBoundaryEpoch, validatedRecovery: "
        "quickActionRecoveryWasValidated ) "
        "} await finishBeginningRestoreMutation()"
    )
    if restore is None or restore_boundary not in normalized_restore:
        errors.append(
            "restore must retain its broker epoch through every success, error, "
            "and cancellation exit"
        )
    elif (
        restore.count("beginRestoreMutation()") != 1
        or restore.count("finishQuickActionBoundary(") != 1
        or restore.count("quickActionRecoveryWasValidated = true") != 1
        or restore.count("endAuthoritativeBoundary(") != 0
    ):
        errors.append(
            "restore must reopen durable admission only after successful publication"
        )
    begin_restore = declaration_body(
        restore_source,
        "func beginRestoreMutation() throws -> UInt64",
    )
    normalized_begin_restore = normalized_swift_body(begin_restore)
    begin_restore_boundary = (
        "let quickActionBoundaryEpoch = "
        "try beginAuthoritativeQuickActionBoundary() "
        "cancelWidgetReportingDayRefresh() "
        "isBookReplacementInProgress = true logicalBookRevision &+= 1 "
        "isWorking = true "
        "goalMutationBarrierClosed = true return quickActionBoundaryEpoch"
    )
    if begin_restore is None or (
        begin_restore_boundary not in normalized_begin_restore
    ):
        errors.append(
            "restore must begin its broker boundary synchronously before its first "
            "lifecycle state change or suspension"
        )
    finish_begin_restore = declaration_body(
        restore_source,
        "func finishBeginningRestoreMutation() async",
    )
    if finish_begin_restore is None or " ".join(
        finish_begin_restore.split()
    ) != (
        "await waitForGoalMutationDrain() isLifecycleMutationInProgress = true "
        "requestedQuickLogMode = nil intelligenceService.cancelPendingWork() "
        "invalidateInFlightJournalProjection()"
    ):
        errors.append(
            "restore may suspend only after its broker boundary and deferred "
            "cleanup are installed"
        )
    if (
        restore_source.count("beginAuthoritativeQuickActionBoundary()") != 1
        or restore_source.count("quickActionRouteBroker.beginAuthoritativeBoundary()") != 0
        or restore_source.count("finishQuickActionBoundary(") != 1
        or restore_source.count("endAuthoritativeBoundary(") != 0
    ):
        errors.append("restore source must own exactly one balanced broker boundary")

    start = declaration_body(lifecycle_source, "func start() async")
    normalized_start = "" if start is None else " ".join(start.split())
    start_defer = (
        "var quickActionBoundaryEpoch: UInt64? "
        "var quickActionRecoveryWasValidated = false beginStartupWork() "
        "defer { isWorking = false isStarting = false "
        "finishQuickActionBoundary( quickActionBoundaryEpoch, "
        "validatedRecovery: quickActionRecoveryWasValidated ) }"
    )
    inspect_erase = declaration_body(
        lifecycle_source,
        "private func inspectDataEraseIntent(",
    )
    normalized_inspect_erase = (
        "" if inspect_erase is None else " ".join(inspect_erase.split())
    )
    inspect_contract = (
        "do { let isPending = try await dataEraseIntent "
        ".isPendingWithoutBlockingLaunch() if isPending { do { return ( "
        ".success(true), try beginAuthoritativeQuickActionBoundary() ) } catch { "
        "return (.failure(error), nil) } } return (.success(false), nil) } catch { "
        "let inspectionError = error do { return ( .failure(inspectionError), "
        "try beginAuthoritativeQuickActionBoundary() ) } catch { return "
        "(.failure(error), nil) } }"
    )
    nonblocking_inspection_sequence = (
        "let dataEraseInspection = await inspectDataEraseIntent() "
        "quickActionBoundaryEpoch = dataEraseInspection.boundaryEpoch "
        "await lifecycleHooks.checkpoint(.afterStartupTombstoneInspection) "
        "await closeStoreBeforeStartup()"
    )
    deferral_offset = normalized_start.find(start_defer)
    inspection_offset = normalized_start.find(nonblocking_inspection_sequence)
    if start is None or start_defer not in normalized_start:
        errors.append("startup must defer-balance its broker boundary")
    startup_work = declaration_body(
        lifecycle_source,
        "private func beginStartupWork()",
    )
    if startup_work is None or " ".join(startup_work.split()) != (
        "isWorking = true isStarting = true"
    ):
        errors.append("startup must synchronously close its ordinary work gate")
    finish_boundary = declaration_body(
        lifecycle_source,
        "func finishQuickActionBoundary(",
    )
    if normalized_swift_body(finish_boundary) != (
        "if let epoch { quickActionRouteBroker.endAuthoritativeBoundary(epoch) } "
        "if validatedRecovery { finishValidatedQuickActionIngressRecovery() }"
    ):
        errors.append(
            "boundary completion must end first and reopen only from an explicit "
            "validated-success signal"
        )
    validated_recovery = declaration_body(
        lifecycle_source,
        "func finishValidatedQuickActionIngressRecovery()",
    )
    if normalized_swift_body(validated_recovery) != (
        "guard quickActionRouteBroker "
        ".reopenDurableAdmissionAfterAuthoritativeRecovery() else { return } "
        "clearOrphanedQuickActionRequestAfterDurableRecovery()"
    ):
        errors.append(
            "validated recovery must explicitly reopen then clear only orphaned UI"
        )
    if inspect_erase is None or inspect_contract not in normalized_inspect_erase:
        errors.append(
            "startup must begin a boundary for pending and unreadable "
            "tombstones after its nonblocking read"
        )
    if (
        start is None
        or inspection_offset < 0
        or deferral_offset < 0
        or deferral_offset > inspection_offset
    ):
        errors.append(
            "startup must defer action routing before the nonblocking tombstone "
            "read and publish its boundary before any later suspension"
        )
    if start is not None and (
        start.count("beginAuthoritativeBoundary()") != 0
        or start.count("endAuthoritativeBoundary(") != 0
        or start.count("finishQuickActionBoundary(") != 1
        or start.count("quickActionRecoveryWasValidated = true") != 1
        or "return quickActionRecoveryWasValidated" not in start
    ):
        errors.append(
            "startup must delegate tombstone boundaries and return one explicit "
            "validated-success signal"
        )
    elif normalized_start.find(
        "quickActionRecoveryWasValidated = true"
    ) < normalized_start.find(
        "openAndFinishStartupIncludingKeyCliffRecovery("
    ):
        errors.append(
            "startup may validate ingress recovery only after database and key-cliff "
            "startup completes"
        )
    if inspect_erase is not None and (
        inspect_erase.count("beginAuthoritativeQuickActionBoundary()") != 2
        or "dataEraseInspection.result.get()" not in normalized_start
    ):
        errors.append(
            "startup tombstone inspection must cover pending, unreadable, and "
            "deferred-result paths exactly once"
        )
    boundary_helper = declaration_body(
        lifecycle_source,
        "func beginAuthoritativeQuickActionBoundary() throws -> UInt64",
    )
    if boundary_helper is None or " ".join(boundary_helper.split()) != (
        "let epoch = try quickActionRouteBroker.beginAuthoritativeBoundary() "
        "requestedQuickLogMode = nil return epoch"
    ):
        errors.append(
            "every authoritative broker begin must invalidate the occupied UI "
            "request and prove durable closure before suspension"
        )
    present_request = declaration_body(
        lifecycle_source,
        "func presentQuickLogRequest(_ request: QuickLogRouteRequest) -> Bool",
    )
    if present_request is None or " ".join(present_request.split()) != (
        "guard requestedQuickLogRequest == request, request.generation == "
        "quickActionRouteBroker.handoffGeneration, "
        "!quickActionRouteBroker.isAuthoritativeBoundaryActive, "
        "presentedQuickLogRequest == nil || presentedQuickLogRequest == request "
        "else { return false } "
        "presentedQuickLogRequest = request return true"
    ):
        errors.append(
            "MainTab may present only the exact current-generation request while "
            "no authoritative boundary is active"
        )
    consume_request = declaration_body(
        lifecycle_source,
        "func consumeQuickLogRequest(_ request: QuickLogRouteRequest)",
    )
    if consume_request is None or " ".join(consume_request.split()) != (
        "guard requestedQuickLogRequest == request, presentedQuickLogRequest == nil "
        "|| presentedQuickLogRequest == request else { return } "
        "if request.requiresIngressAcknowledgement { guard quickActionRouteBroker."
        "acknowledge( token: request.ingressToken ) else { return } } "
        "requestedQuickLogMode = nil"
    ):
        errors.append(
            "quick-log acknowledgement must durably consume only the exact occupied token"
        )
    deep_link = declaration_body(
        lifecycle_source,
        "func handleDeepLink(_ url: URL) -> Bool",
    )
    if deep_link is None or normalized_swift_body(deep_link) != (
        "guard !quickActionRouteBroker.isAuthoritativeBoundaryActive, "
        "!goalMutationBarrierClosed else { return false } do { guard try "
        "dataEraseIntent.isPending() == false else { return false } } catch { "
        "return false } guard !isBookReplacementInProgress, startupFailureKind "
        "!= .missingDeviceBoundKey, (try? hasPendingKeyCliffRecoveryTransaction()) "
        "== false else { requestedQuickLogMode = nil return false } guard let "
        "action = MoneyUpQuickAction(exactDeepLink: url) "
        "else { return false } let mode = QuickLogLaunchMode(action) "
        "requestedQuickLogMode = mode _ = routeLockSafeRequestIfPossible() "
        "return true"
    ):
        errors.append(
            "deep-link handoff must remain an exact data-free route that fails "
            "closed at every authoritative boundary"
        )
    return errors


def validate_book_replacement_action_boundaries(
    restore_preview_source: str,
    key_cliff_source: str,
) -> list[str]:
    """Keep production restore paths inside balanced action-only boundaries."""
    errors: list[str] = []

    preview_restore = declaration_body(
        restore_preview_source,
        "func restoreEncryptedBackup(\n        _ ticket: RestorePreviewTicket",
    )
    normalized_preview = (
        "" if preview_restore is None else " ".join(preview_restore.split())
    )
    preview_boundary = (
        "let quickActionBoundaryEpoch = try beginRestoreMutation() "
        "var quickActionRecoveryWasValidated = false defer { "
        "finishBookReplacementMutation() finishQuickActionBoundary( "
        "quickActionBoundaryEpoch, validatedRecovery: "
        "quickActionRecoveryWasValidated ) } "
        "await finishBeginningRestoreMutation()"
    )
    if preview_restore is None or preview_boundary not in normalized_preview:
        errors.append(
            "ticket restore must install balanced broker and book-replacement "
            "cleanup before its normal-book suspension"
        )
    elif (
        preview_restore.count("beginRestoreMutation()") != 1
        or preview_restore.count("finishQuickActionBoundary(") != 1
        or preview_restore.count("quickActionRecoveryWasValidated = true") != 1
        or preview_restore.count("endAuthoritativeBoundary(") != 0
    ):
        errors.append(
            "ticket restore must own one success-qualified broker epoch"
        )

    resumed_startup = declaration_body(
        key_cliff_source,
        "func openAndFinishStartupIncludingKeyCliffRecovery(",
    )
    normalized_resumed_startup = (
        "" if resumed_startup is None else " ".join(resumed_startup.split())
    )
    resumed_startup_boundary = (
        "let quickActionBoundaryEpoch = try quickActionBoundaryForKeyCliffResume( "
        "isResuming ) var quickActionRecoveryWasValidated = false defer { "
        "finishQuickActionBoundary( quickActionBoundaryEpoch, validatedRecovery: "
        "quickActionRecoveryWasValidated ) } if isResuming {"
    )
    boundary_begin_offset = (
        -1
        if resumed_startup is None
        else resumed_startup.find(
            "let quickActionBoundaryEpoch = try quickActionBoundaryForKeyCliffResume("
        )
    )
    boundary_defer_offset = (
        -1
        if resumed_startup is None
        else resumed_startup.find("        defer {", boundary_begin_offset)
    )
    resume_work_offsets = (
        []
        if resumed_startup is None
        else [
            offset
            for token in (
                "KeyCliffRecoveryTransaction.phase(",
                "keyCliffRecoveryKeyAccess.delete()",
                "KeyCliffRecoveryTransaction.restoreOriginal(",
                "KeyCliffRecoveryTransaction.installCandidate(",
                "openDatabaseStore(",
                "await ",
            )
            if (offset := resumed_startup.find(token)) >= 0
        ]
    )
    boundary_precedes_resume_work = (
        boundary_begin_offset >= 0
        and boundary_defer_offset > boundary_begin_offset
        and bool(resume_work_offsets)
        and boundary_defer_offset < min(resume_work_offsets)
    )
    if (
        resumed_startup is None
        or resumed_startup_boundary not in normalized_resumed_startup
        or not boundary_precedes_resume_work
    ):
        errors.append(
            "resumed startup must synchronously install a balanced broker "
            "boundary before rollback, candidate install, database open, or "
            "suspension work"
        )
    elif (
        resumed_startup.count("quickActionBoundaryForKeyCliffResume(") != 1
        or resumed_startup.count("finishQuickActionBoundary(") != 1
        or resumed_startup.count("quickActionRecoveryWasValidated = isResuming") != 1
        or resumed_startup.count("endAuthoritativeBoundary(") != 0
    ):
        errors.append(
            "resumed startup must own one success-qualified broker epoch"
        )
    resume_boundary_helper = declaration_body(
        key_cliff_source,
        "private func quickActionBoundaryForKeyCliffResume(",
    )
    if normalized_swift_body(resume_boundary_helper) != (
        "guard isResuming else { return nil } "
        "return try beginAuthoritativeQuickActionBoundary()"
    ):
        errors.append(
            "resumed startup boundary helper must synchronously close only a "
            "pending key-cliff epoch"
        )

    key_cliff_restore = declaration_body(
        key_cliff_source,
        "func recoverMissingDeviceBoundKey(",
    )
    normalized_key_cliff = (
        "" if key_cliff_restore is None else " ".join(key_cliff_restore.split())
    )
    key_cliff_boundary = (
        "let quickActionBoundaryEpoch = try beginKeyCliffRecoveryMutation() "
        "var quickActionRecoveryWasValidated = false defer { "
        "finishBookReplacementMutation() finishQuickActionBoundary( "
        "quickActionBoundaryEpoch, validatedRecovery: "
        "quickActionRecoveryWasValidated ) } disableBudgetWidgetSnapshot() "
        "try await requireEmptyLockedCaptureInbox()"
    )
    if key_cliff_restore is None or key_cliff_boundary not in normalized_key_cliff:
        errors.append(
            "missing-key recovery must install balanced broker and "
            "book-replacement cleanup before its first suspension"
        )
    elif (
        key_cliff_restore.count("beginKeyCliffRecoveryMutation()") != 1
        or key_cliff_restore.count("finishQuickActionBoundary(") != 1
        or key_cliff_restore.count("quickActionRecoveryWasValidated = true") != 1
        or key_cliff_restore.count("endAuthoritativeBoundary(") != 0
    ):
        errors.append(
            "missing-key recovery must own one success-qualified broker epoch"
        )
    key_cliff_begin = declaration_body(
        key_cliff_source,
        "private func beginKeyCliffRecoveryMutation() throws -> UInt64",
    )
    if key_cliff_begin is None or " ".join(key_cliff_begin.split()) != (
        "let epoch = try beginAuthoritativeQuickActionBoundary() do { try "
        "beginLifecycleMutation(invalidatesJournalProjection: false) } catch { "
        "quickActionRouteBroker.endAuthoritativeBoundary(epoch) throw error } "
        "isWorking = true isBookReplacementInProgress = true return epoch"
    ):
        errors.append(
            "missing-key recovery must close durable admission before state "
            "mutation and rebalance it if lifecycle admission fails"
        )
    return errors


def validate_shortcuts_source(source: str) -> list[str]:
    errors: list[str] = []
    if "moneyup://" in source or ".deepLink" in source:
        errors.append("App Shortcuts must not open a custom scheme directly")
    if "struct MoneyUpAppShortcuts: AppShortcutsProvider" not in source:
        errors.append("MoneyUpAppShortcuts provider is missing")
    if source.count("AppShortcut(") != len(EXPECTED_ACTIONS):
        errors.append("App Shortcuts must expose exactly the six reviewed actions")
    actions = re.findall(r"OpenQuickLogIntent\(action:\s*\.([A-Za-z0-9]+)\)", source)
    expected_names = [name for name, _, _ in EXPECTED_ACTIONS]
    if actions != expected_names:
        errors.append(
            f"App Shortcut action mapping drifted: expected {expected_names}, found {actions}"
        )
    for phrase in EXPECTED_PHRASES:
        if phrase not in source:
            errors.append(f"App Shortcuts provider is missing reviewed phrase {phrase!r}")
    if source.count(r"\(.applicationName)") != len(EXPECTED_PHRASES):
        errors.append("each App Shortcut phrase must contain applicationName exactly once")
    for symbol, boundary in FORBIDDEN_ACTION_SYMBOLS.items():
        if symbol in source:
            errors.append(f"App Shortcuts provider crosses {boundary}: {symbol}")
    return errors


def validate_widget_source(source: str) -> list[str]:
    errors: list[str] = []
    if "moneyup://" in source or ".deepLink" in source:
        errors.append("widgets must not open a custom scheme directly")
    if source.count('let kind = "MoneyUpQuickLog"') != 1:
        errors.append("persisted MoneyUpQuickLog widget kind drifted")
    if "MoneyUpQuickLogControl()" not in source:
        errors.append("WidgetBundle does not include the iOS 18 quick-log control")
    if "Link(" in source or ".widgetURL(" in source:
        errors.append("quick widgets must use OpenQuickLogIntent, not raw links/widgetURL")
    button = "Button(intent: OpenQuickLogIntent(action: action))"
    if source.count(button) != 5 or source.count("Button(intent:") != 5:
        errors.append("every quick-action widget family must use Button(intent:)")
    if (
        source.count("let snapshot = store.readPublishedSnapshot(now: now)") != 1
        or source.count(
            "BudgetWidgetSnapshotStore(allowsMaintenanceWrites: false)"
        ) != 1
        or "budgetSnapshot: store.read()" in source
        or "insights: store.readInsights()" in source
    ):
        errors.append(
            "widget timeline entries must read one generation without becoming a writer"
        )

    widget_view = declaration_body(source, "private struct MoneyUpWidgetView")
    budget_status_call = re.compile(
        r"case\s+\.budgetStatus\s*:\s*BudgetStatusWidgetView\s*\(\s*"
        r"snapshot\s*:\s*entry\.budgetSnapshot\s*,\s*"
        r"family\s*:\s*family\s*,\s*"
        r"homeDensity\s*:\s*homeDensity\s*\)",
        flags=re.DOTALL,
    )
    if widget_view is None or len(budget_status_call.findall(widget_view)) != 1:
        errors.append(
            "Budget Status must receive the current snapshot and active widget family"
        )
    smart_overview_call = re.compile(
        r"case\s+\.smartOverview\s*:\s*SmartOverviewWidgetView\s*\(\s*"
        r"snapshot\s*:\s*entry\.budgetSnapshot\s*,\s*"
        r"insights\s*:\s*entry\.insights\s*,\s*"
        r"family\s*:\s*family\s*,\s*"
        r"homeDensity\s*:\s*homeDensity\s*\)",
        flags=re.DOTALL,
    )
    if widget_view is None or len(smart_overview_call.findall(widget_view)) != 1:
        errors.append(
            "Smart Overview must receive budget and insights from the same "
            "timeline entry together with the active widget family"
        )
    density_contract = (
        "@Environment(\\.dynamicTypeSize) private var dynamicTypeSize",
        "dynamicTypeSize.isAccessibilitySize ? .accessibility : .standard",
        "homeDensity: homeDensity",
    )
    if widget_view is None or any(
        marker not in widget_view for marker in density_contract
    ):
        errors.append(
            "Home widgets must derive and pass one accessibility Dynamic Type "
            "density policy"
        )

    small_action = declaration_body(source, "private struct SmallQuickActionView")
    medium_actions = declaration_body(
        source,
        "private struct MediumQuickActionsView",
    )
    action_density_contract = (
        small_action is not None
        and "if homeDensity == .accessibility" in small_action
        and "WidgetActionGlyph(action: action, size: 32)" in small_action
        and medium_actions is not None
        and ".prefix(homeDensity.mediumQuickActionLimit)" in medium_actions
        and "if homeDensity == .accessibility" in medium_actions
    )
    if not action_density_contract:
        errors.append(
            "Home quick actions must replace fixed small/medium density at "
            "accessibility sizes"
        )

    rectangular_action = declaration_body(
        source,
        "private struct AccessoryRectangularActionView",
    )
    rectangular_accessibility_contract = (
        rectangular_action is not None
        and ".frame(width: 28)\n                .accessibilityHidden(true)"
            in rectangular_action
        and ".accessibilityElement(children: .ignore)" in rectangular_action
        and ".accessibilityLabel(action.titleKey)" in rectangular_action
        and ".accessibilityHint(action.accessibilityHintKey)" in rectangular_action
    )
    if not rectangular_accessibility_contract:
        errors.append(
            "rectangular action accessibility must hide decorative imagery and "
            "expose the explicit action label and neutral hint"
        )

    accessibility_preview = declaration_body(
        source,
        "private struct MoneyUpWidgetAccessibilityPreviewSurface",
    )
    accessibility_preview_contract = (
        ".environment(\\.dynamicTypeSize, .accessibility5)",
        "homeDensity: .accessibility",
        ".environment(\\.locale, language.locale)",
    )
    modern_preview_contract = (
        '#Preview("Quick action · Small", as: .systemSmall)',
        '#Preview("Quick action · Medium", as: .systemMedium)',
        '#Preview("Smart overview · Small", as: .systemSmall)',
        '#Preview("Smart overview · Medium", as: .systemMedium)',
        "MoneyUpWidgetEntry.preview(content: .quickAction)",
        "MoneyUpWidgetEntry.preview(content: .smartOverview)",
        "language: .english",
        "language: .simplifiedChinese",
    )
    deprecated_preview_markers = (
        "PreviewProvider",
        "WidgetPreviewContext",
        ".previewContext(",
    )
    if (
        accessibility_preview is None
        or any(
            marker not in accessibility_preview
            for marker in accessibility_preview_contract
        )
        or source.count("#Preview(") < 8
        or any(marker not in source for marker in modern_preview_contract)
        or any(marker in source for marker in deprecated_preview_markers)
    ):
        errors.append(
            "widget previews must use modern macros and cover reduced-density "
            "AX5 Home layouts in English and Simplified Chinese"
        )

    configuration = declaration_body(
        source,
        "struct MoneyUpWidgetConfigurationIntent",
    )
    if configuration is None:
        errors.append("MoneyUpWidgetConfigurationIntent is missing or malformed")
    else:
        parameters = re.findall(
            r"@Parameter\([\s\S]*?\)\s*var\s+([A-Za-z][A-Za-z0-9]*)"
            r"\s*:\s*([A-Za-z][A-Za-z0-9]*)",
            configuration,
        )
        expected_parameters = [
            ("content", "MoneyUpWidgetContent"),
            ("defaultAction", "MoneyUpQuickAction"),
        ]
        if configuration.count("@Parameter") != 2 or parameters != expected_parameters:
            errors.append(
                "widget configuration must retain only its two closed enum parameters"
            )

    budget_body = declaration_body(source, "private struct BudgetStatusWidgetView")
    if budget_body is None:
        errors.append("BudgetStatusWidgetView is missing or malformed")
    else:
        for forbidden in ("Button(", "Link(", "OpenQuickLogIntent", ".widgetURL("):
            if forbidden in budget_body:
                errors.append(
                    "budget status must remain passive; found " + forbidden
                )
        body = declaration_body(budget_body, "var body: some View")
        normalized_body = normalized_swift_body(body)
        state_contracts = [
            (
                ".disabled",
                'detail: "widget.budget_enable", '
                'compactDetail: "widget.budget_disabled_short"',
            ),
            (
                ".needsBudget(_)",
                'detail: "widget.budget_needs_plan", '
                'compactDetail: "widget.budget_needs_plan_short"',
            ),
            (
                ".zeroBudget(_)",
                'detail: "widget.budget_zero_plan", '
                'compactDetail: "widget.budget_zero_plan_short"',
            ),
            (
                ".negativeBudget(_)",
                'detail: "widget.budget_negative_plan", '
                'compactDetail: "widget.budget_negative_plan_short"',
            ),
            (
                ".stale",
                'detail: "widget.budget_stale", '
                'compactDetail: "widget.budget_stale_short"',
            ),
        ]
        expected_state_labels = [
            "disabled", "needsBudget", "zeroBudget", "negativeBudget",
            "stale", "available",
        ]
        state_labels = [] if body is None else re.findall(
            r"case\s+(?:let\s+)?\.([A-Za-z][A-Za-z0-9]*)",
            body,
        )
        state_contract_is_complete = state_labels == expected_state_labels
        for state, arguments in state_contracts:
            state_contract_is_complete = state_contract_is_complete and (
                f"case {state}: statusMessage( title: \"widget.budget_status\", "
                f"{arguments}"
            ) in normalized_body
        state_contract_is_complete = state_contract_is_complete and (
            "case let .available(percentUsed, _): "
            "availableStatus(percentUsed: percentUsed)"
        ) in normalized_body
        if not state_contract_is_complete:
            errors.append(
                "budget status must preserve distinct disabled, needs-budget, "
                "zero-budget, negative-budget, stale, and available state guidance"
            )

        expected_available_families = [
            "systemSmall", "systemMedium", "accessoryCircular",
            "accessoryInline", "accessoryRectangular",
        ]
        available = declaration_body(budget_body, "private func availableStatus")
        available_families = [] if available is None else re.findall(
            r"case\s+\.([A-Za-z][A-Za-z0-9]*)\s*:",
            available,
        )
        available_markers = (
            "let isOver = percentUsed > 100",
            "percentAccessibility(percentUsed, isOver: isOver)",
        )
        available_family_markers = {
            "systemSmall": (
                "homeDensity.usesReducedBudgetStatus",
                "accessibilityAvailableStatus(",
                "smallAvailableStatus(percentUsed: percentUsed, isOver: isOver)",
            ),
            "systemMedium": (
                "homeDensity.usesReducedBudgetStatus",
                "accessibilityAvailableStatus(",
                "mediumAvailableStatus(percentUsed: percentUsed, isOver: isOver)",
            ),
            "accessoryCircular": (
                "Gauge(value: min(Double(percentUsed), 100), in: 0...100)",
                ".gaugeStyle(.accessoryCircularCapacity)",
                "percentAccessibility(percentUsed, isOver: isOver)",
            ),
            "accessoryInline": (
                "Text(visiblePercentUsed(percentUsed))",
                "percentAccessibility(percentUsed, isOver: isOver)",
            ),
            "accessoryRectangular": (
                "HStack(spacing: 8)",
                'LocalizedStringKey("widget.budget_over")',
                'LocalizedStringKey("widget.budget_on_plan")',
                "percentAccessibility(percentUsed, isOver: isOver)",
            ),
        }
        available_family_contract_is_complete = all(
            (section := simple_switch_case_body(available, family)) is not None
            and all(marker in section for marker in markers)
            for family, markers in available_family_markers.items()
        )
        small_available = declaration_body(
            budget_body,
            "private func smallAvailableStatus",
        )
        medium_available = declaration_body(
            budget_body,
            "private func mediumAvailableStatus",
        )
        accessibility_available = declaration_body(
            budget_body,
            "private func accessibilityAvailableStatus",
        )
        percent_accessibility = declaration_body(
            budget_body,
            "private func percentAccessibility",
        )
        shared_available_contract_is_complete = (
            small_available is not None
            and 'LocalizedStringKey("widget.budget_over")' in small_available
            and 'LocalizedStringKey("widget.budget_on_plan")' in small_available
            and "percentAccessibility(percentUsed, isOver: isOver)"
                in small_available
            and medium_available is not None
            and 'LocalizedStringKey("widget.budget_over")' in medium_available
            and 'LocalizedStringKey("widget.budget_on_plan")' in medium_available
            and "percentAccessibility(percentUsed, isOver: isOver)"
                in medium_available
            and accessibility_available is not None
            and 'LocalizedStringKey("widget.budget_over")'
                in accessibility_available
            and 'LocalizedStringKey("widget.budget_on_plan")'
                in accessibility_available
            and ".minimumScaleFactor(" not in accessibility_available
            and percent_accessibility is not None
            and 'AppLocalization.string("widget.budget_over", language: language)'
                in percent_accessibility
            and 'AppLocalization.string("widget.budget_on_plan", language: language)'
                in percent_accessibility
        )
        if (
            available_families != expected_available_families
            or available is None
            or any(marker not in available for marker in available_markers)
            or not available_family_contract_is_complete
            or not shared_available_contract_is_complete
        ):
            errors.append(
                "budget status available and over-plan states must route every "
                "supported Home and Lock Screen family"
            )

        expected_message_families = [
            "systemSmall", "systemMedium", "accessoryInline",
            "accessoryCircular", "accessoryRectangular",
        ]
        status_message = declaration_body(budget_body, "private func statusMessage")
        message_families = [] if status_message is None else re.findall(
            r"case\s+\.([A-Za-z][A-Za-z0-9]*)\s*:",
            status_message,
        )
        message_markers = (
            "Text(detail)",
            "Label(compactDetail, systemImage: systemImage)",
            ".accessibilityLabel(compactDetail)",
            "Text(compactDetail)",
        )
        message_family_markers = {
            "systemSmall": (
                "homeDensity.usesReducedBudgetStatus",
                "Label(compactDetail, systemImage: systemImage)",
                "WidgetBrandHeader()",
                "Text(detail)",
            ),
            "systemMedium": (
                "homeDensity.usesReducedBudgetStatus",
                "Label(compactDetail, systemImage: systemImage)",
                "HStack(spacing: 14)",
                "Text(detail)",
            ),
            "accessoryInline": (
                "Label(compactDetail, systemImage: systemImage)",
            ),
            "accessoryCircular": (".accessibilityLabel(compactDetail)",),
            "accessoryRectangular": ("Text(title)", "Text(compactDetail)"),
        }
        message_family_contract_is_complete = all(
            (section := simple_switch_case_body(status_message, family)) is not None
            and all(marker in section for marker in markers)
            for family, markers in message_family_markers.items()
        )
        if (
            message_families != expected_message_families
            or status_message is None
            or any(marker not in status_message for marker in message_markers)
            or not message_family_contract_is_complete
        ):
            errors.append(
                "budget status nonpercentage states must route every supported "
                "Home and Lock Screen family with full or compact guidance"
            )
    return errors


def validate_smart_overview_widget_source(source: str) -> list[str]:
    """Pin the passive family routing and state-specific recovery guidance."""
    errors: list[str] = []
    overview = declaration_body(source, "struct SmartOverviewWidgetView")
    if overview is None:
        return ["SmartOverviewWidgetView is missing or malformed"]

    body = declaration_body(overview, "var body: some View")
    expected_routes = [
        ("systemSmall", "systemSmall"),
        ("systemMedium", "systemMedium"),
        ("accessoryInline", "accessoryInline"),
        ("accessoryCircular", "accessoryCircular"),
        ("accessoryRectangular", "accessoryRectangular"),
    ]
    routed_families = [] if body is None else re.findall(
        r"case\s+\.([A-Za-z][A-Za-z0-9]*)\s*:\s*"
        r"([A-Za-z][A-Za-z0-9]*)",
        body,
    )
    if routed_families != expected_routes:
        errors.append(
            "Smart Overview body must explicitly route every supported Home "
            f"and Lock Screen family; found {routed_families}"
        )

    mapping = declaration_body(overview, "private static func presentationFamily")
    expected_mappings = [
        ("systemSmall", "systemSmall"),
        ("systemMedium", "systemMedium"),
        ("accessoryInline", "accessoryInline"),
        ("accessoryCircular", "accessoryCircular"),
        ("accessoryRectangular", "accessoryRectangular"),
    ]
    mapped_families = [] if mapping is None else re.findall(
        r"case\s+\.([A-Za-z][A-Za-z0-9]*)\s*:\s*"
        r"return\s+\.([A-Za-z][A-Za-z0-9]*)",
        mapping,
    )
    if mapped_families != expected_mappings:
        errors.append(
            "Smart Overview WidgetFamily mapping must preserve every reviewed "
            f"family; found {mapped_families}"
        )

    unavailable = declaration_body(
        overview,
        "private var unavailableBudgetMessage: some View",
    )
    unavailable_contract = (
        "presentation.budget.requiresSettingsEnablement",
        '"widget.smart_enable"',
        '"widget.smart_open_app"',
        '"widget.smart_enable_short"',
        '"widget.smart_refresh_short"',
    )
    if unavailable is None or any(
        marker not in unavailable for marker in unavailable_contract
    ):
        errors.append(
            "Smart Overview must distinguish disabled Settings guidance from "
            "stale open-to-refresh guidance in every compact layout"
        )

    inline = declaration_body(overview, "private var accessoryInline: some View")
    inline_contract = (
        "presentation.budget.requiresSettingsEnablement",
        "presentation.budget.canRefreshByOpeningApp",
        '"widget.smart_enable_short"',
        '"widget.smart_refresh_short"',
    )
    circular = declaration_body(
        overview,
        "private var accessoryCircular: some View",
    )
    circular_contract = (
        "case .disabled:",
        'accessibilityLabel("widget.smart_enable_short")',
        "case .stale:",
        'accessibilityLabel("widget.smart_open_app")',
    )
    if (
        inline is None
        or any(marker not in inline for marker in inline_contract)
        or circular is None
        or any(marker not in circular for marker in circular_contract)
    ):
        errors.append(
            "Smart Overview Lock Screen layouts must keep disabled and stale "
            "recovery guidance distinct"
        )

    budget_value = declaration_body(overview, "private var budgetValue: String")
    nonpercentage_contract = (
        "case .zeroBudget:",
        'AppLocalization.string("widget.smart_budget_zero")',
        "case .negativeBudget:",
        'AppLocalization.string("widget.smart_budget_negative")',
    )
    if budget_value is None or any(
        marker not in budget_value for marker in nonpercentage_contract
    ):
        errors.append(
            "Smart Overview must distinguish zero and negative budgets without "
            "inventing a percentage"
        )

    budget_accessibility = declaration_body(
        overview,
        "private var budgetAccessibilityValue: String",
    )
    if (
        budget_accessibility is None
        or re.search(
            r"case\s+\.disabled\s*:\s*return\s+"
            r"AppLocalization\.string\(\"widget\.smart_enable\"\)",
            budget_accessibility,
            flags=re.DOTALL,
        )
        is None
        or re.search(
            r"case\s+\.stale\s*:\s*return\s+"
            r"AppLocalization\.string\(\"widget\.smart_open_app\"\)",
            budget_accessibility,
            flags=re.DOTALL,
        )
        is None
    ):
        errors.append(
            "Smart Overview accessibility must expose Settings for disabled "
            "and open-app refresh for stale data"
        )

    system_small = declaration_body(
        overview,
        "private var systemSmall: some View",
    )
    system_medium = declaration_body(
        overview,
        "private var systemMedium: some View",
    )
    accessible_small = declaration_body(
        overview,
        "private var systemSmallAccessibility: some View",
    )
    accessible_medium = declaration_body(
        overview,
        "private var systemMediumAccessibility: some View",
    )
    density_contract_is_complete = (
        "homeDensity: MoneyUpWidgetHomeDensity = .standard" in overview
        and "homeDensity: homeDensity" in overview
        and system_small is not None
        and "presentation.homeDensity == .accessibility" in system_small
        and "systemSmallAccessibility" in system_small
        and system_medium is not None
        and "presentation.homeDensity == .accessibility" in system_medium
        and "systemMediumAccessibility" in system_medium
        and accessible_small is not None
        and ".minimumScaleFactor(" not in accessible_small
        and accessible_medium is not None
        and ".minimumScaleFactor(" not in accessible_medium
    )
    if not density_contract_is_complete:
        errors.append(
            "Smart Overview must replace fixed Home grids with reduced-density "
            "accessibility layouts"
        )

    for forbidden in ("Button(", "Link(", "OpenQuickLogIntent", ".widgetURL("):
        if forbidden in overview:
            errors.append(
                "Smart Overview must remain passive; found " + forbidden
            )
    return errors


def validate_app_localization_source(source: str) -> list[str]:
    """Keep widget language reads inside the declared App Group boundary."""
    errors: list[str] = []
    if re.search(r"UserDefaults\.standard|\?\?\s*\.standard", source):
        errors.append(
            "shared localization must not fall back to extension standard defaults"
        )
    current = declaration_body(source, "static var current")
    resolver = declaration_body(source, "static func resolved(")
    if (
        "static var defaults: UserDefaults?" not in source
        or "suiteName: BudgetWidgetSnapshotStore.appGroupIdentifier" not in source
        or current is None
        or "resolved(from: defaults)" not in current
        or resolver is None
        or "defaults?.string(forKey: storageKey)" not in resolver
        or "?? .system" not in resolver
    ):
        errors.append(
            "unavailable App Group localization must resolve to system language"
        )
    return errors


def validate_widget_snapshot_source(source: str) -> list[str]:
    """Validate the reviewed, record-free App Group schema-v4 boundary."""
    errors: list[str] = []
    if source.count("static let currentSchemaVersion = 4") != 1:
        errors.append("widget snapshot must remain schema version 4")
    if source.count(
        'static let payloadKey = "moneyUp.widget.snapshot.v4"'
    ) != 1:
        errors.append("widget snapshot must retain its single version-4 payload key")
    if (
        "static var allowedPersistedKeys: Set<String> { [payloadKey] }"
        not in source
    ):
        errors.append("widget snapshot persisted-key allowlist must contain only payloadKey")
    if source.count("_ snapshot: BudgetWidgetSnapshot,") != 1:
        errors.append(
            "widget publication must distinguish disabled, stale, no-budget, "
            "zero/negative-budget, and percentage"
        )

    insights = declaration_body(source, "struct PersistedInsights")
    if insights is None:
        errors.append("widget snapshot PersistedInsights schema is missing or malformed")
    else:
        properties = re.findall(
            r"(?m)^\s*var\s+([A-Za-z][A-Za-z0-9]*)\s*:\s*([^\n=]+)",
            insights,
        )
        normalized = [(name, value.strip()) for name, value in properties]
        expected = [
            ("reviewCount", "Int?"),
            ("allowancePercentRemaining", "Int?"),
            ("activeCommitmentCount", "Int"),
            ("daysUntilNextCommitment", "Int?"),
            ("validUntil", "Date"),
        ]
        if normalized != expected:
            errors.append(
                "widget insights must retain only reviewed bounded derivatives; "
                f"found {normalized}"
            )

    snapshot = declaration_body(source, "struct PersistedSnapshot")
    if snapshot is None:
        errors.append("widget PersistedSnapshot schema is missing or malformed")
    else:
        properties = re.findall(
            r"(?m)^\s*var\s+([A-Za-z][A-Za-z0-9]*)\s*:\s*([^\n=]+)",
            snapshot,
        )
        normalized = [(name, value.strip()) for name, value in properties]
        expected = [
            ("schemaVersion", "Int"),
            ("enabled", "Bool"),
            ("budgetState", "BudgetState"),
            ("percentUsed", "Int?"),
            ("periodToken", "String?"),
            ("budgetValidUntil", "Date?"),
            ("insights", "PersistedInsights?"),
        ]
        if normalized != expected:
            errors.append(
                "widget snapshot must retain only reviewed status and insight fields; "
                f"found {normalized}"
            )

    write = "defaults.set(data, forKey: Self.payloadKey)"
    if source.count("defaults.set(") != 1 or source.count(write) != 1:
        errors.append(
            "widget snapshot must use one version-4 App Group write through payloadKey"
        )
    required_migration_markers = [
        "guard version <= 3",
        "guard version >= 1 else { return .disabled }",
        "guard version >= 2 else { return .stale }",
        'key.hasPrefix("budgetStatus.") || key.hasPrefix("widget.")',
        "daysUntilNextCommitment: nil",
    ]
    for marker in required_migration_markers:
        if marker not in source:
            errors.append(f"widget snapshot migration is missing {marker}")

    publish = declaration_body(source, "func publish(")
    sanitizer = declaration_body(source, "private static func sanitized(")
    budget_sanitizer = declaration_body(
        source,
        "private static func sanitizedBudgetState",
    )
    count_guard = declaration_body(
        source,
        "private static func hasValidInsightCounts",
    )
    negative_contract = (
        publish is not None
        and "guard Self.hasValidInsightShape(insights)" in publish
        and "percentUsed >= 0" in publish
        and sanitizer is not None
        and "hasValidInsightCounts(" in sanitizer
        and budget_sanitizer is not None
        and "percentUsed >= 0" in budget_sanitizer
        and count_guard is not None
        and "reviewCount.map { $0 >= 0 }" in count_guard
        and "allowancePercentRemaining.map { $0 >= 0 }" in count_guard
        and "activeCommitmentCount >= 0" in count_guard
        and "daysUntilNextCommitment.map { $0 >= 0 }" in count_guard
    )
    if not negative_contract:
        errors.append(
            "widget snapshot must reject negative current derivatives before "
            "positive overflow bounding"
        )

    current_record = declaration_body(source, "private func currentRecord")
    migration = declaration_body(source, "func migrateIfNeeded")
    corrupt_contract = (
        current_record is not None
        and "let data = defaults.data(forKey: Self.payloadKey)" in current_record
        and "guard let decoded = decodedRecord(from: data) else" in current_record
        and "return .stale" in current_record
        and migration is not None
        and "if let data = defaults.data(forKey: Self.payloadKey)" in migration
        and "decodedRecord(from: data)" in migration
        and "persist(.stale, to: defaults)" in migration
    )
    if not corrupt_contract:
        errors.append(
            "present corrupt or future widget payloads must be stale while an "
            "absent payload remains disabled"
        )

    canonical_disabled_contract = (
        sanitizer is not None
        and "return value == .disabled ? .disabled : .stale" in sanitizer
        and "guard value.budgetState != .disabled else { return .stale }"
            in sanitizer
    )
    if not canonical_disabled_contract:
        errors.append(
            "only the canonical empty disabled widget record may render as opt-out"
        )

    bounded_decode = declaration_body(
        source,
        "private func decodedRecord(from data: Data)",
    )
    period_token = declaration_body(
        source,
        "private static func isValidPeriodToken",
    )
    bounded_payload_contract = (
        "static let maximumPayloadByteCount = 4_096" in source
        and bounded_decode is not None
        and "data.count <= Self.maximumPayloadByteCount" in bounded_decode
        and "decoder.decode(PersistedSnapshot.self, from: data)" in bounded_decode
    )
    if not bounded_payload_contract:
        errors.append(
            "widget payload bytes must be capped before version-4 JSON decoding"
        )
    bounded_period_contract = (
        period_token is not None
        and "token.utf8.count == 7" in period_token
        and "(1...9_999).contains(year)" in period_token
        and "(1...12).contains(month)" in period_token
        and 'String(format: "%04d-%02d", year, month)' in period_token
        and "regularExpression" not in period_token
    )
    if not bounded_period_contract:
        errors.append(
            "widget period token must be one canonical bounded YYYY-MM value"
        )
    return errors


def validate_control_source(source: str) -> list[str]:
    errors: list[str] = []
    if "moneyup://" in source or ".deepLink" in source:
        errors.append("control must not open a custom scheme directly")
    if "@Parameter" in source or "ControlConfigurationIntent" in source:
        errors.append(
            "control must not declare a second configuration payload"
        )
    if "struct MoneyUpQuickLogControl: ControlWidget" not in source:
        errors.append("MoneyUpQuickLogControl is missing")
    if "intent: OpenQuickLogIntent.self" not in source:
        errors.append("control configuration must use OpenQuickLogIntent")
    if "ControlWidgetButton(action: configuration)" not in source:
        errors.append("control action must execute its configured OpenQuickLogIntent")
    if source.count("ControlWidgetButton(") != 1:
        errors.append("quick-log control must expose exactly one intent button")
    if "OpenURLIntent" in source:
        errors.append("control bypasses the reviewed intent mapping with OpenURLIntent")
    for symbol, boundary in FORBIDDEN_ACTION_SYMBOLS.items():
        if symbol in source:
            errors.append(f"quick-log control crosses {boundary}: {symbol}")
    return errors


def validate_compiled_surface_inventory(root: Path) -> list[str]:
    """Inventory every Swift source included by the app and widget targets."""
    errors: list[str] = []
    sources: dict[str, str] = {}
    for source_root in COMPILED_SWIFT_ROOTS:
        directory = root / source_root
        try:
            paths = sorted(directory.rglob("*.swift"))
        except OSError as error:
            errors.append(f"cannot inventory compiled Swift root {source_root}: {error}")
            continue
        for path in paths:
            relative = path.relative_to(root).as_posix()
            try:
                sources[relative] = path.read_text(encoding="utf-8")
            except OSError as error:
                errors.append(f"cannot read compiled Swift source {relative}: {error}")

    # Package.swift is digest-pinned below and every current production target
    # uses its default Sources/<Target> path. Reject any new repository Swift
    # root so a custom package target cannot sit outside the compiled inventory.
    try:
        repository_swift = sorted(root.rglob("*.swift"))
    except OSError as error:
        errors.append(f"cannot discover repository Swift sources: {error}")
        repository_swift = []
    for path in repository_swift:
        relative_path = path.relative_to(root)
        relative = relative_path.as_posix()
        if relative in sources or relative == "Package.swift":
            continue
        if relative_path.parts[0] in IGNORED_SWIFT_INVENTORY_ROOTS:
            continue
        errors.append(
            "unreviewed production Swift source is outside the compiled "
            f"inventory: {relative}"
        )
        try:
            sources[relative] = path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"cannot read unreviewed Swift source {relative}: {error}")

    for relative, source in sources.items():
        uses_app_intents = (
            re.search(r"(?m)^\s*(?:@_exported\s+)?import\s+AppIntents\s*$", source)
            is not None
        )
        if uses_app_intents and relative not in APP_INTENTS_SOURCE_ALLOWLIST:
            errors.append(
                f"unreviewed compiled AppIntents source is outside the allowlist: {relative}"
            )
        if relative not in PLATFORM_REFERENCE_ALLOWLIST:
            for marker in PLATFORM_REFERENCE_MARKERS:
                if marker in source:
                    errors.append(
                        f"unreviewed compiled platform-action reference {marker} "
                        f"in {relative}"
                    )

    combined = "\n".join(sources.values())
    forbidden_global_patterns = {
        r"\bOpenIntent\b": "an alternate OpenIntent",
        r"\bOpenURLIntent\b": "a direct URL intent",
        r"\.result\s*\(\s*opensIntent\s*:": "an intent-opening result",
        r"\bIntentDialog\b": "an intent dialog payload",
        r"\bIntentFile\b": "an intent file payload",
    }
    for pattern, description in forbidden_global_patterns.items():
        if re.search(pattern, combined):
            errors.append(f"compiled platform-action inventory contains {description}")

    declaration_patterns = {
        r"\bAppIntent\b": 1,
        r"\bControlConfigurationIntent\b": 1,
        r"\bWidgetConfigurationIntent\b": 1,
        r"\bAppShortcutsProvider\b": 1,
        r"\bControlWidget\b": 1,
        r"\bAppIntentControlConfiguration\s*\(": 1,
        r"@Parameter\b": 3,
    }
    for pattern, expected_count in declaration_patterns.items():
        count = len(re.findall(pattern, combined))
        if count != expected_count:
            errors.append(
                "compiled platform-action declaration inventory drifted for "
                f"{pattern!r}: expected {expected_count}, found {count}"
            )

    for pattern, expected_by_file in PLATFORM_SURFACE_INVENTORY.items():
        actual_by_file = {
            relative: len(re.findall(pattern, source))
            for relative, source in sources.items()
            if re.search(pattern, source)
        }
        if actual_by_file != expected_by_file:
            errors.append(
                "compiled platform-action surface moved or multiplied for "
                f"{pattern!r}: expected {expected_by_file}, found {actual_by_file}"
            )
    for pattern, expected_by_file in COMPILED_REFERENCE_INVENTORY.items():
        actual_by_file = {
            relative: len(re.findall(pattern, source))
            for relative, source in sources.items()
            if re.search(pattern, source)
        }
        if actual_by_file != expected_by_file:
            errors.append(
                "compiled platform-action reference inventory drifted for "
                f"{pattern!r}: expected {expected_by_file}, found {actual_by_file}"
            )
    return errors


def bilingual_values(entry: object) -> tuple[str, str] | None:
    if not isinstance(entry, dict):
        return None
    localizations = entry.get("localizations")
    if not isinstance(localizations, dict):
        return None
    values: list[str] = []
    for language in ("en", "zh-Hans"):
        localization = localizations.get(language)
        if not isinstance(localization, dict):
            return None
        unit = localization.get("stringUnit")
        if not isinstance(unit, dict) or unit.get("state") != "translated":
            return None
        value = unit.get("value")
        if not isinstance(value, str) or not value.strip():
            return None
        values.append(value)
    return values[0], values[1]


def validate_localization_catalogs(root: Path) -> list[str]:
    errors: list[str] = []
    catalog_contract = [
        (
            root / "App/MoneyUp/Resources/Localizable.xcstrings",
            PLATFORM_LOCALIZATION_KEYS | SHORTCUT_LOCALIZATION_KEYS,
        ),
        (
            root / "App/MoneyUpWidget/Localizable.xcstrings",
            PLATFORM_LOCALIZATION_KEYS | CONTROL_LOCALIZATION_KEYS,
        ),
    ]
    for path, expected_keys in catalog_contract:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"cannot parse {path.relative_to(root)}: {error}")
            continue
        strings = payload.get("strings", {})
        missing = expected_keys - set(strings)
        if missing:
            errors.append(
                f"{path.relative_to(root)} is missing platform metadata: "
                + ", ".join(sorted(missing))
            )
        for key in expected_keys & set(strings):
            values = bilingual_values(strings[key])
            if values is None:
                errors.append(f"{path.relative_to(root)}:{key} is not bilingual")
                continue
            if (
                key == "platform_action.capture_without_unlock"
                and values != PREFERENCE_NEUTRAL_CAPTURE_HINTS
            ):
                errors.append(
                    f"{path.relative_to(root)}:{key} must not promise that "
                    "capture bypasses the user's unlock preference"
                )
            for value in values:
                if "%" in value or "${" in value:
                    errors.append(
                        f"{path.relative_to(root)}:{key} contains dynamic metadata"
                    )

    shortcuts = root / "App/MoneyUp/Resources/AppShortcuts.xcstrings"
    try:
        payload = json.loads(shortcuts.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"cannot parse {shortcuts.relative_to(root)}: {error}")
        return errors
    strings = payload.get("strings", {})
    if set(strings) != set(EXPECTED_PHRASES):
        errors.append("AppShortcuts.xcstrings phrases drifted from the reviewed set")
    for phrase, entry in strings.items():
        values = bilingual_values(entry)
        if values is None:
            errors.append(f"AppShortcuts.xcstrings:{phrase} is not bilingual")
            continue
        for value in values:
            if value.count(r"\(.applicationName)") != 1:
                errors.append(
                    f"AppShortcuts.xcstrings:{phrase} must preserve applicationName"
                )
            remainder = value.replace(r"\(.applicationName)", "")
            if r"\(" in remainder or "%" in remainder or "${" in remainder:
                errors.append(
                    f"AppShortcuts.xcstrings:{phrase} contains a payload placeholder"
                )
    return errors


def validate_identity_and_capture_boundary(root: Path) -> list[str]:
    errors: list[str] = []
    try:
        project = (root / "project.yml").read_text(encoding="utf-8")
    except OSError as error:
        return [f"cannot read project.yml: {error}"]
    if 'deploymentTarget:\n    iOS: "18.0"' not in project:
        errors.append("project iOS deployment target drifted from 18.0")
    if "bundleIdPrefix: com.laiwenkang" not in project:
        errors.append("project bundle ID prefix drifted")
    expected_target_sources = {
        "MoneyUp": ["App/MoneyUp", "App/Shared"],
        "MoneyUpTests": ["Tests/MoneyUpAppTests"],
        "MoneyUpWidget": ["App/MoneyUpWidget", "App/Shared"],
    }
    for target, expected_sources in expected_target_sources.items():
        actual_sources = project_target_source_paths(project, target)
        if actual_sources != expected_sources:
            errors.append(
                f"{target} compiled source roots drifted: expected "
                f"{expected_sources}, found {actual_sources}"
            )
    bundle_ids = re.findall(
        r"(?m)^\s+PRODUCT_BUNDLE_IDENTIFIER:\s*([^\s#]+)\s*$",
        project,
    )
    expected_bundle_ids = [
        APP_BUNDLE_ID,
        TEST_BUNDLE_ID,
        PERFORMANCE_TEST_BUNDLE_ID,
        WIDGET_BUNDLE_ID,
    ]
    if bundle_ids != expected_bundle_ids:
        errors.append(
            "project bundle IDs drifted: "
            f"expected {expected_bundle_ids}, found {bundle_ids}"
        )
    try:
        package_path = root / "Package.swift"
        package = package_path.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"cannot read Package.swift: {error}")
    else:
        if hashlib.sha256(package_path.read_bytes()).hexdigest() != (
            PACKAGE_MANIFEST_SHA256
        ):
            errors.append(
                "Package.swift changed the reviewed app-linked target graph"
            )
        if ".iOS(.v18)" not in package:
            errors.append("package iOS deployment target drifted from 18")

    expected_entitlement = {
        "com.apple.security.application-groups": [APP_GROUP_ID]
    }
    for relative in (
        "App/MoneyUp/MoneyUp.entitlements",
        "App/MoneyUpWidget/MoneyUpWidget.entitlements",
    ):
        path = root / relative
        try:
            with path.open("rb") as source:
                payload = plistlib.load(source)
        except (OSError, plistlib.InvalidFileException) as error:
            errors.append(f"cannot parse {relative}: {error}")
            continue
        if payload != expected_entitlement:
            errors.append(f"{relative} changed the reviewed App Group payload")

    for relative, expected_digest in APP_GROUP_PAYLOAD_SHA256.items():
        path = root / relative
        try:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as error:
            errors.append(f"cannot read reviewed App Group source {relative}: {error}")
            continue
        if digest != expected_digest:
            errors.append(f"{relative} changed the reviewed App Group payload")

    capture_path = root / "App/MoneyUp/LockedCaptureStore.swift"
    try:
        capture_source = capture_path.read_text(encoding="utf-8")
        capture_digest = hashlib.sha256(capture_path.read_bytes()).hexdigest()
    except OSError as error:
        errors.append(f"cannot read locked-capture store: {error}")
    else:
        if capture_digest != LOCKED_CAPTURE_STORE_SHA256:
            errors.append("LockedCaptureStore.swift changed outside the reviewed W7 scope")
        capture_required = (
            "static let durableWriteOptions: Data.WritingOptions = [",
            ".completeFileProtectionUntilFirstUserAuthentication",
            "try combined.write(to: url, options: Self.durableWriteOptions)",
            "try Self.enforceDurableFileProtection(at: url)",
            "FileProtectionType.completeUntilFirstUserAuthentication",
        )
        for declaration in capture_required:
            if declaration not in capture_source:
                errors.append(
                    "locked-capture first-unlock protection is missing "
                    + declaration
                )
        if (
            ".completeFileProtectionUnlessOpen" in capture_source
            or "attributesOfItem" in capture_source
        ):
            errors.append(
                "locked-capture protection must migrate without legacy writes "
                "or production metadata reads"
            )
    return errors


def validate_release_gates(root: Path) -> list[str]:
    errors: list[str] = []
    required_files = {
        ".github/workflows/ci.yml": [
            "python3 Scripts/validate_platform_actions.py",
            "Tests/PlatformActionsValidatorTests",
        ],
        ".github/workflows/testflight.yml": [
            "python3 Scripts/validate_platform_actions.py",
        ],
        "Scripts/validate_release_assets.py": [
            "validate_platform_actions.py",
        ],
        "docs/FIRST_TEST.md": [
            "PLATFORM_ACTIONS_RUNBOOK.md",
        ],
        "docs/PLATFORM_ACTIONS_RUNBOOK.md": [
            "iOS 18",
            "App Shortcuts Preview",
            "Budget status",
            "Control Center",
            "locked-capture",
            "durable **at-least-once ingress",
            "4,096 bytes",
            "first-unlock file protection",
            "OS invocation identifier",
            "transient startup work",
            "newest invocation is rejected",
            "discards the entire old-book FIFO",
            "persist a closed-admission boundary",
            "generation-bound",
            "supportedModes",
        ],
    }
    for relative, declarations in required_files.items():
        path = root / relative
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"cannot read required platform-action gate {relative}: {error}")
            continue
        for declaration in declarations:
            if declaration not in text:
                errors.append(f"{relative} is missing platform-action gate {declaration}")
    return errors


def validate_repository(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    errors.extend(validate_compiled_surface_inventory(root))
    source_contract = [
        (
            "App/Shared/MoneyUpQuickAction.swift",
            validate_shared_action_source,
        ),
        (
            "App/MoneyUp/MoneyUpAppShortcuts.swift",
            validate_shortcuts_source,
        ),
        (
            "App/MoneyUp/MoneyUpApp.swift",
            validate_app_routing_source,
        ),
        (
            "App/MoneyUp/RootView.swift",
            validate_root_handoff_source,
        ),
        (
            "App/MoneyUp/QuickLogLaunchMode.swift",
            validate_request_identity_source,
        ),
        (
            "App/MoneyUp/AppModelValidation.swift",
            validate_model_validation_handoff_source,
        ),
        (
            "App/MoneyUp/AppModelQuickActionIngress.swift",
            validate_model_quick_action_ingress_source,
        ),
        (
            "App/MoneyUp/QuickLogSheet.swift",
            validate_log_handoff_source,
        ),
        (
            "App/MoneyUp/QuickLogEntryDraft.swift",
            validate_log_request_draft_source,
        ),
        (
            "App/MoneyUp/QuickLogEntryBody.swift",
            validate_log_request_body_source,
        ),
        (
            "App/MoneyUp/LockedQuickCaptureView.swift",
            validate_locked_handoff_source,
        ),
        (
            "App/MoneyUp/MoneyUpQuickActionRouting.swift",
            validate_app_router_source,
        ),
        (
            "App/MoneyUpWidget/MoneyUpWidget.swift",
            validate_widget_source,
        ),
        (
            "App/MoneyUpWidget/SmartOverviewWidgetView.swift",
            validate_smart_overview_widget_source,
        ),
        (
            "App/Shared/AppLocalization.swift",
            validate_app_localization_source,
        ),
        (
            "App/Shared/BudgetWidgetSnapshot.swift",
            validate_widget_snapshot_source,
        ),
        (
            "App/MoneyUpWidget/MoneyUpQuickLogControl.swift",
            validate_control_source,
        ),
    ]
    for relative, validator in source_contract:
        path = root / relative
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"cannot read {relative}: {error}")
            continue
        errors.extend(f"{relative}: {error}" for error in validator(source))
    boundary_paths = [
        "App/MoneyUp/AppModel.swift",
        "App/MoneyUp/AppModelLifecycle.swift",
        "App/MoneyUp/AppModelSettings.swift",
        "App/MoneyUp/AppModelBackupRestore.swift",
    ]
    boundary_sources: list[str] = []
    for relative in boundary_paths:
        try:
            boundary_sources.append(
                (root / relative).read_text(encoding="utf-8")
            )
        except OSError as error:
            errors.append(f"cannot read {relative}: {error}")
    if len(boundary_sources) == len(boundary_paths):
        errors.extend(
            "quick-action boundary lifecycle: " + error
            for error in validate_boundary_lifecycle_sources(*boundary_sources)
        )
    replacement_paths = [
        "App/MoneyUp/AppModelRestorePreview.swift",
        "App/MoneyUp/AppModelKeyCliffRecovery.swift",
    ]
    replacement_sources: list[str] = []
    for relative in replacement_paths:
        try:
            replacement_sources.append(
                (root / relative).read_text(encoding="utf-8")
            )
        except OSError as error:
            errors.append(f"cannot read {relative}: {error}")
    if len(replacement_sources) == len(replacement_paths):
        errors.extend(
            "quick-action book replacement: " + error
            for error in validate_book_replacement_action_boundaries(
                *replacement_sources
            )
        )
    errors.extend(validate_localization_catalogs(root))
    errors.extend(validate_identity_and_capture_boundary(root))
    errors.extend(validate_release_gates(root))
    return errors


def main() -> int:
    errors = validate_repository()
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(
        "Validated six exact quick-log routes, bounded durable data-free ingress "
        "with exact-token acknowledgement, passive budget status, bilingual "
        "metadata, and preserved release identity"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
