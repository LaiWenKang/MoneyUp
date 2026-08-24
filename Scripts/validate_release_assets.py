#!/usr/bin/env python3
"""Fail CI when release-critical privacy, localization, or icon assets drift."""

from __future__ import annotations

import json
import plistlib
import re
import struct
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_LANGUAGES = {"en", "zh-Hans"}
SQLCIPHER_REVISION = "f879fffaaa3ad3541a77830daad4a28726dfa927"
PRINTF_PLACEHOLDER = re.compile(
    r"%(?:(\d+)\$)?[-+# 0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|L|z|j|t|q)?([@diouxXfFeEgGaAcCsSp])"
)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def collect_string_units(
    payload: object, path: tuple[str, ...] = ()
) -> dict[tuple[str, ...], dict[str, object]]:
    """Return every stringUnit leaf, including plural and device variations."""
    units: dict[tuple[str, ...], dict[str, object]] = {}
    if isinstance(payload, dict):
        if "stringUnit" in payload:
            unit = payload["stringUnit"]
            if not isinstance(unit, dict):
                fail(f"invalid stringUnit at {'/'.join(path) or '<root>'}")
            units[path] = unit
        for key, value in payload.items():
            if key != "stringUnit" and isinstance(value, (dict, list)):
                units.update(collect_string_units(value, (*path, str(key))))
    elif isinstance(payload, list):
        for index, value in enumerate(payload):
            if isinstance(value, (dict, list)):
                units.update(collect_string_units(value, (*path, str(index))))
    return units


def placeholder_signature(value: str) -> tuple[tuple[int, str], ...]:
    """Normalize printf argument positions so translated text may reorder them."""
    implicit_position = 0
    signature: list[tuple[int, str]] = []
    for match in PRINTF_PLACEHOLDER.finditer(value.replace("%%", "")):
        explicit_position = match.group(1)
        if explicit_position is None:
            implicit_position += 1
            position = implicit_position
        else:
            position = int(explicit_position)
        signature.append((position, match.group(2)))
    return tuple(sorted(signature))


