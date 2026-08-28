# MoneyUp 0.6.0 Comprehensive Quality Audit

Audit date: 27 August 2026

Baseline: `b0ac219e0eabf0888358dbb0154b1071c35aed66` (`main`)

Review branch: `codex/comprehensive-quality-audit-0.6.0`

## Outcome

**Release decision: blocked.** No P0 defect was found, and the review fixed a
set of P1/P2 correctness, recovery, privacy, input-boundary, and evidence
problems. One product P1 remains: a receipt-heavy book can lose portable-backup
availability, and backup construction reaches its shared 250 MB limit only
after materializing the complete logical book through multiple whole-buffer
copies. Exact-candidate macOS CI, code coverage, physical
power-interruption, accessibility, performance, and upgrade/restore evidence
also remain open.

This report does not claim that software can be proven bug-free. It records
what was inspected, what changed, what evidence exists, and what is still
required before a user should trust the candidate with irreplaceable data.

## Authority and reviewed inputs

1. `MoneyUp_Golden_PRD_v1.0_2026-08-26(1).docx` is controlling. The uploaded
   filename/Library label calls it v1.1 in one place, while the document itself
   is titled Golden PRD v1.0 and is effective 26 August 2026. The internal title
   and effective date were used.
2. `MoneyUp-0.4.0-Audit(1).pdf` supplies D-01 through D-23 and the original
   risk evidence.
3. `MoneyUp-PRD-v1.1.pdf` supplies earlier context only where it does not
   conflict with the Golden PRD.
4. Accounting and security invariants take precedence over presentation
   refinements. Later accepted Flexible Today and visual-identity decisions are
   identified as later decisions in `GOLDEN_TRACEABILITY.md`.

Every page of the two PDFs and the rendered Word document was inspected, and
all 97 Golden requirement IDs were extracted and reconciled. The exact matrix
is in [REQUIREMENTS_TEST_MATRIX.md](REQUIREMENTS_TEST_MATRIX.md).

## Scope and inventory

| Item | Audited scope |
|---|---:|
| Baseline tracked files | 175 |
| Candidate tracked files after audit artifacts are added | 180 |
| Swift files | 110 |
| Swift source/test lines | 50,406 |
| Declared automated tests | 384 |
| Core test declarations | 223 |
| Persistence test declarations | 28 |
| App-model test declarations | 133 |
| Golden requirements | 97 / 97 traced |
| Runtime Swift package dependencies | 1 |

The inventory covered `.github`, `App`, `Scripts`, `Sources`, `Tests`, `docs`,
the package/project manifests, entitlements, privacy manifest, asset catalogs,
localization catalogs, legal/support files, release workflows, and all tracked
files. All tracked files were checked for emptiness and parseability where a
machine-readable format applies. Every Swift file participated in repository-
wide lexical review; correctness/security/recovery paths were manually traced
across callers, state transitions, persistence operations, and consumers.
The closed, filename-by-filename manifest and review treatment are in
[FILE_REVIEW_INVENTORY.md](FILE_REVIEW_INVENTORY.md).

## Architecture and cross-feature map

| Boundary | Owns | Cross-feature effects reviewed |
|---|---|---|
| SwiftUI app/views | User input, routing, accessibility, disclosure | Log, History, Today, Insights, Plan, Calendar, Assets, Settings, Data Safety |
| `AppModel` (`@MainActor`) | Lifecycle serialization and coherent published state | Draft/save/lock races; account/category lifecycle; schedules; goals; investments; imports; backup/restore; widget publication |
| `MoneyUpCore` | Pure Decimal/accounting/domain rules | Journal balance, minor units, reports, periods, rates, recurrence, rollover, goals, lots/FIFO, CSV/XLSX |
| `MoneyUpPersistence` | SQLCipher actor, normalized indexes, atomic batches, snapshots | Journal pages/events, attachment metadata, quarantine, schema migration, portable archives |
| Locked capture boundary | Separate device-only key and redacted encrypted FIFO | Cold widget/deep link, authenticated draft promotion, exactly-once journal handoff |
| Widget boundary | App Group percentage/state snapshot only | Explicit opt-in, expiry, redaction, lock survival, erase/no-book scrubbing |

