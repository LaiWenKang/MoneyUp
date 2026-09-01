from __future__ import annotations

import json
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
#if os(iOS) && canImport(FoundationModels)
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
        .range(0...20)
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
    @Guide(.range(0...256)) var rankOrdinal: Int
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
            and "0...255" in violation.detail
        ]
        self.assertEqual(len(bounded), 3)

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
            {"Tool", "ToolChoice", "ProviderClient", "PackageID", "PCCClient"}
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


if __name__ == "__main__":
    unittest.main()
