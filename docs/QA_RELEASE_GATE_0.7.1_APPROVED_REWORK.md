# MoneyUp 0.7.1 Approved Rework — QA and Release Gate

Applies to decision `MU-CC-071-2026-09-04` in
[CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md](CHANGE_CONTROL_0.7.1_APPROVED_REWORK.md).

Status: **Open. Nothing in this document is a pass until its evidence is
recorded for the final candidate identity.**

## 1. Problem

The approved redesign crosses arithmetic, accounting classification, time-zone,
navigation, privacy, persistence, and extension-process boundaries. A happy-path
UI check cannot establish that:

- a remaining-day value conserves exact money;
- an allowance did not become duplicate or unrestricted value;
- a quote did not become a ledger fact;
- a Back affordance has a real destination;
- a widget read one coherent generation; or
- the IPA sent to Apple is the source and binary that were tested.

This gate defines the smallest complete evidence chain that can answer those
questions.

## 2. Constraints

- Preserve every invariant in the change-control record.
- Test implementation behavior rather than screenshots alone.
- Do not use production financial data in tests, screenshots, diagnostics, or
  artifacts.
- Automated tests use deterministic clocks, calendars, identifiers, locale,
  currencies, and provider doubles. They do not contact a network.
- A later commit invalidates all earlier exact-candidate CI, archive, IPA,
  TestFlight, migration, performance, and physical evidence.
- Simulator evidence cannot close a physical-device or signed-extension gate.
- A configured workflow, a declared test, or a source inspection is not an
  execution pass.

## 3. Assumptions

- **[VERIFIED]** The implementation baseline is
  `30a783141e2b979553305aa2a5360af65b4d6427`.
- **[VERIFIED]** The current repository uses SQLCipher schema 9 and Widget App
  Group snapshot schema 3 at the baseline.
- **[VERIFIED]** CI has four required jobs: Release assets, Core tests, iOS
  Simulator build, and iPhone Simulator performance baseline.
- **[VERIFIED]** CI is pinned to Xcode 16.4 build 16F6 and iOS Simulator SDK
  18.5; protected distribution is pinned to Xcode 26.6 build 17F113 and
  iPhoneOS SDK 26.5.
- **[VERIFIED]** The TestFlight workflow checks `expected_sha`, runs from
  `main`, validates the signed IPA with Apple, hashes it, and—in `upload`
  mode—checks the same hash immediately before transfer.
- **[ASSUMED]** Marketing version remains 0.7.1. The release owner may change
  it, but source, workflow, documents, metadata, archive, and TestFlight must
  then change together.

## 4. Approach and evidence states

| State | Meaning |
|---|---|
| `DESIGNED` | Acceptance and failure cases are specified, but no implementation pass is claimed. |
| `STATIC-PASS` | A named static/mutation validator passed on the recorded SHA. |
| `AUTO-PASS` | The named executable test passed on the recorded SHA/toolchain. |
| `SIGNED-PASS` | Apple validated the signed exact IPA and identity/entitlement/dSYM checks passed. |
| `PHYSICAL-PASS` | The named manual case passed on a recorded device/OS/build. |
| `BLOCKED` | Missing evidence or a defect prevents promotion. |

The release evidence ledger must record test ID, result, source SHA, version,
build, run/artifact identifier, toolchain or device/OS, timestamp, operator,
and a privacy-safe evidence link. “Passed locally” without identity is not a
valid release entry.

## 5. Automated acceptance matrix

Tests may be consolidated, but every row must retain an independently
observable assertion and map back to the named approved requirement IDs.

### 5.1 Today

