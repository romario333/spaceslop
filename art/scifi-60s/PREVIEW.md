earth.png — 280×280 vintage ink-and-print Earth, disc fills the canvas edge-to-edge, transparent.
moon.png — 168×168 inked crater moon, disc fills the canvas edge-to-edge, transparent.
ship.png — 40×15, trimmed to content, right-facing retro rocket, transparent, no baked thrust.
iss.png — 52×15, trimmed to content, outlined retro-futurist station, transparent.
mars.png — 243×247 vintage ink-and-print Mars, disc fills the canvas edge-to-edge, transparent.
venus.png — 235×243 vintage ink-and-print Venus, disc fills the canvas edge-to-edge, transparent.
mercury.png — 237×237 vintage ink-and-print Mercury, disc fills the canvas edge-to-edge, transparent.
sun.png — 241×245 vintage ink-and-print Sun, disc fills the canvas edge-to-edge, transparent.
jupiter.png — 241×245 vintage ink-and-print Jupiter, disc fills the canvas edge-to-edge, transparent.
saturn.png — 279×92 vintage ink-and-print Saturn with rings spanning the canvas; the canvas width is the ring span, so the planet disc is deliberately smaller than the physics radius.
uranus.png — 258×258 vintage ink-and-print Uranus, disc fills the canvas edge-to-edge, transparent.
neptune.png — 241×243 vintage ink-and-print Neptune, disc fills the canvas edge-to-edge, transparent.
phobos.png — 130×130 ink-and-print cratered Mars moon, disc fills the canvas, transparent.
deimos.png — 115×79 ink-and-print cratered Mars moon, lumpy silhouette fills the canvas, transparent.
io.png — 151×153 ink-and-print volcanic Jupiter moon, disc fills the canvas, transparent.
europa.png — 141×146 ink-and-print ice-cracked Jupiter moon, disc fills the canvas, transparent.
ganymede.png — 145×149 ink-and-print grooved Jupiter moon, disc fills the canvas, transparent.
callisto.png — 142×143 ink-and-print dark cratered Jupiter moon, disc fills the canvas, transparent.

Note: every planet/moon canvas was cropped to its alpha bounding box, so opaque
pixels touch all four edges and `spriteScale` (which maps canvas *width* onto the
physics diameter) draws each body at its true collision size. Canvases are no
longer the round 280/168 numbers in `art/README.md`'s size table — the
zero-padding rule wins over the nominal canvas size.
