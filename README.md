# MoneyUp

**Private money, clearly understood.**

MoneyUp is a local-first iOS budget and personal-finance app. It combines fast
logging with a balanced ledger, multi-level budgets, a finance calendar,
on-device charts, accounts and holdings, and spreadsheet-friendly export.

## Project status

MoneyUp's source app identity is **Founders Beta 0.7.1 (source build 11)**.
This candidate extends the feedback baseline merged through pull request #40
with exact split assistance, stronger keyboard avoidance, direct hierarchical
category management, default-on eligible on-device assistance, useful
History shortcuts, general loan purposes, optional tab gestures, account-aware
allowances, selectable pacing, a Plan overview, and a privacy-safe Smart
Overview widget. A second feedback pass then made every amount name its own
currency where a symbol would be ambiguous, rebuilt Today around user-pinned
budget categories with month/week/day remaining, removed the parts of Today
that another tab already owned, and gave every swapped Plan section an
explicit way back. A density pass then moved routine explanation behind a
single glyph, gave Today's cards a headline figure with their supporting rows
one tap away, and replaced captions that named a figure with the symbol for it.
The current feedback pass defaults exact amounts to glance-private masking,
replaces generic History chips with actual hot categories, surfaces the budget
simulator and interactive chart preview, removes duplicate navigation, and adds
Reduce-Motion-safe spring, selection, and press feedback.
The prior merged baseline passed release,
architecture, recovery, privacy, core/app-model, unsigned app/widget Simulator,
and serial performance CI; build 11 must repeat those exact-head gates. Physical iPhone migration,
restore, accessibility, performance, signed-binary, TestFlight-processing,
closed-beta, and App Review evidence remain release gates. Developers can
install the app from source on an iOS 18 device through Xcode.

The beta includes:

- an encrypted SQLCipher database with a random 256-bit app-generated,
  device-bound key;
- Keychain protection requiring device-owner presence, configurable timed
  auto-lock (one minute by default), and an immediate app-switcher privacy cover;
- a four-step first-run guide that explains the local-only model, base currency,
  first financial account, opening balance or amount owed, review, and what to
  do next;
- persistent expense, income, same-currency, and foreign-currency transfers;
- account balance reconciliation that does not distort income or spending;
- arbitrary-depth categories and monthly limits with correct roll-up, dated
  rollover rules, sinking funds, and savings goals with contributions,
  withdrawals, resets, archive, and deletion; parent categories can be changed
  safely, and flexible budgets can expose exact daily or weekly pacing;
- planning-only employer allowances with daily, weekday, weekly, or monthly
  cadence, optional end dates, category eligibility, no/full/capped rollover,
  and usage history; allowance value never inflates income, cash, or net worth;
- actual and recurring projected money flow in the finance calendar, including
  schedule editing, pausing, ending, skipping, confirming, matching, and
  exactly-once posting;
- selectable report periods with category and monthly cash-flow charts, plus
  deterministic readings, all calculated on device;
- a Today board of up to eight pinned budget categories, each showing what is
  left for the month with the same remainder apportioned across the coming week
  and the current day, all resolved from one reporting instant; Flexible Today
  keeps its purpose-classified allocations, tap-through arithmetic breakdown,
  flexible commitments, and explicit exclusions, and collapses beside the board
  once categories are pinned; bills, debt, and goals never become discretionary
  money, and separate cash-versus-debt positioning is unchanged;
- tappable category and monthly-flow charts that inspect exact values and open
  History with the matching category/date filters, plus a six-month net-flow
  preview on Today;
- a read-only budget what-if simulator for additional spending and income that
  never mutates the ledger, budget, or reports;
- explicit reporting of money held or spent outside the base currency, which is
  listed on its own with its ISO code rather than converted or dropped;
- amounts that name their own currency: an ISO code is added automatically
  wherever two currencies the book actually holds would otherwise share one
  locale symbol, with explicit symbol-only and code-always settings, a live
  sample of every currency held, and account pickers that name the currency
  they are about to record money in;
