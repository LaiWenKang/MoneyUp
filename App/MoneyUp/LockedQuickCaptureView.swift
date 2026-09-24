import SwiftUI

struct LockedQuickCaptureView: View {
    private enum FocusedField: Hashable {
        case amount
        case payee
        case note
    }

    private enum ReplayInspectionState {
        case checking
        case ready
        case failed
    }

    @Environment(AppModel.self) private var model
    let request: QuickLogRouteRequest

    private var mode: QuickLogLaunchMode { request.mode }

    private let unlockMethod = UnlockMethod.current

    @State private var amountText = ""
    @State private var payee = ""
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSave = false
    @State private var showsFieldErrors = false
    @State private var replayInspectionState: ReplayInspectionState = .checking
    /// Present only when the owner opted in to favourites while locked.
    @State private var lockedFavourites: [LockedFavouriteShortcut] = []
    @FocusState private var focusedField: FocusedField?

    private var hasValidAmount: Bool {
        guard amountText.utf8.count <= LockedCapture.maximumAmountByteCount,
              let amount = decimalAmount(from: amountText) else { return false }
        return amount > .zero
    }

    private var detailsFitCapture: Bool {
        payee.utf8.count <= LockedCapture.maximumPayeeByteCount
            && note.utf8.count <= LockedCapture.maximumNoteByteCount
    }

    private var canSave: Bool {
        replayInspectionState == .ready
            && hasValidAmount
            && detailsFitCapture
    }

