# Golden PRD Execution Plan

Last reconciled: 5 September 2026 against the uploaded MoneyUp Golden PRD
(document version 1.0; supplied file label v1.1), the independent 0.4.0 audit,
and later accepted founder decisions.

The Golden PRD is the functional/release authority. Security and accounting
invariants remain non-negotiable. The earlier PRD is supporting evidence only
where it does not conflict. Its StoreKit and CloudKit requirements are
superseded: the approved first public release is free and local-only.

Checked source items describe the build-11 0.7.1 candidate. Exact PR-head CI
run 300 and merged implementation CI run 301 cover the prior build-10 baseline;
this candidate must repeat exact-head CI before signed promotion. Checked source items do not
close physical-device, signed-binary, TestFlight, closed-beta, or App Store
gates. See [Golden PRD
traceability](GOLDEN_TRACEABILITY.md) for every requirement ID and its evidence
status.

## 0.7.1 complete feedback follow-up

- [x] Quick Log scrolls the focused amount, account, smart-entry, title,
  notes, and split fields above the keyboard; its untouched occurrence time
  refreshes from the injected current clock.
- [x] Quick Log and transaction editing provide exact Equal, unlocked
  Rebalance, 50/50, 60/40, and 70/30 split tools with per-row locks.
- [x] Both entry forms re-scroll after keyboard layout settles, reserve focused
  bottom space, support interactive dismissal, and always expose Done.
- [x] Deterministic defaults prefer valid user settings, then matching local
  payee history, then an active leaf category; every suggestion remains
  visible and editable.
- [x] Widget and shortcut routes open the same full Quick Log with account,
  category, title, notes, date/time, and split details after authentication.
  The separate locked inbox retains amount/title/notes only and defers protected
  account/category selection until intentional unlock.
- [x] History defaults to Today, offers seven-day/month/all scopes, computes
  complete spending/income/refund/net totals per currency, displays title,
  notes, and full category paths, and keeps direct Calendar access.
- [x] History adds a second composable smart-filter row for review items,
  splits, recurring transactions, allowances, and notes.
- [x] Expense and income categories support arbitrary-depth parent selection,
  full-path search, visible child creation from every active row, safe
  reparenting, and cycle/kind validation directly from Log.
- [x] Flexible category budgets can opt into exact daily or weekly remaining
  pacing, and Plan can view Today, This week, or Rest of month without mutation.
- [x] Allowances keep benefit-limit, prepaid-asset, and reimbursement modes
  economically distinct across daily/weekday/weekly/monthly cadence, optional
  expiry, eligible categories, usage history, and no/full/capped rollover.
  Benefit capacity and reimbursement claims remain policy/evidence only;
  prepaid value must already exist in an exclusively owned, same-currency
  restricted account and is displayed separately from unrestricted wealth.
  Policy-zone editors store a visible inclusive end as the next civil-day
  boundary, preserve exact legacy partial-day bounds, and retain the plan zone
  for name-only edits. Usage/category choices and date presentation resolve the
  governing policy revision. A historical prepaid preview reads indexed ledger
  state at the exact expense instant and fails closed if its plan, account,
  instant, projection, or book revision becomes stale. Eligible Quick Log
  expenses save allowance evidence atomically. Stable-ID edit/delete/Undo is
  limited to current standalone benefit usage; linked, prepaid, reimbursement,
  archived, and grandfathered evidence remains protected. Reimbursement claims
  follow optimistic pending → approved/rejected and approved → reimbursed
  transitions; terminal states cannot reopen, every status remains evidence-only,
  and actual incoming money is logged separately. Archive/unarchive is an
  effective-dated pause. Every restricted debit requires exactly one valid
  usage/expiry authorization; bounded complete-history account recovery reaches
  a fixed point without deleting encrypted evidence, and strict restore rejects
  an invalid graph.
- [x] Loan plans attach to loan liability accounts and show remaining/advanced/
  paid principal, interest, fees, dates, APR, term, debt-total inclusion, notes,
  repayment history, additional drawdown, paid-off closure, and home/vehicle/
  education/medical/personal/business/installment/credit-line/other purposes.
  Financial activity is posted atomically through the balanced ledger.
