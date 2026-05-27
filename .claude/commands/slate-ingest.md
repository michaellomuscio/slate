---
description: Ingest a Slate take bundle — transcribe (word-level) + detect silences + extract frames
argument-hint: [path to take bundle, defaults to current dir]
---

Ingest the Slate take bundle so it becomes editable. Bundle path: **$ARGUMENTS**
(if empty, use the current directory).

1. Run: `python3 ~/projects/screen-recorder/pipeline/ingest.py "<bundle>"`
2. Report the summary it prints (words, segments, silences, frames).
3. Read `transcript.json` and give me a 1–2 sentence read on the take: what it's about,
   roughly how long, and whether there's a lot of dead air / fillers to clean.
4. Tell me the next step is `/slate-strip-filler` (to clean it) or `/slate-cut` (to shape a
   social clip or course module).

If ingest fails on the whisper model, tell me — I may need to point `--model` at one.
