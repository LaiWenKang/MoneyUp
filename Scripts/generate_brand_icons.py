#!/usr/bin/env python3
"""Generate deterministic MoneyUp light, dark, and tinted App Store icons."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageColor, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "App" / "MoneyUp" / "Assets.xcassets" / "AppIcon.appiconset"
BRAND_MARK = (
    ROOT
    / "App"
    / "MoneyUp"
    / "Assets.xcassets"
    / "MoneyUpBrandMark.imageset"
    / "MoneyUpBrandMark@3x.png"
)
WORK_SIZE = 2048
OUTPUT_SIZE = 1024


def add_glow(image: Image.Image, center: tuple[int, int], radius: int, color: str) -> None:
    glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    x, y = center
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)
    glow = glow.filter(ImageFilter.GaussianBlur(radius // 2))
    image.alpha_composite(glow)


def masked_layer(mask: Image.Image, color: str) -> Image.Image:
    red, green, blue, alpha = ImageColor.getcolor(color, "RGBA")
    layer = Image.new("RGBA", mask.size, (red, green, blue, 0))
    if alpha != 255:
        mask = mask.point([value * alpha // 255 for value in range(256)])
    layer.putalpha(mask)
    return layer


def draw_brand_mark(image: Image.Image, color: str, shadow: str) -> None:
    """Render the shared horned-money emblem used inside the app too."""
    with Image.open(BRAND_MARK) as source:
        source_alpha = source.convert("RGBA").getchannel("A")
    bounds = source_alpha.getbbox()
    if bounds is None:
        raise ValueError(f"brand mark has no visible pixels: {BRAND_MARK}")

    cropped = source_alpha.crop(bounds)
    target_width = 1480
    target_height = round(target_width * cropped.height / cropped.width)
    resized = cropped.resize(
        (target_width, target_height),
        Image.Resampling.LANCZOS,
    )
    x = (WORK_SIZE - target_width) // 2
    y = (WORK_SIZE - target_height) // 2 + 20

    mark_mask = Image.new("L", image.size, 0)
    mark_mask.paste(resized, (x, y))

    shadow_mask = Image.new("L", image.size, 0)
    shadow_mask.paste(resized, (x + 18, y + 28))
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(26))
    image.alpha_composite(masked_layer(shadow_mask, shadow))
    image.alpha_composite(masked_layer(mark_mask, color))


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
    draw_brand_mark(image, mark, shadow)
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
