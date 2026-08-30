# Explainable Capture Intelligence EPCC Record

Date: 29 August 2026

This is the evidence record for `codex/advanced-intelligence-epcc`. It records
what was inspected, why this slice was selected, the validation boundary, and
the checks that still require physical iPhones or exact release binaries. It
does not promote a release or replace the 97-row Golden requirement matrix.

## Explore baseline

| Item | Recorded evidence |
|---|---|
| Approved baseline | `main` at `ff272da89de9f4e3cb9c44d4abd27deae7d2b338`; fetched again before the final review and unchanged |
| Scope branch | Existing `codex/advanced-intelligence-epcc`, whose merge base is the approved baseline; no duplicate scope branch or pull request existed |
| Baseline CI | Main CI run 163 passed 301 core/persistence tests, 237 app tests, and the app/widget Simulator build; TestFlight run 20 validated and uploaded 0.6.0 (1020.1) from the same SHA. Neither result validates this later branch. |
| Review host | Linux 6.18.35 x86_64, Git 2.51.1, Python 3.12.13 |
| Unavailable locally | `swift`, `xcodebuild`, `xcrun`, Simulator, and `xcresulttool` are absent after direct command lookup; exact Swift and app execution is delegated to the pinned macOS CI jobs |
| Project toolchain | Swift 6, strict concurrency, warnings as errors, iOS 18, Xcode 16.4 build 16F6 / iPhoneSimulator SDK 18.5 in CI |
| Dependency boundary | One pinned runtime package: SQLCipher.swift revision `f879fffaaa3ad3541a77830daad4a28726dfa927`; this branch adds none |
| Persistence boundary | Actor-isolated SQLCipher schema 6, independently validated records and normalized indexes; this branch changes no collection, schema, migration, archive, Keychain, entitlement, or bundle identity |

The review covered the five permanent tabs and routing, Quick Log and its
encrypted draft, locked capture, History paging/filtering, Today guidance,
Plan/schedules/goals, Assets/investments/rates, onboarding, Settings/Data
Safety, widget/App Group snapshot, App Intents/URLs, OCR and attachment
sanitization, import/export, archive/restore, lock/background lifecycle,
`AppModel` mutation barriers, the immutable balanced ledger, persistence
migrations/indexes/quarantine, tests, workflows, dependencies, licenses,
entitlements, manifests, localization, and release documentation.

### Product sources and authority resolution

| Supplied source | SHA-256 | Treatment |
|---|---|---|
| `MoneyUp_Golden_PRD_v1.0_2026-08-26(1).docx` | `c5d77d743bf086fc6e040bf567cfa3f4cd57bb16dfaab49d8d8b88200a8351f0` | Controlling product source. The supplied external label calls it v1.1 in one place, but its title/content say v1.0 effective 26 August 2026. |
| `MoneyUp-0.4.0-Audit(1).pdf` (22 pages) | `605c66e34c9b2e4300ce454adf0ce5cd3f6a4553d962de6ceb78eb4fff523b43` | Diagnostic history; current code was rechecked rather than assuming historical line numbers or closure. |
| `MoneyUp-PRD-v1.1.pdf` (34 pages) | `821692f4a8f3505aa46e78b434abe88412d93e6b6b5f84012bdde299d9dbd65f` | Earlier context only where compatible with the controlling source. |

Material conflicts were resolved as follows:

- The earlier PRD's CloudKit sync scope is superseded by the Golden local-only
  boundary and remains deferred pending a new authorization, privacy,
  recovery, and product decision.
- The earlier StoreKit purchase scope is superseded by the Golden first-public-
  version-free decision.
- The 0.4.0 audit's four-tab recommendation is superseded by the Golden and
  current five-tab contract.
- The later accepted adaptive soft-green identity and Flexible Today product
  decisions supersede the Golden presentation names/colors without weakening
  its accounting, privacy, accessibility, or unavailable-state invariants.

### Baseline commands and result

```text
git fetch origin main codex/advanced-intelligence-epcc --prune
git merge-base HEAD origin/main
  ff272da89de9f4e3cb9c44d4abd27deae7d2b338

git diff --check
  pass
python3 -m py_compile Scripts/*.py
  pass
python3 Scripts/validate_release_assets.py
  pass: 901 bilingual baseline strings, offline boundary, manifests,
  assets, deterministic 10,000-entry fixture, and release workflows
```

## Capability and risk map

