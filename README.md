# MoneyUp

**Private money, clearly understood.**

MoneyUp is a local-first personal finance app for fast expense logging,
hierarchical budgeting, cash-flow planning, actionable insights, and asset
tracking. The product is being designed so that raw financial data remains on
the user's device unless the user explicitly exports or backs it up.

## Project status

MoneyUp is at **Foundation 0.1**. This repository currently contains:

- a testable Swift domain package for currencies, money, double-entry journal
  entries, hierarchical budgets, and deterministic CSV export;
- an iOS SwiftUI shell for Today, Plan, Calendar, Insights, Assets, and Quick
  Log;
- English and Simplified Chinese localization from the first screen;
- an explicit privacy threat model and architectural decisions;
- macOS CI for Swift tests and an unsigned iOS Simulator build.

Encrypted persistence, Face ID locking, widgets, and sync are planned next.
**Do not use the current build for real financial data yet.**

## Product principles

1. **Local first:** the core experience works without an account or network.
2. **Privacy is architectural:** no ads, financial-data analytics, or remote AI.
3. **Simple outside, rigorous inside:** consumer-friendly flows backed by a
   balanced ledger.
4. **Smart means useful:** deterministic, explainable insights before AI
   decoration.
5. **Portable by default:** users can export their records in documented,
   durable formats.
6. **Bilingual by design:** English and Simplified Chinese are developed and
   tested together.

## Repository layout

```text
App/MoneyUp/                 SwiftUI iOS application shell
Sources/MoneyUpCore/         Platform-independent finance domain
Tests/MoneyUpCoreTests/      Ledger, budget, money, and export tests
docs/                        Product, architecture, data, security, roadmap
project.yml                  Reproducible XcodeGen project definition
Package.swift                Swift package for the tested core
```

## Build and test

Core tests require a Swift 6-compatible toolchain:

```bash
swift test
```

To generate and open the iOS project:

```bash
brew install xcodegen
xcodegen generate
open MoneyUp.xcodeproj
```

The generated Xcode project is intentionally not committed. CI regenerates it
from `project.yml` and builds against a generic iOS Simulator destination with
code signing disabled.

## Security

The intended guarantee is narrower and more honest than "unbreakable":

> MoneyUp does not receive raw financial records. Data leaves the device only
> through an explicit user action, and optional remote backups are encrypted
> before upload with a key MoneyUp does not possess.

See [SECURITY.md](SECURITY.md) for current implementation status, threat model,
non-goals, and vulnerability reporting.

## Documentation

- [Product definition](docs/PRODUCT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Data model and invariants](docs/DATA_MODEL.md)
- [Delivery roadmap](docs/ROADMAP.md)

## License

MoneyUp is available under the [MIT License](LICENSE).
