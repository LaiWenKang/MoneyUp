import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from appstore_release import prepare, validate_config, resource, ReleaseClient
from appstore_screenshots import screenshot_manifest, upload_parts, sync_screenshots
from appstore_support import prepare_support
from appstore_previews import movie

ROOT = Path(__file__).resolve().parents[2] / "docs/app-store/0.7.2"


class AppStoreReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / "release.json").read_text())

    def test_transient_reads_retry_but_uncertain_writes_do_not(self):
        client = ReleaseClient(Path("unused-test-key"), "test-key", "test-issuer", True)
        for method, expected_calls in [("GET", 2), ("POST", 1)]:
            error = HTTPError("https://api.appstoreconnect.apple.com/v1/apps", 500, "failure", {},
                              io.BytesIO(b'{"errors":[{"code":"UNEXPECTED_ERROR","detail":"private detail"}]}'))
            response = Mock()
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            response.read.return_value = b'{"data":[]}'
            with patch("appstore_release.token", return_value="test-token"), \
                 patch("appstore_release.time.sleep"), patch("appstore_release.build_opener") as opener:
                opener.return_value.open.side_effect = [error, response]
                if method == "GET":
                    self.assertEqual(client.request(method, "/v1/apps"), {"data": []})
                else:
                    with self.assertRaisesRegex(RuntimeError, "HTTP 500 during POST /v1/apps") as caught:
                        client.request(method, "/v1/apps", {"data": {}})
                    self.assertNotIn("private detail", str(caught.exception))
                self.assertEqual(opener.return_value.open.call_count, expected_calls)

    def test_reviewed_bilingual_manifest_matches_real_pngs(self):
        manifest = validate_config(self.config, ROOT)
        self.assertEqual(set(manifest), {"en-US", "zh-Hans"})
        self.assertEqual(len(manifest["en-US"]), 8)

    def test_rejects_unreviewed_images_and_path_escape(self):
        for field, value in [("sha256", "0" * 64), ("file", "../private.png")]:
            config = copy.deepcopy(self.config)
            config["screenshots"]["en-US"][0][field] = value
            with self.assertRaises(ValueError):
                screenshot_manifest(config, ROOT)

    def test_preview_movies_match_reviewed_digests_and_reject_escape(self):
        for locale in ["en-US", "zh-Hans"]:
            self.assertIsNotNone(movie(self.config, ROOT, locale))
        for key, value in [("sha256", "0" * 64), ("file", "../private.mp4")]:
            config = copy.deepcopy(self.config)
            config["previews"]["en-US"][key] = value
            with self.assertRaises(ValueError):
                movie(config, ROOT, "en-US")
        config = copy.deepcopy(self.config)
        del config["previews"]["en-US"]["audio"]
        with self.assertRaises(ValueError):
            movie(config, ROOT, "en-US")

    def test_rejects_missing_locale_and_overlong_store_copy(self):
        config = copy.deepcopy(self.config)
        del config["localizations"]["zh-Hans"]
        with self.assertRaises(ValueError):
            validate_config(config, ROOT)
        self.config["localizations"]["en-US"]["keywords"] = "x" * 101
        with self.assertRaises(ValueError):
            validate_config(self.config, ROOT)

    def test_upload_rejects_non_apple_origin_and_incomplete_ranges_before_network(self):
        for operations in [
            [{"url": "https://apple.com.attacker.test/upload", "method": "PUT", "offset": 0, "length": 3}],
            [{"url": "https://upload.apple.com/a", "method": "PUT", "offset": 1, "length": 2}],
            [{"url": "https://upload.apple.com/a", "method": "POST", "offset": 0, "length": 3}],
            [{"url": "https://upload.apple.com/a", "method": "PUT", "offset": 0, "length": 3,
              "requestHeaders": [{"name": "Authorization", "value": "secret"}]}]
        ]:
            with self.assertRaises(ValueError):
                upload_parts(operations, b"abc")

    def test_public_preparation_rejects_internal_only_and_unprocessed_builds(self):
        client = Mock()
        for attrs in [{"processingState": "PROCESSING"},
                      {"processingState": "VALID", "buildAudienceType": "INTERNAL_ONLY"}]:
            with self.assertRaises(ValueError):
                prepare(client, {"id": "app"}, {"id": "build", "attributes": attrs}, self.config, ROOT)
        client.request.assert_not_called()

    def test_support_product_validation_precedes_external_writes(self):
        for price in ["0", "-1", "NaN", "0.999"]:
            config = copy.deepcopy(self.config)
            config["supportProducts"][0]["basePrice"] = price
            client = Mock()
            with self.assertRaises(ValueError):
                prepare_support(client, {"id": "app"}, config, ROOT)
            client.request.assert_not_called()

    def test_verify_only_never_replaces_or_uploads_screenshots(self):
        client = Mock()
        client.all.side_effect = [[{"id": "set", "attributes": {"screenshotDisplayType": "APP_IPHONE_65"}}],
                                  [{"id": "asset", "attributes": {"fileName": "a.png", "assetDeliveryState": {"state": "UPLOADED"}}}]]
        with self.assertRaises(ValueError):
            sync_screenshots(client, "locale", [(Path("a.png"), b"abc")], verify_only=True)
        client.request.assert_not_called()
        client.delete_screenshot.assert_not_called()

    def test_verified_asset_must_match_both_bytes_and_order(self):
        client = Mock()
        client.all.side_effect = [[{"id": "set", "attributes": {"screenshotDisplayType": "APP_IPHONE_65"}}],
            [{"id": "asset", "attributes": {"fileName": "a.png", "assetDeliveryState": {"state": "COMPLETE"},
                                            "sourceFileChecksum": hashlib.md5(b"abc", usedforsecurity=False).hexdigest()}}]]
        self.assertTrue(sync_screenshots(client, "locale", [(Path("a.png"), b"abc")], verify_only=True)["processed"])
        client.request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
