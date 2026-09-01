#!/usr/bin/env python3
"""Validate MoneyUp's closed, payload-free performance signpost boundary."""

from __future__ import annotations

from collections import Counter
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_OPERATIONS = [
    ("storeOpen", "StoreOpen"),
    ("unlock", "Unlock"),
    ("ledgerLoad", "LedgerLoad"),
    ("save", "Save"),
    ("historyPage", "HistoryPage"),
    ("historyQuery", "HistoryQuery"),
    ("csvExport", "CSVExport"),
    ("xlsxExport", "XLSXExport"),
    ("archiveExport", "ArchiveExport"),
    ("archiveRestore", "ArchiveRestore"),
    ("receiptProcessing", "ReceiptProcessing"),
    ("projection", "Projection"),
    ("deterministicIntelligence", "DeterministicIntelligence"),
    ("unlockToFirstUsefulContent", "UnlockToFirstUsefulContent"),
    ("transactionSaveToPublication", "TransactionSaveToPublication"),
    ("historyQueryToContent", "HistoryQueryToContent"),
    ("historyPageToContent", "HistoryPageToContent"),
    ("calendarDateComputation", "CalendarDateComputation"),
]
LOW_LEVEL_SITE_SPECS = [
    (
        "storeOpen",
        "Sources/MoneyUpPersistence/EncryptedRecordStore.swift",
        "public init(databaseURL: URL, key: Data) throws",
    ),
    (
        "unlock",
        "App/MoneyUp/AppModelDependencies.swift",
        "static let production: DatabaseStoreOpener =",
    ),
    (
        "ledgerLoad",
        "App/MoneyUp/AppModelRecovery.swift",
        "func load(\n        from store: EncryptedRecordStore,",
    ),
    (
        "save",
        "Sources/MoneyUpPersistence/EncryptedRecordStore.swift",
        "public func upsert<Value: Encodable & Sendable>(",
    ),
    (
        "save",
        "Sources/MoneyUpPersistence/EncryptedRecordStore.swift",
        "public func write(\n        _ records: [RecordWrite],",
    ),
    (
        "historyPage",
        "Sources/MoneyUpPersistence/EncryptedRecordStore.swift",
        "public func fetchJournalEntryPage(",
    ),
    (
        "historyQuery",
        "Sources/MoneyUpCore/HistoryQuery.swift",
        "public func filteredEntries(",
    ),
    (
        "csvExport",
        "Sources/MoneyUpCore/LedgerCSVExporter.swift",
        "public static func export(\n        _ entries: [JournalEntry],",
    ),
    (
        "xlsxExport",
        "Sources/MoneyUpCore/LedgerXLSXExporter.swift",
        "public static func export(\n        entries: [JournalEntry],\n"
        "        accounts: [LedgerAccount],\n"
        "        rates: [DatedExchangeRate] = [],\n"
        "        attachmentMetadata:",
    ),
    (
        "archiveExport",
        "Sources/MoneyUpPersistence/EncryptedRecordStoreDiagnostics.swift",
        "public func exportPortableArchive(",
    ),
    (
        "archiveRestore",
        "Sources/MoneyUpPersistence/EncryptedRecordStoreDiagnostics.swift",
        "public func restorePortableArchive(",
    ),
    (
        "receiptProcessing",
        "Sources/MoneyUpCore/ReceiptTextParser.swift",
        "public static func analyze(",
    ),
    (
        "projection",
        "Sources/MoneyUpIntelligence/ProjectionBudgetDetector.swift",
        "public static func project(",
    ),
    (
        "deterministicIntelligence",
        "App/MoneyUp/AppModelServices.swift",
        "nonisolated private static func detectedFindings(",
    ),
]

# These begin sites are intentionally broader than the low-level operation
# boundaries above. Their corresponding ends may cross actor/view boundaries,
# so they have dedicated ownership checks below instead of pretending they are
# ordinary function-scoped `defer` intervals.
JOURNEY_BEGIN_SITES = [
    (
        "unlockToFirstUsefulContent",
        "App/MoneyUp/AppModelDependencies.swift",
    ),
    (
        "transactionSaveToPublication",
        "App/MoneyUp/QuickLogEntryCommit.swift",
    ),
    (
        "historyQueryToContent",
        "App/MoneyUp/HistoryView.swift",
    ),
    (
        "historyPageToContent",
        "App/MoneyUp/HistoryView.swift",
    ),
    (
        "calendarDateComputation",
        "App/MoneyUp/CalendarView.swift",
    ),
]

