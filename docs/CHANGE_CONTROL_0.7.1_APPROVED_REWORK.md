# MoneyUp 0.7.1 Approved Rework — Change-Control Record

Decision ID: `MU-CC-071-2026-09-04`

Status: **Approved for implementation; not release-accepted**

Founder approval: 4 September 2026, “Approve all.”

Implementation baseline: `30a783141e2b979553305aa2a5360af65b4d6427`
(`main` when this record was opened).

Feedback build: TestFlight `0.7.1 (1037.1)`. That installed build is evidence of
the reported problems, not the identity of the corrected candidate. The next
candidate must use a new build identity.

The acceptance and promotion evidence required by this decision is defined in
[QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md](QA_RELEASE_GATE_0.7.1_APPROVED_REWORK.md).

## 1. Problem

MoneyUp currently presents three economically different things too similarly:

1. ledger-recorded money;
2. policy-bound allowance entitlement or restricted stored value; and
3. a dated market observation used to estimate an investment's current value.

At the same time, Today needs clearer period context, top-level controls consume
too much horizontal space, some navigation implies a previous screen that does
not exist, and WidgetKit families can receive layouts or state that are not
valid for their constraints.

The root requirement is not “add more finance features.” It is: **help a person
make a correct next financial decision with evidence they can inspect, without
turning an estimate, entitlement, or stale projection into recorded money.**

## 2. Authority and version resolution

### 2.1 Source record

The supplied sources do not share one unambiguous version label:

| Supplied source | Internal identity | Treatment |
|---|---|---|
| `MoneyUp_Golden_PRD_v1.1_2026-08-26.docx` library label / uploaded DOCX copy | The document itself says Golden PRD **v1.0**, effective 26 August 2026, and declares itself final | Controlling baseline by its printed contents; this record does not rename it |
| `MoneyUp-PRD-v1.1.pdf` | Product Requirements **v1.1** | Context only where it does not conflict with the Golden document or later approved decisions |
| `MoneyUp-0.4.0-Audit(1).pdf` | Independent 0.4.0 audit | Defect evidence and non-regression input, not product authority |
| This decision record | Later founder approval dated 4 September 2026 | Narrow amendment for the requirements listed below |

This is a transparent amendment, not a silent replacement. The Golden
document's accounting, exactness, privacy, recovery, accessibility, and release
invariants remain controlling. Where this record deliberately changes prior
product presentation or scope, the conflict is named below.

### 2.2 Deliberate amendments

| Earlier contract or implementation | Approved resolution |
|---|---|
| “Safe to Spend Today” wording | The current budget-only value is named **Flexible today**. A liquidity-aware “Safe to Spend” value is deferred until unrestricted-cash and reserve-floor evidence exists. |
| Manual investment repricing and no automatic market prices | Add provider-neutral quote-observation and valuation contracts now, with manual/local policy as the only shipping mode. Zero is permitted only as an explicit manual/manual-legacy write-down; provenance, source identity/dedupe, quote currency, and provider response/request bindings are contractual. Provider networking remains a separately approved future stage. |
| Allowance metadata as a planning plan with optional linked asset | Preserve three economic modes, but make prepaid restricted value visibly discoverable under Assets without converting benefit limits or reimbursement-claim evidence at any status into assets. |
| Optional global horizontal tab swipe | Remove it. The five visible tabs remain the only global tab-navigation control. |
| Plan overview plus synthetic section “Back” | Plan's four peer sections use one adaptive root selector. Back appears only for a real pushed destination or recorded cross-tab origin. |
| Horizontally scrolling History hot-category chips | Keep deterministic ranking, but expose categories through one labelled menu with active state and Reset. User-defined categories are never icon-only. |

No other Golden requirement is weakened by this amendment.

## 3. Constraints and invariants

The implementation must preserve all of the following:

- Every committed journal entry balances independently in each currency using
  exact `Decimal` arithmetic.
- No implicit foreign-exchange conversion, invented rate, or cross-currency
  total is allowed.
- Ledger balances remain the only recorded-money and recorded-net-worth source
  of truth.
- A budget, benefit limit, reimbursement claim/status, or quote never creates
  money or a receivable.
