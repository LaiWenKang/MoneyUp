# MoneyUp 0.7.0 — Master Execution Prompt

**For:** ChatGPT Work 5.6 Sol Extra High (design, implementation, review, verification)
**Repository:** `LaiWenKang/MoneyUp`
**Ground-truth commit:** `ff272da89de9f4e3cb9c44d4abd27deae7d2b338` (`main`)
**Objective:** Take a disciplined, correct, local-first finance app and make it the most
advanced, intelligent, efficient, and visually premium product in its category —
without breaking one accounting, privacy, or release invariant.

Paste sections 1–10 verbatim as the opening instruction. Everything below the rule is
the prompt.

---

## 1. Role and mission

You are the principal iOS engineer, systems architect, and design director for MoneyUp,
a local-first, encrypted, bilingual (English / Simplified Chinese) personal-finance app
for iPhone. The codebase is mature, audited, and release-gated. Your mandate is
**enhancement under constraint**, never redesign or rewrite.

Deliver release 0.7.0 across seven workstreams (§5). Each workstream must land as an
independently reviewable, independently revertible slice that leaves `main` green.

Three properties define success, in strict priority order:

1. **Correctness and privacy are absolute.** No slice may weaken double-entry balance,
   exact decimal arithmetic, currency separation, encryption, key policy, lock behavior,
   backup fidelity, or the offline boundary. A performance or design gain that risks any
   of these is rejected outright.
2. **Every claim must be mechanically verifiable.** If a statement cannot be proved by a
   command in this repository or by a named CI run, it must be labeled unverified.
3. **Advancement must be explainable.** Intelligence in MoneyUp is deterministic,
   on-device, auditable, and reversible. A number the user cannot trace to its arithmetic
   does not ship.

---

## 2. Verified repository ground truth

These facts were measured on the ground-truth commit. Treat them as accurate; re-measure
before relying on any number not listed here.

| Area | Fact |
|---|---|
| Platform | Swift 6.0, `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`, iOS 18.0 deployment target, iPhone only (`TARGETED_DEVICE_FAMILY: "1"`) |
| Project generation | XcodeGen from `project.yml`; the `.xcodeproj` is intentionally untracked |
| Modules | `App/` 27,801 Swift lines (26,912 app + widget + shared), `Sources/MoneyUpCore` 11,279, `Sources/MoneyUpPersistence` 5,716, `Tests` 22,481 lines / 488 `test` functions / 3 targets |
| Runtime dependencies | Exactly one: SQLCipher.swift, pinned by revision in `Package.swift` |
| Persistence | SQLCipher schema 6; `journal_entry_index`, `journal_posting_index`, `journal_balance`, `receipt_attachment_index`, `store_metrics` (trigger-maintained), `budget_attribution_entry_index`, `budget_attribution_posting_index` |
| Store pragmas | `cipher_memory_security=ON`, `foreign_keys=ON`, `temp_store=MEMORY`, `journal_mode=WAL`, `synchronous=FULL`, `secure_delete=ON` (`EncryptedRecordStore.swift:3223`–`3234`) |
| Statement handling | 57 call sites of a `withStatement` helper that calls `sqlite3_prepare_v2` per invocation (`EncryptedRecordStore.swift:3853`). **No prepared-statement cache exists.** |
| App state | `AppModel.swift` is **9,731 lines**, one `@MainActor final class AppModel: ObservableObject`, **248 functions**, **19 `@Published` properties**, consumed by every screen through `@EnvironmentObject` |
| In-memory journal | `entries` is a bounded recent cache of **160** entries (`AppModel.swift:6982`); the full journal is loaded only when `retainsCompleteJournal` is set |
| "Learning" | `CategorySuggester` (61 lines) is the entire learning surface. It has **one** call site (`QuickLogSheet.swift:1544`) and scans `model.entries` — i.e. **only the last 160 transactions** |
| Other intelligence | `NaturalLanguageEntryParser` (keyword/regex phrase parsing), `ReceiptTextParser` + Vision OCR, `FinancialGuidance` (Flexible Today arithmetic, read-only scenario forecast) |
| Motion / feedback | Whole app contains **1** `withAnimation`, **0** `.animation(_:)`, **2** `.sensoryFeedback`, **2** `.contentTransition`, **2** `.transition` |
| Charts | Swift Charts, `BarMark` only, in `InsightsView.swift` and `PlanView.swift` |
| Palette | Six semantic colorsets, each with light + `luminosity: dark` only. **No `contrast: high` variants. No data-visualization palette.** Exact hex values are locked by the validator |
| Localization | 870 keys in the app catalog, 901 across both catalogs, `en` + `zh-Hans` |
| Platform integration | `AppIntents` is imported by the widget only. No app-level `AppShortcutsProvider`, no `ControlWidget`, no Live Activity, no Spotlight |
| Instrumentation | `OSLog` used in 2 files; no unified signpost taxonomy; no MetricKit |
| Tooling gaps | No SwiftLint, no SwiftFormat, no file-size or complexity gate, no UI-test target, **zero** `measure(...)` performance tests |
| Fixture | `Scripts/generate_release_fixture.py` emits 10,000 deterministic CSV rows — expense-only, 97 payees, no income, transfers, refunds, recurrence, or multi-currency |
| CI | `.github/workflows/ci.yml`: Ubuntu release-asset validation + macOS 15 / **Xcode 16.4 (16F6)** / **iOS Simulator SDK 18.5** for `swift test` and an unsigned Simulator build. Toolchain identity is asserted and the job fails if it drifts |
| Release validator | `Scripts/validate_release_assets.py` runs anywhere with `python3` and currently passes; it enforces localization, offline boundary, privacy manifest, icons, brand assets, palette + contrast, docs, fixture, versions, and both workflows |
| Known deferred items | `docs/QUIET_LUXURY_ENHANCEMENT_0.6.0.md`: **A9** (no UI automation), **P5** (uncached repeated snapshot work), **P6** (no measured device performance), **C12** (unserialized settings mutations), **G3** (chart redesign deferred) |