# Exact wrapper end ownership. Unlock transfers one interval from the detached
# opener to AppModel and therefore has both an opener-failure cleanup and one
# successful-journey owner. Every other journey has one idempotent local owner.
EXPECTED_WRAPPER_END_COUNTS = Counter(
    path for _, path, _ in LOW_LEVEL_SITE_SPECS
)
EXPECTED_WRAPPER_END_COUNTS.update(
    {
        "App/MoneyUp/AppModelDependencies.swift": 1,
        "App/MoneyUp/AppModelPerformance.swift": 1,
        "App/MoneyUp/QuickLogEntryCommit.swift": 1,
        "App/MoneyUp/HistoryView.swift": 2,
        "App/MoneyUp/CalendarView.swift": 1,
    }
)

# Direct OSLog performance primitives predate the centralized wrapper for the
# two fixed-label receipt journeys. This global inventory is deliberately
# closed: a new constructor, interval primitive, event, alias, or wrapper
# reference fails even when it uses another category or an indirect call form.
EXPECTED_PRIMITIVE_OCCURRENCES = {
    "OSSignposter": Counter(
        {
            "App/MoneyUp/QuickLogSheet.swift": 1,
            "Sources/MoneyUpCore/PerformanceSignposts.swift": 1,
        }
    ),
    "beginInterval": Counter(
        {
            "App/MoneyUp/QuickLogEntryReceipt.swift": 2,
            "Sources/MoneyUpCore/PerformanceSignposts.swift": 1,
        }
    ),
    "endInterval": Counter(
        {
            "App/MoneyUp/QuickLogEntryReceipt.swift": 6,
            "Sources/MoneyUpCore/PerformanceSignposts.swift": 4,
        }
    ),
    "emitEvent": Counter(),
    "withIntervalSignpost": Counter(),
    "makeSignpostID": Counter(
        {
            "App/MoneyUp/QuickLogEntryReceipt.swift": 2,
            "Sources/MoneyUpCore/PerformanceSignposts.swift": 1,
        }
    ),
    "os_signpost": Counter(),
}

EXPECTED_SIGNPOSTER_IDENTIFIERS = {
    "receiptSignposter": Counter(
        {
            "App/MoneyUp/QuickLogSheet.swift": 1,
            "App/MoneyUp/QuickLogEntryReceipt.swift": 10,
        }
    ),
    "signposter": Counter(
        {"Sources/MoneyUpCore/PerformanceSignposts.swift": 8}
    ),
}
EXPECTED_SIGNPOSTER_MEMBER_REFERENCES = {
    "receiptSignposter": Counter(
        {
            ("App/MoneyUp/QuickLogEntryReceipt.swift", "makeSignpostID"): 2,
            ("App/MoneyUp/QuickLogEntryReceipt.swift", "beginInterval"): 2,
            ("App/MoneyUp/QuickLogEntryReceipt.swift", "endInterval"): 6,
        }
    ),
    "signposter": Counter(
        {
            ("Sources/MoneyUpCore/PerformanceSignposts.swift", "isEnabled"): 1,
            ("Sources/MoneyUpCore/PerformanceSignposts.swift", "makeSignpostID"): 1,
            ("Sources/MoneyUpCore/PerformanceSignposts.swift", "beginInterval"): 1,
            ("Sources/MoneyUpCore/PerformanceSignposts.swift", "endInterval"): 4,
        }
    ),
}


def declaration_body(source: str, declaration: str) -> str | None:
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


def call_arguments(source: str, callee: str) -> list[str]:
    """Return balanced argument text for every exact reviewed Swift callee."""

    arguments: list[str] = []
    cursor = 0
    while True:
        start = source.find(callee, cursor)
        if start < 0:
            return arguments
        opening = source.find("(", start + len(callee))
        if opening < 0:
            return arguments
        depth = 1
        index = opening + 1
        in_string = False
        escaped = False
        while index < len(source) and depth:
            character = source[index]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
            elif character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            index += 1
        if depth:
            return arguments
        arguments.append(source[opening + 1 : index - 1])
        cursor = index


