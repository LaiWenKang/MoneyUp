import Foundation
import MoneyUpCore
import SwiftUI

/// Pure mapping between a saved favourite and the Log draft. Keeping it free
/// of view state makes the "prefill, never post" contract directly testable.
enum QuickLogFavouriteFill {
    /// Fills the draft from a favourite. The amount is replaced only by a
    /// fixed-amount favourite; an amount the user already typed survives an
    /// amount-only favourite. Stale references are skipped, never guessed.
    static func fill(
        _ favourite: QuickLogFavourite,
        current: QuickLogDraft,
        usableAccountIDs: Set<UUID>,
        usableCategoryIDs: Set<UUID>,
        locale: Locale = .current
    ) -> QuickLogDraft {
        var updated = current
        updated.kind = favourite.kind == .income ? .income : .expense
        if let amount = favourite.amount {
            updated.amountText = editableAmount(amount, locale: locale)
        }
        if let accountID = favourite.accountID, usableAccountIDs.contains(accountID) {
            updated.accountID = accountID
            updated.accountWasEdited = true
        }
        if let categoryID = favourite.categoryID, usableCategoryIDs.contains(categoryID) {
            updated.categoryID = categoryID
            updated.categoryWasEdited = true
        }
        // Blank favourite text never erases a title or note already typed.
        if !favourite.payee.isEmpty { updated.payee = favourite.payee }
        if !favourite.note.isEmpty { updated.note = favourite.note }
        updated.smartText = ""
        updated.destinationAmountText = ""
        updated.destinationAccountID = nil
        return updated
    }

    /// A candidate from the entry just saved. Transfers, refunds, and splits
    /// do not map to one reusable account/category pair.
    static func candidate(
        from draft: QuickLogDraft,
        categoryName: String?,
        locale: Locale = .current
    ) -> QuickLogFavourite? {
        guard draft.splitLines.isEmpty, draft.batch == nil else { return nil }
        let kind: QuickLogFavourite.Kind
        switch draft.kind {
        case .expense: kind = .expense
        case .income: kind = .income
        case .transfer, .refund: return nil
        }
        let payee = draft.payee.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = payee.isEmpty ? (categoryName ?? "") : payee
        return QuickLogFavourite(
            name: name,
            kind: kind,
            amount: decimalAmount(from: draft.amountText, locale: locale),
            accountID: draft.accountID,
            categoryID: draft.categoryID,
            payee: payee,
            note: draft.note
        )
    }
}

extension QuickLogEntryView {
    /// Favourites are shown for a single expense or income entry. A batch,
    /// split, or allowance draft has structure a favourite cannot represent.
    var showsFavouritesStrip: Bool {
        !dismissAfterSave && !model.quickLogFavourites.isEmpty
            && (kind == .expense || kind == .income)
            && batch == nil && splitLines.isEmpty && selectedAllowanceID == nil
    }

    var favouritesSection: some View {
        QuickLogFavouritesStrip(
            isVisible: showsFavouritesStrip,
            isDisabled: isSaving || isScanning || isCheckingDuplicates || isClearingDraft,
            hidesAmounts: hidesAmounts,
            apply: applyFavourite
        )
    }

    func applyFavourite(_ favourite: QuickLogFavourite) {
        guard showsFavouritesStrip, !isSaving, !isScanning, !isCheckingDuplicates,
              !isClearingDraft, model.state == .ready, !model.isBookReplacementInProgress,
              model.quickLogFavouriteRepairs(favourite).isEmpty else { return }
        let categoryPool = favourite.kind == .income
            ? recordingIncomeCategories : recordingExpenseCategories
        let updated = QuickLogFavouriteFill.fill(
            favourite,
            current: draftSnapshot,
            usableAccountIDs: Set(model.userAccounts.map(\.id)),
            usableCategoryIDs: Set(categoryPool.map(\.id))
        )
        guard updated != draftSnapshot else {
            focusAfterFavourite(favourite)
            return
        }
        cancelSmartParsing()
        cancelOnDeviceAssistance()
        clearCaptureSuggestionProvenance()
        receiptProtectedFields.formUnion([\QuickLogDraft.payee, \QuickLogDraft.accountID,
            \QuickLogDraft.categoryID, \QuickLogDraft.note])
        if favourite.hasFixedAmount { receiptProtectedFields.insert(\QuickLogDraft.amountText) }
        // Keep the provenance of an in-flight locked capture and the date
        // policy; the entry is still a new transaction with a fresh time.
        let wasShowingOptionalDetails = isShowingOptionalDetails
        if updated.kind != kind { preservesCaptureSuggestionsAcrossNextKindChange = true }
        applyDraft(updated)
        isShowingOptionalDetails = wasShowingOptionalDetails || !favourite.note.isEmpty
        refreshUntouchedOccurrenceDate(persist: false)
        if !dismissAfterSave { model.updateQuickLogDraft(draftSnapshot) }
        focusAfterFavourite(favourite)
    }

    private func focusAfterFavourite(_ favourite: QuickLogFavourite) {
        // An amount-only favourite is the "Lunch" flow: the keyboard is ready
        // for the one value that changes. A fixed amount leaves Save in view.
        focusedField = favourite.hasFixedAmount && !amountText.isEmpty ? nil : .amount
    }

    func favouriteCandidateForSavedEntry() -> QuickLogFavourite? {
        guard !dismissAfterSave, model.canAddQuickLogFavourite else { return nil }
        return QuickLogFavouriteFill.candidate(
            from: draftSnapshot,
            categoryName: categoryID.map { model.categoryPathName(for: $0) }
        )
    }
}

