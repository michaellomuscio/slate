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
3. **Choose the scenes — a real narrative process, not just "keep a strong 30–60s."** Run a
   first pass with `python3 pipeline/propose_edit.py "<bundle>" --preset <target>` (keep-first
   cleanup — **course** trims only genuine dead air, **social** cuts tight; it recovers the
   payoff automatically by using the true timeline end, collapses long AI-wait gaps to a ~1.5s
   beat, and never cuts mid-word), then do the editorial judgment via the multi-lens panel (social-media + storytelling +
   marketing experts → a showrunner). Reason through those lenses, or run the
   `slate-narrative` workflow. **Non-negotiable rules (learned the hard way):**
   - **A long mid-take silence is the AI working — NOT the end.** Cut the silence, KEEP the
     good content after it. The PAYOFF (the result being shown/described) usually lives at the
     very end, after the longest gap — re-read the transcript near the end and make sure the
     payoff is in the cut. Never end on the tease. (The renderer freezes the last screen frame
     for payoff narration that has no screen, so audio/camera-only payoffs still work.)
   - **Judge as a stranger** who doesn't know what you're about to show — it must hook in the
     first 2–3s, make sense as a story, and land a concrete takeaway.
   - Catch false starts, repeats, rambles, over-explanation — cut with a `reason`. Place
     `zooms` on key reveals/clicks. Keep the timeline a gapless cover of `[0, duration]`.
4. **Show me the plan** — working title, one-sentence throughline, the narrative arc
   beat-by-beat, the chosen spans with their role (hook/context/demo/payoff), original vs new
   length, and explicit confirmation the **payoff is included**. **Wait for my OK.** (If I said
   "just do it" in the notes, skip the wait.)
5. **Validate, then render** — first `python3 pipeline/validate_edit.py "<bundle>"` and fix
   anything it flags (a timeline gap, an out-of-range zoom, a cut landing mid-word); the
   renderer runs this too and **refuses to render an invalid EDL**. Then `python3
   pipeline/render.py "<bundle>" --preset <target>` (suggest `--preview` first — a fast,
   low-fps, caption-free structure check). Report final vs source length, resolution, and that
   captions burned in. Then offer: `open "<bundle>/final.mp4"`.

Principles: you reason over the transcript + `take.md` + frames + clicks and write `edit.json`;
ffmpeg does the pixels; sync is guaranteed by construction (cuts remove audio+video together).
Never desync, never leave gaps in the timeline, always keep a `reason` on every cut.
