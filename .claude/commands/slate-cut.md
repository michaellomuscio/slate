---
description: Shape a Slate take into a target format (social clip or course module) by writing the EDL
argument-hint: social|course [path to take bundle]
---

Shape a Slate take into a finished piece. Parse **$ARGUMENTS** for the target
(`social` = tight 30–60s vertical; `course` = full clean landscape walkthrough) and the
bundle path (default: current directory).

1. Make sure the take is ingested (run `/slate-ingest` first if there's no `transcript.json`).
   Read `take.md` and `transcript.json`; peek at `frames/` to see what's on screen.

2. **Choose the scenes with a real narrative process — this is the whole game.** Don't just
   keep "a strong 30–60s." Run the multi-lens analysis (you may invoke the
   `slate-narrative` workflow for a social-media + storytelling + marketing expert panel, or
   reason through these lenses yourself):
   - **Social-media lens:** the first 2–3 seconds must HOOK or it gets scrolled past. Open on
     the boldest claim/result, never throat-clearing ("hey, this is a test video"). Maximize
     retention; cut anything slow.
   - **Storytelling lens:** a stranger who doesn't know what you're doing must get a clear
     ARC — setup → tension → **payoff**. Protect the connective tissue that makes it cohere.
   - **Marketing lens:** make the problem→solution and the concrete takeaway obvious
     ("stop paying for X — do this instead"), and make sure the value/payoff lands.

3. **Hard rules learned the hard way:**
   - **A long silence in the middle is the AI working — NOT the end.** Cut the silence, but
     KEEP the good content after it. The payoff (the finished result being shown/described)
     often lives at the very end, after the longest gap. Re-read the transcript near the end
     of the take and make sure the payoff is in the cut — never end on the tease if a real
     payoff was recorded. (The renderer freezes the last screen frame for payoff narration
     that has no screen, so audio/camera-only payoffs are fine to keep.)
   - **Judge as a stranger.** If a first-time viewer wouldn't understand what's happening or
     why it's cool, the cut is wrong — add back the line that makes it make sense.
   - **Tight, not incoherent.** Cut boring/rambling/repeated/over-explained parts and false
     starts; keep the beats that carry the story.

4. Write a valid `edit.json` (see `EDIT_SCHEMA.md`) — `timeline` covers `[0, duration]`,
   keeps in time order, every `cut` has a `reason`. Place `zooms` on key reveals/clicks.

5. Show me: the working title, the throughline (one sentence), the narrative arc beat-by-beat,
   chosen spans with their role (hook/context/demo/payoff), and total length. Confirm the
   payoff is included. Wait for my OK, then point me to `/slate-render --preset <target>`.
