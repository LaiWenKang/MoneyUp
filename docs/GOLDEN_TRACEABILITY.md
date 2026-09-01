# Golden PRD Traceability - MoneyUp 0.7.0 Candidate

Reconciled: 1 September 2026

This is the requirement-to-evidence map for the retained MoneyUp 0.6.0
migration baseline and the merged 0.7.0 W1/W2 candidate. It prevents
"implemented in source" from being misreported as "released" or "accepted."

The approved 0.6.0 baseline was
`ff272da89de9f4e3cb9c44d4abd27deae7d2b338`. W1 merged through PR #30 at
`da88df25ab06e93ec5998a9edbcf0153587a9af2`; its exact merged-main CI passed.
W2 merged through PR #31 at
`4159df31b7e0b9489d1ddcd84c261296faaeda39`; CI run 246 passed the release,
Core/persistence/intelligence, app-model, and app/widget Simulator gates on that
exact merge SHA. Later candidate commits must repeat those gates. Physical-
device, signed-binary, TestFlight, and release evidence remain open.

The exact 97-row requirement-to-test mapping is in
[REQUIREMENTS_TEST_MATRIX.md](REQUIREMENTS_TEST_MATRIX.md). The complete source,
dependency, defect, test-design, and release-blocker review is in
[QUALITY_AUDIT_0.6.0.md](QUALITY_AUDIT_0.6.0.md), with the closed file manifest
in [FILE_REVIEW_INVENTORY.md](FILE_REVIEW_INVENTORY.md).

## Evidence vocabulary

| Label | Meaning |
|---|---|
| Source implemented | The unified source contains the named behavior and a reviewable implementation/test anchor. It does not prove the final merge compiled. |
| Mac gate open | The final unified SHA still needs the release validator, Swift tests, app-model XCTest, and app/widget Simulator build on macOS. |
| Physical gate open | Timing, device security, appearance, accessibility, migration, restore, or usability must be measured on the required iPhones. |
| Release gate open | TestFlight, founder/co-tester seven-day use, closed beta, exact-binary store review, App Review, release, or monitoring evidence is not complete. |

Local static checks alone may catch localization, JSON, privacy-asset, and
repository-shape errors. They are not substitutes for Mac compilation or
exact-candidate tests. Similarly, a configured CI workflow is not a green
exact-candidate run.

## 0.7.0 W1 architecture traceability

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| W1-OBS | `@Observable AppModel`, `@Environment(AppModel.self)`, the five observable service state owners, and `AppModelTests.testObservationInvalidatesOnlyTrackedAppModelProperties` replace global `ObservableObject` broadcasts with tracked reads. Async persisted settings intentionally retain explicit bindings instead of direct synchronous mutation. | Merged; exact PR-head and merged-main CI passed. |
| W1-SVC | `AppModelServices`, protocol seams, and bounded `AppModel*` extensions separate Ledger, Planning, Assets, Portability, Capture, and Intelligence ownership while the coordinator retains lock, generation, cancellation, and cross-service sequencing. | Merged; automated gate passed; physical performance remains deferred. |
| W1-C12 | `ProfileMutationSerializer`, `testProfileMutationsSerializeAndPreserveLatestUnrelatedChoices`, and `testFailedProfileMutationDoesNotRollBackUnrelatedSetting` enforce FIFO latest-choice convergence and scoped failure isolation without a profile representation change. | Merged; exact merged-main CI passed. |
| W1-TXN | The operation-specific AppModel tests mapped under DAT-09 cover save, edit, delete, split/attachment, import, reconciliation, schedule posting, lifecycle, and goal movement; store rollback tests retain the durable boundary. | Merged; automated gate passed; physical interruption remains deferred. |
| W1-STRUCT | `Scripts/validate_swift_structure.py`, its release-validator invocation, and the explicit CI step enforce 1,200-line files, 600-line type/extension bodies, and 80-line function bodies under `App/` and `Sources/`. | Merged; exact PR-head and merged-main CI passed. |

