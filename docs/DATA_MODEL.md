# Data Model and Invariants

## Automatic budgets and schema 10

`BudgetNode.allocationMode` distinguishes fixed envelopes from general allocations
added to children. Legacy payloads decode as fixed envelopes; uncapped groups migrate
only in the current revision. `monthlyAllocations` contains validated month/currency
overrides. Ancestor totals are derived, never stored as extra allocations.

Schema 10 rejects older readers that would apply the former cap-only interpretation.
The generic encrypted table layout is unchanged. Earlier schemas and recorded history
remain supported by the new reader. Encrypted profile display preferences do not
alter the ledger or budget calculations. See `BUDGET_REDESIGN_2026-09-05.md`.

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

`AllowancePlan` is policy over a benefit limit, restricted prepaid asset, or
reimbursement claim; it never manufactures a balance. It has an exact-currency
amount, daily/weekday/weekly/monthly cadence, reporting time zone, optional end
date, eligible expense categories, no/full/capped rollover, and bounded usage,
policy-revision, and reconciliation evidence. `AllowancePolicyRevision` is
effective-dated so later edits cannot reinterpret an earlier usage.

Archive/unarchive is also an immutable effective-dated timeline with an active
baseline. Archive is a pause, not deletion or proration. Historical summaries
use the state at the requested instant; wholly archived cadence periods add no
entitlement or expiry expectation, while a period active for any instant keeps
one unprorated entitlement. The current lifecycle Boolean is a presentation and
write guard derived consistently with the last transition, not authority to
rewrite the past.

Current-format plans persist `archiveTimelineVersion`, `archiveTransitions`,
and `isArchived` as one per-plan integrity unit. If either new field is present,
missing/null/unsupported markers, missing/null timelines, an empty timeline
paired with an archived current state, unordered or nonalternating transitions,
and a final state inconsistent with `isArchived` fail closed. Schema-9
compatibility still accepts a fully legacy
shape containing neither new field. An archived legacy record with no evidence
infers its transition at plan start; otherwise the transition is the earliest
finite instant strictly after its latest usage and no earlier than its latest
reconciliation period end. Consequently, a deliberately forged payload that
removes both new fields is indistinguishable from genuine legacy data under
schema-9 backward compatibility; SQLCipher and authenticated portable archives
remain the provenance boundary rather than an unsupported claim of semantic
history authentication. These are additive Codable payload fields and require
no SQLCipher schema bump.

`benefitLimit` is entitlement only and has no ledger account. `prepaidAsset`
must reference an active same-currency `restrictedAllowance` asset and uses that
account as the real payment source; any uncovered expense remains on the
explicitly selected source. One active prepaid plan owns one restricted account;
new/edit pickers exclude an account owned by another active plan while retaining
the edited plan's own valid link. Availability is evaluated from the encrypted
posting index at the expense instant: later top-ups cannot fund earlier use,
and the account's running balance may never be negative. Quick Log's asynchronous
historical preview is bound to the exact plan, source account, occurrence
instant, journal-projection revision, and logical-book revision. It publishes
only the matching result and fails closed while loading or after any of those
facts changes; it never substitutes the current display balance. Events with
the same timestamp form one atomic batch because journal entries have no durable
order within that instant. Completed non-rollover periods use an idempotent
`AllowanceReconciliation` plus balanced non-income/non-expense adjustment to
remove only truly expired stored value. `reimbursement` starts as
expense-backed pending-claim evidence with an explicit
`AllowanceClaimStatus`. The only forward transitions are pending to approved or
rejected, then approved to reimbursed; rejected and reimbursed are terminal.
Every transition is an optimistic, durable evidence update and never creates or
changes a journal entry, cash account, restricted account, income, or receivable.
An actual incoming reimbursement is recorded separately through the normal
ledger workflow.

The allowance editor treats user-picked dates as policy-zone civil dates: a
start is stored at that day's start and a visible inclusive final day is stored
as the next civil-day boundary, preserving the domain's half-open interval
across DST. Existing legacy partial-day bounds retain their exact instants
rather than being silently rounded. A name-only edit preserves the plan zone;
a zone/rule edit becomes an effective future policy revision. The active and
pending governing zones are visible, and usage/reconciliation dates are
formatted through their recorded policy revision's zone. A usage editor resolves
the policy at the chosen occurrence instant, offers General only for an
unrestricted category policy, and clears or normalizes a category that becomes
invalid when the date crosses a revision boundary.

