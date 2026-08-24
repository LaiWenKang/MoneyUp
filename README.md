# MoneyUp

**Private money, clearly understood.**

MoneyUp is a local-first iOS budget and personal-finance app. It combines fast
logging with a balanced ledger, multi-level budgets, a finance calendar,
on-device charts, accounts and holdings, and spreadsheet-friendly export.

## Project status

MoneyUp is at **Founders Beta 0.3.0**. The app is functional and can be installed
from source on an iOS 18 device through Xcode. It is not yet distributed as a
signed TestFlight or App Store build.

The beta includes:

- an encrypted SQLCipher database with a random 256-bit app-generated,
  device-bound key;
- Keychain protection requiring device-owner presence, automatic background
  locking, and an app-switcher privacy cover;
- onboarding with base currency, first account, and opening balance;
- persistent expense, income, same-currency, and foreign-currency transfers;
- account balance reconciliation that does not distort income or spending;
- arbitrary-depth categories and monthly limits with correct roll-up;
- actual and recurring projected money flow in the finance calendar;
- selectable report periods with category and monthly cash-flow charts, plus
  deterministic readings, all calculated on device;
- explicit reporting of money held or spent outside the base currency, which is
  listed on its own rather than converted or dropped;
- bank, cash, e-wallet, card, loan, brokerage, and investment accounts;
- manually priced investment holdings and base-currency net worth;
- smart entry that reads a receipt photo or screenshot with on-device text
  recognition, parses typed phrases such as "lunch 12.50 cash yesterday", and
  suggests a category from the user's own history, with no image retained and
  no remote model involved;
- a privacy-redacted Home Screen widget with expense and income shortcuts;
- posting-level CSV export with account metadata for Numbers and Excel;
- English and Simplified Chinese UI and first-run categories;
- a royal-blue app icon and accent colour with restrained gold highlights, a
  lock screen that names the biometry the device actually has, and an in-app
  version with release notes on update;
- an App Store privacy manifest, an in-app bilingual privacy and beta guide,
  backup exclusion for non-restorable ciphertext, and confirmations before
  permanent transaction, schedule, or holding deletion;
- Swift tests plus a clean unsigned iOS Simulator build in CI.

Portable encrypted backup/restore, imports, and signed public distribution are
not in this beta. Until backup/restore ships, do not make MoneyUp the only copy
of information you cannot afford to lose; export CSV snapshots regularly and
protect them because they are readable plaintext.

## Install the beta

### iPhone-only tester

Once the signed founders build is available, install Apple's TestFlight app,
open the private MoneyUp invitation, and tap Install. MoneyUp itself has no
login; the invitation uses an Apple Account through TestFlight and never needs
a ChatGPT account. See the [first-test runbook](docs/FIRST_TEST.md).

The Apple Developer membership is active, both bundle identifiers and the App
Store Connect record exist, and the protected GitHub environment has been
configured by the account holder. The first TestFlight build now waits for the
signed validation and upload workflows. The
[iPhone-only Apple setup guide](docs/APPLE_SETUP.md) gives the exact steps and
keeps every private key out of the repository and chat.

### Developer source install

You need a Mac with Xcode 16 or later, XcodeGen, and an iPhone running iOS 18 or
later with a device passcode enabled.

```bash
git clone https://github.com/LaiWenKang/MoneyUp.git
cd MoneyUp
brew install xcodegen
xcodegen generate
open MoneyUp.xcodeproj
```

In Xcode, choose a signing team for both `MoneyUp` and `MoneyUpWidget`, select
your iPhone, and press Run. If the bundle identifiers are unavailable, replace
both identifiers in `project.yml`, regenerate the project, and try again.

See [Beta installation and use](docs/BETA_INSTALL.md) for the complete setup,
first-run checklist, widget steps, and data-retention caveats.
The release gates and two-person TestFlight protocol are in the
[launch plan](docs/LAUNCH_PLAN.md) and [first-test runbook](docs/FIRST_TEST.md).
Signed archives use the protected, manual
[TestFlight workflow](.github/workflows/testflight.yml), which requires Xcode
26, the iOS 26 SDK, immutable dependencies, explicit confirmation, and
encrypted archive/dSYM retention before Apple receives an upload.

## Product principles

1. **Local first:** the core experience works without an account or network.
2. **Privacy is architectural:** no ads, financial telemetry, backend, or
   remote AI receives financial records.
3. **Simple outside, rigorous inside:** consumer-friendly flows commit balanced
   journal entries using exact decimal amounts.
4. **Smart means explainable:** insights are deterministic and calculated on
   device.
5. **Portable by default:** readable exports retain stable identifiers and
   accounting detail.
6. **Bilingual by design:** English and Simplified Chinese ship together.

## Repository layout

```text
App/MoneyUp/                    SwiftUI iOS application
App/MoneyUpWidget/              Privacy-safe WidgetKit extension
Sources/MoneyUpCore/            Finance domain and export rules
Sources/MoneyUpPersistence/     SQLCipher encrypted record store
Tests/                          Domain and encrypted-store tests
docs/                           Product, architecture, data, and roadmap
project.yml                     Reproducible XcodeGen definition
Package.swift                   Swift package and pinned dependency
```

## Build and test

```bash
swift test -Xswiftc -warnings-as-errors
xcodegen generate
xcodebuild \
  -project MoneyUp.xcodeproj \
  -scheme MoneyUp \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The generated Xcode project is intentionally ignored. CI repeats both commands
on every change to `main` and on pull requests.

## Security

MoneyUp does not operate a service that receives raw financial data. Data
leaves the app only through an explicit export action. This guarantee cannot
protect a compromised operating system, an already-unlocked screen, user-made
screenshots, or plaintext files after the user exports them.

See [SECURITY.md](SECURITY.md) for implemented controls, limits, recovery
behavior, and vulnerability reporting.

## Documentation

- [Beta installation and use](docs/BETA_INSTALL.md)
- [Product definition](docs/PRODUCT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Data model and invariants](docs/DATA_MODEL.md)
- [Delivery roadmap](docs/ROADMAP.md)

## License

MoneyUp is available under the [MIT License](LICENSE). SQLCipher notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
