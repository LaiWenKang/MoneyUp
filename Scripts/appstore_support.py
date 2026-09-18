"""Configure optional consumable developer support; never accept agreements."""
from decimal import Decimal
import hashlib
from urllib.parse import quote

from distribute_testflight import one, query
from appstore_screenshots import upload_parts


def support_products(client, app_id):
    rows = client.all(f"/v1/apps/{app_id}/inAppPurchasesV2?limit=200")
    return [{"id": row["id"], "product_id": row["attributes"].get("productId"),
             "state": row["attributes"].get("state"), "type": row["attributes"].get("inAppPurchaseType")}
            for row in rows]


def verify_price(client, product_id, base_territory, expected):
    schedule = client.request("GET", f"/v2/inAppPurchases/{product_id}/iapPriceSchedule")["data"]
    sid = schedule["id"]
    base = client.request("GET", f"/v1/inAppPurchasePriceSchedules/{sid}/baseTerritory")["data"]
    if base["id"] != base_territory:
        raise ValueError("Existing support base territory differs from the reviewed configuration")
    prices = client.all(query(f"/v1/inAppPurchasePriceSchedules/{sid}/manualPrices",
        **{"filter[territory]": base_territory, "include": "inAppPurchasePricePoint", "limit": 200}))
    price = one(prices, "reviewed base price schedule")
    point_id = price["relationships"]["inAppPurchasePricePoint"]["data"]["id"]
    point = client.request("GET", f"/v1/inAppPurchasePricePoints/{quote(point_id, safe='')}")["data"]
    actual = point["attributes"]["customerPrice"]
    if Decimal(actual) != Decimal(expected):
        raise ValueError("Existing support price differs from the reviewed configuration")
    return {"base_territory": base_territory, "customer_price": actual,
            "start_date": price["attributes"].get("startDate"), "end_date": price["attributes"].get("endDate")}


def prepare_support(client, app, config, root):
    from appstore_release import resource
    expected = config["supportProducts"]
    base_territory = config["supportBaseTerritory"]
    if base_territory not in {"USA", "SGP"}:
        raise ValueError("Reviewed support base territory required")
    if config.get("supportBaseCurrency") != {"USA": "USD", "SGP": "SGD"}[base_territory]:
        raise ValueError("Support base currency differs from the selected territory")
    if len(expected) != 3 or {p["productId"] for p in expected} != {
            "com.laiwenkang.MoneyUp.support." + size for size in ("small", "medium", "large")}:
        raise ValueError("Exactly the reviewed three support products are required")
    for product in expected:
        price = Decimal(product["basePrice"])
        if not price.is_finite() or price <= 0 or price.as_tuple().exponent < -2:
            raise ValueError("Support prices must be positive base-currency amounts in cents")
        if set(product.get("localizations", {})) != {"en-US", "zh-Hans"}:
            raise ValueError("Bilingual support product metadata required")
        for attrs in product["localizations"].values():
            if not 1 <= len(attrs.get("name", "")) <= 30 or not 1 <= len(attrs.get("description", "")) <= 45:
                raise ValueError("Invalid support product copy")
    screenshot = root / config["supportScreenshot"]["file"]
    if not screenshot.resolve().is_relative_to(root.resolve()):
        raise ValueError("Review screenshot path escaped release directory")
    data = screenshot.read_bytes()
    if not 24 < len(data) <= 15_000_000 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid support review screenshot")
    if hashlib.sha256(data).hexdigest() != config["supportScreenshot"]["sha256"]:
        raise ValueError("Support review screenshot changed")
    existing = {row["product_id"]: row for row in support_products(client, app["id"])}
    pricing = {}
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
            points = client.all(query(f"/v2/inAppPurchases/{iid}/pricePoints", **{"filter[territory]": base_territory, "limit": 200}))
            point = one([r for r in points if Decimal(r["attributes"]["customerPrice"]) == Decimal(product["basePrice"])], "base-territory price point")
            payload = resource("inAppPurchasePriceSchedules", relationships={
                "inAppPurchase": ("inAppPurchases", iid), "baseTerritory": ("territories", base_territory)})
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
        versions = client.all(f"/v2/inAppPurchases/{iid}/versions?limit=200")
        if not versions:
            client.request("POST", "/v1/inAppPurchaseVersions", resource("inAppPurchaseVersions",
                relationships={"inAppPurchase": ("inAppPurchases", iid)}))
        pricing[product["productId"]] = verify_price(client, iid, base_territory, product["basePrice"])
    return {"support_products": support_products(client, app["id"]), "pricing": pricing, "agreements_accepted": False,
            "note": "Paid Apps Agreement, banking and tax setup remain Account Holder responsibilities."}
