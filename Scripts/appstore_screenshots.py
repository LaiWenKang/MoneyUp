"""Bounded, resumable uploads of reviewed synthetic App Store screenshots."""
from __future__ import annotations

import hashlib
import re
import struct
from urllib.parse import urlsplit
from urllib.request import Request, build_opener

from distribute_testflight import NoRedirect, one


def screenshot_manifest(config, root):
    result = {}
    for locale, files in config.get("screenshots", {}).items():
        if not 1 <= len(files) <= 10:
            raise ValueError("One to ten screenshots required per locale")
        result[locale] = []
        for entry in files:
            path = (root / entry["file"]).resolve()
            if not path.is_relative_to(root.resolve()) or path.suffix != ".png":
                raise ValueError("Screenshot path must stay within the release directory")
            data = path.read_bytes()
            if not 24 < len(data) <= 15_000_000 or data[:8] != b"\x89PNG\r\n\x1a\n":
                raise ValueError("Invalid or excessive screenshot PNG")
            if struct.unpack(">II", data[16:24]) != (1284, 2778):
                raise ValueError("Reviewed 6.5-inch screenshot dimensions required")
            if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise ValueError("Screenshot digest differs from reviewed manifest")
            result[locale].append((path, data))
        if len({p.name for p, _ in result[locale]}) != len(files):
            raise ValueError("Duplicate screenshot names")
    if set(result) != {"en-US", "zh-Hans"}:
        raise ValueError("Both screenshot localizations required")
    return result


def upload_parts(operations, data):
    ranges = []
    for operation in operations:
        parts = urlsplit(operation["url"])
        if (parts.scheme != "https" or not (parts.hostname or "").endswith(".apple.com")
                or parts.username or parts.password or parts.port not in (None, 443)
                or operation["method"] != "PUT"):
            raise ValueError("Unexpected Apple asset-upload origin or method")
        offset, length = operation["offset"], operation["length"]
        if type(offset) is not int or type(length) is not int or offset < 0 or length <= 0 or offset + length > len(data):
            raise ValueError("Invalid upload byte range")
        ranges.append((offset, offset + length))
    end = 0
    for first, last in sorted(ranges):
        if first != end:
            raise ValueError("Overlapping or incomplete asset upload")
        end = last
    if end != len(data):
        raise ValueError("Incomplete asset upload")
    for operation in operations:
        offset, length = operation["offset"], operation["length"]
        headers = {h["name"]: h["value"] for h in operation.get("requestHeaders", [])}
        if any(k.lower() in {"authorization", "cookie", "host"} for k in headers):
            raise ValueError("Unexpected sensitive upload header")
        request = Request(operation["url"], data=data[offset:offset + length], headers=headers, method="PUT")
        with build_opener(NoRedirect()).open(request, timeout=60) as response:
            response.read(1024)


def complete(row, data):
    attrs = row["attributes"]
    return (attrs.get("assetDeliveryState", {}).get("state") == "COMPLETE"
            and attrs.get("sourceFileChecksum") == hashlib.md5(data, usedforsecurity=False).hexdigest())


def sync_screenshots(client, localization_id, files, verify_only=False):
    sets = client.all(f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets?limit=200")
    sets = [row for row in sets if row["attributes"]["screenshotDisplayType"] == "APP_IPHONE_65"]
    if not sets:
        if verify_only:
            raise ValueError("Required screenshot set missing")
        result = client.request("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_IPHONE_65"},
            "relationships": {"appStoreVersionLocalization": {"data": {
                "type": "appStoreVersionLocalizations", "id": localization_id}}}}})
        sets = [result["data"]]
    sid = one(sets, "screenshot set")["id"]
    existing = client.all(f"/v1/appScreenshotSets/{sid}/appScreenshots?limit=200")
    expected_names = [path.name for path, _ in files]
    if verify_only:
        if [r["attributes"]["fileName"] for r in existing] != expected_names:
            raise ValueError("Screenshot order or count changed")
        if not all(complete(row, data) for row, (_, data) in zip(existing, files)):
            raise ValueError("Screenshots not processed or checksums differ")
        return {"count": len(files), "processed": True}
    # The caller has already checked that this is an editable, exact target
    # version. Remove only screenshots in this draft's own localization/set.
    retained = {}
    expected = {path.name: data for path, data in files}
    for row in existing:
        name = row["attributes"]["fileName"]
        if name in expected and complete(row, expected[name]) and name not in retained:
            retained[name] = row
        elif name in expected and row["attributes"].get("sourceFileChecksum") == hashlib.md5(expected[name], usedforsecurity=False).hexdigest():
            raise ValueError("Screenshot still processing; inspect and retry later")
        else:
            client.delete_screenshot(row["id"])
    ids = []
    for path, data in files:
        if path.name in retained:
            ids.append(retained[path.name]["id"])
            continue
        row = client.request("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots", "attributes": {"fileName": path.name, "fileSize": len(data)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sid}}}}})["data"]
        upload_parts(row["attributes"]["uploadOperations"], data)
        client.request("PATCH", f'/v1/appScreenshots/{row["id"]}', {"data": {
            "type": "appScreenshots", "id": row["id"], "attributes": {
                "uploaded": True, "sourceFileChecksum": hashlib.md5(data, usedforsecurity=False).hexdigest()}}})
        ids.append(row["id"])
    client.request("PATCH", f"/v1/appScreenshotSets/{sid}/relationships/appScreenshots",
                   {"data": [{"type": "appScreenshots", "id": identifier} for identifier in ids]})
    rows = client.all(f"/v1/appScreenshotSets/{sid}/appScreenshots?limit=200")
    return {"count": len(ids), "processed": len(rows) == len(files)
            and all(complete(row, data) for row, (_, data) in zip(rows, files))}
