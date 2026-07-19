# Art guide — space-slop

This folder is the working area for all game art. Read this file fully before
producing anything; it is the contract between the art and the game code.

**space-slop** is a tiny 2D top-down space game (Zig + raylib, desktop and
WebAssembly). A rocket flies between planets under Newtonian gravity. The camera
is top-down, rotatable ship, smooth zoom from 0.15× to 4.0×. Right now everything
is placeholder vector shapes drawn in code — your art replaces those.

## Folder layout

```
art/
  README.md            <- this file (specs, sizes, rules)
  themes/
    pixelart.md        <- style guide for the "pixelart" theme
    scifi-60s.md       <- style guide for the "scifi-60s" theme
  pixelart/            <- finished PNG exports for the pixelart theme
  scifi-60s/           <- finished PNG exports for the scifi-60s theme
  _wip/                <- scratch space, source files, experiments (never shipped)
```

Work however you like inside `_wip/`, but final deliverables are flat PNGs in
the theme folders. The game embeds assets from `resources/`; a human (or a later
task) copies an approved theme folder there — **never write into `resources/`
yourself.**

Every theme folder must contain the same file names so themes are hot-swappable:

```
earth.png   moon.png   ship.png   iss.png
```

Optional extras (same names across themes when present): `ship_thrust_0.png`,
`ship_thrust_1.png` (flame frames), `stars_tile.png` (seamless background tile).

## Asset list and sizes

World units map 1:1 to pixels at zoom 1.0. Sizes below are the *canvas* size,
and the canvas must be fully used — see the zero-padding rule under Technical
rules. The game positions and rotates everything around the image center.

| Asset | File | Canvas size | Notes |
|-------|------|-------------|-------|
| Earth | `earth.png` | 280 px diameter | Matches in-game radius 140. Blue/white living planet. |
| Moon | `moon.png` | 168 px diameter | Matches in-game radius 84. Grey, cratered, dead. |
| Starship | `ship.png` | ~40 px long, ~16 px tall | The player. Nose **points right** (see orientation). |
| ISS | `iss.png` | ~44 px wide, ~20 px tall | Small station orbiting Earth. Solar panels + modules, readable at this size. |

Ship and ISS sizes are approximate — trim the canvas to the actual drawing.
Planet sizes are exact and non-negotiable (see zero padding below).

Exports are at exactly these sizes for every theme; `art/<theme>/SCALE.txt`
records the export multiple of this table and must contain `1`. (Pixelart is
*drawn* at half size on a native pixel grid and exported nearest-neighbour
doubled — see its theme doc — but the shipped PNG is still 1×.)

## Technical rules

- **Format:** PNG, RGBA, transparent background. No JPEG, no baked backgrounds.
- **Zero padding — this breaks the game if violated.** The opaque content must
  touch all four canvas edges (alpha bounding box == full canvas). The game
  stretches the whole texture across the sprite's world-space size, so any
  transparent margin renders the object *smaller* than its physics size: a
  padded planet shows a disc smaller than its collision/gravity radius, and
  ships/stations shrink relative to everything else. For planets specifically:
  the disc diameter, the canvas dimension, and the in-game collision diameter
  are the same number. Trim before export, never pad "for safety".
- **Orientation:** "forward" is **+X (right)**. The game computes heading with
  `Vec2.fromAngle` and rotates the sprite; a ship drawn pointing up will fly
  sideways. Planets/ISS have no forward but should look correct unrotated.
- **Pivot:** visual center of mass at the canvas center. No off-center sprites.
- **Lighting:** pick one global light direction — **upper left** — and use it in
  every asset of a theme so the scene reads as one sun.
- **No baked effects that belong to the engine:** no motion blur, no engine
  flame in `ship.png` (flame is separate frames), no glow halos around planets,
  no drop shadows. The game composites those.
- **Background:** the game clears to near-black (`#0a0a14`-ish) with tiny star
  dots. Sprites must read against very dark blue. Avoid pure-black outlines
  disappearing into the background — keep silhouettes one step lighter or rimmed.
- **Zoom survival:** sprites are shown from 0.15× to 4.0×. Check every export at
  25% and 400% nearest-neighbor scale. Silhouette must stay recognizable at 25%.

## Themes

Two themes to start. Each has its own style doc in `themes/` — read it before
drawing that theme. The *content* (what the object is) must match across themes;
only the *rendering style* changes.

1. **pixelart** — crisp low-res pixel art, limited palette. See
   [themes/pixelart.md](themes/pixelart.md).
2. **scifi-60s** — 1960s sci-fi illustration: ink lines, retro-futurist pulp /
   space-race poster look. See [themes/scifi-60s.md](themes/scifi-60s.md).

## Workflow / definition of done

1. Read this file and the theme doc.
2. Draft in `_wip/`, iterate freely.
3. Export finals to `art/<theme>/` with the exact file names above.
4. Self-check each export:
   - transparent background, correct canvas size,
   - **zero padding: opaque pixels touch all four canvas edges,**
   - ship points right,
   - looks right on a `#0a0a14` background at 25% / 100% / 400%,
   - consistent light from upper left,
   - style matches the theme doc.
5. Add or update `art/<theme>/PREVIEW.md`: one line per asset noting any
   deviation from spec (or "to spec"). If you can, also render a contact sheet
   `art/<theme>/_wip_preview.png` showing all sprites on a dark background.

Do not modify anything outside `art/`. If a spec here seems wrong or
impossible for the style, note it in `PREVIEW.md` rather than silently
deviating.
