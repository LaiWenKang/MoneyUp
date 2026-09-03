# MoneyUp Founder/Co-tester Runbook

Version target: 0.7.1, source build 11 (the GitHub workflow assigns a unique
TestFlight upload build)

This runbook is for MoneyUp's founder and co-tester on their two iPhones. Use
small sample values during the first session. The beta is not yet the right
place for records that cannot be reconstructed.

## How installation works

Record the exact predecessor currently installed from the private **Founders
Internal** TestFlight group. The expected predecessor is 0.7.0 (1025.1) once
App Store Connect processing and group availability are confirmed. If that
build is not available, record the actual installed version/build and keep the
0.7.0-to-0.7.1 upgrade cell open rather than inferring a pass. Install 0.7.1
over the recorded predecessor without deleting MoneyUp. The co-tester is
invited by email to the private **Founders External** group only after internal
acceptance and Apple's TestFlight Beta App Review accepts the selected build.

Before the account holder updates the installed beta, pin its existing
small and medium MoneyUp widgets. Confirm the small widget opens Expense and
the medium widget's Expense and Income links work, then leave both pinned for
the migration checks in section 7.

On each iPhone:

1. Install Apple's **TestFlight** app from the App Store.
2. Open the Apple invitation and accept it with the intended Apple Account.
3. Install or update MoneyUp in TestFlight.
4. Open MoneyUp. First setup requires a device passcode; later unlocks use the
   device passcode, Face ID, or Touch ID.

MoneyUp itself has no login. The invitation must open TestFlight, not ask for a
ChatGPT account. Gmail is only one possible email inbox; it is not required.
Each TestFlight build expires after 90 days, so install and complete this test
well before the expiry date shown in TestFlight.

## Before starting

- Use an iPhone running iOS 18 or later with a device passcode enabled.
- Confirm TestFlight shows version 0.7.1 and an upload build newer than the
  recorded predecessor build.
- Decide who tests English and who tests Simplified Chinese first; switch roles
  on a later day.
- Prepare fictional sample accounts, merchants, balances, and a receipt image.
- Do not paste real account numbers, card numbers, passwords, or recovery codes
  into notes.
- For the exact iOS 18 App Intent, App Shortcut, interactive widget, Control
  Center, Lock Screen, and Action button matrix, also complete the
  [privacy-safe platform actions runbook](PLATFORM_ACTIONS_RUNBOOK.md). Its
  exact-route, passive Budget status, metadata, App Group, and locked-capture
  checks are release gates rather than optional discovery testing.

## Founders smoke and acceptance test

### 1. First launch, guidance, appearance, and lock

Complete `LAUNCH-01-WATCHDOG` on the exact candidate before any App Review
resubmission. Use an iOS 26.6 iPhone if available and repeat the basic cold
launch on the oldest supported iPhone/iOS combination:

- Force-quit and cold-launch 20 times with airplane mode enabled. The launch UI
  must appear promptly, remain responsive, require no network, and never crash,
  hang, silently reset, or show an indefinite loading/buffering state.
- On an existing encrypted book, cold-launch and leave the Face ID/Touch ID or
  passcode prompt unanswered for at least 30 seconds. The process must remain
  alive; completing authentication must reveal the correct existing book.
- Repeat with biometric cancellation, retry, and passcode fallback. Each path
  must resolve to a usable locked/retry or ready state without duplicate
  prompts, blank content, data loss, or a watchdog termination.
- Background once while authentication is pending, then return and unlock.
  Private values must remain covered and the app must recover without a crash
  or stale loading state.
- Capture device/OS/build, cold-launch outcomes, one Instruments main-thread
  trace, and the privacy-safe performance signposts. Confirm there is no
  `0x8BADF00D` crash report and separately measure the Golden unlock-to-first-
  useful-content p95; authentication response time is recorded but excluded
  from that performance budget.

- Without outside instructions, follow the four setup steps. Confirm each page
  explains what the choice means and why it matters, shows progress, and offers
  an obvious Back or Continue action.
- Confirm the first-account page clearly says this is a financial account, not
  a MoneyUp login. Leave the name empty and enter an invalid amount once; the
  screen must explain the exact correction rather than only disabling a button.
