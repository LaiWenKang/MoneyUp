# Data Model and Invariants

## Ledger

MoneyUp uses double-entry accounting internally while hiding accounting jargon
from normal logging flows.

```text
JournalEntry
├── identity, kind, occurred time, created time
├── optional payee and note
└── Posting (two or more)
    ├── ledger account
    └── signed decimal amount plus currency
```

For an SGD 5 coffee paid from a bank account:

```text
Dining expense    +SGD 5
Bank asset        -SGD 5
                  ------
                     SGD 0
```

For a foreign-currency transfer, each currency balances independently through
trading/FX clearing postings. The user sees one transfer; the engine may create
four postings.

### Ledger invariants

1. A journal entry contains at least two postings.
2. Posting identifiers are unique within an entry.
3. Zero-value postings are rejected.
4. Signed postings sum to exactly zero independently for every currency.
5. Currency and asset codes are normalized and validated.
6. Monetary values use `Decimal`, never `Double`.
7. Invalid persisted entries cannot bypass validation during decoding.

## Accounts, cards, and investments

- Asset accounts include cash, banks, e-wallets, and broker cash balances.
- Liability accounts include credit cards and loans.
- Income and expense accounts power reports and categories.
- Trading accounts balance exchanges between currencies or assets.
- A payment card is metadata linked to its underlying account; it is not an
  independent asset unless it owns a distinct balance.
- Investment holdings have quantities, instruments, lots, and dated valuation
  snapshots. Market value changes do not silently rewrite historical spending.

## Budget tree

Each budget node has an identifier, optional parent, localized/user-facing name,
and optional limit in the plan's base currency.

```text
Needs (hard cap)
└── Food (allocation)
    ├── Groceries
    └── Dining
```

Direct spending at `Dining` rolls up to `Dining`, `Food`, and `Needs`. Limits do
not roll up or sum: a child limit is an allocation inside the parent cap. This
prevents the common error where nested budgets inflate the total plan.

The storage model supports arbitrary depth. The product UI should recommend no
more than three visible levels and use tags for orthogonal context.

## Time and recurrence

- Store timestamps as absolute instants and retain the user's relevant calendar
  context separately when day-level reporting depends on it.
- A recurring template predicts future money movement.
- Posting or matching an actual entry satisfies the occurrence rather than
  creating a second transaction.
- Editing a series and editing one occurrence are separate operations.

## Export identity

Readable exports retain stable entry, posting, and account identifiers so later
imports can detect duplicates. Decimal numbers use a locale-independent format;
display formatting is applied only by the UI or spreadsheet. User-controlled
text that begins like a spreadsheet formula is neutralized during CSV export to
avoid formula injection.
