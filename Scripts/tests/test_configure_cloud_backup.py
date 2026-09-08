import json
import plistlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import configure_cloud_backup as setup


class CloudBackupConfigurationTests(unittest.TestCase):
    def options(self):
        return dict(container="iCloud.com.laiwenkang.MoneyUp", environment="development",
                    api_token="synthetic-test-token", callback_url="https://moneyup.example/auth/icloud/callback",
                    team_id="3ZPDTY7ZRS", root=Path("/synthetic"))

    def test_prepares_app_only_entitlement_and_association(self):
        files = setup.configuration_files(**self.options())
        entitlement = plistlib.loads(files[Path("/synthetic/CloudKit/Local.entitlements")])
        self.assertEqual(entitlement["com.apple.developer.associated-domains"], ["webcredentials:moneyup.example"])
        association = json.loads(files[Path("/synthetic/CloudKit/Local.site/.well-known/apple-app-site-association")])
        self.assertEqual(association, {"webcredentials": {"apps": ["3ZPDTY7ZRS.com.laiwenkang.MoneyUp"]}})
        spec = json.loads(files[Path("/synthetic/CloudKit/Local.project.yml")])
        self.assertEqual(set(spec["targets"]), {"MoneyUp"})

    def test_rejects_insecure_callbacks_and_unverified_production(self):
        for url in ["http://moneyup.example/callback", "https://user@moneyup.example/callback",
                    "https://moneyup.example/callback?token=x", "https://moneyup.example/", "https://moneyup.example:444/callback"]:
            with self.assertRaises(ValueError):
                setup.configuration_files(**(self.options() | {"callback_url": url}))
        with self.assertRaises(ValueError):
            setup.configuration_files(**(self.options() | {"environment": "production"}))

    def test_callback_page_does_not_read_or_forward_credentials(self):
        files = setup.configuration_files(**self.options())
        page = next(value.decode() for path, value in files.items() if path.name == "index.html")
        for forbidden in ("<script", "location.search", "ckWebAuthToken", "fetch(", "<iframe"):
            self.assertNotIn(forbidden, page)

    def test_callback_path_cannot_escape_the_generated_site(self):
        for path in ("/../../outside", "/auth/%2e%2e/outside", "/auth/%00/callback"):
            with self.assertRaises(ValueError):
                setup.configuration_files(**(self.options() | {"callback_url": "https://moneyup.example" + path}))


if __name__ == "__main__":
    unittest.main()
