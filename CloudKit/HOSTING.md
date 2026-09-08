# Free callback hosting

Use **Cloudflare Pages static hosting** and its included `pages.dev` address.
There are no Functions, Workers scripts, databases, paid bindings, or purchased
domains in this deployment. Backups go directly from MoneyUp to Apple; only
five public support files are deployed here.

## Prepared bundle

```sh
python3 Scripts/build_cloud_callback_site.py --team-id 3ZPDTY7ZRS
```

The output is `CloudKit/CallbackSite`. A new zip for Cloudflare Dashboard direct
upload can be created with `--zip /path/to/new-archive.zip`. The archive contains
only the generated site assets, never the repository, app configuration, keys,
or financial records.

The deployed project is `moneyup-signin`, with the stable origin
`https://moneyup-signin.pages.dev` and callback
`https://moneyup-signin.pages.dev/auth/icloud/callback`.

The extensionless callback is backed by `auth/icloud/callback.html` so Pages
serves the exact path without redirecting to a trailing slash. The root 404
file prevents SPA fallback from silently treating an incorrect callback as
valid. The Apple association file has an explicit JSON content type. Global
headers disable response caching, referrers, framing, forms, and scripts.

## Phone-compatible authorization

When using Codex Remote from a phone, authorize the Mac with a short-lived
Cloudflare device code rather than trying to sign into the Mac browser:

```sh
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.129.1 login --device --browser=false --use-keyring --scopes account:read user:read pages:write
```

Open the exact verification URL printed by Wrangler on the phone, enter its
current code, and approve Wrangler. Keep the request running until it reports
success, then verify with `wrangler whoami`. Expired codes must be regenerated;
ordinary phone-browser sign-in alone does not authorize the Mac CLI. Never
send passwords or access tokens through chat. Do not expand to unrelated
Workers, database, or account-administration scopes merely to silence
Wrangler's generic missing-scope warning.

## Deploy after signing in

Use **Workers & Pages → Pages → Direct Upload** in the Cloudflare Dashboard.
Upload the generated zip or folder. Stay on static/free hosting and leave Web
Analytics and any script injection disabled.

Alternatively, use the pinned CLI after a reviewed CLI authorization:

```sh
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.129.1 pages project create moneyup-signin --production-branch main
WRANGLER_SEND_METRICS=false npx --yes wrangler@4.129.1 pages deploy CloudKit/CallbackSite --project-name moneyup-signin --branch main
```

Do not use a temporary preview account for this sign-in domain. The domain and
Apple association must remain under the owner's control.

## Verify before configuring Apple

```sh
python3 Scripts/verify_cloud_callback_host.py \
  --base-url https://moneyup-signin.pages.dev \
  --team-id 3ZPDTY7ZRS
```

This verifies HTTPS, a direct 200 response, exact app association, privacy
headers, no query reflection, and a 404 for invalid routes. It sends only a
fixed synthetic marker. It does not authenticate an Apple Account or prove the
native return flow.

Keep the callback page free of analytics, third-party assets, and query-string
logging. Native acceptance must prove that the associated HTTPS callback is
intercepted by MoneyUp before a real authorization token reaches the host.
Provider-side operational/security logging must not be represented as absent
merely because this static site contains no logging code.

## Verification recorded on 8 September 2026

- Wrangler 4.129.1 local Pages runtime reported **No Functions** and parsed both
  header rules.
- Local routing, JSON association, security headers, query non-reflection, and
  404 checks passed. This local HTTP check does not establish deployed HTTPS.
- Ten cloud configuration/site/accessibility Python tests passed.
- The owner approved Wrangler through the phone-compatible device authorization
  flow. The Mac now has account-read and Pages-write access; credentials are
  encrypted with their encryption key in macOS Keychain. The Mac browser
  session is separate and is not required for CLI deployment.
- Deployed the five-file static bundle from `786fb8a` to the production Pages
  project. Deployment: `633c0e3c-4494-47f6-ab43-2c9600ab9d89`.
- Live HTTPS, direct callback response, exact Apple app association, privacy
  headers, query non-reflection, and unknown-route 404 checks all passed.
- [Live verification evidence](../docs/review-evidence/2026-09-08/cloud-backup/hosting-live-verification.json).
  This proves the hosting surface, not native Apple account sign-in or backup.

References: [Pages pricing](https://developers.cloudflare.com/pages/functions/pricing/),
[Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/),
[route matching](https://developers.cloudflare.com/pages/configuration/serving-pages/),
[response headers](https://developers.cloudflare.com/pages/configuration/headers/).

## Apple setup preflight after deployment

The Apple Developer portal reauthenticated successfully. MoneyUp's registered
App ID prefix is `3ZPDTY7ZRS`, matching the hosted association file. Its existing
App Groups capability is enabled; Associated Domains and iCloud are off.
Enabling the two new capabilities, provisioning the MoneyUp CloudKit container,
and creating its development web API token are awaiting explicit approval for
those Apple-side security permissions. No Apple capability changes have been
saved and no private book has been uploaded.