| Test ID | Requirements | Deterministic setup | Required assertions |
|---|---|---|---|
| `TOD-AUTO-01` | `AR-TOD-01`, `AR-TOD-02` | Fixed reporting date, English and `zh-Hans` localization fixtures | User-facing hero is Flexible today; context names the localized date, period end, inclusive day count, and only shows the reporting zone when different from the device zone. |
| `TOD-AUTO-02` | `AR-TOD-03` | First day, middle day, final day, January–February, leap February, year boundary | All Today derivatives share one period token and instant; denominator is inclusive and never below one; half-open month boundary is stable. |
| `TOD-AUTO-03` | `AR-TOD-03` | Reporting zones with DST gap/fold and fixed non-DST zone; device zone changed before/after calculation | Reporting-day attribution and period totals do not follow the device zone; no duplicate or skipped allocation. |
| `TOD-AUTO-04` | `AR-TOD-04` | Positive remainders in JPY, SGD, and KWD that do not divide evenly | Sum of all day allocations equals the exact remainder in minor units; every prefix is monotonic and bounded; deterministic residual is on the final reporting day. |
| `TOD-AUTO-05` | `AR-TOD-04`, `AR-TOD-05` | Negative, zero, overspent, arithmetic overflow, unavailable budget, unclassified purpose, due/posted/excluded commitments | States and reasons remain distinct; no false zero or unrestricted-cash claim; a due commitment is counted exactly once. |
| `TOD-AUTO-06` | `AR-TOD-03`, `AR-TOD-04` | Mutation replaces the single snapshot with multiple `Date()`/`Calendar.current` reads or multiplies a rounded daily value | Static/mutation test fails, preventing midnight tearing and cumulative rounding drift. |

### 5.2 Allowances

| Test ID | Requirements | Deterministic setup | Required assertions |
|---|---|---|---|
| `ALL-AUTO-01` | `AR-ALL-01`, `AR-ALL-02` | Legacy and new limit-only, prepaid, and reimbursement records; two active prepaid plans competing for one account | Decode is lossless; no mode creates a posting; a prepaid link requires an active same-currency restricted asset owned by no other active plan; the edited plan may retain its own valid account. Limit-only/reimbursement cannot masquerade as assets and existing account types are not silently changed. |
| `ALL-AUTO-02` | `AR-ALL-03` | Expense below, equal to, and above remaining benefit; prepaid and non-prepaid payment sources; backdated expense before a later top-up or debit; equal-timestamp funding/spend; date/source/plan/projection/book revision changed during preview | Expense, postings, funding split, and usage commit or roll back together. Prepaid mode debits the linked restricted asset or rejects the inconsistent route. Historical spendable value comes from the indexed ledger at the exact expense instant; current balance, future funding, and later debit cannot leak backward. An in-flight/stale preview cannot enable Save. Point-in-time and chronological balances remain nonnegative; equal-timestamp events form one deterministic batch. The remainder is exact. |
| `ALL-AUTO-03` | `AR-ALL-03`, `AR-ALL-05`, `AR-ALL-08` | Save, double-save, edit amount/date/category/account/mode, delete, Undo, lock/background at each commit boundary | Exactly one usage links to the authoritative entry; edit relinks/removes stale evidence; deletion and Undo restore coherent journal and usage state. |
| `ALL-AUTO-04` | `AR-ALL-04` | Daily, weekday, weekly, monthly; no/full/capped rollover; visible start/inclusive end around DST; legacy partial-day bounds; final period | Every domain interval is half-open in the visible governing policy zone. A new start stores civil-day start and the inclusive final day stores the next civil-day boundary without fixed-second arithmetic; a legacy partial-day instant remains exact. Reset/expiry changes derived capacity once and never posts income/expense or deletes ledger value. |
| `ALL-AUTO-05` | `AR-ALL-04`, `AR-ALL-05` | Travel, device-zone change, DST gap/fold, midnight, effective plan with no activity, later zone/policy edits, usage date crossing a revision, restricted versus unrestricted eligible categories | No double reset. Effective history is retained even before first usage; name-only edit preserves the zone, immutable plan bounds/funding reject retroactive change, and policy changes start at the next cadence boundary. Every displayed policy/usage/reconciliation date uses its governing revision zone. The usage picker changes with the occurrence-time policy, clears an invalid old selection, and offers General only when unrestricted. |
| `ALL-AUTO-06` | `AR-ALL-06`, `AR-ALL-09` | Restricted prepaid value, non-transferable limit, and reimbursement in every claim status | Flexible today excludes all restricted value. Only qualifying owned prepaid value appears in the labelled restricted net-worth component; no reimbursement status changes headline unrestricted cash or creates an asset/receivable. |
| `ALL-AUTO-07` | `AR-ALL-02`, `AR-ALL-06`, `AR-ALL-08` | Restore, merge, delete/reassign of plan, linked account, and eligible categories; malformed/negative restricted ledger | Referenced lifecycle operation either preserves/reassigns every link atomically or fails before mutation. Normal recovery quarantines invalid restricted state without deleting encrypted rows; strict restore rejects it. Backup/restore preserves exact valid mode and history. |
| `ALL-AUTO-08` | `AR-ALL-04`, `AR-ALL-05`, `AR-ALL-07` | Archive/unarchive at exact usage and cadence boundaries; partial and wholly archived daily/weekly/monthly periods; full/capped rollover; expiry; same-instant toggles; current-format null/missing/unsupported/inconsistent marker or timeline; genuine legacy archived records with no evidence, usage, or reconciliation evidence | Archive is a forward-only effective-dated pause and never rewrites a prior summary. A partially active period receives one unprorated entitlement; a wholly archived period receives no new grant or expiry expectation. Same-instant actions coalesce deterministically. Current-format damage fails closed; a fully legacy-shaped record infers plan start or the earliest boundary strictly after its latest usage and no earlier than its latest reconciliation period end. |
| `ALL-AUTO-09` | `AR-ALL-03`, `AR-ALL-06`, `AR-ALL-08` | Cross-plan duplicate claims; one entry reused by usage/reconciliation; wrong kind/category/date/amount/currency/account/source/fingerprint/origin; unlinked restricted expense/transfer/adjustment; invalid prepaid versus benefit/reimbursement metadata; recovery dependencies removed across successive passes | Every live negative restricted posting has exactly one valid claim and every claim matches immutable journal facts. Normal recovery uses complete normalized restricted-account history plus referenced evidence, grows quarantine/removal sets to a fixed point, excludes an invalid prepaid plan and its debit evidence in memory, preserves raw encrypted rows, and retains a standalone ordinary benefit/reimbursement expense when only its plan metadata is invalid. Strict restore rejects any equivalent candidate. |
| `ALL-AUTO-10` | `AR-ALL-05`, `AR-ALL-09` | Pending claim approved/rejected; approved claim reimbursed; stale/repeated/skipped/terminal transition; eligible advanced-status expense edit/delete; edit that removes eligibility; current unlinked benefit usage edit/delete/Undo; archived/grandfathered/linked usage; presentation state cleared before Undo; intervening capacity/policy/revision change; persistence failure, lock, and stale logical book | Claim transitions are forward-only, optimistic, durable, and journal/account-count neutral. Eligible edits preserve advanced status; deletion removes evidence; losing eligibility requires confirmation. Unlinked benefit-only edit uses exact expected evidence and preserves its UUID; delete returns exact evidence; Undo synchronously captures usage/plan/policy and atomically restores once only while current writable/unlinked/unclaimed/category/date/revision/capacity invariants still hold. Restricted evidence stays on its journal workflow. Every failure leaves the complete prior plan and widget generation unavailable/current as specified, never a partially published mix. |