The highest-coupling paths were followed end to end:

| Action | Required atomic/consistent consumers |
|---|---|
| Journal save/edit/delete | SQLCipher record and index, revision, draft deletion, attachment link, balances, budget attribution/rollover, reports, History/Calendar, widget snapshot |
| Account/category lifecycle | Journal references, budgets/timeline, schedules, holdings/positions, profile defaults, current draft, historical audit |
| Reporting-zone change/travel | History bounds, period reports, budget month, goals, schedules, rates, snapshots, widget expiry |
| Schedule post/match/edit/delete | Schedule occurrence state, linked journal entry, audit link, derived projections, restore/lifecycle barriers |
| Investment purchase/sale/reprice/correct | Cash and position postings, lots/disposals, holdings, net worth, snapshots, protected deletion rules |
| Restore | Every collection identity/relationship, domain decode, indexes, live replacement rollback, preferences, current UI state |

## Review and test-design methods

- Requirement analysis and a 97-row RTM with at least one named automated or
  manual case per requirement.
- File/directory/configuration inventory, dependency provenance review, and
  static scans for unsafe error suppression, force operations, dynamic SQL,
  runtime networking, secrets, raw diagnostics, stale schemas, dead settings,
  unbounded file reads, non-finite dates, and unchecked arithmetic.
- Equivalence partitions for transaction kinds, account/category kinds,
  currencies, CSV dialects, date grammars, archive versions, queue states, and
  valid/malformed relationship classes.
- Boundary cases at zero/nonzero, currency minor units, Decimal magnitude,
  byte/row/count caps, exact period ends, seven-day stale price, schedule
  occurrence boundaries, archive version/KDF/password limits, and file-size
  sentinels.
- Positive and negative cases for wrong password, tamper, duplicates,
  cancellation, missing/orphan references, ambiguous dates, malformed quotes,
  garbage numeric suffixes, archived targets, overflow, clock rollback, and
  unsupported future schemas.
- Interaction/race cases for lock/save, draft debounce/save, scan/lock,
  erase/commit, restore/profile/goal/schedule barriers, stale generations,
  capture promotion/removal, and concurrent rate/goal writes.
- Stress fixtures for 10,000 journal entries, 20,000 accepted import rows,
  bounded recurrence, large receipt metadata indexes, extreme Decimal values,
  and multi-page sparse History matches.
- Interruption reasoning and deterministic checkpoints around SQLCipher commit,
  restore replacement, draft persistence, capture handoff, schedules, goals,
  investments, and snapshots. Actual process termination/power removal still
  requires the physical cases below.

## Findings fixed on the review branch

