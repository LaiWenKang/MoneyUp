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
        await captureSupportPage(store)
        let product = try XCTUnwrap(products.first)
        for _ in 0..<2 {
            let outcome = try await backend.purchase(id: product.id)
            XCTAssertEqual(outcome, .completed)
        }
        XCTAssertEqual(session.allTransactions().count, 2)
        var unfinished = 1
        for _ in 0..<20 {
            unfinished = 0
            for await transaction in StoreKit.Transaction.unfinished {
                if case let .verified(value) = transaction, StoreKitDeveloperSupport.productIDs.contains(value.productID) {
                    unfinished += 1
                }
            }
            if unfinished == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(unfinished, 0)
    }

    @MainActor
    private func captureSupportPage(_ store: DeveloperSupportStore) async {
        let controller = UIHostingController(rootView: NavigationStack {
            DeveloperSupportView(store: store)
        }.preferredColorScheme(.light).environment(\.locale, Locale(identifier: "en_US")))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 428, height: 926)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
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