- Restricted value never increases unrestricted cash or Flexible today.
- Derived-value failure is explicit and never rendered as a false zero.
- Origin-day and reporting-day calculations use the profile's stable Gregorian
  reporting calendar and time zone; absolute instants remain authoritative for
  ordering.
- Core use remains local, offline, encrypted, inspectable, and recoverable.
- No financial domain payload enters diagnostics, signposts, notifications,
  widgets, unencrypted defaults, or app-switcher snapshots.
- The five permanent tabs remain Today, History, center Log, Plan, and Assets.
- English and Simplified Chinese, VoiceOver, Dynamic Type, Reduce Motion,
  Increase Contrast, Reduce Transparency, and redaction remain release gates.
- Source implementation, a declared test, Simulator success, signed
  validation, TestFlight availability, and physical acceptance are distinct
  evidence states.

## 4. Approved requirements

### 4.1 Today and decision guidance

| ID | Requirement | Acceptance boundary |
|---|---|---|
| `AR-TOD-01` | The budget-only hero and all supporting copy use **Flexible today**, not “Safe to Spend.” | “Safe to Spend” may return only after a separate approved model constrains budget capacity by unrestricted liquidity and reserve/obligation evidence. |
| `AR-TOD-02` | Today shows a compact localized civil date and remaining-period context adjacent to the hero. | The explanation states the reporting-period end and number of civil days including today. It shows the reporting zone only when it differs from the device zone. |
| `AR-TOD-03` | One immutable reporting-period snapshot feeds the hero, seven-day amount, remaining-period amount, pinned-budget board, denominator, and explanation. | Gregorian profile calendar/zone; month start inclusive and next-month start exclusive; first, middle, leap-month, DST, and final-day cases agree. The final-day denominator is exactly one. |
| `AR-TOD-04` | Currency-minor-unit allocation conserves the exact positive flexible remainder over the remaining days. | Daily and prefix amounts never exceed the period remainder; deterministic residual units are assigned to the final reporting day. A zero-minor-unit currency such as JPY and a three-decimal currency such as KWD are mandatory tests. |
| `AR-TOD-05` | Negative, zero, unavailable, unclassified, and commitment-excluded states remain semantically distinct. | No false zero, hidden exclusion, or label implying unrestricted liquidity. Exact arithmetic and exclusion reasons remain inspectable. |

### 4.2 Allowances and restricted value

