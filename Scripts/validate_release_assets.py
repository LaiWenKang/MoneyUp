#!/usr/bin/env python3
"""Fail CI when release-critical privacy, localization, or icon assets drift."""

from __future__ import annotations

import csv
import json
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_LANGUAGES = {"en", "zh-Hans"}
SQLCIPHER_REVISION = "f879fffaaa3ad3541a77830daad4a28726dfa927"
CHECKOUT_ACTION_REVISION = "3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ARTIFACT_REVISION = "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
XCODEGEN_VERSION = "2.46.0"
XCODEGEN_SHA256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
CI_XCODE_VERSION = "16.4"
CI_XCODE_BUILD = "16F6"
CI_IPHONESIMULATOR_SDK_VERSION = "18.5"
RELEASE_XCODE_VERSION = "26.6"
RELEASE_XCODE_BUILD = "17F113"
RELEASE_IPHONEOS_SDK_VERSION = "26.5"
TESTFLIGHT_CONTROL_ISSUE = 23
PRINTF_PLACEHOLDER = re.compile(
    r"%(?:(\d+)\$)?[-+# 0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|L|z|j|t|q)?([@diouxXfFeEgGaAcCsSp])"
)
LOCALIZED_STRING_REFERENCE = re.compile(
    r'String\(localized:\s*"([^"]+)"'
)
SWIFTUI_LOCALIZED_REFERENCE = re.compile(
    r'(?:Text|Button|Label|Picker|Toggle|SecureField|TextField|Section|'
    r'NavigationLink|DisclosureGroup|LabeledContent|confirmationDialog|'
    r'navigationTitle|alert)\(\s*'
    r'"([A-Za-z0-9_.-]+)"'
)
ACCESSIBILITY_LOCALIZED_REFERENCE = re.compile(
    r'\.accessibility(?:Label|Hint)\(\s*"([A-Za-z0-9_.-]+)"'
)
HARD_CODED_CHART_DIMENSION = re.compile(r'\.value\(\s*"[^"]+"')


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

    catalog_keys = {
        catalog: set(json.loads(catalog.read_text(encoding="utf-8"))["strings"])
        for catalog in catalogs
    }
    source_catalogs = (
        (
            app_root,
            catalog_keys[app_root / "Resources" / "Localizable.xcstrings"],
        ),
        (
            widget_root,
            catalog_keys[widget_root / "Localizable.xcstrings"],
        ),
    )
    for source_root, keys in source_catalogs:
        for source in source_root.rglob("*.swift"):
            text = source.read_text(encoding="utf-8")
            referenced = {
                match.group(1)
                for pattern in (
                    LOCALIZED_STRING_REFERENCE,
                    SWIFTUI_LOCALIZED_REFERENCE,
                    ACCESSIBILITY_LOCALIZED_REFERENCE,
                )
                for match in pattern.finditer(text)
            }
            missing = sorted(referenced - keys)
            if missing:
                fail(
                    f"{source.relative_to(ROOT)} references missing localized "
                    f"key(s): {', '.join(missing)}"
                )
            if HARD_CODED_CHART_DIMENSION.search(text):
                fail(
                    f"{source.relative_to(ROOT)} contains a hard-coded chart "
                    "dimension; use String(localized:)"
                )
    print("Validated literal Swift localization references")


