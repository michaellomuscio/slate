# Slate — project guide for Claude Code

Slate is a two-part system for making screencasts that **Claude Code edits**:

1. **The recorder** (macOS app, `Slate/`, SwiftUI + ScreenCaptureKit) records screen,
   camera, mic, and a click/event log as separate files on one shared clock → a **take
   bundle**. See `README.md` for the bundle format.
2. **The editing pipeline** (`pipeline/`, Python + ffmpeg + ElevenLabs/whisper) turns a
   bundle into a finished video. Claude is the editor-in-chief; ffmpeg is the hands;
   `edit.json` is the script. See `EDIT_SCHEMA.md` and `WORKFLOW.md`.

## The workflow  (full version in WORKFLOW.md)

```
record (Slate.app)  →  ~/Movies/Slate/take-…/     # screen.mov camera.mov audio.wav events.jsonl meta.json
   /slate-ingest        → transcript.json, frames/  # transcribe (verbatim) + silences + disfluencies
   /slate-digest        → take.md, contact_sheet.jpg # the artifact Claude reads to "see" the take
   /slate-strip-filler  → edit.json                  # propose cuts, Claude refines
   (or /slate-cut social|course → edit.json)         # narrative shaping
   /slate-render        → final.mp4 + final.srt        # ffmpeg executes the EDL
```

`/slate [social|course] [latest]` runs the whole thing end-to-end, narrated.

## The pipeline scripts (all stdlib Python 3.9, run from anywhere)

| script | does | output |
|---|---|---|
| `pipeline/ingest.py <bundle> [--stt auto\|eleven\|whisper] [--model P] [--verbatim]` | peak-normalize audio → transcribe (word-level) + silence detect + disfluency detect + frames | `transcript.json`, `frames/`, `frames.json` |
| `pipeline/digest.py <bundle>` | human+Claude-readable brief + tiled contact sheet; flags quiet audio | `take.md`, `contact_sheet.jpg` |
| `pipeline/propose_edit.py <bundle> [--mode cut\|silence] [--preset …]` | deterministic first-pass EDL: silence/filler/disfluency cuts + click zooms | `edit.json` |
| `pipeline/render.py <bundle> [--preset …] [--no-zoom] [--no-camera] [--preview]` | execute the EDL: per-segment cut→concat, zoom, camera bubble, framing, loudnorm | `final.mp4`, `final.srt` |
| `pipeline/make_test_bundle.py [dir]` | synth a real test bundle via `say` + ffmpeg | a take bundle |

`pipeline/lib/transcribe.py` is the pluggable STT layer (ElevenLabs Scribe ↔ whisper-cli).

## Hard-won constraints (don't relearn these)

- **System Python is 3.9.6** (`/usr/bin/python3`). No third-party packages — stdlib only.
  Avoid `match`, runtime `X | Y` unions. Scripts use `from __future__ import annotations`.
- **Transcription is ElevenLabs Scribe by default** (verbatim — keeps "um/uh" with word
  timestamps), auto-selected when `ELEVENLABS_API_KEY` is found (env or
  `~/.claude/channels/telegram/.env`). whisper-cli is the offline/free fallback (it *drops*
  fillers — proven). Never hardcode the key. Force a backend with `--stt`/`$SLATE_STT`.
- **Audio is peak-normalized before STT.** Real mic capture is often ~30 dB too quiet
  (a real take peaked at −29.6 dB → whisper returned `[BLANK_AUDIO]`). Normalization is
  dynamics-preserving so silence detection stays meaningful. The renderer loudness-normalizes
  the output (≈ −16 LUFS).
- **The system ffmpeg lacks libass** (Homebrew 8.1). Slate uses its OWN libass-enabled build
  at `pipeline/bin/ffmpeg` (via `lib.bundle.ffmpeg_cmd()`, override `$SLATE_FFMPEG`) so
  burned-in captions work. **Never reinstall/disturb the system ffmpeg.** ffprobe = system.
- **Timeline discipline.** Everything is global time; `meta.streams[x].startOffset` maps to
  each file's local clock. The editable span is `[bundle.timeline_start(), bundle.timeline_end()]`
  (where the primary streams exist) so we never seek before a stream began or past any end.
  The renderer is the only place offsets are applied.
- **Sync is by construction.** Segments are cut from screen+audio together; intermediates are
  PCM-in-MKV (no AAC priming) with an output `-t` + `-fps_mode cfr` (a VFR screen can't
  over-run). Validated ~3 ms on a real take. Camera warm-up is gated by `camera_live_at()`.

## Building / packaging the recorder app

XcodeGen-managed: `xcodegen generate && open Slate.xcodeproj`. Set your Team under Signing &
Capabilities (stable signature → TCC permissions persist). Min macOS 15, Swift 5 mode,
hardened runtime ON.

Standalone app (no Xcode): `scripts/package.sh` → Developer-ID-signed `dist/Slate.app` + a
drag-to-Applications `dist/Slate.dmg`. Notarization is optional (single Mac) — set up a
`notarytool` keychain profile named `slate-notary` first; see the header of `scripts/package.sh`.