| ID | Requirement | Acceptance boundary |
|---|---|---|
| `AR-ALL-01` | The product retains three economic allowance modes: `benefitLimit`, `prepaidAsset`, and `reimbursement`. | Limit-only is policy capacity. Prepaid is already-funded restricted value. Reimbursement is expense-backed claim-status evidence; no status is itself money or a receivable. |
| `AR-ALL-02` | A prepaid allowance can be presented as a dedicated restricted asset/account experience under Assets while the linked ledger account remains authoritative. | Creating or editing allowance metadata never posts income, changes a balance, or duplicates net worth. One active prepaid plan owns one active same-currency restricted account; another active plan cannot select it, and existing generic assets are not silently reclassified. |
| `AR-ALL-03` | Applying an allowance to an expense records the chosen payment source and allowance usage consistently and atomically. | Prepaid spending cannot debit an unrelated account while leaving its restricted asset unchanged. Funding is measured at the expense instant, so a future top-up cannot authorize a backdated expense and no chronological restricted balance may become negative. The asynchronous preview is bound to the exact plan, source, occurrence instant, journal projection, and logical book; stale/in-flight evidence cannot enable Save. Every restricted debit must be owned by exactly one semantically valid prepaid usage or expiry reconciliation; positive funding needs no allowance claim. If the benefit does not cover the full expense, explicit split funding or a clear block is required. |
| `AR-ALL-04` | Cadence, eligibility, start/end, no/full/capped rollover, and expiry use a fixed policy time zone and remain explainable. | The governing zone is visible. New starts normalize to policy-zone day start, a chosen inclusive final day persists as the next civil-day boundary, and DST is calendar-derived; legacy partial-day bounds retain their exact instants. Travel, midnight, weekday, month-end, and editing cases do not double-reset or silently delete ledger value. Derived entitlement expiry is not posted as fake income or expense. |
| `AR-ALL-05` | Usage history retains the policy/version facts needed to reproduce the decision at posting time. | Once a plan is effective or has activity, its start/end, funding mode, linked account, and prior policy zone are not retroactively rewritten; policy edits begin at the next cadence boundary. Usage/reconciliation dates use their governing revision zone, and a usage editor resolves categories at the chosen occurrence instant, offering General only under an unrestricted policy. Replacing/deleting an entry relinks/removes its usage atomically. A current unlinked benefit-only edit uses exact expected evidence and preserves its UUID; delete returns exact evidence, and Undo captures usage/plan/policy synchronously and re-adds only if the current writable/unlinked/unclaimed/category/date/revision/capacity invariants still pass, without changing a journal. |
| `AR-ALL-06` | Restricted value is visibly separated from unrestricted cash and Flexible today. | User-owned prepaid value may appear in a labelled restricted component of net worth. Non-transferable/use-it-or-lose-it capacity and reimbursement-claim evidence at every status are excluded. Lifecycle operations fail closed if references cannot be preserved; malformed or historically negative restricted ledgers are quarantined without deleting encrypted evidence. |
| `AR-ALL-07` | Archive and unarchive are effective-dated lifecycle events, not a retroactive Boolean rewrite. | Archive is a pause. Historical summaries use the state at the requested instant; a cadence period active for any instant receives one unprorated entitlement, while a wholly archived period accrues no new grant and creates no expiry expectation. Current-format records bind a supported per-plan marker, timeline, and current state; partial, null, unsupported, unordered, or state-inconsistent forms fail closed. |
| `AR-ALL-08` | Allowance evidence and restricted-account debits form one bidirectionally closed authorization graph. | A journal entry may be claimed by at most one valid allowance usage or expiry reconciliation, and every live negative restricted posting must have exactly one such claim with matching immutable entry facts. Normal recovery scans complete indexed account-scoped restricted history plus referenced evidence to a monotonic fixed point, quarantines invalid plans and unauthorized prepaid evidence in memory while preserving encrypted rows, and keeps an ordinary benefit/reimbursement expense when only its allowance metadata is invalid. Strict restore rejects the same candidate. |
| `AR-ALL-09` | Reimbursement claim status is an explicit, evidence-only lifecycle. | A pending claim may become approved or rejected; approved may become reimbursed; rejected and reimbursed are terminal. Updates use an optimistic expected-state check and persist without changing any journal entry, account, cash, income, restricted value, or receivable. Eligible expense edits retain advanced status, deletion removes its evidence, and an edit that removes eligibility requires explicit confirmation rather than silently discarding the claim. Actual reimbursement money is logged separately. |

### 4.3 Investment market-data foundation

| ID | Requirement | Acceptance boundary |
|---|---|---|
| `AR-MKT-01` | A provider-neutral instrument identity distinguishes at least symbol and market venue, and supports an explicit stable identifier when available. | An ambiguous symbol is not guessed. The user or future provider mapping must choose the venue/instrument explicitly. |
| `AR-MKT-02` | A market quote is append-only exact evidence containing price, quote currency, market/received timestamps, source class/identifier, optional source-native record/sequence identity, and delay/freshness facts. | Price is positive except for an explicit manual or migrated-manual zero write-down; provider zero is invalid. Source/type/delay/quality combinations fail closed when inconsistent. Event dedupe preserves distinct equal-time source kinds/sequences and selects the latest correction before policy filtering, so an ineligible correction cannot revive older evidence. |
| `AR-MKT-03` | Manual/local is the only active policy in this release. Core defines provider and observation-store contracts plus a request policy that denies unapproved work. | No provider adapter, endpoint, credential, `URLSession`, backend, symbol transmission, background fetch, or App Privacy change ships in this tranche. Any future adapter response remains untrusted until its exact request identity/time/result set, supported kinds, requested currencies, and provider provenance match. Existing manual repricing remains available. |
| `AR-MKT-04` | Recorded book value and market estimate remain separate. | Purchases, sales, fees, lots, disposals, and recorded repricing remain ledger-authoritative. A quote can compute a dated **Estimated market value** but cannot write a journal entry or rewrite a lot. Only an explicit user action may record valuation. |
| `AR-MKT-05` | Quote completeness and freshness are inspectable per position and for aggregates. | A missing/stale/currency-mismatched observation produces a named gap and partial/unavailable aggregate, never a false zero or invented FX. Existing historical net-worth snapshots remain frozen. |
| `AR-MKT-06` | Any future network provider requires a new activation decision and privacy/security review. | The review must cover commercial display rights, provider availability, transmitted fields, retention, API-key ownership and Keychain storage, TLS host allowlist, timeout/cancellation/rate limiting, redacted logs, deletion/export, App Privacy answers, and manual fallback. iOS background delivery and WidgetKit timelines must not be described as real-time guarantees. |

