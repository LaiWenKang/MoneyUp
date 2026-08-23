#!/usr/bin/env python3
"""Fail CI when release-critical privacy, localization, or icon assets drift."""

from __future__ import annotations

import json
import plistlib
import struct
import sys
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_LANGUAGES = {"en", "zh-Hans"}


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_localizations() -> None:
    catalogs = sorted((ROOT / "App").rglob("*.xcstrings"))
    if not catalogs:
        fail("no string catalogs found")

    owners: dict[str, list[Path]] = defaultdict(list)
    checked = 0
    for catalog in catalogs:
        try:
            payload = json.loads(catalog.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            fail(f"cannot parse {catalog.relative_to(ROOT)}: {error}")

        for key, entry in payload.get("strings", {}).items():
            checked += 1
            owners[key].append(catalog)
            localizations = entry.get("localizations", {})
            missing = REQUIRED_LANGUAGES - set(localizations)
            if missing:
                fail(
                    f"{catalog.relative_to(ROOT)}:{key} is missing "
                    + ", ".join(sorted(missing))
                )
            for language in REQUIRED_LANGUAGES:
                unit = localizations[language].get("stringUnit", {})
                if unit.get("state") != "translated" or not unit.get("value", "").strip():
                    fail(
                        f"{catalog.relative_to(ROOT)}:{key} has an incomplete "
                        f"{language} translation"
                    )

    duplicates = {key: paths for key, paths in owners.items() if len(paths) > 1}
    if duplicates:
        key, paths = next(iter(duplicates.items()))
        fail(
            f"localization key {key!r} appears in multiple catalogs: "
            + ", ".join(str(path.relative_to(ROOT)) for path in paths)
        )

    print(f"Validated {checked} bilingual strings in {len(catalogs)} catalogs")


def validate_privacy_manifest() -> None:
    manifest_path = ROOT / "App" / "MoneyUp" / "PrivacyInfo.xcprivacy"
    try:
        with manifest_path.open("rb") as file:
            manifest = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot parse privacy manifest: {error}")

    if manifest.get("NSPrivacyTracking") is not False:
        fail("privacy manifest must declare tracking disabled")
    if manifest.get("NSPrivacyCollectedDataTypes") != []:
        fail("privacy manifest must match MoneyUp's no-data-collection architecture")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        fail("privacy manifest must not declare tracking domains")

    accessed = manifest.get("NSPrivacyAccessedAPITypes", [])
    user_defaults = next(
        (
            item
            for item in accessed
            if item.get("NSPrivacyAccessedAPIType")
            == "NSPrivacyAccessedAPICategoryUserDefaults"
        ),
        None,
    )
    if user_defaults is None or "CA92.1" not in user_defaults.get(
        "NSPrivacyAccessedAPITypeReasons", []
    ):
        fail("privacy manifest must declare UserDefaults reason CA92.1")

    print("Validated PrivacyInfo.xcprivacy")


def png_dimensions(path: Path) -> tuple[int, int]:
    try:
        data = path.read_bytes()[:24]
    except OSError as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")
    if len(data) != 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        fail(f"{path.relative_to(ROOT)} is not a valid PNG")
    return struct.unpack(">II", data[16:24])


def validate_icons() -> None:
    icon_directory = (
        ROOT / "App" / "MoneyUp" / "Assets.xcassets" / "AppIcon.appiconset"
    )
    required = ["AppIcon.png", "AppIcon-Dark.png", "AppIcon-Tinted.png"]
    for name in required:
        path = icon_directory / name
        if png_dimensions(path) != (1024, 1024):
            fail(f"{path.relative_to(ROOT)} must be 1024 by 1024 pixels")
    print("Validated default, dark, and tinted app icons")


def validate_public_documents() -> None:
    for name in ["PRIVACY.md", "SUPPORT.md", "docs/LAUNCH_PLAN.md", "docs/FIRST_TEST.md"]:
        path = ROOT / name
        if not path.is_file() or path.stat().st_size < 200:
            fail(f"missing or incomplete release document: {name}")
        text = path.read_text(encoding="utf-8")
        if "TODO" in text or "TBD" in text:
            fail(f"release document still contains a placeholder: {name}")
    print("Validated public policy, support, launch, and tester documents")


def main() -> None:
    validate_localizations()
    validate_privacy_manifest()
    validate_icons()
    validate_public_documents()
    print("Release asset validation passed")


if __name__ == "__main__":
    main()
