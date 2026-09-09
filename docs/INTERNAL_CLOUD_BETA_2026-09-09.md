# Combined crash-fix and iCloud internal beta

The owner selected a combined TestFlight delivery and has no spare test devices.
The candidate includes the reproduced 1046.1 export-filename fix and the
previously unconfigured, opt-in separate-account iCloud backup feature.

## Delivery boundary

- Only `Founders Internal`; preserve current tester membership.
- Select `cloud_backup=internal-beta` in the protected TestFlight workflow.
  The upload remains pinned to the reviewed main commit and explicitly confirmed.
- Apple export uses `testFlightInternalTestingOnly=true`. The release validator
  rejects public/external export options, a disabled cloud configuration, missing
  production settings, or missing signed/profile callback-domain authorization.
- The configured bundle explicitly records device validation as pending and the
  cloud screen shows beta status. Full-release configuration retains its live
  acceptance requirement. Public 1.0 remains unsubmitted.
- No private financial records are transferred by provisioning, building, or
  tests. The user connects an Apple Account and explicitly enables backups in the
  app with a saved recovery password. The phone's system account is unchanged.

## Backup success contract

```text
Encrypted snapshot → Upload → Download → Hash check → Streamed authentication
                                                          ↓
                                              Record successful backup
```

`CloudBackupController` reuses the same token-rotating client for upload and
download. The download validates every chunk and the complete ciphertext hash.
`PortableArchive.verify` authenticates and decrypts the archive stream without
writing a database or retaining the complete decoded book. Cancellation and
verification failure leave success unset and retain the encrypted outbox for
retry with the same archive identity. This verifies the stored encrypted file;
device-specific sign-in and application-level recovery remain distinct checks.

The privacy policy explains the additional encrypted download. In-app consent
still precedes upload. The beta notice asks users to retain a separate encrypted
file until recovery has been tested.

## Apple production setup reviewed on 9 September

The CloudKit Console's production schema currently contains only the built-in
`Users` record type. The reviewed deployment diff adds:

- `MoneyUpBackup`: opaque book ID, creation timestamp, encoded manifest;
  four indexes, including record ID, book ID, and query/sort on creation time.
- `MoneyUpBackupChunk`: opaque backup ID, chunk index, encrypted asset, hash;
  two query indexes, on record ID and backup ID.
- Both types allow authenticated iCloud users to create records and only each
  record's creator to read/write. The existing `Users` type is unchanged.

Production has no API token. A read-only authentication-start request using the
existing development token returned `401 AUTHENTICATION_FAILED`, confirming it
cannot be used for this release. The unsaved production-token draft is:

| Setting | Value |
| --- | --- |
| Name | MoneyUp Internal Beta Backup |
| Container | `iCloud.com.laiwenkang.MoneyUp` |
| Environment | Production |
| Callback | `https://moneyup-signin.pages.dev/auth/icloud/callback` |
| Allowed origin | Only `https://moneyup-signin.pages.dev` |
| Discoverability | Off |
| Server-to-server key | None |

Saving the token and deploying the schema create production access and require
confirmation. The token will be stored in the protected GitHub `testflight`
environment as `CLOUDKIT_WEB_API_TOKEN`; its value must not enter source or logs.
After confirming deployment, record the reviewed `CloudKit/schema.ckdb` SHA-256
as `CLOUDKIT_SCHEMA_SHA256` in that same protected environment. A future schema
change then blocks release until its deployment is reviewed and recorded.
The workflow verifies a real `421 AUTHENTICATION_REQUIRED` response and an Apple
sign-in destination before building, so a missing or development token fails
the release instead of shipping a nonfunctional button.

## Validation evidence

- 19 Python cloud configuration, authentication-start, release-boundary,
  callback-site, and accessible-error tests passed.
- Two persistence tests passed for multi-chunk authentication, wrong passwords,
  ciphertext corruption, cancellation, and unchanged source archives.
- 24 focused native tests passed for cloud transfer and opt-in/account isolation,
  download-verification failure/retry, backup export presentation, pending
  captures, and rendered cloud screens.
- A configured simulator build uses an explicitly synthetic token only to test
  bundle generation and UI. It is not production authentication evidence and
  must never be uploaded. The real production-token probe remains required.
- The configured simulator build passed the same 24 native tests in
  `/tmp/moneyup-combined-cloud-configured.xcresult`. Bundle metadata passed the
  internal-beta validator. Both beta connection screens were visually inspected;
  the connection action is visible and the pending-validation notice is localized.
- Live callback-host verification, workflow YAML parsing, release assets, Swift
  structure, architecture, accessible errors, launch safety, platform actions,
  performance signposts, and diff-whitespace checks passed.

Screens: [English](review-evidence/2026-09-09/cloud-beta/connect-en.png),
[Simplified Chinese](review-evidence/2026-09-09/cloud-beta/connect-zh-Hans.png).
These use fictional local fixtures, not a live Apple connection.

## Remaining first-device acceptance

Install the combined internal beta over the existing app. Keep the installation
and original book. Save a local encrypted file, connect the intended backup
account, enable cloud backup, and wait for verified success. A downloaded backup
can be inspected through the existing read-only restore preview without
committing replacement of the current book. Full recovery on another device,
account switching on a physical phone, native HTTPS callback interception,
session reconnection, and real quota/interruption checks remain pending.

References: [Apple internal-only distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases),
[CloudKit schema deployment](https://developer.apple.com/documentation/CloudKit/deploying-an-icloud-container-s-schema),
[HTTPS authentication callbacks](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https(host:path:)).
