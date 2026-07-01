#!/usr/bin/env python3
"""Slate ingest: turn a raw take bundle into something Claude can reason about.

    python3 pipeline/ingest.py <bundle> [--stt auto|eleven|whisper] [--model PATH]
                                        [--verbatim] [--language eng] [--no-normalize]

Produces, inside the bundle:
  transcript.json  word-level transcript on the GLOBAL timeline + silences + disfluencies
  frames/          screenshots at clicks + scene changes + periodic, for visual context
  frames.json      index of those frames (global timestamps)

TRANSCRIPTION (see lib/transcribe.py): ElevenLabs "Scribe" is the default backend when an
API key is available — it is VERBATIM (keeps "um"/"uh"/false starts) and returns per-word
timestamps, which is exactly what filler removal needs. whisper.cpp is the offline/free
fallback (it cleans disfluencies). Force either with --stt or $SLATE_STT.

THREE belt-and-suspenders signals make filler/dead-air removal robust regardless of backend:
  1. words[]         verbatim tokens (ElevenLabs) -> the FILLERS set matches real words.
  2. silences[]      dead-air intervals (ffmpeg silencedetect) — the reliable pause signal.
  3. disfluencies[]  *voiced* gaps between words with no transcript — fillers a backend
                     dropped still make SOUND; we flag inter-word gaps carrying speech-level
                     energy. This is what lets us cut an "um" whisper deleted.

AUDIO IS PEAK-NORMALIZED FIRST. Real mic capture is often far too quiet (a real Slate take
peaked at -29.6 dB → whisper returned [BLANK_AUDIO] and silencedetect saw all-silence). We
apply a single fixed gain so the peak hits ~-1 dBFS — this preserves dynamics (silence stays
silent) while making quiet speech transcribable and the -28 dB silence threshold meaningful.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

try:
    import audioop                                  # stdlib through 3.12; C-fast DSP
except ImportError:                                 # pragma: no cover (3.13+)
    audioop = None

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle, ffmpeg_cmd, probe_duration, run
from lib import transcribe as stt

SAMPLE_RATE = 16000                                 # whisper's required input rate

# Preferred whisper models in descending quality order (bigger models retain more
# disfluencies). Used only to locate a local model file for the whisper fallback.
MODEL_PREFERENCE = ("small.en", "medium.en", "small", "medium", "base.en", "base")


def find_model(arg):
    if arg:
        return arg
    env = os.environ.get("SLATE_WHISPER_MODEL")
    if env and Path(env).exists():
        return env
    here = Path(__file__).resolve().parent
    search_dirs = [
        here / "models",
        Path.home() / "Downloads/workspace/whisper_models",
        Path("/opt/homebrew/share/whisper-cpp/models"),
    ]
    for pref in MODEL_PREFERENCE:
        for d in search_dirs:
            p = d / ("ggml-%s.bin" % pref)
            if p.exists():
                return str(p)
    raise SystemExit("No whisper model found. Pass --model PATH or set SLATE_WHISPER_MODEL.")


# ---- audio prep + envelope -------------------------------------------------

def decode_pcm16k(audio_path):
    """Decode any audio file to raw 16 kHz mono signed-16 PCM bytes (one ffmpeg pass).
    These bytes feed the STT wav, the silence detector, and the RMS envelope."""
    r = subprocess.run(
        [ffmpeg_cmd(), "-v", "error", "-i", str(audio_path),
         "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", "-"],
        capture_output=True)
    if r.returncode != 0:
        raise RuntimeError("ffmpeg decode failed:\n" + r.stderr.decode("utf-8", "replace")[-2000:])
    return r.stdout


def _peak_amplitude(pcm):
    if audioop is not None:
        return audioop.max(pcm, 2)
    m = 0
    for i in range(0, len(pcm) - 1, 2):
        s = pcm[i] | (pcm[i + 1] << 8)
        if s >= 32768:
            s -= 65536
        if abs(s) > m:
            m = abs(s)
    return m


def _apply_gain(pcm, factor):
    if audioop is not None:
        return audioop.mul(pcm, 2, factor)
    out = bytearray(len(pcm))
    for i in range(0, len(pcm) - 1, 2):
        s = pcm[i] | (pcm[i + 1] << 8)
        if s >= 32768:
            s -= 65536
        v = max(-32768, min(32767, int(s * factor)))
        out[i] = v & 0xFF
        out[i + 1] = (v >> 8) & 0xFF
    return bytes(out)


def peak_normalize(pcm, target_dbfs=-1.0, max_gain_db=40.0):
    """Apply ONE fixed gain so the loudest sample sits at `target_dbfs`. Dynamics-preserving
    (unlike loudnorm): silence stays silent, quiet speech becomes audible. Returns
    (pcm, applied_gain_db). Gain is capped so a near-silent take doesn't amplify pure noise."""
    if not pcm:
        return pcm, 0.0
    peak = _peak_amplitude(pcm)
    if peak <= 0:
        return pcm, 0.0
    cur_db = 20.0 * math.log10(peak / 32768.0)
    gain_db = min(max_gain_db, target_dbfs - cur_db)
    if gain_db <= 0.1:                              # already loud enough
        return pcm, 0.0
    return _apply_gain(pcm, 10.0 ** (gain_db / 20.0)), gain_db