def validate_offline_runtime_boundary() -> None:
    forbidden_runtime_symbols = (
        "import Network",
        "import WebKit",
        "URLSession",
        "NWConnection",
        "WKWebView",
        "CFNetwork",
        "Network.framework",
        "Alamofire",
        "Moya",
    )
    for source_root in (ROOT / "App", ROOT / "Sources"):
        for source in source_root.rglob("*.swift"):
            text = source.read_text(encoding="utf-8")
            matches = [
                symbol for symbol in forbidden_runtime_symbols if symbol in text
            ]
            if matches:
                fail(
                    f"{source.relative_to(ROOT)} crosses the reviewed offline "
                    f"runtime boundary: {', '.join(matches)}"
                )
    print("Validated offline runtime boundary")


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

    accessed = manifest.get("NSPrivacyAccessedAPITypes")
    if not isinstance(accessed, list) or len(accessed) != 1:
        fail("privacy manifest must declare exactly the reviewed UserDefaults API")

    user_defaults = accessed[0]
    if (
        not isinstance(user_defaults, dict)
        or user_defaults.get("NSPrivacyAccessedAPIType")
        != "NSPrivacyAccessedAPICategoryUserDefaults"
    ):
        fail("privacy manifest must declare exactly the reviewed UserDefaults API")

    reasons = user_defaults.get("NSPrivacyAccessedAPITypeReasons")
    expected_reasons = {"CA92.1", "1C8F.1"}
    if (
        not isinstance(reasons, list)
        or not all(isinstance(reason, str) for reason in reasons)
        or len(reasons) != len(expected_reasons)
        or set(reasons) != expected_reasons
    ):
        fail(
            "privacy manifest must declare exactly UserDefaults reasons CA92.1 "
            "(app-only standard defaults) and 1C8F.1 (same-App-Group defaults)"
        )

    print("Validated PrivacyInfo.xcprivacy")


def validate_info_plist_localizations() -> None:
    expected = {
        "en": {
            "NSFaceIDUsageDescription": "Unlock your private MoneyUp financial data.",
            "UTTypeDescription": "MoneyUp Encrypted Backup",
        },
        "zh-Hans": {
            "NSFaceIDUsageDescription": "解锁你在 MoneyUp 中的私密财务数据。",
            "UTTypeDescription": "MoneyUp 加密备份",
        },
    }
    for language, declarations in expected.items():
        path = ROOT / "App" / "MoneyUp" / f"{language}.lproj" / "InfoPlist.strings"
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as error:
            fail(f"cannot read {path.relative_to(ROOT)}: {error}")
        for key, value in declarations.items():
            declaration = f'"{key}" = "{value}";'
            if declaration not in text:
                fail(f"{path.relative_to(ROOT)} must localize {key}")
    print("Validated bilingual Info.plist user-facing strings")


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
        # Filled actions intentionally stay forest green in both appearances.
        # The brighter dark-mode accent remains available for links and icons,
        # but is not safe behind the white foreground used by prominent controls.
        "BrandAction": ["#34785F", "#34785F"],
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

    def relative_luminance(color: str) -> float:
        components = [int(color[index:index + 2], 16) / 255 for index in (1, 3, 5)]
        linear = [
            value / 12.92
            if value <= 0.04045
            else ((value + 0.055) / 1.055) ** 2.4
            for value in components
        ]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

    def contrast(first: str, second: str) -> float:
        first_luminance = relative_luminance(first)
        second_luminance = relative_luminance(second)
        lighter = max(first_luminance, second_luminance)
        darker = min(first_luminance, second_luminance)
        return (lighter + 0.05) / (darker + 0.05)

    for action in expected["BrandAction"]:
        if contrast(action, "#FFFFFF") < 4.5:
            fail(f"BrandAction does not support a white control foreground: {action}")
    if contrast(expected["BrandAction"][1], expected["BrandBackground"][1]) < 3:
        fail("dark BrandAction is not distinguishable from BrandBackground")

    widget_source = (
        ROOT / "App" / "MoneyUpWidget" / "MoneyUpWidget.swift"
    ).read_text(encoding="utf-8")
    if "colors: [Color.moneyUpAction, Color.moneyUpActionDeep]" not in widget_source:
        fail("widget action gradient must keep every white-bearing stop contrast-safe")
    if contrast("#255C48", "#FFFFFF") < 4.5:
        fail("widget deep action stop does not support a white foreground")

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
    for path in (ROOT / "App" / "MoneyUp").glob("*.swift"):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if ".buttonStyle(.borderedProminent)" not in line:
                continue
            nearby = "\n".join(lines[index + 1:index + 5])
            if ".tint(.moneyUpAction)" not in nearby:
                fail(
                    f"{path.relative_to(ROOT)}:{index + 1} prominent action "
                    "must use the contrast-safe BrandAction token"
                )
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


