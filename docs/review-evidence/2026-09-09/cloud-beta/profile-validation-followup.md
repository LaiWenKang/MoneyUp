# Provisioning-profile validation follow-up

The first combined upload attempt, run `34296405200`, passed release preflight,
created the 0.7.1 (1047.1) archive, and exported a signed IPA. Its final cloud
check accepted the app's exact signed callback domain but rejected the
provisioning-profile authorization. The upload step did not run.

The checker incorrectly required the profile grant to be an array. A profile
is an authorization allowlist, distinct from the app's claimed entitlements;
Apple profiles can represent the associated-domains grant as the scalar `*`.
The app must still claim only `webcredentials:moneyup-signin.pages.dev`.

The correction accepts the scalar wildcard and existing valid array forms only
in the profile. Missing, malformed, or unrelated grants still fail. A wildcard,
unrelated domain, or extra domain in the app signature still fails. CLI success
output now reports the profile representation without exposing credentials.
The next signed validation must confirm the actual profile representation.

Validation: all 21 Python cloud/release tests passed. Application source,
encryption, signed-domain configuration, and internal-only export requirements
are unchanged.

References: [Apple TN3125: profile allowlists versus app entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles),
[Fastlane's profile/app entitlement handling](https://github.com/fastlane/fastlane/blob/master/sigh/lib/assets/resign.sh).