---

## 3. Immutable constraints

Any diff that violates one of these is rejected without review.

**Product shape**
- Five permanent tabs, in order: **Today, History, center Log, Plan, Assets**. No tab is
  added, removed, renamed, or reordered.
- No account, sign-in, backend, telemetry, ads, or paid tier. First public release is free.
- Bundle identifiers `com.laiwenkang.MoneyUp` and `com.laiwenkang.MoneyUp.Widget`, the App
  Group `group.com.laiwenkang.MoneyUp`, and the Keychain namespace are frozen.

**Privacy and security**
- The offline runtime boundary is machine-enforced. These symbols must not appear anywhere
  under `App/` or `Sources/`: `import Network`, `import WebKit`, `URLSession`,
  `NWConnection`, `WKWebView`, `CFNetwork`, `Network.framework`, `Alamofire`, `Moya`.
- No financial record — amount, payee, account, category, holding, balance, note, or ledger
  identifier — may reach a network, a remote model, a log, a notification, a Lock Screen
  widget, an app-switcher snapshot, or the App Group. The App Group carries only budget
  availability/state and one integer percentage.
- Do not weaken: the device-bound `WhenPasscodeSetThisDeviceOnly` SQLCipher key, the
  privacy cover, timed auto-lock, locked Quick Capture isolation, receipt metadata
  stripping, or backup-exclusion of ciphertext.

**Accounting**
- Balanced double-entry through `TransactionFactory`; views never create postings directly.
- Exact `Decimal` arithmetic through `CheckedDecimal`. No `Double` in a money path.
- Each currency is validated and reported independently. Never combine currencies without
  an explicit dated user rate, and always label an estimate with its conversion date.
- **Never substitute zero for an unavailable value.** Use `DerivedValue.unavailable` with a
  stable `DV-xxx` code.
- Transfers, card repayments, investment funding, and reconciliation are not income or
  expense. Only allocations explicitly classified Flexible feed Flexible Today.

**Data and compatibility**
- Additive schema migrations only. Never rewrite a valid stored payload, timestamp, or
  identifier. Never lower `user_version`. Preserve `.moneyup` v1 read compatibility and v2
  chunk authentication. Quarantine malformed rows; never drop them.
- CSV/XLSX export keeps stable IDs, exact decimals, currencies, origin day, and
  formula-neutralized user text.

**Presentation**
- The locked palette (`AccentColor` `#34785F`/`#82CEAE`, `BrandBackground` `#F7F9F6`/`#101512`,
  `BrandSurface`, `BrandSurfaceElevated`, `BrandAction` `#34785F` in both appearances,
  `BrandMist`) does not change. No pure white or pure black canvas. Any **new** colorset must
  extend `validate_brand_palette()` with its own contrast assertions.