| ID | Sev. | Finding and resolution | Regression evidence source |
|---|---:|---|---|
| A-001 | P1 | CSV parsing accepted prefix numbers/ambiguous decorations and weak row/date/quote boundaries. It now requires full tokens, locale-aware dates, consistent flow/type columns, physical line reporting, a 20,000-row cap, a 128-byte amount cap, and SHA-256 fingerprints. | `TransactionCSVImporterTests` negative/boundary suite |
| A-002 | P1 | Skipped import rows could leak proposed categories/trading accounts, and a matching archived category could receive new postings. Candidate state now rolls back per failed row and active target checks are enforced. | `testSkippedImportRowCannotLeakItsProposedCategoryIntoLaterCommit`; `testImportNeverPostsToArchivedCategoryWithMatchingName` |
| A-003 | P1 | Restore identity/relationship validation missed duplicate logical IDs, exact revision suffixes, unordered inverse-rate duplicates, duplicate split IDs, and transaction-kind-specific split categories. All are rejected before live replacement. | Restore tests at lines 766-1353 of `AppModelTests.swift` |
| A-004 | P1 | A crash/failure after locked-capture draft persistence but before inbox removal could later promote the same capture after its transaction committed. Queue append/remove now return authoritative counts; Save removes any surviving source copy before journal commit while the SQLCipher draft remains retryable. | `testReviewedCaptureRemovalFailureCannotCreateDuplicateTransaction`; `testLockAfterCaptureHandoffCommitsExactlyOnceAndLeavesNoQueueCopy` |
| A-005 | P1 | Restore, import, and locked-capture reads trusted metadata or one-shot `FileHandle` reads. `BoundedFileReader` now loops partial reads through an exact max+1 sentinel; all three call sites enforce limits. | `testBoundedFileReaderConsumesToEOFAndStopsOneBytePastTheLimit` plus import/capture envelope tests |
| A-006 | P1 | Locked capture/UI amount work could parse before rejecting oversized input. All money text now has a 128-byte pre-parse ceiling; payee/note/date/count/uniqueness are bounded. | `testLockedCaptureRejectsUnboundedOrInvalidEnvelopeFields`; oversized CSV token test |
| A-007 | P1 | Schedule, savings-goal, and investment lifecycle dates admitted non-finite values in some construction/mutation/decode paths. All affected boundaries now reject them before mutation. | `testScheduleRejectsNonFiniteLifecycleDatesAtEveryWriteBoundary`; goal/investment non-finite suites |
| A-008 | P1 | Investment disposals did not centrally validate finite dates, positive exact amounts, currency consistency, realized arithmetic, or deterministic sequence. The model now validates and throws without consuming lots on failure. | Expanded `InvestmentPortfolioTests` |
| A-009 | P1 | Recovery quarantine did not fully reject parent cycles/kind mismatches, shared investment positions, or ledger mismatches. Relationship validation/quarantine now prevents affected data entering calculations. | account/investment restore and book-validation tests |
| A-010 | P1 | Auto-lock treated clock rollback/invalid elapsed time as not expired. It now fails closed at negative/non-finite elapsed time and exact timeout. | `testAutoLockUsesExactBoundaryAndTreatsClockRollbackAsUnsafe`; `testZeroDelayAndInvalidLifecycleClockLockImmediately` |
| A-011 | P2 | Receipt media sniffing could mislabel unrelated ISO-base media/random bytes. JPEG/PNG signatures and HEIC `ftyp` box/brand validation are now exact; unknown media is rejected. | `ReceiptAttachmentTests` |
| A-012 | P2 | Some write/domain errors were not guaranteed safe/localized, and successful backup/restore retained passwords in SwiftUI state. Safe presentation coverage was expanded and passwords clear after success. | safe-error tests; `DataSafetyView` review |
| A-013 | P2 | Category suggestion ties depended on input order. Tie-breaking is stable and deterministic. | `testEqualCountAndRecencyTieIsDeterministicAcrossInputOrder` |
| A-014 | P2 | Decimal keyboards lacked a reliable Done route and some Quick Log write failures were inline-only. Shared keyboard toolbars and an accessible alert/field errors were added. | source review; physical accessibility case remains open |
| A-015 | P2 | CI did not retain coverage evidence and mutable tool/action resolution weakened reproducibility. Actions are commit-pinned, XcodeGen is checksum-verified, core warnings are errors, and both coverage reports are uploaded. | `.github/workflows/ci.yml`; exact run open |
| A-016 | P2 | Portable archive input checks lacked independent PBKDF vectors and strict malformed version/KDF/password coverage. These boundaries and tests were added. | `testPortableArchivePBKDFMatchesIndependentSHA256Vectors` and archive negative tests |
| A-017 | P3 | A no-op OCR downcast produced a warning and schema documentation still named an old schema. The cast was removed and docs now identify schema 4/current collections. | static review and release validator |
| A-018 | P1 containment | Backup and restore used separate literal size policy and could present an archive as ready even when the same UI would reject it. One public 250 MB limit now governs seal, open, and bounded file import with a safe bilingual error. This contains false success but does not close O-001's buffering/availability risk. | portable archive boundary assertions; release validator |

## Open findings and blockers

### O-001 — P1: receipt-heavy books can lose backup availability or exhaust memory

`EncryptedRecordStore.snapshot()` fetches every record payload into one
`DatabaseSnapshot`. `PortableArchive.seal` JSON-encodes that snapshot, encrypts
the entire JSON with one-shot AES-GCM, then JSON/base64-encodes the ciphertext
again. Restore reads the whole archive into `Data`. This audit made seal, open,
and the UI share one 250,000,000-byte boundary, so the reviewed build will not
export an archive it refuses by size. However, seal discovers an oversized
archive only after allocating the raw snapshot, inner JSON, ciphertext, and
outer JSON, and the user receives no complete portable backup. A receipt may be
15,000,000 bytes and there is no aggregate attachment limit.

