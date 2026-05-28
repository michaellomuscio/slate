#!/usr/bin/env python3
"""Slate renderer: execute edit.json into final.mp4 (+ final.srt).

    python3 pipeline/render.py <bundle> [--preset course|social] [--no-zoom] [--no-camera]
                                        [--preview]

Approach (this is the sync guarantee): the timeline is rendered SEGMENT BY SEGMENT. Each
kept segment is cut from screen + audio together, so audio and video can never drift —
a `cut` removes the same span from both; a `silence` keeps the video and swaps in silent
audio of equal length. Zoom and the camera bubble are composited per segment. The
segments are then concatenated; captions are remapped onto the resulting shorter timeline.
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle, ffmpeg_cmd, ffmpeg_has_filter, fmt_ts_srt, run

V_ENC_FINAL = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "veryfast"]

# Caption styling baked at burn time (ASS style attributes). Tuned per preset so the
# captions don't fight the camera bubble or the frame edges.
CAPTION_STYLES = {
    "course": ("FontName=Helvetica,FontSize=22,PrimaryColour=&H00FFFFFF&,"
               "BackColour=&H80000000&,BorderStyle=3,Outline=0,Shadow=0,"
               "MarginV=48,Alignment=2,Bold=1"),
    "social": ("FontName=Helvetica,FontSize=38,PrimaryColour=&H00FFFFFF&,"
               "BackColour=&H80000000&,BorderStyle=3,Outline=0,Shadow=0,"
               "MarginV=200,Alignment=2,Bold=1"),
}


def even(n):
    n = int(round(n))
    return n - (n % 2)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def zoom_pan_filter(W, H, Z, cx, cy, dur, fps, ramp=0.35):
    """Return a `zoompan=…` filter that eases into a zoom toward (cx,cy) and back.

    `crop` won't do this — its w/h are evaluated once at filter init. `zoompan`
    is the filter built for time-varying zoom. Progress p(time) ramps 0→1 over
    `ramp` s, holds at 1, ramps 1→0 over the last `ramp` s. Smoothstepped to
    s(p)=p²(3−2p). Zoom factor at time t is 1+(Z−1)·s. The source window is
    centered on (cx, cy) and clamped to the frame at each instant.
    """
    r = max(0.01, min(ramp, dur / 2.0))
    p = "min(max(min(time/%.4f,(%.4f-time)/%.4f),0),1)" % (r, dur, r)
    s = "(%s)*(%s)*(3-2*(%s))" % (p, p, p)
    z = "(1+(%.4f-1)*(%s))" % (Z, s)
    x = "max(0,min(iw-iw/(%s),%.2f-iw/(2*(%s))))" % (z, cx, z)
    y = "max(0,min(ih-ih/(%s),%.2f-ih/(2*(%s))))" % (z, cy, z)
    return ("zoompan=z='%s':x='%s':y='%s':d=1:s=%dx%d:fps=%d"
            % (z, x, y, W, H, fps))


def active_zoom(zooms, t):
    for z in zooms:
        if z["start"] <= t < z["end"]:
            return z
    return None


def split_for_zoom(segments, zooms):
    """Split kept segments at zoom boundaries so each piece has one constant zoom (or none)."""
    pieces = []
    for seg in segments:
        bounds = {seg["start"], seg["end"]}
        for z in zooms:
            for bnd in (z["start"], z["end"]):
                if seg["start"] < bnd < seg["end"]:
                    bounds.add(bnd)
        ordered = sorted(bounds)
        for a, c in zip(ordered, ordered[1:]):
            pieces.append({"start": a, "end": c, "op": seg["op"],
                           "zoom": active_zoom(zooms, (a + c) / 2.0)})
    return pieces


def render_segment(b, idx, piece, W, H, fps, cam, tmp):
    dur = piece["end"] - piece["start"]
    out = tmp / ("seg_%04d.mp4" % idx)

    inputs = []
    # input 0: screen
    inputs += ["-ss", "%.3f" % b.to_local("screen", piece["start"]), "-t", "%.3f" % dur,
               "-i", str(b.stream_path("screen"))]
    cam_in = None
    if cam:
        cam_in = 1
        inputs += ["-ss", "%.3f" % b.to_local("camera", piece["start"]), "-t", "%.3f" % dur,
                   "-i", str(b.stream_path("camera"))]
    if piece["op"] == "silence":
        a_idx = (cam_in + 1) if cam_in else 1
        inputs += ["-f", "lavfi", "-t", "%.3f" % dur, "-i", "anullsrc=r=48000:cl=mono"]
    else:
        a_idx = (cam_in + 1) if cam_in else 1
        inputs += ["-ss", "%.3f" % b.to_local("audio", piece["start"]), "-t", "%.3f" % dur,
                   "-i", str(b.stream_path("audio"))]

    # video filtergraph
    fc = ["[0:v]scale=%d:%d,setsar=1,fps=%d,setpts=PTS-STARTPTS[base0]" % (W, H, fps)]
    last = "base0"
    z = piece.get("zoom")
    if z:
        Z = max(1.01, float(z["scale"]))
        chain = zoom_pan_filter(W, H, Z, float(z["x"]), float(z["y"]), dur, fps)
        fc.append("[%s]%s[zoomed]" % (last, chain))
        last = "zoomed"
    if cam:
        d = even(cam.get("size", 0.18) * H)
        margin = even(0.03 * H)
        # square-cover the camera, then optional circular alpha
        cf = "[1:v]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1" % (d, d, d, d)
        if cam.get("shape", "circle") == "circle":
            cf += (",format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
                   "a='if(lte((X-%d)*(X-%d)+(Y-%d)*(Y-%d),%d),255,0)'"
                   % (d // 2, d // 2, d // 2, d // 2, (d // 2) ** 2))
        cf += "[cam]"
        fc.append(cf)
        corner = cam.get("corner", "br")
        x = "W-w-%d" % margin if "r" in corner else "%d" % margin
        y = "H-h-%d" % margin if "b" in corner else "%d" % margin
        fc.append("[%s][cam]overlay=%s:%s[vout]" % (last, x, y))
    else:
        fc.append("[%s]copy[vout]" % last)

    cmd = ([ffmpeg_cmd(), "-y"] + inputs +
           ["-filter_complex", ";".join(fc), "-map", "[vout]", "-map", "%d:a" % a_idx] +
           ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast",
            "-r", str(fps), "-c:a", "aac", "-ar", "48000", "-ac", "1", str(out)])
    run(cmd)
    return out


def build_srt(b, kept_segments):
    """Remap transcript words onto the post-cut timeline and group into cues."""
    tr = b.load_transcript()
    if not tr:
        return ""
    # map global time -> new time using cumulative kept duration
    spans = []
    acc = 0.0
    for s in kept_segments:
        spans.append((s["start"], s["end"], acc))
        acc += s["end"] - s["start"]

    def remap(t):
        for s, e, base in spans:
            if s - 1e-3 <= t <= e + 1e-3:
                return base + (clamp(t, s, e) - s)
        return None

    cues, cur = [], []
    for w in tr.get("words", []):
        ns, ne = remap(w["start"]), remap(w["end"])
        if ns is None or ne is None:
            if cur:
                cues.append(cur); cur = []
            continue
        if cur and (len(cur) >= 7 or ns - cur[-1][1] > 0.6):
            cues.append(cur); cur = []
        cur.append((ns, ne, w["w"]))
    if cur:
        cues.append(cur)

    out = []
    for i, cue in enumerate(cues, 1):
        start = cue[0][0]
        end = max(c[1] for c in cue)
        text = " ".join(c[2] for c in cue).strip()
        out.append("%d\n%s --> %s\n%s\n" % (i, fmt_ts_srt(start), fmt_ts_srt(end), text))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--preset", choices=["course", "social"], default=None)
    ap.add_argument("--no-zoom", action="store_true")
    ap.add_argument("--no-camera", action="store_true")
    ap.add_argument("--preview", action="store_true", help="half-res, faster")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    edit = b.load_edit()
    if not edit:
        raise SystemExit("No edit.json — run propose_edit (or write one) first.")

    preset = args.preset or edit.get("preset", "course")
    screen = b.stream("screen")
    W, H = even(screen["width"]), even(screen["height"])
    if args.preview:
        W, H = even(W / 2), even(H / 2)
    fps = b.fps

    kept = [s for s in edit["timeline"] if s["op"] != "cut"]
    if not kept:
        raise SystemExit("Timeline removes everything — nothing to render.")
    zooms = [] if args.no_zoom else edit.get("zooms", [])
    cam = edit.get("camera", {}) if not args.no_camera else {}
    cam = cam if cam.get("enabled") and b.stream_path("camera") else None

    pieces = split_for_zoom(kept, zooms)

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        seg_files = []
        print("Rendering %d segment(s)…" % len(pieces))
        for i, p in enumerate(pieces):
            seg_files.append(render_segment(b, i, p, W, H, fps, cam, tmp))

        listfile = tmp / "list.txt"
        listfile.write_text("".join("file '%s'\n" % f for f in seg_files))

        # captions
        srt = build_srt(b, kept)
        (b.path / "final.srt").write_text(srt)
        burn = edit.get("captions", {}).get("burn") and ffmpeg_has_filter("subtitles")

        # final framing + concat in one pass
        if preset == "social":
            ow, oh = 1080, 1920
        else:
            ow, oh = 1920, 1080
        vf = ("scale=%d:%d:force_original_aspect_ratio=decrease,"
              "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black" % (ow, oh, ow, oh))
        if burn:
            style = CAPTION_STYLES.get(preset, CAPTION_STYLES["course"])
            srt_path = str(b.path / "final.srt")
            vf += ",subtitles=filename='%s':force_style='%s'" % (srt_path, style)

        final = b.path / "final.mp4"
        run([ffmpeg_cmd(), "-y", "-f", "concat", "-safe", "0", "-i", str(listfile),
             "-vf", vf] + V_ENC_FINAL + ["-c:a", "aac", "-ar", "48000", str(final)])

    from lib.bundle import probe_duration
    print("\nRendered:", final)
    print("  preset:   %s  (%dx%d)" % (preset, ow, oh))
    print("  length:   %.2fs  (from %.2fs source)" % (probe_duration(final), b.load_transcript()["duration"]))
    print("  captions: final.srt%s" % ("  (burned in)" if burn else "  (sidecar — ffmpeg lacks libass)"))


if __name__ == "__main__":
    main()
