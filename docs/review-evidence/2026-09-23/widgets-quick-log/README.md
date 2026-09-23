# Widgets and fast logging: gap review and first delivery (2026-09-23)

Baseline: `main` at `2db53da` (0.7.2, build 1064.1). This review checked the
widget and fast-logging proposal section by section against that code. It then
delivered the tranche the owner chose: favourites stay **in the app**, and the
flagship Quick Log widget ships first.

## Owner decisions

- **Favourites stay inside MoneyUp.** They are stored in the encrypted
  profile and never reach a widget, control, Siri, or the App Group. The
  platform rule stays as it was: platform surfaces carry only the six
  closed quick actions.
- **Nothing is saved directly from a widget.** Favourites only fill in the Log
  form; the user still taps Save. The `Button(intent:)` ban is unchanged.

## What main already did (verified in code, not rebuilt)

| Proposal item | Status on `2db53da` | Where |
|---|---|---|
| A widget tap opens the requested mode directly | Yes: expense, income, transfer and refund set the kind; Smart Entry focuses its text field; Receipt opens the picker | `QuickLogEntryDraft.handleRequestedLaunch` / `performLaunch` |
| The right field is focused without an extra tap | Yes: the amount field is focused on launch and after save | `QuickLogEntryBody` `onAppear`, `completeSuccessfulSave` |
| A widget request doesn't overwrite an unfinished draft | Yes: the user chooses Resume, Discard or Cancel | `QuickLogEntryBody` draft-switch dialog |
| Opening Log is not the same as editing | Yes: choosing a kind is routing, not content | `QuickLogDraft.hasUserEdits`; `Feedback1059RenderEvidenceTests` |
| New entries get a fresh timestamp | Yes: the time refreshes until there is content | `QuickLogOccurrencePolicy` |
| "Recorded", "captured for review" and "not saved" stay distinct | Yes: Locked Quick Capture says "Captured privately", separate from "Saved"; failures show an alert | `LockedQuickCaptureView` |
| Repeated taps and retries | Each submission gets its own ingress token; duplicate review guards saves | `MoneyUpQuickActionRouteBroker`, `QuickLogEntryDuplicateReview` |
| Widget reloads after changes; "unavailable" never shown as zero | Yes | `AppModelJournalProjection`, `BudgetWidgetSnapshot` states |
| Actions-only privacy by default | Yes: widget summaries are opt-in | `UserProfile.showsBudgetStatusWidget` |
| Control Center / Lock Screen / Action button control | Yes | `MoneyUpQuickLogControl` |

## Delivered in this change

1. **Quick Log widget redesign.** The card is shared by the widget and the
   in-app preview (`App/Shared/QuickLogWidgetCard.swift`) and draws only the
   closed action enum.
   - **Small:** the whole widget is the action, with a full-bleed MoneyUp
     green, the mark, and "Log expense".
   - **Medium:** a dominant hero plus three labelled shortcuts in a fixed
     order.
   - **Large (new):** a compact hero plus all five other actions as a list.
   - **Budget status / Smart Overview at Large ("Today + Log"):** the medium
     summary sits on top, with the medium Quick Log card below it.
   - **AX sizes:** secondary shortcuts give way to one large hero.
   - **Tinted and accented modes:** the card falls back to monochrome plates.
   - **Contrast:** white text is at least 4.5:1 on every gradient stop in
     every appearance and contrast mode. This is enforced by
     `validate_release_assets.py`.
   - **Accessibility:** each tile announces its consequence ("Log expense",
     "Add receipt") plus the existing unlock hint.
2. **Favourites (in-app).**
   - **Model:** `QuickLogFavourite` in `MoneyUpCore`, stored in the encrypted
     `UserProfile`. At most 12, trimmed and bounded. An empty list is not
     written, so older builds never meet the key.
   - **Two kinds:** fixed amount ("Coffee · SGD 3.20") or amount each time
     ("Lunch"). The chip shows the amount, or only the name.
   - **Log strip:**
     - One tap fills the form.
     - An amount-only favourite focuses the amount field and keeps an amount
       already typed.
     - Blank favourite text never erases text the user typed.
     - Nothing is saved until Save.
   - **Repair:** an account or category that is gone or archived is never
     guessed. The chip shows "Needs attention" and opens the editor with that
     field cleared.
   - **Merges:** merging an account or category updates favourites that use
     it.
   - **Save as favourite:** a star in the "Saved" banner. The banner doesn't
     auto-dismiss while the editor is open. A new favourite starts as
     amount-each-time.
3. **Widgets & Quick Access page** (Settings → Widgets and reporting). It has:
   - a live preview of each size and main action, with steps for adding the
     widget;
   - favourites management (edit, reorder, delete, repair);
   - the Control Center, Lock Screen, Action button and Siri entry points;
   - the two privacy switches with plain explanations.

