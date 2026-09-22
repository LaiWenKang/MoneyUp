# MoneyUp 0.7.2 (1060.1, 1061.1 and 1063.1) — build 1059.1 feedback delivery

Delivered to App Store Connect on 22 September 2026 from main commit
`4cd0ad92eb4d6a762a74c782e4e5276c59f9026c` (pull request #75, squash-merged after all five CI jobs passed on the exact head).

- Signed release build **0.7.2 (1060.1)**, IPA SHA-256 `3da024690c99d698848e51078706f9e6d177670352f16c883fa6983dae345aee`, uploaded by [TestFlight run 35677332908](https://github.com/LaiWenKang/MoneyUp/actions/runs/35677332908). The run's StoreKit purchase integration gate and secretless preflight passed on the same revision. The encrypted release recovery bundle is retained as that run's artifact.
- Export compliance: the exempt answer (`uses_non_exempt_encryption: false`) was inherited from 1059.1 after confirming `Package.resolved`, `Package.swift`, the entitlements, `Info.plist` and `project.yml` are byte-identical to the 1059.1 source ([run 35680630571](https://github.com/LaiWenKang/MoneyUp/actions/runs/35680630571)). Receipt: `apple-compliance-1060.1.json`.
- App Store Connect readback ([run 35680704659](https://github.com/LaiWenKang/MoneyUp/actions/runs/35680704659)): processing `VALID`, internal TestFlight `IN_BETA_TESTING` (existing internal group of 3 testers; the external group was not assigned), external `READY_FOR_BETA_SUBMISSION`. Receipt: `apple-inspect-1060.1.json`.
- Public version state before delivery ([run 35674643217](https://github.com/LaiWenKang/MoneyUp/actions/runs/35674643217)): **0.7.2 (1059.1) is still `WAITING_FOR_REVIEW`** with all three support products; 0.7.1 (1051.1) remains `READY_FOR_DISTRIBUTION`. Receipt: `apple-inspect-public-0.7.2.json`.

## Second delivery: 0.7.2 (1061.1)

Main commit `911e480` (pull request #77: locked widget captures open straight in Log, History capture card with Open in Log / Discard, Log recent-entry capsules and one-row smart entry, release notes).

- Signed build **0.7.2 (1061.1)**, IPA SHA-256 `16f8b6cd8cc5170eedd544d7e70b0c9c5d700900b0a29a6367ec6db182991eb1`, uploaded by [TestFlight run 35696302418](https://github.com/LaiWenKang/MoneyUp/actions/runs/35696302418); StoreKit gate and secretless preflight passed on the same revision.
- Export compliance inherited from 1060.1 after confirming the encryption-relevant inputs are unchanged ([run 35701032178](https://github.com/LaiWenKang/MoneyUp/actions/runs/35701032178)). Receipt: `apple-compliance-1061.1.json`.
- **Distributed to the internal TestFlight group with the bilingual test notes** from `docs/TESTFLIGHT_WHATS_NEW.json` ([run 35701089479](https://github.com/LaiWenKang/MoneyUp/actions/runs/35701089479)). Receipt: `apple-internal-1061.1.json`.
- Readback ([run 35701197392](https://github.com/LaiWenKang/MoneyUp/actions/runs/35701197392)): processing `VALID`, internal `IN_BETA_TESTING` (3 internal testers covered), external `READY_FOR_BETA_SUBMISSION`. Receipt: `apple-inspect-1061.1.json`.
- Apple needed roughly eight minutes after upload before the build was visible to the API; the first compliance attempt failed with "Expected exactly one matching iOS build" and succeeded once processing completed.
- The public 0.7.2 version remains `WAITING_FOR_REVIEW` on 1059.1; see "Not done, by design" above.

## Third delivery: 0.7.2 (1063.1)

Main commit `cac08ff` (pull requests #79, #80 and #81: Log currency control and conversion, History scope-row filters and no capture card, header-line explainers, Today hero, category tints, Assets by currency, saved-amount banner, Insights privacy collapse, illustrations, onboarding copy, recovery notes, vendored Apple skills, release tooling).

- Run 62 (`f26cc9f`) failed its StoreKit gate on the timing flake and did not upload; no 1062.x build exists in App Store Connect.
- Signed build **0.7.2 (1063.1)**, IPA SHA-256 `d57e53bce033a845c92d372f83a02af15e2fefb648231202a1c74bddabad2bba`, uploaded by [TestFlight run 35750198040](https://github.com/LaiWenKang/MoneyUp/actions/runs/35750198040); the deadline-based StoreKit gate passed first time.
- Export compliance inherited from 1061.1 ([run 35755210095](https://github.com/LaiWenKang/MoneyUp/actions/runs/35755210095)); the tester workflow's new processing wait meant no retry was needed. Receipt: `apple-compliance-1063.1.json`.
- Distributed to the internal group with the bilingual notes ([run 35755510612](https://github.com/LaiWenKang/MoneyUp/actions/runs/35755510612)). Receipt: `apple-internal-1063.1.json`.
- Readback ([run 35755605043](https://github.com/LaiWenKang/MoneyUp/actions/runs/35755605043)): processing `VALID`, internal `IN_BETA_TESTING` (3 covered), external `READY_FOR_BETA_SUBMISSION`. Receipt: `apple-inspect-1063.1.json`.
- Public 0.7.2 remains `WAITING_FOR_REVIEW` on 1059.1 ([inspection 35745225764](https://github.com/LaiWenKang/MoneyUp/actions/runs/35745225764)). The owner reports the Paid Apps Agreement accepted; the API exposes no readback for it.

## Not done, by design

Attaching 1060.1 to the public 0.7.2 version requires that version to be editable. It is in Apple's review queue, and `appstore_release.py prepare` refuses versions in `WAITING_FOR_REVIEW`. Replacing the reviewed build means cancelling the current review submission and resubmitting, which loses the queue position; that is an owner decision and was not taken here. No external TestFlight distribution, App Store metadata change, or submission was performed. Banking, tax and the Paid Apps Agreement were not inspected or modified; the 19 September receipt records the agreement as not yet accepted.
