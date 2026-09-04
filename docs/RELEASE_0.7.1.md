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
| Useful History shortcuts | Today, 7 days, Month, and All remain the time row. The generic “smart” row is replaced by up to five hot categories ranked from the person's bounded recent activity by frequency, then recency, with deterministic ties. One split entry counts once per category; archived and system accounts are excluded. The complete advanced filter sheet remains available. |
| Loans beyond cars | Loan plans now carry a purpose: home, vehicle, education, medical, personal, business, installment, credit line, or other. Purpose changes presentation only; principal and repayments remain ledger-authoritative. |
| Swipe between tabs | An optional Settings gesture moves one tab left or right after a deliberate horizontal swipe, never wraps at the ends, and never removes the visible tab bar. It defaults off to avoid collisions with charts and horizontal controls. |
| Configurable expiring allowances | Benefits supports limit-only, prepaid-asset, and reimbursement modes; currency-matched linked asset accounts; daily/weekday/weekly/monthly cadence; start/end dates; eligible categories; notes/history; and no/capped/full rollover. Quick Log can atomically link an eligible expense to its allowance usage. |
| Daily/weekly budget flexibility | Plan lets the user view an exact flexible remainder as Today, This week, or Rest of month without mutating the underlying monthly limit. Each result uses the selected civil-day cadence and currency rounding. |
| Useful Flexible Today | Today now shows the current daily amount, next-seven-day capacity, remaining-period capacity and days, plus reserved commitments and a tap-through arithmetic explanation. |
| Five-tab organization | The five permanent tabs remain Today, History, Log, Plan, and Assets. Plan now opens on a compact overview and offers Budget, Calendar, Goals, and Allowances as clear internal destinations; Log and History keep the highest-frequency tasks one tap away. |
| Currency clarity everywhere | Amounts add their ISO code automatically wherever two currencies the book actually holds would otherwise render with the same locale symbol; a single-currency book is unchanged. Settings adds a Currency section naming the base currency, offering Automatic, Currency symbol, or ISO code, sampling every currency held, and holding the saved-rate route. Every account picker that decides the currency of money being entered names that currency once the book holds more than one, and foreign balances and excluded foreign spending always carry their code. |
| Today reworked around pinned categories | Today leads with up to eight pinned budget categories, each showing what is left for the month plus that same remainder apportioned across the coming week and the current day in a quieter type size, all resolved from one reporting instant. An overspent category reports its overspend instead of a negative pace, and every pinned row names its purpose so an even split of a commitment is never read as discretionary money. Pins are chosen from the board or swiped in from the Plan budget list, and are stored with the encrypted profile. |
| Less repetition per tab | Today no longer repeats what another tab owns: the recent-transaction list belongs to History, the Assets shortcut to the Assets tab, the Log/Plan buttons to their permanent tabs, and the privacy explanation to Settings. Safe to spend keeps its full hero only until categories are pinned, then collapses to one line that still opens its arithmetic. Plan shows its section switcher only inside a section, so its overview list is the single root menu; History no longer duplicates Plan's Calendar route. |
| A way back | Every Plan section swapped in behind the section switcher carries a named top-left route back to the overview. History remains focused on searching and filtering transactions; Calendar has one canonical home under Plan. |
| Premium visual hierarchy | Routine explanation is one glyph away instead of permanent screen furniture. Today now adds exact cash-versus-debt and budget-progress orbit graphics, plus a six-month net cash-flow preview that opens the existing selectable Insights charts. The read-only budget simulator is a direct Plan destination instead of being buried inside Budget. All graphics retain adjacent textual values and non-color meaning. |
| Glance privacy | Exact amounts default to `*****` on upgrade and new installs. One eye control on Today, History, Log, Plan, Assets, Insights, and the simulator changes the device-wide UI preference; Settings exposes the same choice. Populated Log, transaction-edit, and simulator fields remask when focus leaves and reveal only when tapped for editing. Masking is synchronous so an old amount cannot cross-fade through the privacy state; interactive inputs, transaction rows, and charts announce a localized hidden state to VoiceOver. Currency labels remain visible. |
| Luxurious, accessible motion | Reusable spring disclosure, snappy selection, press-depth, symbol replacement, chart-selection, and simulator-update motion add tactility without animating financial digits. Reduce Motion makes every MoneyUp-owned selection, disclosure, press, confirmation, and state update immediate; native tab and sheet transitions stay native. |
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

- release-asset validation, including 1,360 bilingual strings across three catalogs;
- architecture and Swift structure fitness;
- offline/privacy/recovery mutation gates;
- 118 Python validator tests across the architecture, platform-action, and
  performance suites;
- 775 declared Swift tests: 724 XCTest and 51 Swift Testing declarations;
- clean patch whitespace validation.

Still required on the exact release-truth commit:

- macOS Xcode build and all Swift test targets in GitHub Actions;
- unsigned app/widget Simulator build;
- signed archive and TestFlight processing;
- physical iPhone keyboard, migration, restore, accessibility, performance,
  widget, lock-state, bilingual, and seven-day beta evidence.

Source implementation or declared tests must not be reported as physical or
signed evidence.