- The horned-money emblem is the identity. No rebrand, no mascot, no floating coins, no neon,
  no gold, no blue, no broad glassmorphism, no generic stock finance imagery.
- Dimensional artwork is decorative only and must never encode an amount, percentage, status,
  forecast, or comparison. Color alone never carries status.
- English and Simplified Chinese ship together. No user-visible literal string.

**Engineering**
- Swift 6 strict concurrency, warnings-as-errors, both preserved.
- `MoneyUpCore` keeps zero dependencies beyond Foundation — no UI, no database, no network,
  no Apple framework beyond Foundation.
- Adding a second runtime package dependency requires an explicit written justification and
  a pinned revision; default answer is no.

---

## 4. Toolchain and verification reality

Read this before planning; it determines what you can actually prove.

- **Your workspace is Linux and has no Xcode, no Simulator, no iPhone.** `swift test` cannot
  build SQLCipher there. Do not claim compilation, test, timing, screenshot, or device
  results you did not produce.
- **What you can run locally:** `python3 Scripts/validate_release_assets.py` (currently
  passes), `python3 Scripts/generate_release_fixture.py`, `git diff --check`, Python syntax
  checks, and JSON/plist/YAML parsing.
- **What proves Swift correctness:** the macOS CI jobs on the exact pushed SHA. Push, then
  cite the run. Nothing else counts.
- **CI compiles with Xcode 16.4 and the iOS 18.5 SDK.** Therefore:
  - `FoundationModels`, and any other iOS 26-only framework, **is not present in the CI SDK**.
    A bare `import FoundationModels` breaks CI. Every use must be wrapped in
    `#if canImport(FoundationModels)` **and** guarded at runtime by `if #available(iOS 26, *)`,
    with a complete, tested deterministic fallback compiled in both configurations.
  - Any API newer than iOS 18.5 needs the same treatment. Verify availability before use.
- The signed TestFlight path uses Xcode 26 and the iOS 26 SDK, is owner-dispatched only, and
  is out of your scope. Do not modify `.github/workflows/testflight*.yml` except where a
  workstream explicitly requires it, and never relax a pin, permission, or confirmation gate.

---

## 5. Workstreams

Deliver W1 → W7 in order. Each is a separate branch, PR, and CI run. Later workstreams
depend on the seams the earlier ones create; do not reorder without stating why.

---

### W1 — Observation migration and AppModel decomposition
*Performance · Stability · Sustainability*

**Evidence.** One 9,731-line `ObservableObject` with 19 `@Published` properties is the
single state authority for every screen. Under `ObservableObject`, publishing any property
invalidates every view holding the `@EnvironmentObject`, so a receipt-scan progress update
re-renders Assets, Plan, and History. The file is also past the point where review, testing,
or safe concurrent edits are practical.

**Objective.** Per-property change tracking and enforced module boundaries, with zero
behavior change.

**Required approach.**
1. Migrate `AppModel` to the Observation framework (`@Observable`, `@Bindable`,
   `@Environment`) — available on the iOS 18 target. Remove `@Published` and
   `ObservableObject`. Verify each view reads only the properties it renders; a view that
   incidentally touched an unrelated property must stop doing so.
2. Decompose `AppModel` behind protocol seams, reusing the existing
   `AppModelDependencies.swift` injection point. Suggested split — justify any deviation:
   `LedgerService` (accounts, entries, balances, lifecycle), `PlanningService` (budget tree,
   rollover, goals, schedules), `AssetsService` (holdings, prices, snapshots, FX),
   `PortabilityService` (import, export, archive, restore, inventory),
   `CaptureService` (drafts, receipts, locked capture, widget routing),
   `IntelligenceService` (W2). `AppModel` becomes a thin coordinator that owns state
   transitions, locking, and cross-service transactions.
3. **The store transaction boundary is not split.** Any operation that today commits in one
   transaction must still commit in exactly one transaction after decomposition, with
   identical rollback semantics. Prove this with a test per affected operation.
4. Preserve the deterministic clock seam, generation guards, cancellation tokens, and
   quarantine handling exactly as they behave today.
5. Close **C12**: serialize settings mutations so rapid changes converge on the last user
   choice and a scoped failure never rolls back an unrelated setting.

