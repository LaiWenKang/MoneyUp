# Market-data foundation — 0.7.1

Status: domain foundation only. No online quote feature is active.

## Problem

An investment price is evidence about a value at one market instant. It is not
a purchase, sale, cash movement, or accounting correction. Treating a fetched
price as any of those would make provider failure capable of rewriting net
worth or creating unexplained journal activity.

## Constraints and approved invariants

1. Manual/local operation remains the default and works without a provider.
2. Quote retrieval never creates or edits a journal entry.
3. A quote is immutable, exact-Decimal evidence with instrument, currency,
   source class and identifier, market/receipt timestamps, type, delay,
   quality, session facts, and optional source-native record/sequence identity.
4. Unavailable data is a typed outcome, never a zero quote. A zero is valid
   only as an explicit user-entered manual or migrated-manual write-down;
   provider-reported zero is invalid rather than an unavailable-data sentinel.
5. Recorded net worth remains authoritative. A temporary market estimate
   replaces a connected position component once; it is never added on top.
6. Currencies remain separate unless every non-zero foreign component has an
   applicable dated exchange rate. A partial combined total is forbidden.
7. Closed/halted-session carry-forward honors a supplied next-open boundary
   before a generic age limit, without guessing weekends or exchange holidays.
8. Existing `InvestmentHolding.priceHistory` remains ledger/manual repricing
   history. Market observations belong in a separate append-only store.

## Implemented boundary

The following provider-neutral types are in `MoneyUpCore`:

- `InstrumentIdentity` and `MarketVenue`
- `MarketQuoteObservation`, `MarketQuoteProvenance`, quote
  type/delay/status/quality, and `MarketSessionContext`
- `MarketDataPolicy`, with `manualLocalDefault`
- `MarketQuoteResolver` for deterministic event-identity dedupe, eligibility,
  freshness, and closed-session carry-forward
- `MarketQuoteBatch` with complete/partial/unavailable outcomes
- `MarketDataProvider` plus `MarketQuoteProviderResponseValidator`, a capability
  protocol and untrusted-response boundary with no concrete adapter
- `MarketQuoteObservationStore`, an encrypted-storage contract with no current
  persistence implementation
- `LegacyMarketDataMigration`, which maps dated manual history without
  inventing missing dates, venues, or providers
- `MarketEstimatedNetWorthEngine` and per-position valuation evidence/gaps

`MarketValuationLedgerCoverage` forces the caller to state one of two audited
accounting facts:

- `replaceRecordedPosition(accountID:value:)`: subtract the already-counted
  ledger position, then add its market estimate; or
- `addConfirmedLegacyPosition`: add only after explicit confirmation that the
  legacy value is absent from every recorded asset balance.

Duplicate holding IDs and duplicate connected position-account IDs fail before
calculation. Missing, disallowed, future, or rejected-stale quotes leave the
recorded totals unchanged and produce an explicit gap.

Observation construction binds the quote currency to the instrument and binds
manual, migrated-manual, imported, and provider provenance to their permitted
type/delay/quality combinations. Dedupe identity includes instrument, source
class, source identifier, market time, and any source-native record or sequence
identifier; quote type is only a conservative fallback when no native event
identity exists. Corrections are deduplicated before current-policy filtering,
so a newer disallowed correction cannot resurrect older evidence for the same
event. A future provider response is untrusted until its request ID/time, exact
result set, supported instrument kinds, per-instrument quote currency, provider
source class, and provider identifier all match the originating request and
descriptor.

## Persistence and migration impact

This tranche changes no SQLCipher schema and writes no new records. The quote
store protocol is deliberately separate so a future schema can use an
append-only `marketQuoteObservations` collection without nesting unbounded
provider history inside a holding payload.

Legacy mapping uses the holding UUID as the provisional instrument UUID and
the existing price-point UUID as the observation UUID. A current price without
an `asOf` date is flagged for resolution and is not copied with an invented
timestamp. Corrected evidence and superseded restoration points are excluded;
equal-timestamp history is fully preserved and resolves by the holding's
persisted source sequence, and each surviving point retains its UUID as
source-record provenance.
Migration must remain copy-first and idempotent until the encrypted store,
restore, quarantine, export, and size-limit paths support the collection.

## Privacy boundary

There is no provider adapter, endpoint, transport API, credential, background
task, broker login, backend, or symbol transmission in this implementation.
The request planner returns `localOnly` under the default policy. Merely
conforming a future adapter to `MarketDataProvider` does not authorize calling
it.

Before `foregroundOnDemand` can ship, a versioned product/privacy decision must
explicitly supersede the current no-transmission contract and define:

- provider identity, licensing, attribution, retention, and redistribution;
- the exact instrument metadata disclosed and when disclosure occurs;
- consent, opt-out, deletion, failure, throttle, and credential behavior;
- App Privacy answers, threat model, and privacy-copy changes;
- foreground-only refresh expectations and visible timestamp/delay/staleness.

iOS background execution and widget timelines cannot support a truthful
real-time guarantee. The intended next product step is opt-in delayed/end-of-day
foreground refresh, while manual repricing remains fully available.

## Verification matrix

`MarketDataFoundationTests` covers:

- stable identity normalization and Codable round trips;
- lossless Decimal quote evidence, explicit manual-zero write-downs, and
  provider-zero/invalid currency/time rejection;
- exact provenance type/delay/quality binding for manual, migrated, imported,
  and provider evidence;
- default policy blocking and explicit foreground planning;
- deterministic correction dedupe independent of input order, preserving
  distinct equal-time source sequences and source classes and applying policy
  only after the newest correction is selected;
- closed-session end-of-day and last-trade carry-forward only until a supplied
  next-open boundary, independent of the generic age window;
- exact provider request/result/provider/currency binding before an adapter
  response can be accepted;
- partial provider batches and unavailable outcomes without false zero;
- provider failure retaining the last stored observation;
- missing/stale-rejected quotes preserving recorded ledger value;
- connected-position replacement and duplicate-account prevention;
- one-round destination-currency precision;
- mixed-currency output with no invented FX total; and
- legacy identity/history preservation without an invented price date, while
  corrected evidence, superseded restorations, and same-instant ordering remain
  faithful to the effective holding projection.

The Linux review environment does not include the Swift toolchain. Repository
Python architecture checks and diff integrity can run here; the Swift package
and Xcode test targets remain mandatory CI gates before merge.

## Staged follow-up (not implemented)

1. Add an encrypted append-only quote collection, migration/quarantine paths,
   and retention limits.
2. Add UI for resolving exchange/instrument ambiguity and inspecting source,
   delay, market timestamp, freshness, and partial coverage.
3. Add one explicitly approved foreground adapter behind consent and licensing.
4. Consider opportunistic refresh only after the foreground flow is reliable;
   never advertise it as real-time.
5. Keep an explicit user action for promoting an estimate into a dated ledger
   valuation entry.