def normalized_arguments(arguments: str) -> str:
    return re.sub(r"\s+", " ", arguments.strip())


def swift_executable_text(source: str) -> str:
    """Blank Swift comments/string text while retaining interpolation code."""

    output: list[str] = []
    stack: list[tuple[str, int, bool]] = [("code", 0, False)]
    index = 0

    def blank(text: str) -> None:
        output.extend("\n" if character == "\n" else " " for character in text)

    while index < len(source):
        mode, value, is_multiline = stack[-1]
        if mode == "string":
            hashes = value
            quote = '"""' if is_multiline else '"'
            close = quote + ("#" * hashes)
            interpolation = "\\" + ("#" * hashes) + "("
            if source.startswith(interpolation, index):
                blank(interpolation[:-1])
                output.append("(")
                index += len(interpolation)
                stack.append(("code", 1, False))
                continue
            if source.startswith(close, index):
                blank(close)
                index += len(close)
                stack.pop()
                continue
            if hashes == 0 and source[index] == "\\":
                escaped_end = min(index + 2, len(source))
                blank(source[index:escaped_end])
                index = escaped_end
                continue
            blank(source[index])
            index += 1
            continue

        interpolation_depth = value
        if source.startswith("//", index):
            line_end = source.find("\n", index)
            if line_end < 0:
                blank(source[index:])
                break
            blank(source[index:line_end])
            output.append("\n")
            index = line_end + 1
            continue
        if source.startswith("/*", index):
            comment_start = index
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            blank(source[comment_start:index])
            continue

        hash_count = 0
        while index + hash_count < len(source) and source[index + hash_count] == "#":
            hash_count += 1
        quote_index = index + hash_count
        if quote_index < len(source) and source[quote_index] == '"':
            multiline = source.startswith('"""', quote_index)
            delimiter_length = hash_count + (3 if multiline else 1)
            blank(source[index:index + delimiter_length])
            index += delimiter_length
            stack.append(("string", hash_count, multiline))
            continue

        character = source[index]
        output.append(character)
        index += 1
        if interpolation_depth:
            if character == "(":
                stack[-1] = ("code", interpolation_depth + 1, False)
            elif character == ")":
                interpolation_depth -= 1
                if interpolation_depth == 0:
                    stack.pop()
                else:
                    stack[-1] = ("code", interpolation_depth, False)
    return "".join(output)


def normalized_swift_identifiers(source: str) -> str:
    """Make escaped Swift identifiers visible to the closed symbol inventory."""

    return re.sub(
        r"`([A-Za-z_][A-Za-z0-9_]*)`",
        r"\1",
        swift_executable_text(source),
    )


