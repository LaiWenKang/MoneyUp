# MoneyUp 0.7.2 public update

Owner requested source/build review, merge after successful checks, improved App
Store screenshots, public availability including Malaysia, and optional developer
support on 18 September 2026. Existing France exclusion remains in place.

## Baseline and storefront evidence

- Reviewed baseline main: f6f0f923a7fee14f4bb2c66b5321be77dea946c5 (PR #67).
- Current uploaded baseline: 0.7.1 (1055.1), processing VALID, internal testing
  available, external READY_FOR_BETA_SUBMISSION; refreshed inspect run 35347258440.
- Public 0.7.1 appeared on 18 September at 12:37:22 UTC. Apple lookup and exact-name
  search both returned app 6804665286 in all 15 checked storefronts. See the JSON
  receipt. This is not a claim about every country's search ranking.
- Remote Claude UI branch 883b519 is dated 4 September. No 18 September Claude
  source push was found. Open PRs #29 (old execution prompt) and #7 (browser PWA)
  are not new iOS changes and are not included indiscriminately.

## Changes

- Marketing version 0.7.2; production ledger, migration and encryption behavior
  remain the reviewed main implementation.
- Eight bilingual store compositions, each using an unaltered native app capture
  with a fictional three-month ledger, six budgets, three goals and three accounts.
  The sample never reads installed user records. Capture code is test-target only.
- Optional repeatable StoreKit consumable tips in Settings. Core features remain
  free. Apple supplies local prices. Cancellation/pending/unverified results do
  not claim success; concurrent taps are serialized; transactions are verified
  and finished. No purchase becomes a ledger entry or MoneyUp server request.
- Protected main-only API tooling separates inspection, metadata preparation,
  support-product configuration, and public submission. Exact SHA, reviewed image
  digests, processed build, metadata readback and asset-processing checks gate
  submission. It does not sign agreements or change banking/tax/territory policy.

## Validation and outstanding gates

- Baseline local core suite: 410 XCTest + 53 Swift Testing passed. Other native
  targets are covered separately; this number is not the full repository count.
- Baseline script suite: 109 tests passed. New public-release boundary tests: 8 passed.
- Current structure, architecture and release-assets validators pass.
- Native screenshot rendering passed; final 16 bilingual compositions were re-captured and visually reviewed with richer Today history and intact navigation.
- Support state tests passed locally. Xcode 27 local StoreKit testing showed product
  setup/transaction-finish inconsistencies. The complete app-model test step passed
  in pinned Xcode 16.4 CI run 35350179182, including the retained real StoreKit
  integration assertion. iOS 26 interaction run 35350179229 passed. Final-head CI
  is still required after the screenshot and workflow refinements.
- Local full regression recorded 746 passes and one SIGTERM while an older test
  harness using the same simulator was being stopped; that exact restore test
  passed an isolated rerun alongside screenshot capture. It was not changed.
- Platform ingress gate: retain adjacent durable-ingress reload and acknowledgement
  at startup, then attach the payment listener. All 60 platform-validator tests
  passed after this ordering correction.
- Account Holder must have an active Paid Apps Agreement and completed banking/tax
  details. Existing private review contact is kept inside Apple's service.
- CI, signed upload, Apple processing, product approval, public review and physical
  iPhone acceptance are separate evidence. No public update is represented as
  submitted or approved by this source note.

## Official API references

- https://developer.apple.com/documentation/appstoreconnectapi
- https://developer.apple.com/documentation/appstoreconnectapi/uploading-assets-to-app-store-connect
- https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase
- https://developer.apple.com/app-store/review/guidelines/

## Import and media follow-up

- Owner requested CSV, XLSX and JSON support after observing greyed-out Files picker items. The picker now accepts provider items, rejects directories, coordinates read-only access, and validates bounded contents. Parsing occurs off the UI actor.
- XLSX supports stored/deflated ZIP, shared and inline strings, worksheet choice, date styles and 1900/1904 dates, sparse columns, CRC checks and bounded expansion. It never executes formulas or external XML entities. JSON preserves decimal precision and provides explicit table/column/type/date review. Nonzero fee/coupon columns are review-only; ambiguous reimbursement originals no longer become incoming refunds automatically.
- Eleven targeted import tests passed; two additional Core cases cover reimbursement direction and fees/coupons. The entire expanded Core suite passed locally.
- Sixteen English/Chinese posters now mix light and dark screens and lead with the existing 3D Money World artwork. Two 18-second 886x1920 H.264/30fps native-view previews and two 6-second brand clips are included.
- A simulator recording run (PID 26404, 23:16, 0.7.2 source build 11) hit a Swift Charts assertion while an opaque brand animation unnecessarily mounted and invalidated the app chart tree. The recorder now isolates the animated layer and does not mount app charts for brand-only clips. The failing Chinese brand path passed at 23:31 after that change; this is recorder-path evidence, not an assertion of physical-device perfection.
- Actual owner-file import and physical-device payment acceptance remain separate from fixture and simulator results.

- Owner chose SGD as the base currency and S$1 / S$5 / S$10 support levels. Coffee / Dinner / Boost copy keeps the default audience broad; banking and paid-contract setup still require Account Holder action. The revised local StoreKit purchase/finish test passed on 19 September at 00:02, and its SGD review screenshot replaced the earlier USD fixture.
- Structured numeric cells retain their type and are localized only at the existing CSV-parser boundary, preventing a decimal like 1.234 from becoming a grouping-based 1234 under a German locale. Targeted JSON and XLSX regressions cover this.

- Owner revised support prices to SGD 1 / 5 / 10 and requested natural rhyming store copy on 19 September. Screenshots, movie branding and the StoreKit review capture are regenerated for these final choices.

- Regenerated all 16 posters and four movies with rhyming copy; native capture passed at 00:34 on 19 September. The Xcode 27 / iOS 26.5 StoreKit test service returned SKInternalErrorDomain 3 and no products; the matched Xcode 27 / iOS 27 run passed repeated consumable purchases and finishing at 00:36 with the SGD 1 / 5 / 10 screenshot. Final CI still independently verifies its pinned Xcode 16.4 runtime.
- Older SDK overlays rejected the video recorder async finishWriting call under strict concurrency. The test-only recorder now bridges Apple’s completion-handler API while retaining writer access on MainActor; no production ledger or payment behavior changed.

- Initial calendar selection now uses the same reporting snapshot as the rest of MainTabView, eliminating host-clock drift in fixed-date fixtures. Calendar screenshots passed with September 18 sample cash flow after midnight. Completion-handler video recording and the centered two-line English opening passed native capture at 00:50 on 19 September.

- Final pinned-Xcode CI executed 759 app tests: the StoreKit SGD purchase test passed, but one CSV encoding test exposed older Foundation classifying a leading BOM as a control character. Decode now removes a leading BOM first and shares explicit C0/C1 validation across text and structured imports, preserving legitimate Unicode format characters. UTF-8, UTF-8 BOM, UTF-16 LE/BE BOM, GB18030 and joined-emoji notes are covered. All 11 targeted import tests passed locally at 01:24; the final commit requires a fresh complete CI pass.

- Movie finalization adds a silent two-channel AAC track at 48 kHz / 256 kbps CBR using Apple afconvert, then passes through the original video with AVFoundation. All four finalized movies decoded completely (540 / 540 / 180 / 180 video frames). The finalizer refuses existing audio and existing output files. Preview manifests bind both the reviewed audio metadata and final-byte SHA-256. This packaging step changes no iOS app, test or project source.

- Full native/core/assets/performance CI passed for application source `fe0e053dd69609887215c2676fea696929e14841` (run 35374309825); both iOS 26 interaction runs passed. The following media-only finalization changes no App, Sources, Tests, project.yml, package or workflow files. Its nine release-boundary tests and release-asset validation passed locally, and both 18-second finalized movies played to completion in the preview browser. Signed-upload preflight revalidates the final merged revision.

- Release preflight on Xcode 26.6 / iOS 26.5 passed the import encoding cases, then its StoreKit Test service failed to save configuration (SKInternalErrorDomain 3) and waited indefinitely. This matches Apple forum thread 826971 / FB22237318. Payment integration now runs as a required same-revision Xcode 16.4 / iOS 18.5 job, while the release-toolchain job retains all other native tests and release compilation. Signing depends on both successful jobs. Validator mutation tests reject removal, ignored payment failures, runtime drift, and additional skipped native tests. No production application code changed for this infrastructure fix.
