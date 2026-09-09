# Fix the first iCloud backup record save in 1048.1

Build 1048.1 sends the CloudKit schema type `ASSET` as a web-service field
discriminator when saving an uploaded chunk. Apple rejects that wire value.
The client then maps `BAD_REQUEST` to `invalidResponse`, which incorrectly
instructs the owner to reconnect an already verified account.

The fix passes the complete upload receipt as the field's value without an
explicit type, matching Apple's documented upload workflow and CloudKit JS.
Timestamp fields retain their explicit `TIMESTAMP` type. Encryption, account
identity, record names, schema, and saved recovery credentials are unchanged.

## Evidence and diagnostic limits

The owner confirmed 1048.1 and a failure after connecting iCloud. The production
console showed the following private-database web requests on 9 September:

| Singapore time | Operation | Result |
| --- | --- | --- |
| 11:48:52 | UserRetrieve | SUCCESS |
| 11:48:54 | AssetUploadTokenFetch | SUCCESS |
| 11:48:57 | RecordModify | USER_ERROR / OTHER |

The console does not expose the exact rejected field or response body. The
request format defect was independently verified with a read-only development
`records/query` probe: the same asset field-value dictionary with `type: ASSET`
returns HTTP 400 `BAD_REQUEST`, reason `BadRequestException: Unexpected input`.
Changing only the type to `ASSETID`, or omitting it, passes that parsing stage;
the deliberately empty asset query then returns HTTP 500 `INTERNAL_ERROR`.
Those latter responses are not successful upload evidence. The probe reads
no private records and creates no records. Credentials and account identifiers
are excluded from this evidence.

The documented production fix is the omitted type, rather than relying on an
empty-asset query as a round-trip test. The existing native transfer test now
uses a stricter server fixture that rejects unsupported wire types. Before the
fix it fails at `CloudBackupTests.swift:107` with `invalidResponse`; after the
fix it completes upload, listing, download, and reviewed restore.

## Error and retry behavior

```text
Encrypted archive -> Apple upload receipt -> Save record -> Download and verify
                                                |
                                         Request rejected
                                                |
                                Retain archive and account setup
                                                |
                                  Update app, then manual retry
```

Known malformed-request errors have a separate bilingual message. Unexpected
service responses no longer use the sign-in callback message. Rejected or
unusable responses stop automatic retries for the current controller lifetime;
manual backup retries the same retained archive without requiring a reconnect
or a new recovery password. Reopening the screen preserves the attention state.
Temporary server errors remain retryable. Only fixed MoneyUp text reaches the
UI; raw server reasons, URLs, account IDs, and credentials remain excluded.

## Validation

- 22 distinct native tests passed across the cloud transfer, request-failure,
  and render suites. This includes account isolation, token rotation, opt-in,
  interrupted upload, quota, corruption, verified download, and reviewed restore.
- The final changed retry/status behavior and both new language screenshots
  passed a subsequent focused five-test run.
- 21 Python cloud setup/release/accessibility tests passed.
- English and Simplified Chinese rejection screens were visually inspected.
  The account remains connected, the status is actionable, and the message is
  fully visible in the alert. The screen fixtures contain synthetic data only.
- Local Xcode: 27.0 (27A5252f), iOS 27.0 Simulator. CI's pinned Xcode 16.4 / iOS
  18.5 validation and any signed release remain separate evidence.

Local native results: `/tmp/moneyup-cloud-wire-fixed.xcresult` (21 tests),
`/tmp/moneyup-cloud-wire-final.xcresult` (5 tests, four overlapping).
The regression-before log is `/tmp/moneyup-cloud-wire-red.log`.

No private book was uploaded or restored during this repair. The owner-device
acceptance remains: install the fixed internal build over 1048.1, open iCloud
backup, tap **Back up now**, and wait for the verified backup time. Confirm the
backup appears in history; downloading it must open the existing restore
preview before any replacement. Retain the current installation and book.

Screens: [English](request-rejected-en.png),
[Simplified Chinese](request-rejected-zh-Hans.png).

References: [Apple asset upload workflow](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/UploadAssets.html),
[field-value dictionary](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html),
[server error categories](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ErrorCodes.html).
