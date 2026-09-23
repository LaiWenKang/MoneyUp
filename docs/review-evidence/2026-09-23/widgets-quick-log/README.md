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
     green, the glyph, "Log expense" and "Amount first".
   - **Medium:** a dominant hero plus three labelled shortcuts in a fixed
     order.
   - **Large (new):** the hero plus all five other actions, laid out as rows of
     three with no empty slot.
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
     ("Lunch"). The chip shows the amount or a keypad prompt.
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
- A budget-period pace marker in "Today + Log". It reuses the existing
  record-free summary today.
- Animated transitions between timeline entries.
- Measured tap-to-save timing on devices.
- **Physical-device check, required before any submission:** open every tab
  and the new widget sizes on a physical iPhone running the TestFlight build.
  See `docs/INCIDENT_2026-09-23_LOG_TAB_CRASH.md`.

## Evidence

Renders are from `QuickLogFavouriteAppTests.testRenderQuickLogWidgetsQuickAccessAndFavouriteStrip`
on the iOS 27.0 simulator (Xcode 27); see the PNGs in this folder.