- Complete onboarding with a base currency, account name, type, and small
  opening balance. For one run, enter a negative bank overdraft; for another,
  enter a positive card or loan amount owed. Confirm both display with the
  expected user-facing sign.
- On Today, confirm **Log money** and **Plan a budget** make the next actions
  obvious without referring back to this runbook.
- Check light and dark mode: the horned-money emblem, icon, and actions are soft
  green; primary canvases are off-white or deep charcoal rather than pure
  white/black; text and controls retain clear contrast.
- In Settings, leave Auto-lock at its default of one minute. Send MoneyUp to
  the background; its app-switcher preview must hide financial values
  immediately.
- Reopen it well before one minute has elapsed. The privacy cover should clear
  after MoneyUp becomes active without asking for authentication. Background it
  again, wait more than one minute, and reopen it. MoneyUp must now require
  device-owner authentication before showing the book.

Stop and report P0 immediately if the process is killed or becomes unusable
during launch/authentication, if another person can see data in the app
switcher, data appears after the configured timeout without authentication,
the app silently resets, or the opening balance is wrong.

### 2. Core logging

- Record a sample expense from the center Log tab.
- With the amount keypad visible, confirm the keyboard has an obvious Done
  control and the primary Save action remains reachable above it. Enter an
  unfinished amount, use the keyboard's Switch tab menu to visit another tab,
  and return to Log; the keyboard must close and the exact draft must remain.
  Use Done, then confirm every Log control and all five bottom tabs are
  reachable; no action should remain hidden behind the keyboard.
- Enter part of another transaction, background and unlock MoneyUp, and confirm
  the encrypted draft returns without being saved as a transaction.
- Tap Save twice rapidly and confirm exactly one transaction is recorded.
- Tap Save and immediately background MoneyUp. After unlocking, confirm there
  is exactly one saved transaction and no stale copy in the draft.
- Save a sample, use Undo from the six-second confirmation, and confirm the
  transaction and its effects disappear.
- Split a same-currency expense across at least three categories. Confirm the
  live remainder reaches exactly zero, Save is blocked otherwise, and editing
  the saved entry preserves each line and optional line note.
- Record a sample income.
- Add a second account and make a same-currency transfer.
- If relevant, add a different-currency account and record a transfer with the
  amount received.
- Verify account balances after every action.
- Record `lunch 12.50 cash yesterday` or the equivalent Chinese phrase with
  smart entry, then correct every field before saving.
- Confirm **On-device Smart Entry matching** is off on an upgraded and a clean
  profile. On an eligible iOS 26 device, enable it and enter ambiguous English
  and Chinese phrases. Every optional match must name only an existing account
  or category; **Reject on-device match** must dismiss/revert it in one tap;
  VoiceOver must announce **Use account suggestion: _name_** or **Use category
  suggestion: _name_** in the active language for both on-device and book-
  history suggestions. **Use** may change only that picker and must never save;
  background/reopen once to confirm the accepted choice is in the recoverable
  encrypted draft, then Reject and confirm the immediate prior choice returns.
  Disable Apple
  Intelligence, cancel generation, and repeat on an ineligible device: the
  exact-rule result must remain with no error or fabricated fallback. Capture
  network instrumentation proving zero requests and repeat with VoiceOver.
- Select a clear sample receipt or screenshot. Confirm a reading-progress state
  appears immediately, recognized amount/payee/date values populate without an
  extra tap, and every value remains editable. Repeat with an unreadable crop;
  MoneyUp must finish with a useful error instead of spinning indefinitely.
  Confirm neither image appears anywhere in MoneyUp afterward, and record the
  device model plus elapsed reading time if either scan feels slow.
- Repeat with **Keep this receipt** enabled on a fictional, deliberately
  GPS/camera-tagged JPEG. Confirm the retained image has the expected orientation
  and appears only after Save, survives a password-protected backup/restore, is
  absent from CSV/XLSX, can be deleted only after confirmation, and is removed
  when its transaction is deleted. Retain the fixture hash; the exact-candidate
  sanitizer test must independently prove that its GPS/EXIF/TIFF fields are gone.
