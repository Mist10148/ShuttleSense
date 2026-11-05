"""Regenerate the native and web icons with Python and Pillow."""

import re
from pathlib import Path

from PIL import Image, ImageDraw

APP = Path(__file__).resolve().parents[1]
GREEN = "#2E7D4F"
GOLD = "#FFEE58"
FEATHERS = (
    ((238, 483), (239, 273), (334, 295), (309, 510)),
    ((330, 520), (365, 299), (464, 325), (410, 555)),
    ((430, 563), (494, 334), (591, 373), (514, 600)),
    ((536, 606), (620, 387), (719, 447), (618, 645)),
)
CORK = ((275, 513), (608, 668), (541, 755), (434, 775), (325, 717), (277, 632))


def mark(size: int, *, background: str = "square", inset: float = 1.0) -> Image.Image:
    image = Image.new("RGBA", (1024, 1024))
    draw = ImageDraw.Draw(image)
    if background == "square":
        draw.rectangle((0, 0, 1023, 1023), fill=GREEN)
    elif background == "rounded":
        draw.rounded_rectangle((0, 0, 1023, 1023), radius=210, fill=GREEN)
    for path in FEATHERS:
        draw.polygon(
            [(512 + (x - 478) * inset, 512 + (y - 524) * inset) for x, y in path],
            fill="white",
        )
    draw.polygon(
        [(512 + (x - 478) * inset, 512 + (y - 524) * inset) for x, y in CORK], fill=GOLD
    )
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    web = APP / "web"
    mark(32, background="rounded", inset=1.2).save(web / "favicon.png")
    for size in (192, 512):
        mark(size, inset=1.2).convert("RGB").save(web / f"icons/Icon-{size}.png")
        mark(size).convert("RGB").save(web / f"icons/Icon-maskable-{size}.png")

    mark(256, background="rounded", inset=1.2).save(
        APP / "windows/runner/resources/app_icon.ico",
        sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)],
    )
    res = APP / "android/app/src/main/res"
    for density, size in {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }.items():
        mark(size, background="rounded", inset=1.2).save(
            res / f"mipmap-{density}/ic_launcher.png"
        )

    # A vector drawable keeps the launch mark sharp at every Android density.
    paths = []
    for color, points in [*(("#FFFFFF", path) for path in FEATHERS), (GOLD, CORK)]:
        coords = " ".join(f"{x + 34},{y - 12}" for x, y in points)
        paths.append(
            f'    <path android:fillColor="{color}" android:pathData="M{coords}Z" />'
        )
    (res / "drawable/launch_mark.xml").write_text(
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="128dp" android:height="128dp"\n'
        '    android:viewportWidth="1024" android:viewportHeight="1024">\n'
        + "\n".join(paths)
        + "\n</vector>\n",
        encoding="utf-8",
    )

    ios = APP / "ios/Runner/Assets.xcassets"
    for path in (ios / "AppIcon.appiconset").glob("Icon-App-*.png"):
        match = re.fullmatch(r"Icon-App-([\d.]+)x[\d.]+@(\d)x\.png", path.name)
        if match is None:
            raise ValueError(f"Unrecognized icon filename: {path.name}")
        size = round(float(match[1]) * int(match[2]))
        mark(size, inset=1.2).convert("RGB").save(path)
    for scale in (1, 2, 3):
        suffix = "" if scale == 1 else f"@{scale}x"
        mark(128 * scale, background="none").save(
            ios / f"LaunchImage.imageset/LaunchImage{suffix}.png"
        )


if __name__ == "__main__":
    main()