def validate_release_fixture_generator() -> None:
    script = ROOT / "Scripts" / "generate_release_fixture.py"
    if not script.is_file():
        fail("release-scale fixture generator is missing")

    with tempfile.TemporaryDirectory(prefix="moneyup-release-fixture-") as directory:
        first = Path(directory) / "first.csv"
        second = Path(directory) / "second.csv"
        command = [
            sys.executable,
            str(script),
            "--entries",
            "10000",
            "--output",
        ]
        try:
            subprocess.run(
                [*command, str(first)],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [*command, str(second)],
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"cannot generate release-scale fixture: {error}")

        if first.read_bytes() != second.read_bytes():
            fail("release-scale fixture is not deterministic")
        if first.stat().st_size >= 10_000_000:
            fail("10,000-entry fixture exceeds the app's 10 MB import limit")

        with first.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            rows = list(reader)
        expected_headers = ["id", "date", "kind", "amount", "payee", "note"]
        if reader.fieldnames != expected_headers:
            fail(f"release fixture has unexpected headers: {reader.fieldnames}")
        if len(rows) != 10_000:
            fail(f"release fixture contains {len(rows)} rows instead of 10,000")
        if rows[0]["id"] != "moneyup-release-fixture-00001":
            fail("release fixture first identity drifted")
        if rows[-1]["id"] != "moneyup-release-fixture-10000":
            fail("release fixture last identity drifted")
        if len({row["id"] for row in rows}) != len(rows):
            fail("release fixture identities must be unique")
        if len({row["date"] for row in rows}) != len(rows):
            fail("release fixture timestamps must be unique")
        if any(row["kind"] != "expense" for row in rows):
            fail("release fixture must use the reviewed expense-only shape")
        if any(
            re.fullmatch(r"[1-9][0-9]*\.[0-9]{2}", row["amount"]) is None
            for row in rows
        ):
            fail("release fixture contains an invalid amount")

    runbook = (ROOT / "docs" / "FIRST_TEST.md").read_text(encoding="utf-8")
    for declaration in [
        "Scripts/generate_release_fixture.py",
        "10,000",
        "20 long-lived schedules",
        "Data inventory",
    ]:
        if declaration not in runbook:
            fail(f"first-test runbook is missing release-fixture step: {declaration}")
    print("Validated deterministic 10,000-entry release fixture and runbook")


def validate_project_configuration() -> None:
    path = ROOT / "project.yml"
    try:
        spec = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read project.yml: {error}")

    if "SWIFT_EMIT_LOC_STRINGS: YES" not in spec:
        fail("project.yml must enable compiler extraction of Swift strings")
    if "SWIFT_TREAT_WARNINGS_AS_ERRORS: YES" not in spec:
        fail("project.yml must treat app and widget warnings as errors")
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
    if package.count(".package(") != 1:
        fail("SQLCipher.swift must remain the only runtime package dependency")

    print("Validated matching app/widget versions and automatic signing")


def workflow_step(workflow: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      - name: {re.escape(name)}\n"
        r"(?P<body>.*?)(?=^      - name: |\Z)",
        workflow,
    )
    if match is None:
        fail(f"workflow is missing the {name!r} step")
    return match.group("body")


def validate_action_revisions(workflow: str, workflow_name: str) -> None:
    expected = {
        "actions/checkout": CHECKOUT_ACTION_REVISION,
        "actions/upload-artifact": UPLOAD_ARTIFACT_REVISION,
    }
    for action, revision in expected.items():
        references = re.findall(rf"{re.escape(action)}@([^\s#]+)", workflow)
        if action == "actions/upload-artifact" and not references:
            fail(f"{workflow_name} must retain test or release evidence")
        if action == "actions/checkout" and not references:
            fail(f"{workflow_name} must check out its source candidate")
        if any(reference != revision for reference in references):
            fail(
                f"{workflow_name} must pin every {action} use to reviewed "
                f"commit {revision}"
            )


