#!/usr/bin/env python3
"""Build the static, credential-free Cloudflare Pages sign-in support site."""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import zipfile
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CALLBACK_PATH = "/auth/icloud/callback"

PAGE = '''<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex, nofollow">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>Return to MoneyUp</title>
<style>
:root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
body { margin: 0; background: #f5f8f6; color: #172d23; }
main { max-width: 32rem; margin: 14vh auto; padding: 2rem; }
.brand { color: #30795c; font-weight: 650; letter-spacing: .02em; }
h1 { font-size: clamp(2rem, 7vw, 3rem); line-height: 1.1; margin: 1.25rem 0; }
p { font-size: 1.1rem; line-height: 1.65; }
.note { margin-top: 2rem; color: #4e6559; font-size: .95rem; }
@media (prefers-color-scheme: dark) {
  body { background: #102019; color: #e7f1eb; }
  .brand { color: #90c7ab; } .note { color: #aec5b8; }
}
</style>
<main>
<div class="brand">MoneyUp</div>
<h1>Return to MoneyUp</h1>
<p>Continue in the app. If the iCloud connection did not finish, open MoneyUp and try connecting again.</p>
<p class="note">Apple handles your sign-in. This page has no login form and does not read or display sign-in information.</p>
<p lang="zh-Hans" class="note">请返回 MoneyUp 继续操作。如果 iCloud 连接尚未完成，请在应用中重新连接。此页面不会读取或显示登录信息。</p>
</main>
</html>
'''

HEADERS = '''/*
  Cache-Control: no-store
  Referrer-Policy: no-referrer
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  X-Robots-Tag: noindex, nofollow
  Permissions-Policy: camera=(), microphone=(), geolocation=()
  Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'

/.well-known/apple-app-site-association
  Content-Type: application/json
'''


def site_files(team_id: str, callback_path: str = DEFAULT_CALLBACK_PATH) -> dict[str, bytes]:
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("Use the ten-character Apple Developer team ID")
    decoded = unquote(callback_path)
    if (not callback_path.startswith("/") or callback_path.startswith("//")
            or callback_path == "/" or any(c in callback_path for c in "?#\\")
            or any(ord(c) < 32 for c in decoded)
            or any(segment in {".", ".."} for segment in decoded.split("/"))
            or "\\" in decoded):
        raise ValueError("Use a canonical absolute callback path")
    relative = PurePosixPath(callback_path.lstrip("/"))
    if any(part.startswith(".") or part in {"functions", "_worker.js", "_headers", "_redirects"}
           for part in relative.parts):
        raise ValueError("The callback cannot use a reserved hosting path")
    # Pages serves callback.html at the extensionless /callback URL with no
    # redirect. A directory/index.html instead changes the canonical URL.
    callback_file = (relative / "index.html").as_posix() if callback_path.endswith("/") else relative.as_posix()
    if not callback_file.endswith(".html"):
        callback_file += ".html"
    association = {"webcredentials": {"apps": [team_id + ".com.laiwenkang.MoneyUp"]}}
    return {
        "index.html": PAGE.encode(),
        "404.html": PAGE.replace("Return to MoneyUp</h1>", "Page not found</h1>").encode(),
        callback_file: PAGE.encode(),
        ".well-known/apple-app-site-association": (json.dumps(association) + "\n").encode(),
        "_headers": HEADERS.encode(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--callback-path", default=DEFAULT_CALLBACK_PATH)
    parser.add_argument("--output", type=Path, default=ROOT / "CloudKit/CallbackSite")
    parser.add_argument("--zip", type=Path, help="Also create a new zip containing only the five static files")
    args = parser.parse_args()
    try:
        files = site_files(args.team_id, args.callback_path)
        existing = {p.relative_to(args.output).as_posix() for p in args.output.rglob("*") if p.is_file()}
        if unexpected := existing - files.keys():
            raise ValueError("Output contains unexpected files: " + ", ".join(sorted(unexpected)))
        for relative, content in files.items():
            target = args.output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        if args.zip:
            args.zip.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(args.zip, "x", compression=zipfile.ZIP_DEFLATED) as archive:
                for relative, content in files.items():
                    archive.writestr(relative, content)
        print(f"Prepared {len(files)} static files in {args.output}; no credentials or backup data included.")
        return 0
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
