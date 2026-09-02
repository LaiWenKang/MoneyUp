import Foundation
import MoneyUpCore
import MoneyUpPersistence
import SwiftUI
import UniformTypeIdentifiers

/// A deliberately metadata-only manifest for upgrade and restore reconciliation.
///
/// The exported JSON must never contain record payloads or user-authored
/// identifiers. Counts come from one payload-free encrypted-store snapshot so
/// they describe a coherent point in time even when the journal is paged.
struct PrivacySafeDataInventory: Codable, Equatable, Sendable {
    struct NestedActivityCounts: Codable, Equatable, Sendable {
        let investmentLots: Int
        let investmentDisposals: Int
        let investmentPricePoints: Int
        let investmentCorrections: Int
        let savingsGoalMovements: Int
        let savingsGoalResets: Int
        let loanActivities: Int
        let allowanceUsages: Int
    }

    let formatVersion: Int
    let generatedAt: Date
    let appVersion: String
    let buildNumber: String
    let databaseSchemaVersion: Int32
    let storedRecordCounts: [String: Int]
    let nestedActivityCounts: NestedActivityCounts
    let nestedActivityCountsComplete: Bool
    let pendingLockedCaptureCount: Int
    let quarantinedRecordCount: Int
    let budgetStatusWidgetEnabled: Bool

    init(
        snapshot: DatabaseRecordCountSnapshot,
        investmentHoldings: [InvestmentHolding],
        savingsGoals: [SavingsGoal],
        loanPlans: [LoanPlan] = [],
        allowancePlans: [AllowancePlan] = [],
        generatedAt: Date? = nil,
        appVersion: String,
        buildNumber: String,
        pendingLockedCaptureCount: Int,
        quarantinedRecordCount: Int,
        budgetStatusWidgetEnabled: Bool
    ) {
        formatVersion = 1
        self.generatedAt = generatedAt ?? snapshot.createdAt
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        databaseSchemaVersion = snapshot.schemaVersion
        self.pendingLockedCaptureCount = pendingLockedCaptureCount
        self.quarantinedRecordCount = quarantinedRecordCount
        self.budgetStatusWidgetEnabled = budgetStatusWidgetEnabled

        storedRecordCounts = Dictionary(uniqueKeysWithValues: RecordCollection.allCases.map {
            ($0.rawValue, snapshot.count(in: $0))
        })
        nestedActivityCountsComplete = investmentHoldings.count
            == snapshot.count(in: .investmentHoldings)
            && savingsGoals.count == snapshot.count(in: .savingsGoals)
            && loanPlans.count == snapshot.count(in: .loanPlans)
            && allowancePlans.count == snapshot.count(in: .allowancePlans)
        nestedActivityCounts = NestedActivityCounts(
            investmentLots: investmentHoldings.reduce(0) { $0 + $1.lots.count },
            investmentDisposals: investmentHoldings.reduce(0) {
                $0 + $1.disposals.count
            },
            investmentPricePoints: investmentHoldings.reduce(0) {
                $0 + $1.priceHistory.count
            },
            investmentCorrections: investmentHoldings.reduce(0) {
                $0 + $1.corrections.count
            },
            savingsGoalMovements: savingsGoals.reduce(0) {
                $0 + $1.movements.count
            },
            savingsGoalResets: savingsGoals.reduce(0) { $0 + $1.resets.count },
            loanActivities: loanPlans.reduce(0) { $0 + $1.activities.count },
            allowanceUsages: allowancePlans.reduce(0) { $0 + $1.usages.count }
        )
    }

    func storedRecordCount(in collection: RecordCollection) -> Int {
        storedRecordCounts[collection.rawValue] ?? 0
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    var defaultFilename: String {
        let safeVersion = appVersion.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let safeBuild = buildNumber.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let epoch = generatedAt.timeIntervalSince1970.rounded(.down)
        let epochSecond = epoch.isFinite
            && epoch >= Double(Int.min)
            && epoch <= Double(Int.max)
            ? Int(epoch)
            : 0
        return "MoneyUp-Inventory-\(safeVersion)-\(safeBuild)-\(epochSecond).json"
    }
}

struct PrivacySafeDataInventoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    private var data: Data

    init(inventory: PrivacySafeDataInventory? = nil) {
        if let inventory, let encoded = try? inventory.encodedJSON() {
            data = encoded
        } else {
            data = Data("{}\n".utf8)
        }
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
