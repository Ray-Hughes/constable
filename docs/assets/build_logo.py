"""Rebuild the Constable logo assets from the source artwork.

Three jobs: drop the old tagline, lift the mark off its white background so it
sits on any README theme, and set a new tagline in a face that matches the
wordmark.
"""
from PIL import Image, ImageDraw, ImageFont
import numpy as np

SRC = "/Users/raymondhughes/.claude/image-cache/a545de2b-fa4f-4aa9-9c0c-0dc1aa167827/1.jpeg"
CRIMSON = (154, 19, 49)
CHARCOAL = (54, 54, 54)
AVENIR = "/System/Library/Fonts/Avenir Next.ttc"
DEMI, MEDIUM = 2, 5

# Rows measured off the source: mark 93-511, wordmark 534-617, old tagline 642-674.
MARK = (93, 512)
WORDMARK = (534, 618)


def unmatte(rgb):
    """White background -> alpha, keeping the two flat brand colours flat.

    The artwork is two solid colours antialiased against white, so rather than
    guessing a global key we classify each pixel by hue and recover its coverage
    from the green channel, which has the most contrast against white for both.
    Edges keep their gradient; the fills come back exactly on-brand.
    """
    a = np.asarray(rgb).astype(float)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]

    is_red = (r - g) > 25
    fg_g = np.where(is_red, CRIMSON[1], CHARCOAL[1])
    alpha = np.clip((255.0 - g) / (255.0 - fg_g), 0.0, 1.0)

    out = np.zeros(a.shape[:2] + (4,), dtype=np.uint8)
    for i in range(3):
        out[..., i] = np.where(is_red, CRIMSON[i], CHARCOAL[i])
    # The source is a JPEG, so the "white" is not quite white: ringing around the
    # mark leaves a faint haze across the whole frame, which is enough to defeat
    # getbbox and to show up as grey fog on a dark README. Anything under ~4%
    # coverage is compression noise, not artwork.
    alpha = np.where(alpha < 0.04, 0.0, alpha)
    out[..., 3] = (alpha * 255).round().astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def trim(img):
    bbox = img.getchannel("A").getbbox()
    return img.crop(bbox)


def tracked_text(draw, xy, text, font, fill, tracking):
    """PIL has no letter-spacing. The original tagline is generously tracked, and
    without it the line reads as a different logo, so draw it a glyph at a time."""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += draw.textlength(ch, font=font) + tracking
    return x - tracking


def tracked_width(draw, text, font, tracking):
    return sum(draw.textlength(c, font=font) for c in text) + tracking * (len(text) - 1)


def recolor(img, frm, to):
    """Swap one flat brand colour for another, keeping the alpha channel intact.

    The charcoal that reads as authoritative on white is nearly invisible on
    GitHub's dark theme, and that is where most people will see it.
    """
    a = np.asarray(img).astype(int)
    near = (np.abs(a[..., :3] - np.array(frm)).sum(axis=2) < 90) & (a[..., 3] > 0)
    out = a.copy()
    for i in range(3):
        out[..., i] = np.where(near, to[i], a[..., i])
    return Image.fromarray(out.astype(np.uint8), "RGBA")


def build(tagline, out_path, square_path, charcoal=CHARCOAL):
    source = Image.open(SRC).convert("RGB")
    art = unmatte(source)
    if charcoal != CHARCOAL:
        art = recolor(art, CHARCOAL, charcoal)

    mark = trim(art.crop((0, MARK[0], art.width, MARK[1])))
    word = trim(art.crop((0, WORDMARK[0], art.width, WORDMARK[1])))
    wordmark_colour = charcoal

    # Lay out on a transparent canvas: mark, wordmark, tagline, centred.
    pad = 48
    gap_mark, gap_tag = 34, 26
    tag_size = 33
    font = ImageFont.truetype(AVENIR, tag_size, index=DEMI)

    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    tracking = 5.2
    tag_w = tracked_width(probe, tagline, font, tracking)
    ascent, descent = font.getmetrics()
    tag_h = ascent + descent

    width = int(max(mark.width, word.width, tag_w) + pad * 2)
    height = int(pad + mark.height + gap_mark + word.height + gap_tag + tag_h + pad)
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))

    y = pad
    canvas.alpha_composite(mark, ((width - mark.width) // 2, y))
    y += mark.height + gap_mark
    canvas.alpha_composite(word, ((width - word.width) // 2, y))
    y += word.height + gap_tag

    draw = ImageDraw.Draw(canvas)
    tracked_text(draw, ((width - tag_w) / 2, y), tagline, font, CRIMSON, tracking)

    # Deliberately not trimmed: the padding is the layout. A logo flush against its
    # own bounding box has nowhere to breathe next to a heading.
    canvas.save(out_path)

    # Square mark, for a favicon or an avatar where the wordmark would be unreadable.
    side = int(max(mark.width, mark.height) * 1.18)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.alpha_composite(mark, ((side - mark.width) // 2, (side - mark.height) // 2))
    sq.save(square_path)

    return Image.open(out_path).size, sq.size


if __name__ == "__main__":
    import sys

    tagline = sys.argv[1]
    print("light:", build(tagline, "docs/assets/logo.png", "docs/assets/logo-square.png"))
    print("dark: ", build(tagline, "docs/assets/logo-dark.png",
                          "docs/assets/logo-square-dark.png", charcoal=(214, 221, 226)))