Shipping data impact for this tranche: the new market contracts are Core-only
and introduce no SQLCipher schema migration or stored provider data. Existing
`InvestmentHolding` price history and journal records are not rewritten. A
future observation store or provider adapter must receive its own schema and
migration change record before activation.

### 4.4 Adaptive navigation and Back

| ID | Requirement | Acceptance boundary |
|---|---|---|
| `AR-NAV-01` | Remove global horizontal tab-swiping and its Settings control. | The persisted legacy preference may decode for compatibility but has no navigation effect and is not re-encoded as a live feature. Child charts, filters, lists, and gestures retain ownership of horizontal interaction. |
| `AR-NAV-02` | Plan uses one root `NavigationStack` and one adaptive selector for Budget, Calendar, Goals, and Allowances. | Selected item shows icon and text; unselected items may show icons. All four remain directly tappable without horizontal scrolling, have at least 44-point targets, explicit accessibility labels/selected state, and an accessible-size fallback that does not truncate meaning. |
| `AR-NAV-03` | History keeps its four readable time scopes and places dynamic hot-category selection in one labelled menu/control. | The active category/path is explicit, Reset is obvious, ranking remains deterministic, and duplicate or user-defined icons are never the only identifier. |
| `AR-NAV-04` | Back is contextual, never decorative. | A pushed detail/editor/drill-through receives native Back; a sheet uses Cancel/Close/Done; a tab root has no fake Back. Plan's peer-section selection does not create synthetic history. |
| `AR-NAV-05` | Cross-tab and deep-link flows retain a return origin only when a real origin exists. | A contextual “Back to …” consumes the recorded origin once. Direct tab selection clears stale origin. Drafts, filters, and exact-token action acknowledgement remain safe through return, lock, cancellation, and cold launch. |

### 4.5 Widget correctness

