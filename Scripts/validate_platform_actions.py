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
        "f806810aa1a07959a4c92cba52b8f139ded9dd50e45b6bdd37f54bfb0812595d"
    ),
}
LOCKED_CAPTURE_STORE_SHA256 = (
    "d7f8890fb41b1faf9963961c0ef4039b916d2863a4048d5a023fa650c292b467"
)
SHARED_ACTION_SOURCE_SHA256 = (
    "b9a2bcb8a29dcea02bcacb5414bef6397c0370e525bb8f9401b0b164fc535d38"
)
APP_ROUTER_SOURCE_SHA256 = (
    "5a9334fd5bef49c921ffda531ea769864a820c917742509356dbb96c246d2a9e"
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
        "App/Shared/MoneyUpQuickAction.swift": 11,
        "App/MoneyUpWidget/MoneyUpWidget.swift": 10,
    },
    r"\bMoneyUpQuickActionRouteBroker\b": {
        "App/MoneyUp/AppModel.swift": 5,
        "App/MoneyUp/MoneyUpApp.swift": 1,
        "App/MoneyUp/MoneyUpQuickActionRouting.swift": 1,
        "App/Shared/MoneyUpQuickAction.swift": 3,
    },
    r"\bquickActionRouteBroker\b": {
        "App/MoneyUp/AppModel.swift": 10,
        "App/MoneyUp/AppModelBackupRestore.swift": 1,
        "App/MoneyUp/AppModelKeyCliffRecovery.swift": 2,
        "App/MoneyUp/AppModelLifecycle.swift": 5,
        "App/MoneyUp/AppModelRestorePreview.swift": 1,
        "App/MoneyUp/AppModelSettings.swift": 1,
        "App/MoneyUp/MoneyUpApp.swift": 4,
        "App/MoneyUp/MoneyUpQuickActionRouting.swift": 2,
        "App/MoneyUp/RootView.swift": 3,
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
        "App/MoneyUp/LockedQuickCaptureView.swift": 1,
        "App/MoneyUp/QuickLogEntryDraft.swift": 1,
        "App/MoneyUp/QuickLogLaunchMode.swift": 1,
        "App/MoneyUp/QuickLogSheet.swift": 5,
    },
    r"\brequestedQuickLogRequest\b": {
        "App/MoneyUp/AppModel.swift": 3,
        "App/MoneyUp/AppModelLifecycle.swift": 3,
        "App/MoneyUp/LockedQuickCaptureView.swift": 1,
        "App/MoneyUp/MoneyUpApp.swift": 1,
        "App/MoneyUp/RootView.swift": 3,
    },
    r"\bpresentedQuickLogRequest\b": {
        "App/MoneyUp/AppModel.swift": 1,
        "App/MoneyUp/AppModelLifecycle.swift": 2,
        "App/MoneyUp/AppModelValidation.swift": 1,
        "App/MoneyUp/RootView.swift": 1,
    },
    r"\brequestedQuickLogMode\b": {
        "App/MoneyUp/AppModel.swift": 3,
        "App/MoneyUp/AppModelBackupRestore.swift": 1,
        "App/MoneyUp/AppModelKeyCliffRecovery.swift": 3,
        "App/MoneyUp/AppModelLifecycle.swift": 9,
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
        "MoneyUpQuickActionRouteBroker.shared.submit(action) return .result()"
    ):
        errors.append("OpenQuickLogIntent perform body must remain broker-only")

    broker_body = declaration_body(source, "final class MoneyUpQuickActionRouteBroker")
    if (
        "@MainActor\n@Observable\nfinal class MoneyUpQuickActionRouteBroker"
        not in source
    ):
        errors.append("quick-action route broker must be main-actor observable state")
    if broker_body is None:
        errors.append("process-local quick-action route broker is missing")
    else:
        broker_members = re.findall(
            r"(?m)^    (?:static\s+)?(?:private(?:\(set\))?\s+)?"
            r"(?:let|var)\s+([A-Za-z][A-Za-z0-9]*)",
            broker_body,
        )
        expected_broker_members = [
            "shared",
            "maximumPendingActionCount",
            "pendingActions",
            "nextBoundaryEpoch",
            "activeBoundaryEpochs",
            "revision",
            "handoffGeneration",
            "pendingAction",
            "pendingCount",
            "isAuthoritativeBoundaryActive",
        ]
        if broker_members != expected_broker_members:
            errors.append(
                "route broker declaration inventory drifted; "
                f"found {broker_members}"
            )
        broker_functions = re.findall(
            r"(?m)^    (?:@discardableResult\s*\n    )?func\s+"
            r"([A-Za-z][A-Za-z0-9]*)",
            broker_body,
        )
        if broker_functions != [
            "submit",
            "takePendingAction",
            "discardAllPendingActions",
            "beginAuthoritativeBoundary",
            "endAuthoritativeBoundary",
        ]:
            errors.append(
                "route broker may contain only the reviewed FIFO and boundary "
                "methods"
            )
        properties = re.findall(
            r"(?m)^\s*(?:private(?:\(set\))?\s+)?var\s+"
            r"([A-Za-z][A-Za-z0-9]*)\s*:\s*([^=\n{]+)",
            broker_body,
        )
        normalized_properties = [
            (name, value.strip()) for name, value in properties
        ]
        expected_properties = [
            ("pendingActions", "[MoneyUpQuickAction]"),
            ("nextBoundaryEpoch", "UInt64"),
            ("activeBoundaryEpochs", "Set<UInt64>"),
            ("revision", "UInt64"),
            ("handoffGeneration", "UInt64"),
            ("pendingAction", "MoneyUpQuickAction?"),
            ("pendingCount", "Int"),
            ("isAuthoritativeBoundaryActive", "Bool"),
        ]
        if normalized_properties != expected_properties:
            errors.append(
                "route broker may store only the action FIFO, boundary epochs, "
                "and revision; "
                f"found {normalized_properties}"
            )
        stored_properties = re.findall(
            r"(?m)^\s*(?:private(?:\(set\))?\s+)?var\s+"
            r"([A-Za-z][A-Za-z0-9]*)\s*:\s*([^=\n{]+)\s*=",
            broker_body,
        )
        normalized_stored_properties = [
            (name, value.strip()) for name, value in stored_properties
        ]
        expected_stored_properties = [
            ("pendingActions", "[MoneyUpQuickAction]"),
            ("nextBoundaryEpoch", "UInt64"),
            ("activeBoundaryEpochs", "Set<UInt64>"),
            ("revision", "UInt64"),
            ("handoffGeneration", "UInt64"),
        ]
        if normalized_stored_properties != expected_stored_properties:
            errors.append(
                "route broker stored state must be only the closed action FIFO, "
                "boundary epochs, and revision; found "
                f"{normalized_stored_properties}"
            )
        broker_required = [
            "static let shared = MoneyUpQuickActionRouteBroker()",
            "static let maximumPendingActionCount = 16",
            "private var pendingActions: [MoneyUpQuickAction] = []",
            "private var nextBoundaryEpoch: UInt64 = 0",
            "private var activeBoundaryEpochs: Set<UInt64> = []",
            "private(set) var revision: UInt64 = 0",
            "private(set) var handoffGeneration: UInt64 = 0",
            "var pendingAction: MoneyUpQuickAction? { pendingActions.first }",
            "var pendingCount: Int { pendingActions.count }",
            "var isAuthoritativeBoundaryActive: Bool",
        ]
        for declaration in broker_required:
            if declaration not in broker_body:
                errors.append(f"route broker is missing {declaration}")
        submit = declaration_body(
            broker_body,
            "func submit(_ action: MoneyUpQuickAction) -> Bool",
        )
        if submit is None or " ".join(submit.split()) != (
            "guard !isAuthoritativeBoundaryActive else { return false } "
            "guard pendingActions.count < Self.maximumPendingActionCount else { "
            "revision &+= 1 return false } "
            "pendingActions.append(action) revision &+= 1 return true"
        ):
            errors.append(
                "route broker submit must remain bounded action-only FIFO and "
                "wake routing after a capacity rejection"
            )
        take = declaration_body(broker_body, "func takePendingAction()")
        if take is None or " ".join(take.split()) != (
            "guard !isAuthoritativeBoundaryActive, !pendingActions.isEmpty else { "
            "return nil } "
            "let action = pendingActions.removeFirst() revision &+= 1 return action"
        ):
            errors.append("route broker take must consume exactly one FIFO action")
        discard = declaration_body(
            broker_body,
            "func discardAllPendingActions()",
        )
        if discard is None or " ".join(discard.split()) != (
            "guard !pendingActions.isEmpty else { return } "
            "pendingActions.removeAll(keepingCapacity: false) revision &+= 1"
        ):
            errors.append(
                "route broker discard must clear the complete process-local FIFO"
            )
        begin_boundary = declaration_body(
            broker_body,
            "func beginAuthoritativeBoundary() -> UInt64",
        )
        if begin_boundary is None or " ".join(begin_boundary.split()) != (
            "nextBoundaryEpoch &+= 1 let epoch = nextBoundaryEpoch "
            "activeBoundaryEpochs.insert(epoch) "
            "handoffGeneration &+= 1 "
            "pendingActions.removeAll(keepingCapacity: false) revision &+= 1 "
            "return epoch"
        ):
            errors.append(
                "route broker boundary begin must synchronously advance the UI "
                "generation and clear the FIFO"
            )
        end_boundary = declaration_body(
            broker_body,
            "func endAuthoritativeBoundary(_ epoch: UInt64)",
        )
        if end_boundary is None or " ".join(end_boundary.split()) != (
            "guard activeBoundaryEpochs.remove(epoch) != nil else { return } "
            "revision &+= 1"
        ):
            errors.append(
                "route broker boundary end must balance only its exact epoch"
            )
    for symbol, boundary in FORBIDDEN_ACTION_SYMBOLS.items():
        if symbol in source:
            errors.append(f"shared action source crosses {boundary}: {symbol}")
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
        "if model.quickActionRouteBroker.isAuthoritativeBoundaryActive",
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
    if "quickLogLaunchMode" in source or "logRequestSequence" in source:
        errors.append("RootView must not retain an unversioned quick-log launch")
    return errors


