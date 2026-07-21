#!/usr/bin/env bash
# Convert an approved art theme into shipped game assets:
#   art/<theme>/*.png  ->  resources/<theme>/*.webp   (cwebp -q 80)
# Usage: tools/art2resources.sh <theme>   e.g. tools/art2resources.sh scifi-60s
# The game loads WebP only (see src/render.zig loadTextureWebp); never copy
# raw PNGs into resources/.
set -euo pipefail
cd "$(dirname "$0")/.."

theme="${1:?usage: tools/art2resources.sh <theme>}"
src="art/$theme"
dst="resources/$theme"
[ -d "$src" ] || { echo "no such theme dir: $src" >&2; exit 1; }
command -v cwebp >/dev/null || { echo "cwebp not found (brew install webp)" >&2; exit 1; }

mkdir -p "$dst"
shopt -s nullglob
pngs=("$src"/*.png)
[ ${#pngs[@]} -gt 0 ] || { echo "no PNGs in $src" >&2; exit 1; }
for png in "${pngs[@]}"; do
  name="$(basename "$png" .png)"
  cwebp -quiet -q 80 "$png" -o "$dst/$name.webp"
  echo "$dst/$name.webp"
done
