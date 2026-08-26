# Install and Use Founders Beta 0.5.0

MoneyUp is available to approved founders through private TestFlight groups and
can also be installed from source. New builds still pass through the protected
release workflow before they appear in TestFlight.

## iPhone-only TestFlight installation

The account holder has already installed the initial signed beta from the
private Founders Internal TestFlight group. New candidates appear in that same
group after the protected release workflow completes.
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
3. If Xcode reports that either bundle identifier is unavailable, change
   `PRODUCT_BUNDLE_IDENTIFIER` for both targets in `project.yml`, run
   `xcodegen generate` again, and reopen the project.
4. Connect and trust your iPhone, select it as the run destination, and press
   Run.
5. A free personal team may require periodic reinstallation; a paid Apple
   Developer team uses its normal development-provisioning duration.

## First-run check

1. Authenticate or let MoneyUp create its protected first-install key.
2. Choose a base currency, name the first account, choose its type, and enter
   the current starting balance if desired.
3. Record a small expense from the center Log tab and confirm the account balance and
   category spending both update.
4. Add a monthly limit in Plan and confirm child-category spending rolls up.
5. Open Safe to Spend on Today, inspect its arithmetic, and try the read-only
   budget what-if simulator. Tap an Insights bar and confirm the matching
   filtered History opens.
6. Send MoneyUp to the background. The switcher preview should hide data
   immediately; after the default one-minute delay, reopening should require
   device authentication. The delay is configurable in Settings.

## Add the widget

Long-press the Home Screen or Lock Screen, add a widget, and search for MoneyUp.
The horned-money small and Lock Screen widgets can be configured for Expense,
Income, Transfer, Refund, Smart Entry, or Receipt; the medium widget shows four
illustrated quick actions. No widget displays balances, payees, holdings, or
statistics. Expense,
income, transfer, and refund can open the encrypted Quick Capture form while the
book remains locked; full balances and smart/receipt tools still require unlock.

## Export to Numbers or Excel

Open Assets, choose **Export for Numbers or Excel**, review the plaintext
warning, and save the CSV through the system file picker. Numbers, Excel, and
most spreadsheet apps can open the file. Exported files are not encrypted by
MoneyUp after they leave the app.

## Backup, restore, and migration

The SQLCipher key is intentionally this-device-only. Before deleting MoneyUp or
changing devices, open Settings → Backup and recovery and save a password-
protected `.moneyup` archive. MoneyUp cannot recover that password. Restore is
validated and transactional. CSV is not a full-fidelity backup, but Settings →
Import transactions can preview Qianji-style or generic CSV/TSV files, skip bad
rows and repeat imports, and save accepted rows together.

Updating TestFlight in place preserves data when the bundle identifier,
development team, and Keychain access remain unchanged. A future App Store build
must use the same `com.laiwenkang.MoneyUp` identity; run the upgrade drill in
`FIRST_TEST.md` before release.