/// A concrete type keeps the Log form's generic nesting flat and owns its own
/// repair sheet, so presenting it never adds a modifier to the form chain.
struct QuickLogFavouritesStrip: View {
    @Environment(AppModel.self) private var model
    let isVisible: Bool
    let isDisabled: Bool
    let hidesAmounts: Bool
    let apply: (QuickLogFavourite) -> Void
    @State private var editing: QuickLogFavourite?
    @State private var errorMessage: String?

    var body: some View {
        if isVisible {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.quickLogFavourites) { favourite in
                            chip(for: favourite)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Label("favourites.title", systemImage: "star.fill")
            }
            .sheet(item: $editing) { favourite in
                QuickLogFavouriteEditor(favourite: favourite, isNew: false)
            }
            .moneyUpOperationErrorAlert(message: $errorMessage)
        }
    }

    private func delete(_ favourite: QuickLogFavourite) async {
        do {
            try await model.deleteQuickLogFavourite(id: favourite.id)
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func chip(for favourite: QuickLogFavourite) -> some View {
        let needsRepair = !model.quickLogFavouriteRepairs(favourite).isEmpty
        return Button {
            if needsRepair { editing = favourite } else { apply(favourite) }
        } label: {
            QuickLogFavouriteChip(
                favourite: favourite,
                amountLabel: amountLabel(for: favourite),
                categoryID: favourite.categoryID.flatMap { model.accountsByID[$0] == nil ? nil : $0 },
                needsRepair: needsRepair
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contextMenu {
            Button("favourites.edit", systemImage: "pencil") { editing = favourite }
            Button("favourites.delete", systemImage: "trash", role: .destructive) {
                Task { await delete(favourite) }
            }
        }
        .accessibilityLabel(accessibilityLabel(for: favourite, needsRepair: needsRepair))
        .accessibilityHint(needsRepair ? "favourites.repair_hint" : "favourites.prefill_hint")
        .accessibilityIdentifier("quick-log-favourite-\(favourite.name)")
    }

    private func amountLabel(for favourite: QuickLogFavourite) -> String? {
        guard let amount = favourite.amount else { return nil }
        return QuickLogFavouriteFormatting.amount(amount, accountID: favourite.accountID,
            accountsByID: model.accountsByID, hidesAmounts: hidesAmounts)
    }

    private func accessibilityLabel(for favourite: QuickLogFavourite, needsRepair: Bool) -> String {
        if needsRepair {
            return String(format: AppLocalization.string("favourites.repair_accessibility_format"),
                          favourite.name)
        }
        if let amountLabel = amountLabel(for: favourite) {
            return String(format: AppLocalization.string("favourites.fill_fixed_accessibility_format"),
                          favourite.name, amountLabel)
        }
        return String(format: AppLocalization.string("favourites.fill_amount_accessibility_format"),
                      favourite.name)
    }
}

enum QuickLogFavouriteFormatting {
    /// Written with the account's currency code and minor units ("SGD 3.20")
    /// and masked like every other amount when amounts are hidden.
    @MainActor
    static func amount(
        _ amount: Decimal, accountID: UUID?, accountsByID: [UUID: LedgerAccount], hidesAmounts: Bool
    ) -> String {
        guard let currency = accountID.flatMap({ accountsByID[$0]?.currency }),
              let money = try? Money(amount, currency: currency) else {
            return MoneyAmountPrivacy.protected(editableAmount(amount), hidesAmounts: hidesAmounts)
        }
        let text = formattedMoneyWithCurrencyCode(money)
        return hidesAmounts ? MoneyAmountPrivacy.protected(text, hidesAmounts: true) : text
    }
}

/// Fixed-amount and amount-only favourites are told apart by their second
/// line: a figure, or a keypad prompt. Colour is never the only signal.
struct QuickLogFavouriteChip: View {
    @Environment(AppModel.self) private var model
    let favourite: QuickLogFavourite
    let amountLabel: String?
    let categoryID: UUID?
    let needsRepair: Bool

    var body: some View {
        HStack(spacing: 8) {
            MoneyUpCategoryBadge(
                systemImage: needsRepair ? "exclamationmark.triangle.fill" : symbol,
                tint: needsRepair ? .moneyUpWarning : tint,
                size: 30
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(favourite.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Group {
                    if needsRepair {
                        Text("favourites.needs_attention")
                    } else if let amountLabel {
                        Text(verbatim: amountLabel).monospacedDigit()
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "keyboard").imageScale(.small)
                            Text("favourites.amount_each_time")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(Color.moneyUpSurfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.moneyUpAction.opacity(0.18), lineWidth: 1))
        .contentShape(Capsule())
    }

    private var symbol: String {
        guard let categoryID else {
            return favourite.kind == .income
                ? MoneyUpCategorySymbol.fallbackIncome : MoneyUpCategorySymbol.fallbackExpense
        }
        return MoneyUpCategorySymbol.symbol(for: categoryID, accountsByID: model.accountsByID)
    }

    private var tint: Color {
        categoryID.map { MoneyUpCategorySymbol.tint(for: $0) } ?? .moneyUpAction
    }
}

/// The star beside the saved confirmation. It owns its sheet so the Log
/// form gains no presentation modifier, and reports while it is open so the
/// confirmation does not auto-dismiss underneath the editor.
struct SaveAsFavouriteButton: View {
    let candidate: QuickLogFavourite
    @Binding var isPresenting: Bool

    var body: some View {
        Button {
            isPresenting = true
        } label: {
            Image(systemName: "star")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.moneyUpAction)
        .accessibilityLabel("favourites.save_as")
        .accessibilityIdentifier("log-save-as-favourite")
        .sheet(isPresented: $isPresenting) {
            QuickLogFavouriteEditor(favourite: candidate, isNew: true)
        }
    }
}
