---
description: Shape a Slate take into a target format (social clip or course module) by writing the EDL
argument-hint: social|course [path to take bundle]
---

Shape a Slate take into a finished piece. Parse **$ARGUMENTS** for the target
(`social` = tight 30–60s vertical; `course` = full clean landscape walkthrough) and the
bundle path (default: current directory).

1. Make sure the take is ingested (run `/slate-ingest` first if there's no `transcript.json`).
2. Read `transcript.json` (and peek at `frames/` if you need to see what's on screen).
3. **This is the judgment step — do real editorial work:**
   - For **social**: find the single strongest 30–60s — a complete thought with a hook.
     Set everything else to `cut`. Tighten ruthlessly. `preset: "social"`.
   - For **course**: keep the full walkthrough but remove dead air, fillers, flubs, and
     dead tangents. Keep it coherent and well-paced. `preset: "course"`.
   - Place `zooms` on the moments that matter (clicks from the event log, key reveals).
4. Write a valid `edit.json` (see `EDIT_SCHEMA.md`) — timeline covering `[0, duration]`,
   cuts with `reason`s.
5. Show me the resulting structure: chosen spans, total length, the narrative arc in a few
   bullets. Wait for my OK, then point me to `/slate-render --preset <target>`.
