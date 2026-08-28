# MoneyUp 0.6.0 File Review Inventory

Reviewed: 28 August 2026

This is the closed inventory for the comprehensive audit and completion pass.
It lists every file tracked in the review branch. The 189 paths below reconcile
to the candidate tree.
A listed file is in scope; it does not imply that macOS compilation, physical
behavior, or release acceptance passed.

## Review treatment

| File class | Checks applied | Evidence limit |
|---|---|---|
| App/core/persistence Swift | Full-repository lexical checks; manual caller/callee and state/persistence tracing; requirement/test mapping; boundary/error/race review | Exact-candidate Swift/Xcode execution is pending |
| Test Swift | Declaration inventory; requirement/finding mapping; assertion and failure-injection review | 514 declarations exist; none ran here |
| JSON, xcstrings, plist, privacy, entitlements, YAML | Parser validation, release-validator checks, identifier/localization/privacy/capability consistency | Signed entitlements and exact binary remain physical/release gates |
| PNG/assets | Asset-catalog parse, icon/brand/palette validator, required scale/appearance inventory | Device rendering remains open |
| Python/scripts | Static inspection plus release-validator/fixture workflow execution where applicable | macOS-only built-bundle validator remains open |
| Markdown/legal/release docs | Authority, requirement, privacy/security, support, migration, and promotion consistency review; relative-link validation | Operational checklists are not execution results |
| Package/project/license files | Dependency pin/provenance/license, target/source membership, version/build, capability, and offline-boundary review | SBOM/CVE and macOS resolution remain open |

File-specific findings are recorded in
[QUALITY_AUDIT_0.6.0.md](QUALITY_AUDIT_0.6.0.md); requirement evidence is in
[REQUIREMENTS_TEST_MATRIX.md](REQUIREMENTS_TEST_MATRIX.md).

## Complete candidate-file manifest (189)

