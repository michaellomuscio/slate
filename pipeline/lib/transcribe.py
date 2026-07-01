"""Pluggable speech-to-text for Slate ingest — two backends, one normalized schema.

Both backends return WORDS on the audio's own LOCAL timeline (seconds from the start of
audio.wav). `ingest.py` shifts them onto the global timeline by adding the audio
startOffset. Normalized shape:

    {
      "backend":  "elevenlabs" | "whisper",
      "language": "en",
      "text":     "full transcript ...",
      "words":    [{"w": "Hey", "start": 0.16, "end": 0.26, "p": 0.99}, ...],
      "segments": [{"text": "Hey everyone.", "start": 0.16, "end": 1.70}, ...],
      "audioEvents": [{"text": "(laughter)", "start": 8.1, "end": 8.6}],   # eleven only
    }

WHY TWO BACKENDS
----------------
whisper.cpp (small.en) CLEANS disfluencies — it silently deletes "um"/"uh"/false starts.
That breaks transcript-driven filler removal (you can't cut a word you can't see).
ElevenLabs "Scribe" (scribe_v1) is VERBATIM: it keeps fillers and returns per-word
timestamps + a logprob, so `propose_edit.py`'s FILLERS set finally matches real tokens and
cuts can be word-accurate. Proven on Slate's own test clip:
    Scribe : "...welcome back. Um, today... Uh, the first thing... So, um, let's click..."
    Whisper: "...welcome back. Today... The first thing... So, let's click..."   (0 fillers)

So: ElevenLabs is the default when a key is present; whisper is the offline/free fallback.
Selection order:  explicit arg  >  $SLATE_STT  >  (elevenlabs if key else whisper).

Python 3.9 stdlib only (urllib for the multipart upload — no requests, no SDK).
"""
from __future__ import annotations

import json
import math
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

SPECIAL_TOKEN = re.compile(r"^\[_.*\]$")            # whisper [_BEG_], [_TT_300], ...
SCRIBE_URL = "https://api.elevenlabs.io/v1/speech-to-text"
SCRIBE_MODEL = "scribe_v1"

# Scribe sometimes reports an audio_event (e.g. a tongue-click) as spanning the whole
# following silence. Clamp any audio_event to this many seconds so take.md isn't misled.
AUDIO_EVENT_MAX = 1.0

# whisper.cpp -dtw alignment presets; the preset must match the model or token timestamps
# degrade (and our disfluency detector leans on accurate word boundaries).
DTW_PRESETS = {"tiny", "tiny.en", "base", "base.en", "small", "small.en",
               "medium", "medium.en", "large.v1", "large.v2", "large.v3", "large"}

VERBATIM_PROMPT = ("Um, uh, hmm, well, so, like, you know, I mean. "
                   "Include filler words, false starts, and stutters exactly as spoken.")


class TranscriptionError(RuntimeError):
    """Raised when a backend fails; ingest catches this to fall back."""


# ---------------------------------------------------------------------------
# Backend selection + key discovery
# ---------------------------------------------------------------------------

def find_elevenlabs_key(explicit=None):
    """Locate the ElevenLabs API key without ever hardcoding it.

    Order: explicit arg > $SLATE_ELEVENLABS_API_KEY > $ELEVENLABS_API_KEY >
    a handful of on-disk .env files (the cass channel env is already on this Mac)."""
    if explicit:
        return explicit.strip()
    for var in ("SLATE_ELEVENLABS_API_KEY", "ELEVENLABS_API_KEY"):
        v = os.environ.get(var)
        if v and v.strip():
            return v.strip()
    candidates = [
        Path.home() / ".config/slate/.env",
        Path.home() / ".claude/channels/telegram/.env",
    ]
    for env in candidates:
        try:
            if not env.exists():
                continue
            for line in env.read_text().splitlines():
                line = line.strip()
                if line.startswith("ELEVENLABS_API_KEY") and "=" in line:
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            continue
    return None


def resolve_backend(explicit=None, key=None):
    """Decide which backend to use. Returns 'elevenlabs' or 'whisper'."""
    choice = (explicit or os.environ.get("SLATE_STT") or "").strip().lower()
    if choice in ("eleven", "elevenlabs", "scribe"):
        return "elevenlabs"
    if choice in ("whisper", "local", "offline"):
        return "whisper"
    return "elevenlabs" if key else "whisper"


# ---------------------------------------------------------------------------
# ElevenLabs Scribe
# ---------------------------------------------------------------------------

