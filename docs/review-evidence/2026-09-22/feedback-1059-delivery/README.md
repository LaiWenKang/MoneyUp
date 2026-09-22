# MoneyUp 0.7.2 (1060.1) — build 1059.1 feedback delivery

Delivered to App Store Connect on 22 September 2026 from main commit
`4cd0ad92eb4d6a762a74c782e4e5276c59f9026c` (pull request #75, squash-merged after all five CI jobs passed on the exact head).

- Signed release build **0.7.2 (1060.1)**, IPA SHA-256 `3da024690c99d698848e51078706f9e6d177670352f16c883fa6983dae345aee`, uploaded by [TestFlight run 35677332908](https://github.com/LaiWenKang/MoneyUp/actions/runs/35677332908). The run's StoreKit purchase integration gate and secretless preflight passed on the same revision. The encrypted release recovery bundle is retained as that run's artifact.
- Export compliance: the exempt answer (`uses_non_exempt_encryption: false`) was inherited from 1059.1 after confirming `Package.resolved`, `Package.swift`, the entitlements, `Info.plist` and `project.yml` are byte-identical to the 1059.1 source ([run 35680630571](https://github.com/LaiWenKang/MoneyUp/actions/runs/35680630571)). Receipt: `apple-compliance-1060.1.json`.
- App Store Connect readback ([run 35680704659](https://github.com/LaiWenKang/MoneyUp/actions/runs/35680704659)): processing `VALID`, internal TestFlight `IN_BETA_TESTING` (existing internal group of 3 testers; the external group was not assigned), external `READY_FOR_BETA_SUBMISSION`. Receipt: `apple-inspect-1060.1.json`.
- Public version state before delivery ([run 35674643217](https://github.com/LaiWenKang/MoneyUp/actions/runs/35674643217)): **0.7.2 (1059.1) is still `WAITING_FOR_REVIEW`** with all three support products; 0.7.1 (1051.1) remains `READY_FOR_DISTRIBUTION`. Receipt: `apple-inspect-public-0.7.2.json`.

## Not done, by design

Attaching 1060.1 to the public 0.7.2 version requires that version to be editable. It is in Apple's review queue, and `appstore_release.py prepare` refuses versions in `WAITING_FOR_REVIEW`. Replacing the reviewed build means cancelling the current review submission and resubmitting, which loses the queue position; that is an owner decision and was not taken here. No external TestFlight distribution, App Store metadata change, or submission was performed. Banking, tax and the Paid Apps Agreement were not inspected or modified; the 19 September receipt records the agreement as not yet accepted.
