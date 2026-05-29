# Slate

**A macOS screen recorder built so [Claude Code](https://claude.com/claude-code) can edit the result.**

Loom, Screen Studio, and Descript bake everything into one finished video. Slate does the
opposite: it records each stream **separately** — screen, camera, mic, and a timestamped
click/event log — all aligned to one shared clock, and writes a **machine-readable take
bundle**. That bundle is a contract a downstream pipeline (transcribe → edit-decision-list →
`ffmpeg` render) consumes, with Claude Code as the editor-in-chief. You record; Claude reads
the transcript, sees the frames, and cuts the video.

> The name: a *slate* is the clapboard you snap at the top of a take to sync picture and
> sound. That's the core trick — one clock stamps screen, camera, mic, and every click onto a
> single timeline, so nothing ever has to be re-synced by hand.

---

## Status

**v0.2** — recorder + editing pipeline + in-app review, packaged as a notarized app.

- 🎙️ **Verbatim transcription** via ElevenLabs Scribe (keeps "um/uh" with word-level
  timestamps), with local Whisper as an offline fallback. Quiet mics are auto-normalized.
- ✂️ **Claude edits the video** — `/slate social|course` runs the whole pipeline; sync is
  guaranteed by construction (validated to ~3 ms on a real recording).
- 🧠 **Comprehension layer** — every take gets a `take.md` digest + a tiled `contact_sheet.jpg`
  so Claude can understand a recording without watching it.
- 📦 **Standalone, notarized** — Developer-ID-signed `.app` + DMG; permissions persist.

---

## Quick start

### 1. Install the app

Grab `Slate.dmg` from the latest [Release](../../releases), open it, and drag **Slate** into
Applications. Or build it yourself: `./scripts/package.sh` (see [Building](#building-from-source)).

On first launch, grant **Screen Recording**, **Camera**, and **Microphone**; grant
**Accessibility** (optional) for click-driven auto-zoom. Because the app is Developer-ID
signed, you grant these **once** — rebuilds won't re-prompt.

### 2. Set up transcription (optional but recommended)

Slate auto-detects an `ELEVENLABS_API_KEY` (from the environment or
`~/.claude/channels/telegram/.env`) and uses ElevenLabs Scribe — **verbatim** transcription
that keeps filler words with per-word timestamps. Without a key it falls back to local
`whisper-cli` (free, offline, but it *drops* fillers). Force a backend with `--stt eleven|whisper`
or `$SLATE_STT`.

### 3. Record, then let Claude edit

```
# Record a screencast in Slate.app (talk through what you're doing — clicks become zoom anchors)
# Then, in Claude Code, from anywhere:

/slate course        # newest take → full clean walkthrough
/slate social        # newest take → tightest 30–60s vertical, karaoke captions
```

`/slate` ingests the take, reads it, proposes a cut, shows you the plan, and renders on your OK.
See **[WORKFLOW.md](WORKFLOW.md)** for the full loop and the step-by-step commands.

---

## How it works

Three layers, one contract.

```
 ┌─ 1. RECORD (Slate.app) ─────────────────────────────────────────────┐
 │ ScreenCaptureKit + AVFoundation capture screen / camera / mic /      │
 │ clicks as SEPARATE files on one monotonic clock → a take bundle      │
 └─────────────────────────────┬───────────────────────────────────────┘
                               │  ~/Movies/Slate/take-<ts>/
 ┌─ 2. INGEST + UNDERSTAND ────▼───────────────────────────────────────┐
 │ transcribe (ElevenLabs/Whisper) · silences · frames · take.md ·      │
 │ contact_sheet.jpg  → everything Claude needs to reason about a take  │
 └─────────────────────────────┬───────────────────────────────────────┘
 ┌─ 3. EDIT + RENDER ──────────▼───────────────────────────────────────┐
 │ Claude writes edit.json (the EDL) · ffmpeg executes it · cuts keep   │
 │ A/V locked · zoom · camera bubble · captions  → final.mp4            │
 └──────────────────────────────────────────────────────────────────────┘
```

### The take bundle (the contract)

Each recording is a folder under `~/Movies/Slate/`:

```
take-2026-05-27-143000/
  screen.mov        # ScreenCaptureKit, full resolution, NO zoom baked in
  camera.mov        # webcam, video only (may be absent)
  audio.wav         # microphone, LPCM mono — uncompressed for clean transcription
  events.jsonl      # clicks, cursor path, app switches — one JSON object per line
  meta.json         # the alignment key: clock offsets, display geometry, stream info
  # added by the pipeline:
  transcript.json   # word-level, verbatim, on the global timeline (+ silences, disfluencies)
  take.md           # human + Claude readable digest of the whole take
  contact_sheet.jpg # every sampled frame tiled in one image
  frames/           # screenshots at clicks + scene changes
  edit.json         # the Edit Decision List Claude writes
  final.mp4         # the rendered video (+ final.srt captions)
```

**`meta.json` → `startOffset` is the whole point.** Each stream records the time (in seconds)
between hitting Record (global `t = 0`) and its first frame/sample. To align the streams you
shift each file by its offset — so audio and video never have to be re-synced by hand, the
alignment is *recorded*, not guessed.

The editable timeline runs `[timeline_start, timeline_end]` — the window where the primary
streams actually exist — so the renderer never seeks before a stream began or past any stream's
end. A late-warming webcam (often ~2 s) is gated until real frames exist instead of freezing.

### The editing pipeline (`pipeline/`)

Stdlib Python 3.9 + `ffmpeg` + an STT backend. Run from anywhere.

| script | does | output |
|---|---|---|
| `ingest.py <bundle> [--stt auto\|eleven\|whisper]` | normalize audio → transcribe (word-level) + silence/disfluency detect + frames | `transcript.json`, `frames/` |
| `digest.py <bundle>` | human+Claude-readable brief + contact sheet; flags quiet audio | `take.md`, `contact_sheet.jpg` |
| `propose_edit.py <bundle> [--mode cut\|silence]` | deterministic first-pass EDL: silence/filler/disfluency cuts + click zooms | `edit.json` |
| `render.py <bundle> [--preset course\|social] [--preview]` | execute the EDL: per-segment cut→concat, zoom, camera bubble, captions, loudnorm | `final.mp4`, `final.srt` |
| `make_test_bundle.py [dir]` | synthesize a test bundle (`say` + ffmpeg), no recording needed | a take bundle |

Slash commands wrap these: `/slate`, `/slate-ingest`, `/slate-digest`, `/slate-strip-filler`,
`/slate-cut`, `/slate-render` (in `.claude/commands/`). The edit format is documented in
**[EDIT_SCHEMA.md](EDIT_SCHEMA.md)**.

**The sync guarantee:** the timeline is a complete, ordered partition of the take. A `cut`
removes the same span from audio *and* video (it just gets shorter); a `silence` keeps the
video and swaps in silent audio of equal length. There is no operation that shortens one track
without the other, so A/V cannot drift.

---

## Building from source

XcodeGen-managed — the `.xcodeproj` is generated, not committed.

```sh
brew install xcodegen            # if needed
cd slate
xcodegen generate                # creates Slate.xcodeproj
open Slate.xcodeproj             # set your Team under Signing & Capabilities, ⌘R
```

### Package a standalone, notarized app

```sh
# one-time: store a notarization credential (app-specific password from appleid.apple.com)
xcrun notarytool store-credentials slate-notary \
  --apple-id "you@example.com" --team-id <TEAM_ID> --password "xxxx-xxxx-xxxx-xxxx"

./scripts/package.sh             # → dist/Slate.app + dist/Slate.dmg (signed, notarized, stapled)
./scripts/package.sh --no-notarize   # signed only — fine for your own Mac
```

TCC permissions persist because a Developer ID signature yields a stable `cdhash` every build;
ad-hoc/unsigned builds change identity each compile and macOS re-prompts. See the header of
`scripts/package.sh` for details.

---

## Requirements

- **macOS 15+**, Xcode 16+ (uses ScreenCaptureKit `SCRecordingOutput`, Swift 5 mode).
- **System Python 3.9+** (`/usr/bin/python3`) — the pipeline is stdlib-only, no `pip` needed.
- **ffmpeg with libass** for burned-in captions. Slate ships its own at `pipeline/bin/ffmpeg`
  (run `pipeline/bin/install.sh` after cloning — it's gitignored). Your system ffmpeg is never
  touched. `ffprobe` uses the system binary.
- **A transcription backend**: an ElevenLabs API key (recommended), and/or `whisper-cli`
  (whisper.cpp) with a model in `pipeline/models/` (also gitignored — fetch separately).

---

## Repository layout

```
Slate/                  SwiftUI app — Recording/ (capture), Review/ (in-app playback), Model/, Views/
pipeline/               the editing brain (Python + ffmpeg)
  lib/transcribe.py     pluggable STT (ElevenLabs Scribe ↔ whisper-cli)
  lib/bundle.py         take-bundle IO + timeline math
  ingest.py · digest.py · propose_edit.py · render.py
  bin/                  bundled libass ffmpeg (fetched, gitignored)
.claude/commands/       the /slate* editing verbs
scripts/package.sh      build → sign → notarize → DMG
project.yml             XcodeGen spec
WORKFLOW.md             the end-to-end editing workflow
EDIT_SCHEMA.md          the edit.json (EDL) format
CLAUDE.md               project guide for Claude Code
```

---

## Troubleshooting

- **Transcript is empty / `[BLANK_AUDIO]`** — the mic was too quiet (or there was no speech).
  Ingest peak-normalizes and `take.md` flags "audio TOO QUIET"; record louder next time.
- **Captions render as a `.srt` sidecar instead of burned in** — your `ffmpeg` lacks libass.
  Run `pipeline/bin/install.sh` so Slate uses its own libass build.
- **macOS keeps re-asking for Screen Recording / Accessibility** — you're running an
  ad-hoc/unsigned build. Use a Developer-ID-signed build (`scripts/package.sh`).
- **Camera bubble missing at the very start** — expected; the webcam warm-up window is gated
  until real frames arrive (a frozen frame would be worse).

---

*A personal project by Michael Lomuscio / Lomuscio Labs. © 2026.*
