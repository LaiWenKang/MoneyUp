# MoneyUp Rollout Plan

Last updated: 2 September 2026

## Release decision

MoneyUp remains a native SwiftUI iPhone app. TestFlight is the controlled path
from founders beta to the App Store. The first public version is free, with no
ads, account, in-app purchase, bank aggregation, financial-data backend,
remote AI, or multi-device sync. Monetization or remote capabilities require a
later explicit product, privacy, and threat-model decision.

## Current position

| Area | Status | Release meaning |
|---|---|---|
| Product | Complete 0.7.1 feedback follow-up merged through PR #40 as `68eee4f8`; source build 10 | Keyboard-safe and smarter Log, richer widget capture, daily History, retained Calendar, arbitrary-depth categories, budget pacing, expiring allowances, and ledger-linked loans are integrated; physical acceptance remains open |
| Scale architecture | SQLCipher schema 8 implemented; merged-main CI passed | Exact store metrics, normalized budget attribution, monthly carry checkpoints, compact balances, bounded recent activity, on-demand reads, payload-free intelligence indexes, and recovery coverage for loan/allowance records are integrated; physical measurements remain open |
| Privacy | Source and policy aligned | Local processing, no tracking/backend, metadata-stripped optional encrypted receipts, and a percentage/state-only App Group widget snapshot |
| CI | Exact PR head and merged 0.7.1 implementation passed | Runs [300](https://github.com/LaiWenKang/MoneyUp/actions/runs/33628781671) and [301](https://github.com/LaiWenKang/MoneyUp/actions/runs/33630422384) passed release/structure validation, Core/persistence/intelligence tests, 355 app-model tests, coverage reporting, unsigned app/widget Simulator build, and serial performance baseline; this does not close physical or signed exact-binary gates |
| Automated scale baseline | Exact 0.7.1 candidate and merged implementation passed | The serial Release XCTest target seeds the SHA-bound intelligence-v1 10,000-entry corpus and 20 schedules outside measured blocks, checks detector/operation invariants, and retains raw/JSON clock, CPU, memory, and logical-write evidence on an exact iPhone 16 Pro/iOS 18.5 Simulator; Simulator measurements do not close physical ceilings |
| Backup scale | Source remediation and Mac CI passed; physical evidence open | Version 2 streams file-backed 1 MiB authenticated chunks across a 100,000-record/512 MB stored-payload envelope, so current accepted books have a complete export; interruption, near-limit v2, and compatible-v1 physical-memory evidence remain required |
| Apple capability | 0.7.1 signed validation pending | Earlier signed results cannot be reused for the changed schema-8 binary. TestFlight run 24 stopped in preflight before signing/upload; the corrected 0.7.1 release-truth SHA must repeat the protected validate operation |
| Distribution | 0.7.0 (1025.1) accepted for processing; 0.7.1 not uploaded | Confirm 0.7.0 processing, Founders Internal availability, and installed predecessor build in App Store Connect; validation or upload alone is not installation evidence |
| Physical QA | Open | Upgrade/restore, 10,000-entry/20-schedule performance, bilingual accessibility/widget matrix, and the founder/co-tester seven-day run remain open |
| Public release | Blocked | Closed beta, exact-binary compliance, App Review, manual release, and 72-hour operations evidence are not complete |

Source implementation is not a promotion decision. The per-requirement status
and evidence boundary is in [Golden PRD traceability](GOLDEN_TRACEABILITY.md).

## Stage 0 - exact source candidate

Target: one reviewable 0.7.1 commit whose source version is 0.7.1 build 10 and
whose app/widget/localization/privacy/release documents agree.

Required:

- review the unified `AppModel`, persistence, `RecordCollection`,
  reporting-calendar, rate, goal, snapshot, and widget paths for semantic
  conflicts;
- run release-asset validation and verify both localization catalogs parse with
  complete English/Simplified Chinese values;
- generate the Xcode project on macOS, run core/persistence tests with warnings
  as errors, run app-model XCTest on a booted iPhone Simulator, and build the
  app plus widget without signing;
- run the serial Release measurement baseline on its exact iPhone 16 Pro/iOS
  18.5 Simulator and retain the environment, metric/summary/file-manifest JSON, log, and raw
  result bundle described in [the performance guide](PERFORMANCE_BASELINE.md);
- record the exact commit and keep every failed check open; do not promote a
  different working tree based on partial results.

Exit gate: all exact-candidate Mac checks green, no unresolved P0/P1 defect, and
the candidate still matches the Golden traceability table.

## Stage 1 - Apple capability and signed validation

The account holder performs these actions without sharing Apple credentials:

1. Register App Group `group.com.laiwenkang.MoneyUp` if it does not already
   exist.
2. Enable only that App Group capability on both explicit App IDs:
   `com.laiwenkang.MoneyUp` and `com.laiwenkang.MoneyUp.Widget`.
3. Verify current agreements, the existing `MoneyUp: CowCome` app record, the
   protected GitHub `testflight` environment, and export-compliance readiness.
4. Dispatch the TestFlight workflow from the final `main` commit in `validate`
   mode, either through **Actions** or by posting the exact owner-only command
   `/moneyup-testflight validate` on
   [release-control issue #23](https://github.com/LaiWenKang/MoneyUp/issues/23).
   The issue relay pins the authorized `main` SHA, and TestFlight preflight
   rejects the run if `main` moved before it started.

The workflow must verify:

- source marketing version 0.7.1 and source build 10 before assigning a unique
  upload build number;
- the exact dispatched commit, Xcode/toolchain, immutable dependencies, release
  assets, tests, and app/widget build;
- source app/widget entitlement files contain only the reviewed App Group;
- the exported app and widget have correct IDs, versions, distribution
  profiles, team, signatures, no development/enterprise profile, and matching
  signed App Group entitlements;
- Apple accepts IPA validation.

Exit gate: signed validation succeeds for the exact IPA and its SHA-256 is
recorded. Validation does not create the upload-only encrypted recovery artifact
and does not mean a TestFlight upload or App Review occurred.

## Stage 2 - internal TestFlight and physical acceptance

After a separately confirmed upload, verify the encrypted recovery artifact was
retained before the upload step and contains the archive/dSYMs, complete export
directory, exact validated IPA, and matching SHA-256 manifest. After Apple
processing, add that exact build to **Founders Internal**. First confirm the
exact predecessor installed on the founder device; the expected predecessor is
0.7.0 (1025.1) once processing and group availability are confirmed. Update it
to 0.7.1 in place; never delete the app as an upgrade procedure. If the expected
predecessor is unavailable, record the actual build and keep that upgrade cell
open rather than inferring a pass.

Complete [the founder/co-tester runbook](FIRST_TEST.md), including:

- pre/post inventory across profile, accounts, entries, category hierarchy,
  budgets/pacing, goals, loans, allowances, schedules, holdings/lots, rates,
  snapshots, attachments, settings, pending captures, widgets, and Keychain
  access;
- password-protected v2 archive restore on a clean/fresh install plus v1
  compatibility, wrong password, tampering/cancellation/failure atomicity, and
  near-limit memory observation;
- real-current-time and history-informed editable defaults; amount/account/
  title/notes/split keyboard reachability; Today/seven-day/month/all History
  totals; visible descriptive text/category paths; direct Calendar access; and
  receipt/screenshot latency/error, orientation, and metadata-stripping paths;
- arbitrary-depth category creation/reparent rejection, exact daily/weekly
  budget pacing, expiring allowance cadence/rollover, and loan drawdown/
  repayment/finish-at-zero accounting;
- schedule post/match exactly once, split edit, lifecycle operations, rollover,
  goals, investment purchase/sale/reprice, and CSV/XLSX/import paths;
- every widget family in light/dark/tinted/redacted states, including full Log
  routing while available, locked amount/title/notes capture with protected
  category/account deferral, opt-in percentage/state, and opt-out scrubbing;
- English and Simplified Chinese, VoiceOver, largest Dynamic Type, Reduce
  Motion, smallest supported and current large iPhones;
- the Golden p95 budgets on the oldest supported iPhone with 10,000 entries and
  20 long-lived schedules.

Exit gate: no P0, no open/reproducible P1 in a core workflow, zero reproducible
crash in the candidate, reconciled financial results, and recorded version,
build, device, OS, language, and measurements.

### Explainable-capture physical procedure

Run this procedure on the oldest supported iPhone and a current large iPhone
against the exact signed release-truth SHA; record device, OS, book size, language,
appearance, accessibility settings, timings, and screenshots:

1. Seed three matching-payee entries plus competing category/account history.
   Use Smart Entry in English and Simplified Chinese. Confirm only the
   high-confidence untouched fields prefill, count/date evidence is readable,
   changing payee/date removes stale auto-applied values, and a user or pinned
   choice is never overwritten.
2. With the keyboard visible, switch through Today, History, Log, Plan, and
   Assets and return to Log. The exact unfinished values and confidence/evidence
   must remain; no Save occurs. Unsaved receipt image bytes and their retention
   toggle must be gone, because receipt images are not part of the durable
   draft.
3. Scan at least 20 representative English/Chinese receipts and payment
   screenshots, including rotated, blurred, comma-decimal, JPY, and CJK cases.
   Record Vision-to-review and post-Vision parse p50/p95, top payable-amount
   correctness, and every fallback. Target p95 is 4 seconds end-to-end, 100 ms
   post-Vision, at least 90% top payable-amount accuracy, and zero
   low-confidence prefills. Manual entry must remain immediately available.
4. Create exact and near-match expense, income, refund, same-currency transfer,
   and dated foreign-transfer cases. Confirm only exact money/currency/directed
   legs advise, Review opens the attributed History day, Cancel changes
   nothing, Save anyway creates exactly one entry, repeated taps do not create
   another, and Undo/Edit use existing revision behavior.
5. Repeat scan, suggestion generation, advisory, and Save while backgrounding
   and locking. No stale result, cross-book/account suggestion, retained source
   image, sensitive app-switcher content, or duplicate commit may appear after
   unlock. Exercise app, widget, Shortcut/App Intent, and URL launch paths with
   locked capture both enabled and disabled.
6. On an eligible iOS 26 device, verify the separately opted-in Foundation
   Models path in English and Simplified Chinese: closed existing-name choices
   only, visible provenance, one-tap rejection, no automatic Save, and silent
   deterministic fallback for disabled Apple Intelligence, cancellation, and
   unavailable hardware. Retain network evidence showing no request.
7. Repeat the changed surfaces in both languages, light/dark mode, largest
   Dynamic Type, VoiceOver, and Reduce Motion. Currency must be announced and
   status meaning must remain available without color. Capture before/after
   screenshots for normal, low-confidence, duplicate-review, and locked states.

Any wrong-money result, low-confidence prefill, stale cross-context suggestion,
duplicate commit, retained unselected receipt, inaccessible action, sustained
main-thread stall, or p95 miss fails this gate. Physical execution and
screenshots are currently pending; source or Simulator evidence cannot close it.

## Stage 3 - founder/co-tester seven-day run

Invite the co-tester through the private **Founders External** group only
after internal acceptance and TestFlight Beta App Review. For seven consecutive
days both testers log, correct, plan, unlock, back up, update, and independently
reconcile representative data.

Exit gate:

- no P0 for seven days;
- no open P1 and all fixes verified in a newer build;
- both testers affirm routine logging is sustainable;
- the final book reconciles across balances, budgets, goals, Calendar,
  investments, widget status, reports, and readable exports.

## Stage 4 - closed external beta

Target: 10-25 invited testers, no public link, for at least 14 days and at least
two release candidates.

Required:

- update and clean-restore drills remain green;
- no untranslated, clipped, inaccessible, or misleading common flow;
- performance/energy evidence remains within budget;
- privacy manifest, policy, App Privacy answers, entitlements, and observed
  network behavior match the exact binary;
- feedback is triaged within 48 hours.

Promotion gate: 14 days without P0, all P1 resolved and reverified, no data
continuity regression, and owner approval of the evidence pack.

## Stage 5 - App Store 1.0 candidate

Public submission remains blocked until:

- exact archive/build, dSYMs, metadata, screenshots, review notes, privacy
  answers, languages, entitlements, support contact, age rating, content rights,
  export compliance, and trader-status declaration agree;
- final accessibility, performance, recovery, migration, and physical matrices
  pass;
- App Review can create a sample local book without a demo account and can
  inspect every claimed capability;
- the account holder chooses manual release after approval.

The working copy is [App Store submission](APP_STORE_SUBMISSION.md). Do not call
0.7.1 public 1.0 and do not infer approval from a successful upload.

## Stage 6 - manual release and first 72 hours

After approval, the account holder manually releases 1.0. For 72 hours:

- check App Store Connect crashes, reviews, and support twice daily;
- stop phased release for any P0 or repeated P1;
- fix forward with a higher build number, never reuse an old build;
- preserve schema and archive backward compatibility;
- update release notes/privacy declarations whenever behavior changes.

## Remaining engineering and evidence queue

1. Complete this 0.7.1 release-truth synchronization, require exact-head and
   merged-main CI, then run the protected signed validation operation on that
   unchanged SHA; do not reuse an earlier binary result.
2. Confirm 0.7.0 (1025.1) processing, tester-group availability, and installed
   predecessor state; Apple accepting an upload is not installation evidence.
3. After separately authorized 0.7.1 upload and processing, run physical
   predecessor-to-0.7.1 upgrade continuity, clean-device v2 restore,
   compatible-v1 restore, and receipt-heavy interruption/near-limit memory
   evidence.
4. Oldest-device 10,000-entry/20-schedule cold-start, monthly-checkpoint,
   rollover, and interaction measurements.
5. Bilingual accessibility, appearance, widget, and metadata-stripped receipt
   matrices.
6. Founder/co-tester seven-day run and 14-day closed beta.
7. Exact-binary store compliance, App Review, manual release, and monitoring.

Sync, shared books, bank aggregation, automatic market pricing, hosted AI,
two-way spreadsheet editing, and commerce remain outside this queue because
they are not approved 1.0 requirements.

## Ownership

| Work | Engineering | Apple account holder |
|---|---|---|
| Code, tests, migrations, manifest, release documents | Own | Review |
| Agreements, legal identity, tax/banking, trader status | Advise | Own |
| App Group, App IDs, app record, tester groups | Prepare exact steps | Execute/approve |
| Physical iPhone tests | Supply runbook and triage | Execute with tester |
| Store screenshots/copy | Prepare | Approve against exact binary |
| Submission and manual release | Verify candidate/evidence | Execute |

No collaborator needs the account holder's Apple password. Use protected
environment secrets, scoped App Store Connect roles/API keys, or supervised
screen sharing when account access is required.

## Definition of ready

MoneyUp 0.7.1 is ready for the founder/co-tester run only after exact-candidate
Mac CI, signed validation, physical smoke/upgrade/restore, and TestFlight
processing pass. It is ready for public 1.0 only after every physical,
accessibility, performance, recovery, beta, compliance, review, and exact-binary
gate above is recorded as passed.
