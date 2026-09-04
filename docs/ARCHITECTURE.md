# Architecture

## System shape

```mermaid
flowchart TD
    Widget["Redacted widget"] --> Capture["Encrypted Quick Capture inbox"]
    App["Authenticated SwiftUI app"] --> Core["MoneyUpCore"]
    App --> Intel["MoneyUpIntelligence"]
    App --> Store["MoneyUpPersistence"]
    Store --> Cipher["SQLCipher schema 9"]
    App --> Shared["Bounded status-only App Group"]
    Shared --> Widget
    App --> Files["CSV/XLSX/import/archive"]
```

The widget has two deliberately separate boundaries. Basic actions can route
to a device-only encrypted Quick Capture inbox without opening the book. The
opt-in Budget Status and Smart Overview surfaces read a tiny snapshot from
`group.com.laiwenkang.MoneyUp` containing only state, bounded percentages and
counts, expiry, and an optional next-commitment timestamp. The shared container
never receives amounts, payees, account names, holdings, balances, transaction
data, ledger identifiers, the SQLCipher database, or its Keychain key.

`MoneyUpCore` has no UI, database, or network dependency. It uses Foundation
for domain behavior and CryptoKit only to create local import fingerprints.
Financial invariants remain independently testable, and no runtime backend is
required.

## Module boundaries

| Module | Responsibility | Source state |
|---|---|---|
| MoneyUp app | Observation-tracked state coordinator, locking, bilingual SwiftUI, local guidance and workflows | Implemented — verification pending |
| MoneyUpCore | Exact money, ledger, hierarchy, recurrence, goals, investments, reports, export rules | Implemented in source; exact-candidate core tests open |
| MoneyUpIntelligence | Pure deterministic detectors, exact evidence contracts, projections, and budget proposals; depends only on MoneyUpCore | Implemented; W2 branch and merged-main CI passed; final-candidate repeat open |
| MoneyUpPersistence | SQLCipher schema/migrations, normalized encrypted indexes, atomic writes, snapshots | Implemented in source; Mac test gate open |
| Widget | Redacted actions plus opt-in percentage/state status | Implemented in source; App Group registration/signing and device matrix open |
| Portability | CSV/XLSX, mapped local import, sanitized encrypted attachments, file-backed archive lifecycle | Implemented in source; exact-candidate and physical restore/export drills open |

`BudgetTree`, `BudgetRollover`, `SavingsGoal`, and `FinancialGuidance` own the
exact plan arithmetic. `InvestmentHolding`, `TransactionFactory`, and
`NetWorthSnapshot` keep purchases, sales, repricing, FIFO metadata, and
currency-separated observations tied to the ledger. SwiftUI can render those
results, but dimensional artwork never carries a financial quantity.

## Observation and service ownership

`AppModel` is an `@MainActor @Observable` coordinator. SwiftUI receives it
through `@Environment(AppModel.self)`, so Observation tracks the properties a
view actually reads instead of broadcasting every mutation to every screen.
Async settings bindings remain explicit `Binding` closures: persistence must
complete through the serialized profile boundary before the observed profile
changes, so a direct `@Bindable` write would bypass that safety contract.

Mutable screen state is owned by injected, independently observable services:

| Service | Owned state |
|---|---|
| `LedgerService` | Accounts, journal count/currentness, and the bounded recent journal |
| `PlanningService` | Budget nodes, schedules, and savings goals |
| `AssetsService` | Holdings, dated rates, and net-worth snapshots |
| `PortabilityService` | Recovery and quarantine presentation state |
| `CaptureService` | Draft, receipt metadata, locked-capture count, and Log routing |
| `IntelligenceService` | Findings, refresh/cancellation state, indexed capture suggestions, projections, and reviewed budget proposals |

The services do not own SQLCipher connections and cannot open an independent
transaction. `AppModel` still coordinates locking, generation checks,
cancellation, cross-service transitions, and exactly one store transaction for
each operation that was atomic before the split. The deterministic clock,
quarantine preservation, and rollback ordering remain at their prior seams.

Whole-profile settings writes use a FIFO serializer. Each queued mutation
re-reads the latest committed profile after it acquires the lane, persists only
its local candidate, and publishes only after the write succeeds. Rapid input
therefore converges on the last choice, while a failed mutation cannot replace
or roll back an unrelated committed setting.

Repository structure is a CI invariant. `Scripts/validate_swift_structure.py`
checks every Swift file under `App/` and `Sources/`: files are limited to 1,200
lines, type and extension bodies to 600 lines, and function bodies to 80 lines.
The body-line convention excludes a declaration's signature and outer braces
but includes blank and comment lines inside the body. The release validator
also requires the explicit CI step, so removing or bypassing the gate fails
release readiness.