| Rank | Capability or risk | Value / trust impact | Privacy, scale, and maintenance decision |
|---:|---|---|---|
| 1 | Ambiguous or weak Smart Entry/receipt fields can waste time or create wrong-money capture | Very high daily value; high correctness risk | Use deterministic field evidence and confidence; low confidence never prefills; manual entry and existing Save remain authoritative |
| 2 | Repeated capture can create a valid but accidental duplicate | High trust and cleanup cost | Advisory only, using exact Decimal/currency/directed-account movement before softer evidence; never merge, delete, or block Save anyway |
| 3 | A stale scan/suggestion can cross lock, restore, account, kind, or rapid-action boundaries | Critical privacy/stability risk | Generation and journal/account projection checks; cancel stale work; keep parsing off the main actor; retain no OCR text |
| 4 | Latin substring matching and impossible civil dates can misclassify intent or invent an amount | High capture-correctness risk | Unicode word boundaries for Latin, intentional CJK substring matching, and fail-closed explicit-date handling |
| 5 | The widget's App Group `UserDefaults` use lacked a target-scoped privacy manifest | Release-compliance and transparency risk | Add a widget-only manifest with `1C8F.1`; require app and widget manifests in source and built-bundle validators |
| 6 | Full-book suggestions/duplicates are incomplete when a match is older than the current 80-entry projection | Medium current value; high database/index risk if improvised | Defer issue #27 until exact SQLCipher query contracts, indexes, debounce/cancellation, explainability, and performance acceptance are approved |
| 7 | Persistent learning, recurring/anomaly models, and predictive guidance | Potential value but higher migration, false-positive, and long-term maintenance burden | Do not add opaque or inert state in this slice. Existing exact Today/budget/schedule/stale-price/missing-rate guidance remains the proactive foundation. |

No unresolved P0/P1 accounting, privacy, recovery, or migration source defect
was found in the selected path. Physical and exact-binary evidence remains a
release gate, not an implied pass.

## Plan and selected vertical slice

### Outcome

Make routine capture faster and safer without a new navigation surface,
persisted model, network dependency, or ledger path. Success means suggestions
are useful when evidence is strong, weak results are clearly reviewable,
duplicate risk is inspectable before Save, every path retains immediate manual
fallback, and Save/Undo/revision behavior remains unchanged.

### Architecture and data flow

1. Smart Entry or on-device Vision produces an editable `TransactionDraft`.
2. Pure `MoneyUpCore` parsers/scorers derive ranked field candidates and
   semantic evidence from immutable inputs.
3. Quick Log applies only policy-approved values to still-untouched fields and
   presents every candidate/evidence band for review.
4. Before interactive Save, a pure duplicate detector compares the immutable
   query with the current valid recent projection. Exact Decimal, currency, and
   directed ledger movement are mandatory.
5. Review routes to the attributed History day; cancel changes nothing; Save
   anyway rechecks an opaque query fingerprint and uses the existing atomic
   AppModel/SQLCipher commit, draft deletion, feedback, and Undo path.

The receipt path bounds input to 160 header/footer lines and 512 UTF-8 bytes per
line, parses in a detached task, and checks store generation plus projection
revision before publication. Vision input, OCR lines, scores, and suggestion
profiles are not persisted. An image reaches SQLCipher only through the
existing explicit retention control after orientation, size, and metadata
sanitization.

### Requirement and acceptance scope

| Slice | Golden anchors | Automated evidence | Target / recovery |
|---|---|---|---|
| Explainable recent-history suggestions | LOG-02, LOG-04, LOG-07, DAT-09, SEC-01, SEC-08 | Determinism, confidence thresholds, payee boundaries, currency/kind/role filtering, split ambiguity, stale-field policy | At most 80 current valid entries; high payee-specific confidence requires 3 supporting entries and at least 75%; removing UI/scorer code touches no stored data |
| Receipt review quality and latency | LOG-08, DAT-09, SEC-03, SEC-06, QA-02 | Field scoring/evidence, OCR confidence caps, impossible civil/DST times, pathological input bound, cancellation and stale-generation/account tests | Post-Vision parser physical p95 below 100 ms; Vision-to-review p95 below 4 s; low confidence never prefills; failure/cancel leaves manual entry usable |
| Duplicate advisory | LOG-06, DAT-03, DAT-09, SEC-08 | Expense/income/refund/transfer/foreign-transfer exact movement, JPY/KWD/BTC precision, source replay, stable order/fingerprint, History routing | Recent compute physical p95 below 50 ms; zero tolerated exact-movement/currency false matches in the automated matrix; Cancel/Review/Save anyway and Undo remain available |
| Parser correctness | LOG-07, DAT-03 | Unicode Latin boundaries, CJK substrings, locale decimals, explicit-date ambiguity/impossibility/leap-year tests | Pure rollback: remove parser change; no data rewrite or migration |
| Target-scoped privacy manifests | SEC-01, SEC-07, SEC-09, QA-07 | Source validator requires exact app/widget reasons; built-bundle validator requires both resources | No runtime behavior or data change; exact archive privacy report remains a manual release check |