- [x] Eligible Apple on-device assistance defaults on for new and legacy
  profiles while explicit opt-out and all fail-closed input boundaries remain.
- [x] Remove optional global tab swipes so filters, charts, carousels, and lists
  retain their horizontal gestures; the fixed five-tab bar is the only global
  tab-navigation control. A present legacy preference must decode as a Boolean
  and is normalized to `false`; new initialization ignores `true` and encoding
  omits the retired key.
- [x] Flexible Today shows daily, next-seven-day, and remaining-period capacity,
  remaining days, commitments, and the inspectable arithmetic.
- [x] Plan opens directly on Budget and uses one non-scrolling adaptive peer
  selector for Budget, Calendar, Goals, and Allowances; History retains readable
  time scopes and moves dynamic hot categories into one labelled menu.
- [x] Log and edit accept bounded encrypted images/PDFs; metadata stripping,
  OCR, PDF text extraction, visual classification, and explainable History
  matching stay on device and cannot modify ledger facts.
- [x] Smart Overview widgets add privacy-safe review counts, allowance
  percentage, and relative next-commitment day status across supported Home/Lock
  families. Absent snapshot means disabled; corrupt, future-schema, oversized,
  contradictory, or negative-field content makes the whole generation stale.
  The extension is read-only, the maintenance writer canonicalizes stale state,
  accessibility Dynamic Type reduces Home density, and active-scene/reporting-
  day lifecycle work republishes and rearms from one current generation.
- [x] Core adds provider-neutral market identity, observation, freshness,
  request-policy, migration, and estimated-valuation contracts. Manual/local is
  the only active policy. Quotes are strictly positive except an explicit
  manual/manual-legacy zero write-down; provider zero is invalid. Bound source,
  record/sequence, type/delay/quality, venue/currency, and time provenance drives
  dedupe before eligibility. Provider results must bind their request identity,
  time, exact result set, supported source kind/provider, and per-instrument quote
  currency. No provider, network transport, credentials, persisted quote schema,
  background fetch, or symbol transmission ships in this tranche.
- [x] SQLCipher schema 9, recovery preview, restore validation, quarantine,
  inventory, bilingual strings, accessible errors, tests, version 0.7.1, and
  source build 11 cover the new records and flows.
- [ ] Exact-candidate macOS Xcode CI and physical-device verification remain
  evidence gates; source completion does not close them.

## 0.7.0 W1 - observation and service boundaries

- [x] Replace app-target `ObservableObject`/`@Published` state delivery with
  `@Observable`, `@Environment(AppModel.self)`, and per-property tracking
- [x] Inject separate Ledger, Planning, Assets, Portability, Capture, and
  Intelligence service seams while keeping lock and cross-service transaction
  coordination in `AppModel`
- [x] Retain the single SQLCipher transaction and rollback boundary for save,
  edit, delete, split, import, reconciliation, schedule posting, lifecycle,
  attachment retention, and goal movement
- [x] Preserve the deterministic clock, store-generation guards, cancellation,
  and quarantine behavior through the decomposition
- [x] Close C12 with FIFO profile mutation serialization, latest-choice
  convergence, and scoped-failure isolation tests
- [x] Enforce 1,200-line files, 600-line type/extension bodies, and 80-line
  function bodies under `App/` and `Sources/` in CI and release validation
- [x] PR #30 head and merge SHA `da88df25ab06e93ec5998a9edbcf0153587a9af2`
  passed the pinned macOS 15 / Xcode 16.4 CI
- [ ] Deferred: physical-device, accessibility, and performance evidence is not
  produced by this behavior-neutral architecture slice

## 0.7.0 W2 - configurable, explainable local intelligence

- [x] Add pure `MoneyUpIntelligence`, depending only on `MoneyUpCore`, with
  exact-Decimal, locale-independent recurrence/lapse/price, exact-duplicate,
  median/MAD anomaly, projection, and budget-proposal rules
