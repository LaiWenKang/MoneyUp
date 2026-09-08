# MoneyUp separate-account cloud backup provisioning

The standard project remains local-only until a configured cloud build is
deliberately generated. No production configuration is checked in.

## Apple setup

1. Register `iCloud.com.laiwenkang.MoneyUp` in the existing developer team and
   associate it with MoneyUp. Do not change the widget's capabilities.
2. In CloudKit Console, create the two record types described in
   `schema.ckdb` in **development**. Validate/import the schema using `cktool`
   once management access has been explicitly authorized. Never reset a
   container as part of setup.
3. Create a web API token for this container and configure its Sign In Callback
   to the chosen app-associated HTTPS callback. An API token is app
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
live acceptance. A production override requires a reviewed live-acceptance JSON
file with the source commit and every check named in the helper.

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
