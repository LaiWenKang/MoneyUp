# MoneyUp 0.7.1 — Complete Feedback Follow-up

Source identity: **Founders Beta 0.7.1, build 11**.

This release includes every nonblank item from the 0.6.0 feedback list while
preserving MoneyUp's local-only, encrypted, exact-Decimal, balanced-ledger, and
five-tab product contracts.

## App Review launch correction

Apple's 0.3.0 (1005.1) report is a launch watchdog termination, not an
accounting failure. Its supplied stack shows the main thread waiting in
`SecItemCopyMatching` / `LAContext.evaluateAccessControl` until FrontBoard
terminated scene creation after 19.98 seconds. In this candidate:

- the user-presence-protected database key loads in a user-initiated detached
  task without weakening its device-only Keychain access control;
- SQLCipher construction stays in the same detached boundary and temporary key
  bytes are overwritten on every exit;
- the normal `AppModel.start()` erase-tombstone Keychain query is also
  detached, removing its synchronous XPC call from the protected-book startup
  path;
- executable iOS tests assert both boundaries run off the main thread; and
- a mutation-tested launch-safety validator blocks CI, release validation, and
  TestFlight preflight if these boundaries, the reviewed Keychain inventory,
  dSYM output, or their regression tests drift.

Physical cold-launch, delayed/cancelled authentication, background/foreground,
and repeated-launch evidence on iOS 26.6 remains required before resubmission.

| Feedback | 0.7.1 behavior |
|---|---|
| Smart split calculation | Quick Log and transaction editing offer Equal, Rebalance unlocked, 50/50, 60/40, and 70/30 actions. Exact currency minor units are distributed deterministically, locked rows stay unchanged, and the result always reconciles to the entered total. |
| Keyboard hides the last row | Both forms react to the keyboard safe area, reserve focused-field space, scroll immediately and again after keyboard layout settles, support interactive swipe-down dismissal, and always expose Done. |
| Category management and deeper subcategories | Log exposes Add and Manage Categories together. The searchable manager shows full paths and a visible add-subcategory action on every active category; arbitrary depth, safe reparenting, cycle checks, archive, merge, reassignment, and delete remain supported. |
| On-device intelligence default | Deterministic intelligence and eligible Apple on-device ordinal assistance default on for new and legacy profiles. Users retain an explicit Settings opt-out; unsupported, failed, cancelled, or stale model work changes nothing. |
| Second History filter row | Today, 7 days, Month, and All remain the time row. A second composable row filters Needs Review, Split, Recurring, Allowance, and Has Notes, intersecting exact entry IDs when multiple filters are selected. |
| Loans beyond cars | Loan plans now carry a purpose: home, vehicle, education, medical, personal, business, installment, credit line, or other. Purpose changes presentation only; principal and repayments remain ledger-authoritative. |
| Swipe between tabs | An optional Settings gesture moves one tab left or right after a deliberate horizontal swipe, never wraps at the ends, and never removes the visible tab bar. It defaults off to avoid collisions with charts and horizontal controls. |
| Configurable expiring allowances | Benefits supports limit-only, prepaid-asset, and reimbursement modes; currency-matched linked asset accounts; daily/weekday/weekly/monthly cadence; start/end dates; eligible categories; notes/history; and no/capped/full rollover. Quick Log can atomically link an eligible expense to its allowance usage. |
| Daily/weekly budget flexibility | Plan lets the user view an exact flexible remainder as Today, This week, or Rest of month without mutating the underlying monthly limit. Each result uses the selected civil-day cadence and currency rounding. |
| Useful Flexible Today | Today now shows the current daily amount, next-seven-day capacity, remaining-period capacity and days, plus reserved commitments and a tap-through arithmetic explanation. |
| Five-tab organization | The five permanent tabs remain Today, History, Log, Plan, and Assets. Plan now opens on a compact overview and offers Budget, Calendar, Goals, and Allowances as clear internal destinations; Log and History keep the highest-frequency tasks one tap away. |
| Currency clarity everywhere | Amounts add their ISO code automatically wherever two currencies the book actually holds would otherwise render with the same locale symbol; a single-currency book is unchanged. Settings adds a Currency section naming the base currency, offering Automatic, Currency symbol, or ISO code, sampling every currency held, and holding the saved-rate route. Every account picker that decides the currency of money being entered names that currency once the book holds more than one, and foreign balances and excluded foreign spending always carry their code. |
| Today reworked around pinned categories | Today leads with up to eight pinned budget categories, each showing what is left for the month plus that same remainder apportioned across the coming week and the current day in a quieter type size, all resolved from one reporting instant. An overspent category reports its overspend instead of a negative pace, and every pinned row names its purpose so an even split of a commitment is never read as discretionary money. Pins are chosen from the board or swiped in from the Plan budget list, and are stored with the encrypted profile. |
| Less repetition per tab | Today no longer repeats what another tab owns: the recent-transaction list belongs to History, the Assets shortcut to the Assets tab, and the privacy explainer to Settings. Safe to spend keeps its full hero only until categories are pinned, then collapses to one line that still opens its arithmetic. The Plan chip bar no longer duplicates the overview list it sits above. |
| A way back | Every Plan section swapped in behind the chip bar now carries a named top-left route back to the overview, and a Calendar pushed from History no longer nests a second navigation stack that removed History's own back button. |
| Too many words, too little graphic | Routine explanation is one glyph away instead of permanent screen furniture: 24 always-visible section footers and captions became tap-to-reveal explainers, and their text stays an immediate VoiceOver hint so nothing is hidden from the people most likely to need it. Today's position and budget cards lead with one figure beside a symbol and keep their supporting rows behind a tap; the pinned board and the Plan budget list each carry one detail switch rather than per-row chrome; captions that merely named a figure were replaced by the symbol for it, with the name preserved for VoiceOver and restored on screen at accessibility text sizes. Safe to spend drops the two lines its arithmetic sheet already states exactly. Data-safety and recovery guidance shown at a destructive or irreversible decision stays visible by design. |
| Premium widget system | The configurable widget adds Smart Overview beside Quick Actions and Budget Status. Supported Home and Lock Screen families show privacy-safe review counts, allowance remaining percentage, and next-commitment timing with concise branded tiles; no amount, payee, account name, holding, balance, transaction, or ledger ID crosses the App Group. |

