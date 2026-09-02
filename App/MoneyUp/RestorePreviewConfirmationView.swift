import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI

struct RestorePreviewConfirmationView: View {
    let preview: RestorePreview
    let isWorking: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var currentSummary: RestorePreview.BookSummary? {
        preview.current.availableSummary
    }

    private var isKeyCliffRecovery: Bool {
        currentSummary == nil
    }

    private var confirmationTitleKey: LocalizedStringKey {
        isKeyCliffRecovery
            ? "recovery.key_cliff.confirm_title"
            : "restore.preview.title"
    }

    private var confirmationActionKey: LocalizedStringKey {
        isKeyCliffRecovery
            ? "recovery.key_cliff.confirm_action"
            : "restore.confirm"
    }

    private var replacementDetailKey: LocalizedStringKey {
        isKeyCliffRecovery
            ? "recovery.key_cliff.confirm_detail"
            : "restore.preview.replacement_detail"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        "restore.preview.validated",
                        systemImage: "checkmark.shield.fill"
                    )
                    .foregroundStyle(.green)
                    LabeledContent(
                        "restore.preview.archive_format",
                        value: String(preview.archiveFormatVersion)
                    )
                    LabeledContent(
                        "restore.preview.archive_schema",
                        value: String(preview.archiveSchemaVersion)
                    )
                }

                replacementSection
                candidateDetailsSection

                Section {
                    Label(
                        "restore.preview.safety",
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(confirmationTitleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel", action: onCancel)
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmationActionKey, role: .destructive) {
                        onConfirm()
                    }
                    .disabled(isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("action.working")
                        .padding()
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private var replacementSection: some View {
        Section {
            if currentSummary == nil {
                Label(
                    "restore.preview.current_inaccessible",
                    systemImage: "key.slash.fill"
                )
                .foregroundStyle(.orange)
            }
            countChangeRow(
                "restore.preview.total_records",
                current: currentSummary?.totalStoredRecordCount,
                candidate: preview.candidate.totalStoredRecordCount
            )
            countChangeRow(
                "restore.preview.entries",
                current: currentSummary?.storedRecordCount(in: .journalEntries),
                candidate: preview.candidate.storedRecordCount(in: .journalEntries)
            )
            countChangeRow(
                "restore.preview.accounts",
                current: currentSummary?.storedRecordCount(in: .accounts),
                candidate: preview.candidate.storedRecordCount(in: .accounts)
            )
            countChangeRow(
                "restore.preview.quarantined",
                current: currentSummary?.quarantinedRecordCount,
                candidate: preview.candidate.quarantinedRecordCount
            )
        } header: {
            Text("restore.preview.replacement")
        } footer: {
            Text(replacementDetailKey)
        }
    }

    private var candidateDetailsSection: some View {
        Section {
            detailChangeRow(
                "restore.preview.date_range",
                current: currentSummary.map {
                    RestorePreviewPresentation.dateSpanSummary(for: $0)
                } ?? AppLocalization.string("restore.preview.inaccessible"),
                candidate: RestorePreviewPresentation.dateSpanSummary(
                    for: preview.candidate
                )
            )
            if let currentSummary {
                currencyDisclosure(
                    title: String(
                        format: AppLocalization.string(
                            "restore.preview.current_currencies"
                        ),
                        currentSummary.currencies.count
                    ),
                    currencies: currentSummary.currencies
                )
            } else {
                LabeledContent(
                    "restore.preview.current_currencies_label",
                    value: AppLocalization.string("restore.preview.inaccessible")
                )
            }
            currencyDisclosure(
                title: String(
                    format: AppLocalization.string(
                        "restore.preview.backup_currencies"
                    ),
                    preview.candidate.currencies.count
                ),
                currencies: preview.candidate.currencies
            )
            DisclosureGroup("restore.preview.collection_counts") {
                ForEach(RecordCollection.allCases, id: \.rawValue) { collection in
                    countChangeRow(
                        collection.localizationKey,
                        current: currentSummary?.storedRecordCount(in: collection),
                        candidate: preview.candidate.storedRecordCount(in: collection)
                    )
                }
            }
        } header: {
            Text("restore.preview.backup_details")
        }
    }

    private func countChangeRow(
        _ key: LocalizedStringKey,
        current: Int?,
        candidate: Int
    ) -> some View {
        let currentText = current.map { String($0) }
            ?? AppLocalization.string("restore.preview.inaccessible")
        let accessibilityValue = current.map {
            String(
                format: AppLocalization.string("restore.preview.count_change"),
                $0,
                candidate
            )
        } ?? String(
            format: AppLocalization.string("restore.preview.value_change"),
            currentText,
            String(candidate)
        )
        return LabeledContent(key, value: "\(currentText) → \(candidate)")
            .accessibilityValue(
                accessibilityValue
            )
    }

    private func detailChangeRow(
        _ key: LocalizedStringKey,
        current: String,
        candidate: String
    ) -> some View {
        LabeledContent(key) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(
                    format: AppLocalization.string("restore.preview.current_value"),
                    current
                ))
                Text(String(
                    format: AppLocalization.string("restore.preview.backup_value"),
                    candidate
                ))
            }
            .font(.subheadline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key)
        .accessibilityValue(String(
            format: AppLocalization.string("restore.preview.value_change"),
            current,
            candidate
        ))
    }

    private func currencyDisclosure(
        title: String,
        currencies: [CurrencyCode]
    ) -> some View {
        DisclosureGroup {
            if currencies.isEmpty {
                Text("restore.preview.none")
            } else {
                ForEach(currencies, id: \.self) { currency in
                    Text(currency.value)
                        .accessibilityLabel(currency.value)
                }
            }
        } label: {
            Text(title)
        }
        .accessibilityHint("restore.preview.currency_disclosure_hint")
    }
}

enum RestorePreviewPresentation {
    static func dateSpanSummary(
        for book: RestorePreview.BookSummary,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let span = book.entryDateSpan else {
            return AppLocalization.string("restore.preview.none")
        }
        let calendar = FinancialPeriodBoundary.gregorianCalendar(
            timeZoneIdentifier: book.reportingTimeZoneIdentifier
        )
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            .locale(locale)
        return span.oldest.formattedForReporting(style, calendar: calendar)
            + " – "
            + span.newest.formattedForReporting(style, calendar: calendar)
    }
}

private extension RecordCollection {
    var localizationKey: LocalizedStringKey {
        switch self {
        case .profile: "restore.collection.profile"
        case .accounts: "restore.collection.accounts"
        case .journalEntries: "restore.collection.journal_entries"
        case .journalEntryRevisions:
            "restore.collection.journal_entry_revisions"
        case .budgetNodes: "restore.collection.budget_nodes"
        case .scheduledTransactions:
            "restore.collection.scheduled_transactions"
        case .investmentHoldings: "restore.collection.investment_holdings"
        case .netWorthSnapshots: "restore.collection.net_worth_snapshots"
        case .quickLogDrafts: "restore.collection.quick_log_drafts"
        case .accountLifecycleAudit:
            "restore.collection.account_lifecycle_audit"
        case .receiptAttachments: "restore.collection.receipt_attachments"
        case .exchangeRates: "restore.collection.exchange_rates"
        case .savingsGoals: "restore.collection.savings_goals"
        case .loanPlans: "restore.collection.loan_plans"
        case .allowancePlans: "restore.collection.allowance_plans"
        case .budgetConfigurationTimelines:
            "restore.collection.budget_configuration_timelines"
        case .budgetEntryAttributions:
            "restore.collection.budget_entry_attributions"
        }
    }
}
