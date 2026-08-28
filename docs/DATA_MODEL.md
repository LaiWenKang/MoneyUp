# Data Model and Invariants

## Ledger

MoneyUp uses double-entry accounting internally while hiding accounting jargon
from normal logging flows.

```text
JournalEntry
├── identity, kind, occurred time, created time
├── origin calendar, time zone, UTC offset, and stable local-day key
├── optional payee, note, source fingerprint, and revision lineage
└── Posting (two or more)
    ├── ledger account
    └── signed Decimal amount, currency, and optional split note
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
8. A split has at least two positive, same-currency category lines whose sum
   equals the transaction total exactly; saving never adjusts a remainder.
9. Day-level filters use the captured origin day. Legacy entries without
   context receive deterministic, visibly inferred attribution.
10. An edit writes a replacement plus encrypted prior revision; it never
    mutates a financial payload in place or reinterprets currency.

## Accounts, cards, and investments

- Asset accounts include cash, banks, e-wallets, and broker cash balances.
- Liability accounts include credit cards and loans. Product surfaces show
  Amount Owed while the ledger retains liability signs.
- Income and expense accounts power reports and categories.
- Trading accounts balance exchanges between currencies or assets.
- Hidden equity accounts balance opening values and reconciliation so those
  changes never masquerade as income or spending.
- Rename/archive/merge/delete-with-reassignment operations preserve historical
  explanations and update references atomically.
- Each connected holding owns a hidden position asset account. Purchases move
  cash into the position, sales move proceeds back, and repricing balances the
  valuation change against a hidden investment-result account. Net worth comes
  from the ledger exactly once.
- Holdings retain dated manual price history, FIFO acquisition lots, disposal
  bookkeeping, and an explicit initial-cash interpretation. Legacy unconnected
  holdings remain visible until the user chooses how to connect them.
- Price age is inspectable and a price older than seven days is stale.
  Bookkeeping gain/loss is not tax or investment advice.
- Net-worth snapshots are append-only observations separated by currency.
  Later prices do not rewrite an earlier snapshot.

## Budget tree, rollover, and goals

Each budget node has an identifier, optional parent, name, optional limit,
purpose, rollover rule, and explicit rollover activation time.

```text
Needs (hard cap)
└── Food (allocation)
    ├── Groceries
    └── Dining
```

Direct spending at `Dining` rolls up to `Dining`, `Food`, and `Needs` exactly
once. Limits do not roll up or sum: a child limit is an allocation inside the
parent cap. Rollover applies at each half-open monthly boundary only after the
user enabled it; existing books decode with rollover disabled.

`SavingsGoal` represents a savings target or sinking fund with exact currency,
target date, dated contributions and withdrawals, reset rule, dated manual
resets, archive state, and reporting time zone. Resetting starts a new summary
window without deleting movement history. A withdrawal cannot exceed the
available goal balance.

The storage model supports arbitrary category depth. The UI recommends no more
than three visible levels and uses tags for orthogonal context.

## Time, recurrence, and reporting calendar

- Absolute instants remain authoritative for ordering.
- Day-level reporting retains origin calendar, time zone, UTC offset, and local
  day key so travel and daylight-saving changes cannot silently move activity.
- The profile owns a stable Gregorian reporting time zone used by Today,
  History, Calendar, reports, schedules, rollover, goals, rates, and date
  pickers.
- Every financial period is half-open: start inclusive, end exclusive.
- Weekly, monthly, and yearly recurrences stay anchored to the original day.
  If a month/year lacks it, MoneyUp uses the last valid day, then returns to the
  anchor when possible.
- A scheduled item is forecast only until it is matched or posted. Editing,
  pausing, ending, skipping, confirming, matching, and posting retain explicit
  state; posting links the entry and advances the occurrence once.

## SQLCipher records and normalized indexes

Deterministic encrypted payloads remain the recovery source of truth. Schema 4
includes the normalized ledger support tables and attachment metadata indexing:

| Structure | Contract |
|---|---|
| `journal_entry_index` | Chronological/date/source lookup without full payload decode |
| `journal_posting_index` | Posting events for account references, reports, Calendar, and lifecycle operations |
| `journal_balance` | Exact materialized amount per account and currency |
| `receipt_attachment_index` | Receipt-to-entry relationship and bounded metadata without loading attachment bytes |

Normal unlock loads non-journal records, compact exact balances/counts, and a
bounded recent page rather than the complete journal. History uses keyset
paging. Calendar/report ranges use posting events. Routine mutations update
indexes and balance deltas in the same transaction. Full rebuild is limited to
migration, restore, or repair.

Malformed or orphaned rows are quarantined from calculations but their raw
encrypted records remain in snapshots and archives. Schema-1/2 migration builds
the ledger indexes without changing valid legacy payloads, identifiers,
timestamps, or stored decimal precision; schema-4 migration builds the receipt
metadata index without rewriting valid attachment payloads.

## Quick-log draft and receipt attachment

One optional in-progress Log draft is stored separately in SQLCipher. It
contains editable form values and stable selections, not receipt bytes. A
successful save atomically writes the entry, any explicitly retained encrypted
receipt attachment, and draft deletion. The cleared form can retain only a new
encrypted preference snapshot without reviving the old amount.

Receipt attachments are optional entry-keyed records containing size-validated
image bytes with signature-derived MIME metadata. Entry replacement relinks
them atomically; confirmed
attachment or entry deletion removes them. Password-protected raw snapshot
backup preserves them. CSV/XLSX, drafts, widgets, logs, and diagnostics never
receive the bytes.

## Dated exchange rates

A user-supplied rate stores an ordered currency pair, a positive exact Decimal
quote-per-base value, and an effective origin day. Historical lookup selects
the latest direct or inverse rate no later than the relevant day. Converted
results remain visibly dated estimates and unconverted mode remains available.
No applicable rate produces an explicit unavailable/unconverted result, never
an invented value.

## Widget snapshot

The app and widget share one App Group only for a versioned redacted snapshot:
disabled, needs-plan, unavailable, or available with an integer percent used.
The payload contains no amount, payee, account, holding, balance, transaction,
book, or ledger identifier. Opt-out, profile removal, and erase scrub the
snapshot and known legacy prototype keys. Locking may retain an already
published opt-in percentage because it contains no financial record fields.

## Export identity and portable recovery

Readable CSV and XLSX retain stable entry, posting, account, and hierarchy
identifiers; locale-independent exact decimals; timestamps; origin-day facts;
currencies; names; and account types. CSV begins with a UTF-8 BOM and
neutralizes spreadsheet-formula prefixes only in user text. XLSX stores user
text as inline strings and valid financial values as numeric cells.

An authenticated `.moneyup` archive wraps a raw logical database snapshot. Its
key derives from a user-held password independent of the live device key.
Restore validates collection identities and payloads, replaces records in one
transaction, reloads invariants, and restores the pre-operation snapshot on
failure.

CSV/Qianji import is local and preview-first. Invalid rows are surfaced,
unknown CSV/TSV layouts can be mapped column by column, account/category
targets are reviewed, fingerprints detect repeats, and accepted rows commit as
one atomic batch. CSV/XLSX are readable portability formats, not full-fidelity
backups or live two-way databases.