```text
.github/dependabot.yml
.github/workflows/ci.yml
.github/workflows/testflight.yml
.gitignore
App/MoneyUp/AccountInput.swift
App/MoneyUp/AppModel.swift
App/MoneyUp/AppModelDependencies.swift
App/MoneyUp/AppSettingsView.swift
App/MoneyUp/AppVersion.swift
App/MoneyUp/Assets.xcassets/AccentColor.colorset/Contents.json
App/MoneyUp/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png
App/MoneyUp/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png
App/MoneyUp/Assets.xcassets/AppIcon.appiconset/AppIcon.png
App/MoneyUp/Assets.xcassets/AppIcon.appiconset/Contents.json
App/MoneyUp/Assets.xcassets/BrandAction.colorset/Contents.json
App/MoneyUp/Assets.xcassets/BrandBackground.colorset/Contents.json
App/MoneyUp/Assets.xcassets/BrandMist.colorset/Contents.json
App/MoneyUp/Assets.xcassets/BrandSurface.colorset/Contents.json
App/MoneyUp/Assets.xcassets/BrandSurfaceElevated.colorset/Contents.json
App/MoneyUp/Assets.xcassets/Contents.json
App/MoneyUp/Assets.xcassets/MoneyUpBrandMark.imageset/Contents.json
App/MoneyUp/Assets.xcassets/MoneyUpBrandMark.imageset/MoneyUpBrandMark.png
App/MoneyUp/Assets.xcassets/MoneyUpBrandMark.imageset/MoneyUpBrandMark@2x.png
App/MoneyUp/Assets.xcassets/MoneyUpBrandMark.imageset/MoneyUpBrandMark@3x.png
App/MoneyUp/Assets.xcassets/MoneyUpMoneyWorld.imageset/Contents.json
App/MoneyUp/Assets.xcassets/MoneyUpMoneyWorld.imageset/MoneyUpMoneyWorld-Dark.png
App/MoneyUp/Assets.xcassets/MoneyUpMoneyWorld.imageset/MoneyUpMoneyWorld-Dark@2x.png
App/MoneyUp/Assets.xcassets/MoneyUpMoneyWorld.imageset/MoneyUpMoneyWorld-Dark@3x.png
App/MoneyUp/Assets.xcassets/MoneyUpMoneyWorld.imageset/MoneyUpMoneyWorld.png
App/MoneyUp/Assets.xcassets/MoneyUpMoneyWorld.imageset/MoneyUpMoneyWorld@2x.png
App/MoneyUp/Assets.xcassets/MoneyUpMoneyWorld.imageset/MoneyUpMoneyWorld@3x.png
App/MoneyUp/Assets.xcassets/MoneyUpScenarioStudio.imageset/Contents.json
App/MoneyUp/Assets.xcassets/MoneyUpScenarioStudio.imageset/MoneyUpScenarioStudio-Dark.png
App/MoneyUp/Assets.xcassets/MoneyUpScenarioStudio.imageset/MoneyUpScenarioStudio-Dark@2x.png
App/MoneyUp/Assets.xcassets/MoneyUpScenarioStudio.imageset/MoneyUpScenarioStudio-Dark@3x.png
App/MoneyUp/Assets.xcassets/MoneyUpScenarioStudio.imageset/MoneyUpScenarioStudio.png
App/MoneyUp/Assets.xcassets/MoneyUpScenarioStudio.imageset/MoneyUpScenarioStudio@2x.png
App/MoneyUp/Assets.xcassets/MoneyUpScenarioStudio.imageset/MoneyUpScenarioStudio@3x.png
App/MoneyUp/AssetsView.swift
App/MoneyUp/BoundedFileReader.swift
App/MoneyUp/CSVDocument.swift
App/MoneyUp/CSVImportNameResolver.swift
App/MoneyUp/CalendarView.swift
App/MoneyUp/CurrencyPicker.swift
App/MoneyUp/DashboardView.swift
App/MoneyUp/DataSafetyView.swift
App/MoneyUp/DatabaseKeyStore.swift
App/MoneyUp/DerivedValue.swift
App/MoneyUp/DisplayFormatting.swift
App/MoneyUp/ExchangeRatesView.swift
App/MoneyUp/HistoryView.swift
App/MoneyUp/ImportTransactionsView.swift
App/MoneyUp/InsightsView.swift
App/MoneyUp/LedgerLifecycleViews.swift
App/MoneyUp/LedgerPortabilityErrors.swift
App/MoneyUp/LockedCaptureStore.swift
App/MoneyUp/LockedQuickCaptureView.swift
App/MoneyUp/MoneyAmountKeyboard.swift
App/MoneyUp/MoneyUp.entitlements
App/MoneyUp/MoneyUpApp.swift
App/MoneyUp/MoneyUpArchive.swift
App/MoneyUp/MoneyUpTheme.swift
App/MoneyUp/MoneyUpVisuals.swift
App/MoneyUp/OnboardingView.swift
App/MoneyUp/PlanView.swift
App/MoneyUp/PrivacyAndBetaView.swift
App/MoneyUp/PrivacyInfo.xcprivacy
App/MoneyUp/PrivacySafeDataInventory.swift
App/MoneyUp/QuickLogDraft.swift
App/MoneyUp/QuickLogLaunchMode.swift
App/MoneyUp/QuickLogSheet.swift
App/MoneyUp/ReceiptImageSanitizer.swift
App/MoneyUp/ReceiptScanner.swift
App/MoneyUp/ReceiptThumbnailDecoder.swift
App/MoneyUp/ReportingDateFormatting.swift
App/MoneyUp/Resources/Localizable.xcstrings
App/MoneyUp/RestoreCandidateValidator.swift
App/MoneyUp/RootView.swift
App/MoneyUp/SafeLocalizedErrors.swift
App/MoneyUp/SavingsGoalsView.swift
App/MoneyUp/TransactionRow.swift
App/MoneyUp/UnlockMethod.swift
App/MoneyUp/XLSXDocument.swift
App/MoneyUp/en.lproj/InfoPlist.strings
App/MoneyUp/zh-Hans.lproj/InfoPlist.strings
App/MoneyUpWidget/Assets.xcassets/Contents.json
App/MoneyUpWidget/Assets.xcassets/MoneyUpBrandMark.imageset/Contents.json
App/MoneyUpWidget/Assets.xcassets/MoneyUpBrandMark.imageset/MoneyUpBrandMark.png
App/MoneyUpWidget/Assets.xcassets/MoneyUpBrandMark.imageset/MoneyUpBrandMark@2x.png
App/MoneyUpWidget/Assets.xcassets/MoneyUpBrandMark.imageset/MoneyUpBrandMark@3x.png
App/MoneyUpWidget/Localizable.xcstrings
App/MoneyUpWidget/MoneyUpWidget.entitlements
App/MoneyUpWidget/MoneyUpWidget.swift
App/Shared/BudgetWidgetSnapshot.swift
LICENSE
PRIVACY.md
Package.swift
README.md
SECURITY.md
SUPPORT.md
Scripts/generate_brand_icons.py
Scripts/generate_release_fixture.py
Scripts/validate_built_bundle.py
Scripts/validate_release_assets.py
Sources/MoneyUpCore/BudgetRollover.swift
Sources/MoneyUpCore/BudgetTree.swift
Sources/MoneyUpCore/CategorySuggester.swift
Sources/MoneyUpCore/CheckedDecimal.swift
Sources/MoneyUpCore/CurrencyCode.swift
Sources/MoneyUpCore/FinanceCalculator.swift
Sources/MoneyUpCore/FinancialGuidance.swift
Sources/MoneyUpCore/FinancialPeriodBoundary.swift
Sources/MoneyUpCore/HistoryQuery.swift
Sources/MoneyUpCore/InvestmentHolding.swift
Sources/MoneyUpCore/InvestmentLedgerIntegrity.swift
Sources/MoneyUpCore/JournalEntry.swift
Sources/MoneyUpCore/LedgerAccount.swift
Sources/MoneyUpCore/LedgerAccountLifecycle.swift
Sources/MoneyUpCore/LedgerCSVExporter.swift
Sources/MoneyUpCore/LedgerPortability.swift
Sources/MoneyUpCore/LedgerPostingEvent.swift
Sources/MoneyUpCore/LedgerXLSXExporter.swift
Sources/MoneyUpCore/MonetaryInputPolicy.swift
Sources/MoneyUpCore/Money.swift
Sources/MoneyUpCore/NaturalLanguageEntryParser.swift
Sources/MoneyUpCore/NetWorthSnapshot.swift
Sources/MoneyUpCore/PeriodReport.swift
Sources/MoneyUpCore/Posting.swift
Sources/MoneyUpCore/ReceiptAttachment.swift
Sources/MoneyUpCore/ReceiptTextParser.swift
Sources/MoneyUpCore/ReportBuilder.swift
Sources/MoneyUpCore/SavingsGoal.swift
Sources/MoneyUpCore/ScheduledTransaction.swift
Sources/MoneyUpCore/TextScanning.swift
Sources/MoneyUpCore/TransactionCSVImporter.swift
Sources/MoneyUpCore/TransactionDraft.swift
Sources/MoneyUpCore/TransactionFactory.swift
Sources/MoneyUpCore/UserProfile.swift
Sources/MoneyUpPersistence/EncryptedRecordStore.swift
Sources/MoneyUpPersistence/PersistenceError.swift
Sources/MoneyUpPersistence/PortableArchive.swift
Sources/MoneyUpPersistence/PortableArchiveV2.swift
Sources/MoneyUpPersistence/RecordCollection.swift
Sources/MoneyUpPersistence/RecordWrite.swift
THIRD_PARTY_NOTICES.md
Tests/MoneyUpAppTests/AppModelTests.swift
Tests/MoneyUpAppTests/CSVImportNameResolverTests.swift
Tests/MoneyUpAppTests/InsightsCategoryBucketTests.swift
Tests/MoneyUpAppTests/ReceiptImageSanitizerTests.swift
Tests/MoneyUpAppTests/ReceiptThumbnailDecoderTests.swift
Tests/MoneyUpCoreTests/BudgetRolloverTests.swift
Tests/MoneyUpCoreTests/BudgetTreeTests.swift
Tests/MoneyUpCoreTests/CheckedDecimalTests.swift
Tests/MoneyUpCoreTests/FinanceCalculatorTests.swift
Tests/MoneyUpCoreTests/FinancialGuidanceTests.swift
Tests/MoneyUpCoreTests/FinancialPeriodBoundaryTests.swift
Tests/MoneyUpCoreTests/HistoryQueryTests.swift
Tests/MoneyUpCoreTests/InvestmentPortfolioTests.swift
Tests/MoneyUpCoreTests/JournalEntryTests.swift
Tests/MoneyUpCoreTests/LedgerAccountLifecycleTests.swift
Tests/MoneyUpCoreTests/LedgerAccountTests.swift
Tests/MoneyUpCoreTests/LedgerCSVExporterTests.swift
Tests/MoneyUpCoreTests/LedgerPortabilityTests.swift
Tests/MoneyUpCoreTests/MoneyTests.swift
Tests/MoneyUpCoreTests/PeriodReportTests.swift
Tests/MoneyUpCoreTests/ReceiptAttachmentTests.swift
Tests/MoneyUpCoreTests/ReceiptTextParserTests.swift
Tests/MoneyUpCoreTests/SavingsGoalTests.swift
Tests/MoneyUpCoreTests/ScheduledAndHoldingTests.swift
Tests/MoneyUpCoreTests/SmartEntryTests.swift
Tests/MoneyUpCoreTests/TransactionCSVImporterTests.swift
Tests/MoneyUpCoreTests/TransactionFactoryTests.swift
Tests/MoneyUpCoreTests/UserProfileMigrationTests.swift
Tests/MoneyUpPersistenceTests/EncryptedRecordStoreTests.swift
docs/APPLE_SETUP.md
docs/APP_STORE_SUBMISSION.md
docs/ARCHITECTURE.md
docs/BETA_INSTALL.md
docs/DATA_MODEL.md
docs/FILE_REVIEW_INVENTORY.md
docs/FIRST_TEST.md
docs/GOLDEN_TRACEABILITY.md
docs/LAUNCH_PLAN.md
docs/PRODUCT.md
docs/QUALITY_AUDIT_0.6.0.md
docs/REQUIREMENTS_TEST_MATRIX.md
docs/ROADMAP.md
docs/VISUAL_SYSTEM.md
project.yml
```
