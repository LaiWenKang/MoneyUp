#!/usr/bin/env python3
"""Inspect or distribute one MoneyUp build using protected App Store Connect credentials.

Only existing testers/groups are used. No public links, accounts, app availability,
export-compliance declarations, or App Store submissions are changed.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

ORIGIN = "https://api.appstoreconnect.apple.com"
BUNDLE = "com.laiwenkang.MoneyUp"
READY = {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING", "BETA_APPROVED"}


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def raw_signature(der: bytes) -> bytes:
    """Decode the short DER sequence of two positive P-256 integers for JOSE."""
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ValueError("Invalid ES256 signature sequence")
    offset, result = 2, b""
    for _ in range(2):
        if offset + 2 > len(der) or der[offset] != 2:
            raise ValueError("Invalid ES256 signature integer")
        size = der[offset + 1]
        value = der[offset + 2:offset + 2 + size]
        if not value or len(value) != size or value[0] & 0x80:
            raise ValueError("Invalid ES256 signature value")
        if len(value) > 1 and value[0] == 0 and value[1] < 0x80:
            raise ValueError("Noncanonical ES256 signature value")
        value = value.lstrip(b"\0")
        if not value or len(value) > 32:
            raise ValueError("Invalid ES256 signature width")
        result += value.rjust(32, b"\0")
        offset += size + 2
    if offset != len(der):
        raise ValueError("Trailing ES256 signature data")
    return result


def token(key: Path, key_id: str, issuer: str) -> str:
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600,
                             "aud": "appstoreconnect-v1"}).encode())
    content = f"{header}.{claims}"
    signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)],
                            input=content.encode(), capture_output=True, check=False)
    if signed.returncode:
        raise ValueError("App Store Connect signing key could not sign")
    return f"{content}.{b64(raw_signature(signed.stdout))}"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("App Store Connect redirect refused")


def safe_url(path: str) -> str:
    url = path if path.startswith("https://") else ORIGIN + path
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.netloc != urlsplit(ORIGIN).netloc or not parts.path.startswith(("/v1/", "/v2/")):
        raise ValueError("App Store Connect origin boundary")
    if parts.fragment or parts.username or parts.password:
        raise ValueError("Invalid App Store Connect URL")
    return url


class Client:
    def __init__(self, key: Path, key_id: str, issuer: str, writable: bool):
        self.key, self.key_id, self.issuer, self.writable = key, key_id, issuer, writable

    def request(self, method: str, path: str, payload=None):
        if method not in {"GET", "POST", "PATCH"} or (method != "GET" and not self.writable):
            raise ValueError("Read-only or unsupported operation")
        url = safe_url(path)
        request = Request(url, data=None if payload is None else json.dumps(payload).encode(), method=method,
                          headers={"Authorization": "Bearer " + token(self.key, self.key_id, self.issuer),
                                   "Content-Type": "application/json"})
        try:
            with build_opener(NoRedirect()).open(request, timeout=45) as response:
                raw = response.read(4_000_001)
                if len(raw) > 4_000_000:
                    raise ValueError("App Store Connect response exceeds bound")
                return json.loads(raw) if raw else {}
        except HTTPError as error:
            # Do not print Apple's response: it can contain tester contact details.
            raise RuntimeError(f"App Store Connect HTTP {error.code} during {method}") from None

    def all(self, path: str):
        result, seen = [], set()
        while path:
            url = safe_url(path)
            if url in seen or len(seen) >= 200:
                raise ValueError("Invalid or excessive pagination")
            seen.add(url)
            page = self.request("GET", url)
            if not isinstance(page.get("data"), list):
                raise ValueError("Expected a resource list")
            result.extend(page["data"])
            path = page.get("links", {}).get("next")
        return result


def query(path: str, **params) -> str:
    return path + "?" + urlencode(params)


def one(resources, description: str):
    if len(resources) != 1:
        raise ValueError(f"Expected exactly one {description}")
    return resources[0]


def locate(client, version: str, build_number: str):
    app = one(client.all(query("/v1/apps", **{"filter[bundleId]": BUNDLE, "limit": 2})), "MoneyUp app")
    if app["attributes"]["bundleId"] != BUNDLE:
        raise ValueError("App identity mismatch")
    # Apple publishes an uploaded build to the API only after processing, which
    # takes several minutes. Callers may allow a bounded wait instead of failing.
    deadline = time.monotonic() + max(0, int(os.environ.get("MONEYUP_BUILD_WAIT_SECONDS", "0")))
    while True:
        builds = client.all(query("/v1/builds", **{"filter[app]": app["id"], "filter[version]": build_number, "limit": 200}))
        matching = []
        for build in builds:
            release = client.request("GET", f'/v1/builds/{build["id"]}/preReleaseVersion')["data"]
            if release["attributes"]["version"] == version and release["attributes"]["platform"] == "IOS":
                matching.append(build)
        if matching or time.monotonic() >= deadline:
            break
        time.sleep(30)
    build = one(matching, "matching iOS build")
    if build["attributes"]["version"] != build_number:
        raise ValueError("Build identity mismatch")
    return app, build


def set_notes(client, build_id: str, notes: dict):
    existing = client.all(f"/v1/builds/{build_id}/betaBuildLocalizations?limit=200")
    by_locale = {row["attributes"]["locale"]: row for row in existing}
    for locale, text in notes.items():
        if locale in by_locale:
            row = by_locale[locale]
            if row["attributes"].get("whatsNew") != text:
                client.request("PATCH", f'/v1/betaBuildLocalizations/{row["id"]}',
                    {"data": {"type": "betaBuildLocalizations", "id": row["id"], "attributes": {"whatsNew": text}}})
        else:
            client.request("POST", "/v1/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})


def inspect(client, app_id: str, build_id: str):
    groups = client.all(f"/v1/apps/{app_id}/betaGroups?limit=200")
    testers = client.all(query("/v1/betaTesters", **{"filter[apps]": app_id, "fields[betaTesters]": "state", "limit": 200}))
    covered = {row["id"] for row in client.all(f"/v1/builds/{build_id}/relationships/individualTesters?limit=200")}
    report = []
    for group in groups:
        members = client.all(f'/v1/betaGroups/{group["id"]}/relationships/betaTesters?limit=200')
        builds = client.all(f'/v1/betaGroups/{group["id"]}/relationships/builds?limit=200')
        assigned = build_id in {row["id"] for row in builds}
        if assigned:
            covered.update(row["id"] for row in members)
        report.append({"internal": group["attributes"]["isInternalGroup"], "testers": len(members), "assigned": assigned})
    detail = client.request("GET", f"/v1/builds/{build_id}/buildBetaDetail")["data"]
    all_ids = {row["id"] for row in testers}
    states = {}
    for row in testers:
        state = row.get("attributes", {}).get("state", "UNKNOWN")
        states[state] = states.get(state, 0) + 1
    summary = {"groups": report, "testers": len(all_ids), "covered_testers": len(all_ids & covered),
               "tester_states": states, "internal_state": detail["attributes"].get("internalBuildState"),
               "external_state": detail["attributes"].get("externalBuildState"),
               "auto_notify": detail["attributes"].get("autoNotifyEnabled")}
    return groups, all_ids - covered, detail, summary


def deliver(client, app, build, notes: dict, distribute: bool):
    build_id, app_id = build["id"], app["id"]
    groups, uncovered, detail, summary = inspect(client, app_id, build_id)
    summary["processing_state"] = build["attributes"].get("processingState")
    if not distribute:
        return summary
    if build["attributes"].get("expired") or summary["processing_state"] != "VALID":
        raise ValueError("Build is expired or not processed")
    if build["attributes"].get("buildAudienceType") != "APP_STORE_ELIGIBLE":
        raise ValueError("An explicitly external-compatible build is required")
    set_notes(client, build_id, notes)
    if not detail["attributes"].get("autoNotifyEnabled"):
        client.request("PATCH", f'/v1/buildBetaDetails/{detail["id"]}',
            {"data": {"type": "buildBetaDetails", "id": detail["id"], "attributes": {"autoNotifyEnabled": True}}})
    for group, row in zip(groups, summary["groups"]):
        if not row["assigned"]:
            client.request("POST", f'/v1/betaGroups/{group["id"]}/relationships/builds',
                {"data": [{"type": "builds", "id": build_id}]})
    # Recompute after group assignment; only pre-existing ungrouped testers need individual access.
    _, uncovered, detail, _ = inspect(client, app_id, build_id)
    for offset in range(0, len(uncovered), 50):
        batch = sorted(uncovered)[offset:offset + 50]
        client.request("POST", f"/v1/builds/{build_id}/relationships/individualTesters",
            {"data": [{"type": "betaTesters", "id": tester} for tester in batch]})
    external = detail["attributes"].get("externalBuildState")
    if external == "READY_FOR_BETA_SUBMISSION":
        reviews = client.all(query("/v1/betaAppReviewSubmissions", **{"filter[build]": build_id, "limit": 200}))
        if not reviews:
            client.request("POST", "/v1/betaAppReviewSubmissions", {"data": {
                "type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    notification = "auto_notify_enabled"
    if external in {"READY_FOR_BETA_TESTING", "BETA_APPROVED"}:
        client.request("POST", "/v1/buildBetaNotifications", {"data": {
            "type": "buildBetaNotifications", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        notification = "notification_requested"
    _, uncovered, _, result = inspect(client, app_id, build_id)
    result["notification"] = notification
    result["all_assigned"] = not uncovered and all(row["assigned"] for row in result["groups"])
    internal_needed = any(row["internal"] and row["testers"] for row in result["groups"])
    result["all_available"] = (result["testers"] > 0 and result["all_assigned"]
        and (not internal_needed or result["internal_state"] in READY)
        and result["external_state"] in READY)
    return result


def internal_access(client, app_id: str, build_id: str):
    groups = client.all(f"/v1/apps/{app_id}/betaGroups?limit=200")
    internal = {group["id"]: group for group in groups
                if group.get("attributes", {}).get("isInternalGroup") is True}
    testers, covered, rows = set(), set(), []
    for group_id in sorted(internal):
        members = {row["id"] for row in client.all(
            f"/v1/betaGroups/{group_id}/relationships/betaTesters?limit=200")}
        builds = client.all(f"/v1/betaGroups/{group_id}/relationships/builds?limit=200")
        assigned = any(row["id"] == build_id for row in builds)
        testers.update(members)
        if assigned:
            covered.update(members)
        rows.append({"id": group_id, "assigned": assigned})
    detail = client.request("GET", f"/v1/builds/{build_id}/buildBetaDetail")["data"]
    state = detail["attributes"].get("internalBuildState")
    all_assigned = bool(rows) and all(row["assigned"] for row in rows)
    return rows, {"scope": "internal", "internal_groups": len(rows),
        "internal_testers": len(testers), "covered_internal_testers": len(covered),
        "internal_state": state, "all_internal_assigned": all_assigned,
        "internal_available": bool(testers) and all_assigned and state in READY}


def deliver_internal(client, app, build, notes: dict):
    """Assign only existing internal groups; never initiate external delivery."""
    if build["attributes"].get("expired") or build["attributes"].get("processingState") != "VALID":
        raise ValueError("Build is expired or not processed")
    rows, summary = internal_access(client, app["id"], build["id"])
    if not summary["internal_testers"] or summary["internal_state"] not in READY:
        raise ValueError("An eligible build and existing internal testers are required")
    set_notes(client, build["id"], notes)
    for row in rows:
        if not row["assigned"]:
            client.request("POST", f'/v1/betaGroups/{row["id"]}/relationships/builds',
                {"data": [{"type": "builds", "id": build["id"]}]})
    _, result = internal_access(client, app["id"], build["id"])
    updated = client.request("GET", f'/v1/builds/{build["id"]}')["data"]
    result["processing_state"] = updated["attributes"].get("processingState")
    result["internal_available"] = (result["internal_available"]
        and result["processing_state"] == "VALID" and not updated["attributes"].get("expired"))
    return result


def compliance(client, build):
    linkage = client.request("GET", f'/v1/builds/{build["id"]}/relationships/appEncryptionDeclaration').get("data")
    declaration = None
    if linkage:
        declaration = client.request("GET", f'/v1/appEncryptionDeclarations/{linkage["id"]}')["data"]
    attributes = declaration.get("attributes", {}) if declaration else {}
    summary = {"uses_non_exempt_encryption": build["attributes"].get("usesNonExemptEncryption"),
        "declaration": {key: attributes.get(key) for key in ["usesEncryption", "exempt",
            "containsProprietaryCryptography", "containsThirdPartyCryptography", "availableOnFrenchStore",
            "appEncryptionDeclarationState"]} if declaration else None}
    return declaration, summary


def availability(client, app_id):
    record = client.request("GET", f"/v1/apps/{app_id}/appAvailabilityV2")["data"]
    territories = client.all(f'/v2/appAvailabilities/{record["id"]}/territoryAvailabilities?include=territory&limit=200')
    france = one([row for row in territories if row.get("relationships", {}).get("territory", {}).get("data", {}).get("id") == "FRA"], "France availability")
    return {"france_available": france["attributes"].get("available"),
            "future_countries_enabled": record["attributes"].get("availableInNewTerritories")}


def inherit_compliance(client, app, build, reference, encryption_unchanged):
    if not encryption_unchanged or build["id"] == reference["id"]:
        raise ValueError("An independently reviewed unchanged-encryption reference is required")
    if build["attributes"].get("processingState") != "VALID" or build["attributes"].get("expired"):
        raise ValueError("Target build is not a valid active build")
    territory_state = availability(client, app["id"])
    if territory_state != {"france_available": False, "future_countries_enabled": False}:
        raise ValueError("France exclusion and future-country settings must be verified first")
    if reference["attributes"].get("processingState") != "VALID" or reference["attributes"].get("expired"):
        raise ValueError("Reference build is not a valid active build")
    declaration, previous = compliance(client, reference)
    prior_value = previous["uses_non_exempt_encryption"]
    target_value = build["attributes"].get("usesNonExemptEncryption")
    if target_value is not None and target_value != prior_value:
        raise ValueError("An existing compliance answer cannot be overwritten")
    if prior_value is False:
        if target_value is None:
            current_declaration, _ = compliance(client, build)
            if current_declaration:
                raise ValueError("A linked encryption declaration needs separate review")
            client.request("PATCH", f'/v1/builds/{build["id"]}', {"data": {
                "type": "builds", "id": build["id"], "attributes": {"usesNonExemptEncryption": False}}})
    elif prior_value is True and declaration and declaration["attributes"].get("appEncryptionDeclarationState") == "APPROVED":
        current = client.request("GET", f'/v1/builds/{build["id"]}/relationships/appEncryptionDeclaration').get("data")
        if current and current["id"] != declaration["id"]:
            raise ValueError("An existing encryption declaration cannot be replaced")
        if not current:
            client.request("PATCH", f'/v1/builds/{build["id"]}/relationships/appEncryptionDeclaration',
                {"data": {"type": "appEncryptionDeclarations", "id": declaration["id"]}})
    else:
        raise ValueError("Reference has no reusable completed compliance result")
    updated = client.request("GET", f'/v1/builds/{build["id"]}')["data"]
    _, result = compliance(client, updated)
    result.update(reference_build=reference["attributes"]["version"], availability=territory_state)
    if result["uses_non_exempt_encryption"] != prior_value:
        raise ValueError("Apple has not confirmed the inherited compliance result")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True)
    parser.add_argument("--version", required=True)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--distribute", action="store_true")
    operation.add_argument("--distribute-internal", action="store_true")
    operation.add_argument("--inherit-compliance", action="store_true")
    parser.add_argument("--reference-build")
    parser.add_argument("--reference-version")
    parser.add_argument("--encryption-unchanged", action="store_true")
    parser.add_argument("--notes", type=Path)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.build) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.version):
        raise ValueError("Invalid version or build number")
    if args.reference_build and not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.reference_build):
        raise ValueError("Invalid reference build")
    if args.reference_version and (not args.reference_build or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.reference_version)):
        raise ValueError("Invalid reference version")
    if args.inherit_compliance and (not args.reference_build or not args.encryption_unchanged):
        raise ValueError("Explicit reference and unchanged-encryption review required")
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id) or not re.fullmatch(r"[0-9a-fA-F-]{36}", issuer):
        raise ValueError("Invalid App Store Connect credential identifiers")
    notes = json.loads(args.notes.read_text()) if args.notes else {}
    if (args.distribute or args.distribute_internal) and (not notes or any(not isinstance(k, str) or not isinstance(v, str) or not v.strip() or len(v) > 4000 for k, v in notes.items())):
        raise ValueError("Reviewed localized test notes are required")
    secret = os.environ.pop("ASC_API_KEY_P8")
    with tempfile.TemporaryDirectory(prefix="moneyup-asc-") as directory:
        key = Path(directory) / "key.p8"
        fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(secret)
        del secret
        client = Client(key, key_id, issuer, args.distribute or args.distribute_internal or args.inherit_compliance)
        app, build = locate(client, args.version, args.build)
        if args.inherit_compliance:
            reference_app, reference = locate(client, args.reference_version or args.version, args.reference_build)
            if reference_app["id"] != app["id"]:
                raise ValueError("Reference app differs from target")
            result = inherit_compliance(client, app, build, reference, args.encryption_unchanged)
        else:
            result = (deliver_internal(client, app, build, notes) if args.distribute_internal
                      else deliver(client, app, build, notes, args.distribute))
            _, result["compliance"] = compliance(client, build)
            result["availability"] = availability(client, app["id"])
            if args.reference_build:
                reference_app, reference = locate(client, args.reference_version or args.version, args.reference_build)
                if reference_app["id"] != app["id"]:
                    raise ValueError("Reference app differs from target")
                _, result["reference_compliance"] = compliance(client, reference)
    result.update(version=args.version, build=args.build)
    args.receipt.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError) as error:
        print(str(error))
        raise SystemExit(1)
    except Exception as error:
        print(f"TestFlight operation failed: {type(error).__name__}")
        raise SystemExit(1)
