# Apple and TestFlight Setup From an iPhone

Apple Developer Program membership was approved on 24 August 2026. MoneyUp can
therefore use Apple's TestFlight distribution, but the account and repository
must be connected once before the first upload. These steps work in Safari on
an iPhone; a personal Mac is not required.

Never paste an Apple password or the contents of an App Store Connect private
key into chat, an issue, a commit, or a workflow input.

## 1. Finish the Apple account prerequisites

1. Sign in to <https://appstoreconnect.apple.com/> and
   <https://developer.apple.com/account/> with the approved Account Holder.
   If a control is hidden on iPhone, use Safari's **aA** menu → **Request
   Desktop Website**.
2. Accept any active agreement shown in App Store Connect **Business** or on
   the developer account landing page. The Paid Apps Agreement, banking, and
   tax setup can wait while MoneyUp is a free beta with no purchases.
3. In the developer account membership details, record the 10-character Team
   ID. This becomes the GitHub environment variable `APPLE_TEAM_ID`.

Apple's agreement guidance is at
<https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements>.

## 2. Register the App Group and verify MoneyUp's two identifiers

MoneyUp 0.6.0 adds an opt-in budget-status widget. The app publishes only a
percentage and availability state to a shared container; it never publishes an
amount, payee, account name, holding, balance, transaction, or ledger
identifier. This requires one permanent App Group shared by the app and widget.

Open **Certificates, Identifiers & Profiles** → **Identifiers**, tap **+**,
choose **App Groups**, and register:

| Description | App Group identifier |
|---|---|
| MoneyUp Shared Status | `group.com.laiwenkang.MoneyUp` |

If the group already exists, verify its exact spelling and reuse it. Do not
create a second group with a similar name.

Return to **Identifiers** and open MoneyUp's two existing explicit **App IDs**
of type **App**. If either is genuinely missing on a replacement team, register
that exact ID before continuing:

| Description | Bundle ID |
|---|---|
| MoneyUp | `com.laiwenkang.MoneyUp` |
| MoneyUp Widget | `com.laiwenkang.MoneyUp.Widget` |

For each App ID, open **Edit**, enable **App Groups**, choose **Configure**,
select only `group.com.laiwenkang.MoneyUp`, continue through **Assign**, and
save. Keep iCloud, Sign in with Apple, push notifications, and every other
unused capability disabled. Both App IDs must authorize the same group before
automatic App Store provisioning can sign the 0.6.0 candidate.

This capability does not grant the widget access to the SQLCipher database or
its Keychain key. Source validation restricts both entitlement files to this
single App Group, and the signed-release workflow independently checks the app
and widget provisioning profiles and signed entitlements.

Apple's identifier instructions are at
<https://developer.apple.com/help/account/identifiers/register-an-app-id> and
<https://developer.apple.com/help/account/identifiers/register-an-app-group>.

## 3. Verify the App Store Connect app record

The App Store Connect record was created on 24 August 2026. In App Store
Connect, open **Apps** and verify these immutable release identifiers before
the first upload:

- platform: iOS;
- App Store name: `MoneyUp: CowCome`;
- installed product name: `MoneyUp` (this is intentionally shorter and is
  controlled by the binary);
- primary language: English (U.S.);
- bundle ID: `com.laiwenkang.MoneyUp`;
- SKU: `MONEYUP-IOS-001`;
- user access: Full Access while the Account Holder is the only App Store
  Connect user; otherwise choose Limited Access and include only release users.

Keep only this one app record. The embedded widget is delivered inside MoneyUp
and does not receive its own App Store Connect record. Apple's instructions
are at
<https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/>.

## 4. Request API access and create the CI key

In App Store Connect, open **Users and Access** → **Integrations** → **App
Store Connect API**.

1. If the page offers **Request Access**, submit that request. Apple reviews
   API access separately from Developer Program membership and may take more
   time to approve it.
2. Once access is available, create a **Team Key** named `MoneyUp TestFlight
   CI`. Do not create an individual key because automatic provisioning needs a
   team key.
3. Use the **Admin** role for the first cloud-signing setup. This key is broad,
   so it is protected by a manual GitHub environment and should be replaced by
   a lower-role key after a successful upload if Apple permits the same signing
   operations with that role. A team key cannot be limited to MoneyUp;
   exposure can affect every app in this App Store Connect account.
4. Download `AuthKey_<KEY_ID>.p8` to the iPhone Files app. Apple permits this
   download only once. Record the 10-character Key ID and the Issuer ID shown
   above the team-key table.

Apple documents the separate API-access request at
<https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/>.
If the key is ever exposed, revoke it immediately in App Store Connect.

## 5. Protect the values in GitHub

The account holder configured the `testflight` environment on 24 August 2026.
Use the checklist below to audit or rotate it; never copy its values into Git.
In the MoneyUp repository, open **Settings** → **Environments** →
**testflight**.

Configure the environment as follows:

- allow deployments only from the `main` branch;
- if the GitHub plan offers required reviewers, add the repository owner and
  leave self-review enabled for this founder/co-tester project;