Because `Data` is base64-encoded in both the snapshot JSON and outer envelope,
ten maximum-size receipts alone can approach 267 MB before other records and
metadata (`150 MB × 4/3 × 4/3`). This is a source-derived upper-bound estimate,
not a device measurement. The backup path also temporarily retains the raw
snapshot payloads, inner JSON, ciphertext, outer JSON, and SwiftUI document
data, creating an out-of-memory risk below the restore cap.

Required resolution before release:

1. Design a version-2 chunked/streaming authenticated archive with explicit
   aggregate/chunk bounds and backward-compatible v1 restore.
2. Stream SQLCipher records/attachments rather than materializing every
   payload, and write/read the archive through a file URL.
3. Add interruption tests between chunks, corrupted/truncated chunk tests,
   aggregate-limit tests, and a physical restore of a near-limit receipt book.
4. Until v2 exists, do not represent small archive round-trip tests as proof
   that every book is recoverable.

This blocks POR-04, POR-05, SEC-05, QA-05, and public release.

### O-002 — P1 evidence: exact-candidate compilation/tests/coverage not run

The Linux review environment has no `swift`, `xcodebuild`, `xcodegen`,
`swiftlint`, `semgrep`, or Apple Simulator. The branch could not be pushed
because the HTTPS GitHub remote has no credentials, and `gh` is unavailable.
Therefore none of the 384 declared tests, warnings-as-errors compilation,
app/widget build, or coverage reports ran against this exact branch. The last
baseline `main` workflow was green, but it predates these changes and is not
candidate evidence.

Required resolution: push this branch, run the pinned CI workflow, inspect all
failures/warnings, publish the two coverage artifacts, review uncovered
critical branches, and repeat on the final SHA.

### O-003 — P1 release evidence: physical and exact-binary gates remain open

Open cases include real background termination/power loss, 0.5.1-to-0.6.0
TestFlight installation, clean-device restore, passcode/biometry/Keychain
behavior, app-switcher and widget privacy, all widget families/appearances,
English/Simplified Chinese, VoiceOver, largest Dynamic Type, Reduce Motion,
oldest/current iPhones, receipt/photo-picker behavior, and the Golden p95
budgets with 10,000 entries and 20 schedules. `FIRST_TEST.md` is the execution
runbook; a document is not a pass result.

## Independent 0.4.0 audit closure map

All D-01 through D-23 have a source-level correction and regression/manual
anchor in the current tree. Their exact-candidate execution state remains open.

| Audit ID | Source-level closure | Evidence anchor |
|---|---|---|
| D-01 | Locale-matched editable amount and unchanged reconciliation no-op | amount parser/keyboard and account-balance tests |
| D-02 | Purchases move cash to a ledger-linked position | investment no-double-count tests |
| D-03 | Currency minor units/new-write magnitude/checked Decimal | `MoneyTests`, write-boundary tests |
| D-04 | Foreign spending is retained/disclosed; dated rates are explicit | period/rate/Plan cases |
| D-05 | Malformed records quarantine while raw data remains recoverable | persistence quarantine/recovery cases |
| D-06 | Shared Gregorian half-open boundaries | financial-period and midnight tests |
| D-07 | `DerivedValue` propagates unavailable state rather than zero | invalid budget/goal/net-worth tests |
| D-08 | Account/source/destination currency labels | Quick Log source plus physical label case |
| D-09 | Refund route/UI/parser reverse expense | refund factory/parser/filter/report cases |
| D-10 | Direct/bounded occurrence lookup and range-scoped Calendar query | recurrence and Calendar cases |
| D-11 | Retired inert lock flag; real archive lifecycle actions | profile migration/lifecycle cases |
| D-12 | Latin word boundaries, retained CJK substring matching | smart-entry boundary cases |
| D-13 | Locale-aware smart/receipt amount grammar | smart/receipt comma-decimal cases |
| D-14 | Trailing 12-month trend independent of selected period | trend-context tests |
| D-15 | Key retrieval and SQLCipher open run in a detached task | `AppModel.start`; physical unlock p95 open |
| D-16 | Currency formatter cache keyed by locale/currency | `MoneyFormatterCache`; physical scroll open |
| D-17 | Shared `accountsByID` index used by rows | `AppModel.accountsByID`, `TransactionRow` |
| D-18 | Budget tree cache keyed by revision/profile | budget-cache invalidation test |
| D-19 | Calendar performs one indexed range load for the selected day | `CalendarView.loadSelectedActuals` |
| D-20 | Normalized journal/posting indexes, bounded recent cache, keyset pages | 10,000-entry persistence/history tests |
| D-21 | Widget uses semantic adaptive assets/styles | widget appearance matrix open |
| D-22 | CSV begins with BOM | exporter/importer tests |
| D-23 | Empty Calendar omits flow; multiple currencies are labeled | daily-flow tests and physical UI case |