- Leave an unfinished expense draft, then open the Income widget action.
  Confirm MoneyUp asks whether to resume or discard the encrypted draft and
  never silently changes its transaction type.

### 2A. 0.7.1 capture and History acceptance

- Open a fresh untouched Log sheet and confirm its date/time is the real current
  instant. Change it manually, leave and return, and confirm the explicit user
  value is never replaced by a later default refresh.
- Enter a known merchant with prior local history and confirm any suggested
  category is an editable active leaf supported by that history. Change the
  merchant/date and verify stale suggestions disappear; a user-selected or
  configured default must never be overwritten.
- With the keyboard visible, focus amount, account, title, multi-line notes,
  split amount, and split memo in turn. Every focused control and Save must
  remain reachable; interactive dismissal and Done must preserve the draft.
- Save distinct title, merchant, notes, and a nested category path. Confirm the
  History row exposes the meaningful title/merchant, notes, and complete path,
  and search can find the saved descriptive text.
- Confirm History opens on Today and its complete per-currency spending,
  refunds, income, and signed net reconcile independently. Repeat seven-day,
  month, and all-time scopes, use advanced filters, and open Calendar directly.

### 3. Budgets and insights

- Add a parent, child, and grandchild expense category. Reparent the child and
  confirm the complete paths update; reject a parent cycle or income/expense
  kind mismatch without changing the book.
- Set monthly limits at both levels.
- Log spending to the child and confirm it rolls up to the parent exactly once.
- Clear one limit to zero and confirm Plan remains readable without a broken or
  misleading progress bar.
- Set one flexible budget to Daily and another to Weekly pacing. Reconcile each
  currency-rounded guidance value from positive remaining monthly budget and
  remaining civil days; confirm pacing changes no monthly limit, rollover,
  journal entry, or historical report.
- Check Today, Plan (including Calendar), and Insights for the same amount and currency.
- If this book originally came from 0.5.0, confirm every still-unclassified
  limited allocation shows **Choose a purpose** and Today shows no optimistic
  daily amount. Classify one flexible allocation, one rent/bill allocation, one
  debt allocation, and one savings goal.
- On Today, open **Flexible Today**. Reconcile only flexible remaining budget
  minus active flexible scheduled occurrences, divided by days remaining
  including today. Confirm rent, loan/card repayment, and goals contribute zero;
  each flexible commitment is deducted once; foreign-currency activity,
  unbudgeted spending, future income, missing rates, and forecast assumptions
  are stated rather than silently folded into the amount.
- Confirm Cash on hand, Card and loan debt, and Net cash remain separate and
  match the underlying base-currency accounts.
- Open Plan → Budget what-if. Try additional spending and income, compare the
  exact projected totals with a calculator, then leave and confirm no ledger,
  budget, or report value changed.
- Change the Insights period and verify that earlier sample entries appear only
  when their dates belong to the selected period.
- Tap a category bar and a monthly-flow bar, inspect the selected value, then
  open transactions. Confirm History has the matching category/date filters and
  Back returns to the chart.
- Repeat both chart selections in grayscale and with the iOS blue/yellow color
  filter (a tritan proxy, not a clinical equivalence claim). Confirm every bar
  remains visible, the dashed selection rule remains distinct, and labels,
  shapes/position, exact amounts, and VoiceOver expose the same meaning without
  relying on hue.
- Isolate or delete earlier expense samples, then make total base-currency
  expenses 100 for last month's equivalent period and 120 for this month so
  far. Confirm the month-to-date sentence says up 20%. Replace this month's
  total with 80, then 100, to confirm down 20% and level.
- Add a foreign-currency expense to either comparison window and confirm the
  month-to-date comparison sentence is suppressed while that currency remains
  listed separately.
- Enable positive-only rollover on a disposable budget partway through a month.
  Verify nothing before the activation period is carried, then cross a month
  boundary and reconcile the effective limit exactly. Repeat with full signed
  rollover and confirm overspend carries only when that rule says it should.
- Create one savings goal and one sinking fund with target dates. Add dated
  contributions and a withdrawal, reject a withdrawal above the available
  balance, perform a reset, and confirm prior movements remain inspectable.
  Archive and restore one goal; delete only disposable sample data.

