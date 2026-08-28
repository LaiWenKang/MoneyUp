# Golden PRD Execution Plan

Last reconciled: 28 August 2026 against the uploaded MoneyUp Golden PRD
(document version 1.0; supplied file label v1.1), the independent 0.4.0 audit,
and later accepted founder decisions.

The Golden PRD is the functional/release authority. Security and accounting
invariants remain non-negotiable. The earlier PRD is supporting evidence only
where it does not conflict. Its StoreKit and CloudKit requirements are
superseded: the approved first public release is free and local-only.

Checked source items describe the source-integrated 0.6.0 candidate. They do
not close exact-candidate Mac CI, physical-device, TestFlight, closed-beta, or
App Store gates. See [Golden PRD traceability](GOLDEN_TRACEABILITY.md) for every
requirement ID and its evidence status.

## Foundation

- [x] Exact Decimal money, currency minor-unit policy, locale-safe parsing, and
  independently balanced multi-currency entries
- [x] SQLCipher with pinned dependency, device-bound Keychain key, privacy
  cover, timed lock, transactional writes, and schema downgrade refusal
- [x] Quarantine/recovery that preserves encrypted raw records rather than
  locking out the readable book
- [x] File-backed version-2 `.moneyup` archive with bounded authenticated chunks,
  version-1 compatibility, transactional restore, and file-backed rollback
- [x] Stable Gregorian reporting calendar, half-open periods, origin time-zone
  context, and stable local-day attribution
- [x] SQLCipher schema 6 with journal/posting, receipt metadata, exact store
  metrics, and budget-attribution indexes; compact balances, monthly rollover
  checkpoints, bounded recent activity, and on-demand paging
- [ ] Exact-candidate Mac core/persistence/app tests and app/widget Simulator
  build
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
- [x] Optional encrypted receipt attachment lifecycle included in raw snapshot
  and `.moneyup` restore, excluded from readable exports
- [x] Privacy-redacted widget actions and opt-in percentage/state-only budget
  snapshot using `group.com.laiwenkang.MoneyUp`
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
- [ ] Exact unified SHA passes release validator, Swift tests, app-model XCTest,
  and app/widget Simulator build on macOS

## G2 - before wider testers

- [ ] Install 0.6.0 over the founder's existing 0.5.1 TestFlight app without
  deletion; reconcile every collection, Keychain state, pending capture, and
  widget before/after
- [ ] Restore `.moneyup` on a clean/fresh install; wrong password, tampering,
  cancellation, and failure leave the current book untouched
- [ ] Pass keyboard/draft/lock/routing and receipt/screenshot checks on the
  founder and co-tester iPhones
- [ ] Measure all Golden p95 budgets with 10,000 entries and 20 schedules on the
  oldest supported iPhone
- [ ] Pass English/Simplified Chinese, VoiceOver, largest Dynamic Type, Reduce
  Motion, light/dark/tinted/redacted, small/large iPhone, and every widget family
- [ ] Prove the same app record, bundle IDs, App Group, Keychain namespace, app
  container, and TestFlight-to-production update path preserve data

## G3 - before public App Store 1.0

- [x] All Golden functional source surfaces mapped in traceability
- [ ] Exact-candidate Mac/Simulator gate
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
- Automatic market prices that disclose a symbol list
- Two-way live spreadsheet editing
- Investment/tax advice or trade execution
- Browser app as a substitute for the native iPhone release
