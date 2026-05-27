#!/usr/bin/env python3
"""Generate a synthetic Slate take bundle for testing the editing pipeline — no recording
required. Uses macOS `say` for real speech (with deliberate fillers) and ffmpeg for test
video, then writes events.jsonl + meta.json in the real bundle format.

    python3 pipeline/make_test_bundle.py [output_dir]

Default output: ~/Movies/Slate/take-TEST
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import probe_duration, run

NARRATION = (
    "Hey everyone, welcome back. "
    "Um, today I'm going to show you the A.I. command center. "
    "Uh, the first thing you'll notice is the dashboard. "
    "So, um, let's click the deploy button right here. "
    "And, uh, that is basically it. Thanks for watching."
)


def main():
    out = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 \
        else Path.home() / "Movies/Slate/take-TEST"
    out.mkdir(parents=True, exist_ok=True)
    print("Building test bundle at:", out)

    with tempfile.TemporaryDirectory() as tmp:
        aiff = Path(tmp) / "n.aiff"
        run(["say", "-o", str(aiff), NARRATION])
        # Recorder writes 16-bit LPCM mono wav; match that.
        run(["ffmpeg", "-y", "-i", str(aiff), "-ac", "1", "-ar", "48000",
             "-sample_fmt", "s16", str(out / "audio.wav")])

    dur = probe_duration(out / "audio.wav")
    print("  audio duration: %.2fs" % dur)

    # Screen: a moving test pattern at 1080p/30. Camera: a smaller pattern for overlay.
    run(["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30",
         "-t", "%.3f" % dur, "-c:v", "libx264", "-pix_fmt", "yuv420p",
         "-preset", "ultrafast", str(out / "screen.mov")])
    run(["ffmpeg", "-y", "-f", "lavfi", "-i", "smptebars=size=640x480:rate=30",
         "-t", "%.3f" % dur, "-c:v", "libx264", "-pix_fmt", "yuv420p",
         "-preset", "ultrafast", str(out / "camera.mov")])

    # Events: app context, a little cursor motion, and a click roughly where the
    # narration says "deploy button" (~65% through).
    click_t = round(dur * 0.65, 2)
    events = [
        {"t": 0.0, "type": "app", "bundleId": "com.apple.Safari", "name": "Safari"},
        {"t": click_t - 0.5, "type": "move", "x": 1400, "y": 300},
        {"t": click_t, "type": "click", "button": "left",
         "x": 1500, "y": 300, "px": 1500.0, "py": 780.0},
    ]
    with (out / "events.jsonl").open("w") as f:
        for e in events:
            f.write(json.dumps(e, sort_keys=True) + "\n")

    meta = {
        "schemaVersion": 1,
        "app": "Slate",
        "appVersion": "0.1.0-test",
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "fps": 30,
        "display": {
            "id": 1, "name": "Test Display",
            "pixelWidth": 1920, "pixelHeight": 1080,
            "pointWidth": 1920, "pointHeight": 1080,
            "backingScaleFactor": 1.0,
            "globalFrame": {"x": 0, "y": 0, "w": 1920, "h": 1080},
        },
        "streams": {
            "screen": {"file": "screen.mov", "startOffset": 0.0, "width": 1920, "height": 1080},
            # camera deliberately lags 0.2s to exercise offset alignment in the renderer
            "camera": {"file": "camera.mov", "startOffset": 0.2, "width": 640, "height": 480},
            "audio": {"file": "audio.wav", "startOffset": 0.0, "sampleRate": 48000, "channels": 1},
        },
        "events": "events.jsonl",
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True))

    print("  wrote screen.mov, camera.mov, audio.wav, events.jsonl, meta.json")
    print("  click event at t=%.2fs" % click_t)
    print("Done.")


if __name__ == "__main__":
    main()