`Scripts/validate_architecture_fitness.py` keeps the reviewed dependency and
safety seams executable: Core imports only Foundation plus the single CSV
SHA-256 implementation; SwiftUI views cannot call `TransactionFactory`; every
colorset is registered with exact light/dark values; static UI keys resolve in
their target catalogs (shared keys resolve in both); and network APIs,
ambiguous URL-loading constructors, unreviewed force operations, and `print`
stay out of shipping Swift, including executable string interpolations. Its
exact safe exceptions are fixed-literal or bounded Foundation initializers and
one already-bounded local archive read recorded beside the checker. The
Foundation Models rules remain dormant unless a source imports
`FoundationModels`; with W3 present, imports and framework uses must stay inside
`#if canImport(FoundationModels)` and iOS 26 runtime-availability scopes. Model
execution must guard on `SystemLanguageModel.default.availability`, while
generated output stays limited to fixed local enums or literal `0...15`
range-guided ordinals. With W3 present, the same gate pins the single typed
request construction, prompt construction, selector call, model response call,
and prompt interpolation inventory; ambient pasteboard/defaults, raw OCR,
money/date/ID, arbitrary string, and extra-call mutations fail validation.

W3's production boundary is narrower still. `NaturalLanguageEntryParser`
retains sole ownership of every financial field and emits a separate bounded
context with parsed financial spans removed. The optional, persisted setting
defaults off, and its disabled path performs neither planning nor selection.
When enabled, stable existing-name lists are capped at 16. Canonical Unicode
normalization and scalar/UTF-8 ceilings apply to context, each name, and the
whole prompt. The only framework implementation accepts that typed request,
uses `SystemLanguageModel.default`, checks exact availability, creates one
uncustomized `LanguageModelSession()`, and asks only for `0...15` ordinals. No
provider, PCC, server, tool, package, dynamic schema, image, or receipt-byte
path exists.

Publication rechecks the request's kind, profile, split state, candidate
membership, and exact per-field value/edit/history provenance. A deterministic
history change filters only its stale model field in either completion order.
Use captures immediate pre-apply state; Reject restores it only while the full
model-applied state remains current. Accepted choices update the recoverable
SQLCipher draft immediately, but only the existing Save action creates a
transaction.

Operation failures cross one of two owned accessibility boundaries. Transient
form failures use `AccessibleErrorPresentation`, whose latest-wins reducer
snapshots a non-empty safe localized failure, resnapshots after every explicit
dismissal update boundary to recover coalesced identical failures, and presents
a native alert that owns VoiceOver focus and announcement. Load and root failures use a
target-bound visible summary with an adjacent retry action. Dismissal clears
only the presentation value. Correctable field validation remains inline, uses
an icon plus text rather than color alone, and is attached to its input as an
accessibility hint. The static `validate_accessible_errors.py` gate builds
fully-qualified declaration scopes across split extensions, rejects every
safe-message context without an exact same-owner alert or mapped retry action,
and requires the same field message directly on an input and its non-color-only
label. No-op retry, nested-owner, unrelated-recovery, cross-struct,
unrelated-alert, non-input-field, unassociated-field, and passive-red mutations
self-test the recursively inventoried gate.

## State and lock lifecycle

The application moves between launching, locked, onboarding, ready, and failed
states. The inactive phase applies an opaque privacy cover immediately. When
the configured timeout expires, the app flushes the encrypted Log draft,
closes the actor-isolated store, clears decoded records and caches, and returns
to the locked state. Receipt bytes never enter a draft.

On unlock, Keychain enforces local user presence before returning the
this-device-only SQLCipher key. Normal startup loads compact non-journal state,
exact balances/reference counts, budget-attribution index health, and at most a
bounded recent-activity page; it does not decode or retain the complete journal
or a healthy attribution history. An indexed mismatch triggers the exact
historical validator and fails budget projection closed. Malformed or orphaned
rows are quarantined from calculations while their encrypted raw records remain
available to backup/repair paths.

Saving, editing, deleting, importing, reconciling, posting a schedule, changing
lifecycle state, retaining an attachment, or moving a goal uses one store
transaction for all affected records. The operation either commits completely
or rolls back completely. The six-second Undo is offered only after a committed
save and reverses the same derived effects once.

## Intelligence boundary