## 0.7.0 W2 intelligence and configurability traceability

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| W2-MOD | `MoneyUpIntelligence` depends only on `MoneyUpCore`; its exact-Decimal detectors and stable finding contracts have no UI, database, network, logging, or locale dependency. | Merged; exact PR-head and merged-main CI passed. |
| W2-S7 | Schema 7 adds `intelligence_control`, account/source facts, and `payee_affinity_index`. The approved migration decodes only missing metadata inside one transaction and preserves payload bytes, hashes, IDs, and timestamps. | Migration/rollback CI passed; physical upgrade evidence open. |
| W2-AFF | Full-book affinity updates with journal/account lifecycle writes; bounded routine reads decode zero journal payloads. History evidence is user-triggered, exact-ID, and capped at 100. | Indexed read/edit/delete/restore tests passed in merged-main CI. |
| W2-DET | Weekly/monthly/yearly recurrence, lapse, price-step, exact duplicate, and category/currency median-MAD anomaly findings remain explainable and advisory. Transfers/splits and required negative cases fail closed. | Pure tests and committed oracle passed; physical accuracy review open. |
| W2-PROJ | Month-end actuals, confirmed remaining schedules, and flexible burn rate remain separate per currency; missing evidence produces `DV-009`, never zero or FX. | Deterministic app-model tests passed; physical review open. |
| W2-BUD | Suggestions use at least three complete positive months from the trailing six, median plus two MAD, and explicit selected diff. Apply/undo each use one transaction; stale proposals fail before writing. | Atomic app-model tests passed; physical review open. |
| W2-OPT | Legacy profiles default intelligence on. Opt-out serially persists, cancels work, clears findings, and clears derived tables without deleting transactions; re-enable explicitly rebuilds. | Persistence/app tests passed; physical behavior review open. |
| W2-CFG | Settings offers System/English/Simplified Chinese and category management. Log exposes title-or-merchant, description/notes, and add-category without changing ledger meaning. | Compile/localization tests passed; bilingual physical review open. |
| W2-QA | `--profile intelligence` generates 10,000 deterministic KWD/SGD/USD rows and a committed oracle with six positive findings and three negative cases; default release output stays byte-identical. | Validator and Swift oracle passed; physical scale budgets open. |

## 0.7.0 W5 architecture fitness traceability

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| W5.2-FIT | `Scripts/validate_architecture_fitness.py`, focused Python fixtures, its release-validator invocation, and the explicit CI steps enforce reviewed Core/CryptoKit imports, view/factory separation, declared colorsets, bilingual static keys, the offline boundary, conditional Foundation Models output limits, and the documented shipping-Swift safety exceptions. | Source implemented; local static and fixture gates passed; exact merged-candidate CI remains open. |

## Capture and transactions

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| LOG-01 | `TransactionFactory`, `QuickLogSheet`, and `AppModel` cover expense, income, same/foreign-currency transfer, refund, and reconciliation-only adjustment flows. | Source implemented; Mac gate open. |
| LOG-02 | Amount-first center Log, focused routine fields, keyboard actions, and save feedback are in `QuickLogSheet`. | Source implemented; sub-8-second physical median gate open. |
| LOG-03 | Account-aware amount labels and separate source/received currency fields live in `QuickLogSheet` and account input formatting. | Source implemented; bilingual device review open. |
| LOG-04 | `UserProfile`, settings, and Log selection logic support smart/fixed defaults and retain still-valid fields across kinds. | Source implemented; Mac gate open. |
| LOG-05 | `QuickLogDraft`, `AppModel`, and SQLCipher record writes persist one draft and delete it in the successful entry transaction; receipt bytes are excluded. | Source implemented; exact-candidate race tests open. |
| LOG-06 | App-model transaction barriers, post-commit feedback, and six-second Undo guard exactly-once save/background behavior. | Source implemented; exact-candidate app tests and physical rapid-tap check open. |
| LOG-07 | `NaturalLanguageEntryParser`, `TextScanning`, locale money/date parsing, and smart-entry tests cover local CJK/Latin matching and word boundaries. | Source implemented; Mac gate open. |
| LOG-08 | `ReceiptScanner`, `ReceiptTextParser`, visible suggestion state, and `ReceiptAttachment` implement on-device OCR with opt-in encrypted retention. | Source implemented; two-device latency/error/retention drill open. |
| LOG-09 | `LockedCaptureStore`, `LockedQuickCaptureView`, routing, and promotion tests keep basic captures redacted and separate from the book key. | Source implemented; physical cold/warm widget routing open. |
| LOG-10 | Smart/receipt authentication gates and locked-capture preference routing are in `AppModel`/Log launch handling. | Source implemented; exact-candidate locked-routing test open. |
| LOG-11 | Shared locale-aware input validation, field messages, `LedgerPortabilityErrors`, and accessible write alerts replace raw OS/Keychain text. | Source implemented; bilingual VoiceOver device review open. |
| LOG-12 | `TransactionFactory`, split draft/editor UI, per-posting memo, and split regressions require exact same-currency balance before Save. | Source implemented; Mac gate open. |

