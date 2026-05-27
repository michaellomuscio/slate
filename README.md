# Slate

A macOS screen recorder built so that **Claude Code can edit the result**.

Unlike Loom / Screen Studio / Descript, Slate doesn't bake everything into one finished
video. It records each stream **separately** and writes a **machine-readable take bundle**
— screen, camera, audio, and a timestamped event log — all aligned to one shared clock.
That bundle is the contract a downstream editing pipeline (transcription → edit-decision-list
→ ffmpeg render) consumes.

> The name: a *slate* is the clapboard you snap at the top of a take to sync picture and
> sound. That's this app's core trick — one shared clock stamps screen, camera, mic, and
> every click onto a single timeline, so nothing ever has to be re-synced by hand.

## Status

**v0.1 — recorder only.** Records the bundle. No in-app editing (editing lives in Claude
Code, operating on the bundle).

## Build

This project uses [XcodeGen](https://github.com/yonyz/XcodeGen) — the `.xcodeproj` is
generated, not committed.

```sh
brew install xcodegen          # if needed
cd ~/projects/screen-recorder
xcodegen generate              # creates Slate.xcodeproj
open Slate.xcodeproj           # then set your Team under Signing & Capabilities, ⌘R
```

**Signing note:** set your Apple Developer **Team** in Xcode (Signing & Capabilities) on
first open. A stable signature means macOS remembers the camera/mic/screen/accessibility
permissions across rebuilds — otherwise you'll be re-prompted every time the signature
changes.

## Permissions it asks for

| Permission | Why | Prompted by |
|---|---|---|
| Screen Recording | capture the screen | first capture attempt |
| Camera | record your face as a separate track | first camera use |
| Microphone | record narration as a separate track | first mic use |
| Accessibility | log global mouse clicks (for auto-zoom later) | in-app "Grant" button |

Accessibility is **optional** — deny it and recording still works, you just won't get the
click log that powers auto-zoom.

---

## The take bundle (the contract)

Each recording produces a folder under `~/Movies/Slate/`:

```
take-2026-05-27-143000/
  screen.mov        # ScreenCaptureKit, full resolution, NO zoom baked in
  camera.mov        # webcam, video only (may be absent if camera disabled)
  audio.wav         # microphone, LPCM mono — uncompressed for clean transcription
  events.jsonl      # clicks, cursor path, app switches — one JSON object per line
  meta.json         # the alignment key: clock offsets, display geometry, stream info
```

### `meta.json`

```jsonc
{
  "schemaVersion": 1,
  "app": "Slate",
  "appVersion": "0.1.0",
  "createdAt": "2026-05-27T14:30:00Z",   // wall-clock start (ISO-8601, UTC)
  "fps": 60,
  "display": {
    "id": 1,
    "name": "Built-in Retina Display",
    "pixelWidth": 3456, "pixelHeight": 2234,   // captured pixel dimensions
    "pointWidth": 1728, "pointHeight": 1117,    // logical points
    "backingScaleFactor": 2.0,
    "globalFrame": { "x": 0, "y": 0, "w": 1728, "h": 1117 }  // for click-coord mapping
  },
  "streams": {
    "screen": { "file": "screen.mov", "startOffset": 0.041, "width": 3456, "height": 2234 },
    "camera": { "file": "camera.mov", "startOffset": 0.118, "width": 1920, "height": 1080 },
    "audio":  { "file": "audio.wav",  "startOffset": 0.052, "sampleRate": 48000, "channels": 1 }
  },
  "events": "events.jsonl"
}
```

**`startOffset` is the whole point.** It is the time (in seconds) between when the user hit
Record (global `t = 0`) and when that stream delivered its first frame/sample. To align the
streams downstream, shift each file by its offset, e.g.:

```sh
ffmpeg -itsoffset 0.041 -i screen.mov \
       -itsoffset 0.118 -i camera.mov \
       -itsoffset 0.052 -i audio.wav  ...
```

Each file's own internal timeline starts at ~0; `startOffset` maps that to the global
timeline shared by every stream and every event. **This is why audio and video never have
to be re-synced by hand** — the alignment is recorded, not guessed.

### `events.jsonl`

One JSON object per line. All `t` values are seconds on the global timeline (same `t = 0`
as the streams).

```jsonc
{"t": 0.000, "type": "app",   "bundleId": "com.apple.Safari", "name": "Safari"}
{"t": 5.000, "type": "move",  "x": 1402, "y": 866}                       // global screen points
{"t": 5.012, "type": "click", "button": "left", "x": 1420, "y": 880,
             "px": 1420, "py": 474}                                       // display-local pixels
```

- `click` — a mouse-down. `x`,`y` are global screen points (bottom-left origin, AppKit);
  `px`,`py` are pixels within the captured display (top-left origin) for direct mapping onto
  `screen.mov`. These drive **auto-zoom** ("zoom toward what was clicked").
- `move` — sampled cursor position (~20 Hz, only when it moved). Drives smooth zoom-follow.
- `app` — frontmost application changed. Useful for chaptering and context.

---

## Why this shape (for the editing pipeline)

The downstream plan (built separately, in Claude Code):

1. **Ingest** — `whisper-cli` transcribes `audio.wav` to word-level timestamps; ffmpeg
   pulls frames at each click + scene change so Claude can *see* the screen.
2. **Edit** — Claude reads the transcript + frames + `events.jsonl` and writes an
   **Edit Decision List** (`edit.json`): ripple-cuts (remove from audio+video together →
   stays in sync), silences (mute in place, your "leave a blank spot" idea), zooms (from the
   click log), captions, chapters.
3. **Render** — ffmpeg executes `edit.json` into the final video, per output preset
   (social-vertical vs course-landscape).

Slate exists to make step 1 trivial and step 2 *possible*. Everything it records is in
service of "Claude can reason about this take without watching a single frame of video it
can't already read from the transcript and the click log."