4. **Budget pace marker.** Budget Status (small, medium, and the large "Today +
   Log") now draws usage as a bar with a tick at today's place in the budget
   month, plus the line "Within pace / Ahead of pace · N% of the month gone".
   - The month is derived from the period end the snapshot already carried.
     Thirteen hours before the reporting-zone midnight is always inside the
     month in UTC, so no schema, zone, or new shared data was added.
   - Timeline: Budget Status re-dates the same generation every 6 hours
     (at most 124 entries) so the tick moves without the app. The stale entry
     at expiry is unchanged. Smart Overview and Quick Log timelines are
     unchanged.
   - "Ahead of pace" needs more than 5 points over the month's elapsed share,
     and spending more is never styled as progress.
5. **Feedback and motion.**
   - Budget percentages animate with a numeric content transition between
     entries.
   - A tapped favourite briefly shows a checkmark. Reduce Motion keeps the
     confirmation without the animation, and VoiceOver announces "Lunch filled
     in. Review, then Save."
   - No haptic was added, because the app's feedback policy reserves haptics
     for consequential results and a prefill isn't one. Save keeps its
     existing success haptic.

6. **Minimal visual pass (one glyph system).**
   - **Signs, not directions:** − expense, + income, ⇄ transfer, ↩ refund,
     sparkles for Smart Entry, and a receipt symbol for Receipt. These live in
     `MoneyUpEntryGlyph` and drive the widget, Control Center, Siri tiles,
     History rows, Insights totals, and the Log receipt button. A test keeps
     `MoneyUpQuickAction.systemImage` in sync with it.
   - **One container per tile:**
     - The hero is a single white disc with the glyph cut in, plus the verb.
       No brand mark, subtitle, or echo glyph.
     - Shortcuts are one soft surface with a tinted glyph and a label. No
       discs or borders.
     - Large is a compact hero with shortcuts as a list, so there is no empty
       space.
   - **Favourite chips:** a fixed amount shows its figure; amount-only shows the
     name alone.
   - **Contrast:** row glyphs are at least 3:1 on their surface (non-text), and
     hero white is at least 4.5:1. Both are validator-enforced.
   - **Unchanged:** the Insights chart legend keeps its filled versus outlined
     ± rectangles, which are the reviewed non-colour encoding.

7. **Owner device feedback on build 1069.1 was that it looked the same, and it
   largely did.** A widget tap on a locked phone opens Locked Quick Capture,
   which this work hadn't touched. Favourites also stayed invisible until one
   existed. Fixes:
   - **Locked Quick Capture:**
     - The same "− Log expense" mark and verb as the widget, a 44 pt amount,
       and one privacy line. The banner, paragraph, and two footnotes are gone.
     - "Capture privately" is pinned above the keyboard. On device it had been
       hidden behind the keypad, because the keyboard toolbar didn't render.
     - "Unlock for favourites and accounts" opens full Log in one tap.
   - **Log:** the favourites row always shows. With none saved it offers a
     dashed "Add a favourite" chip, and afterwards a trailing "New favourite".
   - **Renders:** `locked-capture.png` and `log-favourites-empty.png`.

## Guardrails updated deliberately

- **`validate_platform_actions.py`:**
  - Link and reference inventories updated for the new widget structure.
  - New `validate_quick_log_widget_card_source` check: the shared card may
    contain no links, URLs, intents or snapshot/model inputs, and a tile takes
    only the action and its role.
  - The Smart Overview Large mapping is pinned explicitly.
  - Validator tests: 61 → 62, with mutations for each new rule.
- **`validate_architecture_fitness.py`:**
  - Recomputed the w3 digests for `UserProfile.init`, `UserProfile.init(from:)`
    and the two Log extensions. Those are the only executable changes.
  - The `scanReceipt` state inventory now includes the card's two copy
    mappings.
- **`validate_release_assets.py`:** the widget contrast gate now reads the
  card palette instead of the retired glyph gradient. It caught the first
  light hero stop (#3A866A, 4.38:1), which was changed to #34785F (5.25:1).
- **`AppwideExperienceTests.testScreenTypesStayWithinDeviceSafeDepth`:** now
  also covers `WidgetsQuickAccessView`. Log remains within its 98 ceiling
  because the strip and star are concrete structs that own their sheets.

## Not in this tranche (deliberately)

- Saving directly from the widget, and per-widget favourites. The owner
  declined these because they require payloads on platform surfaces.
- A pace marker on Smart Overview's budget dial. Its presentation carries no
  period end today; Budget Status has the marker.
- Measured tap-to-save timing on devices.
- **Physical-device check, required before any submission:** open every tab
  and the new widget sizes on a physical iPhone running the TestFlight build.
  See `docs/INCIDENT_2026-09-23_LOG_TAB_CRASH.md`.

## Evidence

Renders are from `QuickLogFavouriteAppTests.testRenderQuickLogWidgetsQuickAccessAndFavouriteStrip`
on the iOS 27.0 simulator (Xcode 27); see the PNGs in this folder.

## Internal TestFlight delivery (0.7.2, build 1069.1)

- **Merged:** #86 as `4e226a4`, with the tester notes in #87 as `91b746a`.
  - All five CI jobs passed on the PR.
  - The full local run passed: 781 app tests, the package suite, and every
    validator and validator test.
- **Upload:** `testflight.yml` run 69 (`35906773898`) built, signed, and uploaded
  `4e226a4`. Earlier attempts hit CI problems, not app code:
  - Run 66 was cancelled at the 45-minute preflight limit right after
    `BUILD SUCCEEDED`, because the release build took 16.3 minutes.
  - Runs 67 and 68 failed the pre-existing flaky StoreKit simulator test
    (a 10-minute hang, then a transaction still unfinished after 20 s).
  - Each attempt used a build number.
- **Processing:** `VALID` (`apple-inspect-1069.1.json`).
- **Export compliance:** copied from 1064.1, with non-exempt encryption false
  (`apple-compliance-1069.1.json`). Nothing changed between `2db53da` and
  `91b746a` in `Package.swift`, `Package.resolved`, `project.yml`,
  entitlements, Info.plists, or privacy manifests.
- **Internal:** `IN_BETA_TESTING` for 3 of 3 internal testers, using the
  updated `docs/TESTFLIGHT_WHATS_NEW.json` notes (`apple-internal-1069.1.json`).
- **Not done:** App Store submission. 0.7.2 stays in review with 1064.1.
  These features are for 0.7.3, after the owner has opened every tab and
  tried each widget size on a physical iPhone running 1069.1.