def write_wav16k(pcm, dst):
    """Wrap raw 16 kHz mono s16 PCM in a WAV container STT backends will accept."""
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return dst


def _frame_rms(frame):
    if audioop is not None:
        return audioop.rms(frame, 2)
    n = len(frame) // 2
    if n == 0:
        return 0
    total = 0
    for i in range(0, n * 2, 2):
        s = frame[i] | (frame[i + 1] << 8)
        if s >= 32768:
            s -= 65536
        total += s * s
    return int((total / n) ** 0.5)


def rms_envelope(pcm, hop=0.02):
    """dBFS envelope of the audio, one value per `hop` seconds. 0 at full scale, ~-90 silent."""
    step = int(SAMPLE_RATE * hop) * 2              # bytes per frame (2 bytes/sample)
    if step <= 0:
        return [], hop
    env = []
    for i in range(0, len(pcm) - step + 1, step):
        rms = _frame_rms(pcm[i:i + step])
        db = 20.0 * math.log10(rms / 32768.0) if rms > 0 else -90.0
        env.append(db)
    return env, hop


def _percentile(values, q):
    if not values:
        return -90.0
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((q / 100.0) * (len(s) - 1)))))
    return s[k]


def find_disfluencies(words, env, hop, duration,
                      gap_min=0.18, gap_max=1.0, voiced_frac=0.60, min_margin=8.0,
                      min_voiced_run=0.12):
    """Find *voiced* gaps with no transcript — likely fillers a backend deleted.

    `words` are on the audio-local timeline (seconds). `env` is the dBFS envelope. A gap
    qualifies as a probable dropped filler ("um"/"uh"/a stutter) if it is:
      - between `gap_min` and `gap_max` long — a real dropped filler is short (<~1s); a
        multi-second "voiced" gap is almost always room tone the normalize gain lifted over
        the floor, or a long silence, NOT a swallowed word,
      - at least `voiced_frac` of its frames sit `min_margin` dB above the noise floor, AND
      - it contains a contiguous voiced run of at least `min_voiced_run` seconds (a real
        utterance is continuous, not scattered noise blips).
    With a verbatim backend (ElevenLabs) this list is usually near-empty — the fillers are
    already in words[]. The trailing tail gap (last word -> end of audio) is only emitted if
    it is itself short; a long tail is dead air, handled by the silence detector."""
    if not env:
        return []
    floor = _percentile(env, 10)
    voiced_db = max(floor + min_margin, -50.0)

    def measure(a, b):
        i0 = max(0, int(a / hop))
        i1 = min(len(env), int(math.ceil(b / hop)))
        if i1 <= i0:
            return 0.0, -90.0, 0.0
        seg = env[i0:i1]
        voiced = sum(1 for d in seg if d > voiced_db)
        # longest contiguous voiced run, in seconds
        best = run = 0
        for d in seg:
            if d > voiced_db:
                run += 1
                if run > best:
                    best = run
            else:
                run = 0
        return voiced / len(seg), max(seg), best * hop

    gaps = []
    prev_end = 0.0
    prev_w = None
    for w in words:
        gaps.append((prev_end, w["start"], prev_w, w["w"]))
        prev_end = max(prev_end, w["end"])
        prev_w = w["w"]
    # Trailing tail (last word -> end of audio): only a candidate if it's short. A long tail
    # is dead air / room tone, never a dropped filler — emitting it produces a bogus 55s "gap".
    if duration - prev_end <= gap_max:
        gaps.append((prev_end, duration, prev_w, None))

    out = []
    for a, b, lw, rw in gaps:
        dur = b - a
        if dur < gap_min or dur > gap_max:
            continue
        frac, peak, voiced_run = measure(a, b)
        if frac >= voiced_frac and voiced_run >= min_voiced_run:
            between = [x for x in (lw, rw) if x]
            out.append({"start": round(a, 3), "end": round(b, 3),
                        "dur": round(dur, 3), "peakDb": round(peak, 1),
                        "voicedFrac": round(frac, 2), "between": between})
    return out