### 5.3 Market-data foundation

| Test ID | Requirements | Deterministic setup | Required assertions |
|---|---|---|---|
| `MKT-AUTO-01` | `AR-MKT-01` | Same ticker on two venues, aliases, case/whitespace, missing venue/stable ID | Canonical identity is deterministic; venue ambiguity is an explicit gap and is never guessed. |
| `MKT-AUTO-02` | `AR-MKT-02` | Manual/imported/provider/migrated sources; same-time distinct source kinds and native sequences; corrected event whose newest version is policy-ineligible | Exact source/type/delay/quality combinations are enforced. Dedupe identity preserves distinct events, is input-order stable, and selects a correction before policy filtering so older eligible evidence cannot be resurrected. Provenance and both timestamps survive round-trip where storage is supplied. |
| `MKT-AUTO-03` | `AR-MKT-02`, `AR-MKT-05` | Negative price, explicit manual zero, provider zero, invalid precision/time/currency/provenance, overflow, future skew, currency mismatch, missing and stale quote | Only explicit manual/migrated-manual zero is valid; provider zero and every inconsistent input fail closed. Completeness/freshness names the gap; aggregate is partial/unavailable rather than zero. |
| `MKT-AUTO-04` | `AR-MKT-04` | Holding quantity/lots plus newer observation | Estimated market value uses exact multiplication and exposes evidence; journal, price history, lots/disposals, balances, and frozen snapshots remain byte/value-identical. |
| `MKT-AUTO-05` | `AR-MKT-03` | Manual-local policy plus an injected provider double; wrong request ID/time/result set, instrument kind, quote currency, source class, or provider identifier | Request planning denies provider work before invoking the double. The provider wrapper rejects every unbound response before persistence/use. No concrete provider, endpoint, credential, background task, or network import exists in shipping source. |
| `MKT-AUTO-06` | `AR-MKT-05` | Multi-currency positions with complete/incomplete observations and no exchange rate | Results remain per currency. No converted portfolio total is invented; stable position-level gaps explain incompleteness. |
| `MKT-AUTO-07` | `AR-MKT-03`, `AR-MKT-04` | Existing holding with legacy price events | Migration/read adapter preserves every legacy event and ledger value without backfill or rewrite; new contracts remain compatible with manual repricing. |

