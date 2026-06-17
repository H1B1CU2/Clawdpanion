#!/usr/bin/env python3
"""Generate Claw'd pixel-art menubar frames (idle + typing animation)."""
from PIL import Image
import os, sys

RES = sys.argv[1]
ORANGE = (216, 119, 89, 255)
EYE = (28, 27, 25, 255)
CLEAR = (0, 0, 0, 0)

# Canonical Claw'd on a 12-wide grid. We draw the body into a canvas that is
# GRID_H+1 rows tall so a 1px vertical "bob" has room. Body parts are defined
# relative to a top offset `top` (in grid cells).
GRID_W = 12
GRID_H = 8
BODY_H = GRID_H + 1    # body grid incl. 1 extra row for bob headroom

# Transparent margin (in cells) around the body so Claw'd isn't edge-to-edge in
# the menubar. The full canvas is body + padding on every side.
PADX = 2
PADY = 1
CANVAS_W = GRID_W + 2 * PADX   # 16
CANVAS_H = BODY_H + 2 * PADY    # 11

HEAD_L, HEAD_R = 2, 9          # head/body columns (inclusive) -> 8 wide
EYE_COLS = (3, 8)              # left/right eye columns
LEG_COLS = (2, 4, 7, 9)       # four legs


BODY_MONO = (40, 40, 40, 255)  # template mode ignores RGB; only alpha matters