- [x] Add SQLCipher schema 7 intelligence support tables and transactional
  schema-6 backfill without rewriting journal payloads, identifiers, or dates
- [x] Maintain payee/category affinity and observation facts in the same write
  as save, edit, delete, import, lifecycle changes, restore, and rebuild
- [x] Replace recent-cache category learning with bounded full-book indexed
  lookup; routine intelligence queries decode zero journal payloads
- [x] Add an enabled-by-default legacy preference; disabling intelligence
  cancels work, clears findings, and clears derived tables transactionally
- [x] Keep all findings review-only with stable rule/localization identifiers,
  exact figures, sample size, confidence class, and bounded History routing
- [x] Add editable schedule offers, currency-separated month-end projections,
  and atomic review/apply/one-action-undo for selected budget proposals
- [x] Add Settings language choice, visible Log title/details, category creation
  from Log, and category rename/archive/restore/merge/reassign/delete management
- [x] Add the deterministic 10,000-row, three-currency intelligence profile and
  committed oracle while preserving the original release fixture byte-for-byte
- [x] PR #31 head `488bdd11617565ffa6e7381ad95b63b66f718176`
  and merge SHA `4159df31b7e0b9489d1ddcd84c261296faaeda39`
  passed pinned macOS 15 / Xcode 16.4 CI, including Core/persistence/
  intelligence tests, app-model tests, and the app/widget Simulator build
- [ ] Deferred: exact-candidate physical iPhone, accessibility, migration,
  restore, and oldest-device performance evidence remains open

## 0.7.0 W3 - optional bounded on-device matching (historical)

The off-by-default W3 policy below records the 0.7.0 decision and is superseded
by 0.7.1's documented default-on setting with an explicit opt-out.

- [x] Keep the persisted Foundation Models preference off for legacy and new
  profiles; gate before planning so disabled execution invokes neither planner
  nor selector
- [x] Accept only a normalized typed request at the sole model seam, with
  scalar/UTF-8 component ceilings, a total prompt ceiling, stable lists of at
  most 16 existing names, and no raw OCR, money, date, ID, receipt, or ambient
  string path
- [x] Retain `SystemLanguageModel.default`, exact availability gating, one
  uncustomized session, and two literal `0...15` generated ordinals; retain
  deterministic ownership of every financial field and Save
- [x] Filter deterministic-history/model races per field in both completion
  orders; recheck kind, profile, splits, membership, and full field provenance
  before publication
- [x] Capture immediate pre-Use state and restore it on Reject only while the
  exact model-applied state is current; persist the restored recoverable draft
  through SQLCipher close/reopen without creating a transaction
- [x] Add contextual bilingual VoiceOver labels to model and deterministic
  history Use actions, plus truthful encrypted-draft-versus-Save copy
- [x] Pass local architecture, structure, localization, release, and mutation
  gates for this source slice
- [ ] Run exact-candidate Xcode 16 fallback and Xcode 26 macro/app tests, then
  complete bilingual VoiceOver, Apple Intelligence unavailable/cancelled,
  lock/relaunch, and eligible-device review

## 0.7.0 W4.1 - automated performance measurement baseline

- [x] Add a direct-module, serial Release XCTest target with a
  logically/domain-deterministic encrypted 10,000-entry/20-schedule fixture
  seeded outside measured blocks; bind it to the authoritative W2
  intelligence-v1 oracle and canonical logical-payload SHA-256
- [x] Observe isolated store open+close/load, save, bounded History page/query,
  CSV/XLSX export, archive, restore, receipt parsing, projection, and intelligence with
  XCTest clock, CPU, memory, and logical storage-write metrics
- [x] Pin CI to one erased iPhone 16 Pro/iOS 18.5 Simulator and retain the raw
  `.xcresult`, exported metrics/summary JSON, environment identity,
  evidence-file manifest, and log
- [ ] Run the exact candidate remotely and review its observational evidence;
  do not create timing or memory ceilings from an unreviewed Simulator run
