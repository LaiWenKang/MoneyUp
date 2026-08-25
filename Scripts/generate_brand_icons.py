#!/usr/bin/env python3
"""Generate deterministic MoneyUp light, dark, and tinted App Store icons."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "App" / "MoneyUp" / "Assets.xcassets" / "AppIcon.appiconset"
WORK_SIZE = 2048
OUTPUT_SIZE = 1024


def add_glow(image: Image.Image, center: tuple[int, int], radius: int, color: str) -> None:
    glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    x, y = center
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)
    glow = glow.filter(ImageFilter.GaussianBlur(radius // 2))
    image.alpha_composite(glow)


def draw_growth_mark(image: Image.Image, color: str, shadow: str) -> None:
    shadow_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow_layer)
    bars = [
        (390, 1210, 610, 1550),
        (660, 980, 880, 1550),
        (930, 700, 1150, 1550),
    ]
    for box in bars:
        shadow_draw.rounded_rectangle(
            (box[0] + 22, box[1] + 28, box[2] + 22, box[3] + 28),
            radius=62,
            fill=shadow,
        )
    shadow_draw.line(
        [(1120, 875), (1515, 480)],
        fill=shadow,
        width=128,
        joint="curve",
    )
    shadow_draw.line(
        [(1255, 480), (1515, 480), (1515, 740)],
        fill=shadow,
        width=128,
        joint="curve",
    )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(32))
    image.alpha_composite(shadow_layer)

    draw = ImageDraw.Draw(image)
    for box in bars:
        draw.rounded_rectangle(box, radius=62, fill=color)
    draw.line(
        [(1120, 835), (1515, 440)],
        fill=color,
        width=116,
        joint="curve",
    )
    draw.line(
        [(1255, 440), (1515, 440), (1515, 700)],
        fill=color,
        width=116,
        joint="curve",
    )


def generate(
    filename: str,
    background: str,
    mark: str,
    glow: str,
    shadow: str,
) -> None:
    image = Image.new("RGBA", (WORK_SIZE, WORK_SIZE), background)
    add_glow(image, (1580, 320), 570, glow)
    add_glow(image, (300, 1750), 460, glow)
    draw_growth_mark(image, mark, shadow)
    result = image.convert("RGB").resize(
        (OUTPUT_SIZE, OUTPUT_SIZE),
        Image.Resampling.LANCZOS,
    )
    result.save(OUTPUT / filename, format="PNG", optimize=True)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    generate(
        "AppIcon.png",
        background="#F7F9F6",
        mark="#34785F",
        glow="#BFE3D2A8",
        shadow="#1F46383D",
    )
    generate(
        "AppIcon-Dark.png",
        background="#101512",
        mark="#82CEAE",
        glow="#315B4990",
        shadow="#00000070",
    )
    generate(
        "AppIcon-Tinted.png",
        background="#ECEFEC",
        mark="#313A35",
        glow="#C8CDC9A0",
        shadow="#11171338",
    )


if __name__ == "__main__":
    main()
