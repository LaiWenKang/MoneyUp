#!/usr/bin/env python3
"""Validate release-critical contents of a built MoneyUp app bundle."""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path
from typing import NoReturn


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_plist(path: Path) -> dict[str, object]:
    try:
        with path.open("rb") as file:
            payload = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot read {path}: {error}")
    if not isinstance(payload, dict):
        fail(f"{path} is not a property-list dictionary")
    return payload


def require_value(
    payload: dict[str, object], key: str, expected: str, owner: str
) -> None:
    actual = payload.get(key)
    if actual != expected:
        fail(f"{owner} {key} is {actual!r}; expected {expected!r}")


def require_localizations(bundle: Path, owner: str) -> None:
    for language in ("en", "zh-Hans"):
        directory = bundle / f"{language}.lproj"
        if not directory.is_dir():
            fail(f"{owner} is missing compiled {language} localization")
        strings = directory / "Localizable.strings"
        if not strings.is_file():
            fail(f"{owner} is missing {language} Localizable.strings")


def require_bundle_metadata(
    bundle: Path,
    payload: dict[str, object],
    owner: str,
    package_type: str,
) -> None:
    require_value(payload, "CFBundlePackageType", package_type, owner)
    require_value(payload, "MinimumOSVersion", "18.0", owner)
    executable = payload.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable:
        fail(f"{owner} has no CFBundleExecutable")
    if not (bundle / executable).is_file():
        fail(f"{owner} executable is missing: {executable}")


def validate(args: argparse.Namespace) -> None:
    app = args.app.resolve()
    if not app.is_dir():
        fail(f"app bundle does not exist: {app}")

    widget = app / "PlugIns" / "MoneyUpWidget.appex"
    if not widget.is_dir():
        fail("MoneyUpWidget.appex is missing from the containing app")

    app_info = read_plist(app / "Info.plist")
    widget_info = read_plist(widget / "Info.plist")

    require_bundle_metadata(app, app_info, "app", "APPL")
    require_bundle_metadata(widget, widget_info, "widget", "XPC!")

    require_value(app_info, "CFBundleIdentifier", args.app_bundle_id, "app")
    require_value(
        widget_info,
        "CFBundleIdentifier",
        args.widget_bundle_id,
        "widget",
    )

    extension = widget_info.get("NSExtension")
    if not isinstance(extension, dict) or extension.get(
        "NSExtensionPointIdentifier"
    ) != "com.apple.widgetkit-extension":
        fail("widget has an invalid NSExtensionPointIdentifier")

    url_types = app_info.get("CFBundleURLTypes")
    if not isinstance(url_types, list) or not any(
        isinstance(item, dict)
        and isinstance(item.get("CFBundleURLSchemes"), list)
        and "moneyup" in item["CFBundleURLSchemes"]
        for item in url_types
    ):
        fail("app is missing the moneyup URL scheme")

    for key, expected in (
        ("CFBundleShortVersionString", args.marketing_version),
        ("CFBundleVersion", args.build_number),
    ):
        require_value(app_info, key, expected, "app")
        require_value(widget_info, key, expected, "widget")

    if not (app / "PrivacyInfo.xcprivacy").is_file():
        fail("PrivacyInfo.xcprivacy is missing from the built app")

    require_localizations(app, "app")
    require_localizations(widget, "widget")
    for language in ("en", "zh-Hans"):
        if not (app / f"{language}.lproj" / "InfoPlist.strings").is_file():
            fail(f"app is missing compiled {language} InfoPlist.strings")

    print(
        "Validated MoneyUp "
        f"{args.marketing_version} ({args.build_number}), embedded widget, "
        "privacy manifest, and bilingual resources"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--marketing-version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--app-bundle-id", required=True)
    parser.add_argument("--widget-bundle-id", required=True)
    return parser.parse_args()


if __name__ == "__main__":
    validate(parse_args())