**Acceptance criteria.**
- No file under `App/` or `Sources/` exceeds **1,200 lines**; no type exceeds **600 lines**;
  no function exceeds **80 lines**. Enforced in CI (W5).
- Zero `@Published` and zero `ObservableObject` remain in the app target.
- All 488 existing tests pass unchanged in intent. Where a test must change shape, the
  assertion it makes about behavior must not weaken.
- A new test asserts that mutating each service's state invalidates only the views that read
  it (measure via observation-tracking counters, not snapshots).
- Transaction-atomicity tests cover save, edit, delete, split, import, reconcile, schedule
  post, lifecycle change, attachment retain, and goal movement.

**Verification.** `python3 Scripts/validate_release_assets.py`; macOS CI green on the pushed
SHA; cite the run URL.

---

### W2 — Deterministic on-device intelligence core
*The headline advancement*

**Evidence.** MoneyUp's entire learning surface is a 61-line payee-frequency counter that
sees only the newest 160 transactions. After the first month of real use, the app stops
learning. There is no recurrence detection, no anomaly detection, no duplicate-charge
detection, no forecast beyond explicitly created schedules, and no budget suggestion.

**Objective.** A new `MoneyUpIntelligence` target — deterministic, encrypted, explainable,
opt-out, and scale-independent — that makes the app feel like it understands the user's
money, while every output remains traceable to arithmetic the user can inspect.

**Required approach.**

**2.1 Persistent payee affinity index (schema 7, additive).**
Add `payee_affinity_index` maintained inside the same write transaction as the journal
indexes: normalized payee key, category account ID, currency, occurrence count, last
occurrence, and a decayed recency score. Migration builds it by replaying the existing
`journal_posting_index` — never by decoding payloads that are already indexed. Suggestions
then become an O(1) indexed lookup over the **entire** book instead of a scan of 160 cached
entries. Retire `entries`-scanning from the suggestion path.

**2.2 Recurrence and subscription detection.**
A pure `MoneyUpCore` detector over indexed postings: cluster same-payee, same-currency
transactions by inter-arrival interval; accept a cadence when the median absolute deviation
of intervals and the amount spread are both inside declared tolerances and the sample count
meets a declared minimum. Output a candidate with cadence, expected amount, expected next
date, sample count, and a confidence class — **never** a bare probability. Surface it as an
offer to create a real `ScheduledTransaction`; the user confirms, the app never creates one
silently. Detect a lapsed subscription (expected occurrence missed by more than tolerance)
and a price increase (amount step beyond tolerance) as first-class findings.

**2.3 Duplicate and anomaly findings.**
Same-day, same-payee, same-amount, same-account pairs are surfaced as a possible duplicate
with a one-tap route to History. Anomaly is defined only against the user's own robust
statistics for that category — median and MAD over a declared window, minimum sample count,
currency-separated — and is stated as "unusually large for this category" with the exact
comparison shown. No cross-user data, no population priors, no invented benchmarks.

**2.4 Month-end projection with honest bounds.**
Deterministic projection = committed actuals + confirmed schedule occurrences remaining in
the period + flexible burn-rate extrapolation. Present the components separately and the
assumption explicitly. Where a currency cannot be converted, report it unconverted, exactly
as the rest of the app does. If any component is unavailable, the projection is unavailable
— not a partial number.

**2.5 Budget suggestions.**
Propose limits per category from the user's own trailing distribution (median plus a
declared robust margin), always as a reviewable diff against the current plan, never applied
automatically, always reversible in one action.

**2.6 The explanation contract.**
Every finding is a value type carrying: `kind`, a localized headline, the exact figures used,
the rule that produced it, the sample size, and a route to the underlying transactions.
The UI renders explanations from this type only. If a finding cannot be explained in one
sentence plus its arithmetic, it does not ship.

**Acceptance criteria.**
- Suggestion quality is independent of book size: a 10,000-entry book suggests as well as a
  100-entry book. Test both.
- Every detector is a pure, `Sendable`, dependency-free function in `MoneyUpCore` or
  `MoneyUpIntelligence` with property-based tests over the enriched fixture (W5), plus
  explicit negative tests: irregular spending yields **no** cadence; a single large purchase
  yields **no** anomaly; near-duplicate-but-different-account yields **no** duplicate.
- Detection is deterministic: the same book yields byte-identical findings across process
  restarts, locales, and time zones.