### 5.4 Navigation

| Test ID | Requirements | Deterministic setup | Required assertions |
|---|---|---|---|
| `NAV-AUTO-01` | `AR-NAV-01` | Legacy profile with Boolean tab swipe on/off, invalid legacy field type, new initializer requesting true, and rewritten profile; horizontal drags over root, chart, filter, list, and passive space | No drag changes the selected tab. A present legacy Boolean is type-checked then normalized false, initializer input cannot reactivate it, and rewrite omits the key; malformed type still fails decoding. Five visible tabs remain in fixed order. |
| `NAV-AUTO-02` | `AR-NAV-02` | Every Plan section and selection transition | One stack owns navigation; selector changes peer content without adding stack depth; all four sections remain reachable and selected state is explicit. |
| `NAV-AUTO-03` | `AR-NAV-03` | Empty, one, five, and more-than-five ranked categories; duplicate icons/names; archived/system categories | Menu exposes deterministic eligible results, full path, active state, and Reset. Time scopes remain independent and combinable. |
| `NAV-AUTO-04` | `AR-NAV-04` | Root, pushed detail, nested editor, chart drill-through, sheet, direct tab selection | Root has no Back; pushed flow pops one real destination; sheet dismisses with the correct role; peer Plan selection has no synthetic Back. |
| `NAV-AUTO-05` | `AR-NAV-05` | Cross-tab origin, direct tab reselection, repeated deep link, cold/warm launch, lock/cancel | Contextual origin appears only when real, is consumed once, and is cleared by direct selection. Draft/filter state remains intact; action routing retains durable at-least-once ingress and exact-token UI acknowledgement without claiming exactly-once execution across process death. |

### 5.5 Widgets

