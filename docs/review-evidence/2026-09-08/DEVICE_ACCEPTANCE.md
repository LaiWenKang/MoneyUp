# Every-journey device acceptance

Status: **not executed**. This is the remaining hardware checklist, not a pass
record. Record the exact candidate SHA/build, device/iOS, language, appearance,
reporting/device zones, and outcome for each row. Use a separate fictional test
book/device. Preserve the installed owner book and its verified external backup;
do not erase it, remove its passcode, downgrade, or restore an old backup over it.
The current task has not authorized a merge or release.

## Setup and evidence

- Install an authorized candidate suitable for testing without replacing the
  owner's only recovery path. Verify the actual build before collecting evidence.
- Use 5 and 10 transactions per day; retain the automated 10,000-entry stress
  results separately. Start with SGD 1,000 cash, USD 50 cash, an SGD budget of
  1,000, and fictional expense/income categories.
- Use fictional or redacted screenshot receipts. Compare the selected image with
  amount, currency, merchant and date before saving. Do not put private financial
  screenshots, passwords or balances into shared CI logs or diagnostic evidence.
- Record taps/gestures, first useful content time, stalls, clipping and focus.
  Use the repository's privacy-safe signposts for timing. Simulator measurements
  and manual stopwatch samples must retain their distinct labels.

## Execute every journey

| Journey | Exercise | Required result |
|---|---|---|
| Cold/foreground unlock | Automatic unlock with each auto-lock delay; ordinary return before and after expiry | Authentication starts only when required; success resumes the intended task; no initial app Unlock tap |
| Interrupted authentication | Cancel, retry, authentication failure, available passcode fallback, background during startup, manual Lock | One prompt at a time; no cancellation loop; explicit retry works; manual/automatic lock policy is respected |
| Privacy | Open Log, receipt, account and settings sheets; enter app switcher; repeat during an atomic save/restore | Opaque cover protects presented sheets and accessibility; no amount/name/note leaks in snapshots or logs |
| Onboarding | Currency, account type, signed opening balance, Back, corrections, completion | Correct currency and balance; no duplicate opening entry; controls remain reachable |
| Daily Log | 5–10 expense/income entries; decimal separator, trailing zero, notes, date, account/category changes | Raw typing/cursor/focus stay stable; amount currency is visible; Notes/Save/Done remain usable above the software keyboard |
| Screenshot capture | Light/dark English, Chinese, small text, numeric dates, balance/reference decoys, USD screenshot with SGD account, ambiguous `$`, mixed currencies | Correct fields or explicit review; no automatic currency reinterpretation; missing date is visible; manual edits survive |
| Screenshot interruption | Select a replacement image, leave Log, lock, cancel picker/OCR, edit fields while OCR runs | Obsolete results cannot change the current draft; partial results require explicit selection; no transaction posts automatically |
| Save and Undo | Rapid Save taps, save failure, second entry while acknowledgement is visible, Undo | Exactly one intended commit; feedback and Undo work; totals refresh immediately; new draft remains safe |
| Splits | Equal, percentage and locked-line rebalance; SGD, JPY and KWD; remainder and invalid totals | Exact conservation in currency minor units; no silent residual adjustment or rounding loss |
| History | Search, combined filters, Clear, category descendants, chart drill-through, edit and delete | Visible scope agrees with results; Back preserves real context; horizontal controls cannot switch tabs |
| Repeat/Refund | Prepare from History; repeat with an unfinished draft; change the source before preparation finishes | Source stays intact; replacement requires a choice; stale consent is rejected; prepared draft remains editable |
| Widgets/shortcuts | All six exact actions, locked/unlocked, existing draft, cold launch, cancel/retry | Intended destination, draft protection and exact-token acknowledgement; no duplicate posting or private widget payload |
| Budget planning | Standalone and parent/child categories, monthly/currency allocation, over-budget state, moves/merges/archive | Approved fixed-cap/automatic rules; no double-counting; immediate correct parent/child totals and warnings |
| Flexible today | Explanation, per-category guidance, final day/month boundary, unclassified/unavailable states | Date, denominator, currency, exclusions and guidance agree; unavailable is never zero or stale authority |
| Recurring plans | Past-due/current/future, paused/ended, Review in Calendar, Post/Match/Skip | Earliest unresolved active item remains actionable; metadata never silently posts money |
| Accounts/assets | Add/edit/archive, asset/debt signs, multiple currencies, restricted allowance, manual investment value | Exact balances; no implicit FX; restricted value is separate; back navigation and draft protection work |
| Goals/loans/allowances | Contributions, repayments, benefit/prepaid/reimbursement flows, partial funding, correction | Ledger and planning evidence reconcile; no duplicate cash, false receivable or unauthorized restricted debit |
| Settings | Auto-lock, privacy, language, currency display, pins, guidance and reduced motion | Choices persist through lock/relaunch; EN/zh-Hans parity; five-tab identity remains intact |
| Accessibility | Largest Dynamic Type, VoiceOver, Reduce Motion/Transparency, increased contrast, keyboard | No clipped primary meaning; labelled 44-point controls; sensible focus order, errors and exits |
| Backup/recovery | Export verified `.moneyup` backup, preview/cancel, wrong password, valid restore in the test book, interruption | All-or-nothing replacement; exact currencies, history, preferences and unfinished draft preserved; actionable errors |

Do not simulate loss of the real device-bound key on the owner's installation.
Missing-key, corrupt-book and interrupted-erase fault injection remains covered
by isolated automated fixtures unless a separate disposable device/book is used.

## Result record

```text
Journey:
PASS / FAIL / BLOCKED:
Candidate SHA/build:
Device/iOS:
Language/appearance/accessibility:
Reporting/device zones:
Fictional fixture:
Observed taps/latency:
Observed outcome:
Privacy-safe evidence:
Remaining issue:
```

A completed row must name observed evidence. Leave missing hardware, user
interaction, VoiceOver, real screenshot accuracy and physical timing rows open.
