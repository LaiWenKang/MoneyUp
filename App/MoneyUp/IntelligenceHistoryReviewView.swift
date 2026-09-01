import Foundation
import MoneyUpCore
import SwiftUI

struct IntelligenceHistorySelection: Identifiable {
    let findingID: String
    let entryIDs: [UUID]
    let day: Int?
    let wasTruncated: Bool
    let logicalBookRevision: UInt64

    var id: String { findingID }
}

struct IntelligenceHistoryReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: IntelligenceHistorySelection
    @State private var entries: [JournalEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var editingEntry: JournalEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if selection.wasTruncated {
                        Label(
                            "intelligence.history.limited",
                            systemImage: "info.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isLoading {
                        ProgressView("intelligence.history.loading")
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if let errorMessage {
                        MoneyUpCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(errorMessage)
                                    .foregroundStyle(.secondary)
                                Button("action.try_again") {
                                    Task { await load() }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } else if entries.isEmpty {
                        MoneyUpCard {
                            Text("intelligence.history.no_results")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(entries) { entry in
                            MoneyUpCard {
                                Button {
                                    editingEntry = entry
                                } label: {
                                    TransactionRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .background { MoneyUpBackdrop() }
            .navigationTitle("intelligence.history.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
            .task(id: model.logicalBookRevision) { await load() }
            .onChange(of: model.logicalBookRevision) { _, _ in
                entries = []
                editingEntry = nil
            }
            .sheet(item: $editingEntry) { entry in
                NavigationStack { TransactionEditView(entry: entry) }
            }
        }
    }

    @MainActor
    private func load() async {
        let revision = selection.logicalBookRevision
        guard revision == model.logicalBookRevision,
              !model.isBookReplacementInProgress else {
            entries = []
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await model.intelligenceHistoryEntries(
                entryIDs: selection.entryIDs
            )
            guard revision == model.logicalBookRevision,
                  !model.isBookReplacementInProgress else { return }
            entries = loaded
            errorMessage = nil
        } catch {
            guard revision == model.logicalBookRevision else { return }
            entries = []
            errorMessage = safeUserMessage(for: error, context: .read)
        }
    }
}
