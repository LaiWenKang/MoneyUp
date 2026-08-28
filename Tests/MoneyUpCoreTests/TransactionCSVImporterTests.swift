import Foundation
@testable import MoneyUpCore
import Testing

struct TransactionCSVImporterTests {
    @Test
    func parsesGenericCSVWithQuotedCommasAndBOM() throws {
        let csv = """
        \u{feff}Date,Type,Amount,Account,Category,Payee,Note
        2026-08-20 12:30:00,Expense,12.50,Wallet,Food,"Cafe, One","Lunch, tea"
        2026-08-21 09:00:00,Income,1000,Bank,Salary,Employer,
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.count == 2)
        #expect(preview.rows[0].kind == .expense)
        #expect(preview.rows[0].amount == Decimal(string: "12.50"))
        #expect(preview.rows[0].payee == "Cafe, One")
        #expect(preview.rows[0].note == "Lunch, tea")
        #expect(preview.rows[1].kind == .income)
    }

    @Test
    func parsesChineseQianjiStyleHeadersAndRefund() throws {
        let csv = """
        时间,账单类型,金额,资产账户,分类,交易对象,备注,账单ID
        2026-08-20 12:30:00,支出,12.50,现金,餐饮,咖啡店,午餐,a-1
        2026-08-21 12:30:00,退款,3.00,现金,餐饮,咖啡店,退差价,a-2
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "zh_CN"),
            timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.kind) == [.expense, .refund])
        #expect(preview.rows[0].accountName == "现金")
        #expect(preview.rows[0].id != preview.rows[1].id)
    }

    @Test
    func externalIDsAreMarkedAndRemainCaseSensitiveInV2Fingerprint() throws {
        let csv = """
        ID,Date,Type,Amount,Payee
        Source-A,2026-08-20,Expense,12,Cafe
        source-a,2026-08-20,Expense,12,Cafe
        ,2026-08-20,Expense,12,Cafe
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.hasExternalID) == [true, true, false])
        #expect(preview.rows[0].id != preview.rows[1].id)
        #expect(preview.rows[0].id.hasPrefix("sha256:external:v1:"))
        #expect(preview.rows[0].id == "sha256:external:v1:6d1b1e808a3167ed8e98e8089c39cd432b793a4d75b6c3f87e4c6c2469ac13c9")
        #expect(preview.rows[1].id.hasPrefix("sha256:external:v1:"))
        #expect(preview.rows[2].id.hasPrefix("sha256:v2:"))
    }

    @Test
    func v2FingerprintCaseFoldsOnlyHumanFields() throws {
        let csv = """
        Date,Type,Amount,Currency,Account,Destination Account,Category,Payee,Note
        2026-08-20,Expense,12,sgd,Cash,Savings,Food,Cafe,Lunch
        2026-08-20,EXPENSE,12,SGD,CASH,SAVINGS,FOOD,CAFE,LUNCH
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows[0].id == preview.rows[1].id)
    }

    @Test
    func correctedRowsWithSameExternalIDKeepOneAuthoritativeIdentity() throws {
        let csv = """
        ID,Date,Type,Amount,Account,Category,Payee,Note
        Bank-Exact-42,2026-08-20,Expense,12,Wallet,Food,Cafe,Lunch
        Bank-Exact-42,2026-08-21,Income,99,Bank,Salary,Employer,Correction
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        let allRowsHaveExternalIDs = preview.rows.allSatisfy {
            $0.hasExternalID
        }
        #expect(allRowsHaveExternalIDs)
        #expect(preview.rows[0].id == preview.rows[1].id)
        #expect(preview.rows[0].legacyFingerprintCandidates
            != preview.rows[1].legacyFingerprintCandidates)
    }

    @Test
    func persistenceFingerprintUsesCanonicalSourceNamespace() {
        let identity = "sha256:external:v1:fixture"
        let first = TransactionCSVImporter.persistenceFingerprint(
            for: identity,
            sourceSystem: "  Bank   Feed  "
        )
        let canonicalEquivalent = TransactionCSVImporter.persistenceFingerprint(
            for: identity,
            sourceSystem: "bank feed"
        )
        let otherSource = TransactionCSVImporter.persistenceFingerprint(
            for: identity,
            sourceSystem: "Card Feed"
        )

        #expect(first.hasPrefix("sha256:import:v1:"))
        #expect(first == "sha256:import:v1:e811734d4c5cf389b4c84457c04574475fad170374e45cb0af2e330103cee1ff")
        #expect(first == canonicalEquivalent)
        #expect(first != otherSource)
    }

    @Test
    func parsedRowsCarryHashedLegacyCompatibilityCandidates() throws {
        let preview = try TransactionCSVImporter.parse(
            "ID,Date,Type,Amount\nLegacy-42,2026-08-20,Expense,12\n",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let row = try #require(preview.rows.first)

        #expect(row.legacyFingerprintCandidates.contains {
            $0.hasPrefix("fnv1a64:")
        })
        #expect(row.legacyFingerprintCandidates.contains(
            "fnv1a64:c9ce4f424ef7eb9f"
        ))
        #expect(row.legacyFingerprintCandidates.contains {
            $0.hasPrefix("sha256:v2:")
        })
        #expect(!row.legacyFingerprintCandidates.contains(row.id))
    }

    @Test
    func v2FingerprintCannotCollideAcrossComponentSeparators() throws {
        let separator = "\u{1f}"
        let csv = """
        Date,Type,Amount,Account,Destination Account
        2026-08-20,Expense,12,Cash\(separator)Reserve,Savings
        2026-08-20,Expense,12,Cash,Reserve\(separator)Savings
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows[0].id != preview.rows[1].id)
    }

    @Test
    func foreignTransferDestinationAmountParticipatesInFingerprint() throws {
        let csv = """
        Date,Type,Amount,Destination Amount,Currency,Account,Destination Account
        2026-08-20,Transfer,100,75,SGD,Wallet,Overseas
        2026-08-20,Transfer,100,76,SGD,Wallet,Overseas
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.destinationAmount) == [Decimal(75), Decimal(76)])
        #expect(preview.rows[0].id != preview.rows[1].id)
    }

    @Test
    func explicitlyInvalidOrZeroDestinationAmountsAreRowIssues() throws {
        let csv = """
        Date,Type,Amount,Destination Amount
        2026-08-20,Transfer,100,0
        2026-08-21,Transfer,100,-0
        2026-08-22,Transfer,100,not-a-number
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.isEmpty)
        #expect(preview.issues.map(\.reason) == [
            "invalid_destination_amount",
            "invalid_destination_amount",
            "invalid_destination_amount"
        ])
    }

    @Test
    func safelyAcceptsForeignDecimalSeparatorWithoutTurningItIntoThousands() throws {
        let csv = "Date;Type;Amount\n2026-08-20;Expense;12,50\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.first?.amount == Decimal(string: "12.50"))
    }

    @Test
    func previewsBadRowsInsteadOfDroppingWholeFile() throws {
        let csv = """
        Date,Type,Amount
        bad date,Expense,12
        2026-08-20,Debt,10
        2026-08-21,Income,5
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.issues.map(\.reason) == ["invalid_date", "unsupported_type"])
    }

    @Test
    func parsesYNABOutflowAndInflowColumns() throws {
        let csv = """
        Date,Payee,Category,Memo,Outflow,Inflow
        2026-08-20,Shop,Food,,12.50,
        2026-08-21,Employer,Salary,,,2000
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.map(\.kind) == [.expense, .income])
    }

    @Test
    func rejectsMoneyUpPostingExportRatherThanDuplicatingJournalRows() {
        let csv = "entry_id,posting_id,occurred_at,amount,currency\na,b,2026-08-20,-5,SGD\n"

        do {
            _ = try TransactionCSVImporter.parse(csv)
            Issue.record("Expected the posting-level export to be rejected")
        } catch let error as TransactionCSVImportError {
            #expect(error == .postingLevelExportRequiresArchive)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func mapsUnknownHeadersWithoutGuessingColumns() throws {
        let csv = "When,Flow,Value,Wallet Name,Bucket\n2026-08-26,Expense,12.50,Cash,Food\n"
        let inspection = try TransactionCSVImporter.inspect(csv)
        #expect(!inspection.suggestedMapping.hasRequiredColumns)

        var mapping = CSVColumnMapping()
        mapping[.date] = 0
        mapping[.kind] = 1
        mapping[.amount] = 2
        mapping[.account] = 3
        mapping[.category] = 4
        let preview = try TransactionCSVImporter.parse(
            csv,
            mapping: mapping,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.rows[0].accountName == "Cash")
        #expect(preview.rows[0].categoryName == "Food")
    }

    @Test
    func mappingsRequireDirectionAndDistinctInRangeColumns() throws {
        var mapping = CSVColumnMapping(columns: [.date: 0, .amount: 2])
        #expect(!mapping.hasRequiredColumns)

        mapping[.kind] = 1
        #expect(mapping.hasRequiredColumns)

        mapping[.kind] = 0
        #expect(!mapping.hasRequiredColumns)

        mapping = CSVColumnMapping(columns: [.date: -1, .outflow: 2])
        #expect(!mapping.hasRequiredColumns)

        let outOfRange = CSVColumnMapping(columns: [
            .date: 0,
            .kind: 1,
            .amount: 99
        ])
        do {
            _ = try TransactionCSVImporter.parse(
                "When,Flow,Value\n2026-08-20,Expense,12\n",
                mapping: outOfRange
            )
            Issue.record("Expected an out-of-range mapping to be rejected")
        } catch let error as TransactionCSVImportError {
            #expect(error == .missingRequiredColumns)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func amountOnlyFileIsNotReportedAsActionablyMapped() throws {
        let inspection = try TransactionCSVImporter.inspect(
            "Date,Amount\n2026-08-20,12\n"
        )
        #expect(!inspection.suggestedMapping.hasRequiredColumns)

        do {
            _ = try TransactionCSVImporter.parse(
                "Date,Amount\n2026-08-20,12\n"
            )
            Issue.record("Expected a directionless amount mapping to be rejected")
        } catch let error as TransactionCSVImportError {
            #expect(error == .missingRequiredColumns)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func preservesExplicitImportOffsetForStableOriginDay() throws {
        let csv = "Date,Type,Amount\n2026-08-27T00:30:00+14:00,Expense,5\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.first?.originContext?.dayKey == 20260827)
        #expect(preview.rows.first?.originContext?.utcOffsetSeconds == 14 * 3_600)
    }

    @Test
    func rejectsGarbageSuffixInsteadOfSilentlyTruncatingAmount() throws {
        let csv = "Date,Type,Amount\n2026-08-20,Expense,12abc\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.isEmpty)
        #expect(preview.issues.map(\.reason) == ["invalid_amount"])
    }

    @Test
    func rejectsOversizedAmountTokensBeforeNumericParsing() throws {
        let csv = "Date,Type,Amount\n2026-08-20,Expense,"
            + String(repeating: "1", count: 129)
            + "\n"

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.isEmpty)
        #expect(preview.issues.map(\.reason) == ["invalid_amount"])
    }

    @Test
    func enforcesMonetaryNewWriteBoundaryDuringPreview() throws {
        let maximum = NSDecimalNumber(
            decimal: MonetaryInputPolicy.maximumAbsoluteNewWrite
        ).stringValue
        let csv = """
        Date,Type,Amount
        2026-08-20,Expense,\(maximum)
        2026-08-21,Expense,1000000000000000
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.rows[0].amount == MonetaryInputPolicy.maximumAbsoluteNewWrite)
        #expect(preview.issues.map(\.reason) == ["invalid_amount"])
    }

    @Test
    func enforcesDeclaredCurrencyPrecisionDuringPreview() throws {
        let csv = """
        Date,Type,Amount,Currency
        2026-08-20,Expense,1.5,JPY
        2026-08-21,Expense,2,JPY
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.map(\.amount) == [Decimal(2)])
        #expect(preview.issues.map(\.reason) == ["invalid_amount"])
    }

    @Test
    func acceptsOnlyRecognizedCurrencyDecorationsAroundCompleteAmount() throws {
        let csv = """
        Date,Type,Amount
        2026-08-20,Expense,$12.50
        2026-08-21,Income,SGD 8.25
        2026-08-22,Refund,7.00 SGD
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.amount) == [
            Decimal(string: "12.50")!,
            Decimal(string: "8.25")!,
            Decimal(string: "7.00")!
        ])
    }

    @Test
    func ambiguousSlashDateUsesImportLocaleOrder() throws {
        let csv = "Date,Type,Amount\n03/04/2026,Expense,1\n"
        let utc = TimeZone(secondsFromGMT: 0)!

        let us = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US"),
            timeZone: utc
        )
        let gb = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_GB"),
            timeZone: utc
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        #expect(calendar.component(.month, from: us.rows[0].occurredAt) == 3)
        #expect(calendar.component(.day, from: us.rows[0].occurredAt) == 4)
        #expect(calendar.component(.month, from: gb.rows[0].occurredAt) == 4)
        #expect(calendar.component(.day, from: gb.rows[0].occurredAt) == 3)
    }

    @Test
    func explicitTypeCanUseMappedOutflowAndInflowWithoutAmountColumn() throws {
        let csv = """
        Date,Type,Outflow,Inflow
        2026-08-20,Expense,12.50,
        2026-08-21,Income,,2000
        2026-08-22,Refund,,3.25
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.issues.isEmpty)
        #expect(preview.rows.map(\.kind) == [.expense, .income, .refund])
        #expect(preview.rows.map(\.amount) == [
            Decimal(string: "12.50")!,
            Decimal(2000),
            Decimal(string: "3.25")!
        ])
    }

    @Test
    func rejectsContradictoryOrMismatchedFlowColumns() throws {
        let csv = """
        Date,Type,Amount,Outflow,Inflow
        2026-08-20,Expense,,12,5
        2026-08-21,Income,10,,9
        2026-08-22,Income,,4,
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.isEmpty)
        #expect(preview.issues.map(\.reason) == [
            "invalid_amount", "invalid_amount", "invalid_amount"
        ])
    }

    @Test
    func rejectsMalformedQuotePlacementAndTrailingCharacters() {
        let malformedInputs = [
            "Date,Type,Amount\n2026-08-20,Exp\"ense,12\n",
            "Date,Type,Amount\n2026-08-20,\"Expense\"oops,12\n"
        ]

        for csv in malformedInputs {
            do {
                _ = try TransactionCSVImporter.parse(csv)
                Issue.record("Expected malformed quote placement to be rejected")
            } catch let error as TransactionCSVImportError {
                #expect(error == .malformedCSV)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func enforcesHeaderFieldAndColumnBoundaries() throws {
        let maximumHeader = String(
            repeating: "H",
            count: TransactionCSVImporter.maximumHeaderByteCount
        )
        let acceptedInspection = try TransactionCSVImporter.inspect(
            "\(maximumHeader),Type,Amount\nvalue,Expense,1\n"
        )
        #expect(acceptedInspection.headers[0] == maximumHeader)

        let maximumNote = String(
            repeating: "n",
            count: TransactionCSVImporter.maximumFieldByteCount
        )
        let acceptedPreview = try TransactionCSVImporter.parse(
            "Date,Type,Amount,Note\n2026-08-20,Expense,1,\(maximumNote)\n",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(acceptedPreview.rows.first?.note == maximumNote)

        let tooManyHeaders = (0...TransactionCSVImporter.maximumColumnCount)
            .map { "C\($0)" }
            .joined(separator: ",")
        let malformedInputs = [
            String(
                repeating: "H",
                count: TransactionCSVImporter.maximumHeaderByteCount + 1
            ) + ",Type,Amount\nvalue,Expense,1\n",
            "Date,Type,Amount,Note\n2026-08-20,Expense,1,"
                + String(
                    repeating: "n",
                    count: TransactionCSVImporter.maximumFieldByteCount + 1
                ) + "\n",
            tooManyHeaders + "\n",
            "Date,Date,Type,Amount\n2026-08-20,2026-08-20,Expense,1\n"
        ]

        for csv in malformedInputs {
            do {
                _ = try TransactionCSVImporter.inspect(csv)
                Issue.record("Expected the structural CSV limit to be enforced")
            } catch let error as TransactionCSVImportError {
                #expect(error == .malformedCSV)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func rejectsInputBeyondCoreByteBoundaryBeforeParsing() {
        let oversized = String(
            repeating: "x",
            count: TransactionCSVImporter.maximumInputByteCount + 1
        )

        do {
            _ = try TransactionCSVImporter.inspect(oversized)
            Issue.record("Expected the core input byte limit to be enforced")
        } catch let error as TransactionCSVImportError {
            #expect(error == .inputTooLarge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func datesMustConsumeTheCompleteToken() throws {
        let csv = """
        Date,Type,Amount
        2026-08-20 trailing,Expense,1
        2026-02-31,Expense,1
        2026-08-20,Expense,1
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.issues.map(\.reason) == ["invalid_date", "invalid_date"])
    }

    @Test
    func rejectsRowsBeyondTheAggregateImportBudgetDuringParsing() {
        let header = "Date,Type,Amount\n"
        let row = "2026-08-20,Expense,1\n"
        let csv = header + String(
            repeating: row,
            count: MonetaryInputPolicy.aggregateRecordBudget + 1
        )

        do {
            _ = try TransactionCSVImporter.parse(csv)
            Issue.record("Expected oversized row count to be rejected")
        } catch let error as TransactionCSVImportError {
            #expect(error == .tooManyRows)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func issueLinesRemainPhysicalAfterQuotedMultilineFields() throws {
        let csv = """
        Date,Type,Amount,Note
        2026-08-20,Expense,12,"first line
        second line"
        bad date,Expense,3,invalid
        """

        let preview = try TransactionCSVImporter.parse(
            csv,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(preview.rows.count == 1)
        #expect(preview.rows.first?.sourceLine == 2)
        #expect(preview.rows.first?.note == "first line\nsecond line")
        #expect(preview.issues.map(\.line) == [4])
    }
}
