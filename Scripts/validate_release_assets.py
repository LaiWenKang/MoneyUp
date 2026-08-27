#!/usr/bin/env python3
"""Fail CI when release-critical privacy, localization, or icon assets drift."""

from __future__ import annotations

import json
import plistlib
import re
import struct
import sys
import zlib
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


def png_alpha_coverage(path: Path) -> tuple[int, int, int, int]:
    """Return alpha extrema and fully transparent/opaque pixel counts.

    Release illustrations are normalized to non-interlaced 8-bit RGBA PNGs.
    Decoding their scanline filters here keeps the CI gate dependency-free and
    rejects files that merely declare an unused alpha channel.
    """
    data = path.read_bytes()
    width, height = struct.unpack(">II", data[16:24])
    bit_depth = data[24]
    color_type = data[25]
    interlace = data[28]
    if bit_depth != 8 or color_type not in {4, 6} or interlace != 0:
        fail(
            f"{path.relative_to(ROOT)} must be a non-interlaced 8-bit "
            "grayscale-alpha or RGBA PNG"
        )

    compressed = bytearray()
    offset = 8
    while offset + 12 <= len(data):
        chunk_length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + chunk_length]
        if chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        offset += 12 + chunk_length
        if chunk_type == b"IEND":
            break

    try:
        scanlines = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        fail(f"cannot decode {path.relative_to(ROOT)} alpha data: {error}")

    bytes_per_pixel = 4 if color_type == 6 else 2
    alpha_offset = bytes_per_pixel - 1
    row_bytes = width * bytes_per_pixel
    expected_bytes = height * (row_bytes + 1)
    if len(scanlines) != expected_bytes:
        fail(f"{path.relative_to(ROOT)} has unexpected PNG scanline data")

    previous = bytearray(row_bytes)
    alpha_values: list[int] = []
    cursor = 0
    for _ in range(height):
        filter_type = scanlines[cursor]
        cursor += 1
        raw = scanlines[cursor : cursor + row_bytes]
        cursor += row_bytes
        reconstructed = bytearray(row_bytes)
        for index, value in enumerate(raw):
            left = reconstructed[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            up = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = up
            elif filter_type == 3:
                predictor = (left + up) // 2
            elif filter_type == 4:
                estimate = left + up - upper_left
                left_distance = abs(estimate - left)
                up_distance = abs(estimate - up)
                upper_left_distance = abs(estimate - upper_left)
                predictor = (
                    left
                    if left_distance <= up_distance and left_distance <= upper_left_distance
                    else up if up_distance <= upper_left_distance else upper_left
                )
            else:
                fail(f"{path.relative_to(ROOT)} uses unsupported PNG filter {filter_type}")
            reconstructed[index] = (value + predictor) & 0xFF
        alpha_values.extend(reconstructed[alpha_offset::bytes_per_pixel])
        previous = reconstructed

    return (
        min(alpha_values),
        max(alpha_values),
        sum(value == 0 for value in alpha_values),
        sum(value == 255 for value in alpha_values),
    )


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

    mark_directory = (
        ROOT / "App" / "MoneyUp" / "Assets.xcassets" / "MoneyUpBrandMark.imageset"
    )
    expected_marks = {
        "MoneyUpBrandMark.png": (384, 384, "1x"),
        "MoneyUpBrandMark@2x.png": (768, 768, "2x"),
        "MoneyUpBrandMark@3x.png": (1152, 1152, "3x"),
    }
    for name, (expected_width, expected_height, _) in expected_marks.items():
        path = mark_directory / name
        width, height, color_type, _ = png_metadata(path)
        if (width, height) != (expected_width, expected_height):
            fail(
                f"{path.relative_to(ROOT)} must be "
                f"{expected_width} by {expected_height} pixels"
            )
        if color_type not in {4, 6}:
            fail(f"{path.relative_to(ROOT)} must preserve a transparent mask")

    mark_contents_path = mark_directory / "Contents.json"
    try:
        mark_contents = json.loads(mark_contents_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse horned-money mark Contents.json: {error}")
    mark_images = mark_contents.get("images", [])
    actual_marks = {
        item.get("filename"): item.get("scale")
        for item in mark_images
        if item.get("filename") is not None
    }
    expected_scales = {
        name: scale for name, (_, _, scale) in expected_marks.items()
    }
    if actual_marks != expected_scales:
        fail(f"invalid horned-money mark slots: {actual_marks}")
    template_intent = mark_contents.get("properties", {}).get(
        "template-rendering-intent"
    )
    if template_intent != "template":
        fail("the shared horned-money mark must render as a semantic template")
    print("Validated shared horned-money brand mark")

    widget_mark_directory = (
        ROOT / "App" / "MoneyUpWidget" / "Assets.xcassets"
        / "MoneyUpBrandMark.imageset"
    )
    for name in expected_marks:
        app_path = mark_directory / name
        widget_path = widget_mark_directory / name
        if not widget_path.is_file() or widget_path.read_bytes() != app_path.read_bytes():
            fail(f"widget horned-money mark drifted from the app asset: {name}")

    illustrations = {
        "MoneyUpMoneyWorld": "MoneyUpMoneyWorld",
        "MoneyUpScenarioStudio": "MoneyUpScenarioStudio",
    }
    expected_illustration_sizes = {
        "": (256, 256, "1x", None),
        "@2x": (512, 512, "2x", None),
        "@3x": (768, 768, "3x", None),
        "-Dark": (256, 256, "1x", "dark"),
        "-Dark@2x": (512, 512, "2x", "dark"),
        "-Dark@3x": (768, 768, "3x", "dark"),
    }
    app_assets = ROOT / "App" / "MoneyUp" / "Assets.xcassets"
    for asset_name, filename_stem in illustrations.items():
        directory = app_assets / f"{asset_name}.imageset"
        expected_slots: dict[str, tuple[str, str | None]] = {}
        for suffix, (expected_width, expected_height, scale, appearance) in (
            expected_illustration_sizes.items()
        ):
            name = f"{filename_stem}{suffix}.png"
            expected_slots[name] = (scale, appearance)
            width, height, color_type, has_transparency = png_metadata(
                directory / name
            )
            if (width, height) != (expected_width, expected_height):
                fail(
                    f"{(directory / name).relative_to(ROOT)} must be "
                    f"{expected_width} by {expected_height} pixels"
                )
            if color_type not in {4, 6} and not has_transparency:
                fail(f"{name} must preserve a genuine transparent cutout")
            minimum_alpha, maximum_alpha, transparent, opaque = png_alpha_coverage(
                directory / name
            )
            pixel_count = expected_width * expected_height
            if (
                minimum_alpha != 0
                or maximum_alpha != 255
                or transparent < pixel_count // 20
                or opaque < pixel_count // 20
            ):
                fail(
                    f"{name} must contain substantial fully transparent and "
                    "fully opaque regions"
                )
        try:
            payload = json.loads(
                (directory / "Contents.json").read_text(encoding="utf-8")
            )
        except (OSError, json.JSONDecodeError) as error:
            fail(f"cannot parse {asset_name} Contents.json: {error}")
        actual_slots = {
            item.get("filename"): (
                item.get("scale"),
                (
                    item.get("appearances", [{}])[0].get("value")
                    if item.get("appearances")
                    else None
                ),
            )
            for item in payload.get("images", [])
            if item.get("filename") is not None
        }
        if actual_slots != expected_slots:
            fail(f"invalid {asset_name} illustration slots: {actual_slots}")
    print("Validated adaptive 3D illustration assets and widget brand mark")


def validate_brand_palette() -> None:
    assets = ROOT / "App" / "MoneyUp" / "Assets.xcassets"
    expected = {
        "AccentColor": ["#34785F", "#82CEAE"],
        "BrandBackground": ["#F7F9F6", "#101512"],
        "BrandSurface": ["#EEF4F0", "#18211D"],
        "BrandSurfaceElevated": ["#FAFBF9", "#202923"],
        "BrandAction": ["#34785F", "#82CEAE"],
        "BrandMist": ["#D4EAD8", "#3C6349"],
    }
    for name, expected_colors in expected.items():
        path = assets / f"{name}.colorset" / "Contents.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            fail(f"cannot parse semantic brand asset {name}: {error}")
        actual: list[str] = []
        for item in payload.get("colors", []):
            components = item.get("color", {}).get("components", {})
            try:
                red = int(components["red"], 16)
                green = int(components["green"], 16)
                blue = int(components["blue"], 16)
            except (KeyError, TypeError, ValueError):
                fail(f"{name} must use explicit hexadecimal sRGB components")
            actual.append(f"#{red:02X}{green:02X}{blue:02X}")
        if actual != expected_colors:
            fail(f"{name} drifted from the approved soft-green palette: {actual}")
        if any(color in {"#FFFFFF", "#000000"} for color in actual):
            fail(f"{name} must not use pure white or pure black")

    if (assets / "GoldAccent.colorset" / "Contents.json").exists():
        fail("the retired gold accent must not return to the primary palette")
    if not (ROOT / "Scripts" / "generate_brand_icons.py").is_file():
        fail("app icon artwork must remain reproducible")
    theme = (ROOT / "App" / "MoneyUp" / "MoneyUpTheme.swift").read_text(
        encoding="utf-8"
    )
    if 'Image("MoneyUpBrandMark")' not in theme:
        fail("in-app brand surfaces must use the shared horned-money mark")
    if "MoneyUpGrowthMark" in theme or 'Image(systemName: "arrow.up.right")' in theme:
        fail("the retired three-bar/up-arrow brand mark must not return")
    print("Validated adaptive soft-green semantic palette")


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
    if "UIColorName: BrandBackground" not in spec:
        fail("the launch screen must use the adaptive non-pure brand background")
    if spec.count("CODE_SIGN_STYLE: Automatic") != 2:
        fail(
            "MoneyUp and MoneyUpWidget must use automatic signing"
        )
    if "CODE_SIGN_IDENTITY:" in spec:
        fail(
            "automatic signing must not force a code-sign identity; "
            "Apple Distribution signing occurs during export"
        )
    entitlement_contract = {
        "App/MoneyUp/MoneyUp.entitlements": "App/MoneyUp/MoneyUp.entitlements",
        "App/MoneyUpWidget/MoneyUpWidget.entitlements": (
            "App/MoneyUpWidget/MoneyUpWidget.entitlements"
        ),
    }
    discovered_entitlements = {
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "App").rglob("*.entitlements")
    }
    if discovered_entitlements != set(entitlement_contract):
        fail(
            "only the reviewed app/widget App Group entitlements may ship: "
            f"{sorted(discovered_entitlements)}"
        )
    for relative_path, declared_path in entitlement_contract.items():
        if f"CODE_SIGN_ENTITLEMENTS: {declared_path}" not in spec:
            fail(f"project.yml does not sign with {declared_path}")
        with (ROOT / relative_path).open("rb") as handle:
            entitlement = plistlib.load(handle)
        if entitlement != {
            "com.apple.security.application-groups": [
                "group.com.laiwenkang.MoneyUp"
            ]
        }:
            fail(f"unexpected capability in {relative_path}")
    if "SystemCapabilities" in spec or re.search(
        r"^\s+capabilities:\s*$", spec, re.MULTILINE
    ):
        fail(
            "Xcode capabilities require a signing-flow review before the "
            "unsigned archive path can be used"
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
        "method -string app-store-connect",
        "signingStyle -string automatic",
        "--validate-app",
        "destination -string upload",
        "uploadSymbols -bool true",
        "Scripts/validate_built_bundle.py",
        "Confirm the archive is unsigned",
        "codesign --verify",
        "embedded.mobileprovision",
        "get-task-allow",
        "ProvisionedDevices",
        "ProvisionsAllDevices",
        "-disableAutomaticPackageResolution",
        "actions/upload-artifact@",
        "ARCHIVE_ENCRYPTION_PASSWORD",
        "SOURCE_BUILD_NUMBER:",
        "APP_GROUP_ID: group.com.laiwenkang.MoneyUp",
        "Verify source candidate identity and App Group contract",
        "com.apple.security.application-groups",
        "distribution profile must authorize only",
        "signed entitlements must contain only",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"TestFlight workflow is missing {declaration}")

    archive_step = re.search(
        r"(?ms)^      - name: Create an unsigned release archive\n"
        r"(?P<body>.*?)(?=^      - name: |\Z)",
        workflow,
    )
    if archive_step is None:
        fail("TestFlight workflow is missing the unsigned archive step")
    archive_body = archive_step.group("body")
    for declaration in [
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "clean archive",
    ]:
        if declaration not in archive_body:
            fail(f"unsigned archive step is missing {declaration}")
    for declaration in [
        "-allowProvisioningUpdates",
        "-authenticationKey",
        "CODE_SIGN_STYLE=",
        "CODE_SIGN_IDENTITY=",
    ]:
        if declaration in archive_body:
            fail(f"unsigned archive step must not contain {declaration}")

    export_step = re.search(
        r"(?ms)^      - name: Export an App Store Connect IPA\n"
        r"(?P<body>.*?)(?=^      - name: |\Z)",
        workflow,
    )
    if export_step is None:
        fail("TestFlight workflow is missing the App Store Connect export step")
    export_body = export_step.group("body")
    for declaration in [
        "method -string app-store-connect",
        "signingStyle -string automatic",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        "-authenticationKeyID",
        "-authenticationKeyIssuerID",
    ]:
        if declaration not in export_body:
            fail(f"App Store Connect export step is missing {declaration}")

    key_step_position = workflow.find("- name: Materialize the App Store Connect key")
    unsigned_check_position = workflow.find("- name: Confirm the archive is unsigned")
    export_step_position = workflow.find("- name: Export an App Store Connect IPA")
    if not unsigned_check_position < key_step_position < export_step_position:
        fail(
            "the App Store Connect key must be materialized after the unsigned "
            "archive checks and immediately before export"
        )

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

    project_build = re.search(
        r"^\s+CURRENT_PROJECT_VERSION:\s*([^\s#]+)", project, re.MULTILINE
    )
    workflow_source_build = re.search(
        r"^\s+SOURCE_BUILD_NUMBER:\s*([^\s#]+)", workflow, re.MULTILINE
    )
    if (
        project_build is None
        or workflow_source_build is None
        or project_build.group(1) != workflow_source_build.group(1)
    ):
        fail("TestFlight workflow source build must match project.yml")

    print("Validated protected, pinned TestFlight distribution workflow structure")


def main() -> None:
    validate_localizations()
    validate_privacy_manifest()
    validate_info_plist_localizations()
    validate_icons()
    validate_brand_palette()
    validate_public_documents()
    validate_project_configuration()
    validate_testflight_workflow()
    print("Release asset validation passed")


if __name__ == "__main__":
    main()