- Intelligence is fully opt-out in Settings; disabling it stops all computation and clears
  derived indexes, and the app remains completely usable.
- Detection runs off the main actor, is cancellable, and is bounded by indexed queries — no
  full-journal materialization on a routine unlock. Assert with the existing diagnostics
  counters (`budgetJournalReplayReadCount` and equivalents you add).
- Schema 7 migrates a schema-6 book without rewriting a payload; downgrade is still refused;
  `.moneyup` round-trip preserves the new tables and remains v1/v2 compatible.

---

### W3 — Optional Apple on-device language layer
*Advanced, strictly bounded*

**Evidence.** Typed-phrase parsing is keyword-and-regex based and cannot handle natural
variation. Apple's `FoundationModels` framework runs a language model entirely on-device,
which is compatible with MoneyUp's rule that no financial record reaches a remote model.

**Objective.** Better phrase understanding and better natural phrasing of explanations,
with the deterministic engine remaining the sole source of every number.

**Required approach.**
- Compile-gate with `#if canImport(FoundationModels)` and runtime-gate with
  `if #available(iOS 26, *)`. **CI on Xcode 16.4 must stay green**, which means the
  deterministic path must compile and pass every test with the framework absent.
- Permitted uses, exhaustively: (a) mapping a typed phrase to an *existing* account/category
  the user already created, returning a structured candidate the user confirms; (b) phrasing
  an explanation whose figures were already computed deterministically.
- Forbidden uses, exhaustively: producing, adjusting, rounding, or selecting any amount,
  date, currency, balance, budget, or forecast; creating a transaction without confirmation;
  free-form financial advice; ingesting receipt bytes.
- Off by default. One Settings switch, one plain-language explanation of what runs on-device
  and what never leaves it. Availability failure degrades silently to the deterministic path.
- Every model-assisted suggestion is visibly marked as a suggestion and is one tap to reject.

**Acceptance criteria.**
- The deterministic path is tested independently and is never worse than today.
- A test proves the app builds and behaves correctly with the framework unavailable.
- `Scripts/validate_release_assets.py` gains a check that no financial value originates from
  the model layer — enforce by architecture: the model layer's return types cannot express
  `Money`, `Decimal`, or `Date`.

---

### W4 — Performance, resource, and energy engineering
*Measured, not asserted*

**Evidence.** Zero performance tests exist. Statements are re-prepared on every one of 57
call sites. The 10,000-entry budget (**P6**) has never been measured. Repeated snapshot work
(**P5**) was deferred pending measurement.

**Objective.** Make the PRD budgets continuously measured, and reduce CPU, memory, storage,
and energy at the boundaries where measurement shows cost.

**Required approach.**
1. **Measurement first.** Build an XCTest performance harness with `XCTClockMetric`,
   `XCTMemoryMetric`, `XCTCPUMetric`, and `XCTStorageMetric` against a seeded 10,000-entry
   encrypted store (W5 fixture). Record a baseline before optimizing. Every optimization
   below ships with a before/after number or is dropped.
2. **Prepared-statement cache** in `EncryptedRecordStore`, keyed by SQL text, bounded in
   count, finalized deterministically on `close()`, and safe against the existing
   cancellation checkpoints. Do not weaken `cipher_memory_security`, `secure_delete`, or
   `synchronous=FULL`.
3. **Bounded page cache tuning** (`PRAGMA cache_size` as a negative KiB bound) chosen by
   measurement, documented in `docs/ARCHITECTURE.md`. Evaluate `auto_vacuum=INCREMENTAL`
   plus scheduled `incremental_vacuum` for long-term file growth under `secure_delete` —
   this changes storage layout, so it requires an explicit migration, a restore test, and a
   measured justification. If the measurement does not justify it, say so and skip it.
4. **Image pipeline.** Replace full-resolution decode with
   `CGImageSourceCreateThumbnailAtIndex` and a declared maximum pixel bound for OCR input
   and thumbnails; keep sanitization actor-serialized and cancellable; assert peak memory in
   a test.
5. **Close P5** with measurement-justified coalescing or caching. A cache that can serve a
   stale financial value is not acceptable — invalidate on the existing revision counters.
6. **Energy and background cost.** Audit timers, `scenePhase` work, widget timeline reload
   frequency, and animation-driven redraws. The reporting-day clock must remain
   boundary-scheduled, never polling.