def validate_signpost_source(source: str) -> list[str]:
    errors: list[str] = []
    cases = re.findall(
        r'(?m)^    case ([A-Za-z][A-Za-z0-9]*) = "([^"]+)"$',
        source,
    )
    if cases != EXPECTED_OPERATIONS:
        errors.append(
            "performance operation cases/names drifted: "
            f"expected {EXPECTED_OPERATIONS}, found {cases}"
        )
    mappings = re.findall(
        r'(?m)^        case \.([A-Za-z][A-Za-z0-9]*): "([^"]+)"$',
        source,
    )
    if mappings != EXPECTED_OPERATIONS:
        errors.append(
            "static signpost-name mapping drifted: "
            f"expected {EXPECTED_OPERATIONS}, found {mappings}"
        )
    outcomes = re.findall(
        r"(?m)^    case (success|failure|cancelled)$",
        source,
    )
    if outcomes != ["success", "failure", "cancelled"]:
        errors.append(
            "performance outcome inventory drifted: expected "
            "success/failure/cancelled"
        )

    expected_literals = Counter(
        [name for _, name in EXPECTED_OPERATIONS] * 2
        + [
            "com.laiwenkang.MoneyUp",
            "Performance",
            "outcome=success",
            "outcome=failure",
            "outcome=cancelled",
        ]
    )
    literals = Counter(re.findall(r'"([^"]*)"', source))
    if literals != expected_literals:
        errors.append("performance signpost source contains an unreviewed string literal")

    required = [
        "import OSLog",
        "public enum MoneyUpPerformanceOperation: String, CaseIterable, Sendable",
        "fileprivate var signpostName: StaticString",
        "public struct MoneyUpPerformanceInterval: Sendable",
        "public enum MoneyUpPerformanceOutcome: CaseIterable, Equatable, Sendable",
        "fileprivate let operation: MoneyUpPerformanceOperation",
        "fileprivate let state: OSSignpostIntervalState",
        "subsystem: \"com.laiwenkang.MoneyUp\"",
        "category: \"Performance\"",
        "guard signposter.isEnabled else { return nil }",
        "let signpostID = signposter.makeSignpostID()",
        "operation.signpostName,\n                id: signpostID",
        "signposter.endInterval(interval.operation.signpostName, interval.state)",
    ]
    for declaration in required:
        if declaration not in source:
            errors.append(f"performance signpost source is missing {declaration}")

    begin_declaration = (
        "public static func begin(\n"
        "        _ operation: MoneyUpPerformanceOperation\n"
        "    ) -> MoneyUpPerformanceInterval?"
    )
    end_declaration = (
        "public static func end(_ interval: MoneyUpPerformanceInterval?)"
    )
    outcome_end_declaration = (
        "public static func end(\n"
        "        _ interval: MoneyUpPerformanceInterval?,\n"
        "        outcome: MoneyUpPerformanceOutcome\n"
        "    )"
    )
    begin_body = declaration_body(source, begin_declaration)
    end_body = declaration_body(source, end_declaration)
    outcome_end_body = declaration_body(source, outcome_end_declaration)
    if begin_body is None or begin_body.count("beginInterval(") != 1:
        errors.append("begin API must create exactly one payload-free interval")
    if end_body is None or end_body.count("endInterval(") != 1:
        errors.append("end API must close exactly one payload-free interval")
    if outcome_end_body is None or outcome_end_body.count("endInterval(") != 3:
        errors.append("outcome end API must own exactly three fixed resolutions")
    for outcome in ("success", "failure", "cancelled"):
        expected = f'"outcome={outcome}"'
        if outcome_end_body is None or outcome_end_body.count(expected) != 1:
            errors.append(f"outcome end API is missing fixed {outcome} resolution")

    forbidden = [
        "SignpostMetadata",
        "emitEvent(",
        "Logger(",
        "privacy:",
        "message:",
        "metadata:",
        "#if DEBUG",
        "#if RELEASE",
        "\\(",
    ]
    for symbol in forbidden:
        if symbol in source:
            errors.append(f"performance signpost source contains forbidden {symbol}")
    if source.count("beginInterval(") != 1 or source.count("endInterval(") != 4:
        errors.append("only the centralized wrapper may call OS signpost intervals")
    return errors


def validate_instrumented_sources(sources: dict[str, str]) -> list[str]:
    errors: list[str] = []
    expected_occurrences = Counter(
        (path, operation)
        for operation, path, _ in LOW_LEVEL_SITE_SPECS
    )
    expected_occurrences.update(
        (path, operation) for operation, path in JOURNEY_BEGIN_SITES
    )
    actual_occurrences: Counter[tuple[str, str]] = Counter()
    begin_pattern = re.compile(
        r"MoneyUpPerformanceSignposts\.begin\(\s*\."
        r"([A-Za-z][A-Za-z0-9]*)\s*\)"
    )
    actual_end_counts: Counter[str] = Counter()

    for path, source in sources.items():
        for operation in begin_pattern.findall(source):
            actual_occurrences[(path, operation)] += 1
        actual_end_counts[path] = len(re.findall(
            r"\bMoneyUpPerformanceSignposts\s*\.\s*end\s*\(",
            source,
        ))

    if actual_occurrences != expected_occurrences:
        errors.append(
            "instrumented operation locations drifted: "
            f"expected {expected_occurrences}, found {actual_occurrences}"
        )
    actual_end_counts = +actual_end_counts
    if actual_end_counts != EXPECTED_WRAPPER_END_COUNTS:
        errors.append(
            "centralized end-call ownership drifted: "
            f"expected {EXPECTED_WRAPPER_END_COUNTS}, found {actual_end_counts}"
        )

    for operation, path, anchor in LOW_LEVEL_SITE_SPECS:
        source = sources.get(path)
        if source is None:
            errors.append(f"missing instrumented source {path}")
            continue
        body = declaration_body(source, anchor)
        if body is None:
            errors.append(f"{path} is missing reviewed boundary {anchor}")
            continue
        prefix = re.compile(
            r"^\s*(?:[A-Za-z][A-Za-z0-9]*\s+in\s*)?"
            r"let performanceInterval\s*=\s*"
            r"MoneyUpPerformanceSignposts\.begin\(\s*\."
            + re.escape(operation)
            + r"\s*\)\s*defer\s*\{\s*"
            r"MoneyUpPerformanceSignposts\.end\(performanceInterval\)\s*\}",
            re.DOTALL,
        )
        if prefix.search(body) is None:
            errors.append(
                f"{path}:{anchor} must begin and defer-end only .{operation}"
            )
        expected_body_count = 2 if operation == "unlock" else 1
        if body.count("MoneyUpPerformanceSignposts.begin(") != expected_body_count:
            errors.append(
                f"{path}:{anchor} must begin exactly {expected_body_count} interval(s)"
            )
        if body.count("MoneyUpPerformanceSignposts.end(") != expected_body_count:
            errors.append(
                f"{path}:{anchor} must end exactly {expected_body_count} interval(s)"
            )
    return errors


