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
details or domain identifiers. Before `perform()` reports success, the intent
atomically appends the closed action plus an opaque stable handoff token to a
coordinated, schema-1 App Group FIFO capped at 16 records and 4,096 bytes.
That file contains only schema/authority metadata, admission state, tokens, and
closed action values. Its canonical JSON rejects duplicate or unknown keys,
its private directory is reasserted as `0700` and excluded from backup, and its
atomic ingress uses first-unlock file protection because the contents are data-free.
Basic Lock Screen Quick Capture therefore remains available after the first
device unlock of a boot; reboot-before-first-unlock remains protected. Direct
`.onOpenURL` input is first converted by the same exact closed map and submitted
to that FIFO; it does not mutate `AppModel` directly.

The app reloads durable ingress on cold launch and every active-scene entry.
It begins at most one FIFO delivery into a generation-bound UI request slot,
but does not remove the durable head then. The exact token remains durable
until that exact presented request is applied or dismissed and acknowledged.
An in-process duplicate/stale acknowledgement cannot remove a different head.
Authentication, authoritative erase denial, draft handling, locked Quick
Capture, validation, and every financial write remain inside the app.

This is durable **at-least-once ingress with idempotent exact-token UI
acknowledgement**, not an impossible claim of exactly-once execution across
process death. A crash after delivery but before acknowledgement may replay the
same navigation request after relaunch; it cannot create or repeat a financial
commit because the action carries no transaction data and only opens/focuses
the existing form. App Intents supplies no stable OS invocation identifier, so
an OS retry or two identical taps cannot be deduplicated safely; each successful
submission receives a distinct token. At capacity, the newest invocation is rejected
without evicting or reordering accepted work, and the rejected attempt
still wakes the strict router so accepted work cannot conceal newly unreadable
erase authority. Every durable producer reloads the current epoch before a new
submission and the coordinated append compares that observed authority again;
a boundary that races between those operations rejects the append. A late or
ambiguous coordination error is reported as accepted only when the exact
token/action postcondition is durably present in the same authority epoch.
An authoritative erase
or exclusive book-replacement lifecycle boundary durably closes admission and
discards the entire old-book FIFO before routing; a pending or unreadable erase
tombstone does the same.
The same complete discard applies if erase authority changes after one action
is dequeued or while its lock-safe capture handoff is being checked.
Ordinary startup or same-book lifecycle work and an occupied UI request slot
only defer the queue. Erase, restore, key replacement, and pending/unreadable
startup tombstones synchronously persist a closed-admission boundary before
their first lifecycle side effect or suspension; failure to persist that close
aborts the destructive entry point. Beginning an epoch advances the book
generation and clears both the FIFO and any occupied/local UI handoff. Every
submission while any epoch remains active is rejected. A process crash leaves
admission closed, and only a successfully validated authoritative startup may
recover it. One coordinated recovery preserves any already-valid open epoch
and its accepted FIFO (including a first append racing normal startup), while
absent, corrupt, or closed state becomes a new empty/open epoch. Failed or
cancelled startup remains admission-closed but still exposes the normal Locked
or Recovery UI, never a permanent launch cover. Balanced normal completion
covers all success, error, and cancellation exits. Exact request tokens prevent
delayed callbacks from consuming a newer identical action. Correctness does not
depend on a SwiftUI observation callback seeing an intermediate lifecycle flag.

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
  until the first Log request is acknowledged, then appears with a different
  token. Do not treat the two user/OS invocations as duplicates.
- In an instrumented build, terminate the app after durable admission but
  before routing. Relaunch and confirm the same token is delivered. Repeat by
  terminating after dequeue/presentation but before acknowledgement; relaunch
  may replay that navigation once, and must show no automatically created
  transaction. A clean exact-token acknowledgement must remove the durable
  head; later relaunch/foreground must not replay it.