## Today, History, and Insights

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| TOD-01 | `FinancialGuidance` and `DashboardView` compute purpose-aware Flexible Today from eligible remaining budget, due unposted commitments, and days remaining. | Source implemented under the later founder refinement; Mac gate open. |
| TOD-02 | Dashboard detail exposes arithmetic, period, commitments, and foreign/unbudgeted/rate/schedule exclusions. | Source implemented; bilingual physical reconciliation open. |
| TOD-03 | Today position UI separates cash on hand, card/loan debt, and labeled net cash. | Source implemented; physical visual/accessibility gate open. |
| TOD-04 | Shared budget pace state/marker appears on Today and Plan with text/glyph status, not color alone. | Source implemented; appearance/accessibility matrix open. |
| TOD-05 | Dashboard scheduled/recent sections and guided empty states link directly to Log/Plan. | Source implemented; first-run physical walkthrough open. |
| TOD-06 | `DerivedValue` plus localized unavailable reasons and redacted diagnostic codes render a placeholder instead of zero. | Source implemented; fault-injection/UI evidence open. |
| HIS-01 | SQLCipher `journal_entry_index`, stable keyset pages, bounded recent cache, `AppModel` queries, and `HistoryView` list every valid entry newest-first. | Source implemented; exact 10,000-entry physical smoothness gate open. |
| HIS-02 | `HistoryQuery` searches payee, note, account, and amount with normalized case/diacritic handling. | Source implemented; English/Chinese device review open. |
| HIS-03 | `HistoryQuery`/`HistoryView` combine account, category, kind, date, and amount filters with active-state/reset UI. | Source implemented; Mac and bilingual UI gates open. |
| HIS-04 | `historySummary` pages the complete result and returns separate per-currency totals. | Source implemented; large-book reconciliation open. |
| HIS-05 | History editor and `AppModel.replaceEntry` correct amount/date/account/category/payee/note, preserve split lines, and reject currency reinterpretation. | Source implemented; old-entry and cross-currency regressions open on final SHA. |
| HIS-06 | Replacement writes prior encrypted revision plus `supersedesID`/`revisedAt`, and updates indexes/balances/derived state transactionally. | Source implemented; exact-candidate app/persistence tests open. |
| HIS-07 | Confirmed deletion removes entry, index, balance, attachment, and derived effects; system adjustments use dedicated workflows. | Source implemented; physical correction drill open. |
| HIS-08 | `InsightsView` emits a `HistoryPreset`; History shows pre-applied category/date filters and preserves chart navigation back. | Source implemented; physical navigation/accessibility check open. |
| INS-01 | `ReportBuilder`, `PeriodReport`, and `InsightsView` expose selectable income/expense/net/category/cash-flow/savings/largest-share/period readings locally. | Source implemented; exact-candidate report tests open. |
| INS-02 | Cash-flow series always requests trailing 12-month context and visually identifies the selected analysis window. | Source implemented; chart visual matrix open. |
| INS-03 | Report aggregation retains every category and groups non-leading values as labeled Other. | Source implemented; Mac gate open. |
| INS-04 | Dated user rates can produce labeled estimates; unconverted results remain separated/default when no rate applies. | Source implemented; cross-currency physical reconciliation open. |
| INS-05 | Chart summaries, selection values, non-color cues, and drill-through accessibility live in `InsightsView`. | Source implemented; VoiceOver/Reduce Motion/device matrix open. |

