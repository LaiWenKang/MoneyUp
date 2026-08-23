# Delivery Roadmap

The milestones are ordered by risk. Privacy, key recovery, ledger integrity,
and migration behavior are completed before broad feature work.

## Foundation 0.1 — repository baseline

- [x] Product principles and explicit threat model
- [x] Swift package with money and currency value types
- [x] Balanced multi-currency journal entries
- [x] Validated hierarchical budget roll-up
- [x] Deterministic posting-level CSV encoder
- [x] Bilingual SwiftUI navigation and quick-log shell
- [x] CI for core tests and unsigned iOS build

## Foundation 0.2 — secure local store

- [ ] SQLCipher integration behind a repository protocol
- [ ] Versioned schema and transactional migrations
- [ ] Key generation and Keychain lifecycle
- [ ] Face ID/passcode gate, inactivity lock, and privacy cover
- [ ] Destructive reset and failed-recovery behavior
- [ ] Tests proving the database is unreadable without the key

## Daily Loop 0.3 — real logging

- [ ] Onboarding with locale, base currency, and first account
- [ ] Expense, income, transfer, refund, and split transaction flows
- [ ] Account and category management
- [ ] Recurring transaction templates
- [ ] Recent-record search, edit history, and reconciliation
- [ ] CSV export through the system file picker

## Planning 0.4 — budgets and calendar

- [ ] Period plans and nested limits
- [ ] Rollover, sinking funds, and goals
- [ ] Scheduled-versus-actual matching
- [ ] Finance calendar with daily money flow
- [ ] Explainable safe-to-spend and spending-velocity forecast

## Understanding 0.5 — widgets, insights, and assets

- [ ] Privacy-redacted interactive widgets and App Intents
- [ ] Budget variance and category trend charts
- [ ] Cash-flow and net-worth history
- [ ] Cards as payment instruments linked to accounts
- [ ] Holdings, lots, and manual investment valuations
- [ ] Optional on-device merchant/category suggestions

## Portability 0.6 — backup and optional sync

- [ ] Versioned authenticated `.moneyup` archive
- [ ] Recovery-secret design and restore drills
- [ ] XLSX workbook export
- [ ] Validated, previewable imports with duplicate detection
- [ ] Evaluate optional end-to-end-encrypted device sync

## Explicitly deferred

- Bank credential aggregation or third-party account linking
- Remote generative-AI financial analysis
- Shared household books
- Automatic market prices that disclose a user's symbol list
- Two-way live spreadsheet editing
