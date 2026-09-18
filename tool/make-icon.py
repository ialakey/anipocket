"""AniPocket launcher icon.

The mark: a pocket with a play triangle cut clean out of it. One shape, one
hole — which is what keeps it legible at 48 px and lets the same geometry serve
the adaptive foreground, the themed monochrome layer and the legacy icon.
"""
import pathlib
import sys

from PIL import Image, ImageDraw

S = 4  # supersampling factor
N = 1024  # master canvas

TOP = (0x93, 0x72, 0xFF)
BOTTOM = (0x4F, 0x22, 0xD4)


def gradient(size: int) -> Image.Image:
    """Vertical brand gradient, very slightly warmer at the top left."""
    g = Image.new("RGB", (1, size))
    px = g.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    return g.resize((size, size), Image.BICUBIC)


def rounded_poly(draw: ImageDraw.ImageDraw, points, radius: int, fill):
    """Polygon with rounded corners: fill it, then trace it with a round join."""
    draw.polygon(points, fill=fill)
    # wrap past the first vertex so the closing corner gets a joint as well
    draw.line(list(points) + [points[0], points[1]], fill=fill, width=radius * 2,
              joint="curve")


def mark_mask(size: int) -> Image.Image:
    """The pocket-with-play-hole, as an alpha mask on a `size` canvas."""
    k = size / N
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)

    def r(*v):
        return [x * k for x in v]

    # Pocket body, drawn to the edges of its own box: softly rounded at the
    # bottom, tighter at the shoulders. Callers decide how big the box is.
    d.rounded_rectangle(r(0, 0, 1023, 966), radius=246 * k, fill=255)
    d.rounded_rectangle(r(0, 0, 1023, 560), radius=180 * k, fill=255)

    # the opening: a shallow ellipse bitten out of the top edge
    d.ellipse(r(-61, -150, 1085, 197), fill=0)

    # play triangle, knocked through
    rounded_poly(
        d,
        [(408 * k, 390 * k), (408 * k, 765 * k), (742 * k, 577 * k)],
        radius=int(42 * k),
        fill=0,
    )
    return m


def foreground(size: int) -> Image.Image:
    """White mark on transparency, sized for an adaptive foreground layer."""
    hi = size * S
    layer = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    # Adaptive layers are 108dp, but a launcher crops to the central 72dp and
    # masks *that*. So the mark is sized against the 72dp that actually shows:
    # 0.45 x 108dp = ~49dp, which fills about two thirds of the visible circle,
    # the same proportion the system icons use.
    inner = round(hi * 0.45)
    m = mark_mask(inner)
    full = Image.new("L", (hi, hi), 0)
    full.paste(m, ((hi - inner) // 2, (hi - m.height) // 2))
    layer.paste((255, 255, 255, 255), (0, 0), full)
    return layer.resize((size, size), Image.LANCZOS)


def monochrome(size: int) -> Image.Image:
    hi = size * S
    inner = round(hi * 0.45)
    m = mark_mask(inner)
    full = Image.new("L", (hi, hi), 0)
    full.paste(m, ((hi - inner) // 2, (hi - m.height) // 2))
    layer = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    layer.paste((0, 0, 0, 255), (0, 0), full)
    return layer.resize((size, size), Image.LANCZOS)


def background(size: int) -> Image.Image:
    return gradient(size * S).resize((size, size), Image.LANCZOS).convert("RGBA")


def legacy(size: int, shape: str = "squircle") -> Image.Image:
    """Self-contained icon for pre-adaptive launchers and for iOS."""
    hi = size * S
    art = gradient(hi).convert("RGBA")
    inner = round(hi * 0.58)
    m = mark_mask(inner)
    full = Image.new("L", (hi, hi), 0)
    full.paste(m, ((hi - inner) // 2, (hi - m.height) // 2))
    art.paste((255, 255, 255, 255), (0, 0), full)

    if shape == "square":
        return art.resize((size, size), Image.LANCZOS)

    mask = Image.new("L", (hi, hi), 0)
    d = ImageDraw.Draw(mask)
    if shape == "circle":
        d.ellipse((0, 0, hi - 1, hi - 1), fill=255)
    else:
        d.rounded_rectangle((0, 0, hi - 1, hi - 1), radius=int(hi * 0.2237), fill=255)
    art.putalpha(mask)
    return art.resize((size, size), Image.LANCZOS)


def adaptive_preview(size: int, shape: str = "circle") -> Image.Image:
    """What a launcher actually shows: central 72dp of 108dp, then masked."""
    layer = background(size)
    layer.alpha_composite(foreground(size))
    keep = round(size * 72 / 108)
    off = (size - keep) // 2
    visible = layer.crop((off, off, off + keep, off + keep))
    mask = Image.new("L", (keep, keep), 0)
    d = ImageDraw.Draw(mask)
    if shape == "circle":
        d.ellipse((0, 0, keep - 1, keep - 1), fill=255)
    else:
        d.rounded_rectangle((0, 0, keep - 1, keep - 1), radius=int(keep * 0.22), fill=255)
    visible.putalpha(mask)
    return visible


def _save(img: Image.Image, path: pathlib.Path, opaque: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if opaque:
        flat = Image.new("RGB", img.size, (0, 0, 0))
        flat.paste(img, (0, 0), img)
        img = flat
    img.save(path, "PNG", optimize=True)


# density bucket -> multiplier
DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

IOS_SIZES = [
    ("Icon-App-20x20@1x.png", 20), ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60), ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58), ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40), ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@3x.png", 120), ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180), ("Icon-App-76x76@1x.png", 76),
    ("Icon-App-76x76@2x.png", 152), ("Icon-App-83.5x83.5@2x.png", 167),
    ("Icon-App-1024x1024@1x.png", 1024),
]


def main() -> None:
    root = pathlib.Path(__file__).resolve().parent.parent
    res = root / "android/app/src/main/res"

    for bucket, scale in DENSITIES.items():
        mip = res / f"mipmap-{bucket}"
        _save(legacy(round(48 * scale)), mip / "ic_launcher.png")
        _save(legacy(round(48 * scale), "circle"), mip / "ic_launcher_round.png")
        # adaptive layers are 108dp regardless of the icon's nominal 48dp
        adaptive = round(108 * scale)
        _save(background(adaptive), mip / "ic_launcher_background.png")
        _save(foreground(adaptive), mip / "ic_launcher_foreground.png")
        _save(monochrome(adaptive), mip / "ic_launcher_monochrome.png")
        print(f"  android {bucket}")

    ios = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    if ios.is_dir():
        for name, size in IOS_SIZES:
            # iOS masks the corners itself and rejects alpha
            _save(legacy(size, "square"), ios / name, opaque=True)
        print(f"  ios ({len(IOS_SIZES)} sizes)")

    _save(legacy(512), root / "docs/icon.png")
    print("  docs/icon.png")


if __name__ == "__main__":
    main()
