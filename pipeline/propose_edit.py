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

# Preset-specific cut policy. KEEP-FIRST: we start from the whole editable span and
# only subtract justified cuts. Course protects the walkthrough; social shreds tight.
#   min_gap    : never cut dead air shorter than this (protect natural pauses)
#   keep_pause : how much of a cut gap to LEAVE behind (the residual breath)
#   drop_filler: whether to remove explicit "um/uh" filler tokens
#   max_removed_frac : warn/canary if removed exceeds this fraction of the speech span
PRESETS = {
    "course": {"min_gap": 2.0, "keep_pause": 0.6, "drop_filler": True,
               "max_removed_frac": 0.15},
    "social": {"min_gap": 0.6, "keep_pause": 0.18, "drop_filler": True,
               "max_removed_frac": 0.60},
}

# A silence longer than this is a categorical "long wait" (screen asleep / AI thinking),
# not a breath. We collapse it to a short beat and KEEP everything after it.
LONG_WAIT_S = 10.0
LONG_WAIT_KEEP = 1.5   # seconds of the gap we leave in place (the beat)
MIN_KEEP = 0.35        # merge/absorb any keep shorter than this into a neighbor


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


def partition(start, duration, cuts, op):
    """Turn cut intervals into a full timeline of keep/<op> segments covering
    [start, duration]. `start` is the take's timeline_start (where the primary streams
    exist), so the EDL never addresses the pre-capture head."""
    timeline = []
    t = start
    for s, e, why in cuts:
        s = max(start, s); e = min(duration, e)
        if e <= s:
            continue
        if s > t + 1e-3:
            timeline.append({"op": "keep", "start": round(t, 3), "end": round(s, 3)})
        timeline.append({"op": op, "start": round(s, 3), "end": round(e, 3), "reason": why})
        t = e
    if t < duration - 1e-3:
        timeline.append({"op": "keep", "start": round(t, 3), "end": round(duration, 3)})
    return timeline


def snap_out_of_words(cs, ce, word_bounds):
    """Clamp a cut interval (cs,ce) so it never overlaps any transcript word's
    [start,end]. `word_bounds` is a sorted list of (wstart, wend). We shrink the cut
    inward off any word it collides with; if the whole interval is inside a word we
    return None (nothing safe to cut)."""
    for ws, we in word_bounds:
        if we <= cs:
            continue          # word entirely before the cut
        if ws >= ce:
            break             # words are sorted; no later word overlaps
        # word [ws,we] overlaps [cs,ce] -> push the cut off it
        if ws <= cs and we >= ce:
            return None       # cut is buried inside a single word: drop it
        if ws <= cs < we:
            cs = we           # word covers the head -> start after the word ends
        if cs < we <= ce and ws > cs:
            # word starts inside the cut -> end before the word begins
            ce = min(ce, ws)
        elif ws < ce <= we:
            ce = ws           # word covers the tail -> end before the word begins
    if ce - cs <= 1e-3:
        return None
    return (round(cs, 3), round(ce, 3))


