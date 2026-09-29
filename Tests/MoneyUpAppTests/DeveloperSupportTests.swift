import Foundation
@testable import MoneyUp
import StoreKit
import StoreKitTest
import SwiftUI
import UIKit
import XCTest

final class DeveloperSupportTests: XCTestCase {
    @MainActor
    func testCancelledAndPendingSupportNeverClaimPayment() async {
        let backend = SupportPurchaseStub()
        let store = DeveloperSupportStore(purchaser: backend)
        await store.load()
        backend.outcome = .cancelled
        await store.purchase("test-tip")
        XCTAssertNil(store.messageKey)
        backend.outcome = .pending
        await store.purchase("test-tip")
        XCTAssertEqual(store.messageKey, "support.pending")
        XCTAssertNil(store.purchasingID)
        await store.purchase("test-tip")
        XCTAssertEqual(backend.purchaseCount, 2)
    }

    @MainActor
    func testUnavailableAndUnverifiedPurchasesDoNotThankOrChargeAgain() async {
        let backend = SupportPurchaseStub()
        let store = DeveloperSupportStore(purchaser: backend)
        await store.purchase("unknown")
        XCTAssertEqual(backend.purchaseCount, 0)
        await store.load()
        backend.shouldFail = true
        await store.purchase("test-tip")
        XCTAssertEqual(store.messageKey, "support.failed")
        XCTAssertEqual(backend.purchaseCount, 1)
        await store.load()
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertEqual(store.messageKey, "support.unavailable")
    }

    @MainActor
    func testConcurrentTapsStartOnlyOnePurchase() async {
        let backend = SupportPurchaseStub()
        backend.suspend = true
        let store = DeveloperSupportStore(purchaser: backend)
        await store.load()
        let first = Task { await store.purchase("test-tip") }
        while backend.continuation == nil { await Task.yield() }
        await store.purchase("test-tip")
        XCTAssertEqual(backend.purchaseCount, 1)
        backend.continuation?.resume()
        await first.value
        XCTAssertEqual(store.messageKey, "support.thanks")
        XCTAssertNil(store.purchasingID)
    }

    @MainActor
    func testStoreKitConsumableSupportCanBeRepeatedAndFinished() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "MoneyUpSupport", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        // Local StoreKit configuration propagates asynchronously to its daemon.
        // The local StoreKit daemon publishes the configuration asynchronously
        // and, on shared CI runners, slowly. Wait on a deadline, not a count.
        let productsDeadline = Date().addingTimeInterval(20)
        while Date() < productsDeadline {
            if try await Product.products(for: StoreKitDeveloperSupport.productIDs).count == 3 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let backend = StoreKitDeveloperSupport()
        let store = DeveloperSupportStore(purchaser: backend)
        await store.load()
        XCTAssertEqual(Set(store.products.map(\.id)), StoreKitDeveloperSupport.productIDs)
        XCTAssertTrue(store.products.allSatisfy { !$0.displayPrice.isEmpty && $0.price > 0 })
        let (window, previousKeyWindow) = try await captureSupportPage(store)
        // Purchases need a live presentation scene, just as they do when the
        // user taps a support option. Keep it until transaction checks finish.
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await warmUpLocalSigning(session)
        // The app host already owns its transaction observer. Do not create
        // another observer while the test storefront is being reset.
        let product = try XCTUnwrap(store.products.first)
        for expectedCount in 1...2 {
            // Exercise the same loading and duplicate-tap gates as the button.
            let loadingDeadline = Date().addingTimeInterval(15)
            while store.isLoading, Date() < loadingDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(store.isLoading)
            guard !store.isLoading else { return }
            await store.purchase(product.id)
            XCTAssertEqual(store.messageKey, "support.thanks")
            XCTAssertNil(store.purchasingID)
            guard await verifyFinishedPurchases(session, store: store, count: expectedCount) else { return }
        }
    }

    /// A fresh CI simulator can start with a StoreKit test certificate that
    /// fails verification ("certificate is expired", "not temporally valid")
    /// until StoreKit recovers it; the same transaction verifies a minute
    /// later. That is signing on the runner, not the app, which rightly never
    /// thanks for an unverified purchase. Buy once directly and wait until a
    /// purchase verifies, then start the checked flow from a clean history.
    @MainActor
    private func warmUpLocalSigning(_ session: SKTestSession) async throws {
        let products = try await Product.products(for: StoreKitDeveloperSupport.productIDs)
        let product = try XCTUnwrap(products.first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        _ = try? await product.purchase(confirmIn: scene)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            for await result in StoreKit.Transaction.unfinished {
                guard case let .verified(transaction) = result,
                      StoreKitDeveloperSupport.productIDs.contains(transaction.productID) else { continue }
                await transaction.finish()
                session.clearTransactions()
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw XCTSkip("StoreKit's local test signing never verified a purchase on this runner.")
    }

    @MainActor
    private func verifyFinishedPurchases(
        _ session: SKTestSession,
        store: DeveloperSupportStore,
        count: Int
    ) async -> Bool {
        var unfinishedIDs: [UInt64] = []
        var identifiers: [UInt] = []
        // StoreKit updates its local transaction indexes asynchronously after
        // finish returns. Verify each receipt before initiating the next buy.
        let start = Date()
        var ranLaunchPass = false
        while Date().timeIntervalSince(start) < 20 {
            identifiers = session.allTransactions().map(\.identifier)
            unfinishedIDs = []
            for await result in StoreKit.Transaction.unfinished {
                if case let .verified(value) = result, StoreKitDeveloperSupport.productIDs.contains(value.productID) {
                    unfinishedIDs.append(value.id)
                }
            }
            if Set(identifiers).count == count, unfinishedIDs.isEmpty { return true }
            // On shared CI runners the local StoreKit daemon can drop a finish
            // sent right after a purchase. The guarantee is that a tip always
            // ends finished: by the purchase, or by the pass the app runs at
            // each launch. Run that same pass once before judging.
            if !ranLaunchPass, !unfinishedIDs.isEmpty, Date().timeIntervalSince(start) >= 5 {
                ranLaunchPass = true
                await store.finishUnfinishedSupportTransactions()
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(Set(identifiers).count, count, "Distinct local purchases: \(identifiers)")
        XCTAssertTrue(unfinishedIDs.isEmpty, "Local purchases: \(identifiers); unfinished: \(unfinishedIDs)")
        return false
    }

    @MainActor
    private func captureSupportPage(_ store: DeveloperSupportStore) async throws -> (UIWindow, UIWindow?) {
        let controller = UIHostingController(rootView: NavigationStack {
            DeveloperSupportView(store: store)
        }.preferredColorScheme(.light).environment(\.locale, Locale(identifier: "en_US")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        try? await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "support-review"
        attachment.lifetime = .keepAlways
        add(attachment)
        return (window, previousKeyWindow)
    }
}

@MainActor private final class SupportPurchaseStub: DeveloperSupportPurchasing {
    var outcome = DeveloperSupportOutcome.completed
    var shouldFail = false
    var suspend = false
    var purchaseCount = 0
    var continuation: CheckedContinuation<Void, Never>?

    func products() async throws -> [DeveloperSupportProduct] {
        if shouldFail { throw DeveloperSupportError.unavailable }
        return [DeveloperSupportProduct(id: "test-tip", displayName: "Support", displayPrice: "$0.99", price: 0.99)]
    }

    func purchase(id: String) async throws -> DeveloperSupportOutcome {
        purchaseCount += 1
        if shouldFail { throw DeveloperSupportError.unverified }
        if suspend { await withCheckedContinuation { continuation = $0 } }
        return outcome
    }
}
