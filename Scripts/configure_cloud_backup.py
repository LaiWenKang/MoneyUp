#!/usr/bin/env python3
"""Prepare a local CloudKit-enabled Xcode spec and associated-domain files.

Does not create credentials, deploy a website, or change Apple portal settings.
The API token is read from a file and is never printed.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import unquote, urlsplit

from build_cloud_callback_site import site_files


ROOT = Path(__file__).resolve().parents[1]
LIVE_CHECKS = (
    "different_account_on_device", "native_https_callback", "session_reconnection",
    "encrypted_upload_download_restore", "account_switch_isolation", "quota_and_interruption",
    "privacy_disclosures_reviewed",
)


def configuration_files(*, container: str, environment: str, api_token: str,
                        callback_url: str, team_id: str, root: Path = ROOT,
                        live_evidence: dict | None = None,
                        internal_beta: bool = False,
                        output_prefix: str = "Local") -> dict[Path, bytes]:
    parts = urlsplit(callback_url)
    if not re.fullmatch(r"iCloud\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", container):
        raise ValueError("Use the exact registered iCloud container identifier")
    if environment not in {"development", "production"}:
        raise ValueError("Choose development or production")
    if not re.fullmatch(r"Local(?:\.[a-z0-9-]+)?", output_prefix):
        raise ValueError("Use an ignored Local configuration prefix")
    if internal_beta and environment != "production":
        raise ValueError("An internal TestFlight beta must use the production CloudKit environment")
    if (parts.scheme != "https" or not parts.hostname or parts.username or parts.password
            or parts.port not in {None, 443} or not parts.path or parts.path == "/"
            or parts.query or parts.fragment):
        raise ValueError("Use an HTTPS callback with a path, no credentials, query, or fragment")
    decoded_path = unquote(parts.path)
    if (any(segment in {".", ".."} for segment in decoded_path.split("/"))
            or "\\" in decoded_path or any(ord(c) < 32 for c in decoded_path)):
        raise ValueError("Use a canonical callback path without traversal or control characters")
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("Use the ten-character Apple Developer team ID")
    if not api_token or len(api_token.encode()) > 4096 or any(ord(c) < 32 for c in api_token):
        raise ValueError("The CloudKit web API token is missing or malformed")
    if environment == "production" and not internal_beta and not (
        live_evidence and all(live_evidence.get(check) is True for check in LIVE_CHECKS)
        and re.fullmatch(r"[a-f0-9]{40}", live_evidence.get("source_commit", ""))
    ):
        raise ValueError("Production requires a reviewed live acceptance file for the tested source commit")
    entitlement = {
        "com.apple.security.application-groups": ["group.com.laiwenkang.MoneyUp"],
        "com.apple.developer.associated-domains": ["webcredentials:" + parts.hostname],
    }
    # Includes resolve from XcodeGen's --project-root, which must be the repo
    # root even though this local spec lives in CloudKit/. JSON is valid YAML.
    spec = {
        "include": [{"path": "project.yml", "relativePaths": True}],
        "targets": {"MoneyUp": {
            "settings": {"base": {"CODE_SIGN_ENTITLEMENTS": f"CloudKit/{output_prefix}.entitlements"}},
            "info": {"properties": {
                "MoneyUpCloudBackupEnabled": True,
                "MoneyUpCloudContainer": container,
                "MoneyUpCloudEnvironment": environment,
                "MoneyUpCloudAPIToken": api_token,
                "MoneyUpCloudCallbackURL": callback_url,
                "MoneyUpCloudBackupReleaseChannel": "internal-beta" if internal_beta else "validated",
                "MoneyUpCloudBackupDeviceValidationPending": internal_beta,
            }},
        }},
    }
    cloud = root / "CloudKit"
    files = {
        cloud / f"{output_prefix}.project.yml": (json.dumps(spec, indent=2) + "\n").encode(),
        cloud / f"{output_prefix}.entitlements": plistlib.dumps(entitlement),
    }
    files.update({cloud / f"{output_prefix}.site" / relative: content
                  for relative, content in site_files(team_id, parts.path).items()})
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--environment", choices=("development", "production"), default="development")
    parser.add_argument("--api-token-file", type=Path, required=True)
    parser.add_argument("--callback-url", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--live-acceptance-evidence", type=Path)
    parser.add_argument("--internal-beta", action="store_true",
                        help="Prepare a TestFlight-internal-only candidate with device validation explicitly pending")
    parser.add_argument("--output-prefix", default="Local")
    args = parser.parse_args()
    try:
        evidence = json.loads(args.live_acceptance_evidence.read_text()) if args.live_acceptance_evidence else None
        files = configuration_files(container=args.container, environment=args.environment,
            api_token=args.api_token_file.read_text().strip(), callback_url=args.callback_url,
            team_id=args.team_id, live_evidence=evidence, internal_beta=args.internal_beta,
            output_prefix=args.output_prefix)
        if any(path.exists() for path in files):
            raise ValueError("Local configuration already exists; review it before replacing any files")
        for path, content in files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(content)
        print("Prepared local CloudKit build configuration and callback-site files. No deployment performed.")
        return 0
    except (OSError, ValueError) as error:
        # Validation messages and local I/O failures contain no token contents.
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