- [ ] Deferred: all oldest/current physical-iPhone p95, peak-memory,
  interruption, energy, thermal, Vision/photo, and interaction gates remain open

## 0.7.0 W4.2 - domain-payload-free performance signposts

- [x] Centralize a closed 18-name `OSSignposter` operation inventory with only
  fixed journey outcomes and no domain/user payload API
- [x] Instrument store open/unlock, ledger load, save, History page/query,
  CSV/XLSX export, archive export/restore, receipt processing, projection, and
  deterministic intelligence at their reviewed production boundaries
- [x] Add truthful unlock-to-ready-Today-appearance, save-to-state-publication,
  generation-owned initial/later History publication, and authoritative
  post-query Calendar-compute journeys while preserving low-level intervals
- [x] Gate the names, exact source locations, complete interval ownership,
  global direct/wrapper/signposter primitive allowlist, privacy boundary, Swift
  mapping, runbook, and release workflows with escaped/C-API mutation tests
- [ ] Deferred: exact-candidate Instruments collection and log privacy review,
  oldest/current physical-device p50/p95 evidence, receipt peak memory,
  archive near-limit behavior, and sustained interaction/jank review

## 0.7.0 W6 - design primitives

- [x] Add pure policies for semantic motion, Dynamic Type-relative financial
  typography, consequential feedback, and flat/raised/floating cards
- [x] Preserve raised cards as the default; use opaque surfaces, a solid border
  under Reduce Transparency, and stronger separation under Increase Contrast
- [x] Make financial-value updates immediate and remove custom motion under
  Reduce Motion while retaining native tab and sheet transitions; migrate Quick
  Log confirmation behavior to the same policy
- [x] Enforce consequential haptics through visible-status policy and reject
  direct `sensoryFeedback` bypasses in release validation
- [x] Add exact light/dark normal/high semantic colors and ordered chart roles;
  retain the shipped normal values
- [x] Keep chart data geometry fully opaque, encode selection with a dashed
  rule, and mutation-test rendered 3:1 contrast rather than raw colors alone
- [x] Add focused hosted-app policy tests and migrate Today/Plan hero financial
  values as API proofs
- [ ] Run exact-candidate Xcode CI and the full bilingual visual/accessibility
  matrix, including grayscale and blue/yellow filtering; source policy tests do
  not close screenshot, tritan, VoiceOver, or physical-device gates

## 0.7.0 W7 - privacy-safe platform actions

- [x] Extract one shared six-case quick-action type while retaining the exact
  persisted widget raw values and existing `moneyup://quick-log/<mode>` routes
- [x] Route the action-only `OpenQuickLogIntent` through a coordinated,
  16-record/4,096-byte data-free App Group FIFO and generation-bound UI request.
  Accepted tokens survive process recreation until exact UI acknowledgement;
  a pre-acknowledgement crash may replay navigation but cannot create a
  financial commit. Canonical/backup-excluded first-unlock storage, per-submit
  reload plus authority CAS, exact postcondition reconciliation, and token-bound
  locked-capture replay keep admission and acknowledgement crash-tolerant.
  Capacity rejects newest, and durable closed-admission epochs invalidate
  queued, occupied, and local handoffs across erase, restore, key replacement,
  and tombstone startup before lifecycle work begins,
  shared by widgets, six bilingual App Shortcuts, and one configurable iOS 18
  Control Widget
- [x] Replace quick-action links with interactive intent buttons while keeping
  record-free Budget Status and Smart Overview completely passive
- [x] Gate bundle IDs, reviewed App Group entitlements, locked-capture source,
  global compiled intent/control inventory, action mappings, parameters,
  mutation/UI generations, and bilingual iOS 18/iOS 26 metadata in CI and
  protected distribution validation
- [ ] Deferred: exact-candidate Xcode metadata extraction, App Shortcuts
  Preview, signed-device Siri/Spotlight, widget-upgrade, Control Center, Lock
  Screen, Action button, authentication, and forensic privacy evidence

## Foundation

