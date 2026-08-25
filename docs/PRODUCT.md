# Product Definition

## North star

MoneyUp is a private, local-first personal finance system that makes detailed
logging easy enough to sustain and turns those records into clear budgeting
decisions.

The daily loop is:

1. Record an expense, income, or transfer in seconds.
2. See its effect on account balances and nested budgets immediately.
3. Understand the current liquid position, budget progress, and what is scheduled next.
4. Retain ownership through documented exports; add portable encrypted backup
   before public release.

## Target user

The first version serves one person managing multiple currencies, bank and cash
accounts, cards, brokerages, and manually valued investments. Household sharing
is excluded until a separate end-to-end encryption and authorization design is
approved.

## Core capabilities

| Capability | Founders Beta 0.4.0 behavior |
|---|---|
| Privacy and security | No account or backend; encrypted local database; local authentication |
| Budget planner | Monthly nested limits, roll-up, progress, and explicit unbudgeted spending |
| Widgets | Configurable, privacy-redacted Home and Lock Screen entry points |
| Hierarchy | Arbitrary-depth model with group/category/subcategory roll-up |
| Insights | Category distribution, monthly cash flow, and plain-language readings over a selectable period |
| Finance calendar | Actual transactions and recurring projected occurrences |
| Assets | Assets, liabilities, cards, loans, accounts, and manual holdings |
| Portability | Enriched posting-level CSV; encrypted archive remains planned |
| Easy logging | Leftmost Log tab, amount first, encrypted drafts, retained defaults, and Undo |
| Smart entry | On-device receipt and screenshot reading, typed-phrase parsing, and category suggestions learned from the user's own history |
| Languages | English and Simplified Chinese with locale-correct dates and amounts |

## Product rules

- "Smart" features must be deterministic or on-device, explainable, and
  optional. Raw transactions are never sent to a remote language model.
- Categories answer **why money moved**. Accounts answer **where money lives**.
  Tags capture context and must not replace either hierarchy.
- A credit card is a liability account. A debit card is a payment instrument
  linked to an asset account.
- Transfers, credit-card repayments, and investment funding are not expenses.
- A scheduled item remains a forecast until posted or matched to an actual
  transaction.
- The app database is the source of truth. Spreadsheets are exports or reviewed
  imports, not live writable replicas.

## Initial quality targets

- Median routine expense entry below eight seconds after onboarding.
- No financial-data network requests in strict local mode.
- Journal balance invariant holds for every committed entry and every currency.
- Budget parent totals exactly equal direct plus descendant spending.
- Export/import round trips retain identifiers, decimal values, currencies, and
  timestamps without drift.
- Core screens and workflows pass English and Simplified Chinese UI checks.
- Sensitive content is absent from logs, notifications, lock-screen widgets,
  and app-switcher snapshots by default.
