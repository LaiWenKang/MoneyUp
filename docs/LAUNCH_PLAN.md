# MoneyUp Rollout Plan

Last updated: 28 August 2026

## Release decision

MoneyUp remains a native SwiftUI iPhone app. TestFlight is the controlled path
from founders beta to the App Store. The first public version is free, with no
ads, account, in-app purchase, bank aggregation, financial-data backend,
remote AI, or multi-device sync. Monetization or remote capabilities require a
later explicit product, privacy, and threat-model decision.

## Current position

| Area | Status | Release meaning |
|---|---|---|
| Product | Source-integrated 0.6.0 candidate, source build 8 | Golden functional surfaces are implemented across logging, Today/History/Insights, planning/goals, assets/investments, settings/widgets, portability, data, and security |
| Scale architecture | Implemented; Mac CI passed | SQLCipher schema 6 adds exact store metrics, normalized budget attribution, monthly carry checkpoints, compact balances, bounded recent activity, and on-demand reads; physical measurements remain open |
| Privacy | Source and policy aligned | Local processing, no tracking/backend, metadata-stripped optional encrypted receipts, and a percentage/state-only App Group widget snapshot |
| CI | Exact candidate passed | Run 141 passed release validation, 251 core/persistence tests, 213 app tests, coverage reporting, and the unsigned app/widget Simulator build on `41b44f60178485f76940c14175131ce2884c2f7f` |
| Backup scale | Source remediation and Mac CI passed; physical evidence open | Version 2 streams file-backed 1 MiB authenticated chunks across a 100,000-record/512 MB stored-payload envelope, so current accepted books have a complete export; interruption, near-limit v2, and compatible-v1 physical-memory evidence remain required |
| Apple capability | Manual account-holder action open | Register `group.com.laiwenkang.MoneyUp` and enable it on both existing App IDs before signed validation |
| Distribution | 0.5.1 installed; 0.6.0 not uploaded | Signed validation, upload, Apple processing, internal install, and external Beta App Review remain open |
| Physical QA | Open | Upgrade/restore, 10,000-entry/20-schedule performance, bilingual accessibility/widget matrix, and the founder/co-tester seven-day run remain open |
| Public release | Blocked | Closed beta, exact-binary compliance, App Review, manual release, and 72-hour operations evidence are not complete |

Source implementation is not a promotion decision. The per-requirement status
and evidence boundary is in [Golden PRD traceability](GOLDEN_TRACEABILITY.md).

## Stage 0 - exact source candidate

Target: one reviewable 0.6.0 commit whose source version is 0.6.0 build 8 and
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

- source marketing version 0.6.0 and source build 8 before assigning a unique
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
processing, add that exact build to **Founders Internal**. Update the account
holder's installed 0.5.1 build in place; never delete it as an upgrade procedure.

Complete [the founder/co-tester runbook](FIRST_TEST.md), including:

- pre/post inventory across profile, accounts, entries, budgets, goals,
  schedules, holdings/lots, rates, snapshots, attachments, settings, pending
  captures, widgets, and Keychain access;
- password-protected v2 archive restore on a clean/fresh install plus v1
  compatibility, wrong password, tampering/cancellation/failure atomicity, and
  near-limit memory observation;
- amount-keypad Done/Save/tab reachability and receipt/screenshot latency/error,
  orientation, and metadata-stripping fixture paths on the founder and co-tester
  iPhones;
- schedule post/match exactly once, split edit, lifecycle operations, rollover,
  goals, investment purchase/sale/reprice, and CSV/XLSX/import paths;
- every widget family in light/dark/tinted/redacted states, including opt-in
  percentage/state and opt-out scrubbing;
- English and Simplified Chinese, VoiceOver, largest Dynamic Type, Reduce
  Motion, smallest supported and current large iPhones;
- the Golden p95 budgets on the oldest supported iPhone with 10,000 entries and
  20 long-lived schedules.

Exit gate: no P0, no open/reproducible P1 in a core workflow, zero reproducible
crash in the candidate, reconciled financial results, and recorded version,
build, device, OS, language, and measurements.

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
0.6.0 public 1.0 and do not infer approval from a successful upload.

## Stage 6 - manual release and first 72 hours

After approval, the account holder manually releases 1.0. For 72 hours:

- check App Store Connect crashes, reviews, and support twice daily;
- stop phased release for any P0 or repeated P1;
- fix forward with a higher build number, never reuse an old build;
- preserve schema and archive backward compatibility;
- update release notes/privacy declarations whenever behavior changes.

## Remaining engineering and evidence queue

1. Apple App Group registration and signed entitlement validation.
2. Reconcile the signed candidate with the green exact-source CI evidence.
3. Physical 0.5.1-to-0.6.0 upgrade, clean-device v2 restore, compatible-v1
   restore, and receipt-heavy interruption/near-limit memory evidence.
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

MoneyUp 0.6.0 is ready for the founder/co-tester run only after exact-candidate
Mac CI, signed validation, physical smoke/upgrade/restore, and TestFlight
processing pass. It is ready for public 1.0 only after every physical,
accessibility, performance, recovery, beta, compliance, review, and exact-binary
gate above is recorded as passed.