def _multipart(fields, file_field, filename, file_bytes, content_type):
    boundary = "----SlateBoundaryQ8x2Lp9Zr4Kv"
    crlf = "\r\n"
    out = []
    for k, v in fields.items():
        out.append(("--" + boundary + crlf).encode())
        out.append(('Content-Disposition: form-data; name="%s"%s%s' % (k, crlf, crlf)).encode())
        out.append((str(v) + crlf).encode())
    out.append(("--" + boundary + crlf).encode())
    out.append(('Content-Disposition: form-data; name="%s"; filename="%s"%s'
                % (file_field, filename, crlf)).encode())
    out.append(("Content-Type: %s%s%s" % (content_type, crlf, crlf)).encode())
    out.append(file_bytes)
    out.append(crlf.encode())
    out.append(("--" + boundary + "--" + crlf).encode())
    return b"".join(out), boundary


def scribe_raw(wav_path, key, language="eng", tag_audio_events=True, diarize=False,
               model_id=SCRIBE_MODEL, timeout=600):
    """POST a wav to ElevenLabs Scribe; return the parsed JSON. Retries once on
    transient (timeout / 5xx) errors."""
    fields = {
        "model_id": model_id,
        "timestamps_granularity": "word",
        "tag_audio_events": "true" if tag_audio_events else "false",
        "diarize": "true" if diarize else "false",
    }
    if language:
        fields["language_code"] = language
    body, boundary = _multipart(fields, "file", Path(wav_path).name,
                                Path(wav_path).read_bytes(), "audio/wav")
    last = None
    for attempt in range(2):
        req = urllib.request.Request(SCRIBE_URL, data=body, method="POST")
        req.add_header("xi-api-key", key)
        req.add_header("Content-Type", "multipart/form-data; boundary=" + boundary)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:800]
            last = "HTTP %s: %s" % (e.code, detail)
            if e.code < 500:            # client errors won't fix on retry
                break
        except Exception as e:          # noqa: BLE001 — surface network/parse issues
            last = repr(e)
    raise TranscriptionError("ElevenLabs Scribe failed: %s" % last)


def _prob_from_logprob(lp):
    if not isinstance(lp, (int, float)):
        return 1.0
    try:
        return max(0.0, min(1.0, math.exp(lp)))
    except (OverflowError, ValueError):
        return 1.0


def normalize_scribe(raw):
    """Scribe JSON -> Slate's normalized schema (audio-LOCAL timeline)."""
    words, audio_events = [], []
    for tok in raw.get("words", []) or []:
        typ = tok.get("type", "word")
        text = (tok.get("text") or "").strip()
        if not text:
            continue
        try:
            start = float(tok.get("start"))
            end = float(tok.get("end"))
        except (TypeError, ValueError):
            continue
        if typ == "word":
            words.append({"w": text, "start": round(start, 3), "end": round(end, 3),
                          "p": round(_prob_from_logprob(tok.get("logprob")), 3)})
        elif typ == "audio_event":
            # Scribe often stretches a brief noise (a tongue-click) across a long silent gap,
            # reporting spans of 10-20s+. Those are meaningless and misleading in take.md, so
            # clamp the reported duration to ~1s anchored at the event's start.
            end = min(end, start + AUDIO_EVENT_MAX)
            audio_events.append({"text": text, "start": round(start, 3), "end": round(end, 3)})
        # "spacing" tokens carry no content — skip.

    segments = _segments_from_words(words)
    text = (raw.get("text") or "").strip()
    if not text:
        text = " ".join(w["w"] for w in words)
    return {
        "backend": "elevenlabs",
        "language": (raw.get("language_code") or "en"),
        "text": text,
        "words": words,
        "segments": segments,
        "audioEvents": audio_events,
    }


def _segments_from_words(words, gap=0.8):
    """Group words into caption-ish sentences: break on terminal punctuation or a pause."""
    segments, cur = [], []
    for i, w in enumerate(words):
        cur.append(w)
        ends_sentence = w["w"][-1:] in ".?!"
        next_gap = (words[i + 1]["start"] - w["end"]) if i + 1 < len(words) else 1e9
        if ends_sentence or next_gap > gap:
            segments.append({"text": " ".join(x["w"] for x in cur),
                             "start": cur[0]["start"], "end": cur[-1]["end"]})
            cur = []
    if cur:
        segments.append({"text": " ".join(x["w"] for x in cur),
                         "start": cur[0]["start"], "end": cur[-1]["end"]})
    return segments


# ---------------------------------------------------------------------------
# whisper.cpp (whisper-cli)
# ---------------------------------------------------------------------------

