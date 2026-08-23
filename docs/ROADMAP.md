# Delivery Roadmap

Completed checkboxes describe Local Beta 0.1.0 behavior on `main`; unchecked
items are not promised by the current build.

## Foundation — finance and secure storage

- [x] Exact decimal money and normalized currencies
- [x] Balanced multi-currency journal entries and validated decoding
- [x] Arbitrary-depth budget roll-up
- [x] SQLCipher encrypted store with pinned dependency
- [x] Versioned schema and transactional writes
- [x] Random Keychain key with local user-presence control
- [x] Automatic background lock, decoded-state clearing, and privacy cover
- [x] Wrong-key, plaintext-leak, migration-compatibility, and rollback tests
- [x] Destructive failed-recovery path with explicit confirmation

## Daily use — Local Beta 0.1.0

- [x] Onboarding with base currency, first account, and opening balance
- [x] Expense, income, same-currency, and foreign-currency transfer logging
- [x] Multiple account types, cards, loans, and balance reconciliation
- [x] Default categories plus arbitrary-depth custom expense categories
- [x] Monthly limits with descendant spending roll-up
- [x] Recurring income and expense templates
- [x] Finance calendar with actual and projected money flow
- [x] Category-spending and six-month cash-flow charts
- [x] Manually valued holdings and base-currency net worth
- [x] Privacy-redacted WidgetKit quick-log shortcuts
- [x] Enriched, formula-safe CSV export through the system file picker
- [x] English and Simplified Chinese UI
- [x] CI for Swift tests and the app plus widget Simulator build

## Beta hardening

- [ ] Search, transaction editing, refunds, and split transactions in the UI
- [ ] Scheduled-versus-actual matching and recurrence editing
- [ ] Budget rollover, sinking funds, and savings goals
- [ ] Historical net-worth series and investment lots
- [ ] Accessibility and bilingual UI automation on physical form factors
- [ ] Performance tests for large ledgers and long recurrence histories

## Portability and distribution

- [ ] Versioned authenticated `.moneyup` backup archive
- [ ] Recovery-secret design, transactional restore, and restore drills
- [ ] Previewable CSV import with duplicate detection
- [ ] Native XLSX workbook export
- [ ] Signed TestFlight beta and App Store compliance work
- [ ] Evaluate optional end-to-end-encrypted multi-device sync

## Explicitly deferred

- Bank-credential aggregation or third-party account linking
- Remote generative-AI financial analysis
- Shared household books
- Automatic market prices that disclose a user's symbol list
- Two-way live spreadsheet editing