| Test ID | Requirements | Deterministic setup | Required assertions |
|---|---|---|---|
| `WDG-AUTO-01` | `AR-WDG-01` | Writer interruption between every field of the former schema; concurrent reader; absent, corrupt, oversized, contradictory, negative-field, and future schema-4 values through read-only and maintenance-capable stores | The reader observes only one complete generation. Absence alone reads disabled without a write. Present invalid/future data reads stale; the extension performs no maintenance write, while the app writer replaces it atomically with canonical stale. Legacy values are migrated/scrubbed as specified, never mixed. |
| `WDG-AUTO-02` | `AR-WDG-01`, `AR-WDG-04` | Missing budget, intentional zero budget, negative effective budget, current 0%, over 100%, negative percent/count/day fields, unavailable component, canonical/contradictory disabled, stale, corrupt, future-version, erase, restore, profile removal | State transition is deterministic; unavailable is not zero; missing, zero, negative, current, and over-plan remain distinct. Only genuine opt-out gives Settings guidance; every present malformed/contradictory generation gives open-to-refresh stale guidance. Positive overflow is bounded, negative data invalidates the whole atomic generation, and known legacy/private keys are scrubbed. |
| `WDG-AUTO-03` | `AR-WDG-02` | Every supported family/content state at ordinary and accessibility Dynamic Type sizes, including AX5 EN/zh-Hans previews | Family dispatch selects only its approved layout. Accessory families never instantiate Home-screen grids; Home Quick Actions, Budget Status, and Smart Overview reduce visible density at accessibility sizes without dropping primary meaning or exposing decorative images to accessibility. |
| `WDG-AUTO-04` | `AR-WDG-03` | Timeline date around midnight/month-end/DST with profile and device zones different | Relative wording uses entry date plus stored reporting facts and agrees with the app's day key; preview, snapshot, and timeline use the same policy. |
| `WDG-AUTO-05` | `AR-WDG-04` | Review/allowance/commitment/budget components and allowance/journal mutations updated in different orders | One coherent projection is published only after all in-memory financial state agrees; no intermediate allowance-plan/journal mix, old review count, or zero substitutes for unavailable. Expiry applies to the whole generation. |
| `WDG-AUTO-06` | `AR-WDG-05` | Absent/corrupt/future/oversized/noncanonical/duplicate-key ingress; process recreation before route and after dequeue; wrong/stale token; ambiguous append/ack result; cached-open/cached-closed producer; concurrent first append during recovery; capacity; locked inbox commit before UI completion; erase/restore/key-replacement crash and close failure | Intent success follows a durable data-free append or an exact same-epoch durable postcondition. The exact token stays at the FIFO head until exact UI acknowledgement; a crash before that point may replay navigation but never a financial commit. Wrong/stale acknowledgements remove nothing, capacity rejects newest without eviction, reload-plus-authority-CAS rejects boundary races, and validated recovery preserves current valid/open accepted work while resetting absent/corrupt/closed state. Token-bound locked replay creates one inbox payload. OS retries remain distinct because no stable invocation ID is supplied. |
| `WDG-AUTO-07` | `AR-WDG-06` | App Group key/file/source/schema mutation adds a fourth artifact or any forbidden field class | Static privacy gate permits exactly language preference, one atomic summary key, and one bounded data-free action-ingress file, and rejects amount, name, note, account/holding/symbol/quote, attachment/evidence, and domain identifiers in any of them or a widget route. |
| `WDG-AUTO-08` | `AR-WDG-02`, `AR-WDG-03`, `AR-WDG-04` | Ready scene activation, duplicate activation, onboarding-to-ready, reporting midnight/month-end/DST boundary, wall-clock rollback, background, deferred lock, replacement, and logical-book revision | Activation republishes eligible current state and owns one boundary wait. Crossing the book's civil reporting day refreshes/rearms exactly one wait; obsolete work cannot publish across inactive, lock, replacement, or book-revision boundaries. First onboarding remains opt-in disabled. |

### 5.6 Migration, recovery, and cross-cutting failure injection

| Test ID | Requirements | Required result |
|---|---|---|
| `MIG-AUTO-01` | All data requirements | Installed baseline opens in place; record IDs, timestamps, per-currency balances, journal/posting counts, holding history, allowance links/usages, settings, and drafts are unchanged except explicit additive defaults. Legacy archived allowances infer the earliest evidence-consistent transition without a SQLCipher schema bump or journal rewrite. |
| `MIG-AUTO-02` | `AR-WDG-01` | Widget schema transition is atomic; legacy and future payloads follow explicit migrate/scrub behavior without main-store access. |
| `MIG-AUTO-03` | All | Injected write failure/cancellation/lock at every new persistence boundary leaves the complete old state or complete new state, never a mixture. |
| `MIG-AUTO-04` | All | Version-2 and compatible-v1 archive restore preserve the approved new state. Before candidate-model load, production restore reduces raw rows in stable key order with cooperative cancellation and bounded state rather than a second whole-book snapshot; it rejects malformed/future/oversized input, more than 4,096 allowance usages, 4,096 reconciliations, 512 archive transitions, or `10,000 + 2 × maxPolicyRevisions` period work per plan (11,024 at the 512-revision cap), more than 100,000 of each nested allowance work class in aggregate, or any unauthorized/shared restricted debit before domain decode, relationship traversal, or live-book mutation. Weekday period work is counted exactly in O(1) from weekdays without calendar-day iteration. |
| `SEC-AUTO-01` | `AR-MKT-03`, `AR-MKT-06`, `AR-WDG-06` | Architecture mutation gates reject unauthorized network/provider/credential source and expanded widget/log/signpost payloads. |
| `SEC-AUTO-02` | `AR-NAV-05`, `AR-WDG-05` | Lock, erase tombstone, stale generation, restore, and key-cliff states deny and forget queued navigation/action work without revealing the book. |

