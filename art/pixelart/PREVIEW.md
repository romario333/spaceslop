earth.png — 539×551 native-detail Earth, transparent, upper-left lighting.
moon.png — 325×334 native-detail Moon, transparent, upper-left lighting.
ship.png — regenerated native-detail 128×80 canvas, right-facing, transparent, no baked thrust.
iss.png — regenerated native-detail 128×80 canvas, centered horizontal station, transparent.
palette.png — 16-color shared theme palette.
mars.png — 460×478 native-detail rusty cratered Mars, transparent, upper-left lighting.
venus.png — 458×471 native-detail cloud-covered Venus, transparent, upper-left lighting.
mercury.png — 488×490 native-detail cratered Mercury, transparent, upper-left lighting.
sun.png — 441×466 native-detail textured solar disc, transparent, upper-left lighting.
jupiter.png — 456×466 native-detail banded Jupiter with Great Red Spot, transparent.
saturn.png — 560×172 native-detail Saturn with edge-to-edge horizontal rings; the canvas width is the ring span, so the planet disc is deliberately smaller than the physics radius.
uranus.png — 464×478 native-detail pale cyan Uranus, transparent.
neptune.png — 476×483 native-detail deep blue Neptune with storm bands, transparent.
phobos.png — 257×235 irregular cratered Mars moon, transparent.
deimos.png — 240×222 small cratered Mars moon, transparent.
io.png — 285×295 sulfur-yellow volcanic Jupiter moon, transparent.
europa.png — 271×276 ice-cracked Jupiter moon, transparent.
ganymede.png — 278×284 grooved Jupiter moon, transparent.
callisto.png — 300×306 dark cratered Jupiter moon, transparent.

Note: this is a genuinely regenerated pack, not an upscaled version of the
earlier sprites. It is drawn at 2× world size (`SCALE.txt` = `2`, overriding the
theme default of 1) and is smooth illustration rather than chunky pixels, so the
game renders it with bilinear filtering.

Every planet/moon canvas is cropped to its alpha bounding box, so opaque pixels
touch all four edges and `spriteScale` (which maps canvas *width* onto the
physics diameter) draws each body at its true collision size. Canvases are
therefore no longer the round 560/336 numbers in `art/README.md`'s size table —
the zero-padding rule wins over the nominal canvas size. `ship.png` and
`iss.png` still carry transparent margin and render smaller than nominal.
