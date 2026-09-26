@tool
extends RefCounted

## The contrast maths from WCAG 2.1, written out rather than borrowed.
##
## Godot has Color.srgb_to_linear(), and it happens to use the same piecewise
## curve, but "happens to" is not a specification. WCAG defines the transfer
## function and the luminance weights exactly, and a checker that tells a
## buyer "this fails AA" has to be defending a number the buyer can look up.
## So the formula is here in full, and tests/run_tests.gd pins it against the
## values published in the guidelines (black on white is 21:1, and any colour
## against itself is 1:1).
##
## Everything in this file is a pure function of its arguments. No node, no
## theme, no tree. That is deliberate: it makes the part that is easy to get
## subtly wrong the part that is trivial to test.

## sRGB -> linear, per WCAG 2.1 "relative luminance".
static func to_linear(channel: float) -> float:
    var c := clampf(channel, 0.0, 1.0)
    if c <= 0.04045:
        return c / 12.92
    return pow((c + 0.055) / 1.055, 2.4)


## Relative luminance L, in 0..1. Alpha is ignored - composite first.
static func luminance(c: Color) -> float:
    return 0.2126 * to_linear(c.r) + 0.7152 * to_linear(c.g) + 0.0722 * to_linear(c.b)


## Contrast ratio between two opaque colours. Ranges 1.0 (identical) to 21.0
## (black against white). Order does not matter.
static func contrast(a: Color, b: Color) -> float:
    var la := luminance(a)
    var lb := luminance(b)
    var hi := maxf(la, lb)
    var lo := minf(la, lb)
    return (hi + 0.05) / (lo + 0.05)


## Lays a possibly transparent colour over an opaque one. Straight (not
## premultiplied) alpha, which is what Godot's Color holds.
##
## A translucent font colour is one of the ways a screen fails contrast while
## looking fine in the inspector: the swatch shows the colour the author
## picked, and the screen shows that colour diluted by whatever is behind it.
static func over(fg: Color, bg: Color) -> Color:
    var a := clampf(fg.a, 0.0, 1.0)
    if a >= 1.0:
        return Color(fg.r, fg.g, fg.b, 1.0)
    return Color(
        fg.r * a + bg.r * (1.0 - a),
        fg.g * a + bg.g * (1.0 - a),
        fg.b * a + bg.b * (1.0 - a),
        1.0)


## Composites a front-to-back stack over an opaque base. layers[0] is the
## front-most. Stops early once a layer is fully opaque, because nothing
## behind an opaque layer can affect the result.
static func flatten(layers: Array, base: Color) -> Color:
    var behind := Color(base.r, base.g, base.b, 1.0)
    # Walk back to front so each step is a simple "over".
    var stack: Array = []
    for l in layers:
        if not (l is Color):
            continue
        var c: Color = l
        stack.append(c)
        if c.a >= 1.0:
            break
    for i in range(stack.size() - 1, -1, -1):
        behind = over(stack[i], behind)
    return behind


## WCAG 2.1 calls text "large" at 18pt, or 14pt when bold. Godot sizes fonts
## in pixels, and the guidelines' own note converts 1pt to 1.333px, giving
## 24px and 18.66px. Bold is not reliably knowable from a Control (the weight
## lives in the font resource, and a variation may fake it), so a caller that
## cannot tell passes is_bold = false and gets the stricter threshold. Being
## strict here can only produce a finding the buyer then dismisses; being
## lax silently passes text that a player cannot read.
const LARGE_PX := 24.0
const LARGE_BOLD_PX := 18.66

static func is_large_text(px: float, is_bold: bool = false) -> bool:
    if is_bold:
        return px >= LARGE_BOLD_PX
    return px >= LARGE_PX


## The ratio this text has to reach. AA is the level almost every storefront,
## platform holder and public-sector buyer actually asks for.
const AA_NORMAL := 4.5
const AA_LARGE := 3.0
const AAA_NORMAL := 7.0
const AAA_LARGE := 4.5

static func required(px: float, is_bold: bool = false, level: String = "AA") -> float:
    var large := is_large_text(px, is_bold)
    if level == "AAA":
        return AAA_LARGE if large else AAA_NORMAL
    return AA_LARGE if large else AA_NORMAL


## Non-text contrast: WCAG 2.1 SC 1.4.11 asks 3:1 for the parts of a control
## that show you where it is and what state it is in - its border, its fill
## against the page. Used for focus rings and button outlines.
const NON_TEXT := 3.0


## Formats a ratio the way the guidelines write it, so a buyer can paste the
## number into a compliance sheet. Two decimals, always with the colon.
static func fmt(ratio: float) -> String:
    return "%.2f:1" % ratio