### Required states

- Loading: bounded scan progress with immediate editable manual fields.
- Empty/unavailable: no suggestion is equivalent to no change; the user can
  type normally.
- Locked/background/cancelled: cancel scan, discard unsaved image bytes, and
  suppress stale results; the encrypted text draft follows the existing lock
  lifecycle.
- Low confidence: show candidate and reason, never prefill or auto-save.
- Changed context: discard incompatible receipt suggestions and explain why.
- Duplicate: Review History, cancel, or explicitly Save anyway.
- Failure: localized safe error without raw OCR/system diagnostics; no partial
  transaction or attachment write.
- Recovery/rollback: no schema or archive migration; all commits retain atomic
  existing Save/Edit/Undo/restore semantics.

### Non-goals

Persistent preference state, Core ML, remote inference, receipt line-item
splits, full-book intelligence queries, recurring/anomaly discovery, automated
schedule creation, investment/tax advice, and a chat surface are deliberately
excluded. They need separate false-positive, persistence/migration/reset,
energy, and physical-acceptance designs.

## Code review impact

The branch adds pure protocol-independent capture intelligence to
`MoneyUpCore`, integrates it into the existing Quick Log form, carries aggregate
Vision confidence without retaining OCR text, bounds/cancels scan work, hardens
schedule publication against an await-invalidated array index, adds bilingual
and accessible review copy, and adds app/widget target-scoped privacy-manifest
checks. It changes no money representation, account semantics, entry factory,
database write, schema version, archive format, migration, identity, Keychain
namespace, App Group, entitlement, or deployment target.

## Validation record

The exact reviewed candidate passed the pinned macOS workflow with Swift 6
warnings as errors: 345 core/persistence tests, 243 app tests, and the Release
app plus embedded widget build. The workflow also produced coverage and proved
that both target-scoped privacy manifests reached their built bundles. The
following local checks pass on the current working tree:

Strict review run 173 first passed all core/persistence tests but stopped at
the Release app compile because a line-broken range operator in the new bounded
confidence helper was not accepted by Swift 6. The next commit introduced an
explicit `suffixStart` bound. Run 176 then passed that Release app/widget build
but the app-model test target compile rejected a concurrently captured mutable
confidence fixture under Swift 6. The next commit freezes that fixture as an
immutable value before the `@Sendable` recognizer closure and repeats the entire
workflow; neither failed run is cited as passing candidate evidence.

```text
git diff --check
python3 -m py_compile Scripts/*.py
python3 Scripts/validate_release_assets.py
  pass: 938 bilingual strings; literal localization references; offline
  runtime boundary; exact app/widget privacy reasons; assets; docs; fixture;
  signing and CI/TestFlight workflow structure
```

Static size delta and exact test counts are recorded at final handoff. No local
Xcode, Simulator, memory, CPU, energy, binary-size, screenshot, network-capture,
upgrade, restore, or physical accessibility result is claimed from this Linux
host or from hosted Simulator execution.

## Open evidence and ownership

- Any commit after the recorded exact-head pass must repeat the pinned Swift 6
  warnings-as-errors tests and Release app/embedded-widget build before merge.
- Oldest/current physical iPhones must execute issue #26 and the capture
  procedure in `LAUNCH_PLAN.md`, including 20 bilingual receipt/screenshot
  samples, p50/p95 latency, accuracy/fallback counts, lock/background races,
  VoiceOver, largest Dynamic Type, Reduce Motion, light/dark mode, and
  screenshots.
- The Golden 10,000-entry/20-schedule p95, memory, CPU, energy, storage,
  binary-size, exact-binary privacy report/network observation, in-place
  upgrade, and clean restore gates remain open for the release owner/device
  matrix. Source tests cannot close them.
- Issue #27 owns the future full-book encrypted-query design. Implementing it
  without its product/SQLCipher amendment is not authorized by this slice.