def detect_silences(wav_path, noise_db=-28, min_dur=0.22):
    """Dead-air intervals via ffmpeg silencedetect. Run on the PEAK-NORMALIZED wav so the
    -28 dB threshold is meaningful even for originally-quiet takes."""
    r = subprocess.run(
        [ffmpeg_cmd(), "-hide_banner", "-i", str(wav_path),
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


def extract_frames(b, out_dir, duration, periodic=5.0, max_frames=None):
    """Pull screenshots at clicks + scene changes + a periodic fallback, for visual context.

    Frames are BUDGETED so they span the WHOLE take, not just its opening. The budget scales
    with duration (`max_frames = max(60, duration/3)`), and when the budget is tight, click +
    scene-change frames (the meaningful anchors) are kept in preference to the periodic grid —
    otherwise a naive time-sort lets the first ~60 periodic frames of a long take win and the
    finale is never seen. Each frame is tagged with a `reason` (click|scene|periodic) so the
    digest can label it.

    NOTE: ScreenCaptureKit screen.mov is variable-frame-rate (delivers only on screen
    change), so an input-seek can land on a frame up to ~1s stale inside a static gap — fine
    for context, not for frame-accurate work."""
    screen = b.stream_path("screen")
    if not screen:
        return []
    out_dir.mkdir(exist_ok=True)
    screen_end = b.stream_end("screen") or duration
    if max_frames is None:
        max_frames = max(60, int(duration / 3))

    # Candidate times tagged by reason, priority: click > scene > periodic. Later duplicate
    # times for the same instant lose to the higher-priority reason already recorded.
    reason = {}
    def add(gt, why):
        gt = round(gt, 2)
        prio = {"click": 0, "scene": 1, "periodic": 2}
        if gt not in reason or prio[why] < prio[reason[gt]]:
            reason[gt] = why

    for e in b.clicks():
        add(float(e["t"]), "click")
    r = subprocess.run(
        [ffmpeg_cmd(), "-hide_banner", "-i", str(screen),
         "-vf", "select='gt(scene,0.4)',showinfo", "-vsync", "vfr", "-f", "null", "-"],
        capture_output=True, text=True)
    for m in re.findall(r"pts_time:([\d.]+)", r.stderr):
        add(b.to_global("screen", float(m)), "scene")
    t = 0.0
    while t < duration:
        add(t, "periodic")
        t += periodic

    # Drop times past the screen's own end (can't seek there), then select within budget so
    # coverage spans the whole take: keep ALL click+scene anchors, then fill with periodic
    # frames spread evenly across the timeline (stride the sorted periodic list).
    cand = [(gt, why) for gt, why in reason.items() if gt <= screen_end]
    anchors = sorted([c for c in cand if c[1] != "periodic"])
    periodics = sorted([c for c in cand if c[1] == "periodic"])
    room = max(0, max_frames - len(anchors))
    if room < len(periodics) and periodics:
        n = len(periodics)
        if room <= 1:
            periodics = [periodics[-1]]              # keep the finale over the opening
        else:
            # even sample INCLUDING both endpoints so coverage reaches the take's end
            idx = sorted({int(round(i * (n - 1) / (room - 1))) for i in range(room)})
            periodics = [periodics[i] for i in idx]
    chosen = sorted(set(anchors) | set(periodics))

    frames = []
    for gt, why in chosen:
        local = b.to_local("screen", gt)
        name = "f_%06d.jpg" % int(gt * 1000)
        try:
            run([ffmpeg_cmd(), "-y", "-ss", "%.3f" % local, "-i", str(screen),
                 "-frames:v", "1", "-vf", "scale=960:-1", str(out_dir / name)])
            frames.append({"t": gt, "file": "frames/" + name, "reason": why})
        except RuntimeError:
            pass
    return frames


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--stt", choices=["auto", "eleven", "whisper"], default="auto",
                    help="transcription backend (default: ElevenLabs if a key is found, else whisper)")
    ap.add_argument("--model", default=None, help="whisper model path (fallback backend)")
    ap.add_argument("--verbatim", action="store_true", help="bias whisper toward keeping fillers")
    ap.add_argument("--language", default="eng", help="ISO language code (eng); '' = auto-detect")
    ap.add_argument("--no-normalize", action="store_true", help="skip peak-normalization")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    audio = b.stream_path("audio")
    if not audio:
        raise SystemExit("Bundle has no audio.wav — nothing to transcribe.")
    off = b.offset("audio")

    explicit = None if args.stt == "auto" else args.stt
    key = stt.find_elevenlabs_key()
    backend = stt.resolve_backend(explicit, key)

    # Locate a whisper model for the whisper backend or as the auto-mode fallback.
    model = None
    try:
        model = find_model(args.model)
    except SystemExit:
        if backend == "whisper":
            raise                                   # whisper backend genuinely needs a model

    with tempfile.TemporaryDirectory() as tmp:
        pcm = decode_pcm16k(audio)
        gain_db = 0.0
        if not args.no_normalize:
            pcm, gain_db = peak_normalize(pcm)
            if gain_db > 0:
                print("Normalized audio: +%.1f dB (mic was quiet)" % gain_db)
        wav16k = write_wav16k(pcm, Path(tmp) / "audio16k.wav")

        try:
            result = stt.transcribe(wav16k, backend=explicit, key=key, model=model,
                                    verbatim=args.verbatim, language=args.language)
        except stt.TranscriptionError as e:
            raise SystemExit("Transcription failed: %s" % e)

        words_local = result.get("words", [])
        env, hop = rms_envelope(pcm)
        dur_local = len(pcm) / 2.0 / SAMPLE_RATE
        disfl_local = find_disfluencies(words_local, env, hop, dur_local)
        silences_local = detect_silences(wav16k)

    # local audio clock -> global timeline (add the audio startOffset)
    words = [{"w": w["w"], "start": round(w["start"] + off, 3),
              "end": round(w["end"] + off, 3), "p": round(w.get("p", 1.0), 3)}
             for w in words_local]
    segments = [{"text": s["text"], "start": round(s["start"] + off, 3),
                 "end": round(s["end"] + off, 3)} for s in result.get("segments", [])]
    audio_events = [{"text": a["text"], "start": round(a["start"] + off, 3),
                     "end": round(a["end"] + off, 3)} for a in result.get("audioEvents", [])]
    silences = [{"start": round(s["start"] + off, 3), "end": round(s["end"] + off, 3),
                 "dur": s["dur"]} for s in silences_local]
    disfluencies = [{**d, "start": round(d["start"] + off, 3),
                     "end": round(d["end"] + off, 3)} for d in disfl_local]

    lang = result.get("language", "en")
    if lang == "eng":                               # ISO-639-3 -> 2 for consistency
        lang = "en"

    transcript = {
        "audioStartOffset": off,
        "duration": round(b.timeline_end(), 3),     # authoritative end = end of narration spine (audio)
        "stt": result.get("backend", "?"),          # provenance engine; digest.py reads key "stt"
        "language": lang,
        "text": (result.get("text") or "").strip(),
        "words": words,
        "segments": segments,
        "silences": silences,
        "disfluencies": disfluencies,
        "audioEvents": audio_events,
    }
    if gain_db > 0:
        transcript["audioGainDb"] = round(gain_db, 1)
    b.write_json("transcript.json", transcript)

    print("Extracting frames ...")
    frames = extract_frames(b, b.file("frames"), b.timeline_end())
    b.write_json("frames.json", {"frames": frames})

    text = transcript["text"]
    print("\nIngest complete  (backend: %s):" % transcript["stt"])
    print("  words:        %d" % len(words))
    print("  segments:     %d" % len(segments))
    print("  silences:     %d  (>=0.22s dead air)" % len(silences))
    print("  disfluencies: %d  (voiced gaps — probable hidden fillers)" % len(disfluencies))
    if audio_events:
        print("  audioEvents:  %d  (laughter / noises, tagged not transcribed)" % len(audio_events))
    print("  frames:       %d" % len(frames))
    print("  text:         %s" % (text[:90] + ("…" if len(text) > 90 else "")))


if __name__ == "__main__":
    main()