| ID | Requirement | Acceptance boundary |
|---|---|---|
| `AR-WDG-01` | Publish one atomic, versioned, bounded widget snapshot rather than independently mutable keys. | Readers observe either the old complete generation or the new complete generation. Absence alone is disabled/opt-out; a present corrupt, oversized, contradictory, negative-field, or unsupported-future value is stale. Positive overflow is bounded at the reviewed field limit, while any negative percent/count/day field invalidates the whole generation. The read-only extension never repairs storage, while the app writer atomically canonicalizes stale state. Expiry, opt-out, profile removal, restore boundary, and erase follow their explicit stale/scrub contracts. |
| `AR-WDG-02` | Each supported WidgetKit family receives a family-native information hierarchy. | Accessory circular, rectangular, and inline families never reuse a Home-screen tile grid. Home families reduce visible work at accessibility Dynamic Type sizes; no clipping, microscopic text, redundant label, or hidden primary meaning is allowed. |
| `AR-WDG-03` | Day and due-date wording use the stored reporting-calendar facts and timeline entry date. | Device-zone changes, midnight, DST, month-end, stale timelines, and preview/snapshot/timeline modes cannot change “today” or day-count meaning inconsistently with the app. Ready-scene activation republishes eligible state and arms one reporting-day boundary refresh; boundary crossing rearms, while inactive/locked/replaced books cannot publish obsolete work. |
| `AR-WDG-04` | Smart Overview publishes current bounded review, allowance, commitment, and budget status from one coherent projection. | An unavailable component stays unavailable; it cannot become zero. Opt-out is visibly disabled and directs the user to Settings; expiry is visibly stale and directs the user to open MoneyUp. Missing, intentional-zero, negative, current, and over-plan budgets remain distinct, and no generation combines old and new fields. |
| `AR-WDG-05` | Interactive widget actions use durable at-least-once ingress and exact-token UI acknowledgement. | An accepted data-free action is atomically persisted before intent success and survives cold launch/process recreation until acknowledged. Producers reload then authority-CAS; only a same-epoch exact postcondition resolves an ambiguous result. Validated recovery preserves concurrent valid/open work but resets absent, corrupt, or closed state. Token-bound locked capture makes post-inbox-commit replay idempotent. A crash before acknowledgement may replay navigation but never a financial commit. Separate taps or OS retries remain distinct because App Intents supplies no stable invocation ID. Exact/stale acknowledgements, FIFO capacity rejection, lock, cancellation, and authority replacement cannot consume another request. |
| `AR-WDG-06` | The redacted App Group has an exact three-artifact allowlist: language preference, one atomic summary value, and one bounded data-free action-ingress file. | No other key/file is approved. No amount, payee, account name, holding, symbol, quote, balance, transaction/book/ledger identifier, note, attachment, or extracted evidence crosses the App Group. The ingress file contains only protocol/authority metadata, admission state, opaque handoff tokens, and closed action values. Locked/redacted/tinted states reveal no additional domain content. |

## 5. Data and migration decision

### 5.1 Current release tranche

- SQLCipher remains schema 9 unless an implementation introduces a genuinely
  new persisted record/index. A version must never be bumped merely for a UI or
  Core-only contract.
- Existing allowance records decode losslessly. Archive history is an additive
  Codable field within the existing schema-9 allowance payload, so it does not
  cause a SQLCipher schema bump. Current-format records must carry the supported
  per-plan archive marker, transition timeline, and consistent current state as
  one unit. A genuinely legacy archived record containing neither new field
  infers the earliest evidence-consistent archive boundary: plan start when it
  has no activity, otherwise immediately after its latest usage and no earlier
  than its latest reconciliation period end. Under schema-9 backward
  compatibility, a forged record stripped into that complete legacy shape is
  indistinguishable from genuine legacy data; SQLCipher and authenticated
  portable archives remain the provenance boundary. No account is silently
  retyped.
- A present legacy tab-swipe field is decoded with its original Boolean type,
  then normalized to false. The initializer also ignores a requested true value,
  and every 0.7.1 rewrite omits the retired key entirely.
- Existing investment holdings, price history, lots, disposals, journal
  entries, net-worth snapshots, record IDs, timestamps, and hashes are not
  rewritten for the Core-only market foundation.
- The widget summary schema may advance only through its one atomic `Data` value
  with explicit old-version handling. The App Group allowlist remains exactly
  the nonfinancial language preference, that summary, and one bounded data-free
  quick-action ingress file; no migration creates a fourth key/file or reads the
  main SQLCipher database.
- Production restore reduces raw candidate records in stable key order before
  `AppModel` load, with cooperative cancellation and bounded state rather than a
  second whole-book snapshot. Per-plan allowance work is capped at 4,096 usage
  rows, 4,096 reconciliation rows, 512 archive transitions, and
  `10,000 + 2 × maxPolicyRevisions` period work; corresponding aggregate
  ceilings are 100,000. Weekday-period estimation is exact O(1) work from
  weekdays, not calendar-day iteration. Normal recovery still scans complete
  indexed restricted-account history and preserves encrypted raw rows; strict
  restore rejects invalid graphs.

### 5.2 Required migration evidence

For an installed predecessor and a clean install, retain before/after counts,
stable IDs, per-currency balances, allowance links/usages, holding/lots/
disposals, widget configuration, profile settings, draft/pending actions, and a
privacy-safe inventory hash. Validate:

