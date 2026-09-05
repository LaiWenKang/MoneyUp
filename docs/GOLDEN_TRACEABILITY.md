# Golden PRD Traceability - MoneyUp 0.7.1 Candidate

Reconciled: 5 September 2026

This is the requirement-to-evidence map for the retained MoneyUp 0.6.0
migration baseline, merged 0.7.0 W1-W7 work, the merged build-10 0.7.1
feedback follow-up, and the expanded build-11 candidate. It prevents
"implemented in source" from being misreported as "released" or "accepted."

The approved 0.6.0 baseline was
`ff272da89de9f4e3cb9c44d4abd27deae7d2b338`. W1 merged through PR #30 at
`da88df25ab06e93ec5998a9edbcf0153587a9af2`; its exact merged-main CI passed.
W2 merged through PR #31 at
`4159df31b7e0b9489d1ddcd84c261296faaeda39`; CI run 246 passed its release,
Core/persistence/intelligence, app-model, and app/widget Simulator gates. The
0.7.1 feedback follow-up merged through PR #40 as `68eee4f8`; exact PR-head run
300 and merged-main run 301 passed all four CI jobs for build 10. The build-11
candidate must repeat exact-head CI before signed promotion. Physical-device,
signed-binary, TestFlight, and release evidence remain open.

The exact 97-row Golden requirement-to-test mapping and later approved overlays
are in
[REQUIREMENTS_TEST_MATRIX.md](REQUIREMENTS_TEST_MATRIX.md). The complete source,
dependency, defect, test-design, and release-blocker review is in
[QUALITY_AUDIT_0.6.0.md](QUALITY_AUDIT_0.6.0.md), with the closed file manifest
in [FILE_REVIEW_INVENTORY.md](FILE_REVIEW_INVENTORY.md). The 4 September founder
amendment is recorded without altering the uploaded documents in
[CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md](CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md),
with its exact-SHA and physical evidence contract in
[QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md](QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md).

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

## 0.7.0 W3 optional Foundation Models traceability

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| W3-PREF | `UserProfile.foundationModelAssistanceEnabled`, its serialized `AppModel` update, and bilingual Settings copy enable Apple on-device matching by default while preserving an explicit opt-out. Unsupported devices fail closed to deterministic parsing. `QuickLogAssistanceCoordinator` still checks the gate before planning; `testOffGateNeverInvokesInjectedSelector` proves an opt-out invokes neither planner nor selector. | Source implemented; exact-candidate XCTest and physical Settings review open. |
| W3-BND | `QuickLogPromptBoundary` canonically normalizes while enforcing 128/256 context scalar/UTF-8, 48/96 per-choice, and 3,072/4,096 total prompt ceilings. The sole typed request/call uses only parsed nonfinancial context and numbered existing names. `QuickLogOnDeviceOrdinalModel` uses `SystemLanguageModel.default`, one uncustomized session, availability gating, and two literal `0...15` guided ordinals. The architecture gate pins construction/call/provenance and rejects OCR, money, date, ID, arbitrary, pasteboard, defaults, extra-call, provider/tool/package, and string-output mutations. | Architecture validator and 37 focused Python tests pass locally; Xcode 16 fallback and Xcode 26 compilation remain open. |
| W3-OWN | `NaturalLanguageEntryParser.parse` retains every financial field. `QuickLogAssistancePublicationPolicy` rechecks kind/profile/splits/candidate membership and exact per-field state; deterministic history filters stale model suggestions in both completion orders. Use snapshots immediate field/provenance state, while Reject restores only if the full model-applied state is still current. | Source and adversarial XCTest cases present; exact-candidate app XCTest and eligible-device behavior remain open. |
| W3-DRAFT | An accepted choice immediately updates the recoverable SQLCipher draft but creates no transaction until Save. `AppModelTests.testFoundationModelRejectRestoresImmediateHistoryStateInEncryptedDraft` persists the model choice, restores immediate history state, closes/reopens the encrypted store, and rejects both model IDs. | Source implemented; exact-candidate execution and physical lock/relaunch drill open. |
| W3-A11Y | Optional-model and deterministic-history Use actions own contextual bilingual account/category accessibility labels. The static gate mutation-tests both call sites; bilingual VoiceOver remains a physical gate. | Static gate passed locally; hosted/physical VoiceOver open. |
| W3-FAL | Injected unavailable, error, cancellation, stale generation, invalid ordinal, multilingual bound, history/model race, and suspended mutation cases fail closed without altering exact financial fields. | Source-complete; exact-candidate app XCTest execution open. |

