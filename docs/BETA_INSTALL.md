# Install and Use Founders Beta 0.7.1

MoneyUp is available to its approved founder and co-tester through private
TestFlight groups and can also be installed from source. New builds still pass
through the protected release workflow before they appear in TestFlight.

## iPhone-only TestFlight installation

Record the exact predecessor build already installed by the account holder. The
expected predecessor is 0.7.0 (1025.1) once App Store Connect processing and
Founders Internal availability are confirmed. Do not delete the existing app.
The 0.7.1 candidate appears in that same private group only after the protected
release workflow completes for its exact commit, Apple processes the upload,
and the account holder selects the build.
The second tester receives a private email invitation to the Founders External
group after TestFlight Beta App Review. Both testers install through Apple's
TestFlight app. MoneyUp has no account and the invitation does not require
ChatGPT or Gmail specifically.
TestFlight builds remain available for testing for up to 90 days; the app shows
the exact remaining time, and a newer build is required after expiry.

The complete account setup and cloud-signing sequence is in
[`APPLE_SETUP.md`](APPLE_SETUP.md). It can be completed from Safari on an
iPhone and does not require a personal Mac.

The steps below are for a developer source install and require access to a Mac.

## Requirements

- macOS with Xcode 16 or later
- XcodeGen (`brew install xcodegen`)
- an iPhone running iOS 18 or later
- a device passcode, with Face ID or Touch ID recommended
- an Apple ID signing team in Xcode
- internet access while Swift Package Manager first downloads pinned SQLCipher

A physical iPhone is recommended because the beta deliberately requires the
device's passcode-protected Keychain behavior.

## Generate and run

```bash
git clone https://github.com/LaiWenKang/MoneyUp.git
cd MoneyUp
xcodegen generate
open MoneyUp.xcodeproj
```

Then in Xcode:

1. Select the project, then the `MoneyUp` target, and choose your team under
   Signing & Capabilities.
2. Select `MoneyUpWidget` and choose the same team.
3. If Xcode reports that either bundle identifier is unavailable, change both
   `PRODUCT_BUNDLE_IDENTIFIER` values and use an App Group you own in both
   entitlement files. Register and enable that group for both replacement App
   IDs, run `xcodegen generate` again, and reopen the project.
4. Connect and trust your iPhone, select it as the run destination, and press
   Run.
5. A free personal team may require periodic reinstallation; a paid Apple
   Developer team uses its normal development-provisioning duration.

## First-run check

1. Authenticate or let MoneyUp create its protected first-install key.
2. Choose a base currency, name the first account, choose its type, and enter
   the current starting balance if desired.
3. Record a small expense from the center Log tab. With the amount keypad open,
   confirm Done and Save are reachable and use the keyboard's tab menu to leave
   Log without losing the draft. Confirm the saved expense updates the account
   balance and category spending.
4. Scan a clear sample receipt or screenshot. Reading progress should appear
   immediately and recognized amount, payee, and date suggestions should
   populate visibly while remaining editable.
5. Add a monthly limit in Plan and confirm child-category spending rolls up.
6. Enable rollover on a disposable budget, add a savings or sinking goal, and
   confirm a dated contribution, withdrawal, and reset retain their history.
7. Classify each limited allocation in Plan, open Flexible Today, inspect its
   arithmetic, and try the read-only budget what-if simulator. Tap an Insights
   bar and confirm the matching filtered History opens.
8. Send MoneyUp to the background. The switcher preview should hide data
   immediately; after the default one-minute delay, reopening should require
   device authentication. The delay is configurable in Settings.
9. Create a child and grandchild category, move the child safely, and confirm
   Log and History show the complete category path without duplicating budget
   attribution.
10. In History, verify Today opens by default, title and notes are visible, the
    per-currency spending/income/refund/net totals reconcile, and seven-day,
    month, all-time, filter, and Calendar routes remain available.
11. Enable daily and weekly guidance on disposable flexible budgets and verify
    the pace changes without changing the monthly limit or ledger.
12. Create benefit-limit, prepaid-asset, and reimbursement meal allowances plus
    a disposable loan plan. Confirm policy capacity never becomes income, cash,
    or an asset; prepaid value appears only from its exclusively owned funded
    restricted account. Move a reimbursement claim from pending to approved and
    reimbursed, and reject a separate pending claim. Counts and balances must not
    change: every status is evidence-only, terminal states do not reopen, and
    actual incoming reimbursement is logged separately. When prepaid policy
    capacity expires, confirm the ledger asset remains until an actual provider
    expiry is explicitly reconciled. A loan repayment must
    separate principal, interest, and fees in one balanced entry before the loan
    can finish at zero principal.

## Add the widget

Long-press the Home Screen or Lock Screen, add a widget, and search for MoneyUp.
The horned-money small and Lock Screen widgets can be configured for Expense,
Income, Transfer, Refund, Smart Entry, Receipt, Budget Status, or Smart Overview;
the medium widget shows illustrated quick actions or the selected passive
summary. The App Group allowlist is exactly the nonfinancial language
preference, one opt-in bounded atomic schema-4 summary `Data` value, and one
bounded data-free quick-action ingress JSON file; there is no fourth key or file.
The summary contains status, a bounded reporting-period token, rounded budget/
allowance percentages, review and expense-commitment counts, expiry, and
reporting-calendar-relative due-day distance. The ingress contains only schema/
authority and admission metadata, opaque tokens, and one of six closed action
values. Neither contains an exact due date, amount, payee, account name,
holding/symbol/quote, balance, transaction, note/evidence, book, or ledger
identifier. Expense, income,
transfer, and refund open the full Quick Log when the protected book is
available. While it remains locked, the separate encrypted Quick Capture inbox
accepts amount plus optional title and notes without exposing balances,
accounts, categories, history, or ledger identifiers; protected account and
category selection happens only after intentional unlock and review.

## Export to Numbers or Excel

Open Assets, choose **Export for Numbers or Excel**, review the plaintext
warning, and choose CSV or native XLSX through the system file picker. Numbers,
Excel, and most spreadsheet apps can open the result. Exported files are not
encrypted by MoneyUp after they leave the app.

## Backup, restore, and migration

The SQLCipher key is intentionally this-device-only. Removing the device
passcode or deleting MoneyUp can make the live local book unrecoverable. Before
either action—or changing devices—open Settings → Backup and recovery and save
a password-protected `.moneyup` archive outside the app. MoneyUp cannot recover
that password. If the device key is already missing, first ensure the device
has a passcode, then use the dedicated recovery screen with that archive;
wrong password, tamper, or cancellation leaves the old ciphertext untouched.
With no archive, erase is irreversible and the old book cannot be recovered.
CSV is not a full-fidelity backup, but Settings →
Import transactions can preview Qianji-style or generic CSV/TSV files, map an
unknown layout column by column, skip bad rows and repeat imports, and save
accepted rows together.

Updating TestFlight in place preserves data when the bundle identifier,
development team, and Keychain access remain unchanged. A future App Store build
must use the same `com.laiwenkang.MoneyUp` identity and the app/widget must keep
the reviewed `group.com.laiwenkang.MoneyUp` capability; run the upgrade drill
in `FIRST_TEST.md` before release.

The 0.7.1 source candidate is not a public release. Exact-head Mac CI must
remain green; signed validation, 0.7.1 TestFlight processing, physical
performance/accessibility, upgrade/restore, founder/co-tester seven-day use,
closed beta, and App Store gates remain open until evidence is recorded.