- [x] Exact Decimal money, currency minor-unit policy, locale-safe parsing, and
  independently balanced multi-currency entries
- [x] SQLCipher with pinned dependency, device-bound Keychain key, privacy
  cover, timed lock, transactional writes, and schema downgrade refusal
- [x] Quarantine/recovery that preserves encrypted raw records rather than
  locking out the readable book, including complete restricted-account debit
  authorization scanning and mutually dependent account/plan/journal fixed-point
  recovery. Per plan, work is bounded at 4,096 usage rows, 4,096 reconciliation
  rows, 512 archive transitions, and `10,000 + 2 × maxPolicyRevisions` period
  work, with 100,000 aggregate ceilings; weekday-period estimation is exact O(1)
  work from weekdays rather than calendar days
- [x] File-backed version-2 `.moneyup` archive with bounded authenticated chunks,
  version-1 compatibility, validated destructive preview, digest-bound commit,
  transactional restore, and file-backed rollback. Production restore reduces
  the raw candidate in stable key order before `AppModel` load with cooperative
  cancellation and bounded state, without a second whole-book snapshot
- [x] Dedicated missing-device-key state plus isolated, crash-resumable keyless
  `.moneyup` restore with exact old-ciphertext rollback; physical passcode-removal
  evidence remains open
- [x] Stable Gregorian reporting calendar, half-open periods, origin time-zone
  context, and stable local-day attribution
- [x] SQLCipher schema 9 with journal/posting, searchable receipt metadata, exact store
  metrics, budget-attribution, and derived intelligence indexes; compact
  balances, monthly rollover checkpoints, bounded recent activity, on-demand
  paging, and additive loan/allowance recovery coverage. Effective-dated
  allowance archive history is encoded additively inside the existing record
  payload with a strict per-plan marker, so it requires no SQL schema bump;
  genuine legacy archives infer an evidence-consistent boundary.
- [x] Exact 0.7.1 PR-head and merged-implementation release, Core/persistence/
  intelligence, app-model, app/widget Simulator, and performance jobs passed in
  CI runs 300 and 301
- [ ] Physical migration, restore, and oldest-device scale evidence

## Daily use and correction

- [x] Five permanent tabs: Today, History, center Log, Plan, Assets
- [x] Amount-first expense, income, transfers, refund, encrypted draft, smart
  defaults, field-safe validation, exactly-once Save/Undo, and keyboard
  Done/Save/tab reachability
- [x] Fast-first on-device receipt/screenshot reading with immediate progress,
  editable suggestions, finite failure, and optional metadata-stripped encrypted
  attachment
- [x] Exact N-way split logging/editing with per-line note and live remainder
- [x] Locked Quick Capture that owns no live database key or balances
- [x] Date-indexed/keyset-paged History with search, combined filters,
  per-currency totals, revisions, confirmed deletion, and chart drill-through
- [x] Account/category rename, archive, merge, unused delete, and atomic
  delete-with-reassignment
- [x] Associate correctable field validation with its input and present every
  safe-message context once through an owned native alert or retry summary; the
  scoped static gate rejects cross-owner, passive, or unassociated regressions
- [ ] Physical routine-entry timing, receipt timing, large-History scrolling,
  and end-to-end accessibility evidence

## Today, insights, and planning

- [x] Purpose-aware Flexible Today with inspectable arithmetic, explicit
  exclusions, commitments, and unavailable-state reasons
- [x] Separate cash, debt, and net-cash position; budget pace and guided empty
  states
- [x] Selectable reports, complete category distribution, trailing 12-month
  cash flow, non-color/VoiceOver encodings, and History drill-through
- [x] Arbitrary-depth budget roll-up with unbudgeted and foreign-currency
  disclosures
- [x] Schedule edit/pause/end/skip/confirm/match/post with exactly-once advance
- [x] Budget rollover with explicit activation; savings and sinking goals with
  target dates, dated contributions/withdrawals, resets, archive, and delete
- [x] Calendar no-false-zero multi-currency flows and bounded recurrence lookup
- [ ] Oldest-device 20-schedule/Calendar p95 and physical day/travel/DST matrix