`MoneyUpIntelligence` has no SwiftUI, SQLCipher, Keychain, network, logging, or
locale dependency. Detectors consume normalized `Sendable` values and exact
`Decimal` money, and emit stable localization keys, rule IDs, sample sizes,
confidence classes, exact figures, and bounded routes. The app localizes those
contracts only when rendering, so identical inputs produce byte-stable findings
across English and Simplified Chinese.

Routine payee affinity and detector reads use schema-7 indexes and decode zero
journal payloads. Observation queries are capped at 5,000 rows. A user-triggered
History review decodes only the requested entry IDs and caps the route at 100.
Recurrence findings can prefill an editable schedule but never save it;
budget suggestions present a before/after diff and apply selected changes in one
transaction with one-action atomic undo. Projections keep actuals, confirmed
remaining schedules, and flexible burn rate separate for each currency and
never invent FX or substitute zero for missing evidence.

The non-sensitive System/English/Simplified Chinese preference is stored in the
reviewed App Group defaults so app and widget agree. It is deliberately separate
from the financial profile, reporting time zone, stored text, and parsing rules.

## Ledger and SQLCipher schema 9

Normal views do not create postings directly. `TransactionFactory` creates
balanced expense, income, transfer, foreign-exchange, refund, reconciliation,
split, investment purchase/sale, and valuation entries. `JournalEntry`
validates each currency independently at initialization and decoding, and
retains originating calendar/time-zone facts plus a stable local-day key.

Schema 9 retains deterministic encrypted record payloads and the normalized
encrypted support tables. It includes schema 7's derived local-intelligence
facts, constant-size totals, and historical budget attribution; schema 8's loan
and allowance collections; and a blob-free evidence-search projection for
encrypted image/PDF names, on-device text, and local classification labels:

| Table/index | Purpose |
|---|---|
| `journal_entry_index` | Chronological identity, source fingerprint, stable day/range lookup, and a semantic budget-integrity fingerprint without decoding every payload |
| `journal_posting_index` | Account/category/currency posting events for reports, Calendar, lifecycle counts, and bounded scans |
| `journal_balance` | Exact materialized balance per account/currency |
| `receipt_attachment_index` | Entry relationship, MIME type, byte count, creation time, display name, and bounded evidence-search text without loading an encrypted image/PDF payload |
| `store_metrics` | Trigger-maintained exact record/payload/identity totals used to enforce the portable-recovery envelope in O(1) memory |
| `budget_attribution_entry_index` | Stable historical budget day, entry timestamp, and matching semantic integrity fingerprint without attribution JSON decode |
| `budget_attribution_posting_index` | Historical category/currency/amount postings used by bounded rollover queries |
| `intelligence_control` | Transactional enabled/disabled state for derived intelligence maintenance |
| `ledger_account_intelligence_index` | Minimal account kind/currency/system-role/archive classification |
| `journal_intelligence_source_index` | Normalized payee key and entry kind linked to the journal index |
| `payee_affinity_index` | Full-book category frequency/recency aggregates for bounded Quick Log suggestions |

Routine writes apply exact `-old + new` posting deltas to compact balance rows
inside the same transaction. A full rebuild is reserved for migration,
restore, or explicit repair. History uses stable keyset pages. Calendar and
reports request bounded posting events for the relevant window. Export,
archive, and whole-book lifecycle work page on demand rather than turning the
recent cache into an accidental full journal.

Schema-1/2 books migrate by decoding each legacy journal payload once to build
the normalized indexes without changing the original payload, timestamp, or
identifier. Later migrations add receipt metadata, exact store metrics, and
budget-attribution projections without rewriting valid payloads. Schema 9 adds
bounded evidence-search columns and rebuilds them from encrypted attachment
records without changing attachment bytes. The 6-to-7
migration decodes only metadata that schema 6 did not normalize (payee, kind,
and account classification) inside the migration transaction, then builds the
derived indexes without changing payload bytes, hashes, IDs, or timestamps.
The 7-to-8 migration is compatibility-only: it recognizes additive `loanPlans`
and `allowancePlans` records without rewriting journal payloads. Restore
identity validation, quarantine, bounded inventory, and atomic replacement
include both collections.
Raw malformed rows remain quarantined instead of blocking the readable book.

## Planning and investment records

Budget rollover has an explicit activation day and uses half-open Gregorian
reporting periods, so enabling it never retroactively invents carry-forward.
The first healthy indexed replay in a reporting month persists an authoritative
opening-carry checkpoint. Later unlocks query only the bounded range since the
latest checkpoint; backdated edits explicitly recompute affected checkpoints.
Savings and sinking goals retain dated contributions, withdrawals, manual or
automatic resets, archive state, target date, and reporting time zone.