- successful in-place open;
- interrupted migration and relaunch;
- insufficient storage/write failure;
- future-schema rejection;
- archive v2 restore and compatible-v1 restore;
- downgrade rejection without damage;
- legacy widget payload migration/scrub;
- legacy tab-swipe absent/false/true cases decoding as Boolean and normalizing
  false, wrong-type rejection, initializer suppression, and encoder omission;
- current archive marker/timeline consistency and evidence-safe legacy archive
  inference;
- complete indexed restricted-account authorization recovery plus exact-limit,
  plus-one, cancellation, bounded-memory raw-reduction evidence and strict-
  restore rejection of shared, invalid, missing, or over-limit evidence; and
- no automatic allowance-account reclassification or quote-history backfill.

## 6. Privacy and security impact

This tranche must retain the current “no financial-data network request” claim.
The market provider protocols describe a boundary; they are not authorization
to cross it. A static gate must reject concrete network/provider/credential
implementations until `AR-MKT-06` has a separately approved activation record.

Restricted accounts are financial data and remain in SQLCipher behind the
existing authentication cover. Any quote observations persisted in a future
tranche belong behind the same boundary. Both participate in the applicable
backup/restore/export/deletion policy and are excluded from
logs/signposts/widgets/notifications by default.

Allowance recovery may read the complete normalized posting history of the
affected restricted accounts and fetch the referenced full journal entries.
That account-scoped scan is cancellation-aware and iterates only while the
monotonic account/plan/journal quarantine state changes; it does not authorize
an unrestricted whole-book payload scan or deletion of the retained encrypted
source rows.

The navigation changes must not bypass lock, draft, stale-generation, erase,
or exact-token action boundaries. Widget routing continues through the shared
allowlisted action broker; widgets never open arbitrary URLs or carry domain
payloads.

## 7. Explicit non-goals

The following are not part of this approved implementation tranche:

- a liquidity-aware Safe-to-Spend number;
- user-configurable pay-cycle or arbitrary budget periods;
- automatic allowance income, synthetic expense, or silent balance expiry;
- treating all allowances or reimbursements as assets;
- brokerage login, account aggregation, trading, order routing, tax reporting,
  dividend/split/corporate-action automation, or portfolio advice;
- a live/delayed/EOD provider adapter, backend, API key, background quote job,
  or real-time-price promise;
- invented market venue, quote currency, FX rate, or missing quote;
- a permanent Back button on root tabs;
- icon-only identification of user-created categories;
- swipe as the only way to navigate; or
- financial amounts, holdings, symbols, names, or identifiers in widgets.

## 8. Staged delivery and stop conditions

| Stage | Scope | Exit condition |
|---|---|---|
| A — Contract | This decision record, requirement overlay, tests designed before claims | Requirement IDs map to implementation and evidence; contradictions are resolved explicitly |
| B — Correctness | Today snapshot/allocation, allowance semantics, navigation, atomic widgets, Core-only market foundation | Deterministic tests and static gates pass; no P0/P1 defect; migration/privacy review complete |
| C — Exact CI | Final branch head, PR merge result, and final `main` SHA | All required CI jobs are green on the exact identities defined in the QA gate |
| D — Signed validation | Protected TestFlight workflow in `validate` mode from exact final `main` SHA | Apple validates the signed IPA; identity, entitlements, privacy manifests, dSYMs, and IPA SHA-256 are retained |
| E — Internal TestFlight | Same-SHA `upload` operation, then Founders Internal | The upload run validates and uploads the same hashed IPA; install-over and physical matrix pass |
| F — Wider beta/release | Seven-day internal use, invited beta, exact-binary compliance and App Review | No unresolved critical defect; founder/account-holder performs the protected release action |

Stop promotion immediately for an unbalanced entry, false zero, invented FX or
quote, unrestricted/restricted value mixing, an unauthorized or multiply
claimed restricted debit, retroactively rewritten archive history, data loss,
privacy-boundary expansion, duplicate action, navigation trap, widget content
leak, migration or restore mismatch, launch watchdog regression, exact-SHA
mismatch, or missing release evidence.

## 9. Decision ownership

Implementation may refine type or file names without changing these semantics.
Changing any economic classification, network boundary, data migration,
privacy claim, tab identity, or release gate requires a new dated decision
record. The user-uploaded documents remain unmodified.
