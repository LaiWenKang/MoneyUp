# Privacy-safe platform actions runbook

Target: MoneyUp 0.7.1 on iOS 18 or later

This runbook verifies the exact installed binary. Source validation proves the
closed mapping and rejects known payload-bearing APIs, but it cannot prove that
App Intents metadata extraction, Siri indexing, widget migration, Control
Center presentation, or locked-device routing behaves correctly on an iPhone.

The only value MoneyUp exposes to an App Intent or configurable control is the
closed quick-action choice: Expense, Income, Transfer, Refund, Smart Entry, or
Receipt. The action must resolve byte for byte to exactly one base-free URL
below. Case variants, percent escapes, credentials, ports, queries, fragments,
duplicate/dot segments, and extra or trailing path components are rejected:

| Action | Exact route |
|---|---|
| Expense | `moneyup://quick-log/expense` |
| Income | `moneyup://quick-log/income` |
| Transfer | `moneyup://quick-log/transfer` |
| Refund | `moneyup://quick-log/refund` |
| Smart Entry | `moneyup://quick-log/smart-entry` |
| Receipt | `moneyup://quick-log/scan-receipt` |

No platform surface may accept, announce, return, or persist transaction
details or record identifiers. The intent opens MoneyUp and places the closed
action in a bounded 16-action process-local FIFO. Direct `.onOpenURL` input is
first converted by the same exact closed map and submitted to that FIFO; it
does not mutate `AppModel` directly. The main scene consumes at
most one action into a generation-bound, uniquely identified UI request slot,
waits while startup or another request is active, maps it to the exact existing
route above, and leaves
authentication, authoritative erase denial, draft handling, locked Quick
Capture, validation, and durable writes inside the app. Identical invocations
remain distinct. At capacity, the newest invocation is rejected in memory so
accepted older actions are never evicted or reordered; the rejected attempt
still wakes the strict router so accepted work cannot conceal newly unreadable
erase authority. An authoritative erase
or exclusive book-replacement lifecycle boundary discards the entire in-memory
queue before routing; a pending or unreadable erase tombstone does the same.
The same complete discard applies if erase authority changes after one action
is dequeued or while its lock-safe capture handoff is being checked.
Ordinary startup or same-book lifecycle work and an occupied UI request slot
only defer the queue. Erase, restore, and pending/unreadable startup tombstones
synchronously open a process-local boundary epoch before their first
suspension. Beginning an epoch advances the book generation and immediately
clears both the FIFO and any occupied/local UI handoff. Every submission while
any epoch remains active is rejected, and a deferred epoch close covers all
success, error, and cancellation exits. The boundary cover removes ready/locked
action UI until the epoch closes, and exact request tokens prevent delayed
callbacks from consuming a newer identical action. Correctness does not depend
on a SwiftUI observation callback seeing an intermediate lifecycle flag.

## 1. Build and metadata gate

1. Run `python3 Scripts/validate_platform_actions.py` and the platform-action
   validator tests on the exact candidate SHA.
2. Build the app and embedded widget with the pinned Xcode toolchain. Treat a
   source-validator pass without this build as incomplete evidence.
3. In Xcode, open **Product → App Shortcuts Preview**. Confirm all six shortcuts
   are indexed in English and Simplified Chinese, each phrase names only an
   action and the MoneyUp application name, and each tile uses the matching
   non-sensitive title and symbol.
4. Inspect the extracted App Intents metadata in the app and widget build
   products. `OpenQuickLogIntent` must expose one `MoneyUpQuickAction` parameter
   and no free-form field, open the app when run, and return no value or dialog.
   The control configuration must expose that same one action type. Record the
   Xcode version, SDK, candidate SHA, and screenshots of both language previews.

Stop if metadata extraction reports a second parameter, a free-form field, an
unlocalized title, or a missing action. Do not work around extraction errors by
adding a string parameter or writing a route into shared defaults.

## 2. Shortcut routing

On a physical iPhone, run every App Shortcut once from Shortcuts, once from
Spotlight, and once with Siri. Repeat after selecting English and Simplified
Chinese as the device or per-app language in system Settings.

- Confirm Expense, Income, Transfer, and Refund open the matching Log mode.
- Confirm Smart Entry focuses Smart Entry only after the normal app unlock.
- Confirm Receipt presents the existing receipt picker only after the normal
  app unlock.
- Leave an unfinished encrypted draft before one run. Confirm the existing
  resume-or-discard decision appears and the shortcut does not overwrite it.
- Confirm Siri presents no transaction details, identifier, completion dialog,
  or returned value before or after opening MoneyUp.
- Invoke one basic action while cold startup authentication is in flight. It
  must wait through transient startup work, then route once; it must not be
  cleared merely because the app was busy. A pending/unreadable authoritative
  erase marker must still deny and forget the action.
