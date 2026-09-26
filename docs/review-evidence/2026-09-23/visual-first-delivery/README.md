# MoneyUp 0.7.2 — visual-first pass: 1064.1 withdrawn, 1065.1 submitted for public release

Delivered on 23 September 2026 from main commit
`ab1b333c8ddea7d8d985fe4f42d1596eb8b6a79f` (pull request #83, squash-merged
after all CI jobs passed on the exact head: validate, Core tests, Release
assets, iOS Simulator build, iPhone Simulator performance baseline,
native-review).

## Build

- Signed release build **0.7.2 (1064.1)**, IPA SHA-256
  `da63b51fd0e674480066c416252d9e8c43318a13f30b17f8f5548dd611431204`, uploaded by
  [TestFlight run 35815802201](https://github.com/LaiWenKang/MoneyUp/actions/runs/35815802201)
  (run 64). Secretless preflight, the StoreKit purchase integration gate, and
  signing all passed on the same revision. The encrypted release recovery
  bundle is retained as that run's artifact.
- Export compliance inherited from 1063.1
  ([run 35818609333](https://github.com/LaiWenKang/MoneyUp/actions/runs/35818609333))
  after confirming `Package.resolved`, `Package.swift`, `project.yml`, every
  entitlements file and every `Info.plist` are byte-identical between `cac08ff`
  (1063.1) and `ab1b333`. Receipt: `apple-compliance-1064.1.json`.
- Distributed to the internal TestFlight group with the new bilingual notes
  from `docs/TESTFLIGHT_WHATS_NEW.json`
  ([run 35818960386](https://github.com/LaiWenKang/MoneyUp/actions/runs/35818960386)).
  Receipt: `apple-internal-1064.1.json`.

## Public version

The owner asked for this build to replace 1059.1 in the pending public
submission.

1. Before: 0.7.2 `WAITING_FOR_REVIEW` on 1059.1 since 19 September; 0.7.1
   `READY_FOR_DISTRIBUTION` on 1051.1
   ([run 35811517593](https://github.com/LaiWenKang/MoneyUp/actions/runs/35811517593)).
   Receipt: `apple-inspect-public-before.json`.
2. Withdrawn: the pending review submission was cancelled
   ([run 35819102655](https://github.com/LaiWenKang/MoneyUp/actions/runs/35819102655));
   the version became `DEVELOPER_REJECTED` within two minutes. Receipt:
   `apple-withdraw-0.7.2.json`.
3. Prepared: build 1064.1 attached, bilingual What's New and review notes
   updated, all 16 screenshots replaced with renders of the new UI; the two
   existing previews were kept
   ([run 35819348156](https://github.com/LaiWenKang/MoneyUp/actions/runs/35819348156)).
   Receipt: `apple-prepare-0.7.2.json`.
4. Submitted with the three support products
   ([run 35819700497](https://github.com/LaiWenKang/MoneyUp/actions/runs/35819700497)).
   Receipt: `apple-submission-0.7.2.json`.
5. Final readback
   ([run 35819779669](https://github.com/LaiWenKang/MoneyUp/actions/runs/35819779669)):
   0.7.2 **`WAITING_FOR_REVIEW` on build 1064.1**, release type
   `AFTER_APPROVAL`; all three support products `WAITING_FOR_REVIEW`; en-US and
   zh-Hans each 8 screenshots and 1 preview `COMPLETE`. Receipt:
   `apple-inspect-public-0.7.2.json`.

Superseded the same day; see "Hotfix" below.

## Hotfix: 1064.1 crashed on device, replaced by 1065.1

1064.1 crashed on every Log-tab open on a physical iPhone (iPhone17,2,
iOS 27.0). The Log form's SwiftUI type nesting had grown from 98 to 108 and
overflowed the device main-thread stack; simulators have larger stacks, so no
simulator test could fail. Post-mortem: `docs/INCIDENT_2026-09-23_LOG_TAB_CRASH.md`.

1. The pending review was withdrawn at the owner's request before any decision
   ([run 35822345358](https://github.com/LaiWenKang/MoneyUp/actions/runs/35822345358)).
   Receipt: `apple-withdraw-1064.1.json`.
2. Fix merged as `2db53da3e49c92eb31a5dcb7a6a3b3d3c38fa72d` (pull request #85)
   after every CI job passed. The first run of "iOS Simulator build" failed
   only in the known-flaky StoreKit `DeveloperSupportTests`; rerun passed.
3. Signed build **0.7.2 (1065.1)**, IPA SHA-256
   `789e03c4ca8dd9991b39c5358a3f84350e3d9594258f25bbc5fbd75ff50da56b`, uploaded by
   [TestFlight run 35832255904](https://github.com/LaiWenKang/MoneyUp/actions/runs/35832255904)
   (run 65); preflight, StoreKit gate and signing passed.
4. Export compliance inherited from 1064.1 after confirming the
   encryption-relevant inputs are byte-identical to `cac08ff`
   ([run 35836852594](https://github.com/LaiWenKang/MoneyUp/actions/runs/35836852594)).
   Receipt: `apple-compliance-1065.1.json`.
5. Internal TestFlight distribution
   ([run 35837023029](https://github.com/LaiWenKang/MoneyUp/actions/runs/35837023029)).
   Receipt: `apple-internal-1065.1.json`. **The owner opened the build on a
   physical iPhone and confirmed it before resubmission.**
6. Prepared on 1065.1 with the same screenshots, previews and notes
   ([run 35844089080](https://github.com/LaiWenKang/MoneyUp/actions/runs/35844089080))
   and submitted with the three support products
   ([run 35844260249](https://github.com/LaiWenKang/MoneyUp/actions/runs/35844260249)).
   Receipts: `apple-prepare-0.7.2-1065.1.json`, `apple-submission-0.7.2-1065.1.json`.
7. Final readback
   ([run 35844425719](https://github.com/LaiWenKang/MoneyUp/actions/runs/35844425719)):
   0.7.2 **`WAITING_FOR_REVIEW` on build 1065.1**, `AFTER_APPROVAL`; all three
   support products `WAITING_FOR_REVIEW`; both locales 8 screenshots and 1
   preview `COMPLETE`. 0.7.1 (1051.1) remains live. Receipt:
   `apple-inspect-public-0.7.2-1065.1.json`.

Release is automatic after Apple approves; this record does not mean 0.7.2 is
already public.

## Known limits

- The app previews (18 s, stereo AAC) predate this pass and show the earlier
  row style; their soundtrack is produced outside the repository pipeline.
- The physical-device VoiceOver, large-text and grayscale checklist in
  `docs/UX_AUDIT_2026-09-23.md` remains open (QA-04/QA-06 manual gates).
- Banking, tax and the Paid Apps Agreement were not inspected or modified.