def absorb_tiny_keeps(timeline, duration):
    """A4: any keep shorter than MIN_KEEP is a render-hostile splinter — merge it into
    an adjacent segment by re-opening the neighboring cut(s) around it (extend cuts to
    swallow the sliver, then re-partition into contiguous keep/cut runs)."""
    changed = True
    while changed:
        changed = False
        for i, seg in enumerate(timeline):
            if seg["op"] != "keep" or seg["end"] - seg["start"] >= MIN_KEEP:
                continue
            prev_c = timeline[i - 1] if i > 0 and timeline[i - 1]["op"] != "keep" else None
            next_c = timeline[i + 1] if i + 1 < len(timeline) and timeline[i + 1]["op"] != "keep" else None
            if prev_c is not None:
                prev_c["end"] = seg["end"]
                if next_c is not None:      # bridge two cuts into one across the sliver
                    prev_c["end"] = next_c["end"]
                    timeline.pop(i + 1)
                timeline.pop(i)
            elif next_c is not None:
                next_c["start"] = seg["start"]
                timeline.pop(i)
            else:
                break                        # lone tiny keep with no neighbor cut: leave it
            changed = True
            break
    return timeline


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--mode", choices=["cut", "silence"], default="cut",
                    help="cut = ripple-delete (shortens); silence = mute in place")
    ap.add_argument("--keep-pause", type=float, default=None,
                    help="override preset: natural pause length to leave when compressing silence (s)")
    ap.add_argument("--min-cut", type=float, default=None,
                    help="override preset: don't cut any dead air shorter than this (s)")
    ap.add_argument("--preset", choices=["course", "social"], default="course")
    ap.add_argument("--zoom-scale", type=float, default=1.8)
    ap.add_argument("--no-zoom", action="store_true")
    ap.add_argument("--no-camera", action="store_true")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    tr = b.load_transcript()
    if not tr:
        raise SystemExit("No transcript.json — run ingest first.")

    # P0.1: the editable end is the LIVE narration spine (b.timeline_end()), NOT the
    # frozen tr["duration"], which can be stale (written by an older ingest) and would
    # silently truncate the take at the screen's death — discarding the payoff.
    duration = b.timeline_end()
    frozen = float(tr.get("duration", 0.0) or 0.0)
    if abs(frozen - duration) > 0.5:
        sys.stderr.write(
            "\n*** WARNING: transcript.json 'duration'=%.3fs disagrees with the live "
            "timeline_end()=%.3fs (drift %.3fs).\n"
            "    Using the LIVE timeline_end so the payoff isn't truncated. "
            "Consider re-running ingest to refresh transcript.json.\n\n"
            % (frozen, duration, abs(frozen - duration)))

    start = b.timeline_start()
    pol = PRESETS.get(args.preset, PRESETS["course"])
    # Preset defaults; --min-cut / --keep-pause on the CLI override them.
    min_gap = args.min_cut if args.min_cut is not None else pol["min_gap"]
    keep_pause = args.keep_pause if args.keep_pause is not None else pol["keep_pause"]

    # Sorted word bounds for A2 boundary-snapping (only real, non-empty spans).
    word_bounds = sorted(
        (float(w["start"]), float(w["end"]))
        for w in tr.get("words", [])
        if float(w.get("end", 0)) > float(w.get("start", 0)))

    cuts = []

    # ---- KEEP-FIRST cut selection (A1) ------------------------------------------
    # We start from the full editable span and subtract only justified cuts.
    for s in tr.get("silences", []):
        gs, ge = float(s["start"]), float(s["end"])
        gs = max(gs, start); ge = min(ge, duration)
        gap = ge - gs
        if gap < min_gap:
            continue                     # protect natural pauses
        if gap > LONG_WAIT_S:
            # A3: a long wait (screen asleep / AI thinking). Collapse to a short beat
            # and KEEP everything after it. Emitted as a normal cut with reason
            # "long-wait" so render/validator need no special-casing.
            cs, ce = gs + LONG_WAIT_KEEP, ge
            snapped = snap_out_of_words(cs, ce, word_bounds)
            if snapped:
                cuts.append((snapped[0], snapped[1], "long-wait"))
            continue
        # Ordinary dead air: leave keep_pause of breath, compress out the rest.
        cs = gs + keep_pause / 2.0
        ce = ge - keep_pause / 2.0
        if ce - cs <= 0:
            continue
        snapped = snap_out_of_words(cs, ce, word_bounds)
        if snapped:
            cuts.append((snapped[0], snapped[1], "dead air"))

    # Explicit filler tokens ("um"/"uh") — verbatim backend keeps them, word-accurate.
    if pol["drop_filler"]:
        for w in tr.get("words", []):
            bare = re.sub(r"[^a-z]", "", w["w"].lower())
            if bare in FILLERS:
                # The token IS a word we want gone; cut exactly its span (no blind pad).
                cuts.append((round(float(w["start"]), 3), round(float(w["end"]), 3),
                             "filler: %s" % w["w"]))

    # Voiced gaps a backend dropped (acoustic cross-check; usually empty on ElevenLabs).
    for d in tr.get("disfluencies", []):
        ds, de = float(d["start"]), float(d["end"])
        if de - ds < min_gap:
            continue
        snapped = snap_out_of_words(ds, de, word_bounds)
        if snapped:
            cuts.append((snapped[0], snapped[1], "disfluency"))

    cuts = merge(cuts)
    timeline = partition(start, duration, cuts, args.mode)
    timeline = absorb_tiny_keeps(timeline, duration)

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
        "captions": {"enabled": True, "burn": True},
    }
    b.write_json("edit.json", edit)

    removed = sum(s["end"] - s["start"] for s in timeline if s["op"] == "cut")
    long_waits = sum(1 for s in timeline if s.get("reason") == "long-wait")
    # Speech-bearing span (first word start -> last word end) is the denominator for
    # the course "protect the walkthrough" canary — NOT the whole timeline (which is
    # dominated by dead air).
    words = [w for w in tr.get("words", []) if float(w.get("end", 0)) > float(w.get("start", 0))]
    speech_span = (words[-1]["end"] - words[0]["start"]) if words else duration
    long_wait_removed = sum(s["end"] - s["start"] for s in timeline
                            if s["op"] == "cut" and s.get("reason") == "long-wait")
    speech_removed = removed - long_wait_removed
    removed_frac = (speech_removed / speech_span) if speech_span > 0 else 0.0

    print("Proposed edit.json:")
    print("  segments:  %d  (%d cut, %d silence, %d keep)  long-wait: %d" % (
        len(timeline),
        sum(1 for s in timeline if s["op"] == "cut"),
        sum(1 for s in timeline if s["op"] == "silence"),
        sum(1 for s in timeline if s["op"] == "keep"),
        long_waits))
    print("  zooms:     %d" % len(zooms))
    print("  editable:  %.2fs  (frozen tr.duration=%.2fs)" % (duration, frozen))
    tl_max = max((s["end"] for s in timeline), default=0.0)
    print("  timeline max-end: %.2fs" % tl_max)
    if args.mode == "cut":
        print("  removed:   %.2fs  (long-wait %.2fs + speech-span %.2fs)  ->  new length ~%.2fs"
              % (removed, long_wait_removed, speech_removed, duration - removed))
    print("  removed %% of speech span (%.2fs): %.1f%%  [cap %.0f%%]"
          % (speech_span, 100.0 * removed_frac, 100.0 * pol["max_removed_frac"]))
    if removed_frac > pol["max_removed_frac"]:
        sys.stderr.write(
            "*** WARNING: removed %.1f%% of the speech-bearing span, over the %.0f%% cap "
            "for preset '%s'. Review the cuts.\n"
            % (100.0 * removed_frac, 100.0 * pol["max_removed_frac"], args.preset))
    print("  preset:    %s   captions: srt sidecar (burn=%s)" % (args.preset, edit["captions"]["burn"]))


if __name__ == "__main__":
    main()
