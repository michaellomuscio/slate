#!/usr/bin/env python3
"""Slate renderer: execute edit.json into final.mp4 (+ final.srt).

    python3 pipeline/render.py <bundle> [--preset course|social] [--no-zoom] [--no-camera]
                                        [--preview]

Approach (the sync guarantee): the timeline is rendered SEGMENT BY SEGMENT. Each kept
segment is cut from screen + audio together, so audio and video can never drift — a `cut`
removes the same span from both; a `silence` keeps the video and swaps in silent audio of
equal length. Each segment is bounded by an OUTPUT `-t` and `-fps_mode cfr` so a
variable-frame-rate screen source can't over-run its audio (the bug that made skew
accumulate across the concat). Zoom and the camera bubble are composited per segment; the
segments are concatenated and the output audio is loudness-normalized; captions are remapped
onto the resulting shorter timeline.
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle, ffmpeg_cmd, ffmpeg_has_filter, fmt_ts_srt, probe_duration, run

V_ENC_FINAL = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "veryfast"]
# Broadcast-ish loudness for the final mix — also rescues a quiet mic in the output even
# though the per-segment audio was cut from the raw (often too-quiet) take.
LOUDNORM = "loudnorm=I=-16:TP=-1.5:LRA=11"

# Caption styling baked at burn time (ASS style attributes), tuned per preset.
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


def zoom_pan_filter(W, H, Z, cx, cy, fps, t_into_zoom=0.0, zoom_total=1.0, ramp=0.35):
    """A `zoompan=…` that eases into a zoom toward (cx,cy) and back out, ramping over the
    FULL zoom window (`zoom_total`) — even when a cut splits that window across several
    rendered pieces. zoompan's `time` resets to 0 at the start of each piece, so absolute
    progress through the zoom is `(t_into_zoom + time)`; easing over the whole window keeps
    the magnification monotonic across joins instead of pulsing out→in at every cut.

    Progress p ramps 0→1 over `ramp` s, holds at 1, ramps 1→0 over the last `ramp` s, then
    smoothstepped s(p)=p²(3−2p). Zoom factor = 1+(Z−1)·s. (cx,cy) are in BASE-image pixels
    (already scaled to W×H — the caller scales display coords for --preview)."""
    r = max(0.01, min(ramp, zoom_total / 2.0))
    T = "(%.4f+time)" % t_into_zoom
    p = "min(max(min(%s/%.4f,(%.4f-%s)/%.4f),0),1)" % (T, r, zoom_total, T, r)
    s = "(%s)*(%s)*(3-2*(%s))" % (p, p, p)
    z = "(1+(%.4f-1)*(%s))" % (Z, s)
    x = "max(0,min(iw-iw/(%s),%.2f-iw/(2*(%s))))" % (z, cx, z)
    y = "max(0,min(ih-ih/(%s),%.2f-ih/(2*(%s))))" % (z, cy, z)
    return "zoompan=z='%s':x='%s':y='%s':d=1:s=%dx%d:fps=%d" % (z, x, y, W, H, fps)


def active_zoom(zooms, t):
    for z in zooms:
        if z["start"] <= t < z["end"]:
            return z
    return None


def split_for_zoom(segments, zooms, extra_bounds=()):
    """Split kept segments at zoom boundaries (and any extra boundaries, e.g. the camera's
    start) so each rendered piece has one constant treatment."""
    pieces = []
    bset = list(extra_bounds)
    for seg in segments:
        bounds = {seg["start"], seg["end"]}
        for z in zooms:
            for bnd in (z["start"], z["end"]):
                if seg["start"] < bnd < seg["end"]:
                    bounds.add(bnd)
        for bnd in bset:
            if seg["start"] < bnd < seg["end"]:
                bounds.add(bnd)
        ordered = sorted(bounds)
        for a, c in zip(ordered, ordered[1:]):
            pieces.append({"start": a, "end": c, "op": seg["op"],
                           "zoom": active_zoom(zooms, (a + c) / 2.0)})
    return pieces


def render_segment(b, idx, piece, W, H, fps, cam, tmp, sx, sy):
    dur = piece["end"] - piece["start"]
    # Matroska + PCM audio for intermediates: PCM has NO encoder priming, so concatenating
    # segments is sample-exact (per-segment AAC priming would otherwise add ~10ms each and
    # drift audio behind video). Final pass re-encodes to AAC once.
    out = tmp / ("seg_%04d.mkv" % idx)

    # Camera only when real frames exist at this piece (suppress the warm-up window, where
    # to_local would otherwise clamp to frame 0 and freeze/misalign the bubble).
    use_cam = cam if (cam and b.camera_live_at((piece["start"] + piece["end"]) / 2.0)) else None

    inputs = []
    inputs += ["-ss", "%.3f" % b.to_local("screen", piece["start"]), "-t", "%.3f" % dur,
               "-i", str(b.stream_path("screen"))]
    cam_in = None
    if use_cam:
        cam_in = 1
        inputs += ["-ss", "%.3f" % b.to_local("camera", piece["start"]), "-t", "%.3f" % dur,
                   "-i", str(b.stream_path("camera"))]
    a_idx = (cam_in + 1) if cam_in else 1
    if piece["op"] == "silence":
        inputs += ["-f", "lavfi", "-t", "%.3f" % dur, "-i", "anullsrc=r=48000:cl=mono"]
    else:
        inputs += ["-ss", "%.3f" % b.to_local("audio", piece["start"]), "-t", "%.3f" % dur,
                   "-i", str(b.stream_path("audio"))]

    # video filtergraph
    fc = ["[0:v]scale=%d:%d,setsar=1,fps=%d,setpts=PTS-STARTPTS[base0]" % (W, H, fps)]
    last = "base0"
    z = piece.get("zoom")
    if z:
        Z = max(1.01, float(z["scale"]))
        # Display coords -> base-image coords (handles --preview's smaller base).
        cx, cy = float(z["x"]) * sx, float(z["y"]) * sy
        t_into = max(0.0, piece["start"] - float(z["start"]))
        z_total = max(0.01, float(z["end"]) - float(z["start"]))
        chain = zoom_pan_filter(W, H, Z, cx, cy, fps, t_into_zoom=t_into, zoom_total=z_total)
        fc.append("[%s]%s[zoomed]" % (last, chain))
        last = "zoomed"
    if use_cam:
        d = even(use_cam.get("size", 0.18) * H)
        margin = even(0.03 * H)
        cf = "[1:v]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1" % (d, d, d, d)
        if use_cam.get("shape", "circle") == "circle":
            cf += (",format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
                   "a='if(lte((X-%d)*(X-%d)+(Y-%d)*(Y-%d),%d),255,0)'"
                   % (d // 2, d // 2, d // 2, d // 2, (d // 2) ** 2))
        cf += "[cam]"
        fc.append(cf)
        corner = use_cam.get("corner", "br")
        x = "W-w-%d" % margin if "r" in corner else "%d" % margin
        y = "H-h-%d" % margin if "b" in corner else "%d" % margin
        fc.append("[%s][cam]overlay=%s:%s[vout]" % (last, x, y))
    else:
        fc.append("[%s]copy[vout]" % last)

    # OUTPUT -t + CFR: a VFR screen source clones its last sparse frame past `dur` without
    # this, so video > audio per segment and the skew accumulates across the concat.
    cmd = ([ffmpeg_cmd(), "-y"] + inputs +
           ["-filter_complex", ";".join(fc), "-map", "[vout]", "-map", "%d:a" % a_idx,
            "-t", "%.3f" % dur, "-fps_mode", "cfr", "-r", str(fps),
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "16",
            "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "1", str(out)])
    run(cmd)
    return out


def caption_cues(b, kept_segments, max_words=7, gap=0.6):
    """Remap transcript words onto the post-cut timeline and group into cues — the shared
    basis for both the .srt sidecar and the karaoke .ass. Each cue is a list of
    (start, end, word) on the new (post-cut) timeline; words inside cut spans are dropped."""
    tr = b.load_transcript()
    if not tr:
        return []
    spans, acc = [], 0.0
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
        if cur and (len(cur) >= max_words or ns - cur[-1][1] > gap):
            cues.append(cur); cur = []
        cur.append((ns, ne, w["w"]))
    if cur:
        cues.append(cur)
    return cues


def build_srt(b, kept_segments):
    cues = caption_cues(b, kept_segments)
    out = []
    for i, cue in enumerate(cues, 1):
        start = cue[0][0]
        end = max(c[1] for c in cue)
        text = " ".join(c[2] for c in cue).strip()
        out.append("%d\n%s --> %s\n%s\n" % (i, fmt_ts_srt(start), fmt_ts_srt(end), text))
    return "\n".join(out)


def _fmt_ts_ass(seconds):
    seconds = max(0.0, seconds)
    cs = int(round(seconds * 100))
    h, cs = divmod(cs, 360000)
    m, cs = divmod(cs, 6000)
    s, cs = divmod(cs, 100)
    return "%d:%02d:%02d.%02d" % (h, m, s, cs)


def build_ass_karaoke(b, kept_segments, ow, oh, font_size, margin_v):
    """A karaoke (.ass) caption track: each spoken word highlights in turn (white →
    bright, libass `\\k`). The punchy word-by-word style that reads well on social. Returns
    the .ass text, or '' if there are no words."""
    cues = caption_cues(b, kept_segments)
    if not cues:
        return ""
    header = (
        "[Script Info]\n"
        "ScriptType: v4.00+\n"
        "WrapStyle: 2\n"
        "ScaledBorderAndShadow: yes\n"
        "PlayResX: %d\nPlayResY: %d\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, "
        "BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, "
        "BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        # PrimaryColour (sung) = bright yellow; SecondaryColour (unsung) = white; black
        # outline (BorderStyle 1, Outline 3, Shadow 1) so it's readable on ANY screen content.
        # Alignment 2 = bottom-center.
        "Style: Slate,Helvetica,%d,&H0000F4FF,&H00FFFFFF,&H00000000,&HA0000000,"
        "-1,0,0,0,100,100,0,0,1,3,1,2,80,80,%d,1\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    ) % (ow, oh, int(font_size), int(margin_v))

    lines = []
    for cue in cues:
        start = cue[0][0]
        end = max(c[1] for c in cue)
        parts = []
        for i, (ws, we, word) in enumerate(cue):
            nxt = cue[i + 1][0] if i + 1 < len(cue) else we
            k = max(1, int(round((nxt - ws) * 100)))      # centiseconds this word is active
            parts.append("{\\k%d}%s" % (k, word.replace("{", "(").replace("}", ")")))
        text = " ".join(parts)
        lines.append("Dialogue: 0,%s,%s,Slate,,0,0,0,,%s"
                     % (_fmt_ts_ass(start), _fmt_ts_ass(end), text))
    return header + "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--preset", choices=["course", "social"], default=None)
    ap.add_argument("--no-zoom", action="store_true")
    ap.add_argument("--no-camera", action="store_true")
    ap.add_argument("--preview", action="store_true", help="half-res everything, faster")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    edit = b.load_edit()
    if not edit:
        raise SystemExit("No edit.json — run propose_edit (or write one) first.")

    preset = args.preset or edit.get("preset", "course")
    screen = b.stream("screen")
    screen_w, screen_h = even(screen["width"]), even(screen["height"])
    W, H = screen_w, screen_h
    if args.preview:
        W, H = even(W / 2), even(H / 2)
    sx, sy = W / float(screen_w), H / float(screen_h)   # display px -> base px (for zoom center)
    # meta.fps is a CAP, not a real cadence: ScreenCaptureKit is variable-frame-rate and only
    # delivers on screen change (~14 fps observed), so rendering at 60 just clones frames into
    # a bloated file. 30 fps CFR is plenty for a screencast and keeps sizes sane.
    fps = min(b.fps, 30)

    kept = [s for s in edit["timeline"] if s["op"] != "cut"]
    # Clip to where the primary streams actually exist so we never seek before a stream
    # started (which clamps to local 0 and duplicates content) or past any stream's EOF.
    ts, te = b.timeline_start(), b.timeline_end()
    clipped = []
    for s in kept:
        a, c = max(s["start"], ts), min(s["end"], te)
        if c - a > 0.01:
            clipped.append({**s, "start": round(a, 3), "end": round(c, 3)})
    kept = clipped
    if not kept:
        raise SystemExit("Timeline removes everything — nothing to render.")
    zooms = [] if args.no_zoom else edit.get("zooms", [])
    cam = edit.get("camera", {}) if not args.no_camera else {}
    cam = cam if cam.get("enabled") and b.stream_path("camera") else None

    extra_bounds = [b.offset("camera")] if cam else []
    pieces = split_for_zoom(kept, zooms, extra_bounds)

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        seg_files = []
        print("Rendering %d segment(s)…" % len(pieces))
        for i, p in enumerate(pieces):
            seg_files.append(render_segment(b, i, p, W, H, fps, cam, tmp, sx, sy))

        listfile = tmp / "list.txt"
        listfile.write_text("".join("file '%s'\n" % f for f in seg_files))

        # Framing target first (captions are composited after the frame is sized).
        if preset == "social":
            ow, oh = (1080, 1920)
            if args.preview:
                ow, oh = even(ow / 2), even(oh / 2)
            # COVER-crop to 9:16 (fill the frame, crop the overflow) — no black bars.
            vf = ("scale=%d:%d:force_original_aspect_ratio=increase,"
                  "crop=%d:%d" % (ow, oh, ow, oh))
        else:
            ow, oh = (1920, 1080)
            if args.preview:
                ow, oh = even(ow / 2), even(oh / 2)
            vf = ("scale=%d:%d:force_original_aspect_ratio=decrease,"
                  "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black" % (ow, oh, ow, oh))

        # Captions: always write the .srt sidecar. If burn requested: social gets word-level
        # KARAOKE (.ass, each word highlights as spoken — punchy for vertical); course gets a
        # clean burned SRT. Falls back to the sidecar if libass is unavailable.
        (b.path / "final.srt").write_text(build_srt(b, kept))
        burn = False
        cap_desc = "final.srt (sidecar — upload alongside the video)"
        if bool(edit.get("captions", {}).get("burn")):
            if preset == "social" and ffmpeg_has_filter("ass"):
                ass_text = build_ass_karaoke(b, kept, ow, oh,
                                             round(oh * 0.05), round(oh * 0.14))
                if ass_text:
                    (b.path / "final.ass").write_text(ass_text)
                    vf += ",ass=filename='%s'" % str(b.path / "final.ass")
                    burn = True
                    cap_desc = "final.ass word-karaoke (burned in)"
            if not burn and ffmpeg_has_filter("subtitles"):
                style = CAPTION_STYLES.get(preset, CAPTION_STYLES["course"])
                vf += ",subtitles=filename='%s':force_style='%s'" % (
                    str(b.path / "final.srt"), style)
                burn = True
                cap_desc = "final.srt (burned in)"

        final = b.path / "final.mp4"
        run([ffmpeg_cmd(), "-y", "-f", "concat", "-safe", "0", "-i", str(listfile),
             "-vf", vf, "-af", LOUDNORM] + V_ENC_FINAL +
            ["-c:a", "aac", "-ar", "48000", str(final)])

    src_dur = (b.load_transcript() or {}).get("duration") or b.timeline_end()
    print("\nRendered:", final)
    print("  preset:   %s%s  (%dx%d)" % (preset, "  [preview]" if args.preview else "", ow, oh))
    print("  length:   %.2fs  (from %.2fs source)" % (probe_duration(final), src_dur))
    print("  captions: %s" % cap_desc)


if __name__ == "__main__":
    main()
