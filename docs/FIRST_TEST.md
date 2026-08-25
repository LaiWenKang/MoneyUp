# MoneyUp Founders Test Runbook

Version target: 0.4.1 (source build 5; the GitHub workflow assigns a newer
unique TestFlight build)

This runbook is for the user and his girlfriend, MoneyUp's first two iPhone
testers. Use small sample values during the first session. The beta is not yet
the right place for records that cannot be reconstructed.

## How installation works

The account holder has already installed an earlier signed beta from the
private **Founders Internal** TestFlight group. Install the 0.4.1 candidate from
that same group when it appears. The girlfriend is invited by email to the
private **Founders External** group after Apple's TestFlight Beta App Review
accepts the selected build.

Before the account holder updates the installed 0.4.0 build, pin its existing
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
- Confirm TestFlight shows version 0.4.1 and build 5 or newer.
- Decide who tests English and who tests Simplified Chinese first; switch roles
  on a later day.
- Prepare fictional sample accounts, merchants, balances, and a receipt image.
- Do not paste real account numbers, card numbers, passwords, or recovery codes
  into notes.

## 45-minute smoke test

### 1. First launch and lock

- Complete onboarding with a base currency, account name, type, and small
  opening balance.
- Send MoneyUp to the background. Its app-switcher preview must hide financial
  values.
- Reopen it. MoneyUp must require device-owner authentication before showing
  the book.

Stop and report P0 immediately if another person can see data before unlock,
the app silently resets, or the opening balance is wrong.

### 2. Core logging

- Record a sample expense from the leftmost Log tab.
- Enter part of another transaction, background and unlock MoneyUp, and confirm
  the encrypted draft returns without being saved as a transaction.
- Tap Save twice rapidly and confirm exactly one transaction is recorded.
- Tap Save and immediately background MoneyUp. After unlocking, confirm there
  is exactly one saved transaction and no stale copy in the draft.
- Save a sample, use Undo from the six-second confirmation, and confirm the
  transaction and its effects disappear.
- Record a sample income.
- Add a second account and make a same-currency transfer.
- If relevant, add a different-currency account and record a transfer with the
  amount received.
- Verify account balances after every action.
- Record `lunch 12.50 cash yesterday` or the equivalent Chinese phrase with
  smart entry, then correct every field before saving.
- Select a sample receipt or screenshot. Confirm recognized values are
  editable and that the image does not appear anywhere in MoneyUp afterward.
- Leave an unfinished expense draft, then open the Income widget action.
  Confirm MoneyUp asks whether to resume or discard the encrypted draft and
  never silently changes its transaction type.

### 3. Budgets and insights

- Add a parent and child expense category.
- Set monthly limits at both levels.
- Log spending to the child and confirm it rolls up to the parent exactly once.
- Clear one limit to zero and confirm Plan remains readable without a broken or
  misleading progress bar.
- Check Today, Plan (including Calendar), and Insights for the same amount and currency.
- Change the Insights period and verify that earlier sample entries appear only
  when their dates belong to the selected period.
- Isolate or delete earlier expense samples, then make total base-currency
  expenses 100 for last month's equivalent period and 120 for this month so
  far. Confirm the month-to-date sentence says up 20%. Replace this month's
  total with 80, then 100, to confirm down 20% and level.
- Add a foreign-currency expense to either comparison window and confirm the
  month-to-date comparison sentence is suppressed while that currency remains
  listed separately.

### 4. Calendar and schedules

- Add a weekly or monthly scheduled expense.
- Move the calendar to its next date and confirm the projection appears without
  changing the actual balance.
- Add a schedule dated on the 29th, 30th, or 31st and verify a short month uses
  its last valid day before returning to the original day when possible (for
  example, 31 January → 28 February → 31 March).
- Swipe the schedule, cancel deletion once, then delete the sample. Future
  projections should disappear; actual transactions should remain.

### 5. Assets and holdings

- Add a bank, card, or investment account.
- Reconcile its displayed balance and confirm the adjustment is not counted as
  income or spending.
- Add a sample holding and verify quantity × price equals its displayed value.
- Swipe the holding, cancel once, then delete it. Account transactions must not
  change.

### 6. Corrections and export

- Open History, search by payee, filter to its type, and edit the amount, date,
  category, and note. Confirm balances, budgets, Today, and reports update once.
- In Plan > Calendar, swipe a different sample transaction.
- Cancel the first deletion and confirm nothing changes.
- Delete it on the second attempt and verify its effects disappear from the
  balance, budget, calendar, and report.
- Export CSV from Assets, accept the plaintext warning, save to a temporary
  location, and open it in Numbers or Excel.
- Verify dates, exact decimal amounts, currencies, account names, and IDs.
- Delete the exported sample file when finished if it contains private data.

### 7. Widget

- On the account holder's upgraded phone, confirm both pinned 0.4.0 widgets still
  render, their legacy expense/income links open correctly, they can be resized
  and edited, and they survive a reboot. Then choose a 0.4.1 preferred action. If
  migration fails, remove and re-add the widget and report both build numbers.
- Add small and medium MoneyUp widgets to the Home Screen and one MoneyUp widget
  to the Lock Screen.
- Check inline, circular, and rectangular Lock Screen families where available,
  plus tinted Home Screen rendering.
- Confirm it shows no balances, payees, or statistics.
- Configure and test Expense, Income, Transfer, Refund, Smart Entry, and Receipt.
  With locked capture enabled, the first four must permit amount/payee/note
  capture without showing balances; unlock and confirm each pending item moves
  into the full Log form for account/category review. Smart Entry and Receipt
  must still authenticate first.

### 8. Upgrade, backup, restore, and import

- Before updating, record the 0.4.0 transaction count and several balances.
- Update in TestFlight without deleting the app. Confirm onboarding does not
  reappear and every prior balance, transaction, budget, schedule, and holding
  remains.
- Create a password-protected `.moneyup` backup. Add one disposable transaction,
  restore the backup, and confirm the disposable transaction disappears while
  the backed-up counts and balances return.
- Try the same archive with a wrong password and confirm the current book is
  unchanged. Store the real password separately; MoneyUp cannot recover it.
- Export a small fictional Qianji or generic CSV, preview it in Settings → Import
  transactions, review any rejected lines, and import. Import the same file
  again and confirm all previously accepted rows are reported as duplicates.
- Do not delete the app until this complete drill passes on the release candidate.

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

The founders build passes only when both testers finish the smoke test, the
seven-day period contains no P0, the final candidate has no reproducible crash
or open P1, and the exported sample ledger reconciles with balances, budgets,
calendar totals, and insights.
