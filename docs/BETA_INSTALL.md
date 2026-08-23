# Install and Use Local Beta 0.1.0

MoneyUp is ready for local source installation. It is not yet a signed
TestFlight or App Store download.

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
3. Record a small expense with Quick Log and confirm the account balance and
   category spending both update.
4. Add a monthly limit in Plan and confirm child-category spending rolls up.
5. Send MoneyUp to the background and reopen it; the app should require device
   authentication before showing data again.

## Add the widget

Long-press the Home Screen, add a widget, search for MoneyUp, and choose the
small or medium Private Quick Log widget. The widget never displays balances,
payees, holdings, or statistics. Its shortcuts open MoneyUp, require the normal
device authentication, and present the expense or income form.

## Export to Numbers or Excel

Open Assets, choose **Export for Numbers or Excel**, review the plaintext
warning, and save the CSV through the system file picker. Numbers, Excel, and
most spreadsheet apps can open the file. Exported files are not encrypted by
MoneyUp after they leave the app.

## Important data-retention limit

The SQLCipher key is intentionally this-device-only. Deleting MoneyUp, using
the in-app destructive reset, or losing the protected key can permanently make
the local database unreadable. Local Beta 0.1.0 does not yet have portable
encrypted backup/restore, and CSV is not a complete restore format. Export
snapshots regularly and do not use this beta as the sole record of information
you cannot afford to lose.