- add environment variable `APPLE_TEAM_ID` with the 10-character Team ID;
- add environment variable `ASC_KEY_ID` with the 10-character API Key ID;
- add environment variable `ASC_ISSUER_ID` with the Issuer ID UUID;
- add environment secret `ASC_API_KEY_P8` containing the complete private-key
  text, including the `BEGIN PRIVATE KEY` and `END PRIVATE KEY` lines.
- use the iPhone Passwords app to generate and save a unique random password of
  at least 32 characters, then add it as the environment secret
  `ARCHIVE_ENCRYPTION_PASSWORD`. Do not reuse an Apple or GitHub password.

On iPhone, open the downloaded `.p8` file in Files, use the text preview to
select all and copy, then paste it directly into the GitHub secret field. Do
not replace its line breaks with the two characters `\n`. Delete any clipboard
manager copy afterward. Keep one encrypted recovery copy under the Account
Holder's control, then delete the ordinary copy from Downloads and Recently
Deleted. If the key may have been exposed, revoke it immediately, replace the
GitHub secret, and use the replacement key for the next run.

GitHub never needs an Apple password, a `.p12` certificate, a certificate
password, or manually downloaded provisioning profiles for this design.
The archive password encrypts the exact unsigned Xcode release archive and its
dSYMs before they leave the temporary runner; it never appears in the artifact
or workflow log. The signed IPA is validated separately and is not included in
this recovery artifact.

## 6. Validate, then upload

Open the repository's **Actions** tab and choose **TestFlight**.

1. Run the workflow from `main` with operation **validate**. This creates and
   verifies a cloud-signed IPA but does not upload it.
2. If validation succeeds, run it again from `main` with operation **upload**
   and type `UPLOAD` in the confirmation field. Before Apple receives the
   build, the workflow must successfully store an encrypted archive artifact.
3. A successful workflow means Apple accepted the binary transfer. Build
   processing and TestFlight availability happen afterward in App Store
   Connect.
4. Open that successful GitHub workflow run, find **Artifacts**, download the
   `MoneyUp-encrypted-xcarchive-...` artifact, and save it in a private iCloud
   Drive folder. GitHub deletes public-repository workflow artifacts after at
   most 90 days, so do this immediately. Keep its password in the Passwords
   app. The saved ciphertext is the recovery copy of the exact unsigned release
   archive and dSYMs; it does not need to be opened on the iPhone.

The workflow verifies source version 0.6.0 build 8, then creates a unique upload
build number for every attempt. It verifies Xcode 26 and the iOS 26 SDK, checks
the app and widget versions and identifiers, checks both source entitlement
files, checks privacy and bilingual resources, verifies that both distribution
profiles and both signed bundles authorize only
`group.com.laiwenkang.MoneyUp`, asks Apple to validate the IPA, uploads symbols
for crash diagnosis, and removes the temporary private key and release products
before the runner is destroyed.
Because this repository is public, treat the GitHub artifact as potentially
public ciphertext: the strong, separately stored archive password is required.

The hosted runner deliberately creates an unsigned release archive because it
has no development device or development provisioning profile. The authenticated
`exportArchive` step applies Apple Distribution signing and App Store Connect
distribution profiles to both the app and widget. Only the exported IPA is a
distribution artifact; its signatures and embedded profiles must pass every
workflow check before validation or upload. The App Group above is the one
reviewed custom capability. If MoneyUp adds any other entitlement or
capability, review this signing design before releasing it; the release
validator intentionally blocks unreviewed changes.

If an upload step loses its connection after transfer begins, check App Store
Connect **Build Uploads** before running it again. Never try to reuse an old
build number.

## 7. Make the build available to the founder and co-tester

After Apple finishes processing the upload:

1. Answer export-compliance questions in App Store Connect. MoneyUp links
   SQLCipher, which implements standard encryption outside the iOS system
   libraries, so do not guess `No` and do not add
   `ITSAppUsesNonExemptEncryption` merely to bypass the questionnaire.
2. In **Test Information**, enter the beta description from
   `APP_STORE_SUBMISSION.md`, a monitored feedback email, and the private Beta
   App Review contact name, email, and international-format phone number. The
   Account Holder enters those private values directly; they do not belong in
   Git.
3. Create a TestFlight internal group named **Founders Internal**, add the
   Account Holder, choose **Add Build**, select the build, enter the **What to
   Test** text from `APP_STORE_SUBMISSION.md`, and install it from Apple's
   TestFlight app.
4. Complete the smoke test in `FIRST_TEST.md` before inviting anyone else.
5. Create **Founders External**, add the co-tester's email, attach the tested
   build, select **Automatically notify testers**, and submit it for TestFlight
   Beta App Review. If automatic notification was not selected, use **Notify
   Testers** after Apple approves the build.

The co-tester needs an Apple Account and the TestFlight app. The invitation
email may be Gmail or any other provider. The co-tester does not need ChatGPT,
a MoneyUp account, App Store Connect access, or repository access.

Apple's current tester instructions are here:

- internal: <https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/>;
- external: <https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers>;
- beta information: <https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/>.
