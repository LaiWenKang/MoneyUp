# MoneyUp 0.7.1 — Complete Feedback and Approved Rework

Source baseline: **Founders Beta 0.7.1, source build 11**. The 4 September
approved rework requires a new, unreused distribution build after final source
identity is reconciled; tested build `1037.1` is not the corrected candidate.

Decision `MU-CC-071-2026-09-04` and its exact acceptance are recorded in
[CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md](CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md)
and
[QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md](QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md).

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
| Useful History shortcuts | Today, 7 days, Month, and All remain readable time scopes. Up to five hot categories are still ranked from bounded recent activity by frequency, recency, and deterministic tie-break, but appear in one labelled menu with full path, active state, and Reset rather than a horizontally scrolling chip row. One split entry counts once per category; archived/system categories are excluded and the complete advanced filter sheet remains available. |
| Loans beyond cars | Loan plans now carry a purpose: home, vehicle, education, medical, personal, business, installment, credit line, or other. Purpose changes presentation only; principal and repayments remain ledger-authoritative. |
| Global tab navigation | The optional horizontal root-tab swipe and its Settings control are removed. The fixed five-tab bar is the only global tab-navigation control, so charts, filters, lists, and other horizontal content retain gesture ownership. When present in a legacy profile, the retired field must still decode as a Boolean and is normalized to `false`; the initializer ignores `true`, and the encoder omits the key. |
| Configurable expiring allowances | Benefit limits, prepaid restricted value, and reimbursement claims remain economically distinct. Each active prepaid plan exclusively owns one active same-currency **Restricted allowance** account, whose ledger remains authoritative and whose value never becomes unrestricted wealth. New and edited civil dates use the plan policy zone: the visible inclusive end is stored as the next civil-day boundary without fixed-duration DST arithmetic, while legacy partial-day boundaries remain exact; name-only edits preserve the plan zone. Category selection resolves the governing policy revision at the usage instant, and stale choices fail closed. Quick Log's prepaid preview reads indexed ledger history as of the exact expense instant and discards any in-flight result whose plan, account, timestamp, journal projection, or logical book has changed. Expense funding and usage are atomic, a later top-up cannot fund a backdated expense, and the historical restricted balance never goes negative. Eligible standalone benefit usage can be edited, deleted, and undone by stable identifier; linked, prepaid, reimbursement, archived, or grandfathered evidence cannot. Reimbursement claims move pending → approved/rejected and approved → reimbursed with optimistic expected-state checks; rejected and reimbursed are terminal. These records remain evidence-only at every status and never mutate the journal, an account, cash, income, or receivables; actual reimbursement is logged separately. Archive/unarchive is an effective-dated pause. Every restricted debit requires exactly one valid usage or expiry authorization. Bounded fixed-point recovery preserves encrypted raw evidence, while strict restore rejects the same invalid graph. |
| Daily/weekly budget flexibility | Plan lets the user view an exact flexible remainder as Today, This week, or Rest of month without mutating the underlying monthly limit. Each result uses the selected civil-day cadence and currency rounding. |
| Useful Flexible today | The budget-only metric is consistently named Flexible today. One reporting-calendar snapshot supplies its current-day, exact seven-day prefix, remaining-period amount, localized date, inclusive days through month end, conditional reporting-zone note, reserved commitments, and tap-through arithmetic. Minor-unit residuals reconcile on the final day; a true liquidity-aware Safe-to-Spend metric remains deferred. |
| Five-tab organization | The permanent tabs remain Today, History, Log, Plan, and Assets. Plan uses one navigation stack and an adaptive non-scrolling peer selector: selected section shows icon and name; unselected sections may show icons with accessibility labels/state and a large-text fallback. History keeps labels where user-defined category identity matters. |
| Currency clarity everywhere | Amounts add their ISO code automatically wherever two currencies the book actually holds would otherwise render with the same locale symbol; a single-currency book is unchanged. Settings adds a Currency section naming the base currency, offering Automatic, Currency symbol, or ISO code, sampling every currency held, and holding the saved-rate route. Every account picker that decides the currency of money being entered names that currency once the book holds more than one, and foreign balances and excluded foreign spending always carry their code. |
| Today reworked around pinned categories | Today leads with up to eight pinned budget categories, each showing what is left for the month plus that same remainder apportioned across the coming week and the current day in a quieter type size, all resolved from one reporting instant. An overspent category reports its overspend instead of a negative pace, and every pinned row names its purpose so an even split of a commitment is never read as discretionary money. Pins are chosen from the board or swiped in from the Plan budget list, and are stored with the encrypted profile. |
| Less repetition per tab | Today does not duplicate History, Assets, Log, Plan, or Settings ownership. Flexible today keeps its full hero only until categories are pinned, then collapses to one line that still opens its arithmetic. Plan has no redundant overview layer: its four peer sections are directly selectable, and History does not duplicate Plan's Calendar route. |
| A way back | Back appears only when a real previous destination exists: native Back for pushed detail/editor/drill-through, semantic Cancel/Close/Done for sheets, and one-time “Back to …” for a recorded cross-tab origin. Root tabs and Plan peer sections never show a fake Back; direct tab selection clears stale origins. |
| Premium visual hierarchy | Routine explanation is one glyph away instead of permanent screen furniture. Today now adds exact cash-versus-debt and budget-progress orbit graphics, plus a six-month net cash-flow preview that opens the existing selectable Insights charts. The read-only budget simulator is a direct Plan destination instead of being buried inside Budget. All graphics retain adjacent textual values and non-color meaning. |
| Glance privacy | Exact amounts default to `*****` on upgrade and new installs. One eye control on Today, History, Log, Plan, Assets, Insights, and the simulator changes the device-wide UI preference; Settings exposes the same choice. Populated Log, transaction-edit, and simulator fields remask when focus leaves and reveal only when tapped for editing. Masking is synchronous so an old amount cannot cross-fade through the privacy state; interactive inputs, transaction rows, and charts announce a localized hidden state to VoiceOver. Currency labels remain visible. |
| Stable amount entry | The Log amount input remains mounted while privacy masking changes, so typing `.`, `0`, or `0.` can no longer replace the focused field and collapse the keyboard. Save waits for any selected evidence to finish processing. |
| Encrypted evidence search | Log and transaction edit accept images and PDFs, capped at five files, 15 MB each and 30 MB total. Image metadata is stripped; OCR, embedded PDF text extraction, and image classification run on device. Only bounded results are indexed inside SQLCipher, and History names the attachment that matched without treating extracted text or labels as financial facts. |
| Luxurious, accessible motion | Reusable spring disclosure, snappy selection, press-depth, symbol replacement, chart-selection, and simulator-update motion add tactility without animating financial digits. Reduce Motion makes every MoneyUp-owned selection, disclosure, press, confirmation, and state update immediate; native tab and sheet transitions stay native. |
| Investment valuation foundation | Core gains provider-neutral instrument, market-venue, quote-observation, provider/store, request-policy, completeness/freshness, legacy-migration, and estimated-net-worth contracts. Manual/local is the only active policy in this release. A quote must be strictly positive except for an explicit manual/manual-legacy zero write-down; provider zero is invalid. Source kind/identifier, record/sequence identity, quote type, delay, quality, venue/currency, and timestamp are bound semantics. Source identity drives dedupe before policy eligibility, and provider responses must bind request identity/time, exact result set, supported source kind/provider identity, and each instrument's quote currency. No provider, network, credential, backend, symbol transmission, background job, persistence migration, or privacy-copy change ships. Quotes can explain a dated estimate but cannot mutate the journal, holding price history, lots/disposals, balances, or frozen snapshots. |
| Premium widget system | The configurable widget retains Smart Overview, Quick Actions, and Budget Status while moving to one atomic versioned snapshot, family-native Home/Lock layouts, reporting-calendar-relative dates, coherent unavailable/stale state, and bounded durable at-least-once action ingress with exact-token UI acknowledgement. Canonical, backup-excluded, first-unlock ingress reloads before an authority-CAS append; validated recovery preserves a concurrent valid/open FIFO and resets absent/corrupt/closed state. Token-bound locked capture makes post-commit replay idempotent. A pre-acknowledgement crash may replay navigation but cannot create a financial commit; OS retries remain distinct without an OS-stable invocation ID. No amount, payee, account name, holding/symbol/quote, balance, transaction, note/evidence, or domain identifier crosses the App Group. |

