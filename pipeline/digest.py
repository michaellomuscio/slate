#!/usr/bin/env python3
"""Slate take digest: turn a take bundle into ONE human + Claude readable markdown brief.

    python3 pipeline/digest.py <bundle> [--print]

Writes `take.md` into the bundle. This is the "understandable by Claude Code" artifact —
everything you'd need to reason about a recording WITHOUT watching it: what was on screen
(app timeline + frames), what was said (transcript on the global clock), where the clicks
were (auto-zoom anchors), and where the dead air / fillers are (edit candidates). It also
runs an audio-health check and FLAGS problems (e.g. mic recorded too quiet to transcribe).

Safe to run before or after ingest: with no transcript.json it still summarizes streams,
events, and audio health, and tells you to run /slate-ingest.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle, ffprobe_cmd, ffmpeg_cmd, probe_duration, run


def fmt_t(t):
    t = max(0.0, float(t))
    m, s = divmod(t, 60)
    return "%d:%05.2f" % (int(m), s) if m else "%.2fs" % s


def audio_health(wav):
    """Peak/RMS dBFS via ffmpeg astats. Returns (peak_db, rms_db) or (None, None)."""
    if not wav or not Path(wav).exists():
        return None, None
    try:
        r = subprocess.run([ffmpeg_cmd(), "-hide_banner", "-i", str(wav),
                            "-af", "astats=metadata=0", "-f", "null", "-"],
                           capture_output=True, text=True)
        peak = rms = None
        for line in r.stderr.splitlines():
            m = re.search(r"Peak level dB:\s*(-?[\d.]+|-?inf)", line)
            if m and peak is None:
                peak = float(m.group(1)) if "inf" not in m.group(1) else -120.0
            m = re.search(r"RMS level dB:\s*(-?[\d.]+|-?inf)", line)
            if m and rms is None:
                rms = float(m.group(1)) if "inf" not in m.group(1) else -120.0
        return peak, rms
    except Exception:
        return None, None


def nearest_words(words, t, span=1.2):
    """A short phrase of transcript around time t (global), for labeling clicks."""
    hits = [w["w"] for w in words if abs(((w["start"] + w["end"]) / 2.0) - t) <= span]
    return " ".join(hits[:8]).strip()


def contact_sheet(b, frames):
    """Tile the extracted frames into ONE image (time order, left→right top→bottom) so the
    whole recording can be grasped — by a human or by Claude — in a single look. Pairs with
    the timestamped frame list in take.md."""
    if not frames:
        return None
    fr_glob = str(b.file("frames") / "f_*.jpg")
    n = len(frames)
    cols = min(5, n)
    rows = (n + cols - 1) // cols
    out = b.path / "contact_sheet.jpg"
    try:
        run([ffmpeg_cmd(), "-y", "-pattern_type", "glob", "-i", fr_glob,
             "-vf", "scale=360:-1,tile=%dx%d:padding=6:margin=6:color=0x1b1b1b" % (cols, rows),
             "-frames:v", "1", str(out)])
        return "contact_sheet.jpg"
    except RuntimeError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--print", action="store_true", dest="echo", help="also print to stdout")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    meta = b.meta
    events = b.events()
    tr = b.load_transcript() or {}
    frames = (b._load_json("frames.json", required=False) or {}).get("frames", [])

    words = tr.get("words", [])
    segments = tr.get("segments", [])
    silences = tr.get("silences", [])
    disfl = tr.get("disfluencies", [])
    audio_events = tr.get("audioEvents", [])
    # Real words exclude whisper placeholders like [BLANK_AUDIO]/[SOUND] and (events).
    real_words = [x for x in words if not re.match(r"^[\[(].*[\])]$", x["w"].strip())]

    L = []
    w = L.append
    w("# Take · %s" % b.path.name)
    w("")

    # ---- overview ----
    created = meta.get("createdAt", "")
    try:
        dt = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone()
        created = dt.strftime("%a %b %-d %Y, %-I:%M %p")
    except (ValueError, TypeError):
        pass
    disp = meta.get("display", {})
    dur = tr.get("duration") or probe_duration(b.stream_path("audio") or b.stream_path("screen") or "")
    w("- **Recorded:** %s" % created)
    w("- **Duration:** %s @ %dfps" % (fmt_t(dur), meta.get("fps", 0)))
    w("- **Display:** %s · %d×%d (scale %.0f×)" % (
        disp.get("name", "?"), disp.get("pixelWidth", 0), disp.get("pixelHeight", 0),
        disp.get("backingScaleFactor", 1)))

    streams = meta.get("streams", {})
    sline = []
    for key in ("screen", "camera", "audio"):
        s = streams.get(key)
        if not s:
            sline.append("%s ✗" % key)
            continue
        off = float(s.get("startOffset", 0))
        tag = "%s ✓" % key
        if off > 0.25:
            tag += " (+%.2fs)" % off
        sline.append(tag)
    w("- **Streams:** %s" % " · ".join(sline))
    if tr:
        w("- **Transcript:** %s backend · %d words · %d segments"
          % (tr.get("stt", "?"), len(real_words), len(segments)))
    w("")

    # ---- audio health (catches the silent/too-quiet mic problem) ----
    peak, rms = audio_health(b.stream_path("audio"))
    if peak is not None:
        verdict = "good"
        flag = ""
        if peak < -20 or rms < -45:
            verdict = "⚠️ TOO QUIET — boost/normalize before transcribing or publishing"
            flag = " ⚠️"
        elif peak > -1:
            verdict = "⚠️ near clipping"
        w("## Audio health%s" % flag)
        w("- Peak **%.1f dB**, RMS **%.1f dB** — %s" % (peak, rms, verdict))
        if peak < -20:
            w("- _Normal narration peaks around −6 to −12 dB. This recording will need "
              "`loudnorm` (the pipeline applies it before transcription)._")
        w("")

    # ---- app timeline ----
    apps = [e for e in events if e.get("type") == "app"]
    if apps:
        w("## On-screen apps (context + chaptering)")
        seen = None
        for e in apps:
            name = e.get("name") or e.get("bundleId") or "?"
            if name == seen:
                continue
            seen = name
            w("- `%s`  %s" % (fmt_t(e.get("t", 0)), name))
        w("")

    # ---- clicks ----
    clicks = [e for e in events if e.get("type") == "click"]
    if clicks:
        w("## Clicks · auto-zoom anchors (%d)" % len(clicks))
        for e in clicks:
            t = float(e.get("t", 0))
            label = nearest_words(words, t) if words else ""
            label = (" — near _“%s”_" % label) if label else ""
            w("- `%s`  %s @ px (%.0f, %.0f)%s"
              % (fmt_t(t), e.get("button", "left"), e.get("px", 0), e.get("py", 0), label))
        w("")

    # ---- transcript ----
    if segments:
        w("## Transcript")
        for s in segments:
            w("- `%s` %s" % (fmt_t(s["start"]), s["text"]))
        w("")
    elif tr:
        w("## Transcript")
        w("- _(no speech detected — see Audio health above)_")
        w("")

    # ---- edit candidates ----
    if silences or disfl:
        total_silence = sum(s.get("dur", 0) for s in silences)
        w("## Edit candidates")
        if silences:
            w("- **Dead air:** %d span(s), %.1fs total" % (len(silences), total_silence))
        if disfl:
            w("- **Voiced gaps (probable hidden fillers):** %d" % len(disfl))
        fillers = [w_ for w_ in words
                   if re.sub(r"[^a-z]", "", w_["w"].lower()) in
                   {"um", "uh", "er", "ah", "hmm", "mm", "uhm", "umm", "erm"}]
        if fillers:
            w("- **Explicit filler tokens:** %d (%s)"
              % (len(fillers), ", ".join(sorted({f["w"] for f in fillers}))))
        w("")
    if audio_events:
        w("## Audio events")
        for a in audio_events:
            w("- `%s` %s" % (fmt_t(a["start"]), a["text"]))
        w("")

    # ---- frames ----
    if frames:
        sheet = contact_sheet(b, frames)
        w("## Frames (visual context — read these to *see* the screen)")
        if sheet:
            w("- 🗂️ `%s` — all %d frames tiled in one image, time order (read this first)"
              % (sheet, len(frames)))
        for f in frames:
            note = f.get("reason", f.get("kind", ""))
            note = " — %s" % note if note else ""
            w("- `%s` `%s`%s" % (fmt_t(f.get("t", 0)), f.get("file", "?"), note))
        w("")

    # ---- next step ----
    w("## Suggested next step")
    if not tr:
        w("- Run `/slate-ingest` to transcribe + extract frames, then re-run this digest.")
    else:
        total_silence = sum(s.get("dur", 0) for s in silences)
        if (peak is not None and peak < -20) and not real_words:
            w("- Audio is too quiet and yielded no transcript — re-record with a louder mic, "
              "or the pipeline can still cut on silence/visuals.")
        elif total_silence > 2 or disfl or len(real_words) > 0:
            w("- Clean it: `/slate-strip-filler` — or shape it: `/slate-cut social` | `/slate-cut course`.")
        else:
            w("- Looks tight already. Shape it with `/slate-cut social|course`, then `/slate-render`.")

    md = "\n".join(L) + "\n"
    out = b.path / "take.md"
    out.write_text(md)
    print("Wrote", out)
    if args.echo:
        print("\n" + md)


if __name__ == "__main__":
    main()
