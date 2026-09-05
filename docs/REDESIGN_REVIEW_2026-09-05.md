# MoneyUp redesign review — 5 September 2026

Status: initial proposal, subsequently approved by the user. See
`BUDGET_REDESIGN_2026-09-05.md` for implementation refinements and verification.
Source inspected: `5b0ef2078ff2c15d76145ab3cdd9411ca9727336` (`main`).
The user reports the latest build; the exact installed binary is not established.

## Recommendation

Retain SwiftUI, the exact-decimal financial core, encrypted storage, journal revisions,
and local-only privacy model. Redesign the budget contract and its editors, category
lifecycle, discoverability, and presentation as a coherent change. A complete rewrite
would add migration and financial-regression exposure without resolving the central
product ambiguity: what a parent budget means when children also have budgets.

This review covers source paths for Today, Plan, category management, Log, History,
Settings, Assets, and the simulator, plus relevant domain and persistence boundaries.
It is an initial cross-app audit, not a claim that every screen or device interaction
has been tested. Receipt capture, allowances, loans, onboarding, imports, exports,
recovery, and full accessibility require the journey matrix below.

## Fundamental user needs and invariants

1. Record what happened without having to understand accounting or create an
   unnecessary subcategory.
2. Know which period and currency a number describes, why it changed, and whether
   it is actual, budgeted, reserved, estimated, or hypothetical.
3. Organize categories without losing money, history, drafts, or references.
4. Control guidance and visual density without changing financial meaning.
5. Move freely and recover from mistakes; optional sophistication stays discoverable.

Hard invariants:

- Balanced journal entries remain balanced per currency. Transfers are not spending.
- Roll up each direct posting once per ancestor; do not sum overlapping subtotals.
- Use exact money arithmetic. Convert to floating point only for drawing geometry.
- Resolve period, reporting timezone, currency, configuration revision, journal
  revision, and reporting instant coherently across totals and warnings.
- Closed-period history and rollover retain their recorded interpretation unless an
  explicit correction is reviewed. Hierarchy reorganization is not permission to
  rewrite every past budget.
- Hidden guidance remains part of the underlying calculation. Presentation
  preferences cannot remove a budget, transaction, commitment, or overspend.
- A simulated scenario is separate from actual data and cannot save a transaction.
- Financial identifiers and drafts remain in encrypted app storage; they are not
  added to unencrypted presentation defaults or the widget's shared container.
- Commit related data, references, revisions, and audits atomically; reject stale
  plans and leave the original book intact on failure.

## Findings with evidence

### 1. Budget limits and spending use different hierarchy semantics

`Sources/MoneyUpCore/BudgetTree.swift` explicitly defines an entered parent limit as
a cap. `rolledUpSpending` adds spending through all ancestors, but `progress` uses
only the node's own limit or rollover effective limit. An unlimited parent receives
no derived budget. `planSummary` counts only topmost limited nodes.

Using the actual core source, a standalone Swift executable produced:

| Parent cap | Groceries | Dining | Parent displayed limit | Overall plan limit |
|---:|---:|---:|---:|---:|
| None | SGD 300 | SGD 200 | None | SGD 500 |
| None | SGD 400 | SGD 200 | None | SGD 600 |
| SGD 500 | SGD 300 | SGD 200 | SGD 500 | SGD 500 |
| SGD 500 | SGD 400 | SGD 200 | SGD 500 | SGD 500 |

This explains the automatic-rollup complaint without assuming a cache failure.
`AppModel.budgetNodes` advances the budget revision and clears the tree cache;
`AppModelTests.testBudgetTreeCacheReusesAndInvalidatesByBudgetRevisionAndProfile`
already checks this path. Mounted-view refresh and persistent lazy projections still
need runtime verification. Adding more refresh calls alone will not change the
observed arithmetic contract.

Direct parent logging already exists: `AppModel.expenseCategories` includes active
parents, and `BudgetTree.rolledUpSpending` accepts direct postings at any node. The
design must make this capability obvious and preserve it.

### 2. Merge arithmetic conflicts with the cap model

`AppModelLedgerValidation.budgetsAfterReassigningCategoryHierarchy` adds source and
target limits. The endpoint validator permits same-kind, same-currency ancestor and
descendant targets. A SGD 200 child merged into its SGD 500 parent therefore uses
an amount-combining rule that produces SGD 700, even though the child was already
inside the SGD 500 cap. The standalone probe demonstrates the amount change using
the actual BudgetTree and the helper's addition operation; it is not an end-to-end
app merge test.

