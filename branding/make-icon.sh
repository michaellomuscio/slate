#!/usr/bin/env bash
# Render branding/AppIcon.svg into the macOS AppIcon asset catalog (all sizes).
# Edit AppIcon.svg, re-run this, then rebuild the app. Requires librsvg (brew install librsvg).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$DIR/branding/AppIcon.svg"
XCASSETS="$DIR/Slate/Assets.xcassets"
SET="$XCASSETS/AppIcon.appiconset"

command -v rsvg-convert >/dev/null || { echo "Need rsvg-convert — 'brew install librsvg'"; exit 1; }

TMP="$(mktemp -d)"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TMP/master.png"

mkdir -p "$SET"
for s in 16 32 64 128 256 512; do
  sips -z "$s" "$s" "$TMP/master.png" --out "$SET/icon_$s.png" >/dev/null
done
cp "$TMP/master.png" "$SET/icon_1024.png"
rm -rf "$TMP"

cat > "$XCASSETS/Contents.json" <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",   "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16",   "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Wrote $SET ($(ls "$SET"/*.png | wc -l | tr -d ' ') PNGs). Rebuild the app to apply."
