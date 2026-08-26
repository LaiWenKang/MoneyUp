# Golden PRD Execution Plan

Last reconciled: 26 August 2026 against **MoneyUp Golden PRD v1.1**.

The Golden PRD is the product and release authority. Security/privacy
invariants come next, followed by founder decisions and Issue #10, then the
current implementation. The 0.4.0 audit and earlier PRD are supporting evidence
where they do not conflict. In particular, multi-device
sync and monetization are not part of 1.0 without a new approved decision.

Completed checkboxes below describe behavior present in the current source
candidate. A code status of implemented does not close a gate until the listed
automated or physical evidence passes on the exact candidate.

## Foundation — finance and secure storage

- [x] Exact decimal money and normalized currencies
- [x] Balanced multi-currency journal entries and validated decoding
- [x] Arbitrary-depth budget roll-up
- [x] SQLCipher encrypted store with pinned dependency
- [x] Versioned schema and transactional writes
- [x] Random Keychain key with local user-presence control
- [x] Automatic background lock, decoded-state clearing, and privacy cover
- [x] Wrong-key, plaintext-leak, migration-compatibility, and rollback tests
- [x] Destructive failed-recovery path with explicit confirmation

## Daily use — Founders Beta 0.5.0

- [x] Four-step guided onboarding with privacy/purpose, base currency, first
  account, review, inline explanations, Back/Continue, and explicit next actions
- [x] Expense, income, same-currency, and foreign-currency transfer logging
- [x] Multiple account types, cards, loans, and balance reconciliation
- [x] Default categories plus arbitrary-depth custom expense categories
- [x] Monthly limits with descendant spending roll-up
- [x] Recurring income and expense templates
- [x] Finance calendar with actual and projected money flow
- [x] Category-spending and monthly cash-flow charts over a selectable period
- [x] Tap-to-inspect category and cash-flow charts with matching History filters
- [x] Safe to Spend Today with checkable scheduled-commitment arithmetic and
  explicit foreign-currency, unbudgeted, rate, income, and schedule assumptions
- [x] Consumer-language cash, debt, and net-cash position with a precise 2D diagram
- [x] Read-only budget what-if simulator with exact Decimal arithmetic
- [x] Non-base-currency activity reported explicitly instead of dropped
- [x] Manually valued holdings and base-currency net worth
- [x] Configurable privacy-redacted Home and Lock Screen quick-log shortcuts
- [x] Five permanent tabs for Today, History, center Log, Plan, and Assets
- [x] Center Log tab with encrypted draft recovery and Undo
- [x] On-device receipt reading, typed-phrase entry, and category suggestions
- [x] Adaptive soft-green semantic palette, shared horned-money emblem,
  reproducible light/dark/tinted app icons, original decorative 3D assets,
  exact 2D financial graphics, matching widget, biometry-accurate lock screen,
  and in-app version
- [x] Enriched, formula-safe CSV export through the system file picker
- [x] English and Simplified Chinese UI
- [x] CI for Swift tests and the app plus widget Simulator build
- [x] App privacy manifest and bilingual in-app privacy/beta disclosure
- [x] Confirmed deletion for transactions, schedules, and manual holdings
- [x] Exclude non-restorable encrypted database files from system backup
- [x] Configurable one-minute-default auto-lock and locked Quick Capture inbox
- [x] Searchable History with kind filters, refunds, and atomic transaction editing
- [x] Locale-safe manual amount fields

## Candidate verification — before the next internal 0.5.0 upload

