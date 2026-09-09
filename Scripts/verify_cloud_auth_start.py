#!/usr/bin/env python3
"""Check configured CloudKit authentication without signing in or exposing tokens."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from validate_cloud_release import cloud_release_errors


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_auth_start(status: int, payload: dict) -> bool:
    if status != 421 or not isinstance(payload, dict) or payload.get("serverErrorCode") != "AUTHENTICATION_REQUIRED":
        return False
    try:
        raw_url = payload.get("redirectURL")
        if not isinstance(raw_url, str):
            return False
        url = urlsplit(raw_url)
        host = (url.hostname or "").lower()
        return (url.scheme == "https" and not url.username and not url.password
                and url.port in {None, 443}
                and any(host == domain or host.endswith("." + domain)
                        for domain in ("apple.com", "icloud.com", "apple-cloudkit.com")))
    except ValueError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--deployed-schema-sha256", required=True,
                        help="Reviewed schema digest recorded after production deployment")
    args = parser.parse_args()
    try:
        spec = json.loads(args.configuration.read_text())
        info = spec["targets"]["MoneyUp"]["info"]["properties"]
        schema = Path(__file__).resolve().parents[1] / "CloudKit/schema.ckdb"
        if hashlib.sha256(schema.read_bytes()).hexdigest() != args.deployed_schema_sha256:
            raise ValueError("Production schema has not been recorded for this source")
        if not isinstance(info, dict) or cloud_release_errors(info, "internal-beta"):
            raise ValueError("Invalid configuration")
        container = info["MoneyUpCloudContainer"]
        url = "https://api.apple-cloudkit.com/database/1/" + container + "/production/private/users/current?" + urlencode(
            {"ckAPIToken": info["MoneyUpCloudAPIToken"]})
        origin = "https://" + urlsplit(info["MoneyUpCloudCallbackURL"]).hostname
        request = Request(url, headers={"Origin": origin, "Accept": "application/json"})
        try:
            response = build_opener(NoRedirect()).open(request, timeout=20)
        except HTTPError as response_error:
            response = response_error
        with response:
            status = response.code
            data = response.read(2_097_153)
        if len(data) > 2_097_152 or not validate_auth_start(status, json.loads(data)):
            raise ValueError("Authentication start was not verified")
    except (OSError, URLError, ValueError, KeyError, TypeError):
        print("error: Production CloudKit preflight failed. Check the deployed schema digest, token, and allowed origin; no credentials were printed.")
        return 1
    print("Production CloudKit authentication start verified. Native sign-in and device recovery remain pending.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
