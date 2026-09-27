# 0.7.2 (1075.1): public resubmission of the audit build, 26 September 2026

Build 1075.1 replaces 1065.1 in App Review. 1065.1 had waited since 23 September
with automatic release on approval, and predated the audit fixes on `main`
(#92 audit, #93 S1, #94 P1). Those fixes include the Critical schedule/backup
defect (T1), amount entry in zero-decimal currencies (M1) and statement rows
lost on import (P1).

## Owner decisions (26 September)

- Withdraw 1065.1 now rather than wait for the replacement.
- Submit 1075.1 **without** the physical-iPhone check that
  `docs/INCIDENT_2026-09-23_LOG_TAB_CRASH.md` requires. The owner waived it for
  this build only. `testScreenTypesStayWithinDeviceSafeDepth` still guards the
  device-only type-depth crash in CI.
- Distribute 1075.1 to the existing TestFlight testers, internal and external.
- Merge #95 (refreshed store media and notes) before preparing the version.

## Sequence

| Step | Run | Result | Receipt |
|---|---|---|---|
| App Store inspect | `appstore.yml` 36214904092 | 0.7.2 `WAITING_FOR_REVIEW` on 1065.1; 0.7.1 (1051.1) live | `appstore-inspect-before.json` |
| Withdraw 1065.1 | `appstore.yml` 36218123624 | submission `CANCELING` | `appstore-withdraw-1065.1.json` |
| Signed upload from `3e89bb0` | `testflight.yml` run 75 (36218172419) | StoreKit integration, secretless preflight, sign and deliver: all passed | none (workflow logs) |
| Build visible and processed | `testflight-testers.yml` 36220308434 | `VALID`, `MISSING_EXPORT_COMPLIANCE` | `apple-inspect-1075.1.json` |
| Inherit compliance from 1074.1 | 36220399882 | `uses_non_exempt_encryption: false` | `apple-compliance-1075.1.json` |
| Distribute to all testers | 36221834531 | internal `IN_BETA_TESTING`; external `WAITING_FOR_BETA_REVIEW`; 4/4 testers covered | `apple-distribute-1075.1.json` |
| Merge #95 | `a705ba9` | new screenshots, previews, What's New, TestFlight notes | none |
| Refresh tester notes | 36223105207 | notes from `a705ba9`; no second notification (external still in Beta Review) | `apple-distribute-notes-1075.1.json` |
| Prepare 0.7.2 | `appstore.yml` 36223024835 | build 1075.1 linked; 16 screenshots and 2 previews uploaded | `appstore-prepare-1075.1.json` |
| Media check | `appstore.yml` 36223139704 | `PREPARE_FOR_SUBMISSION`; all media `COMPLETE`; three tips `READY_TO_SUBMIT` | none |
| Submit | `appstore.yml` 36223183916 | `WAITING_FOR_REVIEW`, `AFTER_APPROVAL` | `appstore-submit-1075.1.json` |
| Read-back | `appstore.yml` 36223231654 | 0.7.2 `WAITING_FOR_REVIEW` on 1075.1; tips `WAITING_FOR_REVIEW`; France excluded; 175 territories | `appstore-inspect-after.json` |

## Compliance basis

Between the sources of 1074.1 (`50e4d92`) and 1075.1 (`3e89bb0`), `Package.swift`,
`Package.resolved`, `project.yml`, entitlements and Info.plists are unchanged.
The only cryptography change removes the retired locked-favourites store's
CryptoKit AES-GCM use (one Log for widgets, #92). No algorithm or dependency was
added, so 1074.1's declaration still applies (`encryption_unchanged=true`).

## Replacement by 0.7.2 (1076.3), the same day

On 1075.1 the owner found that every Quick Log tap asked "Unfinished
transaction" over a Log form holding only an account and a category (#97 has
the cause and fix). Owner decision: replace 1075.1 in review once the fix
passed CI.

| Step | Run | Result | Receipt |
|---|---|---|---|
| Merge #97 | `92b1680` | all five PR checks passed | none |
| Signed upload | `testflight.yml` run 76 (36231883549) | attempts 1 and 2 failed the StoreKit gate ("Could not find a UI anchor", a stalled local purchase); attempt 3 passed, so the build is **1076.3**. Root-cause fix proposed in #98. | none |
| Processed | `testflight-testers.yml` 36235759878 | `VALID` | `apple-inspect-1076.3.json` |
| Inherit compliance from 1075.1 | 36235833546 | `uses_non_exempt_encryption: false`; `a705ba9`→`92b1680` changes only Log logic | `apple-compliance-1076.3.json` |
| Distribute | 36235860934 | both groups assigned; internal `IN_BETA_TESTING`. The external Beta App Review submission got HTTP 422 because 1075.1 is still `WAITING_FOR_BETA_REVIEW` (one build at a time); resubmit once it clears. | `apple-testers-1076.3.json` |
| Withdraw 1075.1 | `appstore.yml` 36235892317 | `CANCELING` → `DEVELOPER_REJECTED` | `appstore-withdraw-1075.1.json` |
| Prepare with 1076.3 | 36236051377 | build linked; media already processed (config digest unchanged) | `appstore-prepare-1076.3.json` |
| Submit | 36236085823 | `WAITING_FOR_REVIEW`, `AFTER_APPROVAL` | `appstore-submit-1076.3.json` |
| Read-back | 36236126402 | 0.7.2 `WAITING_FOR_REVIEW` on 1076.3; tips in review; France excluded; 175 territories | `appstore-inspect-after-1076.3.json` |
