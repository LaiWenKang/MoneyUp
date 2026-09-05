# MoneyUp budget and UX redesign

The user approved the recommendations in `REDESIGN_REVIEW_2026-09-05.md` before
implementation. Work is on `codex/moneyup-budget-ux-redesign`.

## Financial contract

- New categories use automatic totals. General allocations cover direct spending
  and descendants without their own allocation. Independently budgeted children
  are added once. Existing fixed envelopes retain their cap semantics.
- Uncapped legacy groups migrate prospectively and idempotently. Fixed limits,
  closed revisions, and carry checkpoints are preserved. Affected node records
  and their configuration timeline commit together.
- Monthly overrides are keyed by civil reporting month and currency. A blank
  override removes that month's allocation; Use recurring settings removes the
  override itself. Recurring base-currency settings remain separately available.
- Periods older than recorded budget configuration are explicitly unavailable;
  the UI does not invent historical budgets. Closed months are read-only.
- General rollover includes unallocated descendants but excludes independently
  budgeted children. Unclassified covered spending requires purpose review before
  daily guidance can be shown.
- Moves and merges decompose affected caps into non-overlapping allocations,
  rearrange the hierarchy, and rebuild enclosing caps. The configured total is
  conserved across recurring and relevant month/currency configurations. A merged
  destination becomes automatic; other envelopes retain their mode. Review shows
  configured totals and affected category totals, explicitly before rollover.
- Changes exposing overlapping child rollover inside a fixed total require review
  before mutation. Existing recurring rollover controls remain available. Financial
  records are never changed merely to bypass a conflict.

## Storage and history

SQLCipher schema **10** is a reader compatibility boundary: older builds reject
the database/archive instead of misreading general allocations as fixed caps.
The encrypted table layout is unchanged; previous schemas remain readable.

Category metadata and hierarchy changes now share one validation and SQL transaction.
Reassignment retains entry/posting identities, amounts, dates, notes, attachments,
encrypted revisions and lifecycle audits. Changed ancestor budgets, pins, defaults
and split-draft references are included. An unused category may have budget settings;
deletion clears saved defaults and empty draft selections safely. Meaningful drafts
and financial/planning references require reassignment or dependency review.

## Interaction and presentation

- Month navigation, searchable currency selection, main category headings and
  indented children share a coherent resolved budget snapshot.
- An interactive composition chart uses non-overlapping root totals, exact
  accessible values, a bounded Other group and budget-edit actions.
- Mode conversion preserves the configured total when feasible and previews the
  result. Recurring settings and monthly overrides have distinct labels.
- Category management is a searchable outline with visible edit, add-child, merge
  and delete menus, plus archive/restore controls.
- History has labeled Filter/Clear filters, active counts and separate search
  clearing. Parent filters include descendants; chart presets preserve exact scope.
- Budget/category sheets protect unsaved dismissal and provide keyboard Done.
  Quick Log focus scrolling follows the shared motion policy.
- Encrypted display preferences offer global and independent category guidance,
  illustration and Today-chart visibility, and additional motion reduction.
  Changes apply optimistically, serialize, revert on failure, and drain before lock.
  They never change financial calculations; parent visibility does not govern children.
- System Reduce Motion always wins. Exact values update immediately and respect
  glance privacy in editors and chart annotations. New UI copy is bilingual.

## Verification record

- Local Swift core compilation, app/test syntax checks and repository static gates
  pass at the current development checkpoint. Local XCTest/iOS execution requires
  Xcode, which is not installed on this Mac.
- A standalone Swift harness passed **540 merges and 519 moves**, checking
  independently constructed SGD 275 / USD 25 allocations in mixed hierarchies.
- The local validator suite executed 65 tests successfully during development.
- Initial commit `797497f` passed the iOS build and 582 app-target tests, plus the
  simulator performance job, in CI run `33962599596`. Package-test literal errors
  and an alert-owner source-check failure from that run were subsequently fixed.
- The expanded candidate adds domain, migration, persistence, preference, hierarchy
  and filter regressions. CI exports native SwiftUI render attachments for visual QA.

Latest-candidate CI and native visual review remain pending during validation.
No main merge, signing, TestFlight upload or physical-device acceptance is claimed.

The architecture validator's exact inventories were refreshed only for UserProfile's
two initializers (encrypted display defaults) and Quick Log's view body (motion
routing). On-device model input/output and authority boundaries remain unchanged;
their independent mutation checks remain enabled.