Quick Log writes the eligible expense, funding split, and linked usage
atomically. Replacing or deleting the expense recomputes, relinks, or removes
that evidence in the same SQLCipher transaction. An eligible reimbursement
expense edit preserves its advanced status, deletion removes its claim evidence,
and an edit that removes eligibility requires explicit confirmation before the
evidence is discarded.
An unlinked, current, non-grandfathered benefit-only usage can itself be edited
by exact expected evidence without changing its stable usage ID. Delete returns
that exact evidence; the Undo request synchronously captures the usage, plan,
and policy revision and atomically re-adds it only if the current plan is
writable and the unlinked/unclaimed/category/date/revision/capacity invariants
still hold. Linked, prepaid, reimbursement, archived, and grandfathered
evidence stays on its authoritative workflow and fails closed. Cross-record validation is
bidirectional: every live negative posting from a `restrictedAllowance` account
must be authorized by exactly one valid prepaid usage or expiry reconciliation,
and every claim must match the entry's immutable kind, date, currency, category,
amount, restricted account, and—where applicable—source, fingerprint, origin,
and balanced adjustment postings. Positive restricted-account funding needs no
allowance claim. A source label alone is descriptive metadata, not authority.

Normal recovery reads the complete normalized posting history only for live
restricted accounts, fetches the full entries needed for negative postings and
linked evidence, and repeats the mutually dependent account/plan/journal checks
until their removal and quarantine sets reach a monotonic fixed point. An
invalid prepaid plan also quarantines its restricted-debit/expiry evidence in
memory; an ordinary benefit-limit or reimbursement expense remains in the book
when only its allowance metadata is invalid. Malformed accounts, historically
negative balances, unauthorized or multiply claimed restricted debits, and
invalid evidence never participate in live calculations, but their encrypted
rows are retained for backup and diagnosis. Strict restore rejects the same
conditions rather than importing a partially trusted graph. Restricted value
is excluded from unrestricted cash and Flexible today.

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

Deterministic encrypted payloads remain the recovery source of truth. Schema 9
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

## Quick-log draft and evidence attachments

One optional in-progress Log draft is stored separately in SQLCipher. It
contains editable form values and stable selections, not receipt bytes. A
successful save atomically writes the entry, any explicitly retained encrypted
images or PDFs, and draft deletion. The cleared form can retain only a new
encrypted preference snapshot without reviving the old amount.

Evidence attachments are optional entry-keyed records: up to five, 15 MB each
and 30 MB total. Retained images are decoded with orientation, bounded to 4,096
pixels, and re-encoded as new JPEG/PNG pixels without source metadata. GPS,
EXIF, TIFF device identifiers, captions, and edit history therefore do not
cross the persistence boundary. PDFs retain their original bytes. Vision OCR,
embedded PDF text extraction, and visual classification run on device; bounded
names, extracted text, and labels are indexed only inside SQLCipher and cannot
change ledger facts. Entry replacement relinks attachments atomically;
confirmed attachment or entry deletion removes them. Password-protected
portable backup preserves the encrypted records. CSV/XLSX, drafts, widgets,
logs, and diagnostics never receive attachment bytes or search text.

## Dated exchange rates

A user-supplied rate stores an ordered currency pair, a positive exact Decimal
quote-per-base value, and an effective origin day. Historical lookup selects
the latest direct or inverse rate no later than the relevant day. Converted
results remain visibly dated estimates and unconverted mode remains available.
No applicable rate produces an explicit unavailable/unconverted result, never
an invented value.

## Market-data foundation

The 0.7.1 approved rework adds Core-only value types and protocols; it does not
add a stored collection or SQLCipher migration. `InstrumentIdentity` preserves
symbol, venue, quote currency, resolution, and stable identity without guessing
an ambiguous listing. `MarketQuoteObservation` is immutable dated evidence with
an exact price, quote/received times, quote type, delay, quality, market-session
context, and provenance.

`MarketEstimatedNetWorthEngine` can replace a position's already-recorded value
exactly once inside a derived estimate or retain that recorded value and report
a stable gap. It does not mutate the journal, `InvestmentHolding.priceHistory`,
lots/disposals, balances, or frozen net-worth snapshots. Missing or stale
quotes and absent FX produce partial/unavailable evidence, never zero or an
invented converted total.