- Queue at least two actions behind transient startup work, then begin an erase
  before releasing the work gate. Confirm the complete queue is forgotten and
  no old-book action appears after the blank replacement book opens. Repeat by
  invoking an action after erase has begun, with a pre-existing pending erase
  tombstone, and with an instrumented tombstone-read failure; every case must
  discard the complete queue before a route reaches `AppModel`.
- Pause erase and restore after their synchronous boundary begins. Submit the
  same action twice while paused and confirm both submissions are rejected.
  Finish the lifecycle before allowing any simulated scene callback; no queued
  old-book action may appear. Repeat cancellation and injected marker failures,
  then confirm the boundary is balanced and a fresh post-lifecycle action is
  accepted.
- During an ordinary same-book lifecycle mutation such as a profile/category
  write, invoke two actions. Confirm both remain queued, then route in FIFO
  order after the mutation finishes. They must not be mistaken for an erase or
  restore boundary.
- Invoke the same action twice while MoneyUp is warm. Confirm the second waits
  until the first Log request is consumed, then appears once itself.
- Repeat while locked, entering data in the first form before cancelling or
  finishing it. Confirm the second action receives a fresh empty form and a
  delayed callback from the first cannot dismiss or save the second.
- Invoke four different actions in rapid order while MoneyUp is warm. Consume
  each Log request and confirm FIFO order with no replacement, duplication, or
  replay after foregrounding.
- In an instrumented test build, submit 17 actions without consuming them.
  Confirm the first 16 retain FIFO order and the newest action is rejected;
  no accepted action may be evicted to make room. Repeat with the erase marker
  becoming unreadable on the 17th attempt and confirm all accepted old-book
  actions are immediately discarded rather than left silently queued.

Capture a screen recording with fictional data. A route mismatch, unexpected
spoken result, reordered/replaced invocation, transient-start loss, silent
draft replacement, or direct save is release-blocking.

## 3. Interactive widget and passive status

Preserve an existing pre-update small and medium `MoneyUpQuickLog` widget, then
install the candidate in place. Add fresh small, medium, and every supported
Lock Screen family beside them.

1. Configure each quick-action family with at least two actions, including one
   basic action and one unlock-required action.
2. Tap the complete small and Lock Screen controls. Tap all four independent
   buttons in the medium widget. Each must execute `OpenQuickLogIntent` and open
   the matching existing route. While the protected book is available, every
   basic action must expose the same full Quick Log details as the center Log
   tab, including account, category, title, notes, date/time, and applicable
   transfer or split fields.
3. Configure **Budget status** in every supported family. Tap the percentage,
   title, icon, progress view, and surrounding background. Budget status must
   remain passive and must not open MoneyUp or run an intent.
4. Confirm the pre-update widgets retain their configuration. In particular,
   Smart Entry and Receipt must not reset merely because their persisted raw
   values use `smartEntry` and `scanReceipt` while their URL paths use hyphens.

Record before/after screenshots and the installed prior/candidate build
numbers. Widget configuration preservation remains a physical migration gate.

## 4. Control Center, Lock Screen, and Action button

1. Add **MoneyUp Quick Log** in Control Center and configure each of the six
   actions in turn. Confirm the visible label and symbol match the choice.
2. Exercise the control from Control Center, the Lock Screen, and the Action
   button configuration UI where supported by the test device.
3. Confirm each interaction opens the exact corresponding route and never
   records a transaction directly.
   On iOS 26 or later, also confirm extracted App Intents `supportedModes`
   reports immediate foreground mode; iOS 18-25 must retain the reviewed legacy
   foreground-open metadata.
4. With MoneyUp locked, verify basic actions follow the existing preference:
   when locked Quick Capture is enabled, only the redacted locked-capture form
   appears with amount plus optional title and notes, and protected account or
   category selection is deferred until intentional unlock and review. When
   locked capture is disabled, normal authentication is required. Smart Entry
   and Receipt must always require the protected app flow.
5. Confirm failed or cancelled authentication leaves no new capture, draft,
   notification, Live Activity, Spotlight item, or App Group payload.

## 5. Privacy and persistence inspection

Use fictional records and take a before/after snapshot of the reviewed App
Group defaults. Merely invoking a shortcut, widget button, or control must not
write a route, pending action, or transaction detail there. Existing language
preference and opt-in bounded status snapshot keys may already exist;
their payload must not change solely because an action opened the app.

Search Console and the built metadata for the fictional values used in the
run. Inspect notification center, Spotlight, Live Activities, Siri history,
and the Shortcuts result. No transaction detail or record identifier may
appear. Finally, reconcile the locked-capture inbox before and after routing:
opening an action alone must not append, remove, or reorder any capture.

Attach the evidence to the exact candidate record. Keep this gate open until
all physical surfaces, both languages, locked/unlocked states, and the widget
upgrade path pass on the signed binary.