## 0.7.0 W5 architecture fitness traceability

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| W5.2-FIT | `Scripts/validate_architecture_fitness.py`, focused Python fixtures, its release-validator invocation, and the explicit CI steps enforce reviewed Core/CryptoKit imports, view/factory separation, declared colorsets, bilingual static keys, the offline boundary, conditional Foundation Models output limits, and the documented shipping-Swift safety exceptions. | Source implemented; local static and fixture gates passed; exact merged-candidate CI remains open. |

## 0.7.0 W6 visual-system traceability

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| W6-PRIM | `MoneyUpTypography`, `MoneyUpCardPolicy`, and their modifiers provide Dynamic Type-relative monospaced financial roles plus opaque flat/raised/floating surfaces. Reduce Transparency selects a solid primary border with no shadow; Increase Contrast widens and strengthens the boundary. `MoneyUpDesignPrimitiveTests` covers every style/environment policy. | Source implemented; local static gate passed; exact-candidate XCTest and physical Dynamic Type/appearance matrix open. |
| W6-MOTION | `MoneyUpMotion` keeps financial values immediate, removes MoneyUp-owned confirmation/state motion under Reduce Motion, and leaves native navigation/presentation native. Quick Log consumes the shared policy. `MoneyUpFeedback.haptic` requires a trigger transition with simultaneous visible status; its modifier remains structurally attached, Quick Log/locked capture use the governed boundary, and release validation mutation-tests that structure and rejects direct bypasses. | Source implemented; local static gate passed; exact-candidate XCTest and physical Reduce Motion/haptic review open. |
| W6-KEY | All six retained app colorsets have explicit light/dark normal/high keys. `validate_release_assets.py` freezes the corrected dark-normal action plus every other reviewed hex, tests action contrast against all three semantic canvases, and replays the old failing dark-action mutation. | Source implemented; local static release gate passed; exact-candidate macOS gate open. |
| W6-CHART | Six ordered `ChartSeries` assets/tokens drive fully opaque cash-flow and category geometry; a primary dashed rule encodes selection without dimming. The release gate composites rendered pixels, requires 3:1 against every canvas, mutation-tests opacity and policy use, directly rejects zero line width plus empty/non-positive dash declarations, applies standard/protan/deutan separation, and retains labels, symbols/shapes, position, amounts, and accessibility values. Tritan is deliberately not claimed by the heuristic. | Source implemented; local static/mutation gate passed; physical high-contrast, grayscale, tritan/blue-yellow-filter, and VoiceOver matrix open. |
| W6-WIDGET | Widget semantic colors respond to appearance and accessibility contrast while `BudgetWidgetSnapshot` and its privacy boundary remain unchanged. | Source implemented; exact signed widget appearance/tint matrix open. |

