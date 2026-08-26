# MoneyUp

**Private money, clearly understood.**

MoneyUp is a local-first iOS budget and personal-finance app. It combines fast
logging with a balanced ledger, multi-level budgets, a finance calendar,
on-device charts, accounts and holdings, and spreadsheet-friendly export.

## Project status

MoneyUp is preparing the **Founders Beta 0.5.1** corrective candidate. Version
0.5.0 is installed by the account holder through private TestFlight;
developers can also install the app from source on an iOS 18 device through
Xcode.

The beta includes:

- an encrypted SQLCipher database with a random 256-bit app-generated,
  device-bound key;
- Keychain protection requiring device-owner presence, configurable timed
  auto-lock (one minute by default), and an immediate app-switcher privacy cover;
- a four-step first-run guide that explains the local-only model, base currency,
  first financial account, opening balance or amount owed, review, and what to
  do next;
- persistent expense, income, same-currency, and foreign-currency transfers;
- account balance reconciliation that does not distort income or spending;
- arbitrary-depth categories and monthly limits with correct roll-up;
- actual and recurring projected money flow in the finance calendar;
- selectable report periods with category and monthly cash-flow charts, plus
  deterministic readings, all calculated on device;
- Flexible Today with purpose-classified allocations, a tap-through arithmetic
  breakdown, flexible commitments, explicit exclusions, and separate
  cash-versus-debt positioning; bills, debt, and goals never become
  discretionary money;
- tappable category and monthly-flow charts that inspect exact values and open
  History with the matching category/date filters;
- a read-only budget what-if simulator for additional spending and income that
  never mutates the ledger, budget, or reports;
- explicit reporting of money held or spent outside the base currency, which is
  listed on its own rather than converted or dropped;
- bank, cash, e-wallet, card, loan, brokerage, and investment accounts;
- manually priced investment holdings and base-currency net worth;
- smart entry that reads a receipt photo or screenshot with on-device text
  recognition, parses typed phrases such as "lunch 12.50 cash yesterday", and
  suggests a category from the user's own history, with no image retained and
  no remote model involved;
- a permanent five-tab layout for Today, History, center Log, Plan, and Assets;
  Log retains encrypted draft recovery, configurable smart defaults, success
  feedback, and Undo;
- a searchable, filterable History tab with refunds and atomic transaction
  editing; prior versions are retained in the encrypted revision collection;
- configurable privacy-redacted Home and Lock Screen widgets for expense,
  income, transfer, refund, smart entry, and receipt scanning, plus a separate
  encrypted Quick Capture inbox that does not reveal balances while locked;
- password-protected `.moneyup` backup with authenticated, transactional restore;
- preview-first local import for Qianji-style and generic CSV/TSV exports, with
  name mapping, duplicate detection, row-level issues, and atomic saving;
- posting-level CSV export with account metadata for Numbers and Excel;
- English and Simplified Chinese UI and first-run categories;
- a distinctive soft-green horned-money emblem shared by the app icon,
  first-run surfaces, and privacy-safe widget; original dimensional
  illustrations for atmosphere; exact 2D position, pace, and scenario graphics;
  and semantic off-white or deep-charcoal surfaces with no pure-white or
  pure-black primary canvas; a lock screen that names the biometry the device
  actually has; and in-app release notes;
- an App Store privacy manifest, an in-app bilingual privacy and beta guide,
  backup exclusion for non-restorable ciphertext, and confirmations before
  permanent transaction, schedule, or holding deletion;
- Swift tests plus a clean unsigned iOS Simulator build in CI.

The 0.5.1 corrective candidate still requires green CI and physical
upgrade/restore, visual, localization, accessibility, and widget drills before
TestFlight distribution or a public release. Keep a separate encrypted backup;
CSV snapshots remain readable plaintext and should be protected.

## Install the beta

### iPhone-only tester

Install Apple's TestFlight app, open the private MoneyUp invitation, and tap
Install. MoneyUp itself has no
login; the invitation uses an Apple Account through TestFlight and never needs
a ChatGPT account. See the [first-test runbook](docs/FIRST_TEST.md).

The Apple Developer membership is active, both bundle identifiers and the App
Store Connect record exist, and the protected GitHub environment has been
configured by the account holder. New candidates go through signed validation
and the protected upload workflow. The
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
Unsigned release archives and Apple Distribution-signed IPAs use the protected, manual
[TestFlight workflow](.github/workflows/testflight.yml), which requires Xcode
26, the iOS 26 SDK, immutable dependencies, explicit confirmation, and
encrypted unsigned-archive/dSYM retention before Apple receives an upload.

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
- [Visual system](docs/VISUAL_SYSTEM.md)
- [Data model and invariants](docs/DATA_MODEL.md)
- [Delivery roadmap](docs/ROADMAP.md)

## License

MoneyUp is available under the [MIT License](LICENSE). SQLCipher notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
