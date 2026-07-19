# Theme: pixelart

Crisp, low-resolution pixel art. Think Kenney space packs, *Starbound*
miniatures, classic 16-bit shooters — but restrained and cohesive, not busy.

Read `art/README.md` first — sizes, orientation, and file names are defined
there. Draw at **half** the README canvas sizes on a native pixel grid
(Earth 140 px diameter, moon 84, ship ~20×8, ISS ~22×10), then export
**nearest-neighbour doubled** to the README sizes, so every art pixel becomes
a crisp 2×2 block (`SCALE.txt` = `1` — the shipped PNG is full size). The game
uses nearest-neighbor filtering, so the chunky-pixel look survives on screen.

## Hard rules

- **Native resolution only.** Draw at the half-size grid above; the only
  scaling ever applied is the final nearest-neighbour ×2 export. Never draw
  big and downscale — that produces mush, not pixel art.
- **Zero padding, disc fills the canvas.** Planet discs span the full canvas
  edge-to-edge (the canvas *is* the collision circle); ship/ISS canvases are
  trimmed to the drawing. See the README's zero-padding rule.
- **No anti-aliasing against transparency.** Sprite edges are hard. Internal
  anti-aliasing (hand-placed intermediate colors) is fine and encouraged on
  large shapes like Earth.
- **One shared palette for the whole theme, ≤ 32 colors.** Define it first,
  save it as `art/pixelart/palette.png` (a strip of swatches), and use only
  those colors in every sprite. Suggested base (tweak freely, then commit to it):
  - deep space blues/purples for shadows: `#1a1c2c #29366f`
  - Earth ocean `#3b5dc9 #41a6f6`, land `#38b764 #257179`, clouds/ice `#f4f4f4 #94b0c2`
  - moon greys `#566c86 #94b0c2 #333c57`
  - hull lights `#f4f4f4 #94b0c2`, accent orange/red `#ef7d57 #b13e53`, cockpit teal `#41a6f6`
- **Dithering:** allowed, sparingly — 2×2 checker for planet terminators and
  large gradients only. No noise dithering on tiny sprites (ship, ISS).
- **Outlines:** selective. Ship and ISS get a 1 px dark (not pure black)
  outline so they pop against space. Planets get no outline — shade the rim
  with a darker palette step instead.

## Per-asset direction

- **earth.png** — round silhouette (it's used as a collision circle). One or two
  recognizable continents, cloud swirls that don't hide the land completely,
  slightly darker terminator on the lower-right (light comes from upper left).
  No atmosphere glow ring — the engine may add one.
- **moon.png** — 3–5 craters of varied size, subtle maria patches, same light
  direction. Should read as clearly smaller and deader than Earth.
- **ship.png** — pointing right. Retro rocket or small fighter, strong
  silhouette: nose, body, two fins. 2–3 hull shades plus one accent color and
  a 1–2 px cockpit. No flame (separate `ship_thrust_*.png` frames if you make
  them: 2 frames, flame trailing left).
- **iss.png** — horizontal truss with 2×2 solar panel pairs and a couple of
  cylindrical modules. At ~28 px this is mostly silhouette work; panels read
  as dark blue rectangles with a 1 px highlight line.

## Quality bar

At 100% on the dark game background, each sprite should be identifiable in
under a second by someone who has never seen the game. At 400% it should look
like deliberate pixel art (clean lines, consistent palette), not upscaled
noise. Banding, pillow-shading, and stray off-palette pixels are rejects.
