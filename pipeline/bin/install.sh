#!/usr/bin/env bash
# Fetch a libass-enabled ffmpeg static build from evermeet.cx into this dir.
# Side-by-side install — doesn't touch the system ffmpeg. Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$DIR/ffmpeg"
if [ -x "$TARGET" ]; then
  echo "already present: $TARGET"
  "$TARGET" -version 2>&1 | head -1
  exit 0
fi
echo "Downloading ffmpeg with libass from evermeet.cx ..."
TMP="$(mktemp -d)"
curl -sL "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" -o "$TMP/ffmpeg.zip"
unzip -q -o "$TMP/ffmpeg.zip" -d "$TMP"
mv "$TMP/ffmpeg" "$TARGET"
chmod +x "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
rm -rf "$TMP"
echo "Installed: $TARGET"
"$TARGET" -version 2>&1 | head -1
"$TARGET" -hide_banner -filters 2>/dev/null | grep -E "^ *[TVA.]+ +(subtitles|drawtext) " | head