def validate_global_signpost_inventory(sources: dict[str, str]) -> list[str]:
    """Close every route to an unreviewed signpost or wrapper indirection."""

    errors: list[str] = []
    normalized_sources = {
        path: normalized_swift_identifiers(source)
        for path, source in sources.items()
    }
    patterns = {
        "OSSignposter": re.compile(r"\bOSSignposter\b"),
        "beginInterval": re.compile(r"\.\s*beginInterval\b"),
        "endInterval": re.compile(r"\.\s*endInterval\b"),
        "emitEvent": re.compile(r"\.\s*emitEvent\b"),
        "withIntervalSignpost": re.compile(r"\.\s*withIntervalSignpost\b"),
        "makeSignpostID": re.compile(r"\.\s*makeSignpostID\b"),
        # The legacy C API would bypass both the constructor and Swift-method
        # inventory, so it is explicitly closed as well.
        "os_signpost": re.compile(
            r"\b_*os_signpost(?:_[A-Za-z0-9_]+)?\b"
        ),
    }
    for symbol, pattern in patterns.items():
        actual = +Counter(
            {
                path: len(pattern.findall(source))
                for path, source in normalized_sources.items()
                if pattern.search(source)
            }
        )
        expected = EXPECTED_PRIMITIVE_OCCURRENCES[symbol]
        if actual != expected:
            errors.append(
                f"global {symbol} allowlist drifted: "
                f"expected {expected}, found {actual}"
            )

    expected_wrapper_references = Counter(
        path for _, path, _ in LOW_LEVEL_SITE_SPECS
    )
    expected_wrapper_references.update(path for _, path in JOURNEY_BEGIN_SITES)
    expected_wrapper_references.update(EXPECTED_WRAPPER_END_COUNTS)
    expected_wrapper_references[
        "Sources/MoneyUpCore/PerformanceSignposts.swift"
    ] += 1
    wrapper_pattern = re.compile(r"\bMoneyUpPerformanceSignposts\b")
    actual_wrapper_references = +Counter(
        {
            path: len(wrapper_pattern.findall(source))
            for path, source in normalized_sources.items()
            if wrapper_pattern.search(source)
        }
    )
    if actual_wrapper_references != expected_wrapper_references:
        errors.append(
            "global performance-wrapper allowlist drifted: "
            f"expected {expected_wrapper_references}, "
            f"found {actual_wrapper_references}"
        )

    for identifier, expected in EXPECTED_SIGNPOSTER_IDENTIFIERS.items():
        pattern = re.compile(r"\b" + re.escape(identifier) + r"\b")
        actual = +Counter(
            {
                path: len(pattern.findall(source))
                for path, source in normalized_sources.items()
                if pattern.search(source)
            }
        )
        if actual != expected:
            errors.append(
                f"global {identifier} identifier allowlist drifted: "
                f"expected {expected}, found {actual}"
            )
        member_pattern = re.compile(
            r"\b" + re.escape(identifier)
            + r"\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b"
        )
        actual_members: Counter[tuple[str, str]] = Counter()
        for path, source in normalized_sources.items():
            actual_members.update(
                (path, member) for member in member_pattern.findall(source)
            )
        expected_members = EXPECTED_SIGNPOSTER_MEMBER_REFERENCES[identifier]
        if actual_members != expected_members:
            errors.append(
                f"global {identifier} member allowlist drifted: "
                f"expected {expected_members}, found {actual_members}"
            )

    receipt_owner = sources.get("App/MoneyUp/QuickLogSheet.swift", "")
    expected_receipt_signposter = (
        "static let receiptSignposter = OSSignposter(\n"
        "        subsystem: \"com.laiwenkang.MoneyUp\",\n"
        "        category: \"QuickLogReceipt\"\n"
        "    )"
    )
    if expected_receipt_signposter not in receipt_owner:
        errors.append("reviewed QuickLogReceipt signposter owner drifted")
    return errors