Each connected holding owns a hidden position account. Purchases move cash to
the position, sales move proceeds back, and repricing balances valuation
changes against a hidden investment result account. Holdings are therefore not
added on top of ledger net worth. FIFO lots/disposals are deterministic
bookkeeping metadata, and append-only snapshots freeze totals separately by
currency.

## Portability boundary

CSV and native XLSX are explicit readable exports. Both retain stable entry,
posting, account, and hierarchy identifiers; exact decimals; currencies;
timestamps; origin-day context; and account metadata. CSV neutralizes formula
prefixes in user text. XLSX uses inline-string cells for user text and numeric
cells for valid financial values. Neither format includes receipt bytes.

Import is local, preview-first, row-aware, duplicate-detecting, and atomic.
Unknown CSV/TSV layouts can be mapped column by column. Full-fidelity recovery
uses an authenticated `.moneyup` archive derived from a user-held password.
Version 2 writes fixed metadata plus independently authenticated 1 MiB chunks
directly from a SQL cursor to a file; the header, chunk index, length, and
declared chunk count reject truncation, append, duplication, and reordering.
Current writes enforce a 100,000-record/512 MB stored-payload envelope, while
legacy version-1 archives remain readable within their compatibility limit.
Attachments, user rates, goals, snapshots, and quarantined encrypted raw
records remain in the archive. Restore streams into an isolated SQLCipher store
before confirmation, then presents only archive/schema versions, collection
counts, entry span, currencies, quarantine count, and current-to-candidate
replacement counts. The confirmation ticket binds that preview to the staged
ciphertext SHA-256; commit first makes a bounded private copy and rejects any
digest change before the existing encrypted rollback checkpoint and one live
transaction. Wrong password, tampering, cancellation, future schema, file swap,
or failure leaves or restores the prior book and never edits the selected file.
Deterministic encrypted staging, validation, verified-commit, and rollback
ownership is removed on normal completion and scavenged exactly at startup
after interruption. The rollback archive and any interrupted writer live in
one private owned directory; external export siblings remain untouched.

The same preview ticket owns normal and missing-device-key restore. Key-cliff
review represents the unreadable current ciphertext as inaccessible, never as
an empty book, and re-verifies its private copy before key generation. While
either restore replaces a book, widget, deep-link, capture, and intelligence
publication remain behind the authority boundary. Key-cliff validation keeps
the durable marker present; only marker removal permits restored preferences,
capture promotion, ready state, intelligence, and widget publication. Restore
failures wait for the preview sheet to dismiss before the native alert. When
the ready hierarchy survives, success focuses one visible confirmation; any
recovery-to-ready root transition is consumed once by the rendered hierarchy.

A missing device-bound key beside surviving main/WAL/SHM ciphertext is a
dedicated recovery state, not a corrupt-key or empty-book state. Because the
old logical store cannot open, `.moneyup` recovery first builds and strictly
validates a separately keyed SQLCipher candidate. Only afterward does it write
a non-secret artifact-mask manifest, store the new this-device-only key, and
rename the old and candidate artifact sets on the same volume. Startup can
idempotently finish that installation; any reopen/load failure deletes the new
key and restores the exact old artifact set. Immediate commit and startup
resume both recheck the separately encrypted capture inbox before removing the
marker; a late old-book capture forces rollback instead of crossing books.
Wrong password, tamper,
cancellation, and candidate validation failure precede all live/Keychain
mutation. The selected external archive is copied and never modified.
A post-completion inbox handoff failure records one redacted retryable issue;
it cannot roll back an already authoritative book or duplicate promotion.

The Data inventory is a separate metadata-only JSON manifest for upgrade and
restore reconciliation. Every durable collection count comes from one
actor-isolated, payload-free SQLCipher count snapshot. Already-decoded holdings
and goals supply nested lot, disposal, price-point, correction, movement, and
reset counts; a completeness flag compares their top-level totals with the raw
store counts. The manifest never loads or contains journal payloads, receipt
bytes, user-authored identifiers, names, amounts, currencies, notes, or balances.

## Evidence boundary

The build-10 0.7.1 baseline is merged through PR #40 as `68eee4f8`; exact
PR-head CI run 300 and merged-main CI run 301 passed. The build-11 product-
feedback candidate must repeat exact-head CI. None of that is signed-binary validation,
10,000-entry physical evidence, upgrade/restore on iPhones, TestFlight
processing, beta use, or App Review. Those gates remain tracked in
[Golden PRD traceability](GOLDEN_TRACEABILITY.md).