The widget App Group allowlist is exactly the nonfinancial language preference,
one atomic bounded schema-4 summary `Data` value, and one bounded data-free
quick-action ingress JSON file; there is no fourth app-owned key or file. An
absent summary is disabled/opted out. A present corrupt, future-schema,
oversized, contradictory, or negative-field value makes the whole generation
stale; positive overflow is bounded, the extension never repairs storage, and
the app writer canonicalizes stale state atomically. Accessibility Dynamic Type
reduces Home-widget density. Ready-scene activation and reporting-day boundary
work republish/rearm one eligible coherent generation, while inactive, locked,
replaced, or revised-book work cannot publish obsolete results.

## Accounting and privacy decisions

- Loan principal remains authoritative in the liability ledger account. Loan
  metadata never becomes a competing balance.
- Interest and fees are explicit expense postings. A repayment cannot silently
  overpay principal, and a loan cannot close above zero.
- Allowance metadata never creates money. Limit-only use remains policy-only;
  prepaid value requires an exclusively owned, already-funded same-currency
  restricted asset. Reimbursement status is optimistic, durable claim evidence
  only: pending may become approved or rejected, approved may become reimbursed,
  terminal states cannot reopen, and none of those transitions changes cash,
  income, receivables, an account, or the journal. The user logs actual incoming
  reimbursement separately. Linked spending, split funding, and usage evidence
  are atomic. Historical previews and category eligibility resolve the exact
  expense instant under its governing policy revision and zone. Archive is a
  dated pause rather than a retroactive rewrite. Expiry changes entitlement,
  never silently deletes an asset or posts fake income/expense. Each restricted
  debit has exactly one journal-backed allowance authorization; ordinary
  benefit/reimbursement expenses survive if only their allowance evidence is
  invalid.
