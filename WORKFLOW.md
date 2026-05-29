# The Slate Workflow — recording to finished video, with Claude Code as the editor

This is the repeatable loop for turning a screen recording into social clips and online-course
modules **that Claude Code edits for you**. The whole design exists to make every recording
*accessible, editable, and understandable* by Claude: separate media streams on one clock, a
verbatim transcript with word timestamps, a click/event log, sampled frames, and a markdown
digest — so Claude can reason about a take without watching it, then drive ffmpeg to cut it.

```
 ┌─ RECORD ────────────┐   ┌─ INGEST ───────────────┐   ┌─ UNDERSTAND ──────────┐
 │ Slate.app           │   │ /slate-ingest          │   │ /slate-digest         │
 │ screen+camera+mic   │──▶│ ElevenLabs transcript, │──▶│ take.md + contact     │
 │ +clicks → bundle    │   │ frames, silences       │   │ sheet (Claude reads)  │
 └─────────────────────┘   └────────────────────────┘   └───────────┬───────────┘
                                                                     │
 ┌─ RENDER ────────────┐   ┌─ EDIT ─────────────────┐               │
 │ /slate-render       │◀──│ /slate-cut social|course│◀─────────────┘
 │ ffmpeg → final.mp4  │   │ or /slate-strip-filler  │
 │ +captions (synced)  │   │ Claude writes edit.json │
 └─────────────────────┘   └────────────────────────┘

 One command does all of it, narrated:  /slate [social|course] [latest]
```

## 0. Once: set up

- **Build the app** (or install the packaged DMG): `scripts/package.sh` → drag `Slate.app` to
  /Applications. First launch asks for Screen Recording / Camera / Mic; grant Accessibility for
  click-driven auto-zoom. (Signed with your Developer ID so these permissions persist.)
- **Transcription key** (optional but recommended): Slate auto-finds `ELEVENLABS_API_KEY` in
  `~/.claude/channels/telegram/.env`. With it, transcription is **verbatim** (keeps "um/uh" with
  word timestamps). Without it, Slate falls back to local whisper (free, offline, but drops
  fillers). Force a backend with `--stt eleven|whisper` or `SLATE_STT`.
- **ffmpeg**: the pipeline uses its own libass-enabled build at `pipeline/bin/ffmpeg`
  (`pipeline/bin/install.sh` fetches it). Your system ffmpeg is never touched.

## 1. Record

Open Slate, pick display / camera / mic, hit Record (⌘R). Talk through what you're doing; click
where it matters (clicks become zoom anchors). Stop. You get a bundle at
`~/Movies/Slate/take-<timestamp>/` with `screen.mov`, `camera.mov`, `audio.wav`, `events.jsonl`,
`meta.json` — each stream aligned to one shared clock so nothing ever needs re-syncing.

> **Mic check:** if your input is quiet, the recording is still recoverable — ingest
> peak-normalizes before transcription and the render loudness-normalizes the output. `take.md`
> will flag "audio TOO QUIET" so you know. But louder-at-the-source is always better.

## 2. The one-shot way

```
/slate course        # newest take → full clean walkthrough
/slate social        # newest take → tightest 30–60s vertical
/slate social ~/Movies/Slate/take-2026-… "lead with the deploy moment"
```

`/slate` ingests, reads `take.md`, proposes a cut, does real editorial judgment, shows you the
plan, waits for your OK, then renders. That's the whole workflow in one command.

## 3. The step-by-step way (more control)

| Step | Command | What Claude does |
|---|---|---|
| Ingest | `/slate-ingest [bundle]` | transcribe (ElevenLabs, verbatim) + frames + silences/disfluencies |
| Understand | `/slate-digest [bundle]` | write/read `take.md` + `contact_sheet.jpg`; summarize the take |
| Clean | `/slate-strip-filler [bundle]` | propose dead-air/filler cuts; Claude refines `edit.json` |
| Shape | `/slate-cut social\|course [bundle]` | pick the spans that tell the story for the format |
| Render | `/slate-render [bundle] [--preview]` | ffmpeg executes `edit.json` → `final.mp4` + captions |

You (and Claude) edit by editing `edit.json` — the Edit Decision List. See `EDIT_SCHEMA.md`.

## 4. How Claude "sees" a take (the contract)

After ingest, these artifacts make a take fully legible to Claude — read them in this order:

1. **`take.md`** — the digest: overview, **audio-health flag**, app timeline (chapters), clicks
   with the words spoken near them, the transcript, dead-air/filler candidates, and a frame index.
2. **`contact_sheet.jpg`** — every sampled frame tiled in one image (time order) — the whole
   recording at a glance.
3. **`transcript.json`** — word-level, verbatim, on the global timeline (+ `silences`,
   `disfluencies`, `audioEvents`, `stt` provenance).
4. **`frames/`** — individual screenshots at clicks + scene changes for close reading.
5. **`events.jsonl`** — clicks (zoom anchors) and app switches (chapters) on the global clock.

## 5. The guarantees (why edits don't break)

- **Sync by construction.** Cuts remove audio+video together (a `cut` shortens both; a `silence`
  mutes in place). There is no operation that shortens one track without the other — so A/V can't
  drift. Validated at ~3 ms on a real variable-frame-rate take.
- **One authoritative timeline.** The editable span is `[timeline_start, timeline_end]` — where
  the primary streams actually exist — so the renderer never seeks before a stream began (no
  duplicated head) or past any stream's end (no tail desync).
- **Camera warm-up handled.** If the webcam starts late (it often takes ~2 s), the PIP bubble is
  suppressed until real frames exist instead of freezing on frame 0.
- **Verbatim fillers.** With ElevenLabs, "um/uh/false starts" are in the transcript with exact
  timestamps, so filler removal is word-accurate — not guesswork.
- **Output is publish-ready.** Captions burn in (sidecar `.srt` always written too), audio is
  loudness-normalized to ≈ −16 LUFS, social renders cover-crop to 9:16 (no black bars).

## 6. Output presets

- **course** — 1920×1080, full clean walkthrough, chapters-friendly, gentle zoom on clicks.
- **social** — 1080×1920 vertical, cover-cropped to fill, the single strongest 30–60s.
- `--preview` renders everything at half-res for a fast look before the full render.
