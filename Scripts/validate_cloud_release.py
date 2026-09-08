#!/usr/bin/env python3
"""Validate cloud beta configuration and signed distribution boundaries without printing tokens."""
from __future__ import annotations

import argparse
import plistlib
import re
from pathlib import Path
from urllib.parse import urlsplit


def cloud_release_errors(info: dict, mode: str, *, signed: dict | None = None,
                         profile: dict | None = None, export_options: dict | None = None) -> list[str]:
    enabled = info.get("MoneyUpCloudBackupEnabled") is True
    if mode == "off":
        return ["Cloud backup unexpectedly enabled in a local-only candidate"] if enabled else []
    if mode != "internal-beta":
        return ["Unknown cloud release mode"]
    errors = []
    if not enabled:
        errors.append("Internal cloud beta has no enabled cloud configuration")
    if (info.get("MoneyUpCloudEnvironment") != "production"
            or info.get("MoneyUpCloudBackupReleaseChannel") != "internal-beta"
            or info.get("MoneyUpCloudBackupDeviceValidationPending") is not True):
        errors.append("Internal cloud beta must name production and keep device validation pending")
    container = info.get("MoneyUpCloudContainer")
    if not isinstance(container, str) or not re.fullmatch(r"iCloud\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", container):
        errors.append("Cloud container is missing or malformed")
    token = info.get("MoneyUpCloudAPIToken")
    if (not isinstance(token, str) or not token or len(token.encode()) > 4096
            or any(ord(c) < 32 for c in token)):
        errors.append("Cloud API token is missing or malformed")
    try:
        raw_callback = info.get("MoneyUpCloudCallbackURL", "")
        if not isinstance(raw_callback, str):
            raise ValueError("Expected a callback URL")
        callback = urlsplit(raw_callback)
        valid = (callback.scheme == "https" and callback.hostname and callback.path not in {"", "/"}
                 and not callback.username and not callback.password and not callback.query
                 and not callback.fragment and callback.port in {None, 443})
    except (ValueError, TypeError):
        valid = False
    if not valid:
        errors.append("Cloud callback must use a complete associated HTTPS URL")
    elif signed is not None:
        expected = "webcredentials:" + callback.hostname
        key = "com.apple.developer.associated-domains"
        if signed.get(key) != [expected]:
            errors.append("Signed app does not carry the exact cloud callback domain")
        if profile is not None:
            entitlements = profile.get("Entitlements", {})
            permitted = entitlements.get(key, []) if isinstance(entitlements, dict) else []
            if not isinstance(permitted, list) or not any(item in permitted for item in ("*", expected)):
                errors.append("Distribution profile does not authorize the cloud callback domain")
    if export_options is not None and (
        export_options.get("method") != "app-store-connect"
        or export_options.get("testFlightInternalTestingOnly") is not True
    ):
        errors.append("Cloud beta must be exported for TestFlight Internal Only")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--info", type=Path, required=True)
    parser.add_argument("--mode", choices=("off", "internal-beta"), required=True)
    parser.add_argument("--signed-entitlements", type=Path)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--export-options", type=Path)
    args = parser.parse_args()
    try:
        def read(path):
            if path is None:
                return None
            value = plistlib.loads(path.read_bytes())
            if not isinstance(value, dict):
                raise ValueError("Expected a property-list dictionary")
            return value
        errors = cloud_release_errors(read(args.info), args.mode, signed=read(args.signed_entitlements),
                                      profile=read(args.profile), export_options=read(args.export_options))
    except (OSError, ValueError, plistlib.InvalidFileException):
        errors = ["Could not read cloud release metadata"]
    if errors:
        for error in errors:
            print("error: " + error)
        return 1
    print("Verified cloud release mode: " + args.mode)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
