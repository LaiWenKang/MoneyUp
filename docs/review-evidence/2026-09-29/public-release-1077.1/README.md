# 0.7.3 (1077.1): TestFlight delivery and public-release preparation, 29 September 2026

Build 1077.1 is `main` at `d286cbb` (release material in #118, on top of #98 to
#117): camera receipt scanning, reminders, Home Screen quick actions, the Focus
filter, Siri Suggestions and tips, Log after auto-lock without Face ID, History
search across every date, the SQLCipher raw-key move (#104) and the speed work.

## Owner decisions (29 September)

- Finish the open pull requests, then take 0.7.3 to TestFlight, App Store
  Connect and the App Store. All four release pull requests (#115, #116, #117,
  #118) are merged.
- Leave 0.7.2 (1076.3) in App Review. It is not withdrawn; 0.7.3 is submitted
  after Apple clears it.
- The physical-iPhone check in `docs/INCIDENT_2026-09-23_LOG_TAB_CRASH.md` is
  **not** waived for this build. The owner checks 1077.1 on their iPhone first
  (update over 0.7.2, every tab, receipt scan, reminders, Focus filter, widget to
  Log after auto-lock), and public submission waits for that.

## Sequence

| Step | Run | Result | Receipt |
|---|---|---|---|
| Merge #118 | `d286cbb` | five required checks passed | none |
| Signed upload from `d286cbb` | `testflight.yml` run 77 (36523144414) | StoreKit integration, secretless preflight, sign and deliver passed on attempt 1, so the build is **1077.1** | none (workflow logs) |
| Inherit compliance from 1076.3 | `testflight-testers.yml` 36526912545 | `uses_non_exempt_encryption: false`; France unavailable, future countries off | `apple-compliance-1077.1.json` |
| Distribute to internal testers | 36527520728 | processing `VALID`; internal `IN_BETA_TESTING`; 3 of 3 testers covered | `apple-distribute-internal-1077.1.json` |
| Distribute to external testers | 36527728415 | external `WAITING_FOR_BETA_REVIEW`; 4 of 4 testers covered | `apple-distribute-1077.1.json` |
| Prepare 0.7.3 (probe) | `appstore.yml` 36527852911 | build, availability, config and media pre-checks passed; App Store Connect answered HTTP 409 `ENTITY_ERROR.RELATIONSHIP.INVALID` when creating version 0.7.3 because 0.7.2 is `WAITING_FOR_REVIEW`. Nothing changed. | none (workflow log) |
| Read-back | `appstore.yml` 36578456264 | 0.7.2 `WAITING_FOR_REVIEW` on 1076.3 (submitted on the evening of 27 September); 0.7.1 (1051.1) live; support tips `WAITING_FOR_REVIEW`; France excluded; 175 territories | `appstore-inspect-1077.1.json` |

App Store Connect refuses a second version while 0.7.2 is in review, so 0.7.3
cannot be created until 0.7.2 leaves review. If 0.7.2 were ever withdrawn to make
way, the likely route is to rename its editable version to 0.7.3 rather than
create a new one; that has not been tried on this account.

## Compliance basis

Between the sources of 1076.3 (`92b1680`) and 1077.1 (`d286cbb`), `Package.swift`,
`Package.resolved`, entitlements and Info.plists are unchanged. `project.yml`
changes only the marketing version and adds `NSCameraUsageDescription`;
`PrivacyInfo.xcprivacy` adds the required-reason declarations from #117. The only
cryptography change is how the database key is handed to SQLCipher (raw-key form
instead of passphrase form, #104). The encryption itself (AES-256 pages,
HMAC-SHA512 per page) is unchanged, and no algorithm, dependency or entitlement
was added, so 1076.3's declaration still applies (`encryption_unchanged=true`).

## Still open

- Physical-iPhone acceptance of 1077.1, including the database key move on an
  update over 0.7.2.
- Beta App Review for the external testers.
- Apple's review of 0.7.2. After it clears: `appstore.yml` prepare, then submit
  for 0.7.3 with build 1077.1.
