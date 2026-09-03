from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import validate_architecture_fitness as fitness
import validate_release_assets as release_assets


class ArchitectureFitnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write(self, relative: str, content: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def write_catalog(self, relative: str, keys: list[str]) -> None:
        strings = {}
        for key in keys:
            strings[key] = {
                "localizations": {
                    "en": {
                        "stringUnit": {
                            "state": "translated",
                            "value": f"English {key}",
                        }
                    },
                    "zh-Hans": {
                        "stringUnit": {
                            "state": "translated",
                            "value": f"中文 {key}",
                        }
                    },
                }
            }
        self.write(
            relative,
            json.dumps({"sourceLanguage": "en", "strings": strings}),
        )

    def rules(self, violations: list[fitness.Violation]) -> set[str]:
        return {violation.rule for violation in violations}

    def write_production_w3_fixture(self) -> dict[str, str]:
        repository = SCRIPTS.parent
        relatives = (
            "project.yml",
            "Sources/MoneyUpCore/UserProfile.swift",
            "Sources/MoneyUpCore/NaturalLanguageEntryParser.swift",
            "App/MoneyUp/AppModelLifecycle.swift",
            "App/MoneyUp/MoneyUpAppShortcuts.swift",
            "App/MoneyUp/QuickLogOnDeviceAssistance.swift",
            "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift",
            "App/MoneyUp/QuickLogSheet.swift",
            "App/MoneyUp/QuickLogEntryBody.swift",
            "App/MoneyUp/QuickLogEntryCommit.swift",
            "App/MoneyUp/QuickLogEntryComponents.swift",
            "App/MoneyUp/QuickLogEntryDraft.swift",
            "App/MoneyUp/QuickLogEntryOnDeviceAssistance.swift",
            "App/MoneyUp/QuickLogEntryReceipt.swift",
            "App/MoneyUp/QuickLogEntryReceiptCandidates.swift",
            "App/MoneyUp/QuickLogEntryCaptureSuggestions.swift",
            "App/MoneyUp/QuickLogLaunchMode.swift",
            "App/Shared/MoneyUpQuickAction.swift",
        )
        sources = {
            relative: (repository / relative).read_text(encoding="utf-8")
            for relative in relatives
        }
        for relative, source in sources.items():
            self.write(relative, source)
        return sources

    def test_core_imports_allow_only_reviewed_sha256_seam(self) -> None:
        self.write(
            "Sources/MoneyUpCore/TransactionCSVRowParser.swift",
            """\
import struct CryptoKit.SHA256
import Foundation

func fingerprint(_ data: Data) {
    _ = SHA256.hash(data: data)
}
""",
        )
        self.assertEqual(fitness.validate_core_imports(self.root), [])

        self.write(
            "Sources/MoneyUpCore/TransactionCSVRowParser.swift",
            "import CryptoKit\nimport Foundation\nlet digest = SHA256.hash(data: Data())\n",
        )
        violations = fitness.validate_core_imports(self.root)
        self.assertTrue(
            any(
                "selective import" in violation.detail
                for violation in violations
                if violation.rule == "core-cryptokit"
            )
        )

        self.write(
            "Sources/MoneyUpCore/Unreviewed.swift",
            "import CryptoKit\n",
        )
        violations = fitness.validate_core_imports(self.root)
        self.assertTrue(
            any(
                violation.path.endswith("Unreviewed.swift")
                and violation.rule == "core-cryptokit"
                for violation in violations
            )
        )

    def test_core_imports_allow_oslog_only_at_reviewed_signpost_seam(self) -> None:
        self.write(
            "Sources/MoneyUpCore/PerformanceSignposts.swift",
            "import OSLog\nimport Foundation\n",
        )
        self.assertEqual(fitness.validate_core_imports(self.root), [])

        self.write(
            "Sources/MoneyUpCore/UnreviewedSignposter.swift",
            "import OSLog\n",
        )
        violations = fitness.validate_core_imports(self.root)
        self.assertTrue(
            any(
                violation.path.endswith("UnreviewedSignposter.swift")
                and violation.rule == "core-import"
                for violation in violations
            )
        )

        self.write(
            "Sources/MoneyUpCore/PerformanceSignposts.swift",
            "import OSLog\nimport Network\n",
        )
        violations = fitness.validate_core_imports(self.root)
        self.assertTrue(
            any(
                violation.path.endswith("PerformanceSignposts.swift")
                and violation.rule == "core-import"
                and "Network" in violation.detail
                for violation in violations
            )
        )

        for broadened_import in (
            "public import OSLog\n",
            "@_exported import OSLog\n",
            "import OSLog\nimport OSLog\n",
        ):
            self.write(
                "Sources/MoneyUpCore/PerformanceSignposts.swift",
                broadened_import,
            )
            violations = fitness.validate_core_imports(self.root)
            self.assertTrue(
                any(
                    violation.path.endswith("PerformanceSignposts.swift")
                    and violation.rule == "core-oslog"
                    and "non-exported import" in violation.detail
                    for violation in violations
                )
            )

    def test_import_scanner_recognizes_swift_6_access_modifiers(self) -> None:
        scan = fitness.scan_swift(
            "public import Foundation\n"
            "internal import struct CryptoKit.SHA256\n"
            "package import FoundationModels\n"
            "import `Network`\n"
        )
        self.assertEqual(
            [module for module, _ in fitness.import_modules(scan)],
            ["Foundation", "CryptoKit", "FoundationModels", "Network"],
        )
        self.write(
            "App/MoneyUp/Future.swift",
            "package import FoundationModels\npackage struct LocalHelper {}\n",
        )
        rules = self.rules(fitness.validate_w3_foundation_models(self.root))
        self.assertIn("w3-compile-gate", rules)
        self.assertNotIn("w3-forbidden-api", rules)

        self.write(
            "App/MoneyUp/EscapedNetwork.swift",
            "import `Network`\n",
        )
        self.assertIn(
            "offline-boundary",
            self.rules(fitness.validate_offline_boundary(self.root)),
        )

    def test_xctest_inventory_counts_only_runnable_case_methods(self) -> None:
        source = """\
import XCTest

final class InventoryTests: XCTestCase {
    func testRunnable() {}
    @MainActor func testActorIsolatedRunnable() {}
    private func testPrivateHelper() {}

    private struct NestedHelper {
        func testNestedHelper() {}
    }
}

extension InventoryTests {
    func testExtensionRunnable() {}
}

func testGlobalHelper() {}
"""
        self.assertEqual(
            release_assets.xctest_method_names(source),
            (
                "testRunnable",
                "testActorIsolatedRunnable",
                "testExtensionRunnable",
            ),
        )

    def test_view_factory_check_is_scoped_to_view_declarations(self) -> None:
        self.write(
            "App/MoneyUp/ReviewView.swift",
            """\
import SwiftUI

struct ReviewView: View {
    var body: some View { Text("review.title") }
}

extension ReviewView {
    func forbidden() {
        _ = TransactionFactory.expense()
    }
}

final class AppModelHelper {
    func allowed() {
        _ = TransactionFactory.expense()
        let example = "TransactionFactory.expense()"
        // TransactionFactory.expense()
    }
}
""",
        )
        violations = fitness.validate_view_posting_boundary(self.root)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "view-posting")
        self.assertEqual(violations[0].line, 9)

    def test_view_factory_follows_protocol_and_generic_conformance(self) -> None:
        self.write(
            "App/MoneyUp/TransitiveView.swift",
            """\
import SwiftUI

protocol MoneyUpView: View {}
protocol MoneyUpService {}

struct ReviewView: MoneyUpView {
    func forbidden() { _ = TransactionFactory.expense() }
}

struct GenericView<Content: View>: View {
    func forbidden() { _ = TransactionFactory.income() }
}

struct GenericHelper<Content> where Content: View {
    func allowed() { _ = TransactionFactory.refund() }
}

extension SwiftUI.View {
    func forbiddenFactory() { _ = TransactionFactory.expense() }
}

struct PostingHelper: MoneyUpService {
    func allowed() { _ = TransactionFactory.transfer() }
}
""",
        )
        violations = fitness.validate_view_posting_boundary(self.root)
        self.assertEqual(len(violations), 3)
        self.assertEqual(
            {"ReviewView", "GenericView", "SwiftUI.View"},
            {
                violation.detail.split("SwiftUI view ", 1)[1].split()[0]
                for violation in violations
            },
        )

    def test_undeclared_colorset_fails_closed(self) -> None:
        self.write(
            "App/MoneyUp/Assets.xcassets/Surprise.colorset/Contents.json",
            "{}",
        )
        violations = fitness.validate_colorsets(self.root)
        self.assertTrue(
            any(
                violation.path.endswith("Surprise.colorset")
                and violation.rule == "colorset-registry"
                for violation in violations
            )
        )

    def test_colorset_schema_requires_exact_normal_and_high_contrast_slots(self) -> None:
        def color(red: str, green: str, blue: str, appearances=None) -> dict:
            item = {
                "color": {
                    "color-space": "srgb",
                    "components": {
                        "alpha": "1.000",
                        "red": red,
                        "green": green,
                        "blue": blue,
                    },
                },
                "idiom": "universal",
            }
            if appearances is not None:
                item["appearances"] = appearances
            return item

        dark = [{"appearance": "luminosity", "value": "dark"}]
        high = [{"appearance": "contrast", "value": "high"}]
        dark_high = dark + high
        payload = {
            "colors": [
                color("0x34", "0x78", "0x5F"),
                color("0x82", "0xCE", "0xAE", dark),
                color("0x1F", "0x60", "0x47", high),
                color("0xA4", "0xE7", "0xCA", dark_high),
            ]
        }
        self.assertEqual(
            fitness._colorset_values(payload),
            ("#34785F", "#82CEAE", "#1F6047", "#A4E7CA"),
        )

        payload["colors"][3]["appearances"] = list(reversed(dark_high))
        with self.assertRaisesRegex(ValueError, "only universal"):
            fitness._colorset_values(payload)

    def test_reviewed_colorset_registry_is_exactly_semantic_and_chart_tokens(self) -> None:
        names = {Path(path).stem for path in fitness.REVIEWED_COLORSETS}
        self.assertEqual(
            names,
            {
                "AccentColor",
                "BrandAction",
                "BrandBackground",
                "BrandMist",
                "BrandSurface",
                "BrandSurfaceElevated",
                "ChartSeries1",
                "ChartSeries2",
                "ChartSeries3",
                "ChartSeries4",
                "ChartSeries5",
                "ChartSeries6",
            },
        )
        self.assertTrue(all(len(values) == 4 for values in fitness.REVIEWED_COLORSETS.values()))

    def test_fixed_route_exceptions_live_only_at_shared_action_seam(self) -> None:
        route_exceptions = [
            exception
            for exception in fitness.SAFE_EXCEPTIONS
            if exception.reason == "the fixed MoneyUp deep link is a valid URL"
        ]
        self.assertEqual(len(route_exceptions), 6)
        self.assertEqual(
            {exception.path for exception in route_exceptions},
            {"App/Shared/MoneyUpQuickAction.swift"},
        )
        self.assertEqual(
            {exception.snippet for exception in route_exceptions},
            {
                'URL(string: "moneyup://quick-log/expense")!',
                'URL(string: "moneyup://quick-log/income")!',
                'URL(string: "moneyup://quick-log/transfer")!',
                'URL(string: "moneyup://quick-log/refund")!',
                'URL(string: "moneyup://quick-log/smart-entry")!',
                'URL(string: "moneyup://quick-log/scan-receipt")!',
            },
        )

    def test_static_localization_finds_keys_but_not_system_images(self) -> None:
        self.write_catalog(
            "App/MoneyUp/Resources/Localizable.xcstrings",
            ["present.title"],
        )
        self.write_catalog("App/MoneyUpWidget/Localizable.xcstrings", [])
        self.write(
            "App/MoneyUp/LocalizedView.swift",
            """\
import SwiftUI

struct LocalizedView: View {
    var title: LocalizedStringKey { "present.title" }
    var body: some View {
        Label("missing.title", systemImage: "checkmark.circle.fill")
    }
    func row(_ key: LocalizedStringKey) -> some View {
        Label(key, systemImage: "circle.dashed")
    }
}
""",
        )
        violations = fitness.validate_static_localizations(self.root)
        missing = [
            violation
            for violation in violations
            if violation.rule == "localization-key"
        ]
        self.assertEqual([violation.detail for violation in missing], [
            "static user-visible key 'missing.title' is missing from "
            "App/MoneyUp/Resources/Localizable.xcstrings"
        ])

    def test_catalog_requires_both_translated_languages(self) -> None:
        payload = {
            "sourceLanguage": "en",
            "strings": {
                "visible.title": {
                    "localizations": {
                        "en": {
                            "stringUnit": {
                                "state": "translated",
                                "value": "Visible",
                            }
                        }
                    }
                }
            },
        }
        self.write(
            "App/MoneyUp/Resources/Localizable.xcstrings",
            json.dumps(payload),
        )
        self.write_catalog("App/MoneyUpWidget/Localizable.xcstrings", [])
        violations = fitness.validate_static_localizations(self.root)
        self.assertIn("localization-bilingual", self.rules(violations))

    def test_localization_scans_typed_arrays_and_dictionary_sides(self) -> None:
        self.write_catalog(
            "App/MoneyUp/Resources/Localizable.xcstrings",
            ["present.title"],
        )
        self.write_catalog("App/MoneyUpWidget/Localizable.xcstrings", [])
        self.write(
            "App/MoneyUp/TypedKeys.swift",
            """\
import SwiftUI

enum TypedKeys {
    static let array: [LocalizedStringKey] = [
        "present.title", "missing.array"
    ]
    static let values: [String: LocalizedStringKey] = [
        "not.visible.dictionary_key": "missing.value"
    ]
    static let keys: [LocalizedStringKey: String] = [
        "missing.key": "not.visible.dictionary_value"
    ]
    static let plain: [String] = ["not.visible.plain_string"]
}
""",
        )
        violations = fitness.validate_static_localizations(self.root)
        details = {
            violation.detail
            for violation in violations
            if violation.rule == "localization-key"
        }
        self.assertTrue(any("missing.array" in detail for detail in details))
        self.assertTrue(any("missing.value" in detail for detail in details))
        self.assertTrue(any("missing.key" in detail for detail in details))
        self.assertFalse(any("not.visible" in detail for detail in details))

    def test_shared_localization_keys_require_app_and_widget_parity(self) -> None:
        self.write_catalog(
            "App/MoneyUp/Resources/Localizable.xcstrings",
            ["shared.title"],
        )
        self.write_catalog("App/MoneyUpWidget/Localizable.xcstrings", [])
        self.write(
            "App/Shared/SharedTitle.swift",
            'let title: LocalizedStringKey = "shared.title"\n',
        )
        violations = fitness.validate_static_localizations(self.root)
        missing = [
            violation.detail
            for violation in violations
            if violation.rule == "localization-key"
        ]
        self.assertEqual(len(missing), 1)
        self.assertIn("App/MoneyUpWidget/Localizable.xcstrings", missing[0])

    def test_offline_scan_ignores_comments_and_strings(self) -> None:
        self.write(
            "App/MoneyUp/Safe.swift",
            """\
import Foundation
// URLSession.shared
let example = "NWConnection"
""",
        )
        self.assertEqual(fitness.validate_offline_boundary(self.root), [])

        self.write(
            "Sources/MoneyUpCore/Online.swift",
            "import Network\nlet connection: NWConnection?\n"
            "let configuration: URLSessionConfiguration?\n",
        )
        violations = fitness.validate_offline_boundary(self.root)
        self.assertEqual(self.rules(violations), {"offline-boundary"})

    def test_offline_boundary_blocks_url_loads_legacy_and_raw_sockets(self) -> None:
        self.write(
            "App/MoneyUp/LocalRead.swift",
            """\
import Foundation
let fileURL = URL(fileURLWithPath: "/tmp/moneyup")
let localData = try Data(contentsOf: fileURL)
let localText = try String(contentsOf: URL(fileURLWithPath: "/tmp/text"))
""",
        )
        self.assertEqual(
            fitness.validate_offline_boundary(
                self.root, local_load_exceptions=()
            ),
            [],
        )
        self.write(
            "App/MoneyUp/RemoteRead.swift",
            """\
import Darwin
import Foundation
let remoteURL = URL(string: "https://example.invalid/data")!
let remoteData = try Data(contentsOf: remoteURL)
let remoteText = try String(contentsOf: endpoint)
let legacy = NSURLConnection()
let descriptor = socket(AF_INET, SOCK_STREAM, 0)
_ = Darwin.connect(descriptor, nil, 0)
""",
        )
        violations = fitness.validate_offline_boundary(
            self.root, local_load_exceptions=()
        )
        self.assertEqual(
            sum(violation.rule == "offline-url-load" for violation in violations),
            2,
        )
        self.assertIn("offline-boundary", self.rules(violations))

    def test_recovery_manifest_local_load_exception_is_exactly_counted(self) -> None:
        path = "App/MoneyUp/KeyCliffRecoveryTransaction.swift"
        snippet = "Data(contentsOf: manifestURL(for: databaseURL))"
        self.write(
            path,
            "import Foundation\n"
            "func load(_ databaseURL: URL) throws {\n"
            f"    _ = try {snippet}\n"
            "}\n",
        )

        self.assertEqual(fitness.validate_offline_boundary(self.root), [])

        self.write(
            path,
            "import Foundation\n"
            "func load(_ databaseURL: URL) throws {\n"
            f"    _ = try {snippet}\n"
            f"    _ = try {snippet}\n"
            "}\n",
        )
        violations = fitness.validate_offline_boundary(self.root)

        self.assertTrue(
            any(violation.rule == "offline-local-load" for violation in violations)
        )

    def test_interpolation_code_remains_visible_to_safety_boundaries(self) -> None:
        self.write(
            "App/MoneyUp/Interpolation.swift",
            r'''func inspect(_ value: Int?) throws {
    let plain = "print(value!) URLSession.shared"
    let forced = "\(try! risky()) \(value!)"
    let nested = "\("inner \(print(value))")"
    let online = "\(URLSession.shared)"
}
''',
        )
        unsafe = fitness.validate_unsafe_swift(self.root, exceptions=())
        self.assertEqual(self.rules(unsafe), {"try-force", "force-unwrap", "print"})
        offline = fitness.validate_offline_boundary(
            self.root, local_load_exceptions=()
        )
        self.assertEqual(self.rules(offline), {"offline-boundary"})

    def test_unsafe_scan_distinguishes_negation_from_force_operators(self) -> None:
        self.write(
            "App/MoneyUp/Safety.swift",
            """\
func safe(_ value: Bool) throws {
    guard !value else { return }
    _ = try !predicate()
    let example = "print(value!)"
    // try! risky()
}

func unsafe(_ value: Int?) {
    _ = value!
    _ = try! risky()
    print(value)
}
""",
        )
        violations = fitness.validate_unsafe_swift(self.root, exceptions=())
        self.assertEqual(
            [violation.rule for violation in violations],
            ["try-force", "print", "force-unwrap"],
        )

    def test_w3_rules_are_dormant_without_foundationmodels_import(self) -> None:
        self.write(
            "App/MoneyUp/Future.swift",
            """\
@Generable
struct UnsafeFutureOutput {
    var amount: Decimal
    var narrative: String
}
""",
        )
        self.assertEqual(fitness.validate_w3_foundation_models(self.root), [])

    def test_w3_trigger_scans_generable_types_in_other_files(self) -> None:
        self.write(
            "App/MoneyUp/LocalModel.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
func modelIsAvailable() -> Bool {
    SystemLanguageModel.default.availability == .available
}
#endif
""",
        )
        self.write(
            "Sources/MoneyUpCore/GeneratedShape.swift",
            """\
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedShape {
    @Guide(.range(0...4))
    var balanceOrdinal: Int
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-sensitive-output", self.rules(violations))
        self.assertNotIn("w3-compile-gate", self.rules(violations))

    def test_w3_accepts_only_bounded_ordinals_and_fixed_enums(self) -> None:
        self.write(
            "App/MoneyUp/LocalIntelligence.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

struct PromptTemplate {
    let text: String
    let amountDescription: String
}

@Generable
@available(iOS 26.0, *)
enum TemplateID {
    case calmSummary
    case nextStep
}

@available(iOS 26.0, *)
@Generable
struct Selection {
    @Guide(.range(0...3))
    var templateOrdinal: Int
    @Guide(description: "Fixed local choice", .range(1...10))
    var choiceOrdinal: Int
    @Guide(
        description: "Another fixed local choice",
        .range(0...14)
    )
    var rankOrdinal: Int
    var template: TemplateID
}

@available(iOS 26.0, *)
func classify(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(
        to: "Choose a local template",
        generating: Selection.self
    )
}
#endif
""",
        )
        self.assertEqual(fitness.validate_w3_foundation_models(self.root), [])

    def test_w3_requires_compile_and_runtime_lexical_containment(self) -> None:
        self.write(
            "App/MoneyUp/MisplacedModel.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26.0, *)
@Generable
struct Selection {
    @Guide(.range(0...3)) var templateOrdinal: Int
}

#if canImport(FoundationModels)
func classify(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Choose", generating: Selection.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-compile-gate", self.rules(violations))
        self.assertIn("w3-runtime-gate", self.rules(violations))

    def test_w3_can_import_condition_may_not_use_or_fallback(self) -> None:
        self.write(
            "App/MoneyUp/DebugFallback.swift",
            """\
#if canImport(FoundationModels) || DEBUG
import FoundationModels

@available(iOS 26.0, *)
@Generable
enum TemplateID { case fixed }

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Choose", generating: TemplateID.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-compile-gate", self.rules(violations))

    def test_w3_each_response_requires_a_dominating_availability_guard(self) -> None:
        self.write(
            "App/MoneyUp/PartiallyGuarded.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
enum TemplateID { case fixed }

@available(iOS 26.0, *)
func guarded(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Guarded", generating: TemplateID.self)
}

@available(iOS 26.0, *)
func unguarded(session: LanguageModelSession) async throws {
    _ = try await session.respond(to: "Unguarded", generating: TemplateID.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        availability = [
            violation
            for violation in violations
            if violation.rule == "w3-availability"
        ]
        self.assertEqual(len(availability), 1)
        self.assertEqual(availability[0].line, 16)

    def test_w3_availability_predicate_must_be_a_positive_conjunct(self) -> None:
        self.write(
            "App/MoneyUp/InvertedAvailability.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
enum TemplateID { case fixed }

@available(iOS 26.0, *)
func guarded(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Guarded", generating: TemplateID.self)
}

@available(iOS 26.0, *)
func negated(session: LanguageModelSession) async throws {
    if !(SystemLanguageModel.default.availability == .available) {
        _ = try await session.respond(to: "Negated", generating: TemplateID.self)
    }
}

@available(iOS 26.0, *)
func inverted(session: LanguageModelSession) async throws {
    if invert(SystemLanguageModel.default.availability == .available) {
        _ = try await session.respond(to: "Inverted", generating: TemplateID.self)
    }
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        availability = [
            violation
            for violation in violations
            if violation.rule == "w3-availability"
        ]
        self.assertEqual(len(availability), 2)

    def test_w3_rejects_same_line_financial_guide_bypass(self) -> None:
        self.write(
            "App/MoneyUp/GuidedLeak.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct GuidedLeak {
    @Guide(.range(0...4)) var amount: Decimal
}

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Choose", generating: GuidedLeak.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-sensitive-output", self.rules(violations))

    def test_w3_property_parser_handles_accessors_backticks_and_continuation(self) -> None:
        self.write(
            "App/MoneyUp/AccessorLeak.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct AccessorLeak {
    public private(set) var `value`:
        Decimal
}

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Choose", generating: AccessorLeak.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertTrue(
            any(
                violation.rule == "w3-sensitive-output"
                and "Decimal" in violation.detail
                for violation in violations
            )
        )

    def test_w3_int_guides_require_small_literal_closed_ranges(self) -> None:
        self.write(
            "App/MoneyUp/DynamicGuides.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct DynamicSelection {
    @Guide(.range(Int.min...Int.max)) var templateOrdinal: Int
    @Guide(.range(lower...upper)) var choiceOrdinal: Int
    @Guide(.range(0...16)) var rankOrdinal: Int
}

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Choose", generating: DynamicSelection.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        bounded = [
            violation
            for violation in violations
            if violation.rule == "w3-output-shape"
            and "0...15" in violation.detail
        ]
        self.assertEqual(len(bounded), 3)

    def test_w3_rejects_customized_sessions_even_without_tools(self) -> None:
        self.write(
            "App/MoneyUp/CustomizedSession.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct LocalChoice {
    @Guide(.range(0...15)) var choiceOrdinal: Int
}

@available(iOS 26.0, *)
func run() async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    let session = LanguageModelSession(instructions: "Choose")
    _ = try await session.respond(
        to: "Choose",
        generating: LocalChoice.self
    )
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-forbidden-api", self.rules(violations))

    def test_w3_rejects_image_receipt_and_byte_boundary_identifiers(self) -> None:
        self.write(
            "App/MoneyUp/LeakingInputs.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct LocalChoice {
    @Guide(.range(0...15)) var choiceOrdinal: Int
}

@available(iOS 26.0, *)
func run(receiptBytes: Data) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    let session = LanguageModelSession()
    _ = try await session.respond(
        to: "Choose",
        generating: LocalChoice.self
    )
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        forbidden = [
            violation for violation in violations
            if violation.rule == "w3-forbidden-api"
        ]
        self.assertTrue(any("receiptBytes" in item.detail for item in forbidden))
        self.assertTrue(any("Data" in item.detail for item in forbidden))

    def test_w3_rejects_financial_and_arbitrary_string_output(self) -> None:
        self.write(
            "App/MoneyUp/UnsafeIntelligence.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct LeakingOutput {
    var amount: Decimal
    var narrative: String
}

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Write anything")
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-sensitive-output", self.rules(violations))
        self.assertIn("w3-string-output", self.rules(violations))
        self.assertIn("w3-output-shape", self.rules(violations))

    def test_w3_rejects_associated_enum_output(self) -> None:
        self.write(
            "App/MoneyUp/AssociatedOutput.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
enum TemplateID {
    case fixed
    case arbitrary(String)
}

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Choose", generating: TemplateID.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-output-shape", self.rules(violations))

    def test_w3_rejects_indirect_associated_enum_output(self) -> None:
        self.write(
            "App/MoneyUp/IndirectAssociatedOutput.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
enum TemplateID {
    case fixed
    indirect case arbitrary(String)
}

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = try await session.respond(to: "Choose", generating: TemplateID.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertTrue(
            any(
                violation.rule == "w3-output-shape"
                and "associated values" in violation.detail
                for violation in violations
            )
        )

    def test_w3_forbidden_api_names_are_component_and_namespace_aware(self) -> None:
        self.write(
            "App/MoneyUp/ForbiddenAPIs.swift",
            """\
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
enum TemplateID { case fixed }

@available(iOS 26.0, *)
func run(session: LanguageModelSession) async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    _ = Tool.self
    _ = ToolChoice.self
    _ = ProviderClient.self
    _ = PackageID.self
    _ = PCCClient.self
    _ = ServerModelClient.self
    _ = FoundationModels.Tool.self
    let specialized: SystemLanguageModel = .init(useCase: .contentTagging)
    _ = LanguageModelSession(model: specialized)
    _ = Toolbox.self
    _ = Tooling.self
    _ = PackagedValue.self
    _ = Adaptation.self
    _ = try await session.respond(to: "Choose", generating: TemplateID.self)
}
#endif
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        forbidden = {
            violation.detail.rsplit(" ", 1)[-1]
            for violation in violations
            if violation.rule == "w3-forbidden-api"
        }
        self.assertTrue(
            {"Tool", "ToolChoice", "ProviderClient", "PackageID", "PCCClient",
             "ServerModelClient"}
            <= forbidden
        )
        self.assertTrue(
            any(
                "useCase" in violation.detail
                for violation in violations
                if violation.rule == "w3-forbidden-api"
            )
        )
        self.assertTrue(
            {"Toolbox", "Tooling", "PackagedValue", "Adaptation"}.isdisjoint(
                forbidden
            )
        )

    def test_w3_requires_gates_and_rejects_provider_apis(self) -> None:
        self.write(
            "App/MoneyUp/UnguardedIntelligence.swift",
            """\
import FoundationModels

func run() {
    let availability = SystemLanguageModel.default.availability
    let provider = RemoteModelProvider()
    let specialized = SystemLanguageModel(useCase: .contentTagging)
}
""",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-availability", self.rules(violations))
        self.assertIn("w3-compile-gate", self.rules(violations))
        self.assertIn("w3-runtime-gate", self.rules(violations))
        self.assertIn("w3-forbidden-api", self.rules(violations))

    def test_w3_reviewed_input_seam_rejects_raw_and_extra_model_inputs(self) -> None:
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        model_relative = "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift"
        sources = self.write_production_w3_fixture()
        request_source = sources[request_relative]
        model_source = sources[model_relative]

        def reset_sources() -> None:
            for relative, source in sources.items():
                self.write(relative, source)

        reset_sources()
        baseline = fitness.validate_w3_foundation_models(self.root)
        self.assertNotIn("w3-input-boundary", self.rules(baseline))

        raw_model_inputs = (
            "rawOCR",
            "money.description",
            "date.description",
            "accountID.uuidString",
            '"arbitrary text"',
        )
        for expression in raw_model_inputs:
            with self.subTest(expression=expression):
                reset_sources()
                mutated = model_source.replace(
                    "to: reviewedPrompt,",
                    f"to: {expression},",
                    1,
                )
                self.assertNotEqual(mutated, model_source)
                self.write(model_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))

        mutations = (
            (
                model_relative,
                model_source.replace(
                    "request: QuickLogOrdinalRequest",
                    "rawOCR: String",
                    1,
                ),
            ),
            (
                request_relative,
                request_source.replace(
                    "request: request\n            )",
                    "request: arbitraryRequest\n            )",
                    1,
                ),
            ),
            (
                request_relative,
                request_source.replace(
                    "context: context,\n            firstChoices: firstChoices,",
                    "context: rawContext,\n            firstChoices: firstChoices,",
                    1,
                ),
            ),
            (
                model_relative,
                model_source.replace(
                    "for: request\n        ) else",
                    "for: receiptRequest\n        ) else",
                    1,
                ),
            ),
            (
                model_relative,
                model_source.replace(
                    "let response = try await session.respond(",
                    "_ = try await session.respond(\n"
                    "            to: reviewedPrompt,\n"
                    "            generating: LocalOrdinalSelection.self\n"
                    "        )\n"
                    "        let response = try await session.respond(",
                    1,
                ),
            ),
            (
                request_relative,
                request_source.replace(
                    '        let prompt = """',
                    "        let ambient = UIPasteboard.general.string ?? \"\"\n"
                    '        let prompt = """',
                    1,
                ),
            ),
            (
                request_relative,
                request_source.replace(
                    '        let prompt = """',
                    "        let ambient = UserDefaults.standard.string(\n"
                    "            forKey: \"model-input\"\n"
                    "        ) ?? \"\"\n"
                    '        let prompt = """',
                    1,
                ),
            ),
        )
        for relative, mutated in mutations:
            with self.subTest(relative=relative, mutation=hash(mutated)):
                reset_sources()
                original = request_source if relative == request_relative else model_source
                self.assertNotEqual(mutated, original)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))

    def test_w3_production_sentinel_requires_canonical_files_and_types(self) -> None:
        repository = SCRIPTS.parent
        sentinel_relative = "Sources/MoneyUpCore/UserProfile.swift"
        sentinel_source = (repository / sentinel_relative).read_text(encoding="utf-8")
        self.write(sentinel_relative, sentinel_source)
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-input-boundary", self.rules(violations))

        sources = self.write_production_w3_fixture()
        self.assertEqual(fitness.validate_w3_foundation_models(self.root), [])
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        model_relative = "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift"

        def reset_sources() -> None:
            for relative, source in sources.items():
                self.write(relative, source)
            for relative in (
                "App/MoneyUp/RenamedRequest.swift",
                "App/MoneyUp/RenamedModel.swift",
            ):
                path = self.root / relative
                if path.exists():
                    path.unlink()

        def assert_rejected() -> None:
            violations = fitness.validate_w3_foundation_models(self.root)
            self.assertIn("w3-input-boundary", self.rules(violations))

        reset_sources()
        (self.root / model_relative).unlink()
        assert_rejected()

        reset_sources()
        (self.root / request_relative).unlink()
        assert_rejected()

        reset_sources()
        (self.root / model_relative).rename(
            self.root / "App/MoneyUp/RenamedModel.swift"
        )
        assert_rejected()

        reset_sources()
        (self.root / request_relative).rename(
            self.root / "App/MoneyUp/RenamedRequest.swift"
        )
        assert_rejected()

        for original, replacement in (
            ("QuickLogOnDeviceOrdinalModel", "RenamedOrdinalModel"),
            ("LocalOrdinalSelection", "RenamedOrdinalSelection"),
        ):
            with self.subTest(original=original):
                reset_sources()
                mutated = sources[model_relative].replace(original, replacement)
                self.assertNotEqual(mutated, sources[model_relative])
                self.write(model_relative, mutated)
                assert_rejected()

        reset_sources()
        self.write(
            model_relative,
            sources[model_relative].replace("import FoundationModels", "", 1),
        )
        assert_rejected()

        reset_sources()
        self.write(
            sentinel_relative,
            sources[sentinel_relative].replace(
                "foundationModelAssistanceEnabled",
                "renamedModelAssistanceEnabled",
            ),
        )
        assert_rejected()

        reset_sources()
        self.write(
            "project.yml",
            sources["project.yml"].replace("name: MoneyUp", "name: Renamed", 1),
        )
        self.write(
            sentinel_relative,
            sources[sentinel_relative].replace(
                "foundationModelAssistanceEnabled",
                "renamedModelAssistanceEnabled",
            ),
        )
        assert_rejected()

    def test_w3_production_limits_are_exact_literals(self) -> None:
        sources = self.write_production_w3_fixture()
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        request_source = sources[request_relative]
        limits = (
            ("maximumChoiceCount", "16"),
            ("maximumContextScalarCount", "128"),
            ("maximumContextUTF8Count", "256"),
            ("maximumChoiceScalarCount", "48"),
            ("maximumChoiceUTF8Count", "96"),
            ("maximumPromptScalarCount", "3_072"),
            ("maximumPromptUTF8Count", "4_096"),
        )
        for name, literal in limits:
            with self.subTest(name=name):
                mutated = request_source.replace(
                    f"static let {name} = {literal}",
                    f"static let {name} = Int.max",
                    1,
                )
                self.assertNotEqual(mutated, request_source)
                self.write(request_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(request_relative, request_source)

    def test_w3_executable_inventories_reject_raw_ambient_and_uuid_inputs(self) -> None:
        sources = self.write_production_w3_fixture()
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        request_source = sources[request_relative]

        factory_anchor = "    }\n}\n\nenum QuickLogPromptBoundary"
        ambient_factories = (
            """    }

    static func ambientPasteboard() -> QuickLogPromptComponent {
        QuickLogPromptComponent(text: UIPasteboard.general.string ?? "")
    }
}

enum QuickLogPromptBoundary""",
            """    }

    static func ambientDefaults() -> QuickLogPromptComponent {
        QuickLogPromptComponent(
            text: UserDefaults.standard.string(forKey: "prompt") ?? ""
        )
    }
}

enum QuickLogPromptBoundary""",
        )
        for factory in ambient_factories:
            with self.subTest(factory=factory.split("func ", 1)[1].split("(", 1)[0]):
                mutated = request_source.replace(factory_anchor, factory, 1)
                self.assertNotEqual(mutated, request_source)
                self.write(request_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))

        mutations = (
            ("parsed.context", "parsed.draft.payee"),
            ("plan.context", "rawOCR"),
            (
                "QuickLogPromptBoundary.normalized(\n            value,",
                "QuickLogPromptBoundary.normalized(\n            money.description,",
            ),
            (
                "return QuickLogAssistancePlan(\n            context: context,",
                "return QuickLogAssistancePlan(\n"
                "            context: parsed.draft.occurredAt.description,",
            ),
            (
                "QuickLogAssistanceChoice(id: account.id, label: $0.text)",
                "QuickLogAssistanceChoice(\n"
                "                        id: account.id,\n"
                "                        label: account.id.uuidString\n"
                "                    )",
            ),
            (
                "QuickLogPromptComponent.choice($0.label)",
                "QuickLogPromptComponent.choice($0.id.uuidString)",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(replacement=replacement):
                mutated = request_source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, request_source)
                self.write(request_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))

        extra_constructor = request_source + """

func unreviewedRequest(
    context: QuickLogPromptComponent,
    choices: [QuickLogPromptComponent]
) {
    _ = QuickLogOrdinalRequest(
        context: context,
        firstChoices: choices,
        secondChoices: choices
    )
}
"""
        self.write(request_relative, extra_constructor)
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-input-boundary", self.rules(violations))

    def test_w3_executable_inventories_pin_limit_enforcement(self) -> None:
        sources = self.write_production_w3_fixture()
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        request_source = sources[request_relative]
        mutations = (
            (
                "static let maximumChoiceCount = 16",
                "static let maximumChoiceCount = 16 + Int.max",
            ),
            (".prefix(maximumChoiceCount)", ".prefix(accounts.count)"),
            (
                "accountChoices.count <= Self.maximumChoiceCount,",
                "accountChoices.count <= Int.max,",
            ),
            (
                "utf8Count + fragmentUTF8Count <= maximumUTF8Count",
                "utf8Count + fragmentUTF8Count <= Int.max",
            ),
            (
                "Set(normalized.map(\\.label)).count == normalized.count",
                "normalized.count >= 0",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                mutated = request_source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, request_source)
                self.write(request_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))

    def test_w3_member_inventories_pin_literals_and_stored_shape(self) -> None:
        sources = self.write_production_w3_fixture()
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        request_source = sources[request_relative]
        mutations = (
            ('collapsed.append(" ")', 'collapsed.append("\\n")'),
            ('return "Not requested"', 'return "Anything"'),
            ('.joined(separator: "\\n")', '.joined(separator: ",")'),
            ('.joined(separator: "\\n")', '.joined(separator: #"\\n"#)'),
            ('Locale(identifier: "en_US_POSIX")', 'Locale(identifier: "en_US")'),
            (
                "Choose ordinals only from the two closed local lists.",
                "Use ambient text to choose anything.",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                mutated = request_source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, request_source)
                self.write(request_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(request_relative, request_source)

        computed_ambient = request_source.replace(
            "    let text: String",
            """    private var stored = ""
    var text: String {
        get { UserDefaults.standard.string(forKey: "prompt") ?? stored }
        set { stored = newValue }
    }""",
            1,
        )
        self.assertNotEqual(computed_ambient, request_source)
        self.write(request_relative, computed_ambient)
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-input-boundary", self.rules(violations))

    def test_w3_parser_provenance_rejects_raw_aliases(self) -> None:
        sources = self.write_production_w3_fixture()
        entry_relative = "App/MoneyUp/QuickLogEntryDraft.swift"
        assistance_relative = (
            "App/MoneyUp/QuickLogEntryOnDeviceAssistance.swift"
        )
        mutations = (
            (
                entry_relative,
                "let parsed = NaturalLanguageEntryParser.parse(",
                "let ignoredParsed = NaturalLanguageEntryParser.parse(",
            ),
            (
                entry_relative,
                "startOnDeviceAssistance(for: parsed)",
                "startOnDeviceAssistance(for: rawOCRParsed)",
            ),
            (
                assistance_relative,
                "requestPlan = QuickLogAssistancePlan.make(\n"
                "                    parsed: parsed,",
                "requestPlan = QuickLogAssistancePlan.make(\n"
                "                    parsed: rawParsed,",
            ),
            (
                assistance_relative,
                "onDeviceAssistanceTask = Task { @MainActor in\n"
                "            var requestPlan",
                "onDeviceAssistanceTask = Task { @MainActor in\n"
                "            let parsed = rawParsed\n"
                "            var requestPlan",
            ),
            (
                entry_relative,
                "            startOnDeviceAssistance(for: parsed)",
                """            let alternate = ParsedNaturalLanguageEntry(
                draft: parsed.draft,
                context: smartText
            )
            ({ parsed in
                startOnDeviceAssistance(for: parsed)
            })(alternate)""",
            ),
        )
        for relative, original, replacement in mutations:
            with self.subTest(relative=relative, replacement=replacement):
                source = sources[relative]
                mutated = source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(relative, source)

    def test_w3_production_compile_gate_rejects_non_ios_conjunction(self) -> None:
        sources = self.write_production_w3_fixture()
        for relative in (
            "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift",
            "App/MoneyUp/QuickLogOnDeviceAssistance.swift",
        ):
            with self.subTest(relative=relative):
                mutated = sources[relative].replace(
                    "#if canImport(FoundationModels)",
                    "#if canImport(FoundationModels) && os(macOS)",
                    1,
                )
                self.assertNotEqual(mutated, sources[relative])
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-compile-gate", self.rules(violations))
                self.write(relative, sources[relative])

        model_relative = "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift"
        self.write(
            model_relative,
            "#if os(macOS)\n" + sources[model_relative] + "#endif\n",
        )
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-compile-gate", self.rules(violations))

    def test_w3_escaped_response_and_extra_model_member_are_rejected(self) -> None:
        sources = self.write_production_w3_fixture()
        model_relative = "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift"
        source = sources[model_relative]
        anchor = "    }\n}\n#endif"
        replacement = """    }

    static func unsafe(text: String) async throws {
        guard SystemLanguageModel.default.availability == .available else {
            return
        }
        let session = LanguageModelSession()
        _ = try await session.`respond`(
            to: text,
            generating: LocalOrdinalSelection.self
        )
    }
}
#endif"""
        mutated = source.replace(anchor, replacement, 1)
        self.assertNotEqual(mutated, source)
        self.write(model_relative, mutated)
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-input-boundary", self.rules(violations))

    def test_w3_canonical_import_inventory_rejects_broadened_forms(self) -> None:
        sources = self.write_production_w3_fixture()
        model_relative = "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift"
        source = sources[model_relative]
        mutations = (
            "public import FoundationModels",
            "@_exported import FoundationModels",
            "import FoundationModels\nimport FoundationModels",
        )
        for replacement in mutations:
            with self.subTest(replacement=replacement):
                mutated = source.replace(
                    "import FoundationModels",
                    replacement,
                    1,
                )
                self.assertNotEqual(mutated, source)
                self.write(model_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(model_relative, source)

    def test_w3_type_headers_and_direct_declarations_are_closed(self) -> None:
        sources = self.write_production_w3_fixture()
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        parser_relative = "Sources/MoneyUpCore/NaturalLanguageEntryParser.swift"
        request_source = sources[request_relative]
        parser_source = sources[parser_relative]
        request_mutations = (
            (
                "component-codable",
                "struct QuickLogPromptComponent: Equatable, Sendable",
                "struct QuickLogPromptComponent: Equatable, Sendable, Codable",
            ),
            (
                "request-codable",
                "struct QuickLogOrdinalRequest: Equatable, Sendable",
                "struct QuickLogOrdinalRequest: Equatable, Sendable, Codable",
            ),
            (
                "nested-type",
                "    let text: String",
                "    struct Ambient { let value: String }\n    let text: String",
            ),
            (
                "subscript",
                "    static let live = QuickLogOrdinalSelector { request in",
                "    subscript(_ request: QuickLogOrdinalRequest) -> String {\n"
                "        UserDefaults.standard.string(forKey: \"prompt\") ?? \"\"\n"
                "    }\n\n"
                "    static let live = QuickLogOrdinalSelector { request in",
            ),
            (
                "backticked-property",
                "    let text: String",
                "    static var `ambient`: QuickLogPromptComponent {\n"
                "        .init(text: UserDefaults.standard.string(\n"
                "            forKey: \"prompt\"\n"
                "        ) ?? \"\")\n"
                "    }\n    let text: String",
            ),
            (
                "attributed-property",
                "    let text: String",
                "    @available(iOS 26.0, *) static var ambient: String {\n"
                "        UserDefaults.standard.string(forKey: \"prompt\") ?? \"\"\n"
                "    }\n    let text: String",
            ),
            (
                "unicode-function",
                "    let text: String",
                "    static func 遠端() -> String {\n"
                "        UserDefaults.standard.string(forKey: \"prompt\") ?? \"\"\n"
                "    }\n    let text: String",
            ),
            (
                "live-selector",
                "    static let live = QuickLogOrdinalSelector { request in",
                "    static let live = QuickLogOrdinalSelector { _ in nil\n"
                "    }\n"
                "    static let ignoredLive = QuickLogOrdinalSelector { request in",
            ),
        )
        for name, original, replacement in request_mutations:
            with self.subTest(name=name):
                mutated = request_source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, request_source)
                self.write(request_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(request_relative, request_source)

        parsed_ambient = parser_source.replace(
            "    public let context: String?",
            """    private var storedContext: String?
    public var context: String? {
        get { UserDefaults.standard.string(forKey: "prompt") ?? storedContext }
        set { storedContext = newValue }
    }""",
            1,
        ).replace("self.context = context", "self.storedContext = context", 1)
        self.assertNotEqual(parsed_ambient, parser_source)
        self.write(parser_relative, parsed_ambient)
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-input-boundary", self.rules(violations))
        self.write(parser_relative, parser_source)

        attributed_types = (
            (
                "App/MoneyUp/QuickLogOnDeviceAssistance.swift",
                "@MainActor\nfinal class QuickLogAssistanceCoordinator",
                "final class QuickLogAssistanceCoordinator",
            ),
            (
                "App/MoneyUp/QuickLogSheet.swift",
                "@MainActor\nenum QuickLogInputAuthority",
                "enum QuickLogInputAuthority",
            ),
            (
                "App/MoneyUp/QuickLogOnDeviceOrdinalModel.swift",
                "@Generable\nprivate struct LocalOrdinalSelection",
                "private struct LocalOrdinalSelection",
            ),
        )
        for relative, original, replacement in attributed_types:
            with self.subTest(relative=relative, attribute=original.splitlines()[0]):
                source = sources[relative]
                mutated = source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(relative, source)

    def test_w3_global_alias_and_consumer_side_doors_are_rejected(self) -> None:
        self.write_production_w3_fixture()
        bypasses = (
            (
                "alias-plan",
                """import Foundation
typealias AlternatePlanner = QuickLogAssistancePlan
func ambientPlan(
    choices: [QuickLogAssistanceChoice]
) -> QuickLogAssistancePlan? {
    AlternatePlanner(
        context: UserDefaults.standard.string(forKey: "prompt") ?? "",
        accountChoices: choices,
        categoryChoices: []
    )
}
""",
            ),
            (
                "resolver-reference",
                "let unreviewedResolver = QuickLogAssistanceResolver.resolve\n",
            ),
            (
                "live-select-consumer",
                """func unreviewedSelect(
    _ request: QuickLogOrdinalRequest
) async throws {
    _ = try await QuickLogOrdinalSelector.live.select(request)
}
""",
            ),
            (
                "parsed-alias",
                """import Foundation
typealias AlternateParsed = ParsedNaturalLanguageEntry
typealias AlternatePlanner = QuickLogAssistancePlan
func unreviewedPlan(
    draft: TransactionDraft,
    accounts: [LedgerAccount]
) -> QuickLogAssistancePlan? {
    let parsed = AlternateParsed(
        draft: draft,
        context: UserDefaults.standard.string(forKey: "prompt")
    )
    return AlternatePlanner.make(
        parsed: parsed,
        accounts: accounts,
        categories: accounts,
        accountFieldWasEdited: false,
        categoryFieldWasEdited: false
    )
}
""",
            ),
        )
        for name, source in bypasses:
            with self.subTest(name=name):
                path = self.root / "App/MoneyUp/UnreviewedW3Bypass.swift"
                if path.exists():
                    path.unlink()
                self.write("App/MoneyUp/UnreviewedW3Bypass.swift", source)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))

    def test_w3_unicode_and_context_boundary_dependencies_are_pinned(self) -> None:
        sources = self.write_production_w3_fixture()
        request_relative = "App/MoneyUp/QuickLogOnDeviceAssistance.swift"
        parser_relative = "Sources/MoneyUpCore/NaturalLanguageEntryParser.swift"
        request_source = sources[request_relative]
        parser_source = sources[parser_relative]
        normalized_mutations = (
            (
                "compatibility",
                "let canonical = value.precomposedStringWithCompatibilityMapping",
                "let canonical = value.precomposedStringWithCanonicalMapping",
            ),
            (
                "zero-width-space",
                "properties.isDefaultIgnorableCodePoint",
                "scalar.value == 0xFE0F",
            ),
            (
                "variation-selector",
                "properties.isDefaultIgnorableCodePoint",
                "scalar.value == 0x200B",
            ),
            (
                "bidi-format",
                "properties.generalCategory == .format",
                "properties.generalCategory == .privateUse",
            ),
            (
                "control",
                "properties.generalCategory != .control",
                "properties.generalCategory != .privateUse",
            ),
        )
        for name, original, replacement in normalized_mutations:
            with self.subTest(name=name):
                mutated = request_source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, request_source)
                self.write(request_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(request_relative, request_source)

        parser_mutations = (
            (
                "scalar-bound",
                "nextScalarCount <= 128, nextUTF8Count <= 256",
                "nextScalarCount <= Int.max, nextUTF8Count <= 256",
            ),
            (
                "byte-bound",
                "nextScalarCount <= 128, nextUTF8Count <= 256",
                "nextScalarCount <= 128, nextUTF8Count <= Int.max",
            ),
            (
                "raw-prefix",
                "let boundedContext = boundedAssistanceContext(words)",
                "let boundedContext = Optional(String(fullContext.prefix(128)))",
            ),
            (
                "mid-token-prefix",
                'return context.isEmpty ? nil : context',
                'return String(words.joined(separator: " ").prefix(128))',
            ),
            (
                "bounded-letter-guard",
                "boundedContext.contains(where: { $0.isLetter }),",
                "!boundedContext.isEmpty,",
            ),
            (
                "bounded-local-name-guard",
                "!containsLocalName(boundedContext, localNames: localNames)",
                "true",
            ),
            (
                "token-projection-dependency",
                "        guard !token.isEmpty, !text.isEmpty else { return nil }",
                "        return nil",
            ),
            (
                "local-helper-shadow",
                """        return ParsedNaturalLanguageEntry(
            draft: draft,""",
                """        func assistanceContext(
            from remainder: String,
            currencyCodes: Set<String>,
            localNames: [String]
        ) -> String? { remainder }
        return ParsedNaturalLanguageEntry(
            draft: draft,""",
            ),
        )
        for name, original, replacement in parser_mutations:
            with self.subTest(name=name):
                mutated = parser_source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, parser_source)
                self.write(parser_relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(parser_relative, parser_source)

    def test_w3_default_preference_and_input_authority_are_exact(self) -> None:
        sources = self.write_production_w3_fixture()
        profile_relative = "Sources/MoneyUpCore/UserProfile.swift"
        authority_relative = "App/MoneyUp/QuickLogSheet.swift"
        body_relative = "App/MoneyUp/QuickLogEntryBody.swift"
        receipt_relative = "App/MoneyUp/QuickLogEntryReceiptCandidates.swift"
        mutations = (
            (
                profile_relative,
                "foundationModelAssistanceEnabled: Bool = true,",
                "foundationModelAssistanceEnabled: Bool = false,",
            ),
            (
                profile_relative,
                """        foundationModelAssistanceEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .foundationModelAssistanceEnabled
        ) ?? true""",
                """        foundationModelAssistanceEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .foundationModelAssistanceEnabled
        ) ?? false""",
            ),
            (
                profile_relative,
                "self.foundationModelAssistanceEnabled = "
                "foundationModelAssistanceEnabled",
                "self.foundationModelAssistanceEnabled = true",
            ),
            (
                authority_relative,
                """        cancelReceipt()
        cancelAssistance()
        start()""",
                """        cancelReceipt()
        start()""",
            ),
            (
                body_relative,
                "cancelAssistance: { cancelOnDeviceAssistance() }",
                "cancelAssistance: {}",
            ),
            (
                receipt_relative,
                """invalidateAssistance: {
                        invalidateOnDeviceCategoryForDeterministicChange()
                    }""",
                "invalidateAssistance: {}",
            ),
        )
        for relative, original, replacement in mutations:
            with self.subTest(relative=relative, replacement=replacement):
                source = sources[relative]
                mutated = source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(relative, source)

    def test_w3_receipt_currentness_seam_is_exact(self) -> None:
        sources = self.write_production_w3_fixture()
        relative = "App/MoneyUp/QuickLogEntryReceipt.swift"
        source = sources[relative]
        self.assertEqual(fitness.validate_w3_foundation_models(self.root), [])
        mutations = (
            (
                "suggestion-publication-guard",
                """        } handleSuggestions: { result in
            guard receiptScanIsCurrent(
                generation: generation,
                logicalBookRevision: logicalBookRevision
            ) else { return false }
            let didApplySuggestions = applyReceipt(result)""",
                """        } handleSuggestions: { result in
            guard true else { return false }
            let didApplySuggestions = applyReceipt(result)""",
            ),
            (
                "captured-book-revision",
                """        generation == receiptScanGeneration
            && logicalBookRevision == model.logicalBookRevision""",
                """        generation == receiptScanGeneration
            && true""",
            ),
            (
                "suggestion-publication-revision",
                """        } handleSuggestions: { result in
            guard receiptScanIsCurrent(
                generation: generation,
                logicalBookRevision: logicalBookRevision
            ) else { return false }
            let didApplySuggestions = applyReceipt(result)""",
                """        } handleSuggestions: { result in
            guard receiptScanIsCurrent(
                generation: generation,
                logicalBookRevision: model.logicalBookRevision
            ) else { return false }
            let didApplySuggestions = applyReceipt(result)""",
            ),
        )
        for name, original, replacement in mutations:
            with self.subTest(name=name):
                mutated = source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(relative, source)

    def test_w3_book_replacement_cancellation_chain_is_exact(self) -> None:
        sources = self.write_production_w3_fixture()
        draft_relative = "App/MoneyUp/QuickLogEntryDraft.swift"
        capture_relative = "App/MoneyUp/QuickLogEntryCaptureSuggestions.swift"
        self.assertEqual(fitness.validate_w3_foundation_models(self.root), [])
        mutations = (
            (
                draft_relative,
                '''        cancelReceiptProcessing()
        cancelCaptureSuggestionLookup()
        clearPerTransactionReviewState()
        amountText = ""''',
                '''        cancelReceiptProcessing()
        cancelCaptureSuggestionLookup()
        amountText = ""''',
            ),
            (
                draft_relative,
                '''        isShowingOptionalDetails = false
        pendingLaunchRequest = nil
        isConfirmingDraftSwitch = false''',
                '''        isShowingOptionalDetails = false
        isConfirmingDraftSwitch = false''',
            ),
            (
                capture_relative,
                '''        clearCaptureSuggestionProvenance()
        cancelOnDeviceAssistance()
        pendingDuplicateReview = nil''',
                '''        clearCaptureSuggestionProvenance()
        pendingDuplicateReview = nil''',
            ),
        )
        for relative, original, replacement in mutations:
            with self.subTest(relative=relative):
                source = sources[relative]
                mutated = source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(relative, source)

    def test_w3_publication_authority_and_state_sinks_are_exact(self) -> None:
        sources = self.write_production_w3_fixture()
        relative = "App/MoneyUp/QuickLogEntryOnDeviceAssistance.swift"
        source = sources[relative]
        mutations = (
            ("suggestionID != baseline.id,", "true,"),
            ("candidates.contains(suggestionID),", "true,"),
            ("currentIDs.contains(suggestionID),", "true,"),
            ("guard currentKind == baseline.kind,", "guard true,"),
            (
                "guard resolution.suggestedAccountID == id else { return nil }",
                "guard true else { return nil }",
            ),
            ("guard current == modelAppliedAccountState,", "guard true,"),
            (
                """    func cancelOnDeviceAssistance() {
        onDeviceAssistanceCoordinator.cancel()
        onDeviceAssistanceTask?.cancel()
        onDeviceAssistanceTask = nil
        onDeviceAssistance = nil
    }""",
                """    func cancelOnDeviceAssistance() {
        onDeviceAssistance = nil
    }""",
            ),
        )
        for original, replacement in mutations:
            with self.subTest(original=original):
                mutated = source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-input-boundary", self.rules(violations))
                self.write(relative, source)

        unchecked = """import Foundation
extension QuickLogEntryView {
    func publishUncheckedSuggestion(_ id: UUID) {
        onDeviceAssistance = .init(
            resolution: .init(
                suggestedAccountID: id,
                suggestedCategoryID: nil
            )
        )
    }
}
"""
        self.write("App/MoneyUp/UncheckedW3.swift", unchecked)
        violations = fitness.validate_w3_foundation_models(self.root)
        self.assertIn("w3-input-boundary", self.rules(violations))

    def test_w3_contextual_use_labels_are_static_mutation_guarded(self) -> None:
        sources = self.write_production_w3_fixture()
        relatives = (
            "App/MoneyUp/QuickLogEntryOnDeviceAssistance.swift",
            "App/MoneyUp/QuickLogEntryCaptureSuggestions.swift",
        )

        def reset_sources() -> None:
            for relative, source in sources.items():
                self.write(relative, source)

        reset_sources()
        baseline = fitness.validate_w3_foundation_models(self.root)
        self.assertNotIn("w3-accessibility", self.rules(baseline))

        for relative in relatives:
            with self.subTest(relative=relative):
                reset_sources()
                source = sources[relative]
                mutated = source.replace(".accessibilityLabel(", ".help(", 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-accessibility", self.rules(violations))

            with self.subTest(relative=relative, mutation="overload-decoy"):
                reset_sources()
                source = sources[relative]
                function_name = (
                    "onDeviceAssistanceRow"
                    if "OnDevice" in relative else "captureSuggestionRow"
                )
                scan = fitness.scan_swift(source)
                declaration = re.search(
                    rf"\bprivate\s+func\s+{function_name}\s*\([^{{}};]*\)"
                    r"\s*->\s*some\s+View\s*\{",
                    scan.masked,
                    re.DOTALL,
                )
                self.assertIsNotNone(declaration)
                assert declaration is not None
                opening = declaration.end() - 1
                closing = fitness.find_matching(scan.masked, opening)
                self.assertIsNotNone(closing)
                assert closing is not None
                decoy = source[declaration.start():closing + 1]
                mutated = source.replace(
                    "        useAccessibilityLabel: String,\n"
                    "        apply: @escaping () -> Void",
                    "        useAccessibilityLabel: String,\n"
                    "        decoy: Bool = false,\n"
                    "        apply: @escaping () -> Void",
                    1,
                ).replace(".accessibilityLabel(", ".help(", 1)
                mutated += (
                    "\nprivate struct AccessibilityDecoy {\n"
                    + decoy
                    + "\n}\n"
                )
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-accessibility", self.rules(violations))

        contextual_arguments = (
            (
                relatives[0],
                '"quick_log.use_account_accessibility_format"\n'
                "                        ),\n"
                "                        item.name",
                '"quick_log.use_account_accessibility_format"\n'
                "                        ),\n"
                '                        ""',
            ),
            (
                relatives[1],
                '"quick_log.use_account_accessibility_format"\n'
                "                        ),\n"
                "                        account.name",
                '"quick_log.use_account_accessibility_format"\n'
                "                        ),\n"
                '                        ""',
            ),
        )
        for relative, original, replacement in contextual_arguments:
            with self.subTest(relative=relative, mutation="empty-context"):
                reset_sources()
                source = sources[relative]
                mutated = source.replace(original, replacement, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-accessibility", self.rules(violations))

            with self.subTest(relative=relative, mutation="sibling-label-decoy"):
                reset_sources()
                source = sources[relative]
                owned = """                        .buttonStyle(.borderless)
                        .accessibilityLabel(
                            Text(useAccessibilityLabel)
                        )"""
                sibling = """                        .buttonStyle(.borderless)
                    Text(useAccessibilityLabel)
                        .accessibilityLabel(
                            Text(useAccessibilityLabel)
                        )"""
                mutated = source.replace(owned, sibling, 1)
                self.assertNotEqual(mutated, source)
                self.write(relative, mutated)
                violations = fitness.validate_w3_foundation_models(self.root)
                self.assertIn("w3-accessibility", self.rules(violations))

    def test_w3_global_use_literal_inventory_rejects_extra_action(self) -> None:
        self.write_production_w3_fixture()
        self.write(
            "App/MoneyUp/ExtraSuggestion.swift",
            """\
import SwiftUI

struct ExtraSuggestion: View {
    var body: some View {
        Button("quick_log.use_suggestion") {}
    }
}
""",
        )

        violations = fitness.validate_w3_foundation_models(self.root)

        self.assertIn("w3-accessibility", self.rules(violations))


if __name__ == "__main__":
    unittest.main()