## Dependency and supply-chain review

| Component | Resolution | Review result / residual risk |
|---|---|---|
| SQLCipher.swift / SQLCipher 4.18.0 | Exact Git revision `f879fffaaa3ad3541a77830daad4a28726dfa927`; official binary target/checksum in upstream manifest | Only runtime package; no MoneyUp runtime networking. License/notices are present. The upstream wrapper/release was inspected, but a binary XCFramework is not equivalent to a reproducible source build or independent binary audit. |
| XcodeGen 2.46.0 | CI downloads the official release and verifies SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` | CI-only build tool; checksum pinned. |
| `actions/checkout` 7.0.1 | Commit `3d3c42e5aac5ba805825da76410c181273ba90b1` | Immutable CI pin, `persist-credentials: false`. |
| `actions/upload-artifact` 4.6.2 | Commit `ea165f8d65b6e75b540449e92b4886f43607fa02` | Immutable CI pin. |

Primary references: [SQLCipher.swift 4.18.0](https://github.com/sqlcipher/SQLCipher.swift/releases/tag/4.18.0),
[SQLCipher 4.18.0](https://github.com/sqlcipher/sqlcipher/releases/tag/v4.18.0),
[XcodeGen releases](https://github.com/yonaskolb/XcodeGen/releases),
[checkout 7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1), and
[upload-artifact 4.6.2](https://github.com/actions/upload-artifact/releases/tag/v4.6.2).

No SBOM/CVE scanner (`syft`, `osv-scanner`, `trivy`) was available. That is a
residual evidence gap, not evidence of no vulnerabilities.

## Local verification completed

| Check | Result |
|---|---|
| `Scripts/validate_release_assets.py` | Pass: bilingual localization, offline boundary, privacy manifest, Info.plist, icons/brand, docs, fixture, project, and TestFlight workflow checks |
| Localization/JSON/plist parsing | Pass |
| `git diff --check` | Pass |
| Tracked empty-file scan | Pass |
| Runtime-network API/source scan | Pass: no runtime networking path found |
| TODO/FIXME and merge-marker scan | Pass in shipped source/configuration |
| Dynamic SQL review | User data is prepared/bound; `sqlite3_exec` use is limited to constant schema/transaction/PRAGMA statements |
| Force/precondition review | Remaining cases are static validated literals, nonempty system buffers, immutable journal preconditions, or test-only construction; no user-data force unwrap was accepted silently |
| Secret-pattern/config review | No committed credential/private-key payload found by local pattern inspection; dedicated secret scanner unavailable |

These are static/local results. They do not replace compiler, test, coverage,
Simulator, signed-binary, or physical evidence.

## Coverage and promotion decision

- Requirement traceability: 97/97.
- Test-source inventory: 384 declarations.
- Exact-branch executed tests: 0 in this environment.
- Exact-branch line/function/branch coverage: unavailable until CI runs.
- Open product P1: O-001 backup/restore scale.
- Open evidence P1s: O-002 exact-candidate CI and O-003 physical/exact-binary gates.

**Do not promote to wider TestFlight or App Review.** First fix O-001, push the
branch, make all exact-candidate CI jobs green, review coverage gaps, then run
the complete physical matrix and reconcile the same candidate SHA/build.