## 0.7.0 W7 platform-action traceability

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| W7-URL | `MoneyUpQuickAction.init(exactDeepLink:)` is a base-free, byte-exact six-literal map. `testPersistedActionsMapToExactDataFreeDeepLinks` accepts every canonical route; `testDeepLinkAllowlistRejectsEveryNoncanonicalVariant` rejects case, escape, credential, port, query, fragment, and path variants without creating a request. | Local source/mutation gate passed; exact-candidate Xcode and signed URL-launch matrix open. |
| W7-FIFO | `MoneyUpApp.routeDeepLink` sends `.onOpenURL` through the same coordinated, schema-1, 16-record/4,096-byte data-free ingress store and disposition router as App Intents. Intent success follows the atomic append. Canonical JSON, `0700`/backup-excluded storage, first-unlock protection, exact write-postcondition reconciliation, cold/active-scene reload, process recreation before route or after dequeue, exact-token acknowledgement, duplicate order, malformed/future/oversized/duplicate-key input, and capacity rejection are pinned by named action tests. Delivery is at least once until UI acknowledgement: a crash may replay navigation, never a financial commit. OS retries remain distinct without an OS-stable invocation ID. | Local source/mutation gate passed; exact-candidate XCTest and physical shortcut/widget/control routing open. |
| W7-AUTH | Generation-bound boundary epochs synchronously persist closed admission and invalidate queued/occupied old-book work before erase, restore, or key-replacement side effects. Producers reload then authority-CAS every append; a close failure aborts lifecycle entry and a crash leaves admission closed until explicit validated recovery. That coordinated recovery preserves a concurrently established valid/open FIFO but resets absent, corrupt, or closed state. Token-bound locked capture makes a crash after inbox append idempotent, while its legacy protection migration preserves ciphertext and FIFO bytes. Boundary, tombstone, restore, erase, key-cliff, concurrent-bootstrap, long-lived-extension, acknowledgement-failure, and stale-token regressions remain named in the W7/AppModel suites. | Source implemented; exact-candidate XCTest plus signed interruption/forensic privacy evidence open. |

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
| LOG-11 | Shared locale-aware input validation, `MoneyUpFieldError`, `AccessibleErrorPresentation`, `LedgerPortabilityErrors`, and the scoped static gate keep field guidance associated while every safe-message context receives one native alert or target-bound retry summary. | Latest-wins reducer and negative mutation tests added; local validators passed; exact-candidate Xcode and bilingual VoiceOver device review open. |
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
| SET-06 | `BudgetWidgetSnapshot`, profile opt-in, the App Group store, and Budget Status/Smart Overview share one bounded schema-4 generation containing only state, a bounded reporting-period token, rounded budget/allowance percentages, review/expense-commitment counts, expiry, and relative due-day distance. The App Group allowlist is exactly the nonfinancial language preference, that one atomic summary `Data` value, and one bounded data-free quick-action ingress file. An absent summary means disabled/opted out; corrupt, future-schema, oversized, contradictory, or negative-field summaries are wholly stale. The extension is read-only, while the ready app canonicalizes stale state, republishes after eligible activation/day-boundary changes, and reduces Home-widget density at accessibility Dynamic Type sizes. Opt-out scrubs the financial summary; erase/restore authority also invalidates old ingress work. | Source implemented; exact-candidate automated execution, Apple capability, signed entitlement, and physical privacy/lifecycle/accessibility gates open. |
| SET-07 | Background-lock orphan state is removed/honored and archive fields have actual lifecycle actions. | Source implemented; migration/runtime tests open. |
| SET-08 | New reporting-zone, rollover, goal, rate, attachment, and widget preferences define defaults/migrations/localization/accessibility/persistence tests. | Source implemented; exact-candidate suites and physical behavior open. |

## Portability, recovery, and upgrade

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| POR-01 | `LedgerCSVExporter`/`LedgerXLSXExporter` include entry/posting/account/hierarchy IDs, exact decimals, timestamps, currencies, names, types, and origin context. | Source implemented; exported fixture review open. |
| POR-02 | CSV emits UTF-8 BOM and neutralizes formula-like user text without changing valid negative numerics. | Source implemented; exact-candidate exporter tests open. |
| POR-03 | Export UI warns that CSV/XLSX are readable plaintext and uses the system destination picker. | Source implemented; physical sheet/picker check open. |
| POR-04 | `PortableArchiveV2`, `EncryptedRecordStore.exportPortableArchive`, and `MoneyUpArchiveTransfer` create file-backed authenticated archives from a user password independent of the live key. Fixed 1 MiB chunks cover current books within the enforced 100,000-record/512 MB stored-payload envelope; v1 remains readable. | Source implementation complete; exact-candidate Mac tests plus clean-device, near-limit v2, and compatible-v1 physical proof open. |
| POR-05 | File-backed restore bounded-copies and fully validates a candidate in an isolated SQLCipher store before showing a privacy-safe replacement preview. Production restore reduces raw candidate records in stable key order before `AppModel` load, with cooperative cancellation and bounded reduction state rather than a second whole-book snapshot. One SHA-256-and-length ticket owns normal and key-cliff restore; key-cliff current state is explicitly inaccessible, and its private copy is reverified before key/manifest mutation. Marker removal gates ready state, capture preference/promotion, widget, and intelligence. Normal restore suppresses cross-book projections and intent, retains a deterministic private rollback directory, and republishes only the successful candidate or completed rollback. Failures wait for sheet dismissal; success has one visible-focus or post-transition announcement route. | Integrated source and static regressions implemented; exact-candidate raw-reduction/work-limit CI, interruption/power-loss, and physical restore/accessibility gates remain open. |
| POR-06 | `TransactionCSVImporter` and import UI implement local preview, row issues, duplicate detection, mappings, and atomic commit. | Source implemented; mapped fixture/device review open. |
| POR-07 | Unknown CSV/TSV mapping UI and dependency-free native OOXML XLSX export are present; spreadsheets remain non-live. | Source implemented; Numbers/Excel physical-open check open. |
| POR-08 | Quarantine/recovery preserves bad raw encrypted rows and offers backup/export/restore before destructive erase. Allowance recovery is bounded per plan at 4,096 usage rows, 4,096 reconciliation rows, 512 archive transitions, and `10,000 + 2 × maxPolicyRevisions` period work, with 100,000 aggregate ceilings for each collection; weekday-period estimation is exact O(1) work from weekdays rather than calendar-day iteration. | Source implemented; exact-candidate limit/cancellation execution and corrupted-book recovery drill open. |
| POR-09 | Schema migration/index rebuild and legacy decoders preserve valid 0.4.0 precision and default new fields safely. The allowance archive timeline is additive inside the schema-9 payload: current-format marker/timeline/state is strict, while a fully legacy archived record infers the earliest evidence-consistent boundary without rewriting the journal or bumping SQLCipher. | Source implemented; exact archive-compatibility suite and installed-book upgrade open. |
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
| DAT-10 | Store decode issues and relationship validation quarantine/count bad rows without discarding the readable book or raw record. Allowance recovery closes restricted debit/evidence ownership over complete indexed account-scoped history to a monotonic fixed point, preserves every encrypted raw row, and respects the documented per-plan and aggregate work ceilings; strict restore rejects the same invalid graph. | Source implemented; exact-candidate allowance-integrity, limit, and cancellation execution plus corrupted fixture/recovery evidence open. |

