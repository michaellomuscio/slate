---
description: Drive a Slate take from raw recording to finished video — ingest, understand, edit, render — narrating the decisions
argument-hint: [social|course] [path to take bundle | "latest"] [extra notes]
---

You are the editor-in-chief for a Slate screencast. Take a recording from raw bundle to a
finished, posted-ready video, end to end, **narrating what you decide and why**. Parse
**$ARGUMENTS** for: a target format (`social` = tight 30–60s vertical; `course` = full clean
landscape walkthrough — default `course`), a bundle path (default: the newest folder under
`~/Movies/Slate/`, i.e. `ls -dt ~/Movies/Slate/take-* | head -1`), and any extra notes from me.

Run the pipeline from `~/projects/screen-recorder/pipeline`. Work through these steps, pausing
only where noted:

1. **Ingest** — `python3 pipeline/ingest.py "<bundle>"`.
   - This auto-selects ElevenLabs Scribe (verbatim — keeps "um/uh") when a key is present,
     else local whisper. It peak-normalizes quiet audio first. Report the backend it used,
     word/segment/silence/disfluency counts, and any `+N dB` normalization (a big boost means
     the mic was too quiet — tell me).
2. **Understand** — `python3 pipeline/digest.py "<bundle>"`, then READ `take.md`.
   - Give me a 2–3 sentence read: what the take is about, how long, audio health, how much
     dead air / filler, and what's visually on screen (peek at a frame or two from `frames/`
     if it helps you reason).
   - If audio health is flagged TOO QUIET **and** there's no transcript, stop and tell me —
     the mic likely wasn't picking up; re-record or proceed visuals-only.
3. **Propose the cut** — `python3 pipeline/propose_edit.py "<bundle>" [--mode silence if I asked]`.
   - Then **do real editorial work** on `edit.json` (see `EDIT_SCHEMA.md`):
     - Protect intentional/emphasis pauses — don't cut every silence to zero.
     - Catch what detection can't: false starts ("so the— ok, the first thing"), repeated
       takes, tangents. Add them as `cut` with a `reason`.
     - For **social**: find the single strongest 30–60s complete thought with a hook; cut the
       rest; `preset:"social"`. For **course**: keep the full clean walkthrough; remove dead
       air/fillers/flubs; `preset:"course"`.
     - Place `zooms` on the moments that matter (clicks from the event log, key reveals).
     - Keep the timeline a gapless cover of `[0, duration]`.
4. **Show me the plan** — original length, time removed, new length, the cut list with reasons,
   and the narrative arc in a few bullets. **Wait for my OK.** (If I said "just do it" in the
   notes, skip the wait.)
5. **Render** — `python3 pipeline/render.py "<bundle>" --preset <target>` (suggest `--preview`
   first for a fast look). Report final vs source length, resolution, and that captions burned
   in (`final.srt` is also written). Then offer: `open "<bundle>/final.mp4"`.

Principles: you reason over the transcript + `take.md` + frames + clicks and write `edit.json`;
ffmpeg does the pixels; sync is guaranteed by construction (cuts remove audio+video together).
Never desync, never leave gaps in the timeline, always keep a `reason` on every cut.