- a default-on glance-privacy preference that renders exact amounts as `*****`
  across amount-heavy surfaces, is available from every primary money screen
  and Settings, and reveals a populated Log amount only when the user taps it
  to edit before remasking on blur;
- bank, cash, e-wallet, card, loan, brokerage, and investment accounts with
  atomic rename, archive, merge, and delete-with-reassignment workflows;
- loan plans attached to liability accounts with remaining principal, total
  advanced, principal paid, interest, fees, APR, term, debt-total inclusion,
  repayments, additional drawdowns, activity notes, and paid-off closure;
  every money movement remains an atomic balanced journal entry;
- ledger-linked manually priced holdings with dated price history, stale-price
  warnings, explicit opening-cash treatment, FIFO lots and disposals, and
  frozen net-worth snapshots kept separate by currency;
- smart entry that reads a receipt photo or screenshot with bounded, fast-first
  on-device text recognition, shows reading progress immediately, populates
  visible amount/payee/date suggestions, parses typed phrases such as "lunch
  12.50 cash yesterday", and suggests a category from the user's own history,
  with no remote model involved; an eligible Apple on-device model is enabled
  by default and can propose a reviewed match from at most 16 existing local
  names, with an explicit opt-out,
  while exact rules retain every financial field and Save; accepting a match
  immediately updates only the recoverable encrypted draft and creates no
  transaction until Save; receipt images remain transient unless the user
  explicitly keeps one as an encrypted transaction attachment;
- progressive disclosure as the default: routine section explanation sits
  behind one information glyph and stays an immediate VoiceOver hint, Today's
  position and budget cards lead with a single figure and expand on tap, and
  the pinned board and budget list each carry one detail switch instead of
  per-row chrome; guidance shown at a destructive or irreversible decision is
  deliberately never collapsed, and remembered layout preferences use a closed
  set of keys that cannot carry book content;
- a permanent five-tab layout for Today, History, center Log, Plan, and Assets,
  with an optional deliberate left/right swipe shortcut, a Plan overview that
  routes to Budget, Calendar, Goals, and Allowances without repeating them in
  the chip bar, and a named top-left route back to that overview from every
  swapped section; Today shows only what no other tab owns;
  Log retains encrypted draft recovery, configurable smart defaults, success
  feedback, and Undo, while the keyboard provides Done, reachable Save, and a
  draft-preserving route to every other tab;
- an always-visible title-or-merchant field and multi-line description/notes
  field in Log, exact smart split/rebalance presets, allowance application, and
  direct searchable category management with visible arbitrary-depth child
  creation, rename, reparent, archive/restore, merge, reassignment, and deletion;
- a searchable, filterable, date-indexed History tab with Today, seven-day,
  month, and all-time scopes plus hot-category shortcuts derived from bounded
  recent frequency and recency; complete advanced account/category/kind/date/amount
  filters; complete per-currency spending, income, refunds,
  and net summaries; visible title, notes, and hierarchical category paths;
  encrypted keyset paging; refunds; and atomic
  transaction editing, including exact N-way category splits with live
  remainder; prior versions are retained in the encrypted revision collection;
- configurable privacy-redacted Home and Lock Screen widgets for expense,
  income, transfer, refund, smart entry, and receipt scanning; a separate
  encrypted Quick Capture inbox that does not reveal balances while locked;
  and configurable Budget Status or Smart Overview surfaces whose opt-in App
  Group snapshot contains only budget/allowance percentages, bounded review/
  allowance/commitment counts, state, expiry, and the next commitment time,
  never amounts, payees, accounts, holdings, balances, or ledger identifiers;
- six bilingual, action-only App Shortcuts, interactive quick-action widget
  buttons, and a configurable iOS 18 Control Widget that open only the existing
  allowlisted routes; Budget status remains passive and no platform action
  carries or returns transaction details;