- Corrupt the ingress file, write a future schema, add an unrecognized field,
  duplicate a JSON key, change canonical encoding, and exceed 4,096 bytes.
  Each state must block admission and route nothing. Confirm its dedicated
  directory remains owner-only and backup-excluded. A validated authoritative
  startup may recover absent/corrupt/closed state; an extension or
  pre-validation callback may not.
- Hold one app broker at absent state, accept the first action from a second
  process while startup validates, then finish validated recovery. Confirm the
  accepted token remains the FIFO head. Repeat with extension brokers cached on
  the open and closed sides of a completed boundary; their first later tap must
  reload the current epoch and succeed, while an injected rotation between
  reload and append must fail its authority comparison.
- Terminate during an erase/restore/key-replacement boundary. Confirm the
  persisted admission state remains closed through process recreation and
  opens empty only after startup validates/reconciles the authoritative book.
- Repeat while locked, entering data in the first form before cancelling or
  finishing it. Confirm the second action receives a fresh empty form and a
  delayed callback from the first cannot dismiss or save the second.
- Terminate after a locked-capture inbox append but before its UI completion.
  Relaunch and confirm the ingress token identifies the already-saved capture,
  the form reports it saved, and retry cannot append a second payload. After an
  unlocked upgrade from an older build, confirm the ciphertext bytes and FIFO
  are unchanged while file protection migrates to first-unlock availability.
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

## 3. Interactive widgets and passive summaries

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
3. Configure **Budget status** and **Smart Overview** in every supported Home and
   Lock Screen family. Exercise disabled, stale, needs-budget, zero-budget,
   negative-budget, current 0%, and over-100% budget states plus nil/partial
   review, allowance, and expense-commitment insights. Disabled must direct the
   user to Settings; stale must direct the user to open MoneyUp; other states and
   unavailable components must never masquerade as zero.
4. Verify every Smart Overview family preserves the current budget while an
   individual insight is unavailable, counts only expense commitments, and shows
   only reporting-calendar-relative due-day distance. At the earliest displayed
   expiry, the complete generation becomes stale; no mixed-generation fields or
   exact due date may remain visible.
5. Tap every Budget Status and Smart Overview percentage, title, icon,
   gauge/progress view, and surrounding background. Both surfaces remain passive
   and must not open MoneyUp or run an intent. Inspect the shared container: its
   app-owned allowlist is exactly one nonfinancial language preference, one
   atomic bounded schema-4 summary `Data` value, and one bounded data-free
   quick-action ingress JSON file, with no fourth key or file. Confirm the summary
   contains only state, a bounded reporting-period token, rounded budget/
   allowance percentages, review/expense-commitment counts, expiry, and relative
   due-day distance. Confirm the ingress contains only schema/authority and
   admission metadata, opaque tokens, and one of six closed action values.
   Neither may contain an amount, payee, account, holding/symbol/quote, balance,
   transaction, note/evidence, book, exact due date, or ledger identity.
6. Confirm the pre-update widgets retain their configuration. In particular,
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
Group artifacts. An accepted shortcut, widget button, control, or allowlisted
URL may change only the bounded data-free ingress file by appending its closed
action, opaque token, and reviewed protocol metadata. It must not persist a URL
route, transaction detail, or domain identifier, and it must not mutate the
existing nonfinancial language preference or opt-in bounded summary merely
because the action opened the app. A rejected invocation must leave all three
artifacts unchanged; no fourth app-owned key or file may appear. Confirm the
ingress bytes are canonical, the enclosing ingress directory is `0700` and
backup-excluded, and a simulated late write error is reconciled against the
exact token/action postcondition rather than returning a false rejection for a
commit that is already durable.

Search Console and the built metadata for the fictional values used in the
run. Inspect notification center, Spotlight, Live Activities, Siri history,
and the Shortcuts result. No transaction detail or record identifier may
appear. Finally, reconcile the locked-capture inbox before and after routing:
opening an action alone must not append, remove, or reorder any capture.

Attach the evidence to the exact candidate record. Keep this gate open until
all physical surfaces, both languages, locked/unlocked states, and the widget
upgrade path pass on the signed binary.
