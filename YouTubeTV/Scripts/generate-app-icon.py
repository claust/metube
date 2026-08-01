#!/usr/bin/env python3
"""Generate the tvOS app icon and top shelf artwork.

The mark is a rune monogram for *Fjernsyn*: ᚠ (U+16A0, fehu/fé, "f") beside
ᛋ (U+16CB, long-branch sól, "s"), painted the red ochre that runestone carvings were
filled with. Both are set from the real Unicode runes rather than redrawn by hand, so
the letterforms are the genuine article — Apple Symbols cuts its terminals at an angle,
which reads as chisel work.

Regenerate after changing the design:

    Scripts/generate-app-icon.py

tvOS wants the icon as a layered image stack — back, middle, front — which the system
separates in 3D when the icon is focused. Here the stone slab is the back, the chiselled
groove is the middle, and the red paint is the front, so focusing the icon lifts the
paint off the stone.
"""

import json
import pathlib
import shutil
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = pathlib.Path(__file__).resolve().parent.parent
CATALOG = REPO / "Sources" / "Resources" / "Assets.xcassets"
BRAND = CATALOG / "App Icon & Top Shelf Image.brandassets"

FONT = "/System/Library/Fonts/Apple Symbols.ttf"
FEHU, SOL = "ᚠ", "ᛋ"

PAINT = (214, 58, 47)
GROOVE = (8, 6, 5)
LIP = (141, 127, 112)

INK_HEIGHT = 0.66  # mark height as a fraction of the canvas
RUNE_GAP = 0.16  # space between the two runes, as a fraction of their height
SS = 2  # supersampling for the glyph masks, so the carved edges stay clean


# ---------------------------------------------------------------- the mark


def _glyph(char, size):
    """A tightly cropped alpha mask of one rune."""
    font = ImageFont.truetype(FONT, size)
    canvas = Image.new("L", (size * 3, size * 3), 0)
    ImageDraw.Draw(canvas).text((size, size), char, font=font, fill=255)
    return canvas.crop(canvas.getbbox())


