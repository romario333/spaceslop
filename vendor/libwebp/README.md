# Vendored libwebp (decode only)

Subset of [libwebp](https://github.com/webmproject/libwebp) **v1.4.0** used to
decode the WebP sprites in `resources/` (raylib's stb_image has no WebP
support). Only the decoder is vendored: `src/dec`, `src/webp` headers, and the
decode-side files of `src/dsp` and `src/utils` — encoder sources
(`*_enc*`, `cost*`, `ssim*`, `huffman_encode*`, `quant_levels_utils*`) are
omitted. (`utils/palette.c` stays: `utils.c` references it and native linking
fails without it; a few encoder headers are kept for the same reason.)
Adds ~70 KB to the wasm bundle.

Compiled into the game by `build.zig` (same file list for native and
emscripten). The game calls `WebPDecodeRGBA` via an `extern` in
`src/render.zig` (`loadTextureWebp`).

To upgrade: download the new release tarball, re-copy the same directories
with the same exclusions, and rebuild. Upstream license in `COPYING` (BSD
3-clause).