def validate_localizations() -> None:
    catalogs = sorted((ROOT / "App").rglob("*.xcstrings"))
    if not catalogs:
        fail("no string catalogs found")

    app_root = ROOT / "App" / "MoneyUp"
    app_catalogs = sorted(app_root.rglob("*.xcstrings"))
    if [path.relative_to(app_root).as_posix() for path in app_catalogs] != [
        "Resources/Localizable.xcstrings"
    ]:
        fail(
            "app strings must remain in the default Localizable.xcstrings "
            "table unless every lookup names a custom table"
        )

    widget_root = ROOT / "App" / "MoneyUpWidget"
    widget_catalogs = sorted(widget_root.rglob("*.xcstrings"))
    if [path.relative_to(widget_root).as_posix() for path in widget_catalogs] != [
        "Localizable.xcstrings"
    ]:
        fail("widget strings must remain in the default Localizable.xcstrings table")

    checked = 0
    for catalog in catalogs:
        try:
            payload = json.loads(catalog.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            fail(f"cannot parse {catalog.relative_to(ROOT)}: {error}")

        for key, entry in payload.get("strings", {}).items():
            checked += 1
            localizations = entry.get("localizations", {})
            missing = REQUIRED_LANGUAGES - set(localizations)
            if missing:
                fail(
                    f"{catalog.relative_to(ROOT)}:{key} is missing "
                    + ", ".join(sorted(missing))
                )
            language_units = {
                language: collect_string_units(localizations[language])
                for language in REQUIRED_LANGUAGES
            }
            expected_paths = set(language_units["en"])
            if not expected_paths:
                fail(f"{catalog.relative_to(ROOT)}:{key} has no English string unit")
            for language in REQUIRED_LANGUAGES:
                actual_paths = set(language_units[language])
                if actual_paths != expected_paths:
                    fail(
                        f"{catalog.relative_to(ROOT)}:{key} has mismatched "
                        f"{language} variation paths"
                    )
                for unit_path, unit in language_units[language].items():
                    value = unit.get("value")
                    if (
                        unit.get("state") != "translated"
                        or not isinstance(value, str)
                        or not value.strip()
                    ):
                        path_text = "/".join(unit_path) or "default"
                        fail(
                            f"{catalog.relative_to(ROOT)}:{key}:{path_text} has "
                            f"an incomplete {language} translation"
                        )
            for unit_path in expected_paths:
                english = language_units["en"][unit_path]["value"]
                mandarin = language_units["zh-Hans"][unit_path]["value"]
                if placeholder_signature(english) != placeholder_signature(mandarin):
                    path_text = "/".join(unit_path) or "default"
                    fail(
                        f"{catalog.relative_to(ROOT)}:{key}:{path_text} has "
                        "mismatched printf placeholders"
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


def validate_info_plist_localizations() -> None:
    expected = {
        "en": "Unlock your private MoneyUp financial data.",
        "zh-Hans": "解锁你在 MoneyUp 中的私密财务数据。",
    }
    for language, value in expected.items():
        path = ROOT / "App" / "MoneyUp" / f"{language}.lproj" / "InfoPlist.strings"
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            fail(f"cannot read {path.relative_to(ROOT)}: {error}")
        declaration = f'"NSFaceIDUsageDescription" = "{value}";'
        if declaration not in text:
            fail(
                f"{path.relative_to(ROOT)} must localize NSFaceIDUsageDescription"
            )
    print("Validated bilingual Face ID purpose strings")


def png_metadata(path: Path) -> tuple[int, int, int, bool]:
    try:
        data = path.read_bytes()
    except OSError as error:
        fail(f"cannot read {path.relative_to(ROOT)}: {error}")
    if (
        len(data) < 33
        or data[:8] != b"\x89PNG\r\n\x1a\n"
        or data[12:16] != b"IHDR"
        or struct.unpack(">I", data[8:12])[0] != 13
    ):
        fail(f"{path.relative_to(ROOT)} is not a valid PNG")
    width, height = struct.unpack(">II", data[16:24])
    color_type = data[25]
    has_transparency_chunk = False
    offset = 8
    while offset + 12 <= len(data):
        chunk_length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_end = offset + 12 + chunk_length
        if chunk_end > len(data):
            fail(f"{path.relative_to(ROOT)} has a truncated PNG chunk")
        chunk_type = data[offset + 4 : offset + 8]
        if chunk_type == b"tRNS":
            has_transparency_chunk = True
        offset = chunk_end
        if chunk_type == b"IEND":
            break
    return width, height, color_type, has_transparency_chunk


def validate_icons() -> None:
    icon_directory = (
        ROOT / "App" / "MoneyUp" / "Assets.xcassets" / "AppIcon.appiconset"
    )
    required = ["AppIcon.png", "AppIcon-Dark.png", "AppIcon-Tinted.png"]
    for name in required:
        path = icon_directory / name
        width, height, color_type, has_transparency_chunk = png_metadata(path)
        if (width, height) != (1024, 1024):
            fail(f"{path.relative_to(ROOT)} must be 1024 by 1024 pixels")
        if color_type in {4, 6} or has_transparency_chunk:
            fail(f"{path.relative_to(ROOT)} must not contain an alpha channel")

    contents_path = icon_directory / "Contents.json"
    try:
        contents = json.loads(contents_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse app icon Contents.json: {error}")

    expected_appearances = {
        "AppIcon.png": None,
        "AppIcon-Dark.png": "dark",
        "AppIcon-Tinted.png": "tinted",
    }
    images = contents.get("images", [])
    if not isinstance(images, list) or len(images) != len(expected_appearances):
        fail("app icon Contents.json must define default, dark, and tinted slots")
    for image in images:
        filename = image.get("filename")
        if filename not in expected_appearances:
            fail(f"unexpected app icon slot: {filename!r}")
        if (
            image.get("idiom") != "universal"
            or image.get("platform") != "ios"
            or image.get("size") != "1024x1024"
        ):
            fail(f"invalid App Store icon metadata for {filename}")
        appearances = image.get("appearances")
        expected = expected_appearances[filename]
        if expected is None and appearances is not None:
            fail("default AppIcon.png must not declare an appearance")
        if expected is not None and appearances != [
            {"appearance": "luminosity", "value": expected}
        ]:
            fail(f"invalid {expected} appearance metadata for {filename}")
    print("Validated default, dark, and tinted app icons")


def validate_public_documents() -> None:
    for name in [
        "PRIVACY.md",
        "SUPPORT.md",
        "docs/APPLE_SETUP.md",
        "docs/LAUNCH_PLAN.md",
        "docs/FIRST_TEST.md",
    ]:
        path = ROOT / name
        if not path.is_file() or path.stat().st_size < 200:
            fail(f"missing or incomplete release document: {name}")
        text = path.read_text(encoding="utf-8")
        if "TODO" in text or "TBD" in text:
            fail(f"release document still contains a placeholder: {name}")
    print("Validated public policy, support, launch, and tester documents")


def validate_project_configuration() -> None:
    path = ROOT / "project.yml"
    try:
        spec = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read project.yml: {error}")

    if "SWIFT_EMIT_LOC_STRINGS: YES" not in spec:
        fail("project.yml must enable compiler extraction of Swift strings")
    if "DEBUG_INFORMATION_FORMAT: dwarf-with-dsym" not in spec:
        fail("project.yml must emit dSYMs for release crash diagnosis")
    if spec.count("CODE_SIGN_IDENTITY: Apple Distribution") != 2:
        fail(
            "MoneyUp and MoneyUpWidget must use Apple Distribution signing "
            "for Release builds"
        )

    lines = spec.splitlines()
    try:
        start = lines.index("  MoneyUpWidget:") + 1
    except ValueError:
        fail("project.yml does not define MoneyUpWidget")
    end = len(lines)
    for index in range(start, len(lines)):
        line = lines[index]
        indentation = len(line) - len(line.lstrip(" "))
        if line.strip() and indentation < 4:
            end = index
            break
    widget = "\n".join(lines[start:end])
    required = [
        "CFBundleShortVersionString: $(MARKETING_VERSION)",
        "CFBundleVersion: $(CURRENT_PROJECT_VERSION)",
        "CODE_SIGN_STYLE: Automatic",
        "APPLICATION_EXTENSION_API_ONLY: YES",
    ]
    for declaration in required:
        if declaration not in widget:
            fail(f"MoneyUpWidget is missing {declaration}")

    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    if f'revision: "{SQLCIPHER_REVISION}"' not in package:
        fail("SQLCipher.swift must remain pinned to its reviewed commit")

    print("Validated matching app/widget versions and automatic signing")


def validate_testflight_workflow() -> None:
    path = ROOT / ".github" / "workflows" / "testflight.yml"
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read TestFlight workflow: {error}")

    required = [
        "workflow_dispatch:",
        "runs-on: macos-26",
        "environment: testflight",
        "cancel-in-progress: false",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        "CODE_SIGN_STYLE=Automatic",
        'CODE_SIGN_IDENTITY="Apple Distribution"',
        "--validate-app",
        "destination -string upload",
        "uploadSymbols -bool true",
        "Scripts/validate_built_bundle.py",
        "-disableAutomaticPackageResolution",
        "actions/upload-artifact@",
        "ARCHIVE_ENCRYPTION_PASSWORD",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"TestFlight workflow is missing {declaration}")

    if not re.search(r"actions/checkout@[0-9a-f]{40}", workflow):
        fail("TestFlight workflow must pin actions/checkout to a full commit")
    if not re.search(r"actions/upload-artifact@[0-9a-f]{40}", workflow):
        fail("TestFlight workflow must pin actions/upload-artifact to a full commit")

    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    project_version = re.search(
        r"^\s+MARKETING_VERSION:\s*([^\s#]+)", project, re.MULTILINE
    )
    workflow_version = re.search(
        r"^\s+MARKETING_VERSION:\s*([^\s#]+)", workflow, re.MULTILINE
    )
    if (
        project_version is None
        or workflow_version is None
        or project_version.group(1) != workflow_version.group(1)
    ):
        fail("TestFlight workflow marketing version must match project.yml")

    print("Validated protected, pinned TestFlight distribution workflow structure")


def main() -> None:
    validate_localizations()
    validate_privacy_manifest()
    validate_info_plist_localizations()
    validate_icons()
    validate_public_documents()
    validate_project_configuration()
    validate_testflight_workflow()
    print("Release asset validation passed")


if __name__ == "__main__":
    main()
