# TestFlight tester delivery

Uploading an IPA does not verify tester access. The owner-only **TestFlight tester delivery** workflow uses the existing `testflight` environment credentials to inspect one exact MoneyUp version/build. Its default `inspect` mode makes no changes. It runs only the checked-out, explicitly supplied main SHA.

For the owner-authorized distribution operation, select `distribute` and enter `DISTRIBUTE`. The helper validates the bundle ID, iOS marketing version, build number, processing state, expiration and external-compatible audience before writing. It then updates the reviewed bilingual test notes, enables automatic notifications, adds the build to existing groups, individually assigns any existing testers not covered by those groups, and submits beta review when required. A manual available-build notification is sent only for an approved build that has not already entered testing.

No tester is created or deleted. No public link, group membership, credential, export-compliance declaration, pricing, territory availability, or public App Store release is changed. Existing France exclusion and future-country settings are outside this helper's write scope.

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