## Planning and Calendar

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| PLN-01 | `BudgetTree` supports arbitrary depth; Plan presents a restrained hierarchy and separate purpose metadata. | Source implemented; physical large-type UI review open. |
| PLN-02 | `BudgetTree`/`ReportBuilder` roll direct spending through ancestors once while treating child limits as allocations. | Source implemented; exact-candidate budget tests open. |
| PLN-03 | Plan summaries expose limit/spent/remaining/unbudgeted plus labeled non-color pace/overspend state. | Source implemented; visual/accessibility gate open. |
| PLN-04 | Plan/Today disclose excluded non-base activity by currency/amount and do not claim on-track over hidden spending. | Source implemented; multi-currency reconciliation open. |
| PLN-05 | Calendar/report models distinguish scheduled forecasts from actual/matched/posted entries. | Source implemented; physical semantic/visual check open. |
| PLN-06 | Schedule models/UI/AppModel support edit, pause, end, skip, confirm, match, and exactly-once posting/advance. | Source implemented; repeated-tap/background physical drill open. |
| PLN-07 | `BudgetRollover`, normalized attribution indexes, monthly opening-carry checkpoints, `SavingsGoal`, Plan goal views, and AppModel support explicit rollover activation, sinking/savings targets, dated movements, resets, archive, and delete. | Source implemented; exact-candidate tests and oldest-device month-boundary/p95 drill open. |
| PLN-08 | Calendar loads actual posting events by range, omits false zero days, and retains per-currency flows. | Source implemented; Calendar physical matrix open. |
| PLN-09 | `ScheduledTransaction` performs direct arithmetic lookup where possible and bounded recurrence otherwise. | Source implemented; 20-long-lived-schedule device budget open. |
| PLN-10 | `FinancialPeriodBoundary`, profile reporting calendar, origin context/day key, date pickers, reports, goals, rates, and schedules share Gregorian half-open rules. | Source implemented; UTC-12/UTC+14/DST physical regression open. |

## Assets, accounts, categories, and investments

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| AST-01 | `LedgerAccount`, onboarding/account UI, and Assets support cash, bank, e-wallet, card, loan, brokerage, and investment accounts with asset/liability semantics. | Source implemented; bilingual onboarding matrix open. |
| AST-02 | Account input accepts explained asset overdraft and uses Amount Owed/non-negative debt semantics for cards/loans. | Source implemented; physical input review open. |
| AST-03 | Reconciliation uses hidden equity, locale-safe no-op detection, and dedicated AppModel workflow. | Source implemented; final locale/no-op tests open. |
| AST-04 | Lifecycle views/models/AppModel implement rename, archive/restore, merge, and delete-with-reassignment while preserving reporting. | Source implemented; exact-candidate old-history tests open. |
| AST-05 | Reference impact/counts and atomic lifecycle batches allow unused deletion or require compatible reassign/merge. | Source implemented; large-book lifecycle regression open. |
| AST-06 | `InvestmentHolding` retains dated prices and exposes Price as of plus a greater-than-seven-day stale state. | Source implemented; physical date/stale display check open. |
| AST-07 | `TransactionFactory` and hidden position/result accounts represent purchase, sale, and repricing as balanced ledger events with no double count. | Source implemented; investment reconciliation open. |
| AST-08 | `InvestmentLot`, `InvestmentDisposal`, and `NetWorthSnapshot` provide deterministic FIFO and append-only historical values. | Source implemented; chronology/sale/snapshot final tests open. |
| AST-09 | Shared searchable `CurrencyPicker` is reused by onboarding, accounts, holdings, import, and exchange-rate setup; `CurrencyCode` rejects invalid free text. | Source implemented; integrated UI compile/device review open. |
| AST-10 | Assets/net-worth views and snapshots keep currencies separate; historical rate conversion is dated, estimated, and inspectable. | Source implemented; physical multi-currency review open. |

