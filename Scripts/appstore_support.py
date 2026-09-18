"""Configure optional consumable developer support; never accept agreements."""
from decimal import Decimal
import hashlib

from distribute_testflight import one, query
from appstore_screenshots import upload_parts


def support_products(client, app_id):
    rows = client.all(f"/v1/apps/{app_id}/inAppPurchasesV2?limit=200")
    return [{"id": row["id"], "product_id": row["attributes"].get("productId"),
             "state": row["attributes"].get("state"), "type": row["attributes"].get("inAppPurchaseType")}
            for row in rows]


def prepare_support(client, app, config, root):
    from appstore_release import resource
    expected = config["supportProducts"]
    if len(expected) != 3 or {p["productId"] for p in expected} != {
            "com.laiwenkang.MoneyUp.support." + size for size in ("small", "medium", "large")}:
        raise ValueError("Exactly the reviewed three support products are required")
    screenshot = root / config["supportScreenshot"]["file"]
    if not screenshot.resolve().is_relative_to(root.resolve()):
        raise ValueError("Review screenshot path escaped release directory")
    data = screenshot.read_bytes()
    if hashlib.sha256(data).hexdigest() != config["supportScreenshot"]["sha256"]:
        raise ValueError("Support review screenshot changed")
    existing = {row["product_id"]: row for row in support_products(client, app["id"])}
    for product in expected:
        current = existing.get(product["productId"])
        if current and current["type"] != "CONSUMABLE":
            raise ValueError("Support product must be consumable")
        if not current:
            row = client.request("POST", "/v2/inAppPurchases", resource("inAppPurchases",
                {"name": product["name"], "productId": product["productId"], "inAppPurchaseType": "CONSUMABLE",
                 "familySharable": False, "reviewNote": "Settings > Support MoneyUp. Optional, repeatable, one-time developer tip. No features, content, subscription or entitlement are granted."},
                {"app": ("apps", app["id"])}))["data"]
            current = {"id": row["id"]}
        iid = current["id"]
        localizations = client.all(f"/v2/inAppPurchases/{iid}/inAppPurchaseLocalizations?limit=200")
        by_locale = {r["attributes"]["locale"]: r for r in localizations}
        for locale, attrs in product["localizations"].items():
            if locale in by_locale:
                row = by_locale[locale]
                if any(row["attributes"].get(k) != v for k, v in attrs.items()):
                    client.request("PATCH", f'/v1/inAppPurchaseLocalizations/{row["id"]}',
                        resource("inAppPurchaseLocalizations", attrs, identifier=row["id"]))
            else:
                client.request("POST", "/v1/inAppPurchaseLocalizations", resource("inAppPurchaseLocalizations",
                    dict(attrs, locale=locale), {"inAppPurchaseV2": ("inAppPurchases", iid)}))
        detail = client.request("GET", f"/v2/inAppPurchases/{iid}?include=iapPriceSchedule,inAppPurchaseAvailability,appStoreReviewScreenshot")["data"]
        relationships = detail.get("relationships", {})
        if not relationships.get("iapPriceSchedule", {}).get("data"):
            points = client.all(query(f"/v2/inAppPurchases/{iid}/pricePoints", **{"filter[territory]": "USA", "limit": 200}))
            point = one([r for r in points if Decimal(r["attributes"]["customerPrice"]) == Decimal(product["usdPrice"])], "US price point")
            payload = resource("inAppPurchasePriceSchedules", relationships={
                "inAppPurchase": ("inAppPurchases", iid), "baseTerritory": ("territories", "USA")})
            payload["data"]["relationships"]["manualPrices"] = {"data": [{"type": "inAppPurchasePrices", "id": "${support-price}"}]}
            payload["included"] = [{"type": "inAppPurchasePrices", "id": "${support-price}",
                "attributes": {"startDate": None, "endDate": None}, "relationships": {
                    "inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iid}},
                    "inAppPurchasePricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": point["id"]}}}}]
            client.request("POST", "/v1/inAppPurchasePriceSchedules", payload)
        if not relationships.get("inAppPurchaseAvailability", {}).get("data"):
            territories = client.all("/v1/territories?limit=200")
            payload = resource("inAppPurchaseAvailabilities", {"availableInNewTerritories": False},
                               {"inAppPurchase": ("inAppPurchases", iid)})
            payload["data"]["relationships"]["availableTerritories"] = {"data": [
                {"type": "territories", "id": r["id"]} for r in territories if r["id"] != "FRA"]}
            client.request("POST", "/v1/inAppPurchaseAvailabilities", payload)
        if not relationships.get("appStoreReviewScreenshot", {}).get("data"):
            row = client.request("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", resource(
                "inAppPurchaseAppStoreReviewScreenshots", {"fileName": screenshot.name, "fileSize": len(data)},
                {"inAppPurchaseV2": ("inAppPurchases", iid)}))["data"]
            upload_parts(row["attributes"]["uploadOperations"], data)
            client.request("PATCH", f'/v1/inAppPurchaseAppStoreReviewScreenshots/{row["id"]}', resource(
                "inAppPurchaseAppStoreReviewScreenshots", {"uploaded": True,
                 "sourceFileChecksum": hashlib.md5(data, usedforsecurity=False).hexdigest()}, identifier=row["id"]))
    return {"support_products": support_products(client, app["id"]), "agreements_accepted": False,
            "note": "Paid Apps Agreement, banking and tax setup remain Account Holder responsibilities."}
