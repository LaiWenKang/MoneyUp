#!/usr/bin/env python3
"""Prepare or submit an exact MoneyUp public update through Apple's API.

Credentials stay in the protected GitHub environment. Public receipts omit
review contacts, tokens, signed upload URLs, and raw Apple error responses.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, build_opener

from distribute_testflight import Client, NoRedirect, BUNDLE, availability, locate, one, query, safe_url, token
from appstore_screenshots import sync_screenshots, screenshot_manifest
from appstore_support import prepare_support, support_products
from appstore_previews import movie, sync_preview
from appstore_api_errors import AppStoreAPIError
from appstore_media_inspection import inspect_media

EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED"}
LOCALES = {"en-US", "zh-Hans"}


def optional_resource(client, path):
    """Apple returns 404 for some unconfigured to-one related resources."""
    try:
        return client.request("GET", path).get("data")
    except AppStoreAPIError as error:
        if error.status == 404:
            return None
        raise


def resource(kind, attributes=None, relationships=None, identifier=None):
    data = {"type": kind}
    if attributes is not None:
        data["attributes"] = attributes
    if relationships:
        data["relationships"] = {key: {"data": {"type": value[0], "id": value[1]}}
                                 for key, value in relationships.items()}
    if identifier:
        data["id"] = identifier
    return {"data": data}


class ReleaseClient(Client):
    def request(self, method, path, payload=None):
        if method not in {"GET", "POST", "PATCH"} or (method != "GET" and not self.writable):
            raise ValueError("Read-only or unsupported operation")
        req = Request(safe_url(path), data=None if payload is None else json.dumps(payload).encode(), method=method,
                      headers={"Authorization": "Bearer " + token(self.key, self.key_id, self.issuer),
                               "Content-Type": "application/json"})
        endpoint = re.sub(r"/[0-9a-fA-F-]{8,}(?=/|$)", "/{id}", path.split("?")[0])
        for attempt in range(3):
            try:
                with build_opener(NoRedirect()).open(req, timeout=45) as response:
                    raw = response.read(4_000_001)
                    if len(raw) > 4_000_000:
                        raise ValueError("App Store response exceeds bound")
                    return json.loads(raw) if raw else {}
            except HTTPError as error:
                # Retry transient reads only. A failed write may already have
                # applied, so its caller must inspect state before retrying.
                if method == "GET" and error.code in {429, 500, 502, 503, 504} and attempt < 2:
                    error.close()
                    time.sleep(2 ** attempt)
                    continue
                raw = error.read(100_000)
                try:
                    errors = json.loads(raw).get("errors", [])
                    codes = [e.get("code", "") for e in errors]
                    codes = [c for c in codes if re.fullmatch(r"[A-Z0-9_.-]{1,100}", c)]
                    agreement = any("agreement" in str(e.get("detail", "")).lower() for e in errors)
                except (ValueError, TypeError):
                    codes, agreement = [], False
                raise AppStoreAPIError(error.code, method, endpoint, codes, agreement) from None

    def delete_screenshot(self, identifier):
        self.delete_media("appScreenshots", identifier)

    def delete_preview(self, identifier):
        self.delete_media("appPreviews", identifier)

    def delete_media(self, kind, identifier):
        # Only screenshots explicitly found inside the target draft are removed.
        if kind not in {"appScreenshots", "appPreviews"} or not self.writable or not re.fullmatch(r"[A-Za-z0-9-]+", identifier):
            raise ValueError("Screenshot deletion requires a writable draft client")
        req = Request(safe_url(f"/v1/{kind}/{identifier}"), method="DELETE",
                      headers={"Authorization": "Bearer " + token(self.key, self.key_id, self.issuer)})
        try:
            with build_opener(NoRedirect()).open(req, timeout=45) as response:
                response.read(1024)
        except HTTPError as error:
            raise RuntimeError(f"App Store screenshot deletion HTTP {error.code}") from None


def app_versions(client, app_id):
    return client.all(query(f"/v1/apps/{app_id}/appStoreVersions", **{"filter[platform]": "IOS", "limit": 200}))


def state(version):
    return version["attributes"].get("appVersionState") or version["attributes"].get("appStoreState")


def inspect(client, app, requested_version=None):
    versions = app_versions(client, app["id"])
    summary = []
    media = {}
    for version in versions:
        build = client.request("GET", f'/v1/appStoreVersions/{version["id"]}/build').get("data")
        summary.append({"id": version["id"], "version": version["attributes"]["versionString"],
                        "state": state(version), "release_type": version["attributes"].get("releaseType"),
                        "build": build["attributes"].get("version") if build else None})
        if version["attributes"]["versionString"] == requested_version:
            media = inspect_media(client, version["id"])
    record = client.request("GET", f'/v1/apps/{app["id"]}/appAvailabilityV2')["data"]
    territories = client.all(f'/v2/appAvailabilities/{record["id"]}/territoryAvailabilities?include=territory&limit=200')
    counts = {}
    unavailable = []
    for row in territories:
        attrs = row["attributes"]
        status = attrs.get("contentStatuses", [])
        for item in status:
            counts[item] = counts.get(item, 0) + 1
        if not attrs.get("available"):
            unavailable.append(row.get("relationships", {}).get("territory", {}).get("data", {}).get("id"))
    return {"app_id": app["id"], "versions": summary, "support_products": support_products(client, app["id"]), "availability": availability(client, app["id"]),
            "territories": len(territories), "unavailable_territories": unavailable, "content_status_counts": counts, "media": media}


def validate_config(config, root):
    if not re.fullmatch(r"\d+\.\d+\.\d+", config.get("version", "")):
        raise ValueError("Explicit three-part version required")
    if config.get("releaseType") != "AFTER_APPROVAL" or set(config.get("localizations", {})) != LOCALES:
        raise ValueError("Reviewed automatic public release and bilingual metadata required")
    for locale, attrs in config["localizations"].items():
        for field, maximum in [("whatsNew", 4000), ("description", 4000), ("keywords", 100), ("promotionalText", 170)]:
            if not isinstance(attrs.get(field), str) or not 0 < len(attrs[field]) <= maximum:
                raise ValueError(f"Invalid {locale} {field}")
    return screenshot_manifest(config, root)


def prepare(client, app, build, config, root):
    version_string = config["version"]
    if build["attributes"].get("processingState") != "VALID" or build["attributes"].get("expired"):
        raise ValueError("Build must be processed and active")
    if build["attributes"].get("buildAudienceType") != "APP_STORE_ELIGIBLE":
        raise ValueError("Public-compatible build required")
    if availability(client, app["id"]) != {"france_available": False, "future_countries_enabled": False}:
        raise ValueError("Existing approved territory boundaries changed")
    manifests = validate_config(config, root)
    movies = {locale: movie(config, root, locale) for locale in LOCALES}
    versions = app_versions(client, app["id"])
    matches = [v for v in versions if v["attributes"]["versionString"] == version_string]
    if matches:
        version = one(matches, "target version")
        if state(version) not in EDITABLE:
            raise ValueError("Only the requested editable version may be prepared")
    else:
        version = client.request("POST", "/v1/appStoreVersions", resource("appStoreVersions",
            {"platform": "IOS", "versionString": version_string, "releaseType": config["releaseType"],
             "copyright": config["copyright"]}, {"app": ("apps", app["id"])}))["data"]
    version_id = version["id"]
    client.request("PATCH", f"/v1/appStoreVersions/{version_id}", resource("appStoreVersions",
        {"releaseType": config["releaseType"]}, {"build": ("builds", build["id"])}, version_id))
    localizations = client.all(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=200")
    by_locale = {row["attributes"]["locale"]: row for row in localizations}
    uploaded = {}
    previews = {}
    for locale, attrs in config["localizations"].items():
        if locale in by_locale:
            identifier = by_locale[locale]["id"]
            client.request("PATCH", f"/v1/appStoreVersionLocalizations/{identifier}",
                           resource("appStoreVersionLocalizations", attrs, identifier=identifier))
        else:
            row = client.request("POST", "/v1/appStoreVersionLocalizations", resource("appStoreVersionLocalizations",
                dict(attrs, locale=locale), {"appStoreVersion": ("appStoreVersions", version_id)}))["data"]
            identifier = row["id"]
        uploaded[locale] = sync_screenshots(client, identifier, manifests[locale])
        previews[locale] = sync_preview(client, identifier, movies[locale])
    # Keep the existing review contact entirely within Apple's service.
    # Never copy contact data into a repository, command line, log, or receipt.
    review = optional_resource(client, f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    contact_keys = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail"]
    contact = {k: (review or {}).get("attributes", {}).get(k) for k in contact_keys}
    if not all(contact.values()):
        previous = [v for v in versions if v["id"] != version_id and state(v) in {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}]
        previous.sort(key=lambda v: v["attributes"].get("createdDate", ""), reverse=True)
        if not previous:
            raise ValueError("No released version with an existing review contact")
        prior = optional_resource(client, f'/v1/appStoreVersions/{previous[0]["id"]}/appStoreReviewDetail')
        for key in contact_keys:
            contact[key] = contact[key] or (prior or {}).get("attributes", {}).get(key)
        if not all(contact.values()):
            raise ValueError("Existing Apple review contact is incomplete")
    review_attributes = dict(contact, notes=config["reviewNotes"], demoAccountRequired=False)
    if review:
        client.request("PATCH", f'/v1/appStoreReviewDetails/{review["id"]}', resource("appStoreReviewDetails",
            review_attributes, identifier=review["id"]))
    else:
        client.request("POST", "/v1/appStoreReviewDetails", resource("appStoreReviewDetails", review_attributes,
            {"appStoreVersion": ("appStoreVersions", version_id)}))
    return {"version_id": version_id, "version": version_string, "build": build["attributes"]["version"],
            "screenshots": uploaded, "previews": previews, "release_type": config["releaseType"], "prepared": True}


REVIEW_QUEUE_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW"}


def withdraw(client, app, config):
    """Cancel the pending review submission for the reviewed version.

    Apple only lets a version's build change while the version is editable, so
    replacing a build under review means leaving the queue first. This never
    deletes the version, its metadata, media or the build; it only flips the
    open review submission to cancelled and reports the resulting state.
    """
    version = one([v for v in app_versions(client, app["id"])
                   if v["attributes"]["versionString"] == config["version"]], "target version")
    if state(version) not in REVIEW_QUEUE_STATES:
        return {"version": config["version"], "state": state(version), "withdrawn_now": False}
    submissions = client.all(f'/v1/apps/{app["id"]}/reviewSubmissions?limit=200')
    pending = [r for r in submissions if r["attributes"]["state"] in REVIEW_QUEUE_STATES]
    submission = one(pending, "pending review submission")
    sid = submission["id"]
    client.request("PATCH", f"/v1/reviewSubmissions/{sid}", resource("reviewSubmissions", {"canceled": True}, identifier=sid))
    result = client.request("GET", f"/v1/reviewSubmissions/{sid}")["data"]
    refreshed = one([v for v in app_versions(client, app["id"])
                     if v["attributes"]["versionString"] == config["version"]], "target version")
    return {"version": config["version"], "submission_id": sid,
            "submission_state": result["attributes"]["state"], "state": state(refreshed),
            "withdrawn_now": result["attributes"]["state"] in {"CANCELING", "CANCELED", "UNRESOLVED_ISSUES"}}


def submit(client, app, build, config, root):
    manifests = validate_config(config, root)
    version = one([v for v in app_versions(client, app["id"])
                   if v["attributes"]["versionString"] == config["version"]], "target version")
    version_id = version["id"]
    if state(version) not in EDITABLE | {"READY_FOR_REVIEW"}:
        return {"version": config["version"], "state": state(version), "submitted_now": False}
    linked = client.request("GET", f"/v1/appStoreVersions/{version_id}/build")["data"]
    if linked["id"] != build["id"] or version["attributes"].get("releaseType") != "AFTER_APPROVAL":
        raise ValueError("Reviewed build or release setting changed")
    localizations = client.all(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=200")
    for locale, attrs in config["localizations"].items():
        row = one([r for r in localizations if r["attributes"]["locale"] == locale], "localization")
        if any(row["attributes"].get(k) != v for k, v in attrs.items()):
            raise ValueError("Reviewed metadata changed")
        sync_screenshots(client, row["id"], manifests[locale], verify_only=True)
        sync_preview(client, row["id"], movie(config, root, locale), verify_only=True)
    if availability(client, app["id"]) != {"france_available": False, "future_countries_enabled": False}:
        raise ValueError("Approved territory boundaries changed")
    expected_items = {("appStoreVersion", "appStoreVersions", version_id)}
    catalog = support_products(client, app["id"])
    for expected in config.get("supportProducts", []):
        product = one([r for r in catalog if r["product_id"] == expected["productId"]], "support product")
        if product["state"] == "APPROVED":
            continue
        versions = client.all(f'/v2/inAppPurchases/{product["id"]}/versions?limit=200')
        candidate = one([v for v in versions if v["attributes"]["state"] in {
            "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "REJECTED", "DEVELOPER_REJECTED"}], "support review version")
        expected_items.add(("inAppPurchaseVersion", "inAppPurchaseVersions", candidate["id"]))
    submissions = client.all(f'/v1/apps/{app["id"]}/reviewSubmissions?limit=200')
    draft = [r for r in submissions if r["attributes"]["state"] == "READY_FOR_REVIEW"]
    if len(draft) > 1:
        raise ValueError("Ambiguous existing review drafts")
    submission = draft[0] if draft else client.request("POST", "/v1/reviewSubmissions",
        resource("reviewSubmissions", {"platform": "IOS"}, {"app": ("apps", app["id"])}))["data"]
    sid = submission["id"]
    items = client.all(f"/v1/reviewSubmissions/{sid}/items?include=appStoreVersion,inAppPurchaseVersion&limit=200")
    present = set()
    for item in items:
        linked = [(key, value["data"]["type"], value["data"]["id"])
                  for key, value in item.get("relationships", {}).items()
                  if key != "reviewSubmission" and isinstance(value.get("data"), dict)]
        if len(linked) != 1 or linked[0] not in expected_items:
            raise ValueError("Review draft contains unrelated items")
        present.add(linked[0])
    for relation, kind, identifier in sorted(expected_items - present):
        client.request("POST", "/v1/reviewSubmissionItems", resource("reviewSubmissionItems", relationships={
            "reviewSubmission": ("reviewSubmissions", sid), relation: (kind, identifier)}))
    client.request("PATCH", f"/v1/reviewSubmissions/{sid}", resource("reviewSubmissions", {"submitted": True}, identifier=sid))
    result = client.request("GET", f"/v1/reviewSubmissions/{sid}")["data"]
    current_state = result["attributes"]["state"]
    return {"submission_id": sid, "state": current_state, "version": config["version"],
            "submitted_now": current_state in {"WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETING", "COMPLETE"},
            "release_type": "AFTER_APPROVAL"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation", choices=["inspect", "prepare-support", "prepare", "withdraw", "submit"], default="inspect")
    parser.add_argument("--build")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    root = args.config.parent
    if args.operation in {"prepare", "submit"}:
        validate_config(config, root)
        if not args.build or not re.fullmatch(r"\d+(?:\.\d+){0,2}", args.build):
            raise ValueError("Exact build required for public changes")
    secret = os.environ.pop("ASC_API_KEY_P8")
    with tempfile.TemporaryDirectory(prefix="moneyup-public-asc-") as directory:
        key = Path(directory) / "key.p8"
        fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(secret)
        del secret
        client = ReleaseClient(key, os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], args.operation != "inspect")
        app = one(client.all(query("/v1/apps", **{"filter[bundleId]": BUNDLE, "limit": 2})), "MoneyUp app")
        if app["attributes"].get("bundleId") != BUNDLE:
            raise ValueError("App identity mismatch")
        if args.operation == "inspect":
            result = inspect(client, app, config["version"])
        elif args.operation == "prepare-support":
            result = prepare_support(client, app, config, root)
        elif args.operation == "withdraw":
            result = withdraw(client, app, config)
        else:
            target_app, build = locate(client, config["version"], args.build)
            if target_app["id"] != app["id"]:
                raise ValueError("Build app mismatch")
            result = (prepare if args.operation == "prepare" else submit)(client, app, build, config, root)
        result["source_sha"] = os.environ.get("GITHUB_SHA")
        result["config_sha256"] = hashlib.sha256(args.config.read_bytes()).hexdigest()
        args.receipt.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError) as error:
        raise SystemExit(str(error)) from None