## 6. Static validation gate

Run from a clean checkout of the candidate SHA:

```bash
python3 Scripts/validate_swift_structure.py
python3 -m unittest discover -s Scripts/tests -p 'test_validate_architecture_fitness.py'
python3 Scripts/validate_architecture_fitness.py
python3 -m unittest discover -s Scripts/tests -p 'test_validate_launch_safety.py'
python3 Scripts/validate_launch_safety.py
python3 -m unittest discover -s Tests/PerformanceSignpostsValidatorTests -p 'test_*.py'
python3 Scripts/validate_performance_signposts.py
python3 Scripts/validate_accessible_errors.py
python3 -m unittest discover -s Tests/PlatformActionsValidatorTests -p 'test_*.py'
python3 Scripts/validate_platform_actions.py
python3 Scripts/validate_release_assets.py
git diff --check
```

In addition, the exact source candidate must have static or mutation coverage
that rejects:

- multiple independent time reads in one Today calculation;
- rounded-daily multiplication as a weekly/period total;
- allowance metadata posting or counting as unrestricted cash;
- a current-format allowance dropping, nulling, downgrading, reordering, or
  contradicting its archive marker/timeline/current state;
- a restricted debit without exactly one semantically valid usage or expiry
  authorization, including a source label presented as authorization;
- a quote observation mutating a journal, lot, or historical snapshot;
- concrete network/provider/credential code in the manual-only market tranche;
- global tab drag handling or a visible legacy swipe setting;
- synthetic Back on a tab or Plan peer root;
- accessory widgets selecting Home-screen layouts;
- non-atomic widget fields or any forbidden widget payload; and
- stale requirements/test-count/release identity documentation.

## 7. Exact-head CI gate

Let `C` be the final feature-branch commit and `M` the final merge commit on
`main`. Record full 40-character SHAs. No source, test, project, workflow,
localization, privacy, or release-document change is permitted after its gate.

1. **Branch head:** the `push` run for the `codex/**` branch must report
   `GITHUB_SHA == C` and all four jobs green.
2. **PR merge result:** the pull-request run must test the merge result built
   from head `C` and the then-current base. Record the PR head SHA, merge-ref
   SHA, run ID, and four green jobs. Do not describe the merge-ref as the source
   head.
3. **Merged main:** after merge, record `M`; the `push` run with
   `GITHUB_SHA == M` must pass all four jobs again. This is the only SHA eligible
   for protected TestFlight dispatch.

Required CI jobs and retained artifacts:

| Job | Required result/evidence |
|---|---|
| Release assets | Structure, architecture, launch, signpost, accessible-error, platform-action, privacy/localization/icon/release validators pass |
| Core tests | Pinned Xcode; warnings-as-errors domain suite; result/log and core-persistence coverage artifact retained |
| iOS Simulator build | Pinned Xcode/SDK; immutable package graph; app and widget build; app-model tests and `.xcresult`/coverage retained |
| iPhone Simulator performance baseline | Exact iPhone 16 Pro iOS 18.5 runtime; serial Release suite; machine-readable environment/metrics and raw `.xcresult` retained |

Cancelled, skipped, neutral, stale, rerun-on-another-SHA, or artifact-missing jobs
do not satisfy the gate.

## 8. Signed validation and TestFlight gate

From final `main` SHA `M`:

