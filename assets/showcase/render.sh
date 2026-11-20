#!/usr/bin/env bash
#
# Usage: assets/showcase/render.sh
#
# Renders card.html to assets/social-card.png (the GitHub social preview,
# 1280x640) and hero.html to assets/hero.webp (the README's animation).
# Needs Google Chrome and ImageMagick; oxipng, when installed, shrinks the
# card without changing a pixel.
#
# The hero is hero.html rendered at nine cross-fade steps and joined into
# a loop: the stretched window for 2 s, a 0.4 s fade, the centered window
# for 3.5 s, and the fade back.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
assets="$(dirname "$here")"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT

# The virtual time budget lets the web fonts and images load before the
# screenshot; without it a render can fall back to other faces.
shoot() {
    local url=$1 size=$2 out=$3
    "$chrome" --headless=new --disable-gpu --hide-scrollbars \
        --force-device-scale-factor=1 --window-size="$size" \
        --virtual-time-budget=5000 --allow-file-access-from-files \
        --screenshot="$out" "$url" 2>/dev/null
}

shoot "file://$here/card.html" 1280,640 "$assets/social-card.png"
if command -v oxipng >/dev/null; then
    oxipng -q -o max --strip safe -Z "$assets/social-card.png"
fi

steps=(0 0.125 0.25 0.375 0.5 0.625 0.75 0.875 1)
for i in "${!steps[@]}"; do
    shoot "file://$here/hero.html?t=${steps[$i]}" 1280,620 "$frames/$i.png"
done

last=$((${#steps[@]} - 1))
sequence=(-delay 200 "$frames/0.png")
for ((i = 1; i < last; i++)); do
    sequence+=(-delay 5 "$frames/$i.png")
done
sequence+=(-delay 350 "$frames/$last.png")
for ((i = last - 1; i >= 1; i--)); do
    sequence+=(-delay 5 "$frames/$i.png")
done
magick "${sequence[@]}" -loop 0 -quality 92 -define webp:method=6 "$assets/hero.webp"
