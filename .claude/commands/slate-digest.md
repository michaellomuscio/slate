---
description: Build/refresh take.md + contact_sheet.jpg for a Slate take, then summarize it
argument-hint: [path to take bundle, defaults to current dir]
---

Make a Slate take legible at a glance. Bundle: **$ARGUMENTS** (if empty, current directory).

1. Run: `python3 ~/projects/screen-recorder/pipeline/digest.py "<bundle>"`
   (writes `take.md` and, if frames exist, `contact_sheet.jpg`).
2. Read `take.md`. If `contact_sheet.jpg` exists, look at it to see the whole recording at once;
   open individual `frames/` if you need a closer look at a moment.
3. Give me a tight read of the take:
   - what it's about and how long
   - **audio health** — if it's flagged TOO QUIET, say so plainly
   - the app/chapter timeline and any notable clicks
   - how much dead air / filler there is, and whether it's worth cleaning
4. Recommend the next step: `/slate-strip-filler`, `/slate-cut social|course`, or `/slate`.

If there's no `transcript.json` yet, tell me to run `/slate-ingest` first.