## Assets and investments

- [x] Cash, bank, e-wallet, card, loan, brokerage, and investment accounts with
  consumer overdraft/amount-owed semantics
- [x] Reconciliation that never appears as income/spending
- [x] One validated searchable currency picker across setup, accounts,
  holdings, import, and rates
- [x] Ledger-linked holdings with explicit opening-cash interpretation,
  purchases, sales, dated repricing, stale warnings, and no net-worth double
  count
- [x] FIFO lots/disposals and append-only net-worth snapshots by currency
- [x] Dated user rates with direct/inverse historical lookup, visibly estimated
  conversion, and default unconverted mode
- [ ] Physical legacy-holding connection, activity chronology, sale/reprice,
  and snapshot reconciliation

## Portability and widgets

- [x] Posting-level UTF-8-BOM/formula-safe CSV and native XLSX export with
  stable IDs, exact decimals, currencies, origin day, and account metadata
- [x] Local preview-first Qianji/generic CSV/TSV import with manual column
  mapping, reviewed targets, duplicate detection, row issues, and atomic commit
- [x] Optional bounded encrypted image/PDF evidence lifecycle and local search
  projection included in raw snapshot and `.moneyup` restore, excluded from
  readable exports, widgets, logs, and diagnostics
- [x] `group.com.laiwenkang.MoneyUp` has an exact three-artifact allowlist: one
  nonfinancial language preference, one atomic bounded schema-4 Budget Status/
  Smart Overview summary `Data` value, and one bounded data-free quick-action
  ingress JSON file. The summary contains only state, a bounded reporting-period
  token, rounded budget/allowance percentages, bounded review/expense-commitment
  counts, expiry, and relative due-day distance. The ingress contains only
  schema/authority and admission metadata, opaque tokens, and one of six closed
  action values. Neither artifact contains exact due dates or record fields, and
  there is no fourth App Group key or file
- [x] Action-only App Intents, bilingual App Shortcuts, interactive quick-action
  widgets, and an iOS 18 Control Widget share one strict URL allowlist; no
  platform action writes or returns transaction data
- [x] Source validator limits app/widget entitlements to the reviewed group;
  TestFlight workflow checks both profiles and signed bundles
- [ ] Account holder registers/enables the App Group on both App IDs
- [ ] Signed IPA entitlement validation, physical widget family matrix, and
  update-preservation evidence

## Historical corrective candidates

### 0.5.1 - founder 0.5.0 findings

- [x] Refined Safe to Spend into purpose-aware Flexible Today
- [x] Routed basic locked widget capture before protected database startup
- [x] Prioritized Log fields/actions over optional detail and decoration
- [x] Replaced the former visual identity with adaptive soft green and the
  horned-money emblem
- [ ] Any unrecorded 0.5.1 exact-build/physical evidence carries into the 0.6.0
  gate; distribution alone never closes it

### 0.5.2 - founder 0.5.1 findings

- [x] Added keyboard Done, reachable Save, and draft-preserving tab navigation
- [x] Moved receipt decoding/OCR off the UI executor and added bounded
  fast-first/fallback recognition with visible population
- [x] Configured exact-commit app-model CI before packaging
- [x] Aligned source metadata at 0.5.2 build 7
- [ ] The 0.5.2 exact-build/physical gate was not recorded as a completed
  public release and is not treated as proof for 0.6.0

## 0.6.0 candidate identity

- [x] Source app and widget marketing version: 0.6.0
- [x] Source build: 8
- [x] TestFlight workflow marketing version: 0.6.0; source build 8 is checked
  before the workflow assigns a unique upload build
- [x] Bilingual in-app 0.6.0 release notes
- [x] Current product, architecture, data, privacy, security, Apple setup,
  tester, launch, and store working documents reconciled
- [x] Exact unified SHA passed release validator, 251 core/persistence tests,
  213 app-model tests, coverage reporting, and app/widget Simulator build on
  macOS in CI run 141