## Privacy, security, and safety

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| SEC-01 | Package/app architecture, privacy manifest, policy, and local-only flows include no account, backend, ads, analytics, financial telemetry, or remote AI. | Source implemented; exact-binary dependency/network review open. |
| SEC-02 | `DatabaseKeyStore` generates a random 256-bit this-device-only, non-synchronizing, user-presence Keychain key for SQLCipher. | Source implemented; physical passcode/biometry behavior open. |
| SEC-03 | Scene privacy cover, timeout, safe draft flush, store close, and decoded/cache clearing live in AppModel. | Source implemented; physical timing/background matrix open. |
| SEC-04 | Locked Quick Capture uses a separate encrypted store and has no live book key, snapshot, balance, history payee, or account data. | Source implemented; physical widget/capture privacy gate open. |
| SEC-05 | Bilingual setup/Security/Data Safety/first-backup copy warns that passcode removal or app deletion can make the live book unrecoverable. Missing key plus ciphertext is a dedicated state. Keyless `.moneyup` recovery copies and validates an isolated SQLCipher candidate before a durable artifact-mask/key/install transaction, preserves the external archive, and rolls back on reopen/load failure. Current writes cannot outgrow the v2 envelope. | Source implemented with rejection/cancellation/filesystem rollback tests; exact-candidate and physical passcode-removal/interruption drill open. |
| SEC-06 | Vision processing is on device; receipt sources are transient unless explicitly retained, then orientation-applied pixels are bounded and re-encoded without GPS/EXIF/TIFF device metadata before SQLCipher/archive persistence. They are never exported/read by widgets. | Source implemented with metadata fixture; exact-candidate and physical retention/network observation open. |
| SEC-07 | Runtime data egress is explicit export only; privacy/security docs require new review before any network integration. | Source implemented; exact-binary network review open. |
| SEC-08 | Redacted logging/diagnostics, domain-payload-free performance signposts with fixed outcomes, privacy cover, and Quick Capture design preserve the App Group's exact three-artifact allowlist: one nonfinancial language preference, one atomic bounded schema-4 summary `Data` value, and one bounded data-free quick-action ingress JSON file carrying only schema/authority metadata, admission metadata, opaque tokens, and one of six closed action values. Exact due dates, financial records, amounts, names, holdings/quotes, balances, notes/evidence, and domain identifiers are forbidden. | Source implemented with signpost and App Group source gates; exact-candidate automated execution and physical feedback/widget/log audit open. |
| SEC-09 | `PRIVACY.md`, privacy manifest, store working copy, support/release docs, and workflow define exact-binary reconciliation. | Release gate open; no submitted binary has been reviewed. |
| SEC-10 | Privacy/security documents state compromised OS, shared credentials, unlocked screen, screenshots, and post-export disclosure as limits. | Source documentation implemented; exact store copy review open. |