## Settings, widgets, and personalization

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| SET-01 | `UserProfile` and Settings offer Immediately/1/5/15 minutes/1 hour with one-minute default; AppModel lock scheduling honors the choice. | Source implemented; physical timing matrix open. |
| SET-02 | Settings controls Locked Quick Capture and Lock Now independently from normal authentication. | Source implemented; physical lock/capture matrix open. |
| SET-03 | Settings stores smart/fixed account/expense/income defaults while Log keeps each selection editable. | Source implemented; Mac/UI check open. |
| SET-04 | Settings links Data Safety, backup/restore, import, privacy/beta, pending captures, and quarantined counts/actions. | Source implemented; bilingual navigation review open. |
| SET-05 | Widget configuration chooses preferred actions across supported Home/Lock families and semantic appearances. | Source implemented; physical family/light/dark/tinted/redacted gate open. |
| SET-06 | `BudgetWidgetSnapshot`, profile opt-in, App Group store, and widget views share only percentage/state and scrub opt-out/erase. | Source implemented; Apple capability, signed entitlement, and physical privacy gates open. |
| SET-07 | Background-lock orphan state is removed/honored and archive fields have actual lifecycle actions. | Source implemented; migration/runtime tests open. |
| SET-08 | New reporting-zone, rollover, goal, rate, attachment, and widget preferences define defaults/migrations/localization/accessibility/persistence tests. | Source implemented; exact-candidate suites and physical behavior open. |

## Portability, recovery, and upgrade

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| POR-01 | `LedgerCSVExporter`/`LedgerXLSXExporter` include entry/posting/account/hierarchy IDs, exact decimals, timestamps, currencies, names, types, and origin context. | Source implemented; exported fixture review open. |
| POR-02 | CSV emits UTF-8 BOM and neutralizes formula-like user text without changing valid negative numerics. | Source implemented; exact-candidate exporter tests open. |
| POR-03 | Export UI warns that CSV/XLSX are readable plaintext and uses the system destination picker. | Source implemented; physical sheet/picker check open. |
| POR-04 | `PortableArchiveV2`, `EncryptedRecordStore.exportPortableArchive`, and `MoneyUpArchiveTransfer` create file-backed authenticated archives from a user password independent of the live key. Fixed 1 MiB chunks cover current books within the enforced 100,000-record/512 MB stored-payload envelope; v1 remains readable. | Source implementation complete; exact-candidate Mac tests plus clean-device, near-limit v2, and compatible-v1 physical proof open. |
| POR-05 | File-backed restore authenticates/decode-inserts bounded records into an isolated SQLCipher store, then replaces the live book transactionally with a separate encrypted rollback archive. Header/frame authentication rejects wrong password, tamper, truncation, append, duplication, reorder, cancel, and future schema. | Source implementation complete; exact-candidate fault execution, interruption/power-loss, and physical restore gates open. |
| POR-06 | `TransactionCSVImporter` and import UI implement local preview, row issues, duplicate detection, mappings, and atomic commit. | Source implemented; mapped fixture/device review open. |
| POR-07 | Unknown CSV/TSV mapping UI and dependency-free native OOXML XLSX export are present; spreadsheets remain non-live. | Source implemented; Numbers/Excel physical-open check open. |
| POR-08 | Quarantine/recovery preserves bad raw encrypted rows and offers backup/export/restore before destructive erase. | Source implemented; corrupted-book recovery drill open. |
| POR-09 | Schema migration/index rebuild and legacy decoders preserve valid 0.4.0 precision and default new fields safely. | Source implemented; exact migration suite and installed-book upgrade open. |
| POR-10 | Bundle/App Store/Keychain/container/widget identities are fixed in source and release workflow. | Source configured; TestFlight-to-TestFlight/App-Store physical gate open. |
| POR-11 | `FIRST_TEST.md` defines pre/post inventory across all record types and widget/Keychain state. | Evidence-only requirement; physical reconciliation open. |

