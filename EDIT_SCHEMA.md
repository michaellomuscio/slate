# `edit.json` — the Slate Edit Decision List (EDL)

This is the contract between judgment and rendering. **Claude writes this file; ffmpeg
executes it.** Claude never touches pixels — it reasons over the transcript, the click log,
and sampled frames, and emits this JSON. `render.py` turns it into `final.mp4`.

Everything is expressed on the **global timeline** (seconds, `t=0` at record start) — the
same timeline as `transcript.json` and `events.jsonl`. The renderer maps to each file's
local clock using `meta.json` offsets, so you never reason about per-file time.

```jsonc
{
  "version": 1,
  "source": "screen",          // primary video; camera becomes an overlay
  "preset": "course",          // "course" (16:9) | "social" (9:16)

  "timeline": [                // ORDERED, must cover [0, duration] with no gaps
    {"op": "keep",    "start": 0.00,  "end": 1.76},
    {"op": "cut",     "start": 1.76,  "end": 2.17, "reason": "dead air"},
    {"op": "keep",    "start": 2.17,  "end": 6.13},
    {"op": "silence", "start": 6.13,  "end": 6.40, "reason": "filler 'um'"}
  ],

  "zooms": [
    {"start": 10.42, "end": 12.42, "x": 1500, "y": 780, "scale": 1.8, "reason": "click: Deploy"}
  ],

  "camera":   {"enabled": true, "shape": "circle", "corner": "br", "size": 0.18},
  "captions": {"enabled": true, "burn": false}
}
```

## Timeline ops — and the sync guarantee

The timeline is a complete, ordered partition of `[0, duration]`. Every op:

| op | audio | video | duration | use it for |
|---|---|---|---|---|
| `keep` | kept | kept | unchanged | the good stuff |
| `cut` | **removed** | **removed** | **shortens** | flubs, rambles, dead air, dropped-filler gaps |
| `silence` | muted | kept | unchanged | a mid-sentence "um" where a visual jump would look worse than a beat of silence |

**Why sync is never a problem:** the renderer builds audio and video from the *same*
segment list. A `cut` removes the identical span from both tracks, so they stay locked and
the clip just gets shorter. A `silence` keeps the video and swaps in silent audio of equal
length. You cannot desync by construction — there is no operation that shortens one track
without the other.

> This is the clean answer to "if I cut audio and rejoin, everything drifts." Right — *if*
> you cut audio alone. Here you cut both together (`cut`), or neither (`silence`).

## zooms

A constant crop-zoom toward `(x, y)` — **display-local pixels** on `screen.mov` (top-left
origin), which is exactly what the click log records as `px`,`py`. `scale` is the
magnification (1.8 ≈ a comfortable emphasis). Zooms are clipped to whatever kept segments
they overlap; cut spans inside a zoom simply vanish with everything else.

## camera

`enabled` requires a `camera.mov` in the bundle. `shape`: `circle` (geq alpha mask) or
`square`. `corner`: `br|bl|tr|tl`. `size`: bubble diameter as a fraction of frame height.

## captions

A timeline-accurate `final.srt` is **always** written (remapped onto the post-cut
timeline). `burn: true` burns them into the pixels — but only if this machine's ffmpeg has
the `subtitles` filter (libass). The current ffmpeg does **not**, so burn falls back to the
sidecar. Upload targets (YouTube, LinkedIn, etc.) accept the `.srt` directly.

## How Claude should reason about an edit

1. `propose_edit.py` gives a deterministic first pass (silence-driven cuts + click zooms).
   Start there; don't redo it by hand.
2. Read `transcript.json`. Protect *intentional* pauses (a beat for emphasis) — don't cut
   every silence to zero. Catch things the script can't: false starts ("so the— ok, the
   first thing"), repeated takes, tangents.
3. For `/slate-cut`, shape narrative: pick the spans that tell the story for the target
   format and set the rest to `cut`. Vertical/social wants the tightest 30–60s; course
   wants the full clean walkthrough with chapters.
4. Keep `reason` on every `cut`/`silence` — it's the audit trail, and it's how Michael
   sanity-checks the edit before rendering.

## redactions  (Slate Edit tab)

The Edit tab can also write a `redactions` array — resizable boxes that cover or
blur part of the screen for a time window. Geometry is **fractional, top-left origin**
(like `camera`/zoom anchors); `start`/`end` are on the **original take timeline** (author
intent), remapped through the cuts only at render time.

```jsonc
"redactions": [
  {"x": 0.05, "y": 0.05, "w": 0.30, "h": 0.20,   // normalized rect, top-left origin
   "start": 0.0, "end": 3.0,                      // ORIGINAL take seconds
   "blur": false, "color": "#000000"}             // blur=true → unreadable; else solid color
]
```

The in-app native renderer paints these per-frame in Core Image (over the screen, under the
camera bubble). `render.py` may honor the same fractional contract later.

## Validation (`pipeline/validate_edit.py`)

`python3 pipeline/validate_edit.py <bundle>` checks an `edit.json` against its bundle, and
`render.py` runs it first and **refuses to render an invalid EDL**. It asserts: the timeline is
sorted, non-overlapping, gapless, and covers `[timeline_start, timeline_end]` (the guard against
silently truncating the payoff); every `cut`/`silence` has a `reason`; zoom/redaction times are in
range; and **no cut boundary lands mid-word** (cross-checked against `transcript.words[]`). It also
warns if a `course` edit removes too much. A `cut` with `reason: "long-wait"` marks a multi-minute
dead-air gap (screen asleep / AI thinking) collapsed to a ~1.5 s beat, keeping everything after it.