1. Reconcile `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, workflow
   `SOURCE_BUILD_NUMBER`, release documents, and App Store metadata. The
   distribution build generated by the workflow must be newer than `1037.1`.
2. Dispatch protected TestFlight `validate` with `expected_sha=M`. Retain run
   ID, toolchain/runner fingerprint, version/build, archive identity,
   entitlements, provisioning profiles, dSYM inventory, IPA SHA-256, and
   Apple's validation result. This closes signed validation only; it is not an
   upload.
3. After approval to distribute internally, dispatch `upload`, type `UPLOAD`,
   and set `expected_sha=M`. This run must repeat preflight and Apple validation
   and upload the exact IPA whose SHA-256 it checked immediately before
   transfer. Retain the encrypted recovery artifact before expiry.
4. Confirm App Store Connect processing completed and assign only that build to
   **Founders Internal**. Record the processed build identity and tester group.

A validate run and an upload run produce separate signed artifacts. Therefore,
the upload operation's own same-run validation/hash check is the authority for
the uploaded IPA; do not claim that a separately generated earlier IPA was
uploaded.

## 9. Physical-device matrix

Use fictional data on at least the oldest supported iPhone/iOS combination and
a current large-screen iPhone on the App Review-class OS. Repeat critical
navigation/widget cases on the founder's normal device. Record hardware, OS,
locale, reporting/device zones, appearance/accessibility settings, installed
predecessor, version/build, and candidate SHA.

### 9.1 Required dimensions

| Surface | Dimensions that must be crossed | Pass evidence |
|---|---|---|
| Today | first/middle/final day; leap February; reporting zone same/different; positive/zero/overspent/unavailable; SGD/JPY/KWD | Screen recording plus independent minor-unit reconciliation of hero, seven-day prefix, period remainder, date, denominator, zone, and explanation |
| Allowance | three modes; four cadences; no/full/capped rollover; exclusive account ownership; eligible/ineligible categories across revisions; pending/approved/rejected/reimbursed claims; historical prepaid preview; inclusive civil end; partial/split/exhausted; benefit-usage and linked-expense edit/delete/Undo; archive/unarchive; plan/device-zone mismatch and DST | Before/after ledger, account count, policy/claim evidence, and allowance reconciliation proving no duplicate/unrestricted/receivable value, stale preview, retroactive date/zone/archive rewrite, grant/expiry for a wholly archived period, or silent ledger expiry |
| Investments | existing manual repricing including explicit zero write-down; provider-zero rejection; same symbol on two venues; fresh/stale/missing/mismatched/provenance-correction quote fixtures; multi-currency | Recorded and estimated values visibly distinct; source/date/gaps inspectable; provider responses remain request/provider/currency bound; no network traffic or ledger/history change from estimate |
| Plan | every peer section; portrait; largest Dynamic Type; VoiceOver; EN/zh-Hans | Four sections reachable without scrolling; selected name/trait and 44-point targets; no fake Back or truncation |
| History | all four time scopes; no/one/many hot categories; long/deep duplicate names; filters combined/reset; VoiceOver | Label/path, active state, Reset, and results agree; horizontal gesture cannot switch tabs |
| Back/deep links | root, nested, sheet, chart drill-through, cross-tab origin, direct tab tap, lock/cancel/cold launch | Native role and destination are correct; origin consumes once; no trap, stale return, draft loss, or duplicate action |
| Widgets | every supported Home/Lock family × light/dark/tinted/redacted × EN/zh-Hans × ordinary/AX5 Dynamic Type × missing/zero/negative/current/over-plan budget, negative/corrupt/future/contradictory payload, partial insight, stale/disabled × activation/reporting-day boundary × unlocked/locked | Screenshot/recording shows intentional accessible density, no clipping/tiny text/leak/false zero/stale mix, correct Settings-versus-refresh guidance and relative day, one current generation after activation/day change, and passive Budget Status/Smart Overview |

Also run largest Dynamic Type, VoiceOver, Increase Contrast, Reduce Motion,
Reduce Transparency, grayscale, interruption/background/foreground, and a
device-zone change against all changed surfaces. A screen that technically
renders but hides the active selection, amount meaning, error recovery, or
navigation exit fails.

### 9.2 Upgrade, restore, and privacy

- Install the exact predecessor through TestFlight, populate fictional
  allowances, holdings, pinned budgets, filters, widgets, draft, and queued
  action, then update without deleting the app.
- Reconcile the privacy-safe inventory before and after update and after one
  foreground/background/lock cycle.
- Restore a verified v2 archive and compatible-v1 archive on a clean device;
  repeat once with interruption during validation/commit.
- Exercise an authentic legacy archived allowance with no evidence and with
  usage/reconciliation evidence; confirm the inferred boundary is respectively
  plan start or the earliest evidence-consistent instant. Reject a
  current-format archive whose marker, timeline, or current state is missing,
  null, unsupported, reordered, or inconsistent. Record the compatibility
  limitation that a payload stripped of both new fields has a valid fully
  legacy shape and cannot be distinguished semantically under schema 9.
- Restore fixtures containing unlinked, multiply claimed, or semantically
  mismatched restricted debits. The production restore path must reject before
  replacement; normal recovery of the equivalent live corruption must preserve
  the encrypted rows while excluding invalid plans and debit evidence.
- On an instrumented fixture, prove raw restore screening occurs before
  candidate-model load, observes cancellation, and rejects one above every
  allowance per-plan/aggregate reconciliation, archive-transition, and
  cadence-period bound. Include a long-lived weekday plan to prove work is
  charged by actual weekday periods, not all calendar days. Retain elapsed time,
  peak memory, and rejection-before-replacement evidence.
- Confirm a legacy Boolean swipe preference is normalized off and omitted on
  the next profile rewrite; a malformed non-Boolean value fails decoding, and
  neither migration nor a new initializer can reactivate tab swiping.
- Inspect network traffic during Today, Plan, Assets, repricing, app launch,
  background/foreground, and widget reload. This tranche must send zero
  financial-data/provider requests.
- Inspect console, signposts, notification previews, widget App Group payload,
  app-switcher snapshots, crash diagnostics, and retained CI artifacts for
  domain payload leakage.

## 10. Performance and stability

Run the existing deterministic 10,000-entry/20-schedule harness and physical
Golden p95 procedure on the exact candidate. The approved rework must not
regress startup/watchdog safety, unlock, tab first content, History query,
transaction publication, export/archive/restore, receipt processing, scrolling,
or peak memory.

Add changed-surface observations for:

- Today recomputation across foreground, midnight, and zone change;
- allowance summary/logging with the maximum bounded history;
- production raw-row restore screening, cancellation, and per-plan/aggregate
  usage, reconciliation, archive-transition, and cadence-period bounds,
  including rejection one over each limit before domain decode and exact
  constant-time weekday-period estimation;
- restricted-account recovery over complete indexed posting history, including
  chained account/plan/journal removals that require more than one fixed-point
  pass;
- market-estimate completeness over the maximum supported holdings/quotes;
- Plan/History selector interaction and first content; and
- widget snapshot publication, corrupt/future read-only decode, accessibility
  density, scene activation/reporting-day lifecycle, and action routing.

Use existing Golden budgets where one exists. If a changed surface has no
approved numeric budget, record p50/p95, device, dataset, and regression versus
the baseline; do not invent a pass threshold after seeing results.

## 11. Release decision checklist

The release owner may mark the candidate ready for Founders Internal only when:

- every approved requirement maps to source and at least one named automated
  or manual test;
- local static/mutation gates and exact branch/PR/main CI are green;
- signed validation succeeded for final `M`;
- migration, restore, launch-watchdog, Today arithmetic, allowance ledger,
  navigation, widget, bilingual accessibility, privacy, and performance
  blockers are closed on the exact signed build;
- no P0/P1 defect, false financial claim, data loss, crash, privacy expansion,
  or missing evidence remains; and
- release notes identify the actual behavior and explicit non-goals.

Wider beta and App Review remain blocked until the existing seven-day internal,
closed-beta, exact-binary metadata/privacy, review, and recovery gates in
`LAUNCH_PLAN.md` and `FIRST_TEST.md` are complete.

## 12. Evidence record template

```text
Test ID:
Result: PASS / FAIL / BLOCKED
Source SHA (40 characters):
PR head / merge-ref / main SHA, if applicable:
Marketing version and build:
CI/TestFlight run and artifact IDs:
IPA SHA-256, if applicable:
Toolchain or device / OS:
Locale; reporting zone; device zone:
Dataset / fixture hash:
Operator and UTC timestamp:
Privacy-safe evidence link:
Observed result and reconciliation:
Defect / waiver decision (waivers cannot weaken financial or privacy invariants):
```
