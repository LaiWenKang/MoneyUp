import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UIKit

struct EditableEntryValues {
    let kind: QuickLogKind
    let amount: Decimal
    let destinationAmount: Decimal?
    let accountID: UUID
    let destinationAccountID: UUID?
    let categoryID: UUID?
    let splitLines: [QuickLogSplitDraftLine]

    init?(entry: JournalEntry, accounts: [LedgerAccount]) {
        let userIDs = Set(accounts.filter {
            ($0.kind == .asset || $0.kind == .liability)
                && $0.systemRole == nil
        }.map(\.id))
        let expenseIDs = Set(accounts.filter {
            $0.kind == .expense && $0.systemRole == nil
        }.map(\.id))
        let incomeIDs = Set(accounts.filter {
            $0.kind == .income && $0.systemRole == nil
        }.map(\.id))

        switch entry.kind {
        case .expense:
            let categories = entry.postings.filter { expenseIDs.contains($0.accountID) }
            guard let category = categories.first, let account = entry.postings.first(where: {
                userIDs.contains($0.accountID)
            }), let combinedAmount = try? Self.total(of: categories) else { return nil }
            kind = category.money.amount < .zero ? .refund : .expense
            amount = combinedAmount
            destinationAmount = nil
            accountID = account.accountID
            destinationAccountID = nil
            categoryID = category.accountID
            splitLines = categories.count > 1 ? categories.map {
                QuickLogSplitDraftLine(
                    id: $0.id,
                    categoryID: $0.accountID,
                    amountText: editableAmount(abs($0.money.amount)),
                    memo: $0.memo ?? ""
                )
            } : []
        case .income:
            let categories = entry.postings.filter { incomeIDs.contains($0.accountID) }
            guard let category = categories.first, let account = entry.postings.first(where: {
                userIDs.contains($0.accountID)
            }), let combinedAmount = try? Self.total(of: categories) else { return nil }
            kind = .income
            amount = combinedAmount
            destinationAmount = nil
            accountID = account.accountID
            destinationAccountID = nil
            categoryID = category.accountID
            splitLines = categories.count > 1 ? categories.map {
                QuickLogSplitDraftLine(
                    id: $0.id,
                    categoryID: $0.accountID,
                    amountText: editableAmount(abs($0.money.amount)),
                    memo: $0.memo ?? ""
                )
            } : []
        case .transfer:
            let userPostings = entry.postings.filter { userIDs.contains($0.accountID) }
            guard let source = userPostings.first(where: { $0.money.amount < .zero }),
                  let destination = userPostings.first(where: { $0.money.amount > .zero })
            else { return nil }
            kind = .transfer
            amount = abs(source.money.amount)
            destinationAmount = abs(destination.money.amount)
            accountID = source.accountID
            destinationAccountID = destination.accountID
            categoryID = nil
            splitLines = []
        case .adjustment, .investment:
            return nil
        }
    }

    private static func total(of postings: [Posting]) throws -> Decimal {
        var result = Decimal.zero
        for posting in postings {
            result = try CheckedDecimal.adding(
                result,
                abs(posting.money.amount)
            )
        }
        return result
    }
}