### 4. Calendar and schedules

- Add a weekly or monthly scheduled expense.
- Move the calendar to its next date and confirm the projection appears without
  changing the actual balance.
- Add a schedule dated on the 29th, 30th, or 31st and verify a short month uses
  its last valid day before returning to the original day when possible (for
  example, 31 January → 28 February → 31 March).
- Edit, pause, resume, skip, and end a disposable schedule. Confirm projections
  distinguish each state. Post one due occurrence and match another to a
  compatible actual transaction; each must link and advance exactly once even
  after repeated taps or reopening the app.
- Swipe a separate schedule, cancel deletion once, then delete it. Future
  projections should disappear; actual transactions should remain.

### 5. Assets and holdings

- Add a bank, card, or investment account.
- Confirm account creation uses **Current balance** for assets and **Amount
  owed** for cards/loans, with visible guidance before saving.
- Reconcile its displayed balance and confirm the adjustment is not counted as
  income or spending.
- Add a sample holding to a brokerage containing 10,000 cash. Buy 20 units at
  200 and explicitly choose **Record a purchase now**; cash should become
  6,000, position value 4,000, and net worth remain 10,000 rather than 14,000.
  In a disposable book, verify **Cash already excludes this position** leaves
  cash unchanged and records the missing opening value. MoneyUp must not choose
  between these interpretations silently.
- Reprice the holding and confirm **Price as of** is visible. Use a price more
  than seven days old and confirm it is marked stale wherever used.
- Buy two lots at different prices and sell through the first plus part of the
  second. Reconcile FIFO quantity/cost bookkeeping and confirm the UI says it
  is not tax advice. Reject a sale before acquisition, an out-of-order/future
  activity date, or more units than available.
- Confirm positions and net-worth history remain separated by currency. Add a
  dated user rate and inspect a visibly estimated conversion; remove the rate
  and confirm unconverted values remain available rather than becoming zero.
- Reduce a disposable holding to zero, then cancel and confirm deletion once.
  A non-zero holding must not be deletable.

### 5A. Loans and expiring allowances

- Create a disposable loan liability and attach one loan plan. Verify remaining
  principal, total advanced, principal paid, interest, fees, opening date, APR,
  term, debt-total inclusion, title, and notes without creating a second source
  of truth for the account balance.
- Record an additional drawdown and a repayment split into principal, interest,
  and fees. Reconcile the single balanced journal entry, reject a principal
  overpayment, and confirm the plan cannot finish until ledger principal is
  exactly zero.
- Create a weekday meal allowance with an end date and no rollover. Record
  category-linked and general use with notes; confirm unused daily value expires
  at the reporting-day boundary and never appears as cash, income, or net worth.
- Repeat with weekly/monthly cadence and capped/full rollover using disposable
  values. Reconcile eligibility, availability, usage history, cap behavior, and
  archive/restore across a reporting-period boundary.

### 6. Corrections and export

- Open History, search by payee, filter to its type, and edit the amount, date,
  category, and note. Confirm balances, budgets, Today, and reports update once.
- In Plan > Calendar, swipe a different sample transaction.
- Cancel the first deletion and confirm nothing changes.
- Delete it on the second attempt and verify its effects disappear from the
  balance, budget, calendar, and report.
- Export CSV from Assets, accept the plaintext warning, save to a temporary
  location, and open it in Numbers or Excel.
- Export native XLSX too. Verify dates, exact decimal amounts, currencies,
  account names, hierarchy IDs, entry/posting IDs, and split notes in both.
- Import an unknown CSV/TSV layout and map columns manually before preview.
  Verify account/category targets, duplicate handling, and atomic failure.
- Delete the exported sample file when finished if it contains private data.

### 7. Widget

- On the account holder's upgraded phone, confirm both previously pinned widgets still
  render, their legacy expense/income links open correctly, they can be resized
  and edited, and they survive a reboot. Then choose a 0.7.1 preferred action. If
  migration fails, remove and re-add the widget and report both build numbers.
- Add small and medium MoneyUp widgets to the Home Screen and one MoneyUp widget
  to the Lock Screen.
