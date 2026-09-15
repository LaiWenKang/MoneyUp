# TestFlight tester delivery

Uploading an IPA does not verify tester access. The owner-only **TestFlight tester delivery** workflow uses the existing `testflight` environment credentials to inspect one exact MoneyUp version/build. Its default `inspect` mode makes no changes. It runs only the checked-out, explicitly supplied main SHA.

For internal access only, select `distribute-internal` and confirm `DISTRIBUTE_INTERNAL`. This operation updates reviewed test notes and assigns the existing build only to existing internal groups. It does not assign external or individual testers, submit beta review, or send an external build notification. It requires processed, unexpired, internally eligible builds and at least one existing internal tester. Its receipt reports unique internal tester coverage, group assignment, and `internal_available`; this proves configured access, not installation on a device. Repeating it skips assignments already present.

For the owner-authorized distribution operation, select `distribute` and enter `DISTRIBUTE`. The helper validates the bundle ID, iOS marketing version, build number, processing state, expiration and external-compatible audience before writing. It then updates the reviewed bilingual test notes, enables automatic notifications, adds the build to existing groups, individually assigns any existing testers not covered by those groups, and submits beta review when required. A manual available-build notification is sent only for an approved build that has not already entered testing.

No tester is created or deleted. The default inspection and distribution operations do not change public links, group memberships, credentials, export-compliance declarations, pricing, territory availability, or public App Store release state. Existing France exclusion and future-country settings are outside this helper's write scope.

The receipt contains aggregate tester counts, group access flags and Apple build states. It excludes tester names, emails, IDs, credentials, JWTs and raw API error responses. `all_assigned` means all configured groups and existing testers have access assigned; `all_available` additionally requires appropriate Apple testing states. Neither proves email delivery or installation. Inspect again after Apple review; rerunning distribution skips existing assignments and existing review submissions.

The helper uses Python's standard library and OpenSSL. Private keys exist only in a mode-0600 temporary file for the command's lifetime. JWTs expire after ten minutes. HTTP redirects and foreign-origin pagination are refused. Mutating calls are not retried automatically after ambiguous network failures; inspect state before retrying.

Validation:

```sh
python3 -m unittest discover -s Scripts/tests -p test_distribute_testflight.py -v
```

Official API references:

- [Beta groups](https://developer.apple.com/documentation/appstoreconnectapi/beta-groups)
- [Build access](https://developer.apple.com/documentation/appstoreconnectapi/builds)
- [Submit beta review](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betaappreviewsubmissions)
- [Build notifications](https://developer.apple.com/documentation/appstoreconnectapi/build-beta-notifications)

## Reusing a reviewed encryption declaration

`inherit-compliance` is a separate, explicitly confirmed operation. Supply a reference build of the same app, iOS platform and marketing version, confirm `INHERIT_COMPLIANCE`, and explicitly affirm that app encryption and dependencies were compared and are unchanged. The operator must compare the actual source and dependency revisions first. For 1052.1, the comparison between the 1051.1 source `8a4b3d7` and the 1052.1 source `e8929fc` contains only UI, localization, support and tests; no encryption implementation or dependency changes.

The operation requires live verification that France is unavailable and future-country inclusion is disabled. It may copy a prior explicitly recorded exempt answer, or attach the same approved non-exempt encryption declaration. It never invents an answer, creates a legal declaration, or overwrites a conflicting existing answer/document. Unknown, expired, unprocessed or unapproved references fail closed. Read-only inspection can report the target/reference compliance metadata and territory flags without making changes. This does not replace the account holder's legal assessment when encryption or distribution changes.