`MarketDataPolicy.manualLocalDefault` is the only active shipping policy. The
provider and observation-store protocols plus request planner are seams for a
future separately approved implementation; this release has no concrete
provider, endpoint, credential, network call, background task, or persisted
quote store.

Observation validation binds manual, migrated-manual, imported, and provider
source classes to their allowed quote type, delay, and quality. Price is
strictly positive except for an explicit user-entered or migrated-manual zero
write-down; provider zero is invalid and cannot represent unavailability.
Event identity includes source class plus any source-native record/sequence ID,
and corrections are deduplicated before current-policy filtering so a newer
ineligible correction cannot revive older evidence. A provider batch is
untrusted until its request ID/time and exact result set, supported instrument
kinds, requested quote currencies, and provider provenance all match.

## App Group artifacts and widget snapshot

The app and widget share one App Group with an exact three-artifact allowlist:

1. the non-financial app-language preference;
2. one schema-4 redacted widget-summary `Data` value; and
3. one bounded, data-free quick-action ingress file containing only schema and
   authority metadata, admission state, opaque handoff tokens, and one of the
   six closed action-enum values.

No other default key or file is an approved cross-process data channel.
Replacing the widget-summary value is its publication boundary, so a reader
cannot combine independently written fields from different generations. Budget
Status contains state, reporting-period token, expiry, and a bounded integer
percent used. Smart Overview adds an optional current review count, bounded
allowance and commitment state, a reporting-calendar-derived relative due-day
count, and one expiry. Nil review count means refresh incomplete; it is not the
same as zero. Positive values are bounded at their reviewed publication limits;
any negative percent, count, or relative-day field invalidates the whole atomic
generation instead of being clamped or salvaged.

Schemas 1–3 migrate once from their independent keys; an exact due date without
reporting-calendar identity is dropped rather than reinterpreted. An absent
schema-4 payload is the genuine opt-out/disabled state. A present corrupt,
oversized, contradictory, negative-field, or unsupported-future payload is
stale and opens the app for refresh: the read-only widget never writes it back,
while the app-side maintenance writer atomically replaces it with canonical
stale state. Expiry also becomes stale. Only a canonical disabled generation
shows Settings guidance. The payload contains no amount, payee, account name,
holding/symbol/quote, balance, transaction/book/ledger identifier, note,
attachment, or evidence text. Opt-out, profile removal, erase, and restore
boundaries scrub the summary and known legacy prototype keys. Locking may retain
already-published opt-in derivatives because they contain no financial record
fields.

When the ready scene activates, the app republishes an eligible current
generation and arms exactly one wait for the next boundary in the book's
reporting calendar. Crossing that civil-day boundary refreshes and rearms;
inactivity, lock, replacement, or logical-book revision cancels or invalidates
obsolete work. First-run/onboarding and opt-out remain disabled rather than
silently activating summaries. Home widgets use a reduced information density
at accessibility Dynamic Type sizes, while Lock Screen families keep their
native compact hierarchy.

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

Before candidate `AppModel` load, production restore streams raw stored rows in
stable key order from the isolated SQLCipher store, checks cooperative
cancellation, and carries only bounded validation state rather than materializing
a second whole-book snapshot. Per-record and aggregate ceilings cover record and
payload bytes, nested journal/lifecycle/investment/schedule/goal/loan work, and
allowance usages, reconciliations, archive transitions, and cadence-period walks.
Allowance ceilings include 4,096 usages, 4,096 reconciliations, and 512 archive
transitions per plan, plus 100,000 of each in aggregate; cadence validation
permits `10,000 + 2 × maxPolicyRevisions` period work per plan (11,024 at the
512-revision cap) and 100,000 period walks across the candidate. Weekday work is
counted exactly from weekdays in constant time rather than charging every
calendar day. Exceeding any ceiling rejects the candidate before domain decode/
relationship traversal or live-book replacement.

CSV/Qianji import is local and preview-first. Invalid rows are surfaced,
unknown CSV/TSV layouts can be mapped column by column, account/category
targets are reviewed, fingerprints detect repeats, and accepted rows commit as
one atomic batch. CSV/XLSX are readable portability formats, not full-fidelity
backups or live two-way databases.
