#!/usr/bin/env python3
"""Validate an edit.json against its take bundle before rendering.

    python3 pipeline/validate_edit.py <bundle>

The whole Slate design is "Claude hand-writes edit.json." A hallucinated timecode,
a dropped segment, or an overlap would otherwise render as silent garbage (out-of-range
clamped, gaps vanished, content duplicated) with exit 0 and no feedback. This validator
is the guard rail: it fails LOUD with the offending segment and a non-zero exit so a bad
EDL never reaches ffmpeg.

Checks (against lib.bundle for the authoritative editable span):
  * schema / types (version, source, preset, timeline shape, op/keep/cut/silence)
  * timeline SORTED, non-overlapping, GAPLESS, covering [timeline_start, timeline_end]
  * every cut/silence carries a non-empty `reason` (reason "long-wait" is accepted)
  * zoom / redaction times within [timeline_start, timeline_end]; sane geometry
  * NO cut boundary lands mid-word (cross-checked against transcript.words[] if present)
  * WARN if > ~20% of the editable span is removed on a course preset (the B1 canary)

Runnable standalone (exit 0 = valid, 2 = invalid) and imported by render.py's main(),
which calls validate() and refuses to render on failure.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle

EPS = 1e-3                 # timeline-coverage tolerance (ms-scale)
WORD_EPS = 0.02            # a cut edge within 20ms of a word edge is "on the boundary", ok
COURSE_REMOVED_WARN = 0.20 # warn if a course EDL removes > this fraction of the span
OPS = ("keep", "cut", "silence")


class EditInvalid(Exception):
    """Raised with a human-readable, segment-pointing message on a hard validation failure."""


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _seg_str(i, s):
    return "timeline[%d] = %r" % (i, s)


def validate(bundle, edit=None, verbose=False):
    """Validate `edit` (or bundle.load_edit()) against `bundle`. Returns a list of
    warning strings. Raises EditInvalid on any hard failure."""
    b = bundle if isinstance(bundle, Bundle) else Bundle(bundle)
    if edit is None:
        edit = b.load_edit()
    if edit is None:
        raise EditInvalid("No edit.json in bundle %s" % b.path)
    if not isinstance(edit, dict):
        raise EditInvalid("edit.json is not a JSON object")

    warnings = []

    # ---- top-level schema --------------------------------------------------
    tl = edit.get("timeline")
    if not isinstance(tl, list) or not tl:
        raise EditInvalid("edit.json 'timeline' must be a non-empty list")

    preset = edit.get("preset", "course")
    if preset not in ("course", "social"):
        warnings.append("unknown preset %r (expected course|social)" % preset)

    ts, te = b.timeline_start(), b.timeline_end()
    if te <= ts:
        raise EditInvalid("bundle editable span is empty: timeline_start=%.3f end=%.3f"
                          % (ts, te))

    # ---- per-segment shape -------------------------------------------------
    for i, s in enumerate(tl):
        if not isinstance(s, dict):
            raise EditInvalid("%s is not an object" % _seg_str(i, s))
        op = s.get("op")
        if op not in OPS:
            raise EditInvalid("%s has op=%r, must be one of %s" % (_seg_str(i, s), op, OPS))
        if not (_is_num(s.get("start")) and _is_num(s.get("end"))):
            raise EditInvalid("%s must have numeric start/end" % _seg_str(i, s))
        if s["end"] <= s["start"]:
            raise EditInvalid("%s has end <= start (zero/negative length)" % _seg_str(i, s))
        if op in ("cut", "silence"):
            reason = s.get("reason")
            if not (isinstance(reason, str) and reason.strip()):
                raise EditInvalid("%s is a %s with no 'reason' (audit trail required)"
                                  % (_seg_str(i, s), op))

    # ---- sorted, non-overlapping, gapless ----------------------------------
    for i in range(1, len(tl)):
        prev, cur = tl[i - 1], tl[i]
        if cur["start"] < prev["start"] - EPS:
            raise EditInvalid("timeline not sorted: %s starts before %s"
                              % (_seg_str(i, cur), _seg_str(i - 1, prev)))
        if cur["start"] < prev["end"] - EPS:
            raise EditInvalid("timeline OVERLAP: %s overlaps %s (gap %.3f)"
                              % (_seg_str(i, cur), _seg_str(i - 1, prev),
                                 prev["end"] - cur["start"]))
        if cur["start"] > prev["end"] + EPS:
            raise EditInvalid("timeline GAP of %.3fs between %s and %s (must be gapless)"
                              % (cur["start"] - prev["end"], _seg_str(i - 1, prev),
                                 _seg_str(i, cur)))

    # ---- coverage of [timeline_start, timeline_end] ------------------------
    first, last = tl[0], tl[-1]
    if first["start"] > ts + EPS:
        raise EditInvalid("timeline starts at %.3f but must cover from timeline_start=%.3f "
                          "(uncovered head of %.3fs)" % (first["start"], ts, first["start"] - ts))
    if last["end"] < te - EPS:
        raise EditInvalid("timeline ends at %.3f but must cover to timeline_end=%.3f "
                          "(uncovered tail of %.3fs — the payoff would be silently dropped)"
                          % (last["end"], te, te - last["end"]))

    # ---- zooms -------------------------------------------------------------
    for i, z in enumerate(edit.get("zooms", []) or []):
        if not isinstance(z, dict):
            raise EditInvalid("zooms[%d] is not an object" % i)
        if not (_is_num(z.get("start")) and _is_num(z.get("end"))):
            raise EditInvalid("zooms[%d] must have numeric start/end: %r" % (i, z))
        if z["end"] <= z["start"]:
            raise EditInvalid("zooms[%d] has end <= start: %r" % (i, z))
        if z["start"] < ts - EPS or z["end"] > te + EPS:
            raise EditInvalid("zooms[%d] time [%.3f,%.3f] out of range [%.3f,%.3f]: %r"
                              % (i, z["start"], z["end"], ts, te, z))
        if _is_num(z.get("scale")) and z["scale"] < 1.0:
            warnings.append("zooms[%d] scale=%.3f < 1.0 (no magnification)" % (i, z["scale"]))

    # ---- redactions (fractional geometry, ORIGINAL take seconds) -----------
    for i, r in enumerate(edit.get("redactions", []) or []):
        if not isinstance(r, dict):
            raise EditInvalid("redactions[%d] is not an object" % i)
        if not (_is_num(r.get("start")) and _is_num(r.get("end"))):
            raise EditInvalid("redactions[%d] must have numeric start/end: %r" % (i, r))
        if r["end"] <= r["start"]:
            raise EditInvalid("redactions[%d] has end <= start: %r" % (i, r))
        if r["start"] < ts - EPS or r["end"] > te + EPS:
            raise EditInvalid("redactions[%d] time [%.3f,%.3f] out of range [%.3f,%.3f]"
                              % (i, r["start"], r["end"], ts, te))
        for k in ("x", "y", "w", "h"):
            v = r.get(k)
            if not _is_num(v) or not (-EPS <= v <= 1 + EPS):
                raise EditInvalid("redactions[%d] %s=%r must be a fraction in [0,1]" % (i, k, v))

    # ---- no cut boundary mid-word ------------------------------------------
    tr = b.load_transcript()
    words = (tr or {}).get("words") or []
    if words:
        cut_edges = []
        for s in tl:
            if s["op"] == "cut":
                cut_edges.append(s["start"])
                cut_edges.append(s["end"])
        for edge in cut_edges:
            for w in words:
                ws, we = w.get("start"), w.get("end")
                if not (_is_num(ws) and _is_num(we)):
                    continue
                # strictly interior to the word (not merely touching its edge)
                if ws + WORD_EPS < edge < we - WORD_EPS:
                    raise EditInvalid(
                        "cut boundary at %.3fs lands MID-WORD %r [%.3f,%.3f] — the word "
                        "would be clipped" % (edge, w.get("w"), ws, we))

    # ---- removed-fraction canary (course) ----------------------------------
    # A collapsed "long-wait" (a legitimate multi-minute AI/idle gap trimmed to a beat) is
    # EXPECTED to remove a lot of time, so it's excluded from the canary. What we're guarding
    # against is the B1 failure — real speech-bearing footage being truncated — so measure the
    # fraction of the span removed by NON-long-wait cuts.
    span = te - ts
    removed = sum(s["end"] - s["start"] for s in tl if s["op"] == "cut")
    removed_lw = sum(s["end"] - s["start"] for s in tl
                     if s["op"] == "cut" and s.get("reason") == "long-wait")
    frac = (removed - removed_lw) / span if span > 0 else 0.0
    if verbose:
        print("  editable span: %.2fs  removed(cut): %.2fs (long-wait %.2fs) "
              "-> non-wait removed %.1f%%" % (span, removed, removed_lw, frac * 100))
    if preset == "course" and frac > COURSE_REMOVED_WARN:
        warnings.append("course EDL removes %.1f%% of the editable span via non-long-wait cuts "
                        "(> %.0f%%) — verify the payoff/full walkthrough isn't being truncated"
                        % (frac * 100, COURSE_REMOVED_WARN * 100))

    return warnings


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print("usage: python3 pipeline/validate_edit.py <bundle>", file=sys.stderr)
        return 2
    b = Bundle(argv[0])
    try:
        warnings = validate(b, verbose=True)
    except EditInvalid as e:
        print("INVALID edit.json: %s" % e, file=sys.stderr)
        return 2
    for w in warnings:
        print("WARNING: %s" % w, file=sys.stderr)
    print("edit.json is valid (%d warning(s))." % len(warnings))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
