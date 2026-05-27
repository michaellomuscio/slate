#!/usr/bin/env python3
"""Slate edit proposer: read transcript.json + events and write a first-pass edit.json
(the Edit Decision List). Deterministic — Claude then reviews/refines it.

    python3 pipeline/propose_edit.py <bundle> [options]

What it proposes:
  * dead-air / dropped-filler removal  — from silence intervals (the reliable signal)
  * explicit filler removal            — from "um/uh/..." tokens, when whisper kept them
  * auto-zoom                          — toward each click, from the event log

Cut semantics (this is the sync-safety guarantee):
  cut      ripple-delete: removed from audio AND video together -> stays in sync, shortens
  silence  mute in place: video continues, audio muted -> duration unchanged (the
           "leave a blank spot" approach; use --mode silence)
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle

FILLERS = {"um", "uh", "er", "ah", "hmm", "mm", "uhm", "umm", "erm"}


def merge(intervals):
    intervals = sorted(intervals, key=lambda x: x[0])
    out = []
    for s, e, why in intervals:
        if out and s <= out[-1][1] + 1e-3:
            out[-1] = (out[-1][0], max(out[-1][1], e),
                       out[-1][2] if out[-1][1] >= e else why)
        else:
            out.append((s, e, why))
    return out


def partition(duration, cuts, op):
    """Turn cut intervals into a full timeline of keep/<op> segments covering [0,duration]."""
    timeline = []
    t = 0.0
    for s, e, why in cuts:
        s = max(0.0, s); e = min(duration, e)
        if e <= s:
            continue
        if s > t + 1e-3:
            timeline.append({"op": "keep", "start": round(t, 3), "end": round(s, 3)})
        timeline.append({"op": op, "start": round(s, 3), "end": round(e, 3), "reason": why})
        t = e
    if t < duration - 1e-3:
        timeline.append({"op": "keep", "start": round(t, 3), "end": round(duration, 3)})
    return timeline


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--mode", choices=["cut", "silence"], default="cut",
                    help="cut = ripple-delete (shortens); silence = mute in place")
    ap.add_argument("--keep-pause", type=float, default=0.22,
                    help="natural pause length to leave when compressing silence (s)")
    ap.add_argument("--min-cut", type=float, default=0.12,
                    help="don't bother cutting anything shorter than this (s)")
    ap.add_argument("--preset", choices=["course", "social"], default="course")
    ap.add_argument("--zoom-scale", type=float, default=1.8)
    ap.add_argument("--no-zoom", action="store_true")
    ap.add_argument("--no-camera", action="store_true")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    tr = b.load_transcript()
    if not tr:
        raise SystemExit("No transcript.json — run ingest first.")
    duration = float(tr["duration"])

    cuts = []

    # 1. Compress silences: keep a short pause, remove the excess.
    half = args.keep_pause / 2.0
    for s in tr.get("silences", []):
        cs, ce = s["start"] + half, s["end"] - half
        if ce - cs >= args.min_cut:
            cuts.append((round(cs, 3), round(ce, 3), "dead air"))

    # 2. Explicit filler tokens (when whisper kept them).
    for w in tr.get("words", []):
        bare = re.sub(r"[^a-z]", "", w["w"].lower())
        if bare in FILLERS:
            cuts.append((round(w["start"] - 0.05, 3), round(w["end"] + 0.05, 3),
                         "filler: %s" % w["w"]))

    cuts = merge(cuts)
    timeline = partition(duration, cuts, args.mode)

    # 3. Auto-zoom toward clicks (px,py = display-local pixels onto screen.mov).
    zooms = []
    if not args.no_zoom:
        for e in b.clicks():
            t = float(e["t"])
            zooms.append({
                "start": round(max(0.0, t - 0.4), 3), "end": round(t + 1.6, 3),
                "x": float(e.get("px", e.get("x", 0))),
                "y": float(e.get("py", e.get("y", 0))),
                "scale": args.zoom_scale, "reason": "click",
            })

    has_camera = b.stream_path("camera") is not None
    edit = {
        "version": 1,
        "source": "screen",
        "preset": args.preset,
        "timeline": timeline,
        "zooms": zooms,
        "camera": {"enabled": has_camera and not args.no_camera,
                   "shape": "circle", "corner": "br", "size": 0.18},
        "captions": {"enabled": True, "burn": False},
    }
    b.write_json("edit.json", edit)

    removed = sum(s["end"] - s["start"] for s in timeline if s["op"] == "cut")
    print("Proposed edit.json:")
    print("  segments:  %d  (%d cut, %d silence, %d keep)" % (
        len(timeline),
        sum(1 for s in timeline if s["op"] == "cut"),
        sum(1 for s in timeline if s["op"] == "silence"),
        sum(1 for s in timeline if s["op"] == "keep")))
    print("  zooms:     %d" % len(zooms))
    print("  original:  %.2fs" % duration)
    if args.mode == "cut":
        print("  removed:   %.2fs   ->  new length ~%.2fs" % (removed, duration - removed))
    print("  preset:    %s   captions: srt sidecar (burn=%s)" % (args.preset, edit["captions"]["burn"]))


if __name__ == "__main__":
    main()