| Golden requirement | Code status after this change | Evidence still required |
|---|---|---|
| Enforce minor units on every new write/import while preserving legacy values exactly | Implemented for log, transfer, reconciliation, budget, schedule, holding-price, onboarding/account, and import boundaries | Green core/app suites and a final write-boundary audit |
| Reject or explicitly convert an edit that changes account currency | Implemented as rejection; same-currency legacy values remain exact | App test and Simulator UI check |
| Combine account, category, kind, inclusive date, and amount History filters | Implemented with a reusable query, obvious reset flow, and 10,000-entry CI guard | Green core test and Simulator build plus bilingual UI review; physical p95 is G2 |
| Use one half-open financial-period boundary | Implemented in core and used by reporting and History; midnight/DST regression tests added | Green core suite and final date-path audit |
| Cover locale and extreme manual money input | Explicit-locale comma-decimal, negative, garbage-suffix, and large-Decimal tests added; currency precision gates remain shared | Green app/core suites and bilingual Simulator entry check |
| Give first-time users an unambiguous setup path | Four-step flow, field-level guidance, review, overdraft/debt language, and visible Today Log/Plan actions implemented | English/Chinese VoiceOver, largest Dynamic Type, light/dark physical walkthrough |
| Replace the old visual identity | Semantic soft-green/off-white/deep-charcoal tokens, restrained gradients/graphics, icon, widget, and palette CI guard implemented | Light/dark/tinted screenshot and contrast review on physical iPhones |
| Show filtered totals separately by currency | Implemented as signed movement per currency; same-currency transfers offset and foreign-currency sides remain separate | Product/UI review and filter-result reconciliation |
| Retain encrypted revisions and invalidate derived caches immediately | Existing atomic write retained; app regression test added | App test must pass in CI |
| Remove or honor `lockWhenBackgrounded` | Removed from the runtime model and future encoding; legacy JSON remains decodable | Core migration test must pass |
| Add AppModel race-condition coverage | Deterministic lifecycle hooks and all named lock/save, scan, erase, stale-generation, deep-link, and capture-promotion cases added | App suite must pass in CI |
| Validate the exact candidate | CI now includes app tests | Release assets, core tests, app tests, app/widget build, unique version/build, and exact-commit packaging must all be green |

Derived financial failures now propagate an explicit unavailable state, show a
localized reason plus a redacted diagnostic code, and log no transaction
content (TOD-06/DAT-08); CI and bilingual Simulator review remain required.
The shared half-open boundary, locale/extreme-value regression coverage, and a
10,000-entry History CI scale guard are now committed. G1 remains open until
the complete core/app suites and Simulator build are green on the exact commit,
then the bilingual light/dark accessibility walkthrough records its physical
evidence.

## G2 — after internal upload, before wider testers

- [ ] Install 0.5.0 over the founder's existing 0.4.1 TestFlight app without
  deleting it; reconcile profile, accounts, entries, budgets, schedules,
  holdings, settings, widgets, and pending captures before and after.
- [ ] Restore a password-protected `.moneyup` backup on a clean/fresh install;
  verify wrong password, cancellation, and failure leave the current book
  untouched.
- [ ] Pass five-tab physical navigation with the keyboard active, unfinished
  drafts, lock/unlock, and exactly-once external routing.
- [ ] Measure 10,000 entries and 20 schedules on the oldest supported iPhone
  against the Golden PRD latency and scrolling budgets.
- [ ] Pass English and Simplified Chinese with VoiceOver, largest Dynamic Type,
  Reduce Motion, light/dark/tinted appearance, and small/large iPhones.
- [ ] Prove the same App Store record, bundle IDs, Keychain namespace, app
  container, widget configuration, and TestFlight-to-production update path
  preserve the tester's data.

## G3 — before public App Store 1.0

- [x] Today: Safe to Spend, consumer-language cash/debt position, budget pace,
  chart inspection/drill-through, guided empty states, and auditable exclusions.
- [ ] Widget: opt-in redacted budget percentage with no amount, payee, account,
  holding, or balance. The 0.5.0 widget visual refresh remains data-free.
- [ ] Assets: account/category rename/archive/merge/delete-with-reassignment,
  holding repricing/staleness, ledger-linked investments, one currency picker,
  lots, and net-worth history.
- [ ] Plan and Log: schedule lifecycle/posting/matching, split transactions,
  optional encrypted attachments, dated user exchange rates, rollover, sinking
  funds, and savings goals.
- [ ] Portability: native XLSX and manual mapping for unknown CSV layouts.
- [ ] Quality/release: close every P0/P1, complete the two-person seven-day run,
  closed-beta gates, final accessibility/performance matrices, truthful store
  compliance, manual release, and the first-72-hour monitoring plan.

## Explicitly deferred pending a new privacy/product decision

- Multi-device sync, shared books, and two-way live spreadsheet editing.
- Bank aggregation or any third-party access to financial records.
- Hosted generative AI or receipt transmission.
- Automatic market prices that disclose a user's symbol list.