struct TransactionEditView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(AppModel.self) var model

    let entry: JournalEntry
    @State var kind: QuickLogKind
    @State var amountText: String
    @State var destinationAmountText: String
    @State var accountID: UUID?
    @State var destinationAccountID: UUID?
    @State var categoryID: UUID?
    @State var splitLines: [QuickLogSplitDraftLine]
    @State var isSplitTransaction: Bool
    @State var occurredAt: Date
    @State var payee: String
    @State var note: String
    @State var isSaving = false
    @State var errorMessage: String?
    @State var isConfirmingDelete = false
    @State var pendingAttachmentDeletionID: UUID?
    @State var isConfirmingAttachmentDelete = false
    @State var attachmentImages: [UUID: UIImage] = [:]
    @State var attachmentLoadFailures = Set<UUID>()
    @State var attachmentLoadTokens: [UUID: UUID] = [:]

    let isEditable: Bool

    init(entry: JournalEntry) {
        self.entry = entry
        // The real extraction runs once the environment model is available.
        _kind = State(initialValue: .expense)
        _amountText = State(initialValue: "")
        _destinationAmountText = State(initialValue: "")
        _accountID = State(initialValue: nil)
        _destinationAccountID = State(initialValue: nil)
        _categoryID = State(initialValue: nil)
        _splitLines = State(initialValue: [])
        _isSplitTransaction = State(
            initialValue: (entry.kind == .expense || entry.kind == .income)
                && entry.postings.count > 2
        )
        _occurredAt = State(initialValue: entry.occurredAt)
        _payee = State(initialValue: entry.payee ?? "")
        _note = State(initialValue: entry.note ?? "")
        isEditable = entry.kind == .expense || entry.kind == .income || entry.kind == .transfer
    }

    var originalLedgerItemIDs: Set<UUID> {
        Set(entry.postings.map(\.accountID))
    }

    /// Active choices plus the archived, user-owned choices already present on
    /// this historical entry. System accounts never enter an edit picker.
    var editableUserAccounts: [LedgerAccount] {
        model.accounts.filter { account in
            (account.kind == .asset || account.kind == .liability)
                && account.systemRole == nil
                && (!account.isArchived || originalLedgerItemIDs.contains(account.id))
        }
    }

    var categories: [LedgerAccount] {
        let expectedKind: LedgerAccountKind = kind == .income ? .income : .expense
        return model.accounts.filter { category in
            category.kind == expectedKind
                && category.systemRole == nil
                && (!category.isArchived || originalLedgerItemIDs.contains(category.id))
        }
    }

    func editorLabel(for item: LedgerAccount) -> String {
        guard item.isArchived else { return item.name }
        return "\(item.name) (\(String(localized: "lifecycle.archived")))"
    }

    var sourceCurrency: CurrencyCode? {
        editableUserAccounts.first(where: { $0.id == accountID })?.currency
    }

    var destinationCurrency: CurrencyCode? {
        editableUserAccounts.first(where: { $0.id == destinationAccountID })?.currency
    }

    var needsDestinationAmount: Bool {
        kind == .transfer && sourceCurrency != destinationCurrency
            && sourceCurrency != nil && destinationCurrency != nil
    }

    var splitRemainder: Decimal? {
        guard let amount = decimalAmount(from: amountText),
              amount > .zero,
              let currency = sourceCurrency,
              let total = try? Money(amount, currency: currency),
              let lines = try? transactionSplitLines(currency: currency),
              let remainder = try? TransactionSplitCalculator.remainder(
                total: total,
                lines: lines
              ) else { return nil }
        return remainder.amount
    }

    var splitLinesAreValid: Bool {
        guard isSplitTransaction,
              let amount = decimalAmount(from: amountText),
              let currency = sourceCurrency,
              let total = try? Money(amount, currency: currency),
              let lines = try? transactionSplitLines(currency: currency),
              lines.allSatisfy({ line in
                  categories.contains(where: {
                      $0.id == line.categoryAccountID
                  }) && currency.supports(line.amount.amount)
              }) else { return false }
        do {
            try TransactionSplitCalculator.validate(total: total, lines: lines)
            return true
        } catch {
            return false
        }
    }

    var canSave: Bool {
        guard isEditable,
              decimalAmount(from: amountText).map({ $0 > .zero }) == true,
              let accountID,
              editableUserAccounts.contains(where: { $0.id == accountID }) else {
            return false
        }
        if kind == .transfer {
            guard let destinationAccountID,
                  destinationAccountID != accountID,
                  editableUserAccounts.contains(where: {
                      $0.id == destinationAccountID
                  }) else { return false }
            return !needsDestinationAmount
                || decimalAmount(from: destinationAmountText).map { $0 > .zero } == true
        }
        if isSplitTransaction { return splitLinesAreValid }
        return categories.contains { $0.id == categoryID }
    }

    var attachmentMetadata: [ReceiptAttachmentMetadata] {
        model.receiptAttachmentMetadata.filter { $0.entryID == entry.id }
    }

    @ViewBuilder
    var splitEditor: some View {
        ForEach(Array(splitLines.enumerated()), id: \.element.id) { index, line in
            let lineID = line.id
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "quick_log.split_category",
                    selection: Binding(
                        get: {
                            splitLines.first(where: { $0.id == lineID })?.categoryID
                        },
                        set: { value in
                            updateSplitLine(lineID) { $0.categoryID = value }
                        }
                    )
                ) {
                    ForEach(categories) { category in
                        Text(verbatim: editorLabel(for: category))
                            .tag(Optional(category.id))
                    }
                }
                .accessibilityLabel(
                    Text(
                        String(
                            format: String(localized: "quick_log.split_category_numbered"),
                            index + 1
                        )
                    )
                )

                HStack {
                    TextField(
                        "quick_log.split_amount",
                        text: Binding(
                            get: {
                                splitLines.first(where: { $0.id == lineID })?.amountText
                                    ?? ""
                            },
                            set: { value in
                                updateSplitLine(lineID) { $0.amountText = value }
                            }
                        )
                    )
                    .moneyAmountKeyboard(currency: sourceCurrency)
                    .accessibilityLabel(
                        Text(
                            String(
                                format: String(localized: "quick_log.split_amount_numbered"),
                                index + 1
                            )
                        )
                    )
                    if let sourceCurrency {
                        Text(sourceCurrency.value).foregroundStyle(.secondary)
                    }
                    if splitLines.count > 2 {
                        Button(role: .destructive) {
                            splitLines.removeAll { $0.id == lineID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(
                            Text(
                                String(
                                    format: String(
                                        localized: "quick_log.split_remove_numbered"
                                    ),
                                    index + 1
                                )
                            )
                        )
                    }
                }

                TextField(
                    "quick_log.split_memo",
                    text: Binding(
                        get: {
                            splitLines.first(where: { $0.id == lineID })?.memo ?? ""
                        },
                        set: { value in
                            updateSplitLine(lineID) { $0.memo = value }
                        }
                    )
                )
                .font(.caption)
                .accessibilityLabel(
                    Text(
                        String(
                            format: String(localized: "quick_log.split_memo_numbered"),
                            index + 1
                        )
                    )
                )
            }
            .padding(.vertical, 4)
        }

        Button {
            splitLines.append(
                QuickLogSplitDraftLine(categoryID: categoryID ?? categories.first?.id)
            )
        } label: {
            Label("quick_log.split_add", systemImage: "plus.circle")
        }
        .disabled(splitLines.count >= QuickLogDraft.maximumSplitLineCount)

        if let remainder = splitRemainder, let sourceCurrency {
            LabeledContent("quick_log.split_remainder") {
                Text("\(editableAmount(remainder)) \(sourceCurrency.value)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(remainder == .zero ? Color.green : Color.red)
            }
            .accessibilityHint(
                remainder == .zero
                    ? Text("quick_log.split_balanced")
                    : Text("quick_log.split_not_balanced")
            )
        }
    }

    func updateSplitLine(
        _ lineID: UUID,
        update: (inout QuickLogSplitDraftLine) -> Void
    ) {
        guard let index = splitLines.firstIndex(where: { $0.id == lineID }) else {
            return
        }
        update(&splitLines[index])
    }
}