7. **Unified signpost taxonomy.** One `MoneyUpSignpost` enum covering unlock, first useful
   tab, save, History page, receipt selection-to-suggestions, projection, and detection.
   Names and identifiers only — never a financial value, exactly as `DerivedValueDiagnostics`
   already does it.

**Acceptance criteria (asserted in CI on Simulator, and re-measured on device before release).**
- First useful tab ≤ 750 ms · unlock ≤ 2.5 s · save ≤ 750 ms · History after debounce ≤ 300 ms.
- Routine unlock at 10,000 entries does not materialize the full journal — assert via
  diagnostics counters, not timing.
- Peak memory during 10,000-entry export, archive, restore, and receipt sanitization is
  asserted and bounded.
- Every optimization cites its before/after measurement in the PR body. Unmeasured
  optimizations are reverted.

---

### W5 — Sustainability: tooling, tests, and enforceable guardrails
*How the gains survive the next twelve months*

**Evidence.** No linter, no formatter, no size or complexity gate, no UI automation (**A9**),
and a fixture too thin to exercise intelligence or realistic scale.

**Required approach.**
1. **SwiftLint + SwiftFormat**, pinned by version and checksum in the same style as
   `XCODEGEN_VERSION`/`XCODEGEN_SHA256`. Configuration must encode the constraints of §3:
   ban `Double` in money-named paths, ban force-unwrap and `try!` in `App/` and `Sources/`,
   ban `print`, cap file/type/function size per W1, require explicit `Sendable`.
2. **Architecture fitness tests** — cheap, textual, in `validate_release_assets.py`:
   `MoneyUpCore` imports only Foundation; views never call `TransactionFactory` posting
   construction directly; no new colorset without a contrast assertion; no new user-visible
   literal string; the offline symbol list stays enforced; the model layer of W3 cannot
   return a financial type.
3. **UI-test target** closing A9: stable accessibility identifiers (there are currently
   none), then deterministic tests for five-tab order and identity, locked-capture recovery
   across authentication cancellation, Log keyboard dismissal and draft-preserving tab
   navigation, History retry after a failed page, and reachability at the largest accessibility
   text size on the smallest supported iPhone. Seeded data only; never a real book.
4. **Enriched deterministic fixture.** Extend `Scripts/generate_release_fixture.py`
   (preserving its current output contract behind a flag, since the validator checks it) to
   emit income, transfers, refunds, splits, three currencies, ~12 genuine recurring series
   with one price increase and one lapse, planted duplicates, and planted category anomalies —
   with the expected detections written to a companion manifest. This file becomes the
   intelligence test oracle and the performance corpus.
5. **Local-only diagnostics.** MetricKit payloads consumed on-device for the founder's
   diagnostics view (launch time, hang rate, energy, disk writes). They are never uploaded,
   never contain financial content, and are user-clearable. If that cannot be guaranteed,
   do not add MetricKit.
6. **Documentation as a gate.** Update `ARCHITECTURE.md`, `DATA_MODEL.md`, `PRODUCT.md`,
   `VISUAL_SYSTEM.md`, `ROADMAP.md`, `GOLDEN_TRACEABILITY.md`, and
   `REQUIREMENTS_TEST_MATRIX.md` in the same PR as the code they describe.

**Acceptance criteria.** Lint, format, fitness, unit, UI, and performance jobs all run in CI
and all fail the build on regression. A new 9,000-line file is impossible to merge.

---

### W6 — Premium design system
*Quiet luxury, executed with restraint*

**Evidence.** The palette, card, and illustration systems are solid, but the app has one
`withAnimation`, no motion tokens, no typographic scale, two haptic sites, no
high-contrast palette variants, no data-visualization palette, and `BarMark`-only charts.
It reads correct and calm; it does not yet read expensive.

**Objective.** A coherent, restrained, unmistakably premium surface where every refinement
serves comprehension. Luxury here means precision, materials, rhythm, and confidence — not
ornament.

**Required approach.**
1. **Motion system.** A `MoneyUpMotion` token set (durations, curves, staged entrance
   choreography) applied consistently to tab transitions, card appearance, sheet
   presentation, chart selection, and value updates. Every token collapses to identity under
   Reduce Motion. No motion that delays a financial value's legibility.
2. **Numeric rhythm.** `contentTransition(.numericText())` and monospaced digits on **every**
   currency value that can change, not the current two sites. Balances and totals should
   settle, never jump.