def draw_claw(scale, top, legs, eyes="open", mono=False, arms="flat", wave=0):
    """Return an RGBA image. `legs` is a dict col->0(down)|1(up). `top` is the
    body's top grid-row (0 = bobbed up, 1 = resting). `eyes` selects the eye
    style: "open" (filled), "closed" (a blink slit), or "happy" (a scrunched
    ">" "<" squint, used while celebrating).
    `mono`: body is a single opaque color and eyes are transparent HOLES, so the
    image works as a macOS template (monochrome, auto-adapting) icon."""
    W = CANVAS_W * scale
    H = CANVAS_H * scale
    img = Image.new("RGBA", (W, H), CLEAR)
    px = img.load()
    body = BODY_MONO if mono else ORANGE
    eye = CLEAR if mono else EYE

    def cell(cx, cy, color):
        x0, y0 = (cx + PADX) * scale, (cy + PADY) * scale
        for yy in range(y0, y0 + scale):
            for xx in range(x0, x0 + scale):
                if 0 <= xx < W and 0 <= yy < H:
                    px[xx, yy] = color

    r0 = top                       # head top row
    # row layout relative to top
    row_headtop = r0 + 0
    row_eyes    = r0 + 1
    row_arms_a  = r0 + 2
    row_arms_b  = r0 + 3
    row_body_a  = r0 + 4
    row_body_b  = r0 + 5
    row_legs_a  = r0 + 6
    row_legs_b  = r0 + 7

    # Solid torso: the whole head-width block from head-top down through the
    # lower body (cols 2..9, every row). Filling the arm rows here too keeps the
    # body from ever splitting when arms are raised.
    for c in range(HEAD_L, HEAD_R + 1):
        cell(c, row_headtop, body)
        cell(c, row_eyes, body)
        cell(c, row_arms_a, body)
        cell(c, row_arms_b, body)
        cell(c, row_body_a, body)
        cell(c, row_body_b, body)

    def raise_arm(side_col):
        hr = (top - 2) + wave                       # hand row (in the top padding)
        cell(side_col, row_arms_a, body)            # shoulder join
        for r in range(hr, row_arms_b + 1):         # forearm + hand: straight UP,
            cell(side_col, r, body)                 # no sideways jut — hand points up

    def flat_arm(cols):
        for c in cols:
            cell(c, row_arms_a, body)
            cell(c, row_arms_b, body)

    # arms: "two" = both up, "one" = right up + left out, else both out (normal)
    if arms == "two":
        raise_arm(HEAD_L - 1)
        raise_arm(HEAD_R + 1)
    elif arms == "one":
        flat_arm((0, 1))
        raise_arm(HEAD_R + 1)
    else:
        for c in range(0, GRID_W):
            cell(c, row_arms_a, body)
            cell(c, row_arms_b, body)
    # eyes (dark pixels in color mode, transparent holes in mono mode)
    if eyes == "closed":
        # closed eyes: a thin slit on the lower half of the eye cell
        for ec in EYE_COLS:
            x0 = (ec + PADX) * scale
            ey0 = (row_eyes + PADY) * scale
            yslit = ey0 + max(1, scale - max(1, scale // 3))
            for xx in range(x0, x0 + scale):
                for yy in range(yslit, ey0 + scale):
                    px[xx, yy] = eye
    elif eyes == "happy":
        # scrunched ">" / "<" squint for celebrating — a bold 3-wide x 5-tall
        # chevron per eye, built from `u`-sized sub-pixels and centred on the
        # eye cell so it scales with the canvas.
        u = max(1, scale // 2)
        gw, gh = 3, 5                        # chevron sub-grid size
        chevrons = {
            # ">" — vertex on the right (points inward toward the nose)
            EYE_COLS[0]: [(0, 0), (1, 1), (2, 2), (1, 3), (0, 4)],
            # "<" — vertex on the left (points inward toward the nose)
            EYE_COLS[1]: [(2, 0), (1, 1), (0, 2), (1, 3), (2, 4)],
        }
        for ec, sub in chevrons.items():
            ox = (ec + PADX) * scale + scale // 2 - (gw * u) // 2
            oy = (row_eyes + PADY) * scale + scale // 2 - (gh * u) // 2
            for sc, sr in sub:
                for yy in range(oy + sr * u, oy + sr * u + u):
                    for xx in range(ox + sc * u, ox + sc * u + u):
                        if 0 <= xx < W and 0 <= yy < H:
                            px[xx, yy] = eye
    else:
        for ec in EYE_COLS:
            cell(ec, row_eyes, eye)
    # legs: each leg is 2 cells tall (rows legs_a, legs_b). "up" legs drop the
    # bottom cell so the foot lifts.
    for lc in LEG_COLS:
        up = legs.get(lc, 0)
        cell(lc, row_legs_a, body)
        if not up:
            cell(lc, row_legs_b, body)
    return img


def save(img, name):
    # @1x = scale1 canvas; @2x rendered at double scale
    img.save(os.path.join(RES, name))


def render(name, top, legs, blink=False, eyes=None, arms="flat", wave=0):
    # `eyes` wins if given; otherwise fall back to the blink bool for callers
    # that only toggle open/closed.
    if eyes is None:
        eyes = "closed" if blink else "open"
    # color set (full orange) + mono set (template-ready: solid shape, eye holes)
    for mono, prefix in ((False, ""), (True, "mono_")):
        draw_claw(2, top, legs, eyes, mono, arms, wave).save(os.path.join(RES, f"{prefix}{name}.png"))
        draw_claw(4, top, legs, eyes, mono, arms, wave).save(os.path.join(RES, f"{prefix}{name}@2x.png"))


# Idle: resting, all legs down, eyes open. A matching eyes-closed frame is shown
# briefly every few seconds so Claw'd blinks while sitting idle.
render("idle", top=1, legs={}, blink=False)
render("idle_blink", top=1, legs={}, blink=True)

# Typing loop: alternate inner/outer legs tapping + 1px bob, with an occasional
# blink. Legs: outer = cols 2,9 ; inner = cols 4,7
OUT = {2: 1, 9: 1}
INN = {4: 1, 7: 1}
frames = [
    (1, OUT, False),   # outer feet up, resting
    (0, {}, False),    # all down, bobbed up
    (1, INN, False),   # inner feet up, resting
    (0, {}, True),     # all down, bobbed up, blink
    (1, OUT, False),
    (0, {}, False),
    (1, INN, False),
    (1, {}, False),
]
for i, (top, legs, blink) in enumerate(frames):
    render(f"type_{i}", top=top, legs=legs, blink=blink)

# Attention: ONE hand up, waving to get noticed (held while a session waits).
att = [
    (False, 0),   # hand high
    (False, 1),   # hand dips (wave)
    (True, 0),    # hand high, blink
    (False, 1),
]
for i, (blink, wave) in enumerate(att):
    render(f"att_{i}", top=1, legs={}, blink=blink, arms="one", wave=wave)

# Done: BOTH hands up, little celebratory bounce (shown briefly after a turn).
# Eyes are scrunched into a happy ">" "<" squint throughout the celebration.
done = [
    (1, 0),   # resting, hands high
    (0, 1),   # bob up, hands dip
    (1, 0),   # resting, hands high
    (0, 1),
]
for i, (top, wave) in enumerate(done):
    render(f"done_{i}", top=top, legs={}, eyes="happy", arms="two", wave=wave)

print(f"wrote idle + idle_blink + {len(frames)} typing + {len(att)} attention + {len(done)} done frames to {RES}")