## Quality and release validation

| ID | Implementation and evidence anchor | Current evidence state |
|---|---|---|
| QA-01 | CI/TestFlight workflows configure warnings-as-errors core tests, app-model XCTest, app/widget Simulator builds, structure checks, and accessible-error checks on PR/main/release paths. | Accessible-error gate passes locally; every later candidate must repeat the exact-SHA CI gate. |
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

## Approved amendment MU-CC-071-2026-09-04 — Decision trust and navigation

The founder approved this amendment after testing `0.7.1 (1037.1)`. It is not
text from either uploaded PRD and does not silently change the internally
printed Golden version. Its complete decisions and non-goals are in
[CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md](CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md).

| Requirement range | Controlled change | Current evidence state |
|---|---|---|
| `AR-TOD-01...05` | Flexible today naming, compact date/period/conditional-zone context, one reporting snapshot, inclusive final-day-safe denominator, and exact minor-unit apportionment. A liquidity-aware Safe-to-Spend model remains deferred. | Approved; exact-candidate automated and physical evidence open. |
| `AR-ALL-01...09` | Distinguish policy limits, prepaid restricted value, and reimbursement-claim evidence; make qualifying prepaid value discoverable as a restricted account without duplicating balances or unrestricted capacity; enforce exclusive active-plan account ownership; bind editing, visible civil dates, categories, and historical Quick Log previews to the governing policy revision and its time zone; preserve atomic funding/usage and historical facts; support stable-ID corrections only for eligible standalone benefit usage; model archive/unarchive as an effective-dated pause; require exactly one valid authorization for every restricted debit; and keep the optimistic pending → approved/rejected → reimbursed claim lifecycle evidence-only. | Approved; exact-candidate claim, editor, historical-preview, usage-correction, archive-compatibility, journal-integrity, migration, ledger, recovery, and physical evidence open. |
| `AR-MKT-01...06` | Introduce Core-only instrument/quote/provider/store/estimated-valuation contracts under a manual-local deny-by-default policy. Quotes are strictly positive except an explicit manual/manual-legacy zero write-down; provenance binds source kind/identifier, record/sequence identity, quote type, delay, quality, venue/currency, and time. Source identity drives dedupe before eligibility, and provider responses must bind request identity/time, exact result set, supported source kinds, provider identity, and each instrument's quote currency. No provider, network, credentials, persistence schema, or symbol transmission is activated in this tranche. | Approved foundation; future provider activation remains separately blocked. |
| `AR-NAV-01...05` | Remove global tab swipe, use one adaptive Plan peer selector, move History's dynamic categories into a labelled menu, and provide Back only for a real pushed or recorded origin. | Approved; exact-candidate accessibility/navigation evidence open. |
| `AR-WDG-01...06` | Atomic versioned snapshot, family-native layouts, reporting-calendar-relative dates, coherent unavailable/stale state, durable at-least-once data-free ingress with exact-token UI acknowledgement, and an exact redacted App Group allowlist. | Approved; exact-candidate widget, signed-extension, and physical matrix open. |

The exact designed automated, mutation, migration, signed, and physical cases
are in
[QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md](QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md).
No row above is a pass merely because this decision is approved.

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

Also open: signed App Group entitlement validation for the final 0.7.1 binary,
in-place installed-predecessor-to-0.7.1 upgrade continuity, clean-device
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
- **Approved rework MU-CC-071-2026-09-04** adds date/period trust context and
  exact residual apportionment to Flexible today; distinguishes allowance
  entitlement, prepaid restricted value, and evidence-only reimbursement
  claims; adds exclusive restricted-account ownership, revision-zone civil-date
  editing, historical prepaid previews, and safe standalone benefit-usage
  correction; adds a manual-only Core market-observation foundation with an
  explicit manual-zero write-down exception and bound provenance; removes global tab swipe;
  replaces Plan's synthetic overview/back model with an adaptive peer selector
  plus contextual native Back; consolidates History's dynamic category chips;
  and makes the widget snapshot/layout/calendar/action boundaries explicit.
  The decision record limits its own authority and keeps true liquidity-aware
  Safe-to-Spend and all market networking separately gated.

The later decisions change presentation/eligibility, not ledger correctness,
privacy, portability, or release evidence standards.