The repair must compare the non-overlapping allocation set before and after a
merge, including ancestor/descendant and shared-ancestor cases. Simple addition is
safe only when the source allocations are disjoint under the chosen model.

### 3. Delete is hidden by policy and navigation

`LedgerLifecycleViews.CategoryManagementSheet` shows Delete unused only when
`impact.isUnused` is true. `AppModel.LedgerItemLifecycleImpact.isUnused` also requires
no budget configuration, child, default, draft, schedule, holding, or transaction
reference, and a current reference-count projection. Even a zero-transaction category
with a configured budget or purpose fails this definition.

Reassignment controls disappear when no compatible target exists. The management
list primarily exposes adding children and opening another sheet. Budget row taps
open a separate budget-only editor; category management is under the ellipsis menu
or Settings. The visible result is an action that appears not to exist.

Current safeguards must be replaced with understandable resolution steps, not removed.
Some planning references also block reassignment after a destination has been offered
(`AppModelQuarantine.validatedLedgerReassignmentEndpoints`). Show these dependencies
and a supported resolution before the final confirmation.

### 4. One category Save spans two independent commits

`CategoryManagementSheet.saveMetadata` first awaits `updateCategoryMetadata`, then
separately awaits `reparentCategory`. Each operation has its own atomic boundary.
If the second fails or the book locks between them, the screen can report an error
after the name/budget was already saved. Replace this with one validated category-edit
command covering metadata and parent changes. Fault-injection tests must prove that
either all changes commit or none do.

### 5. Daily guidance is not independently optional

`DashboardContent.headline` always renders the flexible guidance as a hero or summary.
`UserProfile` has pin and widget preferences but no global/category guidance visibility
policy. Plan has a display cadence and a separate per-budget pacing setting, and
pinned categories calculate daily/weekly spreads regardless of purpose. These
existing controls are not independent show/hide preferences.

Use a global visibility gate plus explicit per-node choices. Global Off hides all
daily guidance but preserves every node choice for the next On. A hidden parent must
not silently hide a separately enabled child. No preference should alter limits,
spending, carry, commitments, warnings, or purpose classification.

### 6. Controls exist, but their meaning and reachability vary

- History's main Filter control is icon-only. Category clearing is an x icon;
  advanced clearing is labeled Reset and only conditionally visible. Filter-sheet
  Reset has a destructive role despite not deleting financial data.
- Plan's detail-density toggle uses a filter-like glyph, although it does not filter.
  Rename the action Display; keep Filter reserved for changing the record set.
- Category management alphabetizes full paths instead of displaying a true parent/
  child outline. Plan indents descendants and bolds roots but uses one large section
  rather than clearly separated main-category headings.
- Quick Log already has a Done control, interactive keyboard dismissal, a keyboard
  navigation menu, and encrypted draft capture. These are foundations to verify and
  extend rather than reimplement blindly.
- Category management's keyboard Done only clears `amountFocused`; the name field
  is not bound to that focus state. The simple Add Category form has no shared Done
  toolbar. Verify and unify focus behavior across all editable fields.
- Budget and category sheet edits live in local state without a draft-preservation
  or unsaved-dismissal contract. Quick Log's protection does not cover every form.
- Quick Log focus scrolling uses direct animations outside the shared motion
  resolver. Include it in the Reduce Motion audit.

## Decisions to discuss before implementation

### A. What an entered parent budget means

Recommended default for new planning: **automatic total with a direct allocation**.

```text
Food total: SGD 600     (derived; counted once)
  Direct Food: SGD 100  (no extra subcategory required)
  Groceries: SGD 300
  Dining: SGD 200
```

For one period and currency:

`subtree budget = direct allocation + sum(immediate child subtree budgets)`

`subtree spending = direct postings + sum(immediate child subtree spending)`

`remaining = effective subtree allocation - subtree spending`

The whole-book plan sums root totals only. Aggregated parents are not persisted as
new allocations. Refunds reduce spending; missing budgets differ from explicit zero.
Direct parent spending remains visible and can exceed its direct allocation even
when the parent group still has room. Show both levels honestly; do not move unused
child allocations automatically.

Alternative: **fixed overall parent total**, with child budgets allocating parts of
that envelope. A SGD 600 Food limit stays SGD 600 after a child edit; show allocated,
unallocated, and overallocated portions explicitly. This offers a stable ceiling but
does not provide automatic growth from child edits.

