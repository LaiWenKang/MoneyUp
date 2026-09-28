import SwiftUI
import TipKit

/// Native TipKit hints. Their state stays in this app's own container: no
/// CloudKit sync, no App Group, and nothing about the book.
enum MoneyUpTips {
    @MainActor
    static func configure() {
        #if DEBUG
        // Journeys assert exact screens; a tip would shift them.
        let hidesTips = ProcessInfo.processInfo.arguments.contains(MoneyUpUITestHarness.enableArgument)
        #else
        let hidesTips = false
        #endif
        // Opening the tip store takes milliseconds; keep it off the main thread.
        // Tips wait for a later visit to Log anyway.
        Task.detached(priority: .utility) {
            if hidesTips { Tips.hideAllTipsForTesting() }
            try? Tips.configure([
                .displayFrequency(.daily),
                .datastoreLocation(.applicationDefault),
                .cloudKitContainer(nil)
            ])
        }
    }
}

/// A tap on the receipt button opens the document camera; the photo library is
/// a touch and hold away. Shown from the second visit to Log until it is
/// closed or the button is used.
struct ScanReceiptTip: Tip {
    static let logOpened = Event(id: "log-opened")

    /// Counts visits only while the tip is still waiting, so at most two are
    /// ever recorded.
    func noteLogVisit() {
        guard case .pending = status else { return }
        Self.logOpened.sendDonation()
    }

    func noteUse() {
        invalidate(reason: .actionPerformed)
    }

    var title: Text { Text("tip.scan_receipt.title") }
    var message: Text? { Text("tip.scan_receipt.message") }
    var image: Image? { Image(systemName: "doc.viewfinder") }

    var rules: [Rule] {
        #Rule(Self.logOpened) { $0.donations.count >= 2 }
    }
}

/// The scan tip, inline under Smart Entry where the receipt button sits, so it
/// never floats over the keypad or another field.
struct QuickLogScanReceiptTip: View {
    var body: some View {
        if ReceiptDocumentCamera.isAvailable {
            TipView(ScanReceiptTip())
        }
    }
}