- file-backed password-protected `.moneyup` v2 backup with bounded authenticated
  chunks, v1 compatibility, and transactional restore/rollback;
- preview-first local import for Qianji-style and generic CSV/TSV exports, with
  manual column mapping, reviewed account/category targets, duplicate
  detection, row-level issues, and atomic saving;
- posting-level CSV and native XLSX export with account metadata, stable IDs,
  exact currencies, and formula-safe user text for Numbers and Excel;
- dated user-supplied exchange rates with historical estimated conversion and
  explicit unconverted results when no applicable rate exists;
- English and Simplified Chinese UI and first-run categories, with an in-app
  System/English/Simplified Chinese preference shared with the widget;
- a distinctive soft-green horned-money emblem shared by the app icon,
  first-run surfaces, and privacy-safe widget; original dimensional
  illustrations for atmosphere; exact 2D position, pace, and scenario graphics;
  and semantic off-white or deep-charcoal surfaces with no pure-white or
  pure-black primary canvas; a lock screen that names the biometry the device
  actually has; and in-app release notes;
- an App Store privacy manifest, an in-app bilingual privacy and beta guide,
  backup exclusion for non-restorable ciphertext, and confirmations before
  permanent transaction, schedule, or holding deletion;
- SQLCipher schema-8 normalized journal, receipt, budget-attribution,
  intelligence, and exact store-metric indexes; compact balances, monthly
  rollover checkpoints, a bounded recent-activity cache, and on-demand
  History/Calendar/export/intelligence reads so normal unlock does not retain
  the full journal or healthy attribution history;
- optional local intelligence for payee/category affinity, recurring or lapsed
  patterns, price changes, exact duplicates, robust spending anomalies,
  per-currency month-end projections, and reviewable budget-limit proposals;
  findings show their rule and figures, schedules are never auto-created, and
  budget changes are never auto-applied;
- source-configured Swift domain and app-model suites, an unsigned iOS
  Simulator app/widget build gate, and a serial Release 10,000-entry/20-schedule
  measurement baseline configured to retain raw and JSON evidence; the prior
  build-10 candidate passed all four automated CI jobs in runs 300 and 301,
  while build 11 requires its own exact-head result.

The unified 0.7.1 candidate still requires signed exact-binary validation,
physical upgrade/restore and 10,000-entry performance drills, bilingual
visual/accessibility/widget checks, the founder/co-tester seven-day run, closed
beta, and App Store gates. Source implementation is not evidence that those
gates passed. Keep a separate encrypted backup; CSV and XLSX snapshots remain
readable plaintext and should be protected. The complete requirement/evidence split is in
[Golden PRD traceability](docs/GOLDEN_TRACEABILITY.md). The complete
feedback-to-implementation overlay is in
[0.7.1 release scope](docs/RELEASE_0.7.1.md).

## Install the beta

### iPhone-only tester

Install Apple's TestFlight app, open the private MoneyUp invitation, and tap
Install. MoneyUp itself has no
login; the invitation uses an Apple Account through TestFlight and never needs
a ChatGPT account. See the [first-test runbook](docs/FIRST_TEST.md).

The Apple Developer membership is active, both bundle identifiers and the App
Store Connect record exist, and the protected GitHub environment has been
configured by the account holder. New candidates go through signed validation
and the protected upload workflow. The
[iPhone-only Apple setup guide](docs/APPLE_SETUP.md) gives the exact steps and
keeps every private key out of the repository and chat.

### Developer source install

You need a Mac with Xcode 16 or later, XcodeGen, and an iPhone running iOS 18 or
later with a device passcode enabled.

```bash
git clone https://github.com/LaiWenKang/MoneyUp.git
cd MoneyUp
brew install xcodegen
xcodegen generate
open MoneyUp.xcodeproj
```