def validate_journey_boundaries(sources: dict[str, str]) -> list[str]:
    """Pin the cross-boundary Golden journeys to truthful publication ends."""

    errors: list[str] = []
    required_by_path = {
        "App/MoneyUp/AppModelDependencies.swift": [
            "return try await Task.detached(priority: .userInitiated)",
            "unlockToFirstUsefulContentInterval: usefulContentInterval",
            "if !transfersUsefulContentInterval",
            "transfersUsefulContentInterval = true",
            "outcome: .failure",
        ],
        "App/MoneyUp/AppModelLifecycle.swift": [
            "adoptUnlockToFirstUsefulContentInterval(",
            "openedDatabase.unlockToFirstUsefulContentInterval",
            "state = .ready",
            "finishUnlockToFirstUsefulContentMeasurement(outcome: .failure)",
            "finishUnlockToFirstUsefulContentMeasurement(outcome: .cancelled)",
        ],
        "App/MoneyUp/AppModelPerformance.swift": [
            "func adoptUnlockToFirstUsefulContentInterval(",
            "outcome: MoneyUpPerformanceOutcome = .cancelled",
            "unlockToFirstUsefulContentInterval = nil",
            "MoneyUpPerformanceSignposts.end(interval, outcome: outcome)",
        ],
        "App/MoneyUp/DashboardContent.swift": [
            "if scenePhase == .active,",
            ".onAppear",
            "model.state == .ready",
            "model.finishUnlockToFirstUsefulContentMeasurement(",
            "outcome: .success",
            "does not claim that Core Animation presented",
        ],
        "App/MoneyUp/QuickLogEntryCommit.swift": [
            "guard !isSaving, canSave else { return }",
            ".transactionSaveToPublication",
            "completeSuccessfulSave(entryID: savedEntryID)",
            "finishPerformanceMeasurement(outcome: .success)",
            "finishPerformanceMeasurement(outcome: .failure)",
            "finishPerformanceMeasurement(outcome: .cancelled)",
            "state-publication/dismissal-request",
        ],
        "App/MoneyUp/HistoryView.swift": [
            "try await Task.sleep(for: .milliseconds(250))",
            "async let pageOutcome = initialPageOutcome(query: querySnapshot)",
            "async let totalsOutcome = summaryOutcome(query: querySnapshot)",
            "loadedEntries = page.entries",
            "summary = resolvedSummary",
            "loadedEntries.append(contentsOf:",
            ".historyQueryToContent",
            ".historyPageToContent",
            "isInitialHistoryLoadInProgress",
            "loadIdentifier: expectedIdentifier",
            "finishInitialHistoryMeasurement(",
            "finishPaginationMeasurement(",
            "state-publication boundary",
        ],
        "App/MoneyUp/CalendarView.swift": [
            "private func computeSelectedDate(",
            ".calendarDateComputation",
            "guard loadRequest == request else { return }",
            "model.scheduledTransactions.filter",
            "FinanceCalculator.dailyFlows(",
            "let dateComputation = currentDateComputation",
            "SwiftUI body reevaluations never create timing samples",
        ],
    }
    for path, declarations in required_by_path.items():
        source = sources.get(path)
        if source is None:
            errors.append(f"missing journey source {path}")
            continue
        for declaration in declarations:
            if declaration not in source:
                errors.append(f"{path} is missing journey boundary {declaration}")

    quick_log = sources.get("App/MoneyUp/QuickLogEntryCommit.swift", "")
    save_guard = quick_log.find("guard !isSaving, canSave else { return }")
    save_begin = quick_log.find(".transactionSaveToPublication")
    save_publish = quick_log.find("completeSuccessfulSave(entryID: savedEntryID)")
    save_finish = quick_log.find(
        "finishPerformanceMeasurement(outcome: .success)",
        save_publish,
    )
    if not (0 <= save_guard < save_begin < save_publish < save_finish):
        errors.append(
            "transaction journey must start after validation and end after "
            "state publication"
        )
    if "Task.yield()" in quick_log:
        errors.append("transaction journey must not claim rendering from Task.yield")

    history = sources.get("App/MoneyUp/HistoryView.swift", "")
    history_page = history.find("loadedEntries = page.entries")
    history_total = history.find("summary = resolvedSummary", history_page)
    history_finish = history.find("performanceOutcome = didFail", history_total)
    history_append = history.find("loadedEntries.append(contentsOf:")
    pagination_finish = history.find("performanceOutcome = .success", history_append)
    if not (0 <= history_page < history_total < history_finish):
        errors.append(
            "History initial journey must publish results and total before ending"
        )
    if not (0 <= history_append < pagination_finish):
        errors.append("History pagination journey must end after appended content")
    if "Task.yield()" in history:
        errors.append("History journeys must not claim rendering from Task.yield")
    initial_guard = history.find("guard !isInitialHistoryLoadInProgress,")
    page_begin = history.find("beginPaginationMeasurement(", initial_guard)
    if not (0 <= initial_guard < page_begin):
        errors.append("History pagination must be blocked by initial completion")

    calendar = sources.get("App/MoneyUp/CalendarView.swift", "")
    calendar_view_body = declaration_body(calendar, "var body: some View")
    if calendar_view_body is None:
        errors.append("Calendar View body is unreadable")
    elif (
        "presentedCalendarList" not in calendar_view_body
        or any(
            construct in calendar_view_body
            for construct in (
                "List {",
                ".toolbar {",
                ".sheet(",
                ".confirmationDialog(",
            )
        )
    ):
        errors.append(
            "Calendar View body must delegate its generic-heavy list and "
            "presentation graph across compiler boundaries"
        )
    compute_body = declaration_body(
        calendar,
        "private func computeSelectedDate(",
    )
    if compute_body is None:
        errors.append("Calendar date-computation boundary is unreadable")
    else:
        if "model.calendarEntries(" in compute_body:
            errors.append("Calendar compute interval must exclude indexed database I/O")
        if compute_body.count("MoneyUpPerformanceSignposts.begin(") != 1:
            errors.append("Calendar compute boundary must begin exactly one interval")
        if compute_body.count("MoneyUpPerformanceSignposts.end(") != 1:
            errors.append("Calendar compute boundary must end exactly one interval")
    return errors


