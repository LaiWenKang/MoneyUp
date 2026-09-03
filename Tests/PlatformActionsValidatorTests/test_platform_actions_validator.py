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

        self.assertTrue(any("request setter must remain" in error for error in errors))

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

    def test_rejects_broker_payload_or_missing_warm_route(self) -> None:
        shared = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated_shared = shared.replace(
            "    private(set) var revision: UInt64 = 0\n",
            "    private(set) var revision: UInt64 = 0\n"
            "    var note: String\n",
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
                "action FIFO, boundary epochs" in error
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
            "        pendingActions.append(action)\n",
            "        pendingActions.append(action)\n"
            "        try? action.rawValue.write(\n"
            '            toFile: "/tmp/moneyup-route",\n'
            "            atomically: true,\n"
            "            encoding: .utf8\n"
            "        )\n",
            1,
        )

        errors = VALIDATOR.validate_shared_action_source(mutated)

        self.assertTrue(any("file persistence" in error for error in errors))
        self.assertTrue(any("submit must remain" in error for error in errors))

    def test_rejects_pending_actions_property_observer(self) -> None:
        source = self.source("App/Shared/MoneyUpQuickAction.swift")
        mutated = source.replace(
            "    private var pendingActions: [MoneyUpQuickAction] = []\n",
            "    private var pendingActions: [MoneyUpQuickAction] = [] {\n"
            "        didSet { HiddenSink.accept(pendingActions) }\n"
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
            "}\n\n/// Opens the app and hands off one allowlisted action in memory.",
            "    private func hiddenBrokerHelper(_ action: MoneyUpQuickAction) {\n"
            "        HiddenSink.accept(action)\n"
            "    }\n"
            "}\n\n/// Opens the app and hands off one allowlisted action in memory.",
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
                "        guard model.handleDeepLink(action.deepLink) else {\n"
                "            broker.discardAllPendingActions()\n"
                "            return .discarded\n"
                "        }\n",
                "        guard model.handleDeepLink(action.deepLink) else {\n"
                "            return .routed\n"
                "        }\n",
                1,
            ),
            source.replace(
                "        guard model.requestedQuickLogMode != nil else {\n"
                "            broker.discardAllPendingActions()\n"
                "            return .discarded\n"
                "        }\n",
                "        guard model.requestedQuickLogMode != nil else {\n"
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
            "        guard pendingActions.count < Self.maximumPendingActionCount "
            "else {\n"
            "            revision &+= 1\n"
            "            return false\n"
            "        }\n",
            "        guard pendingActions.count < Self.maximumPendingActionCount "
            "else {\n"
            "            return false\n"
            "        }\n",
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

        self.assertTrue(
            any(
                "wake routing after a capacity rejection" in error
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
            "            quickActionRouteBroker.endAuthoritativeBoundary("
            "quickActionBoundaryEpoch)\n",
            "            quickActionRouteBroker.discardAllPendingActions()\n",
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
            "        } catch {\n"
            "            return (\n"
            "                .failure(error),\n"
            "                beginAuthoritativeQuickActionBoundary()\n"
            "            )\n",
            "        } catch {\n"
            "            return (.failure(error), nil)\n",
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
            "        await closeStoreBeforeStartup()\n"
        )
        mutated_lifecycle = lifecycle.replace(
            inspection,
            "        await closeStoreBeforeStartup()\n"
            "        let dataEraseInspection = await inspectDataEraseIntent()\n"
            "        quickActionBoundaryEpoch = dataEraseInspection.boundaryEpoch\n",
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
        mutated_lifecycle = lifecycle.replace(
            "        requestedQuickLogMode = nil\n"
            "        presentedQuickLogRequest = nil\n"
            "        return epoch\n",
            "        requestedQuickLogMode = nil\n"
            "        return epoch\n",
            1,
        )

        errors = VALIDATOR.validate_boundary_lifecycle_sources(
            model,
            mutated_lifecycle,
            settings,
            restore,
        )

        self.assertTrue(any("occupied UI request" in error for error in errors))

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
            "            quickActionRouteBroker.endAuthoritativeBoundary(\n"
            "                quickActionBoundaryEpoch\n"
            "            )\n"
            "        }\n"
            "        await finishBeginningRestoreMutation()\n"
        )
        mutated_restore = restore.replace(
            original,
            "        await finishBeginningRestoreMutation()\n"
            "        defer {\n"
            "            finishBookReplacementMutation()\n"
            "            quickActionRouteBroker.endAuthoritativeBoundary(\n"
            "                quickActionBoundaryEpoch\n"
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
        end = (
            "            quickActionRouteBroker.endAuthoritativeBoundary(\n"
            "                quickActionBoundaryEpoch\n"
            "            )\n"
        )
        mutated_preview = preview.replace(end, "", 1)
        mutated_key_cliff = key_cliff.replace(end, "", 1)
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
        resume_end = (
            "                quickActionRouteBroker.endAuthoritativeBoundary(\n"
            "                    quickActionBoundaryEpoch\n"
            "                )\n"
        )
        deferred_cleanup = (
            "        defer {\n"
            "            if let quickActionBoundaryEpoch {\n"
            f"{resume_end}"
            "            }\n"
            "        }\n"
        )
        resume_work = (
            "            try KeyCliffRecoveryTransaction.installCandidate("
            "for: databaseURL)\n"
        )
        mutations = [
            key_cliff.replace(
                "            quickActionBoundaryEpoch = "
                "beginAuthoritativeQuickActionBoundary()\n",
                "            quickActionBoundaryEpoch = nil\n",
                1,
            ),
            key_cliff.replace(resume_end, "", 1),
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
