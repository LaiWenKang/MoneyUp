"""Upload reviewed native app-preview movies using Apple's asset protocol."""
import hashlib
from pathlib import Path

from distribute_testflight import one
from appstore_screenshots import upload_parts


def movie(config, root, locale):
    entry = config.get("previews", {}).get(locale)
    if not entry:
        return None
    path = (root / entry["file"]).resolve()
    if not path.is_relative_to(root.resolve()) or path.suffix != ".mp4":
        raise ValueError("Preview movie must stay within the release directory")
    data = path.read_bytes()
    if not 12 < len(data) <= 500_000_000 or data[4:8] != b"ftyp":
        raise ValueError("Invalid or excessive MP4 preview")
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError("Movie differs from the reviewed digest")
    if entry.get("dimensions") != [886, 1920] or not 15 <= entry.get("duration", 0) <= 30:
        raise ValueError("Reviewed App Store preview dimensions and duration required")
    return path, data


def complete(row, data):
    attrs = row["attributes"]
    return (attrs.get("assetDeliveryState", {}).get("state") == "COMPLETE"
            and attrs.get("sourceFileChecksum") == hashlib.md5(data, usedforsecurity=False).hexdigest())


def sync_preview(client, localization_id, movie_data, verify_only=False):
    if movie_data is None:
        return None
    path, data = movie_data
    sets = client.all(f"/v1/appStoreVersionLocalizations/{localization_id}/appPreviewSets?limit=200")
    sets = [r for r in sets if r["attributes"].get("previewType") == "IPHONE_65"]
    if not sets:
        if verify_only:
            raise ValueError("Required app preview is missing")
        row = client.request("POST", "/v1/appPreviewSets", {"data": {
            "type": "appPreviewSets", "attributes": {"previewType": "IPHONE_65"}, "relationships": {
                "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": localization_id}}}}})["data"]
        sets = [row]
    sid = one(sets, "app preview set")["id"]
    existing = client.all(f"/v1/appPreviewSets/{sid}/appPreviews?limit=200")
    if verify_only:
        if len(existing) != 1 or existing[0]["attributes"].get("fileName") != path.name or not complete(existing[0], data):
            raise ValueError("Movie processing, order or digest is not verified")
        return {"processed": True, "count": 1}
    for row in existing:
        if row["attributes"].get("fileName") == path.name and row["attributes"].get("sourceFileChecksum") == hashlib.md5(data, usedforsecurity=False).hexdigest():
            return {"processed": complete(row, data), "count": 1}
    for row in existing:
        client.delete_preview(row["id"])
    row = client.request("POST", "/v1/appPreviews", {"data": {
        "type": "appPreviews", "attributes": {"fileName": path.name, "fileSize": len(data),
            "mimeType": "video/mp4", "previewFrameTimeCode": "00:00:00:15"}, "relationships": {
                "appPreviewSet": {"data": {"type": "appPreviewSets", "id": sid}}}}})["data"]
    upload_parts(row["attributes"]["uploadOperations"], data)
    client.request("PATCH", f'/v1/appPreviews/{row["id"]}', {"data": {
        "type": "appPreviews", "id": row["id"], "attributes": {"uploaded": True,
            "sourceFileChecksum": hashlib.md5(data, usedforsecurity=False).hexdigest()}}})
    row = client.request("GET", f'/v1/appPreviews/{row["id"]}')["data"]
    return {"processed": complete(row, data), "count": 1}