def validate_receipt_signpost_boundary(source: str) -> list[str]:
    errors: list[str] = []
    begin_arguments = Counter(
        normalized_arguments(arguments)
        for arguments in call_arguments(
            source,
            "Self.receiptSignposter.beginInterval",
        )
    )
    expected_begin_arguments = Counter(
        {
            '"Receipt selection to suggestions", id: suggestionsSignpostID': 1,
            '"Receipt sanitization", id: signpostID': 1,
        }
    )
    if begin_arguments != expected_begin_arguments:
        errors.append("existing receipt begin-argument allowlist drifted")

    end_arguments = Counter(
        normalized_arguments(arguments)
        for arguments in call_arguments(
            source,
            "Self.receiptSignposter.endInterval",
        )
    )
    expected_end_arguments = Counter(
        {
            (
                '"Receipt selection to suggestions", suggestionsInterval, '
                '"outcome=incomplete"'
            ): 1,
            (
                '"Receipt selection to suggestions", suggestionsInterval, '
                '"outcome=ready"'
            ): 1,
            (
                '"Receipt selection to suggestions", suggestionsInterval, '
                '"outcome=empty"'
            ): 2,
            (
                '"Receipt selection to suggestions", suggestionsInterval, '
                '"outcome=failed"'
            ): 1,
            '"Receipt sanitization", interval': 1,
        }
    )
    if end_arguments != expected_end_arguments:
        errors.append("existing receipt end-argument allowlist drifted")

    expected_metadata = Counter(
        [
            "outcome=incomplete",
            "outcome=ready",
            "outcome=empty",
            "outcome=empty",
            "outcome=failed",
        ]
    )
    metadata = Counter(re.findall(r'"(outcome=[A-Za-z]+)"', source))
    if metadata != expected_metadata:
        errors.append("existing receipt signpost outcome allowlist drifted")
    if "\\(" in source:
        errors.append("receipt signposts must not interpolate runtime payloads")
    expected_names = Counter(
        {
            "Receipt selection to suggestions": 6,
            "Receipt sanitization": 2,
        }
    )
    names = Counter(re.findall(r'"(Receipt [^"]+)"', source))
    if names != expected_names:
        errors.append("existing receipt signpost-name allowlist drifted")
    return errors


