# MoneyUp Rollout Plan

Last updated: 24 August 2026

## Release decision

MoneyUp remains a native SwiftUI iPhone app. A web app would weaken the core
advantages already implemented: device-bound encrypted storage, Face ID or
Touch ID protection, WidgetKit quick entry, on-device receipt recognition,
offline operation, and a clean no-backend privacy claim.

TestFlight is the correct path from the founders beta to the App Store. The
first public version should be free, have no ads, no account, no in-app
purchases, and no financial-data backend. Monetization can be evaluated after
retention and reliability are proven.

## Current position

| Area | Status | Release meaning |
|---|---|---|
| Product | Founders Beta 0.3.0 | Core budget, ledger, calendar, insights, assets, widget, export, and bilingual flows exist |
| Privacy | Ready for founders beta | Local encrypted database, protected key, privacy cover, no tracking, privacy manifest, and public policy |
| CI | Active | Domain tests and unsigned app/widget Simulator build run on GitHub's macOS runner |
| Distribution | Blocked by Apple activation | Apple Developer Program was purchased and is awaiting confirmation |
| Recovery | Public-release blocker | CSV export exists; authenticated encrypted backup/restore does not |
| Physical QA | Not yet complete | The user and his girlfriend are the first planned iPhone testers |

Apple says that an individual who does not receive membership confirmation
within 24 hours of purchase should contact Apple Developer Support and include
the Enrollment ID: <https://developer.apple.com/help/account/membership/program-enrollment/>.

## Rollout stages and gates

### Stage 0 — Founders build preparation

Target: a green, reviewable 0.3.0 build that can be uploaded immediately after
membership activation.

Completed:

- encrypted, validated local ledger and device-owner authentication;
- English and Simplified Chinese product UI;
- privacy-redacted widget and on-device receipt/text entry;
- no ads, tracking, analytics SDK, backend, or remote AI;
- App Privacy manifest declaring no tracking or collected data and the required
  `UserDefaults` reason;
- bilingual in-app privacy and beta guidance plus public privacy/support pages;
- confirmed deletion of transactions, schedules, and manual holdings;
- release-asset CI validation for localizations, icons, privacy, and documents;
- non-restorable database ciphertext excluded from system backup.

Required before uploading 0.3.0:

- CI must pass on the exact commit to upload;
- configure the protected GitHub release environment with the active Apple
  team, distribution certificate, app and widget profiles, and a scoped App
  Store Connect API key;
- generate the Xcode project and archive on a GitHub-hosted macOS runner;
- confirm both app and widget bundle identifiers are registered and signable;
- run the 15-minute archive smoke test on a physical iPhone;
- confirm the archive contains `PrivacyInfo.xcprivacy`, both localizations, the
  widget extension, and version/build `0.3.0 (3)`;
- answer App Store Connect encryption questions accurately for SQLCipher;
- never commit certificates, provisioning profiles, API keys, or passwords.

### Stage 1 — First TestFlight distribution

Target: the account holder installs the same signed artifact that will be sent
to the second tester.

1. Accept current Apple Developer and App Store Connect agreements.
2. Register `com.laiwenkang.MoneyUp` and
   `com.laiwenkang.MoneyUp.Widget`, or select final unused equivalents before
   the first upload. After release, treat these identifiers as permanent.
3. Create the MoneyUp app record in App Store Connect with English and
   Simplified Chinese localizations and the Finance category.
4. Dispatch the protected GitHub release workflow to archive and upload build
   3. Do not use a ChatGPT-hosted preview link as distribution.
5. Complete export-compliance processing and wait for build processing.
6. Create the internal TestFlight group **Founders Internal** and add the
   account holder.
7. Install through Apple's TestFlight app and complete the smoke section in
   `FIRST_TEST.md`.

The girlfriend should be the first **external** tester. This avoids granting
her App Store Connect access merely to test the app. Create a private external
group named **Founders External**, add only her email, add the already-tested
build, and submit it for TestFlight Beta App Review. She needs an Apple Account
and the TestFlight app; she does not need Gmail specifically, ChatGPT, a
MoneyUp login, or access to the source repository.

Apple's current TestFlight documentation is here:
<https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview>.

### iPhone-only release administration

The account holder does not need to buy a Mac for the chosen release path.
After membership activation, Apple account actions can be completed in Safari
on the iPhone, and GitHub's macOS runner can perform the Xcode archive. The
bootstrap sequence is:

1. Request App Store Connect API access, then create a least-privilege API key.
2. Generate a private key and certificate-signing request offline.
3. In the Apple Developer portal, issue one Apple Distribution certificate and
   create App Store profiles for the app and widget identifiers.
4. Convert the certificate to a password-protected PKCS#12 file and store the
   certificate, profiles, API key, team ID, and passwords only as protected
   GitHub environment secrets.
5. Add a manual release workflow that imports those secrets into an ephemeral
   macOS keychain, generates the project, runs tests, archives, validates, and
   uploads. Require environment approval and allow it only from a protected
   commit or tag.
6. Delete temporary local credential files after the secrets are stored and
   retain an offline recovery copy controlled by the account holder.

Exact certificate/profile identifiers do not exist until membership and bundle
registration are active, so the upload workflow is deliberately enabled only
after those values can be verified. Xcode Cloud is not the bootstrap choice:
Apple currently requires the first Xcode Cloud workflow to be configured from
Xcode on a Mac. It remains an optional later migration.

### Stage 2 — Two-person founders test

Target: seven consecutive days of realistic daily use without a critical
defect.

Each tester should complete:

