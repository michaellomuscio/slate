---
description: Render a Slate take's edit.json into final.mp4 (+ captions)
argument-hint: [path to take bundle] [--preset social|course] [--preview]
---

Render the approved edit. Parse **$ARGUMENTS** for the bundle path (default: current
directory) and any flags (`--preset social|course`, `--preview` for a fast half-res check,
`--no-zoom`, `--no-camera`).

1. Confirm `edit.json` exists (if not, tell me to run `/slate-strip-filler` or `/slate-cut`).
2. Run: `python3 ~/projects/screen-recorder/pipeline/render.py "<bundle>" <flags>`
3. Report: final length vs source length, resolution/preset, and whether captions were
   burned in or written as a sidecar.
4. Offer to open it: `open "<bundle>/final.mp4"`. If I want to eyeball a moment first,
   pull a frame or two with ffmpeg and show me.

If it's a first look, suggest `--preview` (much faster); render full quality once I'm happy
with the edit.