Migration recommendation: preserve existing caps and historical revisions. Offer a
reviewed conversion to automatic totals rather than reinterpret old amounts as extra
direct allocations. Underallocated caps may have a determinable remainder, but
overallocated, mixed-purpose, or rollover-bearing trees require explicit review.
Do not quietly convert SGD 600 parent plus SGD 500 children into SGD 1,100.

Do not add a generic mode toggle to every simple leaf. A parent editor can expose
the choice where it matters; historical compatibility stays in the data layer.

### B. Visual direction and navigation

Recommend an evolution of the existing forest-green identity: warm opaque surfaces,
deep charcoal in dark mode, strong numerical hierarchy, generous grouping, restrained
depth, and small illustrations at onboarding, empty states, and scenario entry.
Keep precise amounts and charts flat and legible. Avoid decoration competing with
budget editing or transaction scanning.

Retain the five stable destinations for now: Today, History, Log, Plan, Assets.
Relabel Assets to Accounts only if investments and net worth can still be found
without adding navigation ambiguity. A four-tab redesign would require choosing
which daily job to bury; there is no measured evidence yet that this is necessary.

| Destination | Primary user job | Proposed interaction |
|---|---|---|
| Today | Decide what needs attention | Optional guidance, selected budgets, explicit exceptions, Customize |
| History | Find or correct a record | Labeled Filter with count, Clear filters, visible active chips, separate search clearing |
| Log | Capture once and resume safely | Amount-first, clear category path, select a parent directly, persistent encrypted draft |
| Plan | Allocate and explore | Main headings, indented children, Edit budget and Manage as distinct actions |
| Categories | Organize without loss | Tree outline, Add category, Add subcategory, visible More actions, search with ancestor context |
| Assets | Understand cash, debt and holdings | Separate liquidity, liabilities, restricted balances, valuation timestamps |
| Settings | Control experience | Display & guidance, Entry defaults, Privacy & data, Language & currency |

Graphics should answer questions: tappable budget composition, exact spending pace,
cash-flow comparison, and read-only scenario effects. Give every chart a text
alternative and a route to the matching records. Illustrations do not encode amounts.

