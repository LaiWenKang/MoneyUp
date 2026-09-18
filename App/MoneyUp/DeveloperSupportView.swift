import StoreKit
import SwiftUI

struct DeveloperSupportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: DeveloperSupportStore

    init(store: DeveloperSupportStore = .shared) {
        _store = State(initialValue: store)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.largeTitle).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("support.headline").font(.title2.bold())
                    Text("support.explanation").foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            }
            Section {
                if store.isLoading {
                    HStack { ProgressView(); Text("support.loading") }
                } else if !AppStore.canMakePayments {
                    Text("support.restricted").foregroundStyle(.secondary)
                } else {
                    ForEach(store.products) { product in
                        Button {
                            Task { await store.purchase(product.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Text(verbatim: product.displayName)
                                Spacer()
                                if store.purchasingID == product.id { ProgressView() }
                                Text(verbatim: product.displayPrice).fontWeight(.semibold)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .disabled(store.purchasingID != nil || store.pendingIDs.contains(product.id))
                    }
                    if store.products.isEmpty {
                        Button("support.retry") { Task { await store.load() } }
                    }
                }
            } footer: {
                Text("support.terms")
            }
            if let message = store.messageKey {
                Section {
                    Text(LocalizedStringKey(message))
                        .accessibilityIdentifier("developer-support-status")
                }
            }
        }
        .navigationTitle("support.title")
        .moneyUpNavigationSurface()
        .scrollContentBackground(.hidden)
        .background { MoneyUpBackdrop() }
        .task { await store.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.load() } }
        }
    }
}
