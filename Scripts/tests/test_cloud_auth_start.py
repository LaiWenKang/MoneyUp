import sys
import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_cloud_auth_start import validate_auth_start
import verify_cloud_auth_start as probe


class CloudAuthenticationStartTests(unittest.TestCase):
    def run_probe(self, digest):
        info = {"MoneyUpCloudBackupEnabled": True, "MoneyUpCloudEnvironment": "production",
                "MoneyUpCloudBackupReleaseChannel": "internal-beta",
                "MoneyUpCloudBackupDeviceValidationPending": True,
                "MoneyUpCloudContainer": "iCloud.example.MoneyUp",
                "MoneyUpCloudAPIToken": "synthetic-token",
                "MoneyUpCloudCallbackURL": "https://backup.example/auth/callback"}
        response = io.BytesIO(json.dumps({"serverErrorCode": "AUTHENTICATION_REQUIRED",
                                        "redirectURL": "https://idmsa.apple.com/auth"}).encode())
        response.code = 421
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({"targets": {"MoneyUp": {"info": {"properties": info}}}}))
            output = io.StringIO()
            with patch.object(sys, "argv", ["probe", "--configuration", str(config), "--deployed-schema-sha256", digest]), \
                    patch.object(probe, "build_opener") as opener, contextlib.redirect_stdout(output):
                opener.return_value.open.return_value = response
                result = probe.main()
                calls = opener.call_count
        self.assertNotIn("synthetic-token", output.getvalue())
        return result, calls

    def test_missing_production_schema_deployment_stops_before_network(self):
        self.assertEqual(self.run_probe("0" * 64), (1, 0))

    def test_reviewed_schema_and_valid_authentication_response_pass_without_logging_token(self):
        schema = Path(__file__).resolve().parents[2] / "CloudKit/schema.ckdb"
        self.assertEqual(self.run_probe(hashlib.sha256(schema.read_bytes()).hexdigest()), (0, 1))

    def test_only_accepts_an_authenticated_service_response_with_an_apple_signin_url(self):
        response = {"serverErrorCode": "AUTHENTICATION_REQUIRED", "redirectURL": "https://idmsa.apple.com/IDMSWebAuth/auth"}
        self.assertTrue(validate_auth_start(421, response))
        for status in (200, 302, 401, 403, 500):
            self.assertFalse(validate_auth_start(status, response))
        self.assertFalse(validate_auth_start(421, response | {"serverErrorCode": "AUTHENTICATION_FAILED"}))

    def test_redirect_targets_cannot_downgrade_or_leak_credentials(self):
        for url in ("http://idmsa.apple.com/auth", "https://apple.com.evil.example/auth",
                    "https://user:secret@apple.com/auth", "https://apple.com:444/auth", "https://apple.com:bad/auth", None, 1):
            self.assertFalse(validate_auth_start(421, {"serverErrorCode": "AUTHENTICATION_REQUIRED", "redirectURL": url}))


if __name__ == "__main__":
    unittest.main()
