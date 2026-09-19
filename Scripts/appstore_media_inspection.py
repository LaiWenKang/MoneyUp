"""Read every locale/display family in a version without exposing asset URLs."""
from collections import Counter


def inspect_media(client, version_id):
    localizations = client.all(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=200")
    result = {}
    for locale in localizations:
        media = {}
        for label, parent, child, type_key in [
            ("screenshots", "appScreenshotSets", "appScreenshots", "screenshotDisplayType"),
            ("previews", "appPreviewSets", "appPreviews", "previewType"),
        ]:
            sets = client.all(f'/v1/appStoreVersionLocalizations/{locale["id"]}/{parent}?limit=200')
            summaries = []
            for asset_set in sets:
                assets = client.all(f'/v1/{parent}/{asset_set["id"]}/{child}?limit=200')
                states = Counter(row.get("attributes", {}).get("assetDeliveryState", {}).get("state", "UNKNOWN") for row in assets)
                summaries.append({"type": asset_set["attributes"][type_key], "count": len(assets), "states": dict(states)})
            media[label] = summaries
        result[locale["attributes"]["locale"]] = media
    return result
