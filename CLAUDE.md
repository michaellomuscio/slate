# Slate — project guide for Claude Code

Slate is a two-part system for making screencasts that **Claude Code edits**:

1. **The recorder** (macOS app, `Slate/`, SwiftUI + ScreenCaptureKit) records screen,
   camera, mic, and a click/event log as separate files on one shared clock → a **take
   bundle**. See `README.md` for the bundle format.
2. **The editing pipeline** (`pipeline/`, Python + ffmpeg + whisper) turns a bundle into a
   finished video. Claude is the editor-in-chief; ffmpeg is the hands; `edit.json` is the
   script. See `EDIT_SCHEMA.md`.

## The workflow

```
record (Slate.app)  →  ~/Movies/Slate/take-…/        # screen.mov camera.mov audio.wav events.jsonl meta.json
   /slate-ingest        → transcript.json, frames/    # transcribe + see
   /slate-strip-filler  → edit.json                   # propose cuts, Claude refines
   (or /slate-cut social|course → edit.json)          # narrative shaping
   /slate-render        → final.mp4 + final.srt        # ffmpeg executes the EDL
```

## The pipeline scripts (all stdlib Python, run from anywhere)

| script | does | output |
|---|---|---|
| `pipeline/ingest.py <bundle> [--verbatim]` | whisper transcription (word-level, global timeline) + silence detection + frame extraction at clicks/scenes | `transcript.json`, `frames/`, `frames.json` |
| `pipeline/propose_edit.py <bundle> [--mode cut\|silence] [--preset …]` | deterministic first-pass EDL: silence-driven cuts + click zooms | `edit.json` |
| `pipeline/render.py <bundle> [--preset …] [--no-zoom] [--no-camera] [--preview]` | execute the EDL: per-segment cut → concat, zoom, camera bubble, framing | `final.mp4`, `final.srt` |
| `pipeline/make_test_bundle.py [dir]` | synth a real test bundle via `say` + ffmpeg (dev/testing) | a take bundle |

## Hard-won constraints (don't relearn these)

- **System Python is 3.9.6** (`/usr/bin/python3`). No third-party packages — stdlib only.
  Avoid `match`, runtime `X | Y` unions. Scripts use `from __future__ import annotations`.
- **This ffmpeg lacks libass/libfreetype** → no `subtitles`/`drawtext` filters. Captions
  ship as a `final.srt` sidecar. To get burned-in captions, install an ffmpeg with libass
  and set `captions.burn=true`. (Don't silently reinstall Michael's ffmpeg.)
- **Whisper (base.en) cleans disfluencies** — it usually drops "um"/"uh". So filler removal
  is **silence-driven** (the reliable signal), not transcript-driven. `--verbatim` biases
  whisper to keep fillers but is unreliable.
- **Whisper model**: `ingest.py` searches `pipeline/models/`, `$SLATE_WHISPER_MODEL`, and a
  known fallback (`~/Downloads/workspace/whisper_models/ggml-base.en.bin`). `-dtw` improves
  token timestamps.
- **Timeline discipline**: everything is global time; `meta.streams[x].startOffset` maps to
  each file's local clock. The renderer is the only place offsets are applied.

## Building the recorder app

XcodeGen-managed: `xcodegen generate && open Slate.xcodeproj`. Set your Team under Signing
& Capabilities (stable signature → permissions persist). Min macOS 15, Swift 5 mode.
