---
description: Ingest a Slate take bundle — transcribe (verbatim, word-level) + silences/disfluencies + frames
argument-hint: [path to take bundle, defaults to current dir]
---

Ingest the Slate take bundle so it becomes editable. Bundle path: **$ARGUMENTS**
(if empty, use the current directory).

1. Run: `python3 ~/projects/screen-recorder/pipeline/ingest.py "<bundle>"`
   - It peak-normalizes the audio first (so a quiet mic still transcribes), then uses
     **ElevenLabs Scribe** if a key is available — verbatim, so "um/uh" are kept with word
     timestamps — else falls back to local whisper. Force with `--stt eleven|whisper`.
2. Report the summary it prints (backend, words, segments, silences, disfluencies, frames).
   If it printed a `+N dB` normalization, the mic was quiet — mention it.
3. Generate the digest so you (Claude) can actually see the take:
   `python3 ~/projects/screen-recorder/pipeline/digest.py "<bundle>"`, then read `take.md`
   and give me a 1–2 sentence read: what it's about, how long, audio health, and whether
   there's a lot of dead air / filler to clean.
4. Tell me the next step is `/slate-strip-filler` (to clean) or `/slate-cut social|course`
   (to shape) — or just `/slate <target>` to do everything at once.

If transcription fails on a missing key/model, tell me — I can point `--model` at one or
set `--stt whisper` for fully-offline.