- Check inline, circular, and rectangular Lock Screen families where available,
  plus tinted Home Screen rendering.
- Confirm the horned-money mark, dimensional action buttons, and decorative
  background remain clear in light, dark, and tinted modes without resembling
  real financial data.
- With budget status disabled, confirm the widget asks to enable it and shows no
  invented percentage. Enable it and confirm only percentage/state appears -
  never amount, payee, account name, holding, balance, transaction, or ledger
  identifier. Disable it and erase a disposable book to confirm the snapshot is
  scrubbed. Repeat while the book is locked and in redacted mode.
- While the book is available, open Expense, Income, Transfer, and Refund from
  the widget and confirm each routes to the full Quick Log with editable
  account, category, title, notes, date/time, transfer, and split details.
- Terminate MoneyUp while its book is locked and repeat. The separate encrypted
  Quick Capture inbox must expose only amount plus optional title and notes,
  request no Face ID/Touch ID for capture, save in under eight seconds, show a
  confirmation rather than protected content, and display no balance, protected
  account/category choice, history, or ledger identifier. **Unlock and review
  now** must intentionally authenticate before protected assignment.
- Capture multiple items, intentionally unlock once, and confirm the review
  queue advances through every item exactly once. Smart Entry and Receipt must
  display an unlock cue and authenticate before opening.

### 8. Upgrade, backup, restore, and import

- Before updating from the recorded predecessor, save a password-protected
  `.moneyup` archive and record its exact version/build, transaction count,
  several balances, collection counts, settings, and widget configuration.
- Update in TestFlight without deleting the app. Confirm onboarding does not
  reappear and every prior balance, transaction, budget, schedule, and holding
  remains. Reconcile goals, rates, receipt attachments, investment lots,
  net-worth snapshots, settings, pending captures, widget configuration,
  category hierarchy, pacing choices, loans, allowances, and their activity too.
- In the upgraded build, open Settings → Backup and recovery → Data inventory.
  Generate and save the metadata-only JSON as the baseline for every later update
  and restore. It must contain no user-authored names, IDs, amounts, currencies,
  notes, balances, or receipt images.
- Create a password-protected `.moneyup` backup. Add one disposable transaction,
  choose the backup, and verify confirmation appears only after the password is
  accepted and validation completes. Reconcile the displayed archive/schema
  versions, every collection count, entry date span, currencies, quarantine
  count, and current-to-backup replacement summary before confirming. Confirm
  the disposable transaction disappears while the backed-up counts and balances
  return. Generate another Data inventory and compare its stored and nested
  counts with the saved baseline; the selected `.moneyup` file must be unchanged.
- Try the same archive with a wrong password and confirm the current book is
  unchanged. Store the real password separately; MoneyUp cannot recover it.
- Export a small fictional Qianji or generic CSV, preview it in Settings → Import
  transactions, review any rejected lines, and import. Import the same file
  again and confirm all previously accepted rows are reported as duplicates.
- Do not delete the app until this complete drill passes on the release candidate.

#### 8A. Recovery cancellation and interruption evidence — open until executed

These are required manual cases, not recorded passes. Use only a disposable QA
book with a separately verified backup; never create a power-loss condition
against the only copy of real data. Before each case, save a Data inventory JSON,
record its SHA-256 to bind that evidence file, and independently record the
visible account balances and entry count. After relaunch, save and hash a second
inventory and compare every semantic field; `generatedAt` is expected to differ.