def dtw_preset(model_path):
    """Derive the -dtw preset from a model filename, e.g. 'ggml-small.en.bin' -> 'small.en'.

    whisper.cpp is picky here: the preset must be the DOTTED spelling ('large.v3'), but
    ggml filenames use HYPHENS ('ggml-large-v3.bin') — and whisper-cli hard-errors on the
    hyphen form. Quantized artifacts ('ggml-small.en-q5_0.bin') carry a '-qN' tag that is
    never a valid preset. So: strip prefix/suffix, drop the quant tag, convert 'large-vN'
    to 'large.vN', then check membership. Returns None (run without -dtw) if no match."""
    name = Path(model_path).name
    name = re.sub(r"^ggml-", "", name)
    name = re.sub(r"\.bin$", "", name)
    name = re.sub(r"-q\d.*$", "", name)            # drop quantization suffix
    name = re.sub(r"^large-v(\d)$", r"large.v\1", name)   # hyphen -> dotted for large.vN
    return name if name in DTW_PRESETS else None


def whisper_raw(wav_path, model, verbatim=False):
    """Run whisper-cli on a 16 kHz wav; return its JSON (audio-local timeline)."""
    with tempfile.TemporaryDirectory() as tmp:
        of = os.path.join(tmp, "out")
        cmd = ["whisper-cli", "-m", str(model), "-f", str(wav_path),
               "-ojf", "-of", of, "-l", "en"]
        preset = dtw_preset(model)
        if preset:
            cmd += ["-dtw", preset]
        if verbatim:
            cmd += ["--prompt", VERBATIM_PROMPT]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise TranscriptionError("whisper-cli failed (%d):\n%s"
                                     % (r.returncode, (r.stderr or "")[-1500:]))
        with open(of + ".json") as f:
            return json.load(f)


def normalize_whisper(raw):
    """whisper-cli JSON -> Slate's normalized schema (audio-LOCAL timeline)."""
    words = []
    for seg in raw.get("transcription", []):
        for tok in seg.get("tokens", []):
            txt = tok.get("text", "")
            if SPECIAL_TOKEN.match(txt.strip()):
                continue
            off = tok.get("offsets") or {}
            if "from" not in off or "to" not in off:
                continue
            w = txt.strip()
            if not w:
                continue
            words.append({
                "w": w,
                "start": round(off["from"] / 1000.0, 3),
                "end": round(off["to"] / 1000.0, 3),
                "p": round(float(tok.get("p", 1.0)), 3),
            })
    segments = [{
        "text": re.sub(r"\[_.*?\]", "", seg.get("text", "")).strip(),
        "start": round(seg["offsets"]["from"] / 1000.0, 3),
        "end": round(seg["offsets"]["to"] / 1000.0, 3),
    } for seg in raw.get("transcription", []) if seg.get("offsets")]
    text = " ".join(s["text"] for s in segments).strip()
    return {
        "backend": "whisper",
        "language": "en",
        "text": text,
        "words": words,
        "segments": segments,
        "audioEvents": [],
    }


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def transcribe(wav16k_path, *, backend=None, key=None, model=None,
               verbatim=False, language="eng", on_log=print):
    """Transcribe a 16 kHz mono wav. Returns the normalized schema (audio-local times).

    `backend` may be forced ('elevenlabs'/'whisper'); otherwise auto-selected. ElevenLabs
    failures fall back to whisper automatically when a model is available."""
    key = key or find_elevenlabs_key()
    chosen = resolve_backend(backend, key)

    if chosen == "elevenlabs":
        if not key:
            raise TranscriptionError("ElevenLabs backend requested but no API key found "
                                     "(set ELEVENLABS_API_KEY or use --stt whisper).")
        try:
            on_log("Transcribing with ElevenLabs Scribe (%s) ..." % SCRIBE_MODEL)
            result = normalize_scribe(scribe_raw(wav16k_path, key, language=language))
            if result["words"]:
                return result
            on_log("  Scribe returned no words (no speech?) — trying whisper.")
        except TranscriptionError as e:
            on_log("  ElevenLabs failed (%s)." % e)
        if not model:
            # No fallback model available — return whatever Scribe gave (possibly empty).
            return normalize_scribe(scribe_raw(wav16k_path, key, language=language))
        on_log("  Falling back to local whisper.")

    on_log("Transcribing with whisper %s (dtw=%s) ..."
           % (os.path.basename(str(model)), dtw_preset(model) or "off"))
    return normalize_whisper(whisper_raw(wav16k_path, model, verbatim=verbatim))