## Accounting, data, and correctness

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| DAT-01 | `Money`, `CurrencyCode`, input boundaries, schedule/holding/rate/archive/import validation, and policy tests enforce minor units for new data while preserving legacy values. | Source implemented; final write-boundary suite open. |
| DAT-02 | `JournalEntry` validates at least two unique non-zero postings and exact per-currency zero sum at init/decode. | Source implemented; Mac property/regression gate open. |
| DAT-03 | `TransactionFactory` kinds/account roles keep transfers, card payments, investment funding, reconciliation, and refunds out of false income/expense. | Source implemented; sample-ledger reconciliation open. |
| DAT-04 | `DatedExchangeRate`/historical lookup never invent a rate and visibly marks dated estimates. | Source implemented; integrated FX/investment report tests open. |
| DAT-05 | Shared locale formatting/parsing requires full-string validity and covers comma/zero-decimal/precision/garbage/negative/extreme cases. | Source implemented; exact-candidate suites and bilingual entry open. |
| DAT-06 | `FinancialPeriodBoundary` provides the single half-open utility used by History, reports, budgets, goals, rollover, and schedules. | Source implemented; final date-path audit open. |
| DAT-07 | `TransactionOriginContext`, stable day key, reporting time zone, and posting events retain travel/DST attribution. | Source implemented; extreme-zone physical/Simulator regression open. |
| DAT-08 | `DerivedValue` propagates unavailable/error state; UI shows reason and OSLog receives redacted operation/diagnostic only. The separate performance category accepts only 18 static interval names, empty low-level messages, and fixed journey outcomes. | Source implemented with signpost source gate; fault-injection/physical log audit open. |
| DAT-09 | AppModel/store batches cover setup, edit, lifecycle, import, restore, draft removal, reconciliation, investment, attachment, and goal operations atomically. | Source implemented; exact-candidate rollback/race tests open. |
| DAT-10 | Store decode issues and relationship validation quarantine/count bad rows without discarding the readable book or raw record. | Source implemented; corrupted fixture/recovery evidence open. |

## Privacy, security, and safety

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| SEC-01 | Package/app architecture, privacy manifest, policy, and local-only flows include no account, backend, ads, analytics, financial telemetry, or remote AI. | Source implemented; exact-binary dependency/network review open. |
| SEC-02 | `DatabaseKeyStore` generates a random 256-bit this-device-only, non-synchronizing, user-presence Keychain key for SQLCipher. | Source implemented; physical passcode/biometry behavior open. |
| SEC-03 | Scene privacy cover, timeout, safe draft flush, store close, and decoded/cache clearing live in AppModel. | Source implemented; physical timing/background matrix open. |
| SEC-04 | Locked Quick Capture uses a separate encrypted store and has no live book key, snapshot, balance, history payee, or account data. | Source implemented; physical widget/capture privacy gate open. |
| SEC-05 | Data Safety/recovery copy warns about passcode/app-deletion cliffs and prioritizes file-backed `.moneyup` backup/restore before destructive recovery. Current writes cannot outgrow the v2 portable envelope. | Source implemented; exact-candidate and physical warning/recovery drill open. |
| SEC-06 | Vision processing is on device; receipt sources are transient unless explicitly retained, then orientation-applied pixels are bounded and re-encoded without GPS/EXIF/TIFF device metadata before SQLCipher/archive persistence. They are never exported/read by widgets. | Source implemented with metadata fixture; exact-candidate and physical retention/network observation open. |
| SEC-07 | Runtime data egress is explicit export only; privacy/security docs require new review before any network integration. | Source implemented; exact-binary network review open. |
| SEC-08 | Redacted logging/diagnostics, domain-payload-free performance signposts with fixed outcomes, privacy cover, Quick Capture design, and percentage/state-only widget snapshot exclude sensitive values. | Source implemented with signpost source gate; physical feedback/widget/log audit open. |
| SEC-09 | `PRIVACY.md`, privacy manifest, store working copy, support/release docs, and workflow define exact-binary reconciliation. | Release gate open; no submitted binary has been reviewed. |
| SEC-10 | Privacy/security documents state compromised OS, shared credentials, unlocked screen, screenshots, and post-export disclosure as limits. | Source documentation implemented; exact store copy review open. |