Animate expansion, selection, and chart-state changes with short bounded motion;
publish financial numbers immediately. No perpetual ambient animation or forced
count-up. Honor system Reduce Motion, Reduce Transparency, high contrast and Dynamic
Type. Offer an app motion reduction only as an additional reduction, never an override
of an accessibility preference. This follows Apple's [motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion)
and [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

### C. Period, currency, and guidance scope

Current budget writes use one monthly limit in the profile's base currency. Existing
timeline revisions preserve monthly configuration; foreign spending is shown separately.

Recommend exposing month selection and allowing independent budgets for the same
category in separate currencies. Each allocation is keyed by stable category ID,
reporting period, and currency. Never sum currencies implicitly. Daily and weekly
views initially remain derived pacing views of a monthly budget; true weekly/custom
budget periods would be a further product decision with different rollover rules.

Recommend calling the global metric **Daily budget guidance** or retaining the existing
**Flexible Today** label. Its present calculation is plan-paced spending guidance;
the phrase Safe to Spend can imply a cash-affordability guarantee it does not establish.
Changing visibility does not require changing its formula. If cash-aware affordability
is wanted, define that separately from this redesign.

Store global and node visibility choices in the encrypted profile/preferences domain,
with migration defaults that preserve the existing appearance. Apply a toggle in the
UI immediately, serialize durable writes, show/announce persistence failure, and
restore the last saved preference on failure. A final user choice must win rapid
toggle sequences and survive relaunch and backup/restore.

## Category lifecycle contract

Always show a discoverable Delete action for user-created categories. Its next screen
explains what must happen rather than silently removing the action.

- No linked records: confirm deletion, including any budget settings being removed.
- Linked records: select a compatible destination; preview affected transactions,
  schedules, child categories, drafts, defaults, allowance eligibility, pinned views,
  and budget changes. Do not preselect an arbitrary destination.
- Children: explicitly choose to move them to a destination or promote them; do not
  imply that deleting a group also deletes financial records.
- Merge: one source/destination preview with old and new non-overlapping budget totals.
  Resolve period, currency, purpose, rollover, and visibility conflicts before commit.
- Archive: remove from new-entry choices, keep historic records and reporting, and
  explain current-period budget treatment. Proposed default: retain the current
  period's allocation/history; offer ending future allocation explicitly.
- Confirmation names the action and destination. Relevant consequences remain visible,
  consistent with Apple's [alerts guidance](https://developer.apple.com/design/human-interface-guidelines/alerts).
- Preserve entry/posting identities, amounts, dates, notes, attachments, and revision
  provenance while reassigning references. Validate everything, commit one transaction,
  publish a coherent new state, then refresh derived consumers.
- Undo simple organization changes where a valid inverse exists. Do not promise a
  destructive-merge Undo before its durable inverse and intervening-write policy exist.

## Verification and acceptance plan

| Area | Required regression evidence |
|---|---|
| Rollup | Leaf edit updates all ancestors; direct parent allocation/logging; deep hierarchy; unbudgeted and explicit zero; grandchild counted once |
| Time & currency | Same category in two months/currencies; no cross-bucket sum; month-end, leap day, reporting timezone and DST; no duplicate rollover |
| Warnings | Child and parent overspend update after expense, refund, edit, date move and deletion; overallocated envelope distinguished from overspending |
| Hierarchy | Reparent across roots, ancestor/descendant merges, common-parent merges, cycle rejection; pre/post allocation conservation where intended |
| Persistence | Close/reopen actual encrypted store after every mutation; migration, backup/restore, lazy full-journal projection and exact-period checkpoints |
| Atomicity | Inject failure before/during commit and between prepared operations; no partial name/budget/hierarchy save; no broken references |
| Visibility | Global and every node independently; parent hide/child show; rapid toggles; write failure; relaunch; underlying financial snapshot unchanged |
| Deletion | Truly unused item, configured but unlinked item, linked item, last category, no destination, defaults, draft splits, archived children and planning references |
| Forms | Keyboard Done from each field; bottom controls visible; navigate away/resume; swipe dismiss; cancel/discard; lock/background; save failure; restore replaces drafts safely |
| History | Filter and Clear filters visible and named; clearing removes all advertised predicates; search clearing explicit; empty results offer recovery; chart drill-through exact |
| Privacy | Masked amounts and accessible labels stay masked; no financial payload in logs, generated graphics, shared widget storage or remote services |
| Accessibility | VoiceOver, keyboard/Switch Control, large text, long EN/ZH labels, light/dark, high contrast, Reduce Motion and Reduce Transparency |
| Other journeys | First account/opening balance; transfer/refund/splits; schedule posting; allowance use/correction; loan repayment; valuation staleness; export/import/restore |
| Performance | Large realistic book; bounded queries; no per-row full-tree recalculation; deep hierarchy without recursion exhaustion; coherent no-data/loading/error states |

Implementation sequence after discussion:

1. Agree on parent semantics, migration, and period/currency scope; encode financial
   contract tests and failing reproductions before changing calculations.
2. Repair projection consistency, merge conservation, and atomic category edits.
3. Add safe lifecycle resolution and persisted independent visibility preferences.
4. Unify forms, labeled filters, navigation/draft behavior, hierarchy, and settings.
5. Apply the visual system and purposeful interactive graphics; verify on device.

## Verification performed in this review

- Fetched and inspected current `main`; no production source changed.
- Compiled a standalone Swift probe against the actual Money, BudgetTree, and pacing
  source. Four cap/child edit cases passed their current-behavior assertions. The
  merge operation's arithmetic produced SGD 500 → SGD 700 as described above.
- Attempted selected package tests with `swift test`. Build stopped because the
  active Command Line Tools SDK could not resolve XCTest; the build also reported
  a build-database I/O error. No XCTest pass is claimed.
- `xcodebuild -version` reports the active directory is Command Line Tools, and no
  Xcode app was found in `/Applications`. No native simulator or physical-device
  validation was performed.
- A separate interactive concept uses illustrative sample data, not the user's book.
  Its arithmetic and interactions are reviewed separately from native app behavior.
- Reproducible core evidence and the precise concept QA record are in
  [review-evidence/2026-09-05](review-evidence/2026-09-05/README.md).

Open uncertainties: exact installed build; whether another mounted-view invalidation
defect accompanies the demonstrated semantic mismatch; full lifecycle failure behavior
on iOS; desired parent-budget meaning; independent currency/period scope; unfinished
item 7. These do not justify inventing migration behavior before discussion.
