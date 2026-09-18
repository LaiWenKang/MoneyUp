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
- Seven bilingual store compositions, each using an unaltered native app capture
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
- Baseline script suite: 109 tests passed. New public-release boundary tests: 7 passed.
- Current structure, architecture and release-assets validators pass.
- Native screenshot rendering passed, with further layout review/re-capture in progress.
- Support state tests passed locally. Xcode 27 local StoreKit testing showed product
  setup/transaction-finish inconsistencies; the real StoreKit integration assertion
  is retained and must pass the pinned CI environment before merge.
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