def validate_request_identity_source(source: str) -> list[str]:
    errors: list[str] = []
    required = [
        "struct QuickLogRouteRequest: Equatable, Identifiable, Sendable",
        "let id: UInt64",
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
        "guard model.requestedQuickLogRequest == request else { return }",
    ]
    for declaration in required:
        if declaration not in source:
            errors.append(f"locked capture handoff is missing {declaration}")
    if source.count("model.consumeQuickLogRequest(request)") != 2:
        errors.append("locked capture must acknowledge the exact request on both exits")
    if source.count("request: request") != 2:
        errors.append("locked capture must bind both saves to the exact request")
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
        ".deferTransiently: return .deferred case .route: break } guard let action "
        "= broker.takePendingAction() "
        "else { return .idle } guard model.handleDeepLink(action.deepLink) else { "
        "broker.discardAllPendingActions() return .discarded } guard "
        "model.requestedQuickLogMode != nil else { "
        "broker.discardAllPendingActions() return .discarded } guard "
        "model.state == .locked, !model.isLockSafeQuickCaptureRequested else { "
        "return .routed } return .requiresStart"
    ):
        errors.append(
            "app router must discard every post-dequeue authoritative denial, "
            "defer transient work, and take at most one FIFO action"
        )
    if source.count("action.deepLink") != 1:
        errors.append("app router must be the only consumer of the action URL mapping")
    if source.count("broker.takePendingAction()") != 1:
        errors.append("app router must take at most one action per routing pass")
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
        "requestedQuickLogRequest = nil return } nextQuickLogRequestID &+= 1 "
        "requestedQuickLogRequest = QuickLogRouteRequest( id: nextQuickLogRequestID, "
        "generation: quickActionRouteBroker.handoffGeneration, mode: newValue ) }"
    ):
        errors.append(
            "AppModel request setter must remain process-local, generation-bound, "
            "and closed during authoritative boundaries"
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
        "let quickActionBoundaryEpoch = "
        "beginAuthoritativeQuickActionBoundary() defer { "
        "quickActionRouteBroker.endAuthoritativeBoundary(quickActionBoundaryEpoch) "
        "} isWorking = true"
    )
    if erase is None or erase_boundary not in normalized_erase:
        errors.append(
            "erase must synchronously begin and defer-balance the broker boundary "
            "before lifecycle state changes"
        )
    elif (
        erase.count("beginAuthoritativeQuickActionBoundary()") != 1
        or erase.count("quickActionRouteBroker.beginAuthoritativeBoundary()") != 0
        or erase.count("endAuthoritativeBoundary(") != 1
    ):
        errors.append("erase must own exactly one balanced broker boundary")

    restore = declaration_body(
        restore_source,
        "private func restoreEncryptedBackupIntoLiveStore(",
    )
    normalized_restore = "" if restore is None else " ".join(restore.split())
    restore_boundary = (
        "let quickActionBoundaryEpoch = try beginRestoreMutation() defer { "
        "finishBookReplacementMutation() "
        "quickActionRouteBroker.endAuthoritativeBoundary( "
        "quickActionBoundaryEpoch ) "
        "} await finishBeginningRestoreMutation()"
    )
    if restore is None or restore_boundary not in normalized_restore:
        errors.append(
            "restore must retain its broker epoch through every success, error, "
            "and cancellation exit"
        )
    begin_restore = declaration_body(
        restore_source,
        "func beginRestoreMutation() throws -> UInt64",
    )
    normalized_begin_restore = (
        "" if begin_restore is None else " ".join(begin_restore.split())
    )
    begin_restore_boundary = (
        "isBookReplacementInProgress = true logicalBookRevision &+= 1 "
        "let quickActionBoundaryEpoch = "
        "beginAuthoritativeQuickActionBoundary() isWorking = true "
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
        or restore_source.count("endAuthoritativeBoundary(") != 1
    ):
        errors.append("restore source must own exactly one balanced broker boundary")

    start = declaration_body(lifecycle_source, "func start() async")
    normalized_start = "" if start is None else " ".join(start.split())
    start_defer = (
        "var quickActionBoundaryEpoch: UInt64? isWorking = true isStarting = true "
        "defer { isWorking = false isStarting = false if let "
        "quickActionBoundaryEpoch { "
        "quickActionRouteBroker.endAuthoritativeBoundary(quickActionBoundaryEpoch) "
        "} }"
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
        ".isPendingWithoutBlockingLaunch() if isPending { return ( "
        ".success(true), beginAuthoritativeQuickActionBoundary() ) } return "
        "(.success(false), nil) } catch { return ( .failure(error), "
        "beginAuthoritativeQuickActionBoundary() ) }"
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
        or start.count("endAuthoritativeBoundary(") != 1
    ):
        errors.append(
            "startup must delegate exactly two tombstone boundary begins and "
            "defer one epoch end"
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
        "func beginAuthoritativeQuickActionBoundary() -> UInt64",
    )
    if boundary_helper is None or " ".join(boundary_helper.split()) != (
        "let epoch = quickActionRouteBroker.beginAuthoritativeBoundary() "
        "requestedQuickLogMode = nil presentedQuickLogRequest = nil return epoch"
    ):
        errors.append(
            "every authoritative broker begin must synchronously invalidate the "
            "occupied UI request before suspension"
        )
    present_request = declaration_body(
        lifecycle_source,
        "func presentQuickLogRequest(_ request: QuickLogRouteRequest) -> Bool",
    )
    if present_request is None or " ".join(present_request.split()) != (
        "guard requestedQuickLogRequest == request, request.generation == "
        "quickActionRouteBroker.handoffGeneration, "
        "!quickActionRouteBroker.isAuthoritativeBoundaryActive else { return false } "
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
        "guard requestedQuickLogRequest == request else { return } "
        "requestedQuickLogMode = nil"
    ):
        errors.append(
            "quick-log acknowledgement must consume only the exact occupied token"
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
        "let quickActionBoundaryEpoch = try beginRestoreMutation() defer { "
        "finishBookReplacementMutation() "
        "quickActionRouteBroker.endAuthoritativeBoundary( "
        "quickActionBoundaryEpoch ) } await finishBeginningRestoreMutation()"
    )
    if preview_restore is None or preview_boundary not in normalized_preview:
        errors.append(
            "ticket restore must install balanced broker and book-replacement "
            "cleanup before its normal-book suspension"
        )
    elif (
        preview_restore.count("beginRestoreMutation()") != 1
        or preview_restore.count("endAuthoritativeBoundary(") != 1
    ):
        errors.append("ticket restore must own exactly one balanced broker epoch")

    resumed_startup = declaration_body(
        key_cliff_source,
        "func openAndFinishStartupIncludingKeyCliffRecovery(",
    )
    normalized_resumed_startup = (
        "" if resumed_startup is None else " ".join(resumed_startup.split())
    )
    resumed_startup_boundary = (
        "let quickActionBoundaryEpoch: UInt64? if isResuming { "
        "quickActionBoundaryEpoch = beginAuthoritativeQuickActionBoundary() "
        "} else { quickActionBoundaryEpoch = nil } defer { if let "
        "quickActionBoundaryEpoch { "
        "quickActionRouteBroker.endAuthoritativeBoundary( "
        "quickActionBoundaryEpoch ) } } if isResuming {"
    )
    boundary_begin_offset = (
        -1
        if resumed_startup is None
        else resumed_startup.find(
            "quickActionBoundaryEpoch = beginAuthoritativeQuickActionBoundary()"
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
        resumed_startup.count("beginAuthoritativeQuickActionBoundary()") != 1
        or resumed_startup.count("endAuthoritativeBoundary(") != 1
    ):
        errors.append(
            "resumed startup must own exactly one balanced broker epoch"
        )

    key_cliff_restore = declaration_body(
        key_cliff_source,
        "func recoverMissingDeviceBoundKey(",
    )
    normalized_key_cliff = (
        "" if key_cliff_restore is None else " ".join(key_cliff_restore.split())
    )
    key_cliff_boundary = (
        "try beginLifecycleMutation(invalidatesJournalProjection: false) "
        "isWorking = true isBookReplacementInProgress = true let "
        "quickActionBoundaryEpoch = beginAuthoritativeQuickActionBoundary() "
        "defer { finishBookReplacementMutation() "
        "quickActionRouteBroker.endAuthoritativeBoundary( "
        "quickActionBoundaryEpoch ) } try await requireEmptyLockedCaptureInbox()"
    )
    if key_cliff_restore is None or key_cliff_boundary not in normalized_key_cliff:
        errors.append(
            "missing-key recovery must install balanced broker and "
            "book-replacement cleanup before its first suspension"
        )
    elif (
        key_cliff_restore.count("beginAuthoritativeQuickActionBoundary()") != 1
        or key_cliff_restore.count("endAuthoritativeBoundary(") != 1
    ):
        errors.append(
            "missing-key recovery must own exactly one balanced broker epoch"
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
        capture_digest = hashlib.sha256(capture_path.read_bytes()).hexdigest()
    except OSError as error:
        errors.append(f"cannot read locked-capture store: {error}")
    else:
        if capture_digest != LOCKED_CAPTURE_STORE_SHA256:
            errors.append("LockedCaptureStore.swift changed outside the reviewed W7 scope")
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
            "bounded 16-action process-local FIFO",
            "transient startup work",
            "newest action is rejected",
            "discards the entire in-memory",
            "process-local boundary epoch",
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
        "Validated six exact quick-log routes, bounded in-memory action-only FIFO, "
        "passive budget status, bilingual metadata, and preserved release identity"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