def validate_ci_workflow() -> None:
    path = ROOT / ".github" / "workflows" / "ci.yml"
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read CI workflow: {error}")

    validate_action_revisions(workflow, "CI workflow")
    required = [
        f"XCODEGEN_VERSION: {XCODEGEN_VERSION}",
        f"XCODEGEN_SHA256: {XCODEGEN_SHA256}",
        f'CI_XCODE_VERSION: "{CI_XCODE_VERSION}"',
        f"CI_XCODE_BUILD: {CI_XCODE_BUILD}",
        (
            "CI_IPHONESIMULATOR_SDK_VERSION: "
            f'"{CI_IPHONESIMULATOR_SDK_VERSION}"'
        ),
        "runs-on: macos-15",
        "DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer",
        "Verify the exact CI Xcode toolchain",
        "Verify the exact CI Xcode and simulator SDK",
        "XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip",
        "shasum -a 256 -c -",
        "swift test --parallel --enable-code-coverage -Xswiftc -warnings-as-errors",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "-enableCodeCoverage YES",
        "-resultBundlePath \"$RESULT_BUNDLE\"",
        "core-tests.log",
        "core-persistence-coverage.json",
        "app-model-coverage.json",
        "${{ runner.temp }}/MoneyUpTests.xcresult",
        "if: ${{ always() }}",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"CI workflow is missing {declaration}")

    if workflow.count("runs-on: macos-15") != 2:
        fail("both Swift CI jobs must run on the reviewed macos-15 image")
    if workflow.count(
        "DEVELOPER_DIR: /Applications/Xcode_16.4.app/Contents/Developer"
    ) != 2:
        fail("both Swift CI jobs must select the reviewed Xcode 16.4 bundle")

    core_toolchain = workflow_step(workflow, "Verify the exact CI Xcode toolchain")
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '"$XCODE_VERSION_LINE" != "Xcode $CI_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $CI_XCODE_BUILD"',
    ]:
        if declaration not in core_toolchain:
            fail(f"CI core toolchain check is missing {declaration}")

    ios_toolchain = workflow_step(
        workflow, "Verify the exact CI Xcode and simulator SDK"
    )
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '"$XCODE_VERSION_LINE" != "Xcode $CI_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $CI_XCODE_BUILD"',
        '"$SDK_VERSION" != "$CI_IPHONESIMULATOR_SDK_VERSION"',
        "xcrun --sdk iphonesimulator --show-sdk-version",
    ]:
        if declaration not in ios_toolchain:
            fail(f"CI simulator toolchain check is missing {declaration}")

    for wildcard in [
        f"{CI_XCODE_VERSION}*",
        f"{CI_IPHONESIMULATOR_SDK_VERSION}*",
    ]:
        if wildcard in workflow:
            fail(f"CI toolchain checks must use exact equality, not {wildcard}")

    if workflow.count("Install checksum-verified XcodeGen") != 1:
        fail("CI must install checksum-verified XcodeGen exactly once")
    print(
        "Validated exact CI toolchain, immutable tools, warnings-as-errors, "
        "and test evidence"
    )