This identity is retained as the installed migration baseline. TestFlight
accepted 0.6.0 (1020.1) from `ff272da8` on 29 August 2026; processing,
installation, and physical evidence are separate gates.

## 0.7.0 candidate identity

- [x] Source app and widget marketing version: 0.7.0
- [x] Source build: 9
- [x] TestFlight workflow marketing version: 0.7.0; source build 9 is checked
  before the workflow assigns a unique upload build
- [x] Bilingual in-app 0.7.0 release notes cover W1/W2 user-visible changes
- [x] W1/W2 implementation passed merged-main CI run 246 on `4159df31`
- [x] Integrate the validated restore-preview ticket with missing-device-key
  recovery and the shared accessible operation-result presenter; preserve the
  private-copy digest authority and read-only pre-confirmation boundary
- [x] The final 0.7.0 release-truth source passed exact-SHA CI and its protected
  upload was accepted as 0.7.0 (1025.1); processing, installation, and physical
  evidence remain separate

## 0.7.1 candidate identity

- [x] Source app and widget marketing version: 0.7.1
- [x] Source build: 11
- [x] TestFlight workflow marketing version: 0.7.1; source build 11 is checked
  before the workflow assigns a unique upload build
- [x] Bilingual in-app 0.7.1 release notes cover the complete feedback follow-up
- [x] Local release, architecture, structure, launch-safety, platform-action,
  performance, and adversarial validator suites pass with 1052 declared Swift tests
- [x] Correct the App Review 0.3.0 launch watchdog by keeping startup
  Keychain/SQLCipher work off the UI actor without weakening encryption, and
  make the boundary mutation-tested in CI and TestFlight preflight
- [x] Prior build-10 PR-head CI run 300 and merged implementation CI run 301
  passed all four automated jobs
- [ ] Build 11 must pass exact-head and merged-main CI before signed distribution

## G2 - before wider testers

- [ ] Confirm 0.7.0 (1025.1) processing and Founders Internal availability,
  record the exact installed predecessor without deleting MoneyUp, then install
  0.7.1 over it and reconcile every collection, category hierarchy, budget pace,
  loan, allowance, Keychain state, pending capture, and widget before/after
- [ ] Restore `.moneyup` on a clean/fresh install; wrong password, tampering,
  cancellation, and failure leave the current book untouched
- [ ] Pass real-time/smart defaults, keyboard/draft, History/Calendar,
  category/pacing, loan/allowance, locked/unlocked widget routing, and receipt/
  screenshot checks on the founder and co-tester iPhones
- [ ] Measure all Golden p95 budgets with 10,000 entries and 20 schedules on the
  oldest supported iPhone
- [ ] Pass English/Simplified Chinese, VoiceOver, largest Dynamic Type, Reduce
  Motion, Reduce Transparency, Increase Contrast, grayscale/blue-yellow color
  filters, light/dark/tinted/redacted, small/large iPhone, and every widget family
- [ ] Prove the same app record, bundle IDs, App Group, Keychain namespace, app
  container, and TestFlight-to-production update path preserve data

## G3 - before public App Store 1.0

- [x] All Golden functional source surfaces mapped in traceability
- [x] Merged W1/W2 Mac/Simulator gate (CI run 246 on `4159df31`)
- [ ] Founder/co-tester seven-day run without P0/open P1
- [ ] Fourteen-day invited closed beta and update/restore evidence
- [ ] Final accessibility, performance, energy, recovery, and privacy matrices
- [ ] Exact-binary metadata/screenshots/review notes/privacy/export-compliance
  reconciliation
- [ ] App Review approval, account-holder manual release, and first-72-hour
  monitoring

## Explicitly deferred

- Multi-device sync and shared household books
- StoreKit purchase or subscription for the first public version
- Bank aggregation or third-party access to financial records
- Hosted generative AI or receipt transmission
- Provider-backed automatic market prices or any feature that transmits a
  symbol list; the current release contains contracts only and remains manual
- Two-way live spreadsheet editing
- Investment/tax advice or trade execution
- Browser app as a substitute for the native iPhone release
