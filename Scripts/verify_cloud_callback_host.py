#!/usr/bin/env python3
"""Verify a deployed callback site without sending credentials or following redirects."""
from __future__ import annotations

import argparse
import json
from urllib.error import HTTPError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import build_opener, HTTPRedirectHandler, Request

from build_cloud_callback_site import DEFAULT_CALLBACK_PATH, site_files


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


def verify(base_url: str, team_id: str, callback_path: str = DEFAULT_CALLBACK_PATH,
           allow_local_http: bool = False) -> dict:
    # Reuse bundle validation before constructing any request.
    site_files(team_id, callback_path)
    parts = urlsplit(base_url)
    local = allow_local_http and parts.scheme == "http" and parts.hostname in {"127.0.0.1", "localhost", "::1"}
    if (not parts.hostname or parts.username or parts.password or parts.query or parts.fragment
            or parts.path not in {"", "/"} or (not local and (parts.scheme != "https" or parts.port not in {None, 443}))):
        raise ValueError("Use an HTTPS origin; HTTP is allowed only for explicit loopback testing")
    origin = urlunsplit((parts.scheme, parts.netloc, "", "", ""))
    opener = build_opener(NoRedirect())

    def fetch(path: str, expected_status: int = 200):
        request = Request(origin + path, headers={"User-Agent": "MoneyUp-Callback-Verification/1"})
        try:
            response = opener.open(request, timeout=20)
        except HTTPError as error:
            response = error
        with response:
            status = response.code
            headers = response.headers
            data = response.read(65_537)
        if status != expected_status or len(data) > 65_536 or headers.get("Location"):
            raise ValueError(f"Unexpected status, redirect, or oversized response at {path.split('?')[0]}: {status}")
        if "no-store" not in headers.get("Cache-Control", "").lower():
            raise ValueError("The callback site must disable response caching")
        if headers.get("Referrer-Policy", "").lower() != "no-referrer":
            raise ValueError("The callback site must disable referrer transmission")
        if headers.get("X-Content-Type-Options", "").lower() != "nosniff":
            raise ValueError("The callback site must disable content sniffing")
        csp = headers.get("Content-Security-Policy", "")
        for directive in ("default-src 'none'", "form-action 'none'", "frame-ancestors 'none'"):
            if directive not in csp:
                raise ValueError("The callback site is missing its content security policy")
        return headers, data

    headers, association = fetch("/.well-known/apple-app-site-association")
    if headers.get_content_type() != "application/json":
        raise ValueError("Apple's association file must be served as JSON")
    expected = {"webcredentials": {"apps": [team_id + ".com.laiwenkang.MoneyUp"]}}
    if json.loads(association) != expected:
        raise ValueError("The association file does not match MoneyUp's app identity")
    _, callback = fetch(callback_path)
    marker = "moneyup-synthetic-callback-verification"
    _, with_query = fetch(callback_path + "?ckWebAuthToken=" + marker)
    if callback != with_query or marker.encode() in with_query:
        raise ValueError("The callback must not reflect or process query information")
    for forbidden in (b"<script", b"<form", b"<iframe"):
        if forbidden in callback.lower():
            raise ValueError("The callback must remain static, without active content or login forms")
    fetch("/moneyup-route-that-does-not-exist", expected_status=404)
    return {"origin": origin, "callbackURL": origin + callback_path, "appID": team_id + ".com.laiwenkang.MoneyUp",
            "httpsVerified": not local, "association": "passed", "noRedirect": "passed",
            "privacyHeaders": "passed", "queryNotReflected": "passed", "unknownRoute404": "passed",
            "nativeAppleSignIn": "not verified by this check"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--callback-path", default=DEFAULT_CALLBACK_PATH)
    parser.add_argument("--allow-local-http", action="store_true")
    args = parser.parse_args()
    try:
        result = verify(args.base_url, args.team_id, args.callback_path, args.allow_local_http)
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