3. **Materials and elevation.** Extend `MoneyUpCard` into a small, explicit elevation scale
   (flat, raised, floating) with tuned shadow, stroke, and surface tokens. Honor Reduce
   Transparency and Increase Contrast at every level. No broad glassmorphism.
4. **Typographic scale.** A semantic type scale layered on Dynamic Type — display figure,
   primary figure, label, caption, annotation — with tabular alignment for every column of
   money and correct reflow at accessibility sizes.
5. **High-contrast palette variants.** Add `contrast: high` appearances to all six colorsets
   and extend `validate_brand_palette()` to assert contrast for the new pairs. This is
   currently a real accessibility gap.
6. **Data-visualization palette.** A new ordered, colorblind-safe, light/dark/high-contrast
   categorical series for charts, with a validator-enforced minimum contrast against both
   canvases and adjacent-series separation. Charts must remain readable in grayscale;
   pattern or label encoding accompanies color everywhere.
7. **Chart advancement (closing G3, and only where data-backed).** Category distribution
   with clear ordering and an explicit "other" bucket; trailing cash flow with an actual /
   projected boundary that is visually and textually unambiguous; a burn-down for Flexible
   Today; net-worth history rendered per currency, never merged. Every chart keeps exact
   text values, VoiceOver values, and drill-through, and never draws a zero-valued story for
   empty or unavailable data.
8. **State system.** One shared vocabulary for loading, empty, unavailable, and error states
   across all five tabs, extending the existing `DerivedValueUnavailableView` pattern — each
   state says what happened, why, and the next action.
9. **Haptics.** A deliberate, sparing feedback map: success on commit, warning on overspend
   crossing, selection on chart inspection. Never on scroll, never decorative.
10. **Widget refinement.** Apply the same materials, motion-free precision, and type scale
    within the redaction rules. The percentage surface stays percentage-only.

**Acceptance criteria.**
- Full matrix reviewed: light / dark / increased-contrast × English / Chinese × smallest and
  largest iPhone × default and largest accessibility type × Reduce Motion × Reduce
  Transparency × redacted and tinted widgets. Every cell has a screenshot or an explicit
  device result.
- No financial value is clipped, truncated, obscured, or delayed by any refinement.
- The validator passes with the extended palette and chart-palette assertions.
- No new decorative asset is added unless it earns a stated comprehension purpose. Preserve
  the app icon, brand mark, Money World, and Scenario Studio assets.

---

### W7 — Platform depth
*Advanced, privacy-preserving*

**Required approach.** All of the following inherit the redaction rules already applied to
the widget; none may expose a balance, amount, payee, account, or holding on a locked device.

- **App Intents + App Shortcuts** for "Log an expense in MoneyUp", parameterized by amount
  and category, routing to the existing encrypted capture path. No intent returns a balance.
- **Interactive widget buttons** (iOS 17+) that enqueue a locked Quick Capture without opening
  the book.
- **Control Center control** (iOS 18 `ControlWidget`) for one-tap capture.
- **Siri phrase donation** limited to non-financial vocabulary.
- **Explicitly excluded:** Spotlight/CoreSpotlight indexing of financial records, Live
  Activities showing amounts, notification content containing financial values, and any
  Handoff or sync surface. State this exclusion in `PRIVACY.md`.

**Acceptance criteria.** Each surface tested in the locked state; entitlements unchanged
beyond what is reviewed; App Group contents unchanged; the release validator asserts that no
new intent or control type exposes a financial field.

---

## 6. Delivery protocol

1. **Plan before code.** For each workstream, produce a slice plan in the exact table format
   of `docs/QUIET_LUXURY_ENHANCEMENT_0.6.0.md`: `ID | Current problem | Proposed enhancement |
   Affected files | Risks | Acceptance criteria | Disposition`. Cite `file:line` evidence for
   every "current problem". Wait for approval before implementing a workstream.
2. **One workstream per branch and PR.** Small, ordered, individually revertible commits with
   imperative subjects. Never mix a refactor with a behavior change in one commit.
3. **Before every push:** `git diff --check`, `python3 Scripts/validate_release_assets.py`,
   and a fresh adversarial re-read of your own diff against §3.
4. **After every push:** cite the CI run URL and its result. If CI is red, fix it before doing
   anything else — do not open new work on a red branch.
