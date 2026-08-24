# MoneyUp Founders Test Runbook

Version target: 0.3.0 (build 3)

This runbook is for the user and his girlfriend, MoneyUp's first two iPhone
testers. Use small sample values during the first session. The beta is not yet
the right place for records that cannot be reconstructed.

## How installation will work

The account holder installs from the private **Founders Internal** TestFlight
group after the first build is uploaded. The girlfriend is invited by email to
the private **Founders External** group after Apple's first TestFlight Beta App
Review accepts the build.

On each iPhone:

1. Install Apple's **TestFlight** app from the App Store.
2. Open the Apple invitation and accept it with the intended Apple Account.
3. Install MoneyUp in TestFlight.
4. Open MoneyUp. First setup requires a device passcode; later unlocks use the
   device passcode, Face ID, or Touch ID.

MoneyUp itself has no login. The invitation must open TestFlight, not ask for a
ChatGPT account. Gmail is only one possible email inbox; it is not required.

## Before starting

- Use an iPhone running iOS 18 or later with a device passcode enabled.
- Confirm TestFlight shows version 0.3.0 and build 3 or newer.
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

- Record a sample expense from Quick Log.
- Record a sample income.
- Add a second account and make a same-currency transfer.
- If relevant, add a different-currency account and record a transfer with the
  amount received.
- Verify account balances after every action.
- Record `lunch 12.50 cash yesterday` or the equivalent Chinese phrase with
  smart entry, then correct every field before saving.
- Select a sample receipt or screenshot. Confirm recognized values are
  editable and that the image does not appear anywhere in MoneyUp afterward.

### 3. Budgets and insights

- Add a parent and child expense category.
- Set monthly limits at both levels.
- Log spending to the child and confirm it rolls up to the parent exactly once.
- Check Today, Plan, Calendar, and Insights for the same amount and currency.
- Change the Insights period and verify that earlier sample entries appear only
  when their dates belong to the selected period.

### 4. Calendar and schedules

- Add a weekly or monthly scheduled expense.
- Move the calendar to its next date and confirm the projection appears without
  changing the actual balance.
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

- In Calendar, swipe a sample transaction.
- Cancel the first deletion and confirm nothing changes.
- Delete it on the second attempt and verify its effects disappear from the
  balance, budget, calendar, and report.
- Export CSV from Assets, accept the plaintext warning, save to a temporary
  location, and open it in Numbers or Excel.
- Verify dates, exact decimal amounts, currencies, account names, and IDs.
- Delete the exported sample file when finished if it contains private data.

### 7. Widget

- Add the small or medium MoneyUp widget to the Home Screen.
- Confirm it shows no balances, payees, or statistics.
- Use both expense and income shortcuts. Each must open the locked MoneyUp app,
  authenticate, and then show the correct entry type.

## Seven-day use test

For seven days, each tester should:

- record at least five sample or ordinary transactions per day;
- use Quick Log, smart text, and a receipt at least once each;
- review Today and Plan daily;
- compare one day's total with an independent note or calculator;
- background/unlock MoneyUp several times;
- update to the next TestFlight build when offered and confirm all prior data
  remains readable;
- export a CSV snapshot at the midpoint and end.

Do not delete the app as a test until authenticated backup/restore ships.
Reinstalling currently destroys access to the local encrypted book.

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
