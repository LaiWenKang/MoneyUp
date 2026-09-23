# Incident: Log tab crashes on device — 0.7.2 (1064.1), 23 September 2026

## Impact

Build 1064.1 crashed every time the Log tab was opened on a real iPhone
(iPhone17,2, iOS 27.0). The build reached internal TestFlight testers and was
submitted for public App Review; the review was withdrawn the same afternoon
before any decision, so no public user received it. 0.7.1 remained the live
version throughout.

## Timeline (SGT)

| Time | Event |
|---|---|
| ~11:10 | PR #83 merged after every CI job passed; 1064.1 uploaded, distributed internally, and submitted for review. |
| ~13:15 | First device crash reports from TestFlight. |
| 13:30 | Owner reports the crash; the pending review is withdrawn (`CANCELING`). |
| 13:35–14:00 | Release build on iOS 27 and iOS 26.5 simulators and all Log render tests: no crash. |
| 14:05 | A new book-shape render test reproduces a second, latent trap (duplicate category IDs). |
| 14:10 | Device crash log received: stack overflow in Swift runtime type demangling under `QuickLogEntryView.quickLogFormChrome`. |
| 14:30 | Root cause confirmed by measurement; fix and regression guards in place. |

## Root cause

SwiftUI encodes a screen's whole view hierarchy in one generic type. The first
time a screen renders, the Swift runtime decodes that type recursively on the
main thread. The Log form was already the deepest screen in the app (98 levels
of generic nesting; every other screen is 55 or less). The new Log route bar
was written as an inline `@ViewBuilder` property, so its entire nested type was
spliced into the form's type, taking it to **108 levels**. That recursion
overflowed the main-thread stack on a real iPhone
(`EXC_BAD_ACCESS … stack guard region`, ~660 `swift_getTypeByMangledName`
frames).

A second, latent defect was found while reproducing: the chip ranking built a
`Dictionary(uniqueKeysWithValues:)` over category IDs, which traps if a book
holds a duplicated account record. Every other account table in the app
already tolerates duplicates.

## Why tests did not catch it

1. **Simulator stacks are much larger than device stacks.** The same type that
   overflows an iPhone's main thread decodes comfortably in the simulator, so
   every simulator render test, CI job, and simulator walkthrough passed. The
   defect class is invisible to the whole simulator-based pipeline.
2. **No guard existed on view-type complexity.** Nothing measured how deep a
   screen's type was, so a 10% increase on an already-extreme screen was not a
   visible change in review.
3. **An early warning was treated as noise.** The same morning, the Transaction
   edit render test crashed with the same SwiftUI frames
   (`DelayedPreferenceChild`, `IsAnimated`) after a one-line styling change. It
   was worked around as "a SwiftUI bug in this form" instead of being
   investigated as a complexity limit.
4. **Render fixtures were too clean.** Tests used tidy books (unique records,
   a handful of categories), so the duplicate-record trap never ran.
5. **No device check before public submission.** The build was submitted for
   App Review in the same session it was uploaded, without first opening it on
   a physical iPhone from TestFlight.

## Fix

- The route bar is now a concrete `QuickLogRouteBar` struct (with
  `QuickLogCategoryChip`, `QuickLogAllCategoriesMenu`, `QuickLogAccountChip`).
  The Log form type is back to depth 98, the value that has shipped safely.
- The ranking and both menus de-duplicate by ID, keeping the first record, as
  the rest of the app does.

## New coverage

- `AppwideExperienceTests.testScreenTypesStayWithinDeviceSafeDepth` measures
  the generic nesting depth of 34 screen and sheet body types. The Log form may
  not exceed its proven ceiling of 98 (108 crashed); every other screen must stay
  at or below 60 (current maximum 55). Any growth fails CI with a message
  pointing to the fix: extract a concrete `View` struct.
- `AppwideRenderEvidenceTests.testLogTabRendersForEveryBookShape` renders the
  Log tab for five book shapes (duplicated records; deep, hidden, archived and
  preset categories with a 120-entry journal; no categories; no accounts; empty
  book), for every entry kind, in light at default size and dark at an
  accessibility size. It reproduced the duplicate-key trap before the fix.

## Lessons

- **A device is a separate test environment, not a faster simulator.** Stack
  size, memory, and Release optimisation differ; simulator green is necessary,
  not sufficient.
- **Measure what can't be seen in review.** Type depth is now a number with a
  budget, like the existing file and function size limits.
- **Crashes in test harnesses are signals.** A render crash that goes away with
  a tiny change is a limit being approached, not flakiness.
- **Make fixtures as messy as real books.** Duplicates, deep trees, hidden and
  archived items, empty states.
- **Gate public submission on a device run.** From now on: TestFlight build →
  owner opens every tab on a physical iPhone → only then prepare and submit.