## Quality and release validation

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| QA-01 | CI/TestFlight workflows configure warnings-as-errors core tests, app-model XCTest, and app/widget Simulator builds on PR/main/release paths. | W1/W2 merged-main CI passed on `4159df31`; every later candidate must repeat the exact-SHA gate. |
| QA-02 | `MoneyUpAppTests/AppModelTests` covers lock/save/scan/deep-link/erase/stale-generation/capture-promotion and additional lifecycle paths. | Test source implemented; exact-candidate macOS execution open. |
| QA-03 | Core/persistence/app suites cover audit defects, minor units, locales, currency edits, revisions, caches/indexes, BOM, and rollback. | Test source implemented; exact-candidate execution open. |
| QA-04 | `FIRST_TEST.md` defines the required iPhone/language/appearance/Dynamic Type/VoiceOver/Reduce Motion/widget matrix plus oldest-device archive/checkpoint measurements. | Physical gate open. |
| QA-05 | `DataSafetyView` exports a privacy-safe inventory from one payload-free store count snapshot. The fixture generator preserves its original 10,000-row release output and adds an explicit three-currency intelligence profile plus committed oracle; `FIRST_TEST.md` binds these to upgrade, restore, scale, and planted-finding checks. | Fixture/oracle and merged W2 Swift CI passed; physical gates remain open. |
| QA-06 | Roadmap/launch plan prohibit wider testing or App Review while mandatory evidence is open. | Gate enforced in documentation; wider-test/review approval remains open. |
| QA-07 | Workflow and store checklist bind metadata, screenshots, review notes, privacy, languages, version/build, archive, widget, App Group, and binary capabilities. | Exact-binary/App Store gate open. |
| QA-08 | `MoneyUpPerformanceTests`, the `MoneyUpPerformance` Release scheme, and pinned CI build one logically/domain-deterministic 10,000-entry/20-schedule store outside measured blocks from the SHA-bound W2 intelligence-v1 corpus/oracle; assert exact detector and refund/transfer/split exclusion invariants before observing clock/CPU/memory/logical writes for open+close/load, save, History, export, archive/restore, receipt parsing, projection, and intelligence; and retain `.xcresult` plus JSON environment/metrics/summary/file-manifest evidence. | W4.1 source-configured; exact-candidate Simulator run open. This is not the upcoming W5 QA-v2 lifecycle corpus. No absolute ceiling is asserted and every physical p95/memory/interaction gate remains open. |

## Proposed amendment PA-2026-08-29-r1 — Explainable capture guardrails

This task-authorized amendment is not text from the Golden PRD. It was merged
to `main` through PR #28 and is retained by W1 rather than redefined by it. It
extends `LOG-04`, `LOG-07`, `LOG-08`, `DAT-09`, and `SEC-06` without changing
navigation, accounting semantics, persistence schema, archive shape, bundle
identity, or network capability.

| Proposed ID | Behavior and acceptance | Data/privacy/rollback |
|---|---|---|
| PA-CAP-01 | Smart Entry and receipt-assisted Quick Log rank account and category suggestions from the current valid recent-entry cache. Every result carries a deterministic confidence band and count/date evidence; only high-confidence untouched fields may prefill, parser/user choices win, and ambiguous split history never collapses to one category. | Derive on demand inside the unlocked book; persist no profile, score, OCR text, or evidence. Removing the scorer restores prior UI behavior without touching user data. |
| PA-CAP-02 | Before an interactive Save, exact amount/currency/kind/account semantics plus bounded time/payee/source evidence may produce an advisory recent-duplicate warning. The user can review History, cancel, or save anyway; the warning never deletes, merges, or blocks a legitimate repeat. | Inspect only valid in-memory recent entries, never raw/quarantined rows. A versioned draft fingerprint authorizes one unchanged Save attempt only. No database or archive migration. |
| PA-CAP-03 | Receipt amount, merchant, date, and category candidates retain rule evidence and field-relative confidence. Per-line and aggregate Vision confidence may only lower a band; impossible civil/DST times fail closed; low-confidence candidates remain explicit review actions and never silently replace an edited field or offer an incompatible category. | Vision remains on device. Images and OCR text remain transient unless the existing explicit encrypted-attachment control is enabled; semantic evidence contains no receipt text. |
| PA-CAP-04 | Receipt parsing is bounded to 160 header/footer lines, computed outside the main actor, and checked against store generation plus journal/account projection revision before publication. | Cancellation, lock, or restore suppresses stale publication. The bounded fallback always leaves manual entry available. |
| PA-CAP-05 | Latin kind/date tokens use Unicode letter/number boundaries while CJK tokens retain intentional substring matching. Impossible explicit civil dates fail closed instead of becoming a normalized day or invented amount. | Pure parsing change with no stored state; identical input, locale, clock, and book state remain deterministic. |