- Market observations are estimates, not ledger facts. The shipping policy is
  manual/local and deny-by-default, with zero permitted only for an explicit
  manual/manual-legacy write-down. Provenance, dedupe identity, quote currency,
  and provider-response/request bindings are validated before eligibility;
  provider networking remains a future, separately approved
  licensing/privacy/security change.
- No remote model, analytics SDK, backend, currency conversion, or tracking was
  added. Smart defaults use only deterministic on-device data.
- Amounts remain exact `Decimal`; all journal entries balance independently by
  currency; currencies are never silently mixed or converted.

## Release evidence

Completed locally on the frozen approved-rework source:

- release-asset validation, including 1,498 bilingual strings across three catalogs;
- architecture and Swift structure fitness;
- offline/privacy/recovery mutation gates;
- 140 focused Python tests: 55 architecture, 6 launch-safety, 4 raw-restore, 58
  platform-action, and 17 performance-signpost cases;
- 1052 declared Swift tests: 999 XCTest and 53 Swift Testing declarations;
- clean patch whitespace validation.

These local results do not pass exact-head macOS execution, a signed binary,
physical migration/privacy/performance, TestFlight, or App Review. Those
evidence states remain open until repeated on the exact source and binary
identities.

Still required on the exact release-truth commit:

- macOS Xcode build and all Swift test targets in GitHub Actions;
- unsigned app/widget Simulator build;
- signed archive and TestFlight processing;
- physical iPhone keyboard, migration, restore, accessibility, performance,
  widget, lock-state, bilingual, and seven-day beta evidence, including
  production restore work limits and restricted-history fixed-point recovery.

Source implementation or declared tests must not be reported as physical or
signed evidence.