def validate_testflight_workflow() -> None:
    path = ROOT / ".github" / "workflows" / "testflight.yml"
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read TestFlight workflow: {error}")

    required = [
        "workflow_dispatch:",
        "expected_sha:",
        "Optional exact main commit required by an owner-command dispatch",
        "runs-on: macos-26",
        "environment: testflight",
        "cancel-in-progress: false",
        "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
        f'RELEASE_XCODE_VERSION: "{RELEASE_XCODE_VERSION}"',
        f"RELEASE_XCODE_BUILD: {RELEASE_XCODE_BUILD}",
        f'RELEASE_IPHONEOS_SDK_VERSION: "{RELEASE_IPHONEOS_SDK_VERSION}"',
        "toolchain_fingerprint: ${{ steps.release_toolchain.outputs.fingerprint }}",
        "PREFLIGHT_TOOLCHAIN_FINGERPRINT: "
        "${{ needs.preflight.outputs.toolchain_fingerprint }}",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        "method -string app-store-connect",
        "signingStyle -string automatic",
        "--validate-app",
        "--upload-app",
        "uploadSymbols -bool true",
        "Scripts/validate_built_bundle.py",
        "Seed and verify archive App Group entitlements",
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
        "IPA_SHA256",
        "IPA_RELATIVE_PATH",
        "RECOVERY_VERIFY_DIRECTORY",
        "MoneyUp-encrypted-release-recovery-",
        "MoneyUp-Release-Recovery-",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"TestFlight workflow is missing {declaration}")

    if workflow.count("runs-on: macos-26") != 2:
        fail("both TestFlight jobs must run on the reviewed macos-26 image")
    if workflow.count(
        "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer"
    ) != 1:
        fail("TestFlight must globally select the reviewed Xcode 26.6 bundle")
    if "needs: preflight" not in workflow:
        fail("the signing job must depend on its secretless preflight")

    authorization_body = workflow_step(
        workflow, "Require main and explicit upload confirmation"
    )
    for declaration in [
        '"$GITHUB_REF" != "refs/heads/main"',
        'EXPECTED_SHA: ${{ inputs.expected_sha }}',
        '! "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$',
        '"$GITHUB_SHA" != "$EXPECTED_SHA"',
        "Main moved after the owner command was authorized.",
        '"$OPERATION" == "upload"',
        '"$CONFIRMATION" != "UPLOAD"',
    ]:
        if declaration not in authorization_body:
            fail(f"TestFlight authorization step is missing {declaration}")

    release_toolchain = workflow_step(
        workflow, "Verify the exact Apple upload toolchain"
    )
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '${ImageOS:?GitHub runner ImageOS metadata is unavailable}',
        '${ImageVersion:?GitHub runner ImageVersion metadata is unavailable}',
        '"$XCODE_VERSION_LINE" != "Xcode $RELEASE_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $RELEASE_XCODE_BUILD"',
        '"$SDK_VERSION" != "$RELEASE_IPHONEOS_SDK_VERSION"',
        "xcrun --sdk iphoneos --show-sdk-version",
        "id: release_toolchain",
        "TOOLCHAIN_FINGERPRINT=",
        "|${ImageOS}|${ImageVersion}",
        'echo "fingerprint=$TOOLCHAIN_FINGERPRINT" >> "$GITHUB_OUTPUT"',
    ]:
        if declaration not in release_toolchain:
            fail(f"release preflight toolchain check is missing {declaration}")

    signing_toolchain = workflow_step(
        workflow, "Verify the preflighted Apple upload toolchain"
    )
    for declaration in [
        'test -x "$DEVELOPER_DIR/usr/bin/xcodebuild"',
        '${ImageOS:?GitHub runner ImageOS metadata is unavailable}',
        '${ImageVersion:?GitHub runner ImageVersion metadata is unavailable}',
        '"$XCODE_VERSION_LINE" != "Xcode $RELEASE_XCODE_VERSION"',
        '"$XCODE_BUILD_LINE" != "Build version $RELEASE_XCODE_BUILD"',
        '"$SDK_VERSION" != "$RELEASE_IPHONEOS_SDK_VERSION"',
        "xcrun --sdk iphoneos --show-sdk-version",
        "TOOLCHAIN_FINGERPRINT=",
        "|${ImageOS}|${ImageVersion}",
        '"$TOOLCHAIN_FINGERPRINT" != "$PREFLIGHT_TOOLCHAIN_FINGERPRINT"',
        'echo "RELEASE_TOOLCHAIN_FINGERPRINT=$TOOLCHAIN_FINGERPRINT" '
        '>> "$GITHUB_ENV"',
    ]:
        if declaration not in signing_toolchain:
            fail(f"release signing toolchain check is missing {declaration}")

    for weak_check in [
        f"{RELEASE_XCODE_VERSION}*",
        f"{RELEASE_IPHONEOS_SDK_VERSION}*",
        "ImageOS:-unknown",
        "ImageVersion:-unknown",
    ]:
        if weak_check in workflow:
            fail(f"release toolchain fingerprint must not use weak check {weak_check}")

    archive_body = workflow_step(workflow, "Create an unsigned release archive")
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

    entitlement_body = workflow_step(
        workflow, "Seed and verify archive App Group entitlements"
    )
    for declaration in [
        "App/MoneyUpWidget/MoneyUpWidget.entitlements",
        "App/MoneyUp/MoneyUp.entitlements",
        "codesign --force --sign -",
        "codesign --verify",
        "com.apple.security.application-groups",
    ]:
        if declaration not in entitlement_body:
            fail(f"archive entitlement seed step is missing {declaration}")

    debug_symbols_body = workflow_step(workflow, "Verify archive debug symbols")
    for declaration in [
        "MoneyUp.app.dSYM",
        "MoneyUpWidget.appex.dSYM",
        '"$ARCHIVE_PATH/dSYMs/$DSYM_NAME"',
    ]:
        if declaration not in debug_symbols_body:
            fail(f"archive debug-symbol check is missing {declaration}")

    export_body = workflow_step(workflow, "Export an App Store Connect IPA")
    for declaration in [
        "method -string app-store-connect",
        "destination -string export",
        "signingStyle -string automatic",
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        "-authenticationKeyID",
        "-authenticationKeyIssuerID",
        "expected exactly one exported IPA",
        "IPA_SHA256=",
        "IPA_RELATIVE_PATH=",
    ]:
        if declaration not in export_body:
            fail(f"App Store Connect export step is missing {declaration}")

    validation_body = workflow_step(workflow, "Ask Apple to validate the IPA")
    for declaration in ["--validate-app", '--file "$IPA_PATH"']:
        if declaration not in validation_body:
            fail(f"Apple validation step is missing {declaration}")

    recovery_name = "Encrypt and round-trip verify the exact release recovery bundle"
    recovery_body = workflow_step(workflow, recovery_name)
    for declaration in [
        '"$ARCHIVE_RELATIVE_PATH"',
        '"$EXPORT_RELATIVE_PATH"',
        (
            "${RELEASE_TOOLCHAIN_FINGERPRINT:?Verified release toolchain "
            "fingerprint is unavailable}"
        ),
        "tree_digest()",
        'digest.update(b"MoneyUp deterministic tree digest v1\\0")',
        "ordered = sorted(entries",
        "stat.S_IMODE",
        "stat.S_ISDIR",
        "stat.S_ISREG",
        "stat.S_ISLNK",
        "metadata.st_size",
        "os.readlink(path)",
        "while chunk := source.read(1024 * 1024)",
        'test -d "$ARCHIVE_PATH/dSYMs"',
        "DSYM_COUNT=",
        "if (( DSYM_COUNT < 1 ))",
        'ARCHIVE_TREE_SHA256="$(tree_digest "$ARCHIVE_PATH")"',
        'EXPORT_TREE_SHA256="$(tree_digest "$EXPORT_DIRECTORY")"',
        "Toolchain and runner image fingerprint: $RELEASE_TOOLCHAIN_FINGERPRINT",
        "IPA SHA-256: $IPA_SHA256",
        "Archive tree SHA-256: $ARCHIVE_TREE_SHA256",
        "Export tree SHA-256: $EXPORT_TREE_SHA256",
        "openssl enc -d -aes-256-cbc",
        'tar -C "$RECOVERY_VERIFY_DIRECTORY" -xzpf -',
        'RECOVERED_ARCHIVE_TREE_SHA256="$(tree_digest "$RECOVERED_ARCHIVE")"',
        'RECOVERED_EXPORT_TREE_SHA256="$(tree_digest "$RECOVERED_EXPORT")"',
        '"$RECOVERED_ARCHIVE_TREE_SHA256" != "$ARCHIVE_TREE_SHA256"',
        '"$RECOVERED_EXPORT_TREE_SHA256" != "$EXPORT_TREE_SHA256"',
        "RECOVERED_IPA_SHA256",
        'if ! cmp -s "$IPA_PATH" "$RECOVERED_IPA"',
        'grep -Fqx "IPA: $IPA_RELATIVE_PATH"',
        (
            'grep -Fqx "Toolchain and runner image fingerprint: '
            '$RELEASE_TOOLCHAIN_FINGERPRINT"'
        ),
        'grep -Fqx "Archive tree SHA-256: $ARCHIVE_TREE_SHA256"',
        'grep -Fqx "Export tree SHA-256: $EXPORT_TREE_SHA256"',
        "xcarchive tree (including dSYMs)",
        "export tree",
        "verified byte-for-byte",
    ]:
        if declaration not in recovery_body:
            fail(f"release recovery step is missing {declaration}")

    upload_only_condition = "if: ${{ inputs.operation == 'upload' }}"
    if upload_only_condition not in recovery_body:
        fail("release recovery creation must run only for an authorized upload")

    retention_name = "Retain the encrypted exact release recovery bundle"
    retention_body = workflow_step(workflow, retention_name)
    for declaration in [
        upload_only_condition,
        "actions/upload-artifact@",
        "MoneyUp-encrypted-release-recovery-",
        "if-no-files-found: error",
        "retention-days: 90",
    ]:
        if declaration not in retention_body:
            fail(f"release recovery retention step is missing {declaration}")

    upload_name = "Upload the exact validated IPA to TestFlight"
    upload_body = workflow_step(workflow, upload_name)
    for declaration in [
        upload_only_condition,
        "UPLOAD_IPA_SHA256",
        '"$UPLOAD_IPA_SHA256" != "$IPA_SHA256"',
        "--upload-app",
        '--file "$IPA_PATH"',
        '--apiKey "$ASC_KEY_ID"',
        '--apiIssuer "$ASC_ISSUER_ID"',
    ]:
        if declaration not in upload_body:
            fail(f"exact-IPA upload step is missing {declaration}")
    if "xcodebuild" in upload_body or "-exportArchive" in upload_body:
        fail("exact-IPA upload step must not rebuild or re-export the candidate")

    if workflow.count("-exportArchive") != 1:
        fail("TestFlight must export exactly one IPA and must not re-export for upload")
    for forbidden in [
        "destination -string upload",
        "UPLOAD_OPTIONS_PATH",
        "UPLOAD_DIRECTORY",
    ]:
        if forbidden in workflow:
            fail(f"TestFlight workflow must not create a second upload binary: {forbidden}")
    if workflow.count("--upload-app") != 1:
        fail("TestFlight must upload the validated IPA exactly once")

    key_step_position = workflow.find("- name: Materialize the App Store Connect key")
    entitlement_step_position = workflow.find(
        "- name: Seed and verify archive App Group entitlements"
    )
    export_step_position = workflow.find("- name: Export an App Store Connect IPA")
    if not entitlement_step_position < key_step_position < export_step_position:
        fail(
            "the App Store Connect key must be materialized after the archive "
            "entitlement checks and before export"
        )

    validation_step_position = workflow.find("- name: Ask Apple to validate the IPA")
    recovery_step_position = workflow.find(f"- name: {recovery_name}")
    retention_step_position = workflow.find(
        f"- name: {retention_name}"
    )
    upload_step_position = workflow.find(f"- name: {upload_name}")
    if not (
        export_step_position
        < validation_step_position
        < recovery_step_position
        < retention_step_position
        < upload_step_position
    ):
        fail(
            "TestFlight must validate one IPA, preserve its verified recovery "
            "bundle, and only then upload that same IPA"
        )

    validate_action_revisions(workflow, "TestFlight workflow")
    for declaration in [
        f"XCODEGEN_VERSION: {XCODEGEN_VERSION}",
        f"XCODEGEN_SHA256: {XCODEGEN_SHA256}",
        "XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip",
        "shasum -a 256 -c -",
    ]:
        if declaration not in workflow:
            fail(f"TestFlight workflow is missing immutable tool check {declaration}")

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