For PA-2026-08-29-r1 itself, explicit non-goals were persistent learning state,
remote inference, recurring-pattern discovery, unusual-spend prediction,
investment advice, automatic schedule creation, receipt line-item splitting,
and a new setting. Approved W2 subsequently adds separate optional indexed
recurrence/anomaly discovery and an intelligence setting without weakening the
PA capture rules. Schedule creation remains manual. Physical latency, accuracy,
accessibility, and real-OCR targets remain open for the exact release candidate.

## Non-functional promotion gates

The Golden PRD requires physical measurement on the oldest supported iPhone
with 10,000 entries and 20 schedules:

The separate W4.1 Simulator harness is documented in
[the automated performance baseline](PERFORMANCE_BASELINE.md). Its optimized,
serial XCTest measurements are useful regression evidence only; they do not
change any status in the physical table below.

| Operation | Budget | Status |
|---|---:|---|
| Unlock after authentication | p95 <= 2.5 s | Open - no final-candidate physical result |
| First useful tab content | p95 <= 750 ms | Open |
| History search/filter after debounce | p95 <= 300 ms | Open |
| Transaction save | p95 <= 750 ms | Open |
| Calendar date computation | p95 <= 100 ms | Open |
| Scrolling/interaction | No sustained jank | Open |

Also open: signed App Group entitlement validation for the final 0.7.0 binary,
in-place installed-beta-to-0.6.0-to-0.7.0 upgrade continuity, clean-device
restore, founder/co-tester seven-day run, 14-day invited
closed beta, exact-binary privacy/store review, App Review, account-holder
manual release, and first-72-hour monitoring.

## Authority-resolution appendix

### Source order used

1. The uploaded **MoneyUp: CowCome - Golden Product Requirements Document**,
   marked version 1.0 inside the document and effective 26 August 2026, is the
   final functional/release authority. The supplied library/file label may call
   it v1.1; this traceability does not alter the document's printed version.
2. Accounting and security/privacy invariants cannot be weakened by lower
   sources.
3. Later explicit founder decisions can revise product presentation/scope when
   recorded as later decisions rather than misattributed to the uploaded PRD.
4. The independent **MoneyUp 0.4.0 Audit** supplies defect evidence and
   non-regression anchors.
5. The earlier **MoneyUp Product Requirements v1.1** supplies context only where
   it does not conflict with the Golden PRD or later accepted decisions.

### Superseded earlier-PRD scope

- Old FR-901 through FR-903 StoreKit purchase requirements do not apply. The
  Golden boundary says the first public version remains free; 0.6.0 has no
  in-app purchase.
- Old FR-1001 through FR-1012 CloudKit sync requirements do not apply.
  Multi-device encrypted sync is an explicit 1.0 non-goal pending a new privacy,
  authorization, recovery, and product decision.
- The earlier release-number sequence and any requirements derived only from
  those commerce/sync decisions cannot silently re-enter the 1.0 gate.

### Later accepted founder decisions

These decisions were accepted after the uploaded Golden baseline and are not
claimed to be text from that document:

- **Adaptive soft-green identity and horned-money emblem** supersede the
  Golden document's royal-blue/restrained-gold presentation direction. The
  accessibility, semantic-color, contrast, and non-color-status rules remain.
- **Flexible Today** supersedes the user-facing Safe to Spend label and narrows
  eligibility to allocations explicitly classified as flexible. The Golden
  arithmetic, commitment, period, exclusion, unavailable-state, and
  inspectability invariants remain auditable.

The later decisions change presentation/eligibility, not ledger correctness,
privacy, portability, or release evidence standards.
