from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "validate_performance_signposts",
    ROOT / "Scripts/validate_performance_signposts.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load performance-signpost validator")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class PerformanceSignpostsValidatorTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def swift_sources(self) -> dict[str, str]:
        return VALIDATOR.production_swift_sources(ROOT)

    def test_current_repository_passes(self) -> None:
        self.assertEqual(VALIDATOR.validate_repository(ROOT), [])

    def test_rejects_operation_name_or_static_mapping_drift(self) -> None:
        source = self.source("Sources/MoneyUpCore/PerformanceSignposts.swift")
        raw_drift = source.replace(
            'case historyPage = "HistoryPage"',
            'case historyPage = "HistoryPayload"',
            1,
        )
        mapping_drift = source.replace(
            'case .projection: "Projection"',
            'case .projection: "ProjectionDetail"',
            1,
        )

        self.assertTrue(
            any(
                "cases/names drifted" in error
                for error in VALIDATOR.validate_signpost_source(raw_drift)
            )
        )
        self.assertTrue(
            any(
                "mapping drifted" in error
                for error in VALIDATOR.validate_signpost_source(mapping_drift)
            )
        )

    def test_rejects_payload_parameter_or_metadata_interpolation(self) -> None:
        source = self.source("Sources/MoneyUpCore/PerformanceSignposts.swift")
        payload_api = source.replace(
            "        _ operation: MoneyUpPerformanceOperation\n",
            "        _ operation: MoneyUpPerformanceOperation,\n"
            "        payload: String\n",
            1,
        )
        metadata = source.replace(
            "                id: signpostID\n",
            "                id: signpostID,\n"
            '                "amount=\\(amount)"\n',
            1,
        )

        self.assertTrue(
            any(
                "begin API" in error or "missing" in error
                for error in VALIDATOR.validate_signpost_source(payload_api)
            )
        )
        metadata_errors = VALIDATOR.validate_signpost_source(metadata)
        self.assertTrue(any("unreviewed string" in error for error in metadata_errors))
        self.assertTrue(any("forbidden \\(" in error for error in metadata_errors))

    def test_rejects_missing_end_or_extra_call_site(self) -> None:
        sources = self.swift_sources()
        csv_path = "Sources/MoneyUpCore/LedgerCSVExporter.swift"
        sources[csv_path] = sources[csv_path].replace(
            "        defer { MoneyUpPerformanceSignposts.end(performanceInterval) }\n",
            "",
            1,
        )

        missing_end = VALIDATOR.validate_instrumented_sources(sources)

        self.assertTrue(any("end-call ownership drifted" in error for error in missing_end))
        self.assertTrue(any("must end exactly" in error for error in missing_end))

        sources = self.swift_sources()
        history_path = "Sources/MoneyUpCore/HistoryQuery.swift"
        sources[history_path] += (
            "\nlet unsafeInterval = "
            "MoneyUpPerformanceSignposts.begin(.save)\n"
        )

        extra_site = VALIDATOR.validate_instrumented_sources(sources)

        self.assertTrue(any("locations drifted" in error for error in extra_site))

    def test_pins_xcode_compile_boundaries_for_unlock_and_calendar(self) -> None:
        sources = self.swift_sources()
        dependencies_path = "App/MoneyUp/AppModelDependencies.swift"
        sources[dependencies_path] = sources[dependencies_path].replace(
            "return try await Task.detached(priority: .userInitiated)",
            "try await Task.detached(priority: .userInitiated)",
            1,
        )

        unlock_errors = VALIDATOR.validate_journey_boundaries(sources)

        self.assertTrue(
            any(
                "return try await Task.detached" in error
                for error in unlock_errors
            )
        )

        sources = self.swift_sources()
        calendar_path = "App/MoneyUp/CalendarView.swift"
        sources[calendar_path] = sources[calendar_path].replace(
            "            presentedCalendarList\n",
            '            List { Text("calendar.no_actual") }\n',
            1,
        )

        calendar_errors = VALIDATOR.validate_journey_boundaries(sources)

        self.assertTrue(
            any(
                "generic-heavy list and presentation graph" in error
                for error in calendar_errors
            )
        )

    def test_rejects_indirect_wrapper_alias(self) -> None:
        sources = self.swift_sources()
        path = "App/MoneyUp/HistoryView.swift"
        sources[path] += (
            "\nlet unreviewedBegin = MoneyUpPerformanceSignposts.begin\n"
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(
            any("performance-wrapper allowlist drifted" in error for error in errors)
        )

    def test_rejects_new_signposter_in_an_alternate_category(self) -> None:
        sources = self.swift_sources()
        path = "App/MoneyUp/CalendarView.swift"
        sources[path] += (
            "\nlet alternateSignposter = OSSignposter(\n"
            '    subsystem: "com.laiwenkang.MoneyUp",\n'
            '    category: "AlternateTiming"\n'
            ")\n"
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(any("OSSignposter allowlist drifted" in error for error in errors))

    def test_rejects_direct_event_or_alternate_interval_primitive(self) -> None:
        sources = self.swift_sources()
        path = "App/MoneyUp/QuickLogEntryReceipt.swift"
        sources[path] += (
            '\nSelf.receiptSignposter.emitEvent("unreviewed")\n'
            "let unreviewedBegin = Self.receiptSignposter.beginInterval\n"
            "let unreviewedAround = Self.receiptSignposter.withIntervalSignpost\n"
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(any("emitEvent allowlist drifted" in error for error in errors))
        self.assertTrue(any("beginInterval allowlist drifted" in error for error in errors))
        self.assertTrue(
            any("withIntervalSignpost allowlist drifted" in error for error in errors)
        )

    def test_rejects_escaped_event_with_runtime_financial_payload(self) -> None:
        sources = self.swift_sources()
        path = "App/MoneyUp/CalendarView.swift"
        sources[path] += (
            "\nfunc escapedBypass(_ amount: Decimal) {\n"
            "    QuickLogEntryView.receiptSignposter.`emitEvent`(\n"
            '        "Unreviewed", "amount=\\(amount)"\n'
            "    )\n"
            "}\n"
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(any("emitEvent allowlist drifted" in error for error in errors))
        self.assertTrue(
            any("receiptSignposter identifier allowlist drifted" in error for error in errors)
        )

    def test_rejects_escaped_primitive_aliases_and_signposter_alias(self) -> None:
        sources = self.swift_sources()
        receipt_path = "App/MoneyUp/QuickLogEntryReceipt.swift"
        sources[receipt_path] += (
            "\nlet escapedBegin = Self.receiptSignposter.`beginInterval`\n"
            "let escapedEnd = Self.receiptSignposter.`endInterval`\n"
            "let escapedID = Self.receiptSignposter.`makeSignpostID`\n"
            "let signposterAlias = Self.receiptSignposter\n"
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        for primitive in ("beginInterval", "endInterval", "makeSignpostID"):
            self.assertTrue(
                any(f"{primitive} allowlist drifted" in error for error in errors)
            )
        self.assertTrue(
            any("receiptSignposter identifier allowlist drifted" in error for error in errors)
        )

    def test_rejects_count_balanced_receipt_signposter_alias(self) -> None:
        sources = self.swift_sources()
        path = "App/MoneyUp/QuickLogEntryReceipt.swift"
        sources[path] = sources[path].replace(
            "let suggestionsSignpostID = Self.receiptSignposter.makeSignpostID()",
            "let receiptAlias = Self.receiptSignposter\n"
            "        let suggestionsSignpostID = receiptAlias.makeSignpostID()",
            1,
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(
            any("receiptSignposter member allowlist drifted" in error for error in errors)
        )

    def test_string_or_comment_text_cannot_spoof_member_inventory(self) -> None:
        sources = self.swift_sources()
        path = "App/MoneyUp/QuickLogEntryReceipt.swift"
        sources[path] = sources[path].replace(
            "let suggestionsSignpostID = Self.receiptSignposter.makeSignpostID()",
            "let receiptAlias = Self.receiptSignposter\n"
            "        let suggestionsSignpostID = receiptAlias.makeSignpostID()\n"
            '        let spoof = "Self.receiptSignposter.makeSignpostID"\n'
            "        // Self.receiptSignposter.makeSignpostID",
            1,
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(
            any("receiptSignposter member allowlist drifted" in error for error in errors)
        )

    def test_scans_escaped_event_inside_string_interpolation(self) -> None:
        sources = self.swift_sources()
        path = "App/MoneyUp/CalendarView.swift"
        sources[path] += (
            "\nfunc interpolationBypass(_ amount: Decimal) {\n"
            '    _ = "\\(QuickLogEntryView.receiptSignposter.`emitEvent`('
            '"Unreviewed", "amount=\\(amount)"))"\n'
            "}\n"
        )

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(any("emitEvent allowlist drifted" in error for error in errors))
        self.assertTrue(
            any("receiptSignposter member allowlist drifted" in error for error in errors)
        )

    def test_rejects_legacy_c_signpost_bypass(self) -> None:
        sources = self.swift_sources()
        path = "Sources/MoneyUpCore/HistoryQuery.swift"
        sources[path] += "\nos_signpost(.event, log: log, name: name)\n"

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(any("os_signpost allowlist drifted" in error for error in errors))

    def test_rejects_underscored_c_signpost_bypass(self) -> None:
        sources = self.swift_sources()
        path = "Sources/MoneyUpCore/HistoryQuery.swift"
        sources[path] += "\n__os_signpost_emit_with_name_impl(payload)\n"

        errors = VALIDATOR.validate_global_signpost_inventory(sources)

        self.assertTrue(any("os_signpost allowlist drifted" in error for error in errors))

    def test_rejects_receipt_runtime_metadata(self) -> None:
        source = self.source("App/MoneyUp/QuickLogEntryReceipt.swift")
        mutated = source.replace(
            '"outcome=ready"',
            '"outcome=\\(result)"',
            1,
        )

        errors = VALIDATOR.validate_receipt_signpost_boundary(mutated)

        self.assertTrue(any("allowlist drifted" in error for error in errors))
        self.assertTrue(any("interpolate" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
