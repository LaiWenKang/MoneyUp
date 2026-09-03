# Data Model and Invariants

## Ledger

MoneyUp uses double-entry accounting internally while hiding accounting jargon
from normal logging flows.

```text
JournalEntry
├── identity, kind, occurred time, created time
├── origin calendar, time zone, UTC offset, and stable local-day key
├── optional payee/title-or-merchant, note/description, source fingerprint,
│   and revision lineage
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
purpose, rollover rule, explicit rollover activation time, and a pacing cadence.

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

For a flexible node, daily or weekly pacing divides only the positive remaining
monthly amount across the remaining civil days. It rounds once to the node's
currency minor units and is guidance only: it never changes the monthly limit,
ledger, or rollover result. Existing nodes decode with monthly pacing.

## Loans and expiring allowances

`LoanPlan` attaches explanatory metadata and a home, vehicle, education,
medical, personal, business, installment, credit-line, or other purpose to
exactly one active loan liability account. The ledger account remains the sole
principal-balance authority.
Drawdowns and repayments create balanced journal entries; the plan retains only
bounded immutable activity links plus the separated principal, interest, fee,
date, and note needed to explain those entries. Interest and fees post to
explicit expense categories. A loan can be marked finished only when its ledger
principal is exactly zero. `includeInTotalDebt` affects the loan-center aggregate,
not accounting or net worth.

`AllowancePlan` represents an expiring benefit such as a company meal
allowance. It has an exact-currency amount, daily/weekday/weekly/monthly cadence,
reporting time zone, optional end date, eligible expense categories,
no/full/capped rollover, and bounded usage records. `benefitLimit` is
planning-only; `prepaidAsset` and `reimbursement` must reference an active
same-currency asset account whose ledger balance remains authoritative. The
allowance never becomes income or a second net-worth input. Quick Log can write
an eligible expense and linked usage atomically; replacing or deleting the
expense relinks or removes that evidence in the same SQLCipher transaction.

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

Deterministic encrypted payloads remain the recovery source of truth. Schema 8
includes normalized ledger, attachment, store-envelope, historical budget, and
derived intelligence projections:

| Structure | Contract |
|---|---|
| `journal_entry_index` | Chronological/date/source lookup plus a semantic budget-integrity fingerprint without full payload decode |
| `journal_posting_index` | Posting events for account references, reports, Calendar, and lifecycle operations |
| `journal_balance` | Exact materialized amount per account and currency |
| `receipt_attachment_index` | Receipt-to-entry relationship and bounded metadata without loading attachment bytes |
| `store_metrics` | Trigger-maintained exact record, payload, record-ID, and collection-byte totals |
| `budget_attribution_entry_index` | Stable historical budget day/timestamp plus a semantic integrity fingerprint per attributed entry |
| `budget_attribution_posting_index` | Original category/currency/amount postings used after audited lifecycle rewrites |
| `intelligence_control` | Whether derived intelligence tables are maintained; disabling does not remove journal data |
| `ledger_account_intelligence_index` | Minimal account classification required by pure intelligence queries |
| `journal_intelligence_source_index` | Normalized payee and kind metadata tied to the journal entry index |
| `payee_affinity_index` | Deterministic category occurrence/recency aggregates per normalized payee and currency |

Normal unlock loads compact non-journal state, exact balances/counts, indexed
budget-attribution health, and a bounded recent page rather than the complete
journal or healthy attribution history. History uses keyset paging.
Calendar/report/budget ranges use posting events. A normalized mismatch invokes
the exact attribution/audit validator. Routine mutations update indexes,
metrics, and balance deltas in the same transaction. Full rebuild is limited to
migration, restore, or repair.

### 0.7.1 schema-8 additive representation

Schema 8 adds `loanPlans` and `allowancePlans` to the existing generic encrypted
record table. The migration is compatibility-only because the table already
supports additive collections; it does not decode or rewrite journal payloads.
Restore shape/identity validation, cross-record quarantine, privacy-safe record
counts, and atomic replacement all recognize both collections. Invalid account,
category, currency, usage, or journal links fail closed or are quarantined.

### 0.7.0 W1 compatibility and W2 additive representation

The W1 Observation migration and service split changed only in-memory ownership
and left SQLCipher at schema 6. W2 adds schema 7 support tables and one profile
preference; it does not change accounting payload shape. Services receive
decoded state from the `AppModel` coordinator and do not own a store connection.

Save, edit, delete, split, import, reconciliation, schedule posting, lifecycle,
attachment-retention, and goal-movement paths still construct their complete
write/removal sets before making one store transaction call. Live service
state changes only after that call succeeds and the captured store generation
is still current. Cancellation, rollback, and quarantine therefore retain the
same durable boundary and ordering as before decomposition.

Settings continue to use the single primary `UserProfile` record. A FIFO
mutation lane re-reads the latest committed profile for each queued change; it
does not introduce an event log or new representation. A failed candidate is
discarded without publishing or rewriting unrelated committed fields.

W2 adds `UserProfile.intelligenceEnabled`; legacy profiles decode it as `true`.
Disabling persists the preference, clears schema-7 derived tables, and cancels
published findings in the same serialized operation. Re-enabling explicitly
rebuilds the derived facts. Journal payloads remain the source of truth and are
not deleted or rewritten by opt-out.

The schema-6-to-7 migration performs the approved one-time decode of payee,
entry kind, and account metadata that schema 6 did not contain. It runs inside
the migration transaction and preserves journal payload bytes, hashes,
identifiers, and timestamps. Routine intelligence lookup is index-only; rebuild
is limited to migration, restore, repair, or explicit re-enable.

The UI-language preference is non-financial App Group defaults state shared by
the app and widget. It does not alter stored title/merchant text, notes,
reporting time zones, currency, detector input, or serialized finding bytes.

Malformed or orphaned rows are quarantined from calculations but their raw
encrypted records remain in snapshots and archives. Schema-1/2 migration builds
the ledger indexes without changing valid legacy payloads, identifiers,
timestamps, or stored decimal precision; later migrations add receipt metadata,
store metrics, budget attribution, and intelligence indexes without rewriting
valid payloads.

## Quick-log draft and receipt attachment

One optional in-progress Log draft is stored separately in SQLCipher. It
contains editable form values and stable selections, not receipt bytes. A
successful save atomically writes the entry, any explicitly retained encrypted
receipt attachment, and draft deletion. The cleared form can retain only a new
encrypted preference snapshot without reviving the old amount.

Receipt attachments are optional entry-keyed records. The selected source is
transient for OCR; explicit retention decodes orientation, bounds the longest
edge to 4,096 pixels, and re-encodes new JPEG/PNG pixels without copying the
source metadata dictionary. GPS, EXIF, TIFF device identifiers, captions, and
edit history therefore do not cross the persistence boundary. Entry replacement
relinks attachments atomically; confirmed attachment or entry deletion removes
them. Password-protected portable backup preserves the sanitized bytes.
CSV/XLSX, drafts, widgets, logs, and diagnostics never receive them.

## Dated exchange rates

A user-supplied rate stores an ordered currency pair, a positive exact Decimal
quote-per-base value, and an effective origin day. Historical lookup selects
the latest direct or inverse rate no later than the relevant day. Converted
results remain visibly dated estimates and unconverted mode remains available.
No applicable rate produces an explicit unavailable/unconverted result, never
an invented value.

## Widget snapshot

The app and widget share one App Group only for a versioned redacted snapshot.
Budget status contains state, reporting-period token, expiry, and a bounded
integer percent used. Smart Overview adds bounded review/allowance/commitment
counts, an allowance-remaining percentage, daily expiry, and an optional next
commitment timestamp. The payload contains no amount, payee, account name,
holding, balance, transaction, book, or ledger identifier. Opt-out, profile
removal, erase, and unsupported future schemas scrub the snapshot and known
legacy prototype keys. Locking may retain already-published opt-in derivatives
because they contain no financial record fields.

## Export identity and portable recovery

Readable CSV and XLSX retain stable entry, posting, account, and hierarchy
identifiers; locale-independent exact decimals; timestamps; origin-day facts;
currencies; names; and account types. CSV begins with a UTF-8 BOM and
neutralizes spreadsheet-formula prefixes only in user text. XLSX stores user
text as inline strings and valid financial values as numeric cells.

An authenticated `.moneyup` archive wraps the complete logical database. Its
key derives from a user-held password independent of the live device key.
Version 2 is file-backed and chunk-authenticated: a SQL cursor feeds bounded
records into 1 MiB AES-GCM chunks, and restore authenticates each frame while
inserting it into one transaction. Header/chunk metadata detects truncation,
append, duplication, and reordering. Version 1 remains readable for backward
compatibility. Restore validates collection identities and domain relationships,
reloads invariants, and uses a separate file-backed rollback archive if a
post-commit load fails.

CSV/Qianji import is local and preview-first. Invalid rows are surfaced,
unknown CSV/TSV layouts can be mapped column by column, account/category
targets are reviewed, fingerprints detect repeats, and accepted rows commit as
one atomic batch. CSV/XLSX are readable portability formats, not full-fidelity
backups or live two-way databases.