def monogram_mask(w, h, ink_frac):
    """ᚠᛋ, centred in a w x h alpha mask."""
    target = h * ink_frac
    # Render once at a probe size to learn the font's ink-to-point-size ratio, then
    # re-render at the size that actually lands on `target`.
    probe = 200
    a, b = _glyph(FEHU, probe), _glyph(SOL, probe)
    size = max(1, round(probe * target / max(a.height, b.height)))
    a, b = _glyph(FEHU, size), _glyph(SOL, size)

    gap = round(target * RUNE_GAP)
    mask = Image.new("L", (w, h), 0)
    x = (w - (a.width + gap + b.width)) // 2
    for glyph in (a, b):
        mask.paste(glyph, (x, (h - glyph.height) // 2), glyph)
        x += glyph.width + gap
    return mask


def _grow(mask, radius):
    """Widen a mask by roughly `radius`, for the groove around each cut."""
    if radius < 0.5:
        return mask
    return mask.filter(ImageFilter.GaussianBlur(radius)).point(
        lambda v: 255 if v >= 90 else 0
    )


def _tint(mask, color, opacity=1.0):
    layer = Image.new("RGBA", mask.size, color + (0,))
    layer.putalpha(mask.point(lambda v: round(v * opacity)))
    return layer


# ---------------------------------------------------------------- the layers


def stone(w, h):
    """The slab: a vertical gradient, a soft sheen up top, and a little grain."""
    ramp = Image.new("RGB", (1, 256))
    px = ramp.load()
    stops = [(0.0, (57, 52, 47)), (0.55, (36, 31, 27)), (1.0, (18, 15, 13))]
    for y in range(256):
        t = y / 255
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                k = (t - t0) / (t1 - t0)
                px[0, y] = tuple(round(c0[i] + (c1[i] - c0[i]) * k) for i in range(3))
                break
    slab = ramp.resize((w, h), Image.BICUBIC)

    sheen = Image.radial_gradient("L").resize(
        (round(w * 1.5), round(h * 3.0)), Image.BICUBIC
    )
    sheen = Image.eval(sheen, lambda v: round((255 - v) * 0.35))
    canvas = Image.new("L", (w, h), 0)
    canvas.paste(sheen, ((w - sheen.width) // 2, round(h * 0.28) - sheen.height // 2))
    slab = Image.composite(Image.new("RGB", (w, h), (109, 96, 85)), slab, canvas)

    # Coarse grain, not per-pixel: single-pixel noise vanishes at TV viewing distance
    # and, being incompressible, bloats these PNGs by an order of magnitude.
    speck = max(1, round(min(w, h) / 90))
    grain = (
        Image.effect_noise((w // speck + 1, h // speck + 1), 24)
        .resize((w, h), Image.BICUBIC)
        .convert("RGB")
    )
    return Image.blend(slab, grain, 0.05)


def layers(w, h, ink_frac):
    """Back / middle / front, each a full-bleed image at w x h."""
    mask = monogram_mask(w * SS, h * SS, ink_frac)
    grown = _grow(mask, h * SS * 0.011)
    down = lambda m: m.resize((w, h), Image.LANCZOS)
    mask, grown = down(mask), down(grown)

    middle = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    middle.alpha_composite(_tint(grown, GROOVE, 0.85))
    # A lit lower lip, offset down, so the groove reads as depth rather than a shadow.
    middle.alpha_composite(_tint(grown, LIP, 0.30), (0, max(1, round(h * 0.009))))

    return {
        "back": stone(w, h).convert("RGBA"),
        "middle": middle,
        "front": _tint(mask, PAINT),
    }


def flat(w, h, ink_frac):
    """All three layers composited, for the unlayered top shelf art."""
    built = layers(w, h, ink_frac)
    out = built["back"].copy()
    out.alpha_composite(built["middle"])
    out.alpha_composite(built["front"])
    return out


# ---------------------------------------------------------------- catalogue

INFO = {"author": "xcode", "version": 1}


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2) + "\n")


def imagestack(name, w, h, scales, ink_frac=INK_HEIGHT):
    """A layered tvOS icon: Back/Middle/Front, each an imageset of PNGs."""
    stack = BRAND / f"{name}.imagestack"
    stack.mkdir(parents=True, exist_ok=True)
    write_json(
        stack / "Contents.json",
        {
            "layers": [
                {"filename": "Front.imagestacklayer"},
                {"filename": "Middle.imagestacklayer"},
                {"filename": "Back.imagestacklayer"},
            ],
            "info": INFO,
        },
    )

    built = {scale: layers(w * scale, h * scale, ink_frac) for scale in scales}
    for kind in ("back", "middle", "front"):
        layer = stack / f"{kind.capitalize()}.imagestacklayer"
        layer.mkdir(parents=True, exist_ok=True)
        write_json(layer / "Contents.json", {"info": INFO})

        content = layer / "Content.imageset"
        content.mkdir(parents=True, exist_ok=True)
        images = []
        for scale in scales:
            filename = f"{kind}{'' if scale == 1 else f'@{scale}x'}.png"
            built[scale][kind].save(content / filename)
            images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
        write_json(content / "Contents.json", {"images": images, "info": INFO})


def imageset(name, w, h, scales, ink_frac=INK_HEIGHT):
    """An unlayered tvOS image (top shelf)."""
    iset = BRAND / f"{name}.imageset"
    iset.mkdir(parents=True, exist_ok=True)
    stem = name.lower().replace(" ", "-")
    images = []
    for scale in scales:
        filename = f"{stem}{'' if scale == 1 else f'@{scale}x'}.png"
        flat(w * scale, h * scale, ink_frac).convert("RGB").save(iset / filename)
        images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
    write_json(iset / "Contents.json", {"images": images, "info": INFO})


def mark_imageset(name, w, h, scales, ink_frac=0.8):
    """The bare mark on transparency, for drawing the app's own name inside the app.

    Same monogram as the icon, minus the stone it is carved into: on a black screen the
    slab would read as a grey tile around the runes. Lives beside the brand assets rather
    than in them — it fills no tvOS role, it is just an image the app draws.
    """
    iset = CATALOG / f"{name}.imageset"
    iset.mkdir(parents=True, exist_ok=True)
    stem = name.lower().replace(" ", "-")
    images = []
    for scale in scales:
        filename = f"{stem}{'' if scale == 1 else f'@{scale}x'}.png"
        layers(w * scale, h * scale, ink_frac)["front"].save(iset / filename)
        images.append({"filename": filename, "idiom": "tv", "scale": f"{scale}x"})
    write_json(iset / "Contents.json", {"images": images, "info": INFO})


def main():
    if not pathlib.Path(FONT).exists():
        sys.exit(f"{FONT} not found — this script needs macOS's runic-capable system font")

    if BRAND.exists():
        shutil.rmtree(BRAND)
    BRAND.mkdir(parents=True)
    write_json(CATALOG / "Contents.json", {"info": INFO})

    # The App Store icon is 1280x768 and 1x only; the on-device icon is 400x240 @1x/@2x.
    imagestack("App Icon", 400, 240, scales=[1, 2])
    imagestack("App Icon - App Store", 1280, 768, scales=[1])

    # Top shelf art is much wider than the icon, so the mark is dialled back to keep it
    # from filling the whole band.
    imageset("Top Shelf Image", 1920, 720, scales=[1, 2], ink_frac=INK_HEIGHT * 0.62)
    imageset("Top Shelf Image Wide", 2320, 720, scales=[1, 2], ink_frac=INK_HEIGHT * 0.62)

    # Not a brand asset — the menu's header draws this itself.
    # Wider than it is tall, unlike the icon: with no stone around it the canvas is only
    # there to hold the monogram, and a square one crops the two runes at the sides.
    mark_imageset("App Mark", 260, 160, scales=[1, 2])

    write_json(
        BRAND / "Contents.json",
        {
            "assets": [
                {
                    "filename": "App Icon - App Store.imagestack",
                    "idiom": "tv",
                    "role": "primary-app-icon",
                    "size": "1280x768",
                },
                {
                    "filename": "App Icon.imagestack",
                    "idiom": "tv",
                    "role": "primary-app-icon",
                    "size": "400x240",
                },
                {
                    "filename": "Top Shelf Image Wide.imageset",
                    "idiom": "tv",
                    "role": "top-shelf-image-wide",
                    "size": "2320x720",
                },
                {
                    "filename": "Top Shelf Image.imageset",
                    "idiom": "tv",
                    "role": "top-shelf-image",
                    "size": "1920x720",
                },
            ],
            "info": INFO,
        },
    )
    print(f"wrote {BRAND.relative_to(REPO)}")


if __name__ == "__main__":
    main()