## Accounting and privacy decisions

- Loan principal remains authoritative in the liability ledger account. Loan
  metadata never becomes a competing balance.
- Interest and fees are explicit expense postings. A repayment cannot silently
  overpay principal, and a loan cannot close above zero.
- Allowance metadata never creates money. Limit-only use remains planning-only;
  prepaid and reimbursement modes point to a real same-currency asset account
  whose ledger balance remains authoritative. Linking a saved expense records
  evidence atomically and deleting or replacing it removes or relinks that
  evidence in the same transaction.
- No remote model, analytics SDK, backend, currency conversion, or tracking was
  added. Smart defaults use only deterministic on-device data.
- Amounts remain exact `Decimal`; all journal entries balance independently by
  currency; currencies are never silently mixed or converted.

## Release evidence

Locally completed on this source candidate:

- release-asset validation, including 1,322 bilingual strings across three catalogs;
- architecture and Swift structure fitness;
- offline/privacy/recovery mutation gates;
- 112 Python validator tests across the architecture, platform-action, and
  performance suites;
- 752 declared Swift tests: 701 XCTest and 51 Swift Testing declarations;
- clean patch whitespace validation.

Still required on the exact release-truth commit:

- macOS Xcode build and all Swift test targets in GitHub Actions;
- unsigned app/widget Simulator build;
- signed archive and TestFlight processing;
- physical iPhone keyboard, migration, restore, accessibility, performance,
  widget, lock-state, bilingual, and seven-day beta evidence.

Source implementation or declared tests must not be reported as physical or
signed evidence.