- onboarding in a different app language;
- at least three account types and 25 transactions;
- expense, income, same-currency transfer, and one foreign-currency transfer;
- nested budgets at two or more levels;
- one weekly or monthly scheduled item;
- one manual investment holding if applicable;
- receipt/screenshot reading and typed smart entry;
- widget installation and both quick-log shortcuts;
- background lock/unlock at least ten times;
- one transaction deletion, one schedule deletion, and one holding deletion
  using sample records;
- two CSV exports opened in Numbers or Excel;
- one app update from an earlier TestFlight build without losing data.

Exit gate:

- no P0 defect;
- no open P1 defect in onboarding, unlock, save, calculation, export, or update;
- zero reproducible crashes in the final candidate;
- ledger balances, category roll-ups, and reports agree with the testers'
  sample ledger;
- all common screens are usable in English and Simplified Chinese;
- both testers affirm that routine logging is quick enough to sustain.

### Stage 3 — Closed external beta

Target: 10–25 invited testers, not a public link, over at least two release
candidates.

Required before this stage:

- add transaction search and editing, or clearly retain delete-and-recreate as
  the documented correction workflow;
- add schedule and holding editing;
- complete VoiceOver, Dynamic Type, contrast, dark mode, and Reduce Motion
  checks on common tasks;
- add bilingual UI automation for onboarding, logging, deletion, export, and
  background lock on representative iPhone sizes;
- add performance tests for at least 10,000 entries and long recurrence ranges;
- complete the first authenticated encrypted backup/restore design, threat
  review, and recovery drill;
- prepare sanitized sample data and screenshot capture instructions;
- triage TestFlight feedback within 48 hours during the beta.

Promotion gate:

- 14 days without P0;
- all P1 issues resolved and verified in a newer build;
- update migration and restore drills pass;
- no untranslated or clipped common flow;
- privacy manifest and App Privacy answers still match the binary.

### Stage 4 — App Store candidate

Public release is blocked until these are complete:

- versioned authenticated `.moneyup` archive export and transactional restore;
- restore tests for wrong password, tampering, duplicate records, interrupted
  import, older supported archive, and unsupported future archive;
- final accessibility test matrix and honest Accessibility Nutrition Labels;
- final performance and energy check on the oldest supported iPhone class;
- app privacy, privacy-policy URL, support URL, age rating, content rights,
  export compliance, and EU Digital Services Act trader-status declaration;
- localized store description, keywords, review notes, and 1–10 screenshots in
  an accepted current iPhone size without real financial information;
- App Review receives complete access instructions explaining that no account
  is required and how to create a sample local book;
- choose manual release after approval for version 1.0 so the team controls the
  launch moment.

The working metadata and review copy live in `APP_STORE_SUBMISSION.md`.

### Stage 5 — Public 1.0 and operations

Release 1.0 gradually after approval. For the first 72 hours:

- monitor App Store Connect crashes, reviews, and support reports twice daily;
- stop phased release for any P0 or repeated P1;
- fix forward with a higher build number—never attempt to upload an old build;
- preserve database schema backward compatibility across patch releases;
- publish updated release notes, privacy answers, and policy whenever behavior
  changes;
- review SQLCipher and GitHub Actions dependency updates weekly;
- keep CI failure monitoring enabled.

## Engineering queue

Priority order:

1. **P0 — encrypted backup and restore:** public release cannot responsibly
   promise ownership without recoverability.
2. **P1 — transaction/schedule/holding editing and search:** corrections must
   not depend on deletion once more users join.
3. **P1 — UI automation and accessibility:** cover both languages and the
   common iPhone form factors.
4. **P1 — large-ledger performance:** establish explicit time and memory
   budgets for 10,000 and 100,000 entries.
5. **P2 — CSV import with duplicate preview:** useful after backup is proven.
6. **P2 — exchange-rate preferences, budget rollover, goals, and net-worth
   history:** product depth after reliability.
7. **Deferred — sync, shared household books, bank aggregation, and hosted AI:**
   each requires a separate privacy and threat-model decision.

## Release ownership

| Work | Engineering | Apple account holder |
|---|---|---|
| Code, tests, migrations, privacy manifest, release docs | Own | Review |
| Certificates, agreements, legal identity, tax/banking, trader status | Advise | Own |
| App Store Connect record and tester groups | Prepare exact steps | Execute/approve |
| Physical-iPhone test | Supply runbook and triage | Execute with girlfriend |
| Store screenshots and copy | Prepare | Approve truthful final version |
| Submission and release button | Verify candidate | Execute |

No collaborator needs to receive the account holder's Apple password. App
Store Connect roles, scoped API keys, or a supervised screen-sharing session
are the correct mechanisms when access is eventually needed.

## Risk register

| Risk | Control | Release gate |
|---|---|---|
| Device loss before backup ships | Small sample data plus regular CSV export | Blocks public release, not founders test |
| Incorrect finance calculations | Exact decimals, balanced entries, unit tests, manual sample reconciliation | Blocks every candidate |
| Privacy claim drifts from binary | Manifest/document CI and no network dependencies | Blocks every candidate |
| Accidental deletion | Confirmation dialogs and sample-only destructive testing | Verified in founders test |
| Apple membership or review delay | Finish code, metadata, policy, and QA in parallel | Distribution waits; engineering continues |
| Certificate or secret exposure | Keep secrets out of Git and use Apple/GitHub secret stores | Immediate P0 response |
| App update corrupts data | Versioned schema, migration fixtures, physical update test | Blocks broader beta |
| Accessibility claim is inaccurate | Common-task matrix before publishing labels | Blocks App Store submission |

## Definition of ready

MoneyUp is ready for the two founders when membership is active, CI is green,
a signed 0.3.0 build passes the physical smoke test, and TestFlight has finished
processing it. It is ready for the public only after encrypted restore is
proven, all P0/P1 gates above pass, and the exact submitted binary matches the
reviewed privacy and store declarations.