In Xcode, choose a signing team for both `MoneyUp` and `MoneyUpWidget`, select
your iPhone, enable the reviewed App Group for both targets, and press Run. If
the bundle identifiers are unavailable, replace both identifiers and the App
Group in the project/entitlement configuration, regenerate the project, and
try again.

See [Beta installation and use](docs/BETA_INSTALL.md) for the complete setup,
first-run checklist, widget steps, and data-retention caveats.
The release gates and founder/co-tester TestFlight protocol are in the
[launch plan](docs/LAUNCH_PLAN.md) and [first-test runbook](docs/FIRST_TEST.md).
Entitlement-seeded release archives and Apple Distribution-signed IPAs use the
protected, manual [TestFlight workflow](.github/workflows/testflight.yml), which
requires Xcode 26, the iOS 26 SDK, immutable dependencies, explicit
confirmation, and round-trip-verified encrypted retention of the archive,
dSYMs, export directory, exact IPA, and IPA SHA-256 before Apple receives that
same validated IPA. The repository owner can also dispatch that workflow from
the dedicated [release-control issue](https://github.com/LaiWenKang/MoneyUp/issues/23)
with the exact command `/moneyup-testflight validate` or, only after an explicit
upload decision, `/moneyup-testflight upload UPLOAD`. The relay rejects every
other author, issue, pull-request comment, and command spelling, and the
TestFlight workflow rejects the run if `main` moves after authorization.

## Product principles

1. **Local first:** the core experience works without an account or network.
2. **Privacy is architectural:** no ads, financial telemetry, backend, or
   remote AI receives financial records.
3. **Simple outside, rigorous inside:** consumer-friendly flows commit balanced
   journal entries using exact decimal amounts.
4. **Smart means explainable:** insights are deterministic and calculated on
   device.
5. **Portable by default:** readable exports retain stable identifiers and
   accounting detail.
6. **Bilingual by design:** English and Simplified Chinese ship together.

## Repository layout

```text
App/MoneyUp/                    SwiftUI iOS application
App/MoneyUpWidget/              Privacy-safe WidgetKit extension
Sources/MoneyUpCore/            Finance domain and export rules
Sources/MoneyUpPersistence/     SQLCipher encrypted record store
Tests/                          Domain and encrypted-store tests
docs/                           Product, architecture, data, and roadmap
project.yml                     Reproducible XcodeGen definition
Package.swift                   Swift package and pinned dependency
```

## Build and test

```bash
swift test -Xswiftc -warnings-as-errors
xcodegen generate
xcodebuild \
  -project MoneyUp.xcodeproj \
  -scheme MoneyUp \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The generated Xcode project is intentionally ignored. CI repeats both commands
on every change to `main` and on pull requests.

The separate `MoneyUpPerformance` scheme runs an observational optimized
baseline on the CI-pinned iPhone 16 Pro/iOS 18.5 Simulator. See
[Automated performance baseline](docs/PERFORMANCE_BASELINE.md) for the measured
paths and evidence boundary. Its results never replace the oldest-iPhone p95,
peak-memory, scrolling, receipt/Vision, or interruption gates.

## Security

MoneyUp does not operate a service that receives raw financial data. Data
leaves the app only through an explicit export action. This guarantee cannot
protect a compromised operating system, an already-unlocked screen, user-made
screenshots, or plaintext files after the user exports them.

See [SECURITY.md](SECURITY.md) for implemented controls, limits, recovery
behavior, and vulnerability reporting.

## Documentation

- [Beta installation and use](docs/BETA_INSTALL.md)
- [Product definition](docs/PRODUCT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Visual system](docs/VISUAL_SYSTEM.md)
- [Data model and invariants](docs/DATA_MODEL.md)
- [Delivery roadmap](docs/ROADMAP.md)
- [Golden PRD traceability](docs/GOLDEN_TRACEABILITY.md)

## License

MoneyUp is available under the [MIT License](LICENSE). SQLCipher notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
