from __future__ import annotations

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "validate_platform_actions",
    ROOT / "Scripts/validate_platform_actions.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load platform-action validator")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class PlatformActionsValidatorTests(unittest.TestCase):
    def source(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def inventory_with_extra(self, relative: str, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for source_root in VALIDATOR.COMPILED_SWIFT_ROOTS:
                shutil.copytree(ROOT / source_root, root / source_root)
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(source, encoding="utf-8")
            return VALIDATOR.validate_compiled_surface_inventory(root)

    def test_current_repository_passes(self) -> None:
        self.assertEqual(VALIDATOR.validate_repository(ROOT), [])

    def test_rejects_free_form_intent_parameter(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated = source.replace(
            "    var action: MoneyUpQuickAction\n",
            "    var action: MoneyUpQuickAction\n\n"
            '    @Parameter(title: "Unsafe")\n'
            "    var note: String\n",
            1,
        )

        errors = VALIDATOR.validate_shared_action_source(mutated)

        self.assertTrue(any("must expose only action" in error for error in errors))

    def test_rejects_persisted_raw_value_or_route_drift(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        raw_drift = source.replace(
            'case smartEntry = "smartEntry"',
            'case smartEntry = "smart-entry"',
            1,
        )
        route_drift = source.replace(
            'moneyup://quick-log/income"',
            'moneyup://quick-log/income?value=1"',
            1,
        )

        self.assertTrue(
            any(
                "persisted MoneyUpQuickAction" in error
                for error in VALIDATOR.validate_shared_action_source(raw_drift)
            )
        )
        self.assertTrue(
            any(
                "URL allowlist drifted" in error or "path-only" in error
                for error in VALIDATOR.validate_shared_action_source(route_drift)
            )
        )

    def test_rejects_casefolded_or_componentwise_url_decoding(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutations = [
            source.replace(
                "        guard url.baseURL == nil else { return nil }\n",
                "",
                1,
            ),
            source.replace(
                "            $0.deepLink.absoluteString == literal\n",
                "            $0.deepLink.absoluteString.lowercased() "
                "== literal.lowercased()\n",
                1,
            ),
            source.replace(
                "        guard let action = Self.allCases.first(where: {\n"
                "            $0.deepLink.absoluteString == literal\n"
                "        }) else {\n"
                "            return nil\n"
                "        }\n",
                "        let action = Self.expense\n",
                1,
            ),
        ]

        for mutated in mutations:
            errors = VALIDATOR.validate_shared_action_source(mutated)
            self.assertTrue(
                any("exact literal closed mapping" in error for error in errors),
                errors,
            )

    def test_rejects_on_open_url_bypassing_the_closed_app_route(self) -> None:
        source = self.source("App/MoneyUp/MoneyUpApp.swift")
        mutated = source.replace(
            "                .onOpenURL { url in\n"
            "                    routeDeepLink(url)\n"
            "                }\n",
            "                .onOpenURL { url in\n"
            "                    _ = model.handleDeepLink(url)\n"
            "                }\n",
            1,
        )

        errors = VALIDATOR.validate_app_routing_source(mutated)

        self.assertTrue(any("route gate" in error for error in errors), errors)

    def test_rejects_direct_deep_link_routing_outside_the_fifo(self) -> None:
        source = self.source("App/MoneyUp/MoneyUpApp.swift")
        original = (
            "        guard let action = MoneyUpQuickAction(exactDeepLink: url) "
            "else { return }\n"
            "        _ = quickActionRouteBroker.submit(action)\n"
            "        routePendingQuickAction()\n"
        )
        mutations = [
            source.replace(
                original,
                "        guard model.handleDeepLink(url) else { return }\n"
                "        Task { await model.start() }\n",
                1,
            ),
            source.replace(
                original,
                "        guard let action = MoneyUpQuickAction(exactDeepLink: url),\n"
                "              quickActionRouteBroker.submit(action) else { return }\n"
                "        _ = model.handleDeepLink(action.deepLink)\n",
                1,
            ),
        ]

        for mutated in mutations:
            errors = VALIDATOR.validate_app_routing_source(mutated)
            self.assertTrue(
                any("submit one closed action" in error for error in errors),
                errors,
            )

    def test_rejects_permissive_model_deep_link_parsing(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        original = (
            "        guard let action = MoneyUpQuickAction(exactDeepLink: url) else {\n"
            "            return false\n"
            "        }\n"
            "        let mode = QuickLogLaunchMode(action)\n"
        )
        mutated_lifecycle = lifecycle.replace(
            original,
            "        guard url.scheme?.lowercased() == \"moneyup\",\n"
            "              url.host?.lowercased() == \"quick-log\",\n"
            "              let mode = QuickLogLaunchMode(\n"
            "                  rawValue: url.lastPathComponent.lowercased()\n"
            "              ) else {\n"
            "            return false\n"
            "        }\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            model,
            mutated_lifecycle,
            settings,
            restore,
        )

        self.assertTrue(any("exact data-free route" in error for error in errors), errors)

    def test_rejects_action_to_launch_mode_mapping_drift(self) -> None:
        source = self.source("App/MoneyUp/QuickLogLaunchMode.swift")
        mutated = source.replace(
            "        case .refund:\n            self = .refund\n",
            "        case .refund:\n            self = .income\n",
            1,
        )

        errors = VALIDATOR.validate_request_identity_source(mutated)

        self.assertTrue(any("map exhaustively" in error for error in errors), errors)

    def test_rejects_direct_url_intent(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated = source.replace(
            "return .result()",
            "return .result(opensIntent: OpenURLIntent(action.deepLink))",
            1,
        )

        errors = VALIDATOR.validate_shared_action_source(mutated)

        self.assertTrue(any("direct URL intent" in error for error in errors))

    def test_rejects_mutable_ios26_foreground_metadata(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated = source.replace(
            "static let supportedModes: IntentModes = [.foreground(.immediate)]",
            "static var supportedModes: IntentModes = [.foreground(.immediate)]",
            1,
        )

        errors = VALIDATOR.validate_shared_action_source(mutated)

        self.assertTrue(any("supportedModes" in error for error in errors))

    def test_rejects_alternate_intent_in_new_compiled_file(self) -> None:
        errors = self.inventory_with_extra(
            "App/MoneyUp/UnsafeIntent.swift",
            "import AppIntents\n"
            "struct UnsafeIntent: AppIntent {\n"
            "    static let title: LocalizedStringResource = \"Unsafe\"\n"
            "    @Parameter(title: \"Note\") var note: String\n"
            "    func perform() async throws -> some IntentResult { .result() }\n"
            "}\n",
        )

        self.assertTrue(any("outside the allowlist" in error for error in errors))
        self.assertTrue(any("declaration inventory drifted" in error for error in errors))

    def test_rejects_payload_intent_in_linked_package_source(self) -> None:
        errors = self.inventory_with_extra(
            "Sources/MoneyUpIntelligence/UnsafePayloadIntent.swift",
            "import AppIntents\n"
            "struct UnsafePayloadIntent: AppIntent {\n"
            "    static let title: LocalizedStringResource = \"Unsafe\"\n"
            "    @Parameter(title: \"Payload\") var payload: String\n"
            "    func perform() async throws -> some IntentResult "
            "& ReturnsValue<String> {\n"
            "        .result(value: payload)\n"
            "    }\n"
            "}\n",
        )

        self.assertTrue(any("outside the allowlist" in error for error in errors))
        self.assertTrue(any("declaration inventory drifted" in error for error in errors))

    def test_rejects_payload_intent_outside_reviewed_source_roots(self) -> None:
        errors = self.inventory_with_extra(
            "UnsafePackageTarget/UnsafePayloadIntent.swift",
            "import AppIntents\n"
            "struct UnsafePayloadIntent: AppIntent {\n"
            "    static let title: LocalizedStringResource = \"Unsafe\"\n"
            "    @Parameter(title: \"Payload\") var payload: String\n"
            "    func perform() async throws -> some IntentResult { .result() }\n"
            "}\n",
        )

        self.assertTrue(any("outside the compiled inventory" in error for error in errors))
        self.assertTrue(any("outside the allowlist" in error for error in errors))
        self.assertTrue(any("declaration inventory drifted" in error for error in errors))

    def test_rejects_second_provider_and_control_in_new_compiled_file(self) -> None:
        errors = self.inventory_with_extra(
            "App/MoneyUpWidget/UnsafeSurfaces.swift",
            "import AppIntents\nimport WidgetKit\n"
            "struct UnsafeProvider: AppShortcutsProvider {\n"
            "    static var appShortcuts: [AppShortcut] { [] }\n"
            "}\n"
            "struct UnsafeControl: ControlWidget {\n"
            "    var body: some ControlWidgetConfiguration {\n"
            "        StaticControlConfiguration(kind: \"unsafe\") {\n"
            "            ControlWidgetButton(action: OpenQuickLogIntent()) {\n"
            "                Label(\"Unsafe\", systemImage: \"xmark\")\n"
            "            }\n"
            "        }\n"
            "    }\n"
            "}\n",
        )

        self.assertTrue(any("outside the allowlist" in error for error in errors))
        self.assertTrue(any("moved or multiplied" in error for error in errors))

    def test_rejects_indirect_broker_helper_in_new_compiled_file(self) -> None:
        errors = self.inventory_with_extra(
            "App/MoneyUp/UnsafeBrokerHelper.swift",
            "import Foundation\n"
            "extension MoneyUpQuickActionRouteBroker {\n"
            "    func persist(_ action: MoneyUpQuickAction) {\n"
            "        UserDefaults.standard.set(action.rawValue, forKey: \"unsafe\")\n"
            "    }\n"
            "}\n",
        )

        self.assertTrue(
            any("unreviewed compiled platform-action reference" in error for error in errors)
        )

    def test_rejects_request_leak_in_existing_allowlisted_file(self) -> None:
        source = self.source("App/MoneyUp/AppModel.swift")
        mutated = source.replace(
            "            services.capture.requestedQuickLogMode = newValue\n",
            "            services.capture.requestedQuickLogMode = newValue\n"
            "            UserDefaults.standard.set(\n"
            "                newValue?.rawValue,\n"
            '                forKey: "unsafe-platform-request"\n'
            "            )\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            mutated,
            self.source("App/MoneyUp/AppModelLifecycle.swift"),
            self.source("App/MoneyUp/AppModelSettings.swift"),
            self.source("App/MoneyUp/AppModelBackupRestore.swift"),
        )

        self.assertTrue(any("request setter must bind" in error for error in errors))

    def test_rejects_direct_link_action_in_new_compiled_widget_file(self) -> None:
        errors = self.inventory_with_extra(
            "App/MoneyUpWidget/UnsafeLinkView.swift",
            "import SwiftUI\n"
            "struct UnsafeLinkView: View {\n"
            "    var body: some View {\n"
            "        Link(\n"
            '            "Unsafe",\n'
            "            destination: URL(\n"
            '                string: "moneyup://quick-log/expense?note=payload"\n'
            "            )!\n"
            "        )\n"
            "    }\n"
            "}\n",
        )

        self.assertTrue(any("reference inventory drifted" in error for error in errors))

    def test_rejects_uninventoried_compiled_source_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "App", root / "App")
            shutil.copy2(ROOT / "Package.swift", root / "Package.swift")
            project = self.source("project.yml").replace(
                "      - path: App/Shared\n    dependencies:\n",
                "      - path: App/Shared\n"
                "      - path: App/UnsafeActions\n"
                "    dependencies:\n",
                1,
            )
            (root / "project.yml").write_text(project, encoding="utf-8")

            errors = VALIDATOR.validate_identity_and_capture_boundary(root)

        self.assertTrue(any("compiled source roots drifted" in error for error in errors))

    def test_rejects_package_target_graph_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "App", root / "App")
            package = self.source("Package.swift").replace(
                '            dependencies: ["MoneyUpCore"]\n'
                '        ),',
                '            dependencies: ["MoneyUpCore"],\n'
                '            path: "UnsafePackageTarget"\n'
                '        ),',
                1,
            )
            self.assertNotEqual(package, self.source("Package.swift"))
            (root / "Package.swift").write_text(package, encoding="utf-8")
            shutil.copy2(ROOT / "project.yml", root / "project.yml")

            errors = VALIDATOR.validate_identity_and_capture_boundary(root)

        self.assertTrue(any("target graph" in error for error in errors))

    def test_rejects_unreviewed_bundle_id_beside_exact_test_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "App", root / "App")
            shutil.copy2(ROOT / "Package.swift", root / "Package.swift")
            project = self.source("project.yml").replace(
                "com.laiwenkang.MoneyUpPerformanceTests",
                "com.laiwenkang.UnreviewedTests",
                1,
            )
            (root / "project.yml").write_text(project, encoding="utf-8")

            errors = VALIDATOR.validate_identity_and_capture_boundary(root)

        self.assertTrue(any("project bundle IDs drifted" in error for error in errors))

    def test_rejects_excluding_an_audited_compiled_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "App", root / "App")
            shutil.copy2(ROOT / "Package.swift", root / "Package.swift")
            project = self.source("project.yml").replace(
                "      - path: App/Shared\n    dependencies:\n",
                "      - path: App/Shared\n"
                "        excludes:\n"
                "          - MoneyUpQuickAction.swift\n"
                "    dependencies:\n",
                1,
            )
            (root / "project.yml").write_text(project, encoding="utf-8")

            errors = VALIDATOR.validate_identity_and_capture_boundary(root)

        self.assertTrue(any("compiled source roots drifted" in error for error in errors))

    def test_rejects_locked_capture_first_unlock_protection_drift(self) -> None:
        source = self.source("App/MoneyUp/LockedCaptureStore.swift")
        mutations = [
            source.replace(
                ".completeFileProtectionUntilFirstUserAuthentication",
                ".completeFileProtectionUnlessOpen",
                1,
            ),
            source.replace(
                "        try Self.enforceDurableFileProtection(at: url)\n",
                "",
                1,
            ),
            source.replace(
                "FileProtectionType.completeUntilFirstUserAuthentication",
                "FileProtectionType.completeUnlessOpen",
                1,
            ),
        ]

        for mutated in mutations:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                shutil.copytree(ROOT / "App", root / "App")
                shutil.copy2(ROOT / "Package.swift", root / "Package.swift")
                shutil.copy2(ROOT / "project.yml", root / "project.yml")
                (root / "App/MoneyUp/LockedCaptureStore.swift").write_text(
                    mutated,
                    encoding="utf-8",
                )
                errors = VALIDATOR.validate_identity_and_capture_boundary(root)

            self.assertTrue(
                any(
                    "first-unlock protection" in error
                    or "must migrate without legacy writes" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_direct_mutation_and_control_payload(self) -> None:
        shared = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated_shared = shared.replace(
            "return .result()",
            "UserDefaults.standard.set(action.rawValue, forKey: \"route\")\n"
            "        return .result()",
            1,
        )
        control = self.source("App/MoneyUpWidget/MoneyUpQuickLogControl.swift")
        mutated_control = control.replace(
            "struct MoneyUpQuickLogControl: ControlWidget {",
            "struct UnsafeControlIntent: ControlConfigurationIntent {\n"
            '    static let title: LocalizedStringResource = "Unsafe"\n'
            '    @Parameter(title: "Unsafe")\n'
            "    var identifier: String\n"
            "}\n\n"
            "struct MoneyUpQuickLogControl: ControlWidget {",
            1,
        )
        app = self.source("App/MoneyUp/MoneyUpApp.swift")
        mutated_app = app.replace(
            "        Task { await model.start() }\n",
            "        _ = model.saveLockedCapture\n"
            "        Task { await model.start() }\n",
            1,
        )

        self.assertTrue(
            any(
                "defaults writes" in error
                for error in VALIDATOR.validate_shared_action_source(mutated_shared)
            )
        )
        self.assertTrue(
            any(
                "second configuration payload" in error
                for error in VALIDATOR.validate_control_source(mutated_control)
            )
        )
        self.assertTrue(
            any(
                "direct locked-capture mutation" in error
                for error in VALIDATOR.validate_app_routing_source(mutated_app)
            )
        )

    def test_rejects_interactive_budget_status(self) -> None:
        source = self.source("App/MoneyUpWidget/MoneyUpWidget.swift")
        mutated = source.replace(
            "private struct BudgetStatusWidgetView: View {",
            "private struct BudgetStatusWidgetView: View {\n"
            "    // OpenQuickLogIntent must never appear on this passive surface.",
            1,
        )

        errors = VALIDATOR.validate_widget_source(mutated)

        self.assertTrue(any("budget status must remain passive" in error for error in errors))

    def test_widget_previews_use_modern_macros_and_keep_qa_variants(self) -> None:
        source = self.source("App/MoneyUpWidget/MoneyUpWidget.swift")

        self.assertNotIn("PreviewProvider", source)
        self.assertNotIn("WidgetPreviewContext", source)
        self.assertNotIn(".previewContext", source)
        self.assertGreaterEqual(source.count("#Preview("), 8)
        self.assertIn('as: .systemSmall', source)
        self.assertIn('as: .systemMedium', source)
        self.assertIn('.dynamicTypeSize, .accessibility5', source)
        self.assertIn('language: .english', source)
        self.assertIn('language: .simplifiedChinese', source)

        mutations = [
            source.replace("#Preview(", "#LegacyPreview(", 1),
            source.replace(
                ".environment(\\.dynamicTypeSize, .accessibility5)",
                ".environment(\\.dynamicTypeSize, .large)",
                1,
            ),
            source.replace("language: .simplifiedChinese", "language: .english"),
            source.replace(
                '#Preview("Quick action · Small", as: .systemSmall)',
                '#Preview("Quick action · Small")',
                1,
            ),
        ]
        for mutated in mutations:
            self.assertNotEqual(mutated, source)
            errors = VALIDATOR.validate_widget_source(mutated)
            self.assertTrue(
                any("modern macros" in error for error in errors),
                errors,
            )

    def test_rejects_quick_action_hint_that_promises_lockless_capture(self) -> None:
        catalog_paths = (
            "App/MoneyUp/Resources/Localizable.xcstrings",
            "App/MoneyUpWidget/Localizable.xcstrings",
            "App/MoneyUp/Resources/AppShortcuts.xcstrings",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in catalog_paths:
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, destination)
            widget_catalog = root / catalog_paths[1]
            source = widget_catalog.read_text(encoding="utf-8")
            mutated = source.replace(
                "Open MoneyUp to continue logging",
                "Open private capture without unlocking MoneyUp",
                1,
            )
            self.assertNotEqual(mutated, source)
            widget_catalog.write_text(mutated, encoding="utf-8")

            errors = VALIDATOR.validate_localization_catalogs(root)

        self.assertTrue(
            any("must not promise" in error for error in errors),
            errors,
        )

    def test_rejects_shared_localization_standard_defaults_fallback(self) -> None:
        source = self.source("App/Shared/AppLocalization.swift")
        mutated = source.replace(
            "            suiteName: BudgetWidgetSnapshotStore.appGroupIdentifier\n"
            "        )\n"
            "    }\n\n"
            "    static var current",
            "            suiteName: BudgetWidgetSnapshotStore.appGroupIdentifier\n"
            "        ) ?? .standard\n"
            "    }\n\n"
            "    static var current",
            1,
        )

        self.assertNotEqual(mutated, source)
        errors = VALIDATOR.validate_app_localization_source(mutated)
        self.assertTrue(
            any("standard defaults" in error for error in errors),
            errors,
        )

    def test_rejects_missing_stable_nonpercentage_budget_layout(self) -> None:
        source = self.source("App/MoneyUpWidget/MoneyUpWidget.swift")
        for state in ("zeroBudget", "negativeBudget"):
            with self.subTest(state=state):
                mutated = source.replace(
                    f"        case .{state}(_):\n",
                    "        case .stale:\n",
                    1,
                )

                errors = VALIDATOR.validate_widget_source(mutated)

                self.assertTrue(
                    any("preserve distinct" in error for error in errors)
                )

    def test_rejects_budget_status_state_family_or_available_semantics_drift(
        self,
    ) -> None:
        source = self.source("App/MoneyUpWidget/MoneyUpWidget.swift")
        mutations = [
            (
                "active family handoff",
                source.replace(
                    "                BudgetStatusWidgetView(\n"
                    "                    snapshot: entry.budgetSnapshot,\n"
                    "                    family: family,\n"
                    "                    homeDensity: homeDensity\n"
                    "                )",
                    "                BudgetStatusWidgetView(\n"
                    "                    snapshot: entry.budgetSnapshot,\n"
                    "                    family: .systemSmall,\n"
                    "                    homeDensity: homeDensity\n"
                    "                )",
                    1,
                ),
                "active widget family",
            ),
            (
                "disabled guidance",
                source.replace(
                    'detail: "widget.budget_enable",',
                    'detail: "widget.budget_stale",',
                    1,
                ),
                "preserve distinct",
            ),
            (
                "available threshold",
                source.replace(
                    "let isOver = percentUsed > 100",
                    "let isOver = percentUsed >= 100",
                    1,
                ),
                "available and over-plan states",
            ),
            (
                "small available outcome",
                source.replace(
                    "smallAvailableStatus("
                    "percentUsed: percentUsed, isOver: isOver)",
                    "smallAvailableStatus("
                    "percentUsed: percentUsed, isOver: false)",
                    1,
                ),
                "available and over-plan states",
            ),
            (
                "rectangular nonpercentage guidance",
                source.replace(
                    "Text(compactDetail).font(.caption).lineLimit(2)",
                    "Text(detail).font(.caption).lineLimit(2)",
                    1,
                ),
                "nonpercentage states",
            ),
            (
                "accessibility budget density",
                source.replace(
                    "if homeDensity.usesReducedBudgetStatus {",
                    "if false {",
                    1,
                ),
                "available and over-plan states",
            ),
            (
                "accessibility quick-action density",
                source.replace(
                    ".prefix(homeDensity.mediumQuickActionLimit)",
                    ".prefix(4)",
                    1,
                ),
                "Home quick actions",
            ),
            (
                "AX5 bilingual previews",
                source.replace(
                    ".environment(\\.dynamicTypeSize, .accessibility5)",
                    ".environment(\\.dynamicTypeSize, .large)",
                ),
                "widget previews",
            ),
            (
                "rectangular decorative accessibility",
                source.replace(
                    ".frame(width: 28)\n"
                    "                .accessibilityHidden(true)",
                    ".frame(width: 28)",
                    1,
                ),
                "rectangular action accessibility",
            ),
            (
                "rectangular explicit action label",
                source.replace(
                    ".accessibilityElement(children: .ignore)\n"
                    "        .accessibilityLabel(action.titleKey)\n"
                    "        .accessibilityHint(action.accessibilityHintKey)",
                    ".accessibilityElement(children: .combine)\n"
                    "        .accessibilityHint(action.accessibilityHintKey)",
                    1,
                ),
                "rectangular action accessibility",
            ),
        ]
        for label, mutated, expected_error in mutations:
            with self.subTest(label=label):
                self.assertNotEqual(mutated, source)
                errors = VALIDATOR.validate_widget_source(mutated)
                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

    def test_rejects_non_atomic_widget_snapshot_publication(self) -> None:
        source = self.source("App/Shared/BudgetWidgetSnapshot.swift")
        mutated = source.replace(
            "        defaults.set(data, forKey: Self.payloadKey)\n",
            "        defaults.set(data, forKey: Self.payloadKey)\n"
            '        defaults.set(4, forKey: "budgetStatus.schemaVersion")\n',
            1,
        )

        errors = VALIDATOR.validate_widget_snapshot_source(mutated)

        self.assertTrue(any("one version-4 App Group write" in error for error in errors))

        mutations = [
            (
                source.replace("percentUsed >= 0", "percentUsed >= -1", 1),
                "reject negative current derivatives",
            ),
            (
                source.replace(
                    "allowancePercentRemaining.map { $0 >= 0 }",
                    "allowancePercentRemaining.map { $0 >= -1 }",
                    1,
                ),
                "reject negative current derivatives",
            ),
            (
                source.replace(
                    "return value == .disabled ? .disabled : .stale",
                    "return .disabled",
                    1,
                ),
                "canonical empty disabled",
            ),
            (
                source.replace(
                    "        guard let decoded = decodedRecord(from: data) else {\n"
                    "            if allowsMaintenanceWrites {\n"
                    "                persist(.stale, to: defaults)\n"
                    "            }\n"
                    "            return .stale\n"
                    "        }\n",
                    "        guard let decoded = decodedRecord(from: data) "
                    "else { return nil }\n",
                    1,
                ),
                "present corrupt or future",
            ),
            (
                source.replace(
                    "data.count <= Self.maximumPayloadByteCount",
                    "!data.isEmpty",
                    1,
                ),
                "capped before",
            ),
            (
                source.replace(
                    "token.utf8.count == 7",
                    "!token.isEmpty",
                    1,
                ),
                "canonical bounded YYYY-MM",
            ),
        ]
        for unsafe, expected_error in mutations:
            self.assertNotEqual(unsafe, source)
            errors = VALIDATOR.validate_widget_snapshot_source(unsafe)
            self.assertTrue(
                any(expected_error in error for error in errors),
                errors,
            )

    def test_rejects_ambiguous_nil_percentage_widget_publication(self) -> None:
        source = self.source("App/Shared/BudgetWidgetSnapshot.swift")
        mutated = source.replace(
            "        _ snapshot: BudgetWidgetSnapshot,\n",
            "        enabled: Bool,\n        percentUsed: Int?,\n",
            1,
        )

        errors = VALIDATOR.validate_widget_snapshot_source(mutated)

        self.assertTrue(any("distinguish disabled" in error for error in errors))

    def test_rejects_exact_commitment_date_in_widget_snapshot(self) -> None:
        source = self.source("App/Shared/BudgetWidgetSnapshot.swift")
        mutated = source.replace(
            "        var daysUntilNextCommitment: Int?\n",
            "        var nextCommitment: Date?\n",
            1,
        )

        errors = VALIDATOR.validate_widget_snapshot_source(mutated)

        self.assertTrue(any("bounded derivatives" in error for error in errors))

    def test_rejects_mixed_generation_widget_reads(self) -> None:
        source = self.source("App/MoneyUpWidget/MoneyUpWidget.swift")
        mutated = source.replace(
            "        let now = Date()\n"
            "        let snapshot = store.readPublishedSnapshot(now: now)\n",
            "        let now = Date()\n",
            1,
        ).replace(
            "            budgetSnapshot: snapshot.budget,\n"
            "            insights: snapshot.insights\n",
            "            budgetSnapshot: store.read(),\n"
            "            insights: store.readInsights()\n",
            1,
        )

        errors = VALIDATOR.validate_widget_source(mutated)

        self.assertTrue(any("one generation" in error for error in errors))

    def test_rejects_smart_overview_integration_family_or_guidance_drift(self) -> None:
        widget = self.source("App/MoneyUpWidget/MoneyUpWidget.swift")
        split_generation = widget.replace(
            "                    insights: entry.insights,\n",
            "                    insights: nil,\n",
            1,
        )
        self.assertTrue(
            any(
                "Smart Overview must receive budget and insights" in error
                for error in VALIDATOR.validate_widget_source(split_generation)
            )
        )

        overview = self.source("App/MoneyUpWidget/SmartOverviewWidgetView.swift")
        mutations = [
            (
                "body family route",
                overview.replace(
                    "        case .accessoryRectangular:\n"
                    "            accessoryRectangular\n",
                    "        case .accessoryInline:\n"
                    "            accessoryRectangular\n",
                    1,
                ),
                "route every supported",
            ),
            (
                "WidgetFamily mapping",
                overview.replace(
                    "        case .accessoryRectangular:\n"
                    "            return .accessoryRectangular\n",
                    "        case .accessoryRectangular:\n"
                    "            return .systemSmall\n",
                    1,
                ),
                "mapping must preserve",
            ),
            (
                "disabled guidance",
                overview.replace(
                    '            ? "widget.smart_enable"\n'
                    '            : "widget.smart_open_app"\n',
                    '            ? "widget.smart_open_app"\n'
                    '            : "widget.smart_open_app"\n',
                    1,
                ),
                "distinguish disabled Settings guidance",
            ),
            (
                "stale accessibility",
                overview.replace(
                    "        case .stale:\n"
                    '            return AppLocalization.string("widget.smart_open_app")\n',
                    "        case .stale:\n"
                    '            return AppLocalization.string("widget.smart_enable")\n',
                    1,
                ),
                "open-app refresh for stale data",
            ),
            (
                "Lock Screen stale guidance",
                overview.replace(
                    '"widget.smart_refresh_short"',
                    '"widget.smart_enable_short"',
                    1,
                ),
                "Lock Screen layouts",
            ),
            (
                "negative budget distinction",
                overview.replace(
                    'AppLocalization.string("widget.smart_budget_negative")',
                    'AppLocalization.string("widget.smart_budget_zero")',
                    1,
                ),
                "distinguish zero and negative budgets",
            ),
            (
                "accessibility Home density",
                overview.replace(
                    "presentation.homeDensity == .accessibility",
                    "presentation.homeDensity == .standard",
                    1,
                ),
                "reduced-density accessibility layouts",
            ),
        ]
        for label, mutated, expected_error in mutations:
            with self.subTest(label=label):
                self.assertNotEqual(mutated, overview)
                errors = VALIDATOR.validate_smart_overview_widget_source(mutated)
                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

    def test_rejects_broker_payload_or_missing_warm_route(self) -> None:
        shared = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated_shared = shared.replace(
            "    let action: MoneyUpQuickAction\n",
            "    let action: MoneyUpQuickAction\n"
            "    let note: String\n",
            1,
        )
        app = self.source("App/MoneyUp/MoneyUpApp.swift")
        mutated_app = app.replace(
            ".onChange(of: quickActionRouteBroker.revision)",
            ".onChange(of: model.state)",
            1,
        )

        self.assertTrue(
            any(
                "opaque token and closed action" in error
                for error in VALIDATOR.validate_shared_action_source(mutated_shared)
            )
        )
        self.assertTrue(
            any(
                "main scene is missing broker route gate" in error
                for error in VALIDATOR.validate_app_routing_source(mutated_app)
            )
        )

    def test_rejects_broker_file_persistence(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated = source.replace(
            "        guard MoneyUpQuickActionRouteBroker.shared.submit(action) else {\n",
            "        try? action.rawValue.write(\n"
            '            toFile: "/tmp/moneyup-route",\n'
            "            atomically: true,\n"
            "            encoding: .utf8\n"
            "        )\n"
            "        guard MoneyUpQuickActionRouteBroker.shared.submit(action) else {\n",
            1,
        )

        errors = VALIDATOR.validate_shared_action_source(mutated)

        self.assertTrue(any("file persistence" in error for error in errors))
        self.assertTrue(any("durably admit" in error for error in errors))

    def test_rejects_durable_ingress_payload_or_bound_drift(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutations = [
            source.replace(
                "    let action: MoneyUpQuickAction\n",
                "    let action: MoneyUpQuickAction\n    let amount: Int\n",
                1,
            ),
            source.replace(
                "static let maximumPayloadByteCount = 4_096",
                "static let maximumPayloadByteCount = 40_960",
                1,
            ),
            source.replace(
                ".completeFileProtectionUntilFirstUserAuthentication",
                ".noFileProtection",
                1,
            ),
            source.replace(
                'Set($0.keys) == Set(["token", "action"])',
                'Set($0.keys).isSuperset(of: ["token", "action"])',
                1,
            ),
        ]

        for mutated in mutations:
            self.assertNotEqual(mutated, source)
            errors = VALIDATOR.validate_shared_action_source(mutated)
            self.assertTrue(
                any(
                    "durable ingress" in error
                    or "exact broker/intent structural contract" in error
                    for error in errors
                ),
                errors,
            )

    def test_rejects_uncoordinated_or_non_atomic_durable_ingress(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutations = [
            source.replace("NSFileCoordinator(filePresenter: nil)", "HiddenStore", 1),
            source.replace("                .atomic,\n", "", 1),
            source.replace("options: .forReplacing", "options: []", 1),
        ]

        for mutated in mutations:
            self.assertNotEqual(mutated, source)
            errors = VALIDATOR.validate_shared_action_source(mutated)
            self.assertTrue(any("durable ingress" in error for error in errors), errors)

    def test_rejects_durable_epoch_recovery_and_postcondition_drift(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutations = [
            (
                "canonical wire shape",
                source.replace(
                    "try encoder.encode(envelope) == data",
                    "true",
                    1,
                ),
                "try encoder.encode(envelope) == data",
            ),
            (
                "backup migration",
                source.replace(
                    "resourceValues.isExcludedFromBackup = true",
                    "resourceValues.isExcludedFromBackup = false",
                    1,
                ),
                "install-local",
            ),
            (
                "private directory",
                source.replace(
                    ".posixPermissions: 0o700",
                    ".posixPermissions: 0o755",
                    1,
                ),
                "reassert private permissions",
            ),
            (
                "recovery CAS",
                source.replace(
                    "guard wasAbsent || envelope.admission == .closed else {",
                    "guard wasAbsent else {",
                    1,
                ),
                "atomically preserve valid/open work",
            ),
            (
                "producer preflight",
                source.replace("            reloadDurableIngress()\n", "", 1),
                "durable submission must refresh",
            ),
            (
                "append authority",
                source.replace(
                    "|| envelope.authorityToken == expectedAuthorityToken,",
                    "|| true,",
                    1,
                ),
                "producer's observed authority epoch",
            ),
            (
                "atomic postcondition",
                source.replace("persisted == envelope", "true", 1),
                "persisted == envelope",
            ),
            (
                "ack authority",
                source.replace(
                    "previousAuthorityToken == snapshot.authorityToken",
                    "true",
                    1,
                ),
                "acknowledgement convergence",
            ),
            (
                "stale completion",
                source.replace(
                    "            if previousAuthorityToken != "
                    "snapshot.authorityToken {\n"
                    "                acknowledgedDeliveryToken = nil\n"
                    "                acknowledgementRetryToken = nil\n"
                    "            }\n",
                    "            if previousAuthorityToken != "
                    "snapshot.authorityToken {\n"
                    "                acknowledgementRetryToken = nil\n"
                    "            }\n",
                    1,
                ),
                "authority replacement",
            ),
            (
                "implicit reopen",
                source.replace(
                    "        revision &+= 1\n"
                    "    }\n\n"
                    "    /// Successful startup is the authority",
                    "        _ = reopenDurableAdmissionAfterAuthoritativeRecovery()\n"
                    "        revision &+= 1\n"
                    "    }\n\n"
                    "    /// Successful startup is the authority",
                    1,
                ),
                "never implicitly reopen",
            ),
        ]

        for label, mutated, expected_error in mutations:
            with self.subTest(label=label):
                self.assertNotEqual(mutated, source)
                errors = VALIDATOR.validate_shared_action_source(mutated)
                self.assertTrue(
                    any(expected_error in error for error in errors),
                    errors,
                )

    def test_rejects_success_result_without_durable_admission(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated = source.replace(
            "        guard MoneyUpQuickActionRouteBroker.shared.submit(action) else {\n"
            "            throw MoneyUpQuickActionIngressError.unavailable\n"
            "        }\n",
            "        _ = MoneyUpQuickActionRouteBroker.shared.submit(action)\n",
            1,
        )

        errors = VALIDATOR.validate_shared_action_source(mutated)

        self.assertTrue(any("durably admit" in error for error in errors), errors)

    def test_rejects_missing_cold_or_active_durable_reload(self) -> None:
        source = self.source("App/MoneyUp/MoneyUpApp.swift")
        mutations = [
            source.replace(
                "                    quickActionRouteBroker.reloadDurableIngress()\n",
                "",
                1,
            ),
            source.replace(
                "                        quickActionRouteBroker.reloadDurableIngress()\n",
                "",
                1,
            ),
        ]

        for mutated in mutations:
            self.assertNotEqual(mutated, source)
            errors = VALIDATOR.validate_app_routing_source(mutated)
            self.assertTrue(any("route gate" in error for error in errors), errors)

    def test_rejects_startup_not_reopening_crash_closed_ingress(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        mutated = lifecycle.replace(
            "        guard quickActionRouteBroker\n"
            "            .reopenDurableAdmissionAfterAuthoritativeRecovery() "
            "else { return }\n",
            "        guard false else { return }\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            model,
            mutated,
            settings,
            restore,
        )

        self.assertTrue(any("validated recovery" in error for error in errors), errors)

    def test_rejects_scene_retry_without_an_explicit_failed_ack(self) -> None:
        source = self.source("App/MoneyUp/AppModelQuickActionIngress.swift")
        mutated = source.replace(
            "              quickActionRouteBroker.needsAcknowledgementRetry(\n"
            "                  token: request.ingressToken\n"
            "              ),\n",
            "",
            1,
        )

        self.assertNotEqual(mutated, source)
        errors = VALIDATOR.validate_model_quick_action_ingress_source(mutated)
        self.assertTrue(
            any("already failed" in error for error in errors),
            errors,
        )

    def test_rejects_pending_actions_property_observer(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated = source.replace(
            "    private var pendingRecords: [MoneyUpQuickActionIngressRecord] = []\n",
            "    private var pendingRecords: [MoneyUpQuickActionIngressRecord] = [] {\n"
            "        didSet { HiddenSink.accept(pendingRecords) }\n"
            "    }\n",
            1,
        )

        errors = VALIDATOR.validate_shared_action_source(mutated)

        self.assertTrue(
            any("exact broker/intent structural contract" in error for error in errors)
        )

    def test_rejects_helpers_anywhere_in_broker_intent_or_router(self) -> None:
        shared = self.source("App/Shared/MoneyUpQuickAction.swift")
        broker_helper = shared.replace(
            "}\n\nenum MoneyUpQuickActionIngressError: Error {",
            "    private func hiddenBrokerHelper(_ action: MoneyUpQuickAction) {\n"
            "        HiddenSink.accept(action)\n"
            "    }\n"
            "}\n\nenum MoneyUpQuickActionIngressError: Error {",
            1,
        )
        intent_helper = shared.replace(
            "}\n\n// Keep the configuration conformance with the intent",
            "    private func hiddenIntentHelper() {\n"
            "        HiddenSink.accept(action)\n"
            "    }\n"
            "}\n\n// Keep the configuration conformance with the intent",
            1,
        )
        router = self.source("App/MoneyUp/MoneyUpQuickActionRouting.swift")
        router_helper = router.replace(
            "        return .requiresStart\n    }\n}",
            "        return .requiresStart\n    }\n\n"
            "    static func hiddenRouterHelper(_ action: MoneyUpQuickAction) {\n"
            "        HiddenSink.accept(action)\n"
            "    }\n}",
            1,
        )

        for mutated in (broker_helper, intent_helper):
            self.assertTrue(
                any(
                    "exact broker/intent structural contract" in error
                    for error in VALIDATOR.validate_shared_action_source(mutated)
                )
            )
        self.assertTrue(
            any(
                "exact disposition/routing structural contract" in error
                for error in VALIDATOR.validate_app_router_source(router_helper)
            )
        )

    def test_rejects_book_boundary_authority_after_busy_precheck(self) -> None:
        source = self.source("App/MoneyUp/MoneyUpQuickActionRouting.swift")
        mutated = source.replace(
            "        guard !quickActionRouteBroker.isAuthoritativeBoundaryActive,\n"
            "              !goalMutationBarrierClosed else { "
            "return .denyAuthoritatively }\n",
            "        guard !quickActionRouteBroker.isAuthoritativeBoundaryActive "
            "else { return .denyAuthoritatively }\n",
            1,
        )

        errors = VALIDATOR.validate_app_router_source(mutated)

        self.assertTrue(
            any("deny book replacement or erase" in error for error in errors)
        )

    def test_rejects_missing_key_authority_removed_from_router(self) -> None:
        source = self.source("App/MoneyUp/MoneyUpQuickActionRouting.swift")
        mutated = source.replace(
            "        guard !isBookReplacementInProgress,\n"
            "              startupFailureKind != .missingDeviceBoundKey,\n"
            "              (try? hasPendingKeyCliffRecoveryTransaction()) "
            "== false else {\n"
            "            return .denyAuthoritatively\n"
            "        }\n",
            "",
            1,
        )

        errors = VALIDATOR.validate_app_router_source(mutated)

        self.assertTrue(
            any("deny book replacement or erase" in error for error in errors),
            errors,
        )

    def test_rejects_post_dequeue_denial_without_whole_fifo_discard(self) -> None:
        source = self.source("App/MoneyUp/MoneyUpQuickActionRouting.swift")
        mutations = (
            source.replace(
                "        guard model.handleDeepLink(record.action.deepLink) else {\n"
                "            broker.discardAllPendingActions()\n"
                "            return .discarded\n"
                "        }\n",
                "        guard model.handleDeepLink(record.action.deepLink) else {\n"
                "            return .routed\n"
                "        }\n",
                1,
            ),
            source.replace(
                "        guard model.requestedQuickLogMode != nil,\n"
                "              model.requestedQuickLogRequest?.ingressToken "
                "== record.token else {\n"
                "            broker.discardAllPendingActions()\n"
                "            return .discarded\n"
                "        }\n",
                "        guard model.requestedQuickLogMode != nil,\n"
                "              model.requestedQuickLogRequest?.ingressToken "
                "== record.token else {\n"
                "            return .routed\n"
                "        }\n",
                1,
            ),
        )

        for mutated in mutations:
            errors = VALIDATOR.validate_app_router_source(mutated)
            self.assertTrue(
                any("post-dequeue authoritative denial" in error for error in errors),
                errors,
            )

    def test_rejects_capacity_paths_that_do_not_wake_strict_routing(self) -> None:
        shared = self.source("App/Shared/MoneyUpQuickAction.swift")
        muted_broker = shared.replace(
            "            apply(confirmedLoad, preservingActiveDelivery: true)\n"
            "            revision &+= 1\n"
            "            return wasAccepted\n",
            "            apply(confirmedLoad, preservingActiveDelivery: true)\n"
            "            return wasAccepted\n",
            1,
        )
        app = self.source("App/MoneyUp/MoneyUpApp.swift")
        muted_app = app.replace(
            "        guard let action = MoneyUpQuickAction(exactDeepLink: url) "
            "else { return }\n"
            "        _ = quickActionRouteBroker.submit(action)\n"
            "        routePendingQuickAction()\n",
            "        guard let action = MoneyUpQuickAction(exactDeepLink: url),\n"
            "              quickActionRouteBroker.submit(action) else { return }\n"
            "        routePendingQuickAction()\n",
            1,
        )

        self.assertNotEqual(muted_broker, shared)

        self.assertTrue(
            any(
                "exact broker/intent structural contract" in error
                for error in VALIDATOR.validate_shared_action_source(muted_broker)
            )
        )
        self.assertTrue(
            any(
                "including at FIFO capacity" in error
                for error in VALIDATOR.validate_app_routing_source(muted_app)
            )
        )

    def test_rejects_unbalanced_erase_boundary_lifecycle(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        mutated_settings = settings.replace(
            "        defer {\n"
            "            finishQuickActionBoundary(\n"
            "                quickActionBoundaryEpoch,\n"
            "                validatedRecovery: quickActionRecoveryWasValidated\n"
            "            )\n"
            "        }\n",
            "        defer { quickActionRouteBroker.discardAllPendingActions() }\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            model,
            lifecycle,
            mutated_settings,
            restore,
        )

        self.assertTrue(any("defer-balance" in error for error in errors))

    def test_rejects_shared_restore_validation_broker(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        mutated_model = model.replace(
            "        quickActionRouteBroker = MoneyUpQuickActionRouteBroker()\n",
            "        quickActionRouteBroker = .shared\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            mutated_model,
            lifecycle,
            settings,
            restore,
        )

        self.assertTrue(
            any("restore validation" in error for error in errors)
        )

    def test_rejects_missing_startup_tombstone_boundary(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        mutated_lifecycle = lifecycle.replace(
            "                return (\n"
            "                    .failure(inspectionError),\n"
            "                    try beginAuthoritativeQuickActionBoundary()\n"
            "                )\n",
            "                return (.failure(inspectionError), nil)\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            model,
            mutated_lifecycle,
            settings,
            restore,
        )

        self.assertTrue(
            any("pending and unreadable" in error for error in errors)
        )

    def test_rejects_startup_tombstone_inspection_after_suspension(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        inspection = (
            "        let dataEraseInspection = await inspectDataEraseIntent()\n"
            "        quickActionBoundaryEpoch = dataEraseInspection.boundaryEpoch\n"
            "        await lifecycleHooks.checkpoint(.afterStartupTombstoneInspection)\n"
            "        await closeStoreBeforeStartup()\n"
        )
        mutated_lifecycle = lifecycle.replace(
            inspection,
            "        await closeStoreBeforeStartup()\n"
            "        let dataEraseInspection = await inspectDataEraseIntent()\n"
            "        quickActionBoundaryEpoch = dataEraseInspection.boundaryEpoch\n"
            "        await lifecycleHooks.checkpoint(.afterStartupTombstoneInspection)\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            model,
            mutated_lifecycle,
            settings,
            restore,
        )

        self.assertTrue(any("later suspension" in error for error in errors))

    def test_rejects_boundary_that_leaves_occupied_ui_request_alive(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        mutated_model = model.replace(
            "                requestedQuickLogRequest = nil\n"
            "                presentedQuickLogRequest = nil\n",
            "                requestedQuickLogRequest = nil\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            mutated_model,
            lifecycle,
            settings,
            restore,
        )

        self.assertTrue(any("AppModel request setter" in error for error in errors))

    def test_rejects_unversioned_locked_and_main_tab_handoffs(self) -> None:
        root = self.source("App/MoneyUp/RootView.swift")
        locked = self.source("App/MoneyUp/LockedQuickCaptureView.swift")
        mutated_root = root.replace("                        .id(request.id)\n", "", 1)
        mutated_locked = locked.replace(
            "model.consumeQuickLogRequest(request)",
            "model.consumeQuickLogRequest(mode)",
            1,
        )

        self.assertTrue(
            any(
                "generation-bound handoff" in error
                for error in VALIDATOR.validate_root_handoff_source(mutated_root)
            )
        )
        self.assertTrue(
            any(
                "acknowledge the exact request" in error
                for error in VALIDATOR.validate_locked_handoff_source(mutated_locked)
            )
        )

    def test_rejects_restore_cleanup_installed_after_suspension(self) -> None:
        model = self.source("App/MoneyUp/AppModel.swift")
        lifecycle = self.source("App/MoneyUp/AppModelLifecycle.swift")
        settings = self.source("App/MoneyUp/AppModelSettings.swift")
        restore = self.source("App/MoneyUp/AppModelBackupRestore.swift")
        original = (
            "        defer {\n"
            "            finishBookReplacementMutation()\n"
            "            finishQuickActionBoundary(\n"
            "                quickActionBoundaryEpoch,\n"
            "                validatedRecovery: quickActionRecoveryWasValidated\n"
            "            )\n"
            "        }\n"
            "        await finishBeginningRestoreMutation()\n"
        )
        mutated_restore = restore.replace(
            original,
            "        await finishBeginningRestoreMutation()\n"
            "        defer {\n"
            "            finishBookReplacementMutation()\n"
            "            finishQuickActionBoundary(\n"
            "                quickActionBoundaryEpoch,\n"
            "                validatedRecovery: quickActionRecoveryWasValidated\n"
            "            )\n"
            "        }\n",
            1,
        )
        self.assertNotEqual(mutated_restore, restore)

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            model,
            lifecycle,
            settings,
            mutated_restore,
        )

        self.assertTrue(
            any("every success, error" in error for error in errors)
        )

    def test_rejects_unbalanced_production_book_replacement_boundaries(self) -> None:
        preview = self.source("App/MoneyUp/AppModelRestorePreview.swift")
        key_cliff = self.source("App/MoneyUp/AppModelKeyCliffRecovery.swift")
        preview_cleanup = (
            "        defer {\n"
            "            finishBookReplacementMutation()\n"
            "            finishQuickActionBoundary(\n"
            "                quickActionBoundaryEpoch,\n"
            "                validatedRecovery: quickActionRecoveryWasValidated\n"
            "            )\n"
            "        }\n"
        )
        key_cliff_cleanup = preview_cleanup
        mutation = (
            "        defer {\n"
            "            finishBookReplacementMutation()\n"
            "        }\n"
        )
        mutated_preview = preview.replace(preview_cleanup, mutation, 1)
        mutated_key_cliff = key_cliff.replace(key_cliff_cleanup, mutation, 1)
        self.assertNotEqual(mutated_preview, preview)
        self.assertNotEqual(mutated_key_cliff, key_cliff)

        preview_errors = VALIDATOR.validate_book_replacement_action_boundaries(
            mutated_preview,
            key_cliff,
        )
        key_cliff_errors = VALIDATOR.validate_book_replacement_action_boundaries(
            preview,
            mutated_key_cliff,
        )

        self.assertTrue(any("ticket restore" in error for error in preview_errors))
        self.assertTrue(
            any("missing-key recovery" in error for error in key_cliff_errors)
        )

    def test_rejects_resumed_startup_boundary_drift(self) -> None:
        preview = self.source("App/MoneyUp/AppModelRestorePreview.swift")
        key_cliff = self.source("App/MoneyUp/AppModelKeyCliffRecovery.swift")
        deferred_cleanup = (
            "        defer {\n"
            "            finishQuickActionBoundary(\n"
            "                quickActionBoundaryEpoch,\n"
            "                validatedRecovery: quickActionRecoveryWasValidated\n"
            "            )\n"
            "        }\n"
        )
        resume_work = (
            "            try KeyCliffRecoveryTransaction.installCandidate("
            "for: databaseURL)\n"
        )
        mutations = [
            key_cliff.replace(
                "        let quickActionBoundaryEpoch = "
                "try quickActionBoundaryForKeyCliffResume(\n"
                "            isResuming\n"
                "        )\n",
                "        let quickActionBoundaryEpoch: UInt64? = nil\n",
                1,
            ),
            key_cliff.replace(deferred_cleanup, "", 1),
            key_cliff.replace(deferred_cleanup, "", 1).replace(
                resume_work,
                resume_work + deferred_cleanup,
                1,
            ),
        ]

        for mutated in mutations:
            self.assertNotEqual(mutated, key_cliff)
            errors = VALIDATOR.validate_book_replacement_action_boundaries(
                preview,
                mutated,
            )
            self.assertTrue(
                any("resumed startup" in error for error in errors),
                errors,
            )


if __name__ == "__main__":
    unittest.main()
