import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_cloud_callback_site import site_files


class CloudCallbackSiteTests(unittest.TestCase):
    def test_bundle_is_static_and_contains_only_the_app_association(self):
        files = site_files("3ZPDTY7ZRS")
        self.assertEqual(set(files), {"index.html", "404.html", "auth/icloud/callback.html",
            ".well-known/apple-app-site-association", "_headers"})
        association = json.loads(files[".well-known/apple-app-site-association"])
        self.assertEqual(association, {"webcredentials": {"apps": ["3ZPDTY7ZRS.com.laiwenkang.MoneyUp"]}})
        for name, content in files.items():
            for marker in (b"<script", b"<form", b"<iframe", b"ckWebAuthToken", b"ckAPIToken"):
                self.assertNotIn(marker, content, name)

    def test_callback_route_uses_pages_extensionless_matching(self):
        self.assertIn("auth/icloud/callback.html", site_files("3ZPDTY7ZRS"))
        self.assertNotIn("auth/icloud/callback/index.html", site_files("3ZPDTY7ZRS"))
        self.assertIn("signin/return/index.html", site_files("3ZPDTY7ZRS", "/signin/return/"))

    def test_headers_disable_caching_referrers_and_active_content(self):
        headers = site_files("3ZPDTY7ZRS")["_headers"].decode()
        for value in ("Cache-Control: no-store", "Referrer-Policy: no-referrer",
                      "Content-Type: application/json", "form-action 'none'", "frame-ancestors 'none'"):
            self.assertIn(value, headers)

    def test_rejects_traversal_and_reserved_deployment_paths(self):
        for path in ("/../private", "/auth/%2e%2e/private", "/auth/%00/private", "//other/host",
                     "/functions/handler", "/_worker.js", "/.well-known/replace", "/auth?token=secret"):
            with self.assertRaises(ValueError):
                site_files("3ZPDTY7ZRS", path)


if __name__ == "__main__":
    unittest.main()