| Case | Physical action on the exact candidate | Required result | Evidence to retain |
|---|---|---|---|
| `POR-05-TAMPER` | Duplicate a valid `.moneyup` file, flip one byte in the duplicate on a Mac, and try to restore only the modified copy. | Restore is rejected without exposing content; the live book and its inventory remain byte-for-byte/logically unchanged. The untouched archive still restores on the clean QA device. | Candidate version/build; original and modified archive SHA-256; before/after inventory files and hashes; redacted rejection screenshot. |
| `POR-05-CANCEL` | Separately cancel the backup destination picker, restore source picker, and every restore confirmation/password sheet that offers Cancel. | No success state is shown, no partial candidate replaces the live book, and every inventory field except `generatedAt` plus every balance matches. | Which sheet was cancelled; device/OS; before/after inventory files and hashes; semantic comparison; observed UI state. |
| `POR-05-INTERRUPT` | With the 10,000-entry fixture and large fictional receipt attachments, force-terminate MoneyUp once during backup generation and once during restore validation, before any success acknowledgement. Repeat during a large import. | Relaunch opens either the complete pre-operation book or the complete committed result—never a mixture. A partial backup is not presented as ready and is rejected if selected. Import has zero partial rows or duplicates. | Timestamped screen recording with private values covered; termination point; before/after counts, balances, inventory hashes, and output-file SHA-256. |
| `POR-05-POWER-LOSS` | On the disposable physical-device book, start the same receipt-heavy restore, then power the device off while processing and restart it. Repeat once during a transaction save or schedule post. | SQLCipher recovery yields exactly the old state or exactly the committed new state. There is no onboarding reset, key mismatch, orphan attachment, unbalanced entry, partial schedule advance, or duplicate. | Device/OS/battery/power state; approximate interruption point; before/after inventory hashes; balance and schedule reconciliation; redacted video. |
| `SEC-05-KEY-CLIFF` | On a disposable iPhone book only, first export and independently verify a `.moneyup` backup outside MoneyUp. Record its SHA-256 and baseline inventory, then remove the device passcode and reopen the exact candidate. Confirm the dedicated missing-key state, set a new device passcode without deleting MoneyUp, then separately try Cancel, a wrong password, and a tampered copy before restoring the untouched archive. Repeat once with force-termination after validation/installation begins. | MoneyUp explicitly says the device-bound key is missing and never shows onboarding or creates a key beside old ciphertext. Cancel/wrong password/tamper preserve the key-cliff state. The untouched external archive is unchanged. Valid restore yields exactly the archived inventory and balances; interrupted recovery resumes to that complete book or rolls back to the same key-cliff state, never a mixture. | Candidate/version/build/device/OS; backup SHA-256 before/after; baseline/restored inventory and hashes; exact result of every attempt; redacted screenshots/video. Mark this open until physically executed—source tests are not pass evidence. |
| `POR-04-NEAR-LIMIT` | With an instrumented disposable fixture, create and restore a multi-chunk v2 book near the enforced stored-payload ceiling; separately restore a valid near-limit compatible v1 archive. Record peak resident memory and repeat a wrong-password attempt for each. | V2 completes without whole-book memory growth and every inventory/hash reconciles. Wrong passwords leave the live book unchanged. V1 either completes within the oldest-device safety budget or blocks release; a crash/termination is not an acceptable pass. | Exact fixture generator/commit; v1/v2 file hashes and sizes; Instruments memory trace; before/after inventory hashes; device/OS; elapsed time. |

For each case, mark **pass**, **fail**, or **not reached**; never infer a pass
from an automated unit test or from the absence of a visible crash. Any mismatch,
unexpected onboarding, inaccessible key, partial state, or duplicate is P0 and
blocks wider TestFlight promotion. If timing cannot reach the intended phase,
record **not reached** and keep the case open rather than claiming coverage.

### 9. Scale, reporting day, and accessibility

Generate the reviewed fictional CSV from the exact release-candidate checkout:

```sh
python3 Scripts/generate_release_fixture.py \
  --entries 10000 \
  --output MoneyUp-Release-Fixture-10000.csv
```

Generate the separate detector-scale profile and its exact expected-result
manifest. This profile is a normalized QA dataset, not an importer file:

```sh
python3 Scripts/generate_release_fixture.py \
  --profile intelligence \
  --entries 10000 \
  --output MoneyUp-Intelligence-Fixture-10000.csv \
  --oracle MoneyUp-Intelligence-Oracle.json
```

- Confirm the generated oracle is byte-identical to
  `Tests/MoneyUpIntelligenceTests/Fixtures/MoneyUp-Intelligence-Oracle.json`.
  The Swift intelligence test consumes that committed manifest directly.
- Confirm the profile contains exactly three currencies (SGD, USD, and KWD),
  six expected findings spanning recurrence, lapse, price increase, duplicate,
  and anomaly rules, plus irregular cadence, different-account near-duplicate,
  and insufficient-history negative cases.
