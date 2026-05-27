#!/usr/bin/env python3
"""Slate ingest: turn a raw take bundle into something Claude can reason about.

    python3 pipeline/ingest.py <bundle> [--model PATH] [--verbatim]

Produces, inside the bundle:
  transcript.json  word-level transcript on the GLOBAL timeline + silence intervals
  frames/          screenshots at clicks + scene changes + periodic, for visual context
  frames.json      index of those frames (global timestamps)

Whisper (base.en) tends to clean disfluencies, so transcript-only filler detection is
unreliable. We therefore also record audio silence intervals (the dependable dead-air /
dropped-filler signal) for the edit-proposal stage. Pass --verbatim to bias whisper toward
keeping fillers via an initial prompt.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle, probe_duration, run

SPECIAL_TOKEN = re.compile(r'^\[_.*\]$')          # [_BEG_], [_EOT_], [_TT_300], ...
VERBATIM_PROMPT = "Um, uh, hmm, so, like, you know, I mean, well,"

KNOWN_MODEL_FALLBACKS = [
    str(Path.home() / "Downloads/workspace/whisper_models/ggml-base.en.bin"),
]


def find_model(arg):
    cands = []
    if arg:
        cands.append(arg)
    if os.environ.get("SLATE_WHISPER_MODEL"):
        cands.append(os.environ["SLATE_WHISPER_MODEL"])
    here = Path(os.path.dirname(os.path.abspath(__file__)))
    cands += sorted(glob.glob(str(here / "models" / "ggml-*.bin")))
    cands += KNOWN_MODEL_FALLBACKS
    cands += sorted(glob.glob("/opt/homebrew/share/whisper-cpp/models/ggml-*.bin"))
    for c in cands:
        if c and Path(c).exists():
            return c
    raise SystemExit("No whisper model found. Pass --model PATH or set SLATE_WHISPER_MODEL.")


def transcribe(audio_path, model, verbatim):
    with tempfile.TemporaryDirectory() as tmp:
        of = os.path.join(tmp, "out")
        cmd = ["whisper-cli", "-m", model, "-f", str(audio_path), "-ojf", "-of", of,
               "-dtw", "base.en", "-l", "en"]
        if verbatim:
            cmd += ["--prompt", VERBATIM_PROMPT]
        run(cmd)
        return json.loads(Path(of + ".json").read_text())


def words_from_whisper(data):
    """Merge whisper tokens into words on the audio-local timeline (seconds)."""
    words = []
    cur = None
    for seg in data.get("transcription", []):
        for tok in seg.get("tokens", []):
            raw = tok.get("text", "")
            if SPECIAL_TOKEN.match(raw.strip()):
                continue
            clean = raw.strip()
            if not clean:
                continue
            start = tok["offsets"]["from"] / 1000.0
            end = tok["offsets"]["to"] / 1000.0
            p = tok.get("p", 0.0)
            if raw.startswith(" "):                # leading space => new word
                if cur:
                    words.append(cur)
                cur = {"w": clean, "start": start, "end": end, "p": p}
            else:                                  # subword / punctuation => attach
                if cur is None:
                    cur = {"w": clean, "start": start, "end": end, "p": p}
                else:
                    cur["w"] += clean
                    cur["end"] = end
    if cur:
        words.append(cur)
    return words


def detect_silences(audio_path, noise_db=-30, min_dur=0.35):
    r = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(audio_path),
         "-af", "silencedetect=noise=%ddB:duration=%s" % (noise_db, min_dur), "-f", "null", "-"],
        capture_output=True, text=True)
    out = r.stderr
    starts = [float(m) for m in re.findall(r"silence_start: ([\d.]+)", out)]
    ends = [float(m) for m in re.findall(r"silence_end: ([\d.]+)", out)]
    pairs = []
    for i, s in enumerate(starts):
        e = ends[i] if i < len(ends) else None
        if e is not None:
            pairs.append({"start": round(s, 3), "end": round(e, 3),
                          "dur": round(e - s, 3)})
    return pairs


def extract_frames(b, out_dir, duration, periodic=5.0, max_frames=60):
    screen = b.stream_path("screen")
    if not screen:
        return []
    out_dir.mkdir(exist_ok=True)
    times = set()
    for e in b.clicks():
        times.add(round(float(e["t"]), 2))
    # scene changes (global time)
    r = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(screen),
         "-vf", "select='gt(scene,0.4)',showinfo", "-vsync", "vfr", "-f", "null", "-"],
        capture_output=True, text=True)
    for m in re.findall(r"pts_time:([\d.]+)", r.stderr):
        times.add(round(b.to_global("screen", float(m)), 2))
    # periodic fallback
    t = 0.0
    while t < duration:
        times.add(round(t, 2))
        t += periodic

    frames = []
    for gt in sorted(times)[:max_frames]:
        local = b.to_local("screen", gt)
        name = "f_%06d.jpg" % int(gt * 1000)
        try:
            run(["ffmpeg", "-y", "-ss", "%.3f" % local, "-i", str(screen),
                 "-frames:v", "1", "-vf", "scale=960:-1", str(out_dir / name)])
            frames.append({"t": gt, "file": "frames/" + name})
        except RuntimeError:
            pass
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--model", default=None)
    ap.add_argument("--verbatim", action="store_true",
                    help="bias whisper toward keeping fillers")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    audio = b.stream_path("audio")
    if not audio:
        raise SystemExit("Bundle has no audio.wav — nothing to transcribe.")

    model = find_model(args.model)
    print("Transcribing with", os.path.basename(model), "...")
    data = transcribe(audio, model, args.verbatim)

    off = b.offset("audio")
    words = words_from_whisper(data)
    for w in words:                                # local -> global timeline
        w["start"] = round(w["start"] + off, 3)
        w["end"] = round(w["end"] + off, 3)
        w["p"] = round(w["p"], 3)

    segments = []
    for seg in data.get("transcription", []):
        segments.append({
            "text": re.sub(r"\[_.*?\]", "", seg.get("text", "")).strip(),
            "start": round(seg["offsets"]["from"] / 1000.0 + off, 3),
            "end": round(seg["offsets"]["to"] / 1000.0 + off, 3),
        })

    dur = probe_duration(audio)
    silences = [{"start": round(s["start"] + off, 3), "end": round(s["end"] + off, 3),
                 "dur": s["dur"]} for s in detect_silences(audio)]

    transcript = {
        "audioStartOffset": off,
        "duration": round(dur + off, 3),
        "language": data.get("params", {}).get("language", "en"),
        "text": " ".join(s["text"] for s in segments).strip(),
        "words": words,
        "segments": segments,
        "silences": silences,
    }
    b.write_json("transcript.json", transcript)

    print("Extracting frames ...")
    frames = extract_frames(b, b.file("frames"), dur)
    b.write_json("frames.json", {"frames": frames})

    print("\nIngest complete:")
    print("  words:    %d" % len(words))
    print("  segments: %d" % len(segments))
    print("  silences: %d  (>=0.35s)" % len(silences))
    print("  frames:   %d" % len(frames))
    print("  text:     %s" % (transcript["text"][:90] + ("…" if len(transcript["text"]) > 90 else "")))


if __name__ == "__main__":
    main()
