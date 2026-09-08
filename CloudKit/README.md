# MoneyUp separate-account cloud backup provisioning

The standard project remains local-only until a configured cloud build is
deliberately generated. No production configuration is checked in.

## Combined internal beta — 9 September 2026

The owner requested the backup crash fix and iCloud backup together and has no
spare test devices. The protected TestFlight workflow now accepts
`cloud_backup=internal-beta`. It generates the configured app, verifies the
production token can start Apple authentication, preserves the signed callback
domain, and sets Apple's `testFlightInternalTestingOnly` export option. These
builds cannot be used for external testing or App Store submission.

The app shows the beta status. Every new cloud backup is downloaded again and
cryptographically authenticated before the app records a successful backup.
Failed verification retains the existing outbox for retry. This does not replace
physical sign-in, account-isolation, or full application restore acceptance.

`--internal-beta` records device validation as pending in the generated bundle;
it does not mark the checks below passed. Use that configuration only through
the protected internal-only export path. Full-release production configuration
still requires all live-acceptance evidence. Production schema deployment and a
production API token are separate actions; neither follows from generating a
local configuration. See the [combined beta readiness record](../docs/INTERNAL_CLOUD_BETA_2026-09-09.md).

The owner selected free Cloudflare Pages hosting. The static deployment bundle
and verified routing are described in [HOSTING.md](HOSTING.md).

## Verified development setup — 8 September 2026

The owner approved Apple setup. Team `3ZPDTY7ZRS` now has container
`iCloud.com.laiwenkang.MoneyUp`, associated with the MoneyUp App ID.
iCloud with CloudKit support and Associated Domains are saved and enabled.
The existing App Group is retained; the widget was not changed.

Apple validated and imported `schema.ckdb` into development. Both backup record
types, their fields, and query/sort indexes were inspected in CloudKit Console.
The development web API token uses URL Redirect to
`https://moneyup-signin.pages.dev/auth/icloud/callback`, with only origin
`https://moneyup-signin.pages.dev` allowed and user discoverability off.

A live unauthenticated `users/current` check returned Apple's expected
`421 AUTHENTICATION_REQUIRED` and an `idmsa.apple.com` sign-in URL. The same
request without the allowed Origin header returned `401 AUTHENTICATION_FAILED`;
the native client now supplies the callback origin on CloudKit API requests.
This verifies the start of authentication, not a completed account connection.

Ignored, owner-readable `Local.*` configuration files are prepared. The real
development configuration generated successfully and passed 14 native simulator
tests. The ordinary generated project was then returned to its unconfigured
default. No production schema, token, app release, or private-book upload was
performed. No management token or server-to-server key was created.

Future signed builds need refreshed provisioning profiles after the capability
change. No usable signing identity was available in the Mac's default keychain
search during this check, so profile refresh and a signed iPhone build remain
pending, along with the native acceptance checks below.

[Provisioning evidence](../docs/review-evidence/2026-09-08/cloud-backup/apple-development-verification.json)

## Apple setup

1. Register `iCloud.com.laiwenkang.MoneyUp` in the existing developer team and
   associate it with MoneyUp. Do not change the widget's capabilities.
2. In CloudKit Console, create the two record types described in
   `schema.ckdb` in **development**. Validate/import the schema using `cktool`
   once management access has been explicitly authorized. Never reset a
   container as part of setup.
3. Create a web API token for this container and configure its Sign In Callback
   to the chosen app-associated HTTPS callback. Restrict Allowed Origins to the
   callback origin; native API requests must send that exact Origin. An API token is app
   configuration, not an end-user session or a server-to-server private key.
4. Host the generated `apple-app-site-association` file at the callback domain's
   `/.well-known/apple-app-site-association` with JSON content type and no
   redirects. Serve no third-party resources or analytics on the callback.
   Disable/redact query-string logging and use `Cache-Control: no-store` and
   `Referrer-Policy: no-referrer` there. Verify that the native authentication
   session intercepts the callback instead of requesting it from the website.
5. Enable the app's Associated Domains capability and refresh its development
   provisioning profile. Web Services authentication uses the selected web
   account, not the device's native CloudKit account.

## Generate a local build

Run `python3 Scripts/configure_cloud_backup.py --help` for arguments. Supply the
actual registered container, callback URL, team ID, and an API-token **file**.
The helper writes ignored, owner-readable `CloudKit/Local.*` files and never
prints the token. Generate the project with:

```sh
xcodegen generate --spec CloudKit/Local.project.yml --project-root . --project .
```

The ordinary `xcodegen generate` command regenerates the standard project with
cloud backup disabled. Never use a placeholder domain or synthetic token for
live acceptance. A full-release production override requires a reviewed
live-acceptance JSON file with the source commit and every check named in the
helper. The internal-only beta path above preserves their pending status.

## Native acceptance

Use fictional financial fixtures and two test Apple Accounts. Keep the phone
on account A; connect account B through the ephemeral Apple sign-in session.
Verify that account A is unchanged and that only B's private backup list is
accessible. Enable backup explicitly with an independent recovery password.
Verify interruption/retry, session expiry and reconnection, storage exhaustion,
account switching without copied consent, and encrypted restore on another
device. Check missing-key recovery and onboarding restore separately.

The local HTTP simulator and native model tests prove application behavior,
not Apple provisioning, live authorization, or physical-device recovery.

## Source references

- [CloudKit Web Services](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html)
- [Declarative schemas and cktool](https://developer.apple.com/videos/play/wwdc2021/10118/)
- [Associated HTTPS callback](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback/https%28host%3Apath%3A%29)