def validate_testflight_owner_command_workflow() -> None:
    path = ROOT / ".github" / "workflows" / "testflight-owner-command.yml"
    try:
        workflow = path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read TestFlight owner-command workflow: {error}")

    required = [
        "issue_comment:",
        "types: [created]",
        "actions: write",
        "contents: read",
        "cancel-in-progress: false",
        f"github.event.issue.number == {TESTFLIGHT_CONTROL_ISSUE}",
        "github.event.issue.pull_request == null",
        "github.actor == github.repository_owner",
        "github.event.comment.user.login == github.repository_owner",
        "github.event.comment.author_association == 'OWNER'",
        "github.event.comment.body == '/moneyup-testflight validate'",
        "github.event.comment.body == '/moneyup-testflight upload UPLOAD'",
        "runs-on: ubuntu-24.04",
        "timeout-minutes: 5",
        "GH_TOKEN: ${{ github.token }}",
    ]
    for declaration in required:
        if declaration not in workflow:
            fail(f"TestFlight owner-command workflow is missing {declaration}")

    for forbidden in [
        "pull_request_target:",
        "secrets.",
        "contents: write",
        "issues: write",
        "id-token: write",
        "actions/checkout@",
        "startsWith(",
        "contains(",
        "curl ",
        "wget ",
    ]:
        if forbidden in workflow:
            fail(
                "TestFlight owner-command workflow must not contain "
                f"{forbidden}"
            )

    resolve_body = workflow_step(
        workflow, "Resolve exact owner command and current main"
    )
    for declaration in [
        '"$GITHUB_ACTOR" != "$REPOSITORY_OWNER"',
        '"$COMMENT_AUTHOR" != "$REPOSITORY_OWNER"',
        '"$AUTHOR_ASSOCIATION" != "OWNER"',
        f'"$ISSUE_NUMBER" != "{TESTFLIGHT_CONTROL_ISSUE}"',
        'case "$COMMENT_BODY" in',
        '"/moneyup-testflight validate")',
        '"/moneyup-testflight upload UPLOAD")',
        "gh api --method GET",
        '"repos/$REPOSITORY/git/ref/heads/main"',
        "--jq '.object.sha'",
        '! "$MAIN_SHA" =~ ^[0-9a-f]{40}$',
        'echo "operation=$OPERATION" >> "$GITHUB_OUTPUT"',
        'echo "confirmation=$CONFIRMATION" >> "$GITHUB_OUTPUT"',
        'echo "expected_sha=$MAIN_SHA" >> "$GITHUB_OUTPUT"',
    ]:
        if declaration not in resolve_body:
            fail(f"owner-command resolution is missing {declaration}")

    dispatch_body = workflow_step(
        workflow, "Dispatch the pinned TestFlight workflow"
    )
    for declaration in [
        "workflow run testflight.yml",
        "--ref main",
        '--raw-field "operation=$OPERATION"',
        '--raw-field "expected_sha=$EXPECTED_SHA"',
        'if [[ "$OPERATION" == "upload" ]]',
        '--raw-field "confirmation=$CONFIRMATION"',
        'gh "${ARGS[@]}"',
    ]:
        if declaration not in dispatch_body:
            fail(f"owner-command dispatch is missing {declaration}")

    print("Validated owner-only, SHA-pinned TestFlight command workflow")


def main() -> None:
    validate_localizations()
    validate_offline_runtime_boundary()
    validate_privacy_manifest()
    validate_info_plist_localizations()
    validate_icons()
    validate_brand_palette()
    validate_public_documents()
    validate_release_fixture_generator()
    validate_project_configuration()
    validate_ci_workflow()
    validate_testflight_workflow()
    validate_testflight_owner_command_workflow()
    print("Release asset validation passed")


if __name__ == "__main__":
    main()
