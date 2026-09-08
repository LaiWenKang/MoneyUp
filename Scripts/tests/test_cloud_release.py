import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_cloud_release import cloud_release_errors


class CloudReleaseTests(unittest.TestCase):
    def setUp(self):
        self.info = {"MoneyUpCloudBackupEnabled": True, "MoneyUpCloudEnvironment": "production",
                     "MoneyUpCloudBackupReleaseChannel": "internal-beta",
                     "MoneyUpCloudBackupDeviceValidationPending": True,
                     "MoneyUpCloudContainer": "iCloud.example.MoneyUp",
                     "MoneyUpCloudAPIToken": "synthetic-token",
                     "MoneyUpCloudCallbackURL": "https://backup.example/auth/callback"}
        self.key = "com.apple.developer.associated-domains"
        self.signed = {self.key: ["webcredentials:backup.example"]}
        self.profile = {"Entitlements": {self.key: ["*"]}}
        self.options = {"method": "app-store-connect", "testFlightInternalTestingOnly": True}

    def check(self, **overrides):
        arguments = dict(signed=self.signed, profile=self.profile, export_options=self.options)
        arguments.update(overrides)
        return cloud_release_errors(self.info, "internal-beta", **arguments)

    def test_requires_enabled_configuration_and_exact_signed_domain(self):
        self.assertEqual(self.check(), [])
        for key in list(self.info):
            saved = self.info.pop(key)
            self.assertTrue(self.check(), key)
            self.info[key] = saved
        self.assertTrue(self.check(signed={}))
        self.assertTrue(self.check(profile={"Entitlements": {}}))
        self.assertTrue(self.check(signed={self.key: ["webcredentials:other.example"]}))

    def test_pending_device_checks_cannot_be_used_for_external_or_public_export(self):
        for options in ({}, {"method": "app-store-connect"},
                        {"method": "app-store-connect", "testFlightInternalTestingOnly": False}):
            self.assertTrue(self.check(export_options=options))
        self.assertTrue(cloud_release_errors(self.info, "off"))
        self.assertEqual(cloud_release_errors({}, "off"), [])

    def test_invalid_metadata_errors_never_echo_credentials(self):
        for callback in ("http://backup.example/callback", "https://user:secret@backup.example/callback",
                         "https://backup.example/callback?secret=x", "https://backup.example:bad/callback"):
            self.info["MoneyUpCloudCallbackURL"] = callback
            errors = self.check()
            self.assertTrue(errors)
            self.assertNotIn("secret", " ".join(errors))
        self.info["MoneyUpCloudAPIToken"] = "sensitive-token\n"
        self.assertNotIn("sensitive-token", " ".join(self.check()))


if __name__ == "__main__":
    unittest.main()