def validate_tests_docs_and_gates(root: Path) -> list[str]:
    errors: list[str] = []
    required_files = {
        "Tests/MoneyUpCoreTests/PerformanceSignpostsTests.swift": [
            "testOperationInventoryUsesStablePayloadFreeNames",
            *[f'"{name}"' for _, name in EXPECTED_OPERATIONS],
        ],
        "docs/PERFORMANCE_SIGNPOSTS.md": [
            "Closed operation map",
            "outcome=success",
            "outcome=failure",
            "outcome=cancelled",
            "SwiftUI `onAppear` proxy",
            "not a pixel-presentation claim",
            "HistoryPageToContent",
            "10,000-entry/20-schedule",
            "physical-device gates remain open",
            "python3 Scripts/validate_performance_signposts.py",
        ],
        "docs/FIRST_TEST.md": ["PERFORMANCE_SIGNPOSTS.md"],
        ".github/workflows/ci.yml": [
            "Tests/PerformanceSignpostsValidatorTests",
            "python3 Scripts/validate_performance_signposts.py",
        ],
        ".github/workflows/testflight.yml": [
            "python3 Scripts/validate_performance_signposts.py"
        ],
        "Scripts/validate_release_assets.py": [
            "validate_performance_signposts.py"
        ],
    }
    for relative, declarations in required_files.items():
        path = root / relative
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"cannot read required signpost gate {relative}: {error}")
            continue
        for declaration in declarations:
            if declaration not in source:
                errors.append(f"{relative} is missing signpost gate {declaration}")
    return errors


def production_swift_sources(root: Path) -> dict[str, str]:
    """Read every non-test Swift file, including any future target root."""

    sources: dict[str, str] = {}
    for path in root.rglob("*.swift"):
        relative_path = path.relative_to(root)
        if relative_path.parts[0] == "Tests":
            continue
        if any(part in {".build", "DerivedData"} for part in relative_path.parts):
            continue
        sources[relative_path.as_posix()] = path.read_text(encoding="utf-8")
    return sources


def validate_repository(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    central = root / "Sources/MoneyUpCore/PerformanceSignposts.swift"
    try:
        errors.extend(validate_signpost_source(central.read_text(encoding="utf-8")))
    except OSError as error:
        errors.append(f"cannot read centralized performance signposts: {error}")

    try:
        sources = production_swift_sources(root)
    except OSError as error:
        errors.append(f"cannot read production Swift source: {error}")
        sources = {}
    errors.extend(validate_instrumented_sources(sources))
    errors.extend(validate_global_signpost_inventory(sources))
    errors.extend(validate_journey_boundaries(sources))
    receipt = sources.get("App/MoneyUp/QuickLogEntryReceipt.swift")
    if receipt is None:
        errors.append("cannot read existing receipt signpost boundary")
    else:
        errors.extend(validate_receipt_signpost_boundary(receipt))

    category_owners = [
        path
        for path, source in sources.items()
        if 'category: "Performance"' in source
    ]
    if category_owners != ["Sources/MoneyUpCore/PerformanceSignposts.swift"]:
        errors.append(
            "Performance OSLog category must have one centralized owner; "
            f"found {category_owners}"
        )
    errors.extend(validate_tests_docs_and_gates(root))
    return errors


def main() -> int:
    errors = validate_repository()
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(
        "Validated 18 static performance names, 19 reviewed begin sites, "
        "20 owned ends, fixed outcomes, and the closed global signpost "
        "primitive/identifier inventory; "
        "physical-device evidence remains required"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
