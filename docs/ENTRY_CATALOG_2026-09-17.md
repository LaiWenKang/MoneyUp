# Optional entry choices — 2026-09-17

The owner requested simpler grouped lists with direct toggles for financial accounts and spending categories. Existing users must only see new optional choices: upgrading must not create records, enable templates, change balances or rewrite their existing categories.

## Implemented behavior

- The account catalogue has 18 optional manual templates, including cash/bank, wallet balances, investments/retirement, and credit/loan accounts. The category catalogue has 35 optional expense templates. Both have search and localized labels.
- New templates start off because no associated ledger record exists. Explicit enable creates one zero-balance account or an expense category without assigning a budget limit. Preset provenance and picker visibility are stored with that ledger account and therefore travel inside encrypted backups.
- Existing records decode as visible with no preset provenance. Merely rendering the catalogue performs no writes. Existing same-name choices are retained in the existing-choice section instead of automatically reclassified.
- Disabling changes only `isHiddenFromEntry`; it does not archive/delete an account, alter journal postings, remove a category, change a budget, or stop schedules. Hidden financial accounts remain in balance/net-worth membership.
- A hidden parent hides its descendants from new choices. Existing drafts and historical edit selections retain their chosen IDs and required ancestry. Cycles are handled without recursion or unbounded traversal.
- New-entry pickers, defaults, parsing and preload inputs use the visible selection policy. Existing import/management and accounting data are retained. Unselected hidden accounts cannot reappear as preload cards.
- Credit cards and loans remain liabilities. Investments/retirement are excluded from unrestricted liquidity. Prepaid/restricted value opens its existing setup flow; it is not invented as unrestricted cash by a toggle.

## Export follow-up

CSV/XLSX serialization previously ran synchronously inside the main-actor model. It now uses an immutable input snapshot on a detached worker. The existing mutation guard keeps that snapshot coherent, and cancellation, book revision, lock/privacy-cover and publication checks withhold stale plaintext. The UI shows preparation status and prevents repeated export taps. Financial export formats are unchanged.

## Validation

Six domain tests cover legacy defaults, selection ancestry, deep/cyclic structures, metadata bounds, round trips and catalogue integrity. Model tests cover explicit/idempotent activation, currencies, correct liability classification, preservation of budgets/drafts/journal/net worth, storage failure, and hidden-account suggestion filtering. Bilingual/large-text rendering verifies that visiting the lists creates no records; all catalogue/group strings and symbols are checked. Five export tests cover background execution, byte-equivalent output, lock, cancellation, changed-book and failure recovery.

The PR's final full CI, iOS 26 review and signed delivery remain separate gates. No bank connection, live exchange-rate provider, XLSX import or automatic category migration was added. Transaction CSV/TSV import remains separate from encrypted whole-book restore.
