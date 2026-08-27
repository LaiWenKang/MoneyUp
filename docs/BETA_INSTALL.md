# Install and Use Founders Beta 0.6.0

MoneyUp is available to its approved founder and co-tester through private
TestFlight groups and can also be installed from source. New builds still pass
through the protected release workflow before they appear in TestFlight.

## iPhone-only TestFlight installation

The account holder has already installed version 0.5.1 from the private
Founders Internal TestFlight group. The 0.6.0 candidate appears in that same
group only after the protected release workflow completes for its exact commit,
Apple processes the upload, and the account holder selects the build.
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

## Add the widget

Long-press the Home Screen or Lock Screen, add a widget, and search for MoneyUp.
The horned-money small and Lock Screen widgets can be configured for Expense,
Income, Transfer, Refund, Smart Entry, Receipt, or the opt-in budget status;
the medium widget shows illustrated quick actions or status as configured. The
status contains only a percentage/state and no amount, payee, account, holding,
balance, transaction, or ledger identifier. Expense,
income, transfer, and refund can open the encrypted Quick Capture form while the
book remains locked; full balances and smart/receipt tools still require unlock.

## Export to Numbers or Excel

Open Assets, choose **Export for Numbers or Excel**, review the plaintext
warning, and choose CSV or native XLSX through the system file picker. Numbers,
Excel, and most spreadsheet apps can open the result. Exported files are not
encrypted by MoneyUp after they leave the app.

## Backup, restore, and migration

The SQLCipher key is intentionally this-device-only. Before deleting MoneyUp or
changing devices, open Settings → Backup and recovery and save a password-
protected `.moneyup` archive. MoneyUp cannot recover that password. Restore is
validated and transactional. CSV is not a full-fidelity backup, but Settings →
Import transactions can preview Qianji-style or generic CSV/TSV files, map an
unknown layout column by column, skip bad rows and repeat imports, and save
accepted rows together.

Updating TestFlight in place preserves data when the bundle identifier,
development team, and Keychain access remain unchanged. A future App Store build
must use the same `com.laiwenkang.MoneyUp` identity and the app/widget must keep
the reviewed `group.com.laiwenkang.MoneyUp` capability; run the upgrade drill
in `FIRST_TEST.md` before release.

The 0.6.0 source candidate is not a public release. Exact-candidate Mac CI,
physical performance/accessibility, upgrade/restore, founder/co-tester
seven-day use, closed beta, 0.6.0 TestFlight processing, and App Store gates
remain open until evidence is recorded.
