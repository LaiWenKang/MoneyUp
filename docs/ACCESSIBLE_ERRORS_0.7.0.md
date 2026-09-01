# Accessible Error Presentation — 0.7.0

MoneyUp now separates correctable field validation from operation failures.
Field guidance stays beside and in the accessibility hint of its input. A
localized, privacy-safe general, read, write, save, import, export, restore,
scan, or unlock failure receives one owned native alert or a target-bound retry
summary. Native alerts own VoiceOver focus and announcement, so the app posts
no duplicate announcement.

## Source boundary

- `AccessibleErrorPresentation` contains the shared alert reducer, modifier,
  field association modifier, and non-color-only field-error label.
- Dismissing an operation alert clears only the error binding. Entered form
  values, selected mappings, staged previews, and existing retry actions remain.
- The reducer is latest-wins while a summary is active or awaiting dismissal
  completion. Every dismissal crosses an explicit SwiftUI update boundary and
  then resnapshots the binding, so an identical `A -> nil -> A` failure cannot
  disappear when `onChange` coalesces the writes. A newer failure received in
  that interval replaces the queued failure, so stale work cannot reappear.
- `SafeLocalizedErrors` remains the only conversion from arbitrary caught
  errors to user-visible text. The presentation layer never displays raw error
  payloads or diagnostics.
- Data safety, import, settings, transaction editing, accounts, holdings,
  exchange rates, ledger lifecycle, assets, schedules, goals, budgets, category
  creation, and onboarding no longer leave mutation failures as passive red
  text.
- Restore results never compete with their confirmation sheet. Failures enter
  the shared native alert only after dismissal. Success focuses a restore-only
  visible confirmation when the ready hierarchy survives; any recovery-to-ready
  root transition queues success before replacement and consumes it once after
  the surviving hierarchy renders. Appearance and token-change orderings
  converge on one announcement.
- Locked capture, Quick Log amounts and split lines, Plan simulator amounts,
  and History date/amount ranges attach localized guidance to the responsible
  inputs and retain a visible icon-and-text error. Receipt read, recognition,
  and retention failures use the Quick Log operation alert rather than passive
  smart-entry text.

## Automated evidence

- `AccessibleErrorPresentationTests` proves one snapshot per active failure,
  re-presentation after dismissal, latest-wins replacement across the
  dismiss-to-promote race, recovery of a coalesced identical binding value via
  the post-yield snapshot, rejection of empty summaries, restore sheet
  ordering, restore-only focus clearing, and both ready-hierarchy announcement
  orderings.
- `validate_accessible_errors.py` builds declaration scopes across split Swift
  extensions, follows computed-view references outward from each reachable
  `body`, and requires the publishing owner and exact binding or retry summary
  to agree. Deferred restore queue, take, and failure assignment are pinned to
  their intended functions. The gate checks every safe-message context,
  requires each field label and actual input hint to use the same message, and
  rejects dead/unreachable alerts, no-op retries, owner collisions, unrelated
  recovery states, non-input hints, cross-struct routes, and passive red
  failures. It derives source roots from `project.yml`, scans recursively, and
  runs directly in CI and transitively in release validation.
- Local Python, structure, localization, privacy, project, CI, and TestFlight
  release-asset validation passed for this source slice. Swift/Xcode execution
  remains exact-candidate CI work.

## Manual release residue

On both required iPhones and in English and Simplified Chinese, force one safe
failure in save, import, and restore; verify VoiceOver moves to and announces
the native alert once, dismissal preserves the form or preview, and retry is
still available. Repeat at the largest Dynamic Type size and with Increased
Contrast. This source slice does not close that physical gate.
