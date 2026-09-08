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

The intended project name is `moneyup-signin`. Use the actual hostname returned
by Cloudflare, since availability has not yet been established. The callback
path is `/auth/icloud/callback`.

The extensionless callback is backed by `auth/icloud/callback.html` so Pages
serves the exact path without redirecting to a trailing slash. The root 404
file prevents SPA fallback from silently treating an incorrect callback as
valid. The Apple association file has an explicit JSON content type. Global
headers disable response caching, referrers, framing, forms, and scripts.

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
  --base-url https://ACTUAL-PROJECT.pages.dev \
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
- Cloudflare Dashboard and Wrangler both report no authenticated account.
  The owner was asked to sign in or create a free account. No Pages project,
  domain, credentials, or deployment has been created in this step yet.

References: [Pages pricing](https://developers.cloudflare.com/pages/functions/pricing/),
[Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/),
[route matching](https://developers.cloudflare.com/pages/configuration/serving-pages/),
[response headers](https://developers.cloudflare.com/pages/configuration/headers/).
