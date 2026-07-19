# Theme: scifi-60s

1960s science-fiction illustration. The references: space-race era pulp
paperback covers, Chesley Bonestell spacescapes, NASA/mid-century educational
posters, Tintin *Explorers on the Moon*. Hand-drawn ink linework with flat
retro color — a *drawing*, not a render.

Read `art/README.md` first — sizes, orientation, and file names are defined
there. This theme may export at **2×** the README content sizes so the linework
stays clean under zoom (`SCALE.txt` = `2`): Earth 280 px diameter, moon 168,
ship ~48×32, ISS ~56×36. Background still fully transparent PNG.

## Style rules

- **Visible ink line.** Everything is contained by a confident dark line —
  warm near-black (`#2b2320`-ish), not pure black. Line weight varies: thicker
  on silhouettes, thinner for interior detail. Slightly imperfect/organic lines
  are good; sterile geometric strokes are not.
- **Flat color with limited shading.** 2–3 flat tones per surface, no smooth
  gradients. Shadows are hard-edged shapes, as if cut from paper.
- **Hatching and halftone as texture.** Shadow sides and planet terminators use
  hatching, stippling, or coarse halftone dots instead of gradient fills.
  Keep dot/line pitch coarse enough to survive 50% downscale.
- **Palette: mid-century print colors, slightly desaturated and warm.**
  Cream `#f2e8cf`, tomato red `#d95d39`, mustard `#e3b23c`, teal `#3a7d7b`,
  faded navy `#2e4057`, warm ink `#2b2320`. Whites are cream, never `#ffffff`.
  Stay inside roughly this family; it's what makes the theme read as "60s".
- **Same physical content as other themes** — Earth is Earth, the ship is the
  same ship — only drawn in this style. Light still comes from the upper left,
  rendered as a hard lit/shadow split rather than soft shading.

## Per-asset direction

- **earth.png** — round silhouette with a bold outline. Stylized continents in
  teal/mustard on navy oceans, a few simplified cloud shapes in cream. Shadow
  side (lower right) hatched or halftoned, not gradient. Like a globe on a
  vintage classroom poster.
- **moon.png** — cream/grey disc, craters drawn as inked circles with hard
  crescent shadows, some stippling for texture. Clearly a companion piece to
  Earth.
- **ship.png** — pointing right. Classic finned retro rocket: bullet body,
  three fins (two visible), porthole windows, maybe a red-and-cream banded
  paint job. Pure Tintin-rocket energy. No flame in this file.
- **iss.png** — the real ISS reinterpreted as a 60s artist's "space station of
  the future": truss, cylindrical modules with portholes, solar panels drawn
  as outlined mustard/navy rectangles. Inked outline like the ship.

## Quality bar

Each sprite should look like it was clipped out of a 1960s illustrated book:
consistent line weight logic, flat print-like color, hard shadows, warm
palette. If a sprite looks like modern flat-design vector art (uniform
hairlines, neon-clean colors, no texture), it misses the theme — add line
character and hatching. Check at 50% scale that hatching doesn't collapse
into grey mud; coarsen it if it does.