    private var hasUnsavedInput: Bool {
        !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !payee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var amountValidationMessage: String? {
        guard (showsFieldErrors || !amountText.isEmpty), !hasValidAmount else {
            return nil
        }
        return AppLocalization.string("error.invalid_amount")
    }

    private var payeeValidationMessage: String? {
        guard payee.utf8.count > LockedCapture.maximumPayeeByteCount else {
            return nil
        }
        return AppLocalization.string("capture.input_too_long")
    }

    private var noteValidationMessage: String? {
        guard note.utf8.count > LockedCapture.maximumNoteByteCount else {
            return nil
        }
        return AppLocalization.string("capture.input_too_long")
    }

    private var pendingCaptureCountText: String {
        String(
            format: AppLocalization.string("capture.pending_count"),
            model.pendingLockedCaptureCount
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if didSave {
                    Section {
                        VStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text("capture.saved_title")
                                .font(.title2.bold())
                            Text("capture.saved_detail")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Text(pendingCaptureCountText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }

                    Section {
                        Button {
                            model.consumeQuickLogRequest(request)
                        } label: {
                            Label("action.done", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("locked-capture-done")
                        .buttonStyle(.borderedProminent)
                        .tint(.moneyUpAction)

                        Button {
                            Task { await unlock() }
                        } label: {
                            Label(
                                "capture.review_now",
                                systemImage: unlockMethod.systemImage
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!unlockMethod.isAvailable)
                    }
                } else {
                    Section {
                        LockedCaptureHeader(
                            mode: mode,
                            pendingText: model.pendingLockedCaptureCount > 0
                                ? pendingCaptureCountText : nil
                        )
                        if !matchingFavourites.isEmpty, replayInspectionState == .ready {
                            LockedFavouriteChipsRow(favourites: matchingFavourites, apply: applyLockedFavourite)
                        }
                        switch replayInspectionState {
                        case .checking:
                            ProgressView()
                                .accessibilityLabel("lock.opening")
                        case .failed:
                            Button {
                                Task { await inspectCommittedCapture() }
                            } label: {
                                Label(
                                    "action.retry",
                                    systemImage: "arrow.clockwise"
                                )
                            }
                        case .ready:
                            EmptyView()
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

                    Section {
                        TextField("quick_log.amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .focused($focusedField, equals: .amount)
                            .accessibilityIdentifier("locked-capture-amount")
                            .moneyUpFieldValidation(amountValidationMessage)
                        if let amountValidationMessage {
                            MoneyUpFieldError(message: amountValidationMessage)
                        }

                        TextField("transaction.title_or_merchant", text: $payee)
                            .focused($focusedField, equals: .payee)
                            .moneyUpFieldValidation(payeeValidationMessage)
                        if let payeeValidationMessage {
                            MoneyUpFieldError(message: payeeValidationMessage)
                        }
                        TextField(
                            "transaction.description_or_notes",
                            text: $note,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .focused($focusedField, equals: .note)
                        .moneyUpFieldValidation(noteValidationMessage)
                        if let noteValidationMessage {
                            MoneyUpFieldError(message: noteValidationMessage)
                        }
                    }
                    .disabled(replayInspectionState != .ready)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.moneyUpBackground)
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSaving)
            .safeAreaInset(edge: .bottom) {
                if !didSave, replayInspectionState == .ready {
                    // Pinned above the keyboard so Save is never hidden, with
                    // the full-Log route one tap away for favourites.
                    LockedCaptureActionBar(
                        canSave: canSave && !isSaving,
                        canUnlock: unlockMethod.isAvailable && !isSaving,
                        unlockSymbol: unlockMethod.systemImage,
                        save: { Task { await save() } },
                        unlock: { Task { await unlock() } }
                    )
                }
            }
            // The header already names the action; no second "Log" title.
            .navigationTitle(Text(verbatim: ""))
            .moneyUpNavigationSurface()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") {
                        model.consumeQuickLogRequest(request)
                    }
                }
            }
        }
        .task {
            lockedFavourites = await model.lockedFavouriteStore.all()
            await inspectCommittedCapture()
        }
        .moneyUpFeedback(
            for: .financialCommit,
            trigger: didSave,
            visibleStatus: didSave
        )
        .moneyUpOperationErrorAlert(message: $errorMessage)
    }

    private var matchingFavourites: [LockedFavouriteShortcut] {
        switch mode.kind {
        case .expense: lockedFavourites.filter { $0.kind == .expense }
        case .income: lockedFavourites.filter { $0.kind == .income }
        case .transfer, .refund: []
        }
    }

    /// Fills only what the favourite fixes; a typed amount survives an
    /// amount-each-time favourite. Nothing is captured until Save.
    private func applyLockedFavourite(_ favourite: LockedFavouriteShortcut) {
        if let amount = favourite.amountText { amountText = amount }
        payee = favourite.capturePayee
        if !favourite.note.isEmpty { note = favourite.note }
        focusedField = amountText.isEmpty ? .amount : nil
    }

    private func save() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await model.saveLockedCapture(
                request: request,
                amountText: amountText,
                payee: payee,
                note: note
            )
            focusedField = nil
            didSave = true
        } catch {
            errorMessage = safeUserMessage(for: error, context: .save)
        }
    }

    private func unlock() async {
        guard !isSaving, unlockMethod.isAvailable else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // A valid form is first appended to the existing device-only encrypted
        // inbox. The durable ingress token is also the append's idempotency
        // key, while `didSave` prevents a second same-view attempt after an
        // authentication cancellation. Promotion into authenticated Log
        // remains the model's existing exactly-once path and requires review.
        if hasUnsavedInput, !didSave {
            showsFieldErrors = true
            guard hasValidAmount else {
                focusedField = .amount
                return
            }
            guard detailsFitCapture else {
                focusedField = payee.utf8.count > LockedCapture.maximumPayeeByteCount
                    ? .payee : .note
                return
            }
        }
        if canSave, !didSave {
            do {
                try await model.saveLockedCapture(
                    request: request,
                    amountText: amountText,
                    payee: payee,
                    note: note
                )
                focusedField = nil
                didSave = true
            } catch {
                errorMessage = safeUserMessage(for: error, context: .save)
                return
            }
        }
        guard model.requestedQuickLogRequest == request else { return }
        await model.start()
    }

    private func inspectCommittedCapture() async {
        guard !didSave else { return }
        replayInspectionState = .checking
        errorMessage = nil
        focusedField = nil
        do {
            if try await model.resumeCommittedLockedCaptureIfPresent(
                request: request
            ) {
                didSave = true
                return
            }
            guard !Task.isCancelled else { return }
            replayInspectionState = .ready
            await Task.yield()
            focusedField = .amount
        } catch is CancellationError {
            return
        } catch {
            replayInspectionState = .failed
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }
}

/// The same mark and verb as the widget that opened this screen, plus one
/// line on what stays private. Nothing else competes with the amount.
struct LockedCaptureHeader: View {
    let mode: QuickLogLaunchMode
    let pendingText: String?

    private var glyph: String {
        switch mode.kind {
        case .expense: MoneyUpEntryGlyph.expense
        case .income: MoneyUpEntryGlyph.income
        case .transfer: MoneyUpEntryGlyph.transfer
        case .refund: MoneyUpEntryGlyph.refund
        }
    }

    private var title: LocalizedStringKey {
        switch mode.kind {
        case .expense: "widget.hero.expense"
        case .income: "widget.hero.income"
        case .transfer: "widget.hero.transfer"
        case .refund: "widget.hero.refund"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.moneyUpAction, in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text("capture.minimal_note")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.leading, 48)
            if let pendingText {
                Text(pendingText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct LockedCaptureActionBar: View {
    let canSave: Bool
    let canUnlock: Bool
    let unlockSymbol: String
    let save: () -> Void
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: save) {
                Label("capture.save", systemImage: "tray.and.arrow.down.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    // Dimmed brand green, not grey, so the one action stays
                    // recognisable before an amount makes it available.
                    .background(
                        Color.moneyUpAction.opacity(canSave ? 1 : 0.4),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier("locked-capture-save")
            Button(action: unlock) {
                Label("capture.unlock_for_favourites", systemImage: unlockSymbol)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(!canUnlock)
            .accessibilityIdentifier("locked-capture-unlock")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }
}

/// Opted-in favourites on the locked screen: names and fixed amounts only.
struct LockedFavouriteChipsRow: View {
    let favourites: [LockedFavouriteShortcut]
    let apply: (LockedFavouriteShortcut) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(favourites) { favourite in
                    Button { apply(favourite) } label: {
                        HStack(spacing: 6) {
                            Text(favourite.name).font(.subheadline.weight(.semibold))
                            if let amount = favourite.displayAmount {
                                Text(verbatim: amount)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Color.moneyUpSurfaceElevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.moneyUpAction.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("favourites.prefill_hint")
                    .accessibilityIdentifier("locked-favourite-\(favourite.name)")
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("favourites.title")
    }
}