- Confirm the planted refund remains eligible only for applicable rules, while
  transfer and split shapes are excluded from single-category intelligence.
  None may create an extra finding beyond the oracle.

- Use a separate QA book, never a real financial book. In Settings → Import
  transactions, select the generated CSV, choose one test asset account and one
  test expense category as fallbacks, verify 10,000 accepted and zero rejected
  rows, then import. The fixture intentionally omits account, category, and
  currency so the reviewed fallbacks control every posting.
- Add exactly 20 long-lived schedules named `Fixture Schedule 01` through
  `Fixture Schedule 20` against the same test account/category. Keep them active
  and monthly, with distinct positive amounts and future next-occurrence dates.
- Generate and save a Data inventory. Confirm 10,000 transactions and 20
  schedules before collecting measurements; retain the JSON with the evidence.
- Review the exact candidate's retained automated
  [`MoneyUpPerformanceTests`](PERFORMANCE_BASELINE.md) artifacts for gross
  regression context. Simulator values are not substitutes for any measurement
  below and do not close a physical gate.
- Complete the [domain-payload-free performance signpost runbook](PERFORMANCE_SIGNPOSTS.md)
  for the exact Release candidate. Retain the Instruments trace and confirm the
  `Performance` category contains only the 18 reviewed names and only empty or
  fixed success/failure/cancelled outcome messages before using the trace as
  release evidence.
- On the oldest supported iPhone, record p95 unlock, tab-first-content, History
  search/filter after debounce, save, and Calendar-date computation against the
  Golden PRD budgets; inspect scrolling for sustained jank.
- Use a rollover-enabled fixture whose activation predates the current month.
  Measure the first unlock that creates the current-month opening-carry
  checkpoint and at least ten subsequent unlocks. Confirm the persisted timeline
  has one checkpoint for that month, subsequent results reconcile exactly, and a
  backdated edit recomputes the affected carry before reporting success.
- Verify History pages newest-first without gaps/duplicates and totals remain
  complete by currency. Edit and delete entries older than the recent-activity
  cache and confirm balances, budgets, reports, Calendar, and widget status
  update before success is shown.
- Test transactions created around midnight while traveling between UTC-12 and
  UTC+14 and across DST. Their reporting day must remain stable according to
  captured origin context and the configured reporting calendar.
- Complete every common flow in English and Simplified Chinese on the smallest
  supported and a current large iPhone, light/dark/tinted/redacted appearances,
  largest Dynamic Type, VoiceOver, Reduce Motion, Reduce Transparency, and
  Increase Contrast. Include grayscale and the blue/yellow color filter for
  Insights and every status-bearing surface.

## Seven-day use test

For seven days, each tester should:

- record at least five sample or ordinary transactions per day;
- use Quick Log, smart text, and a receipt at least once each;
- review Today and Plan daily;
- compare one day's total with an independent note or calculator;
- background/unlock MoneyUp several times;
- update to the next TestFlight build when offered and confirm all prior data
  remains readable;
- create an encrypted `.moneyup` backup at the midpoint and end, and keep CSV
  only when a readable snapshot is useful.

Deleting the app still destroys the device-bound live key. Reinstall only as a
separate restore drill after verifying the `.moneyup` archive and password.

## Feedback template

Send feedback through TestFlight with:

- severity: P0, P1, P2, or P3;
- MoneyUp version/build;
- iPhone model, iOS version, and app language;
- exact steps;
- expected result;
- actual result;
- whether it repeats;
- screenshot only after every private value is covered.

P0 means data loss, privacy exposure, unrecoverable launch failure, or wrong
ledger totals. Stop using the affected workflow until a fixed build is
available. P1 means a crash or blocked/wrong core workflow. P2 has a safe
workaround. P3 is polish or an enhancement.

## Pass criteria

The candidate passes only when exact-candidate Mac CI is green, both testers
finish the smoke test, the
seven-day period contains no P0, the final candidate has no reproducible crash
or open P1, and the exported sample ledger reconciles with balances, budgets,
calendar totals, goals, investments, widget status, and insights. This runbook
does not record a pass until the measured results and exact version/build are
attached to the candidate evidence.