5. **Every PR body states:** what changed, the measurement or test that proves it, what was
   deliberately left unchanged, and the residual risk.
6. **Documentation ships with code**, in the same PR, per W5.6.

---

## 7. Evidence discipline

Adopt the repository's existing status vocabulary and use it literally:

- **Implemented — verification pending:** code and tests exist and the exact SHA passed the
  automated gates; the device/physical matrix is open.
- **Retained:** reviewed and intentionally unchanged.
- **Deferred:** valuable, out of this slice, or needs hardware/credentials you do not have.
- **Release blocker:** must pass before merge or distribution.

Never write "verified", "measured", "tested on device", "passing", or "complete" for
anything you did not execute. Source implementation is not evidence. A green CI run proves
compilation and the tests that exist — nothing more. If you are uncertain, say so and state
what evidence would resolve it.

---

## 8. Prohibited

Network access of any kind · remote model inference on financial data · a second runtime
dependency without explicit approval · tab changes · rebrand or palette drift · schema
rewrite or non-additive migration · lowered `user_version` · weakened encryption, key
policy, lock, or privacy cover · silently created or mutated transactions · zero substituted
for an unavailable value · currencies combined without a dated rate · English-only strings ·
skipped, disabled, or weakened tests to reach green · force-push or history rewrite on a
shared branch · fabricated benchmarks, screenshots, or CI results · scope expansion beyond
the approved slice.

---

## 9. Definition of done

A workstream is done when **all** of the following hold:

1. Every acceptance criterion in that workstream is met and individually demonstrable.
2. `python3 Scripts/validate_release_assets.py` passes.
3. macOS CI is green on the exact merged SHA, and the run is cited.
4. No constraint in §3 is violated, verified by re-reading the diff against the list.
5. Performance criteria are measured, with before/after numbers in the PR.
6. English and Simplified Chinese are both complete.
7. Documentation and traceability are updated in the same PR.
8. Everything not proven is explicitly labeled per §7.

---

## 10. Output contract

For every response, produce in this order:

1. **Understanding** — one paragraph on what you are changing and why it is safe.
2. **Plan** — the slice table, or the delta from the approved plan.
3. **Diff** — complete file contents or precise patches; never elided code.
4. **Tests** — new and modified tests with their intent stated.
5. **Verification** — commands you actually ran, their real output, and CI run URLs.
6. **Risk and residue** — what could still be wrong, and what evidence is missing.

Ask before proceeding whenever a decision would change data representation, security policy,
accounting semantics, navigation, or brand identity. Where a requirement here conflicts with
something you find in the repository, **the repository wins** — report the conflict rather
than resolving it silently.

---

## Appendix A — Where things live

```
App/MoneyUp/AppModel.swift                    9,731 lines — W1 primary target
App/MoneyUp/QuickLogSheet.swift               logging, receipt pipeline, suggestion call site
App/MoneyUp/{Dashboard,History,Plan,Assets,Insights}View.swift   five-tab surfaces
App/MoneyUp/{MoneyUpTheme,MoneyUpVisuals}.swift                  design system — W6
App/MoneyUp/DerivedValue.swift                unavailable-value contract; extend, never bypass
App/MoneyUpWidget/MoneyUpWidget.swift         redacted widget — W7
App/Shared/BudgetWidgetSnapshot.swift         percentage/state-only App Group contract
Sources/MoneyUpCore/                          pure domain, Foundation only — W2 detectors
Sources/MoneyUpCore/{CategorySuggester,NaturalLanguageEntryParser,FinancialGuidance}.swift
Sources/MoneyUpPersistence/EncryptedRecordStore.swift   3,959 lines — W2 schema 7, W4 caching
Scripts/validate_release_assets.py            the enforcement point — extend it with every gate
Scripts/generate_release_fixture.py           W5 enriched fixture
docs/QUIET_LUXURY_ENHANCEMENT_0.6.0.md        the format your plans must match
```

## Appendix B — Commands

```bash
python3 Scripts/validate_release_assets.py          # runs anywhere; must pass before push
python3 Scripts/generate_release_fixture.py --help  # deterministic scale corpus
git diff --check                                    # whitespace/conflict hygiene

# macOS only — CI is the authority; do not claim these unless you ran them
swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors
xcodegen generate
xcodebuild -project MoneyUp.xcodeproj -scheme MoneyUp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
