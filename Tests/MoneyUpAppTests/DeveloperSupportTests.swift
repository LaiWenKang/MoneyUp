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
        for _ in 0..<20 {
            if try await Product.products(for: StoreKitDeveloperSupport.productIDs).count == 3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let backend = StoreKitDeveloperSupport()
        let products = try await backend.products()
        XCTAssertEqual(Set(products.map(\.id)), StoreKitDeveloperSupport.productIDs)
        XCTAssertTrue(products.allSatisfy { !$0.displayPrice.isEmpty && $0.price > 0 })
        let store = DeveloperSupportStore(purchaser: backend)
        await store.load()
        let (window, previousKeyWindow) = try await captureSupportPage(store)
        // Purchases need a live presentation scene, just as they do when the
        // user taps a support option. Keep it until transaction checks finish.
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        // The app host already owns its transaction observer. Do not create
        // another observer while the test storefront is being reset.
        let product = try XCTUnwrap(products.first)
        for expectedCount in 1...2 {
            let outcome = try await backend.purchase(id: product.id)
            XCTAssertEqual(outcome, .completed)
            guard await verifyFinishedPurchases(session, count: expectedCount) else { return }
        }
    }

    @MainActor
    private func verifyFinishedPurchases(_ session: SKTestSession, count: Int) async -> Bool {
        var unfinishedIDs: [UInt64] = []
        var identifiers: [UInt] = []
        // StoreKit updates its local transaction indexes asynchronously after
        // finish returns. Verify each receipt before initiating the next buy.
        for _ in 0..<50 {
            identifiers = session.allTransactions().map(\.identifier)
            unfinishedIDs = []
            for await result in StoreKit.Transaction.unfinished {
                if case let .verified(value) = result, StoreKitDeveloperSupport.productIDs.contains(value.productID) {
                    unfinishedIDs.append(value.id)
                }
            }
            if Set(identifiers).count == count, unfinishedIDs.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
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
