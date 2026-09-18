import Foundation
import Observation
import StoreKit

struct DeveloperSupportProduct: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let displayPrice: String
    let price: Decimal
}

enum DeveloperSupportOutcome: Equatable, Sendable {
    case completed, pending, cancelled
}

@MainActor
protocol DeveloperSupportPurchasing {
    func products() async throws -> [DeveloperSupportProduct]
    func purchase(id: String) async throws -> DeveloperSupportOutcome
}

enum DeveloperSupportError: Error {
    case unavailable, unverified
}

@MainActor
final class StoreKitDeveloperSupport: DeveloperSupportPurchasing {
    static let productIDs: Set<String> = [
        "com.laiwenkang.MoneyUp.support.small",
        "com.laiwenkang.MoneyUp.support.medium",
        "com.laiwenkang.MoneyUp.support.large"
    ]
    private var availableProducts: [Product] = []

    func products() async throws -> [DeveloperSupportProduct] {
        availableProducts = try await Product.products(for: Self.productIDs)
            .filter { Self.productIDs.contains($0.id) && $0.type == .consumable }
        return availableProducts.sorted { $0.price < $1.price }.map {
            DeveloperSupportProduct(id: $0.id, displayName: $0.displayName,
                                    displayPrice: $0.displayPrice, price: $0.price)
        }
    }

    func purchase(id: String) async throws -> DeveloperSupportOutcome {
        guard AppStore.canMakePayments, Self.productIDs.contains(id),
              let product = availableProducts.first(where: { $0.id == id }) else {
            throw DeveloperSupportError.unavailable
        }
        switch try await product.purchase() {
        case let .success(result):
            guard case let .verified(transaction) = result,
                  transaction.productID == id, transaction.productType == .consumable,
                  transaction.revocationDate == nil else { throw DeveloperSupportError.unverified }
            await transaction.finish()
            return .completed
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw DeveloperSupportError.unavailable
        }
    }
}

@MainActor @Observable
final class DeveloperSupportStore {
    static let shared = DeveloperSupportStore(purchaser: StoreKitDeveloperSupport())
    private let purchaser: any DeveloperSupportPurchasing
    private(set) var products: [DeveloperSupportProduct] = []
    private(set) var isLoading = false
    private(set) var purchasingID: String?
    private(set) var pendingIDs: Set<String> = []
    private(set) var messageKey: String?
    @ObservationIgnored private var observer: Task<Void, Never>?

    init(purchaser: any DeveloperSupportPurchasing) {
        self.purchaser = purchaser
    }

    deinit { observer?.cancel() }

    func load() async {
        guard !isLoading, purchasingID == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await purchaser.products()
            if products.isEmpty { messageKey = "support.unavailable" }
            else if messageKey == "support.unavailable" { messageKey = nil }
        } catch {
            products = []
            messageKey = "support.unavailable"
        }
    }

    func purchase(_ id: String) async {
        guard purchasingID == nil, !isLoading, !pendingIDs.contains(id),
              products.contains(where: { $0.id == id }) else { return }
        purchasingID = id
        messageKey = nil
        defer { purchasingID = nil }
        do {
            switch try await purchaser.purchase(id: id) {
            case .completed: messageKey = "support.thanks"
            case .pending:
                pendingIDs.insert(id)
                messageKey = "support.pending"
            case .cancelled: break
            }
        } catch {
            messageKey = "support.failed"
        }
    }

    /// StoreKit owns payment history. No tip becomes a financial-book entry,
    /// entitlement, subscription, analytics event, or external server request.
    func startObservingTransactions() {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.completeSupportTransaction(result)
            }
        }
        Task { [weak self] in
            for await result in Transaction.unfinished {
                await self?.completeSupportTransaction(result)
            }
        }
    }

    private func completeSupportTransaction(_ result: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = result,
              StoreKitDeveloperSupport.productIDs.contains(transaction.productID),
              transaction.productType == .consumable else { return }
        if transaction.revocationDate == nil { messageKey = "support.thanks" }
        pendingIDs.remove(transaction.productID)
        await transaction.finish()
    }
}
