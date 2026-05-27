---
description: Propose dead-air/filler cuts for a Slate take, then review & refine the EDL
argument-hint: [path to take bundle, defaults to current dir]
---

Clean up a Slate take by removing dead air and fillers. Bundle: **$ARGUMENTS**
(if empty, current directory).

1. Run the deterministic first pass:
   `python3 ~/projects/screen-recorder/pipeline/propose_edit.py "<bundle>"`
   (add `--mode silence` if I asked to keep length and just mute fillers instead of cutting.)
2. Read `transcript.json` and the proposed `edit.json`. **Review the cuts as an editor:**
   - Protect intentional/emphasis pauses — don't cut every silence to nothing.
   - Catch what silence-detection can't: false starts, repeated sentences, a tangent that
     should go. Add those as `cut` segments with a `reason`.
   - Make sure the timeline still covers `[0, duration]` with no gaps (see `EDIT_SCHEMA.md`).
3. If you change anything, rewrite `edit.json` (keep it valid per `EDIT_SCHEMA.md`).
4. Show me a short before/after: original length, time removed, new length, and the list of
   cuts with reasons. Wait for my OK, then point me to `/slate-render`.

Don't render yet — just propose and let me approve the edit.
