# MoneyUp app-wide experience follow-up

The follow-up addresses all five tabs and the clarified report: **Smart Overview was tapped with MoneyUp closed; no device crash report is available**. It extends the build 1039.1 feedback changes in PR #52.

## Changes by journey

| Journey | Implemented improvement |
|---|---|
| Smart Overview | Populated overview widgets now use an exact, data-free Today URL; Budget Status uses an exact Budget URL. Requests wait for an active, unlocked scene. Initial protected startup is claimed once and rechecked after the URL-routing window, avoiding authentication before foreground activation. The six capture routes and their durable FIFO remain separate. |
| Today | Retains the labeled, bounded cards from the first pass. Full-tab screenshots now include its permanent navigation bar and pinned-category board. |
| History | Signed income/expense graphics use a common zero baseline and separate currencies. Filter badges count hidden predicates without duplicating the visible preset date scope. Custom date filters remain counted. Large-text scope menus have an explicit chevron; Filter and Clear filters remain visible. |
| Log | A direction diagram distinguishes expenses, income, refunds, and transfers using the selected controls. Its Save background is bounded, scrolling dismisses the keyboard, and the permanent tab hierarchy has one process-local selection owner. The capture/parser/assistance/write authority is unchanged. |
| Plan / Calendar | Adds a direct return to today and signed daily cash-flow graphics. Existing actual and scheduled money remain separate. |
| Plan / Goals | Tapping a goal opens a readable progress/detail view before editing. A contribution simulator previews exact equal deposits and their completion date, flags a missed deadline, and makes no ledger writes. It is offered only for goals without automatic resets, so it cannot imply that balances survive a reset. |
| Assets | A clearer per-currency net-worth header, guarded snapshot capture with visible success, and an interactive history chart of frozen snapshots. Dragging and Previous/Next buttons inspect the same exact saved values; missing currencies are never filled with zero or converted. Detailed snapshot evidence remains available in a disclosure. |
| Secondary editors | Exchange-rate entry moves into a protected sheet; back navigation from the rates list cannot discard an unfinished rate. Allowance-usage editing now guards dirty dismissal and initializes dates only once. Backup icons use a valid system symbol. |
| Shared appearance | Consistent direction diagrams, progress dials, exact 2D charts, existing restrained illustrations, and press feedback that remains visible with Reduce Motion. Large text keeps textual financial meaning; decorative graphics never carry the only label. |

## Financial and privacy rules

- The contribution preview compares exact Decimal products with bounded binary search. It does not round a quotient to estimate the required deposit count. Its 1,200-deposit horizon is explicit, its dates use the reporting calendar, and it assumes no returns or interest. A final equal deposit may exceed the target; that full amount is retained in the displayed projection.
- Forecasts and chart selections do not mutate journals, balances, goals, or snapshots. Saving a goal movement or snapshot remains a separate explicit action.
- Net-worth chart points come from each snapshot's stored amount in the selected currency. Display lines connect recorded observations, not reconstructed intervening balances.
- The overview router contains only two enum destinations, with exact URL matching. No monetary value, account, note, identifier, or query parameter is accepted. Its pending request is process-local; the App Group payload and encrypted store formats are unchanged.
- Only the affected Quick Log UI declaration digests were renewed for the direction preview, bounded Save background, keyboard dismissal, and extracted toolbar. Capture input, model prompting, cancellation, save, and draft authority remain covered by the original mutation checks.

## Verification

Source checks cover structure, localization, architecture, launch safety, accessible errors, and private platform actions. The architecture tests include the extracted toolbar in their canonical fixture; additional platform mutations reject permissive overview URLs and removal of the scene gate.

Native tests cover cold-start deferral and one-time startup, gated overview consumption, exact URL rejection, contribution precision/overflow/calendar dates, currency-separated snapshot history, entry direction, ordinary keyboard dismissal, system-symbol availability, and a real edited Log draft across all five tabs. Render evidence includes full Today/History/Log/Plan/Assets tabs, Calendar, Goals, large-text Log, small Chinese Assets, goal detail and contribution preview, net-worth history, and the exchange-rate editor.

The iOS 26 workflow also terminates the app, opens the Smart Overview URL, and verifies that the app process remains alive on a clean simulator book. This checks cold launch stability; it does not reproduce the tester's encrypted book or prove the original physical-device crash fixed. Physical-device reproduction, VoiceOver interaction, and signed-binary acceptance remain distinct from simulator evidence.

Final candidate results will be recorded after native verification.

Apple reference: [Linking widgets to app scenes](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity).
