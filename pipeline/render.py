#!/usr/bin/env python3
"""Slate renderer: execute edit.json into final.mp4 (+ final.srt).

    python3 pipeline/render.py <bundle> [--preset course|social] [--no-zoom] [--no-camera]
                                        [--preview]

Approach (the sync guarantee): the timeline is rendered SEGMENT BY SEGMENT. Each kept
segment is cut from screen + audio together, so audio and video can never drift — a `cut`
removes the same span from both; a `silence` keeps the video and swaps in silent audio of
equal length. Each segment is bounded by an OUTPUT `-t` + `-fps_mode cfr` so a VFR screen
source can't over-run its audio. Intermediates use PCM-in-MKV (no AAC priming drift).

Each segment is rendered ALREADY AT THE FINAL PANEL SIZE (course: the whole output frame
with the camera bubble baked in; social: the two stacked panels baked in), so the concat
is a cheap `-c copy` join. Loudness normalization + burned captions happen in ONE final
one-shot pass — no full-resolution intermediates, no double video encode.

Presets:
  course  — the screen's NATIVE aspect, long edge capped at 1920 (e.g. 2940x1912 ->
            1920x1248). NO letterbox/pillarbox bars, NO cropping. Camera as a corner bubble,
            burned captions (ASS at the output PlayRes).
  social  — 1080x1920 vertical STACK: the FULL screen on top + the FULL camera below it
            (neither cropped), with word-karaoke captions at the bottom. The go-to format.

--preview optimizes for cut-STRUCTURE speed: low fps, no caption burn, no zoom.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.bundle import Bundle, ffmpeg_cmd, ffmpeg_has_filter, fmt_ts_srt, probe_duration, run
from validate_edit import EditInvalid, validate

# Segment encode: the ONLY video encode of the "clean" frames. Fast + high quality so the
# final caption-burn pass (course) or copy (preview/social-no-caption) doesn't compound loss.
V_ENC_SEG = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "18"]
# Final caption-burn pass (re-encodes video once, only when captions are burned).
V_ENC_FINAL = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "veryfast"]
LOUDNORM = "loudnorm=I=-16:TP=-1.5:LRA=11"
STACK_BG = "0x161B27"   # slate background behind the stacked panels
PREVIEW_FPS = 12        # cut-structure preview: low fps, skip captions + zoom


def even(n):
    n = int(round(n))
    return n - (n % 2)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def course_output_size(sw, sh):
    """The screen's NATIVE aspect, long edge capped at 1920 (mirrors WalkthroughExporter.swift
    outputSize). NO letterbox bars, NO crop — e.g. 2940x1912 -> 1920x1248."""
    scale = min(1.0, 1920.0 / max(1, sw))
    return even(sw * scale), even(sh * scale)


def zoom_pan_filter(W, H, Z, cx, cy, fps, t_into_zoom=0.0, zoom_total=1.0, ramp=0.35):
    """A `zoompan=…` that eases into a zoom toward (cx,cy) and back out, ramping over the
    FULL zoom window (`zoom_total`) even when a cut splits it across several pieces. zoompan's
    `time` resets per piece, so absolute progress is `(t_into_zoom + time)`; easing over the
    whole window keeps the magnification monotonic across joins instead of pulsing at cuts."""
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


def extract_last_screen_frame(b, tmp):
    """Grab the last real screen frame as a still, so pieces past the screen's end (a
    sleep-killed / short screen track) can FREEZE on it instead of seeking past EOF. Returns
    the PNG path or None."""
    sp = b.stream_path("screen")
    if not sp:
        return None
    out = tmp / "screen_last.png"
    try:
        run([ffmpeg_cmd(), "-y", "-sseof", "-0.5", "-i", str(sp), "-frames:v", "1", str(out)])
        return out if out.exists() else None
    except RuntimeError:
        return None


def screen_filterchain(W, H, piece, sx, sy, fps, out_label="scr"):
    """Build the [0:v] -> screen-panel filter chain (scale to W×H at native aspect + optional
    zoom). `W`,`H` are the target SCREEN-PANEL pixels; the source is fit to them with the SAME
    aspect (course output dims already match the screen aspect, so no bars). Returns a list of
    filter strings ending in [out_label]."""
    fc = ["[0:v]scale=%d:%d,setsar=1,fps=%d,setpts=PTS-STARTPTS[base0]" % (W, H, fps)]
    last = "base0"
    z = piece.get("zoom")
    if z:
        Z = max(1.01, float(z["scale"]))
        cx, cy = float(z["x"]) * sx, float(z["y"]) * sy
        t_into = max(0.0, piece["start"] - float(z["start"]))
        z_total = max(0.01, float(z["end"]) - float(z["start"]))
        fc.append("[%s]%s[zoomed]" % (last, zoom_pan_filter(W, H, Z, cx, cy, fps,
                                                            t_into_zoom=t_into, zoom_total=z_total)))
        last = "zoomed"
    fc.append("[%s]copy[%s]" % (last, out_label))
    return fc


def camera_overlay_chain(b, use_cam, oh, screen_label, cam_input_idx, out_label="vout"):
    """Composite the circular camera bubble (`use_cam` dict) onto `screen_label`, reading the
    camera from filter input `cam_input_idx`. Bubble diameter/margins are fractions of the
    OUTPUT height `oh`. Returns filter strings ending in [out_label]."""
    d = even(use_cam.get("size", 0.18) * oh)
    margin = even(0.03 * oh)
    cf = ("[%d:v]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1"
          % (cam_input_idx, d, d, d, d))
    if use_cam.get("shape", "circle") == "circle":
        cf += (",format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
               "a='if(lte((X-%d)*(X-%d)+(Y-%d)*(Y-%d),%d),255,0)'"
               % (d // 2, d // 2, d // 2, d // 2, (d // 2) ** 2))
    cf += "[cam]"
    corner = use_cam.get("corner", "br")
    x = "W-w-%d" % margin if "r" in corner else "%d" % margin
    y = "H-h-%d" % margin if "b" in corner else "%d" % margin
    return [cf, "[%s][cam]overlay=%s:%s[%s]" % (screen_label, x, y, out_label)]


def render_segment(b, idx, piece, ow, oh, fps, cam, tmp, sx, sy, frozen_png=None):
    """Render ONE piece already at the FINAL course frame size (ow×oh) + its audio, with
    optional zoom and an optional corner camera bubble. Past the screen's end the top freezes
    on `frozen_png` while narration keeps playing."""
    dur = piece["end"] - piece["start"]
    out = tmp / ("seg_%04d.mkv" % idx)   # PCM-in-MKV: sample-exact concat, no AAC priming

    use_cam = cam if (cam and b.camera_live_at((piece["start"] + piece["end"]) / 2.0)) else None
    screen_live = b.screen_live_at((piece["start"] + piece["end"]) / 2.0)

    if screen_live or not frozen_png:
        inputs = ["-ss", "%.3f" % b.to_local("screen", piece["start"]), "-t", "%.3f" % dur,
                  "-i", str(b.stream_path("screen"))]
    else:
        inputs = ["-loop", "1", "-t", "%.3f" % dur, "-i", str(frozen_png)]   # freeze last frame
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

    fc = screen_filterchain(ow, oh, piece, sx, sy, fps, out_label="scr")
    if use_cam:
        fc += camera_overlay_chain(b, use_cam, oh, "scr", cam_in, out_label="vout")
    else:
        fc.append("[scr]copy[vout]")

    cmd = ([ffmpeg_cmd(), "-y"] + inputs +
           ["-filter_complex", ";".join(fc), "-map", "[vout]", "-map", "%d:a" % a_idx,
            "-t", "%.3f" % dur, "-fps_mode", "cfr", "-r", str(fps)] + V_ENC_SEG +
           ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "1", str(out)])
    run(cmd)
    return out


def render_stacked_segment(b, idx, piece, ow, oh, top, panel_sh, cam_y, panel_ch, fps,
                           cam_present, tmp, sx, sy, frozen_png=None):
    """Render ONE piece already at the FINAL social frame size (ow×oh): screen panel on top,
    full camera panel below, slate background, + audio. Baking the stack per-segment lets the
    concat be a cheap copy and needs only one caption pass afterward."""
    dur = piece["end"] - piece["start"]
    out = tmp / ("seg_%04d.mkv" % idx)

    screen_live = b.screen_live_at((piece["start"] + piece["end"]) / 2.0)
    if screen_live or not frozen_png:
        inputs = ["-ss", "%.3f" % b.to_local("screen", piece["start"]), "-t", "%.3f" % dur,
                  "-i", str(b.stream_path("screen"))]
    else:
        inputs = ["-loop", "1", "-t", "%.3f" % dur, "-i", str(frozen_png)]
    cam_live = cam_present and b.camera_live_at((piece["start"] + piece["end"]) / 2.0)
    if cam_live:
        inputs += ["-ss", "%.3f" % b.to_local("camera", piece["start"]), "-t", "%.3f" % dur,
                   "-i", str(b.stream_path("camera"))]
    a_idx = 2 if cam_live else 1
    if piece["op"] == "silence":
        inputs += ["-f", "lavfi", "-t", "%.3f" % dur, "-i", "anullsrc=r=48000:cl=mono"]
    else:
        inputs += ["-ss", "%.3f" % b.to_local("audio", piece["start"]), "-t", "%.3f" % dur,
                   "-i", str(b.stream_path("audio"))]

    # screen panel (with optional zoom), placed on a slate-color canvas at y=top
    fc = screen_filterchain(ow, panel_sh, piece, sx, sy, fps, out_label="scr")
    fc.append("color=c=%s:s=%dx%d:r=%d[bg]" % (STACK_BG, ow, oh, fps))
    fc.append("[bg][scr]overlay=0:%d[withscr]" % top)
    last = "withscr"
    if cam_present:
        if cam_live:
            fc.append("[1:v]scale=%d:%d,setsar=1,fps=%d,setpts=PTS-STARTPTS[campanel]"
                      % (ow, panel_ch, fps))
        else:
            fc.append("color=c=%s:s=%dx%d:r=%d[campanel]" % (STACK_BG, ow, panel_ch, fps))
        fc.append("[%s][campanel]overlay=0:%d[vout]" % (last, cam_y))
        last = "vout"
    else:
        fc.append("[%s]copy[vout]" % last)

    cmd = ([ffmpeg_cmd(), "-y"] + inputs +
           ["-filter_complex", ";".join(fc), "-map", "[vout]", "-map", "%d:a" % a_idx,
            "-t", "%.3f" % dur, "-fps_mode", "cfr", "-r", str(fps)] + V_ENC_SEG +
           ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "1", str(out)])
    run(cmd)
    return out


# Caption text cleanup — applies to the ON-SCREEN text only; the audio is never altered.
# Standalone fillers are dropped; casual contractions are expanded so captions read polished.
CAPTION_FILLERS = {"um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "mm", "mhm"}
CAPTION_EXPAND = {
    "gonna": "going to", "wanna": "want to", "gotta": "got to", "kinda": "kind of",
    "sorta": "sort of", "outta": "out of", "gimme": "give me", "lemme": "let me",
    "dunno": "don't know", "tryna": "trying to", "yall": "you all", "gotcha": "got you",
}


def _clean_tokens(word):
    """One transcript word -> list of cleaned display tokens (0 = drop a standalone filler,
    2 = expand a contraction). Preserves leading capitalization and trailing punctuation."""
    m = re.match(r"^([^\w]*)(.*?)([^\w]*)$", word, re.UNICODE)
    pre, core, suf = m.group(1), m.group(2), m.group(3)
    if not core:
        return [word]
    key = re.sub(r"[^a-z]", "", core.lower())
    if key in CAPTION_FILLERS:
        return []                                  # drop the filler and its punctuation
    if key in CAPTION_EXPAND:
        phrase = CAPTION_EXPAND[key].split()
        if core[:1].isupper():
            phrase[0] = phrase[0].capitalize()
        phrase[0] = pre + phrase[0]
        phrase[-1] = phrase[-1] + suf
        return phrase
    return [word]


def clean_caption_words(words):
    """Map verbatim transcript words -> cleaned caption tokens with timing. Expanded
    contractions split the source word's duration so karaoke still highlights in order;
    dropped fillers simply vanish from the text."""
    out = []
    for wd in words:
        toks = _clean_tokens(wd.get("w", ""))
        if not toks:
            continue
        s, e = wd["start"], wd["end"]
        step = (e - s) / len(toks)
        for i, t in enumerate(toks):
            out.append({"w": t, "start": s + i * step, "end": s + (i + 1) * step})
    return out


def caption_cues(b, kept_segments, max_words=7, gap=0.6):
    """Remap CLEANED transcript words onto the post-cut timeline and group into cues — shared
    by the .srt sidecar and the karaoke .ass. Each cue is a list of (start, end, word) on the
    new timeline; words inside cut spans are dropped."""
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
    for w in clean_caption_words(tr.get("words", [])):
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
    out = []
    for i, cue in enumerate(caption_cues(b, kept_segments), 1):
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


def build_ass_karaoke(b, kept_segments, ow, oh, font_size, margin_v, max_words=4):
    """A karaoke (.ass) caption track at the OUTPUT PlayRes (PlayResX/Y = output w/h, so libass
    sizes text in real output pixels — no 384x288-canvas blow-up). Each spoken word highlights
    in turn (white → yellow, libass `\\k`), boxed/outlined so it reads on any background.
    Alignment 2 = bottom center; `margin_v` is the distance up from the bottom edge."""
    cues = caption_cues(b, kept_segments, max_words=max_words)
    if not cues:
        return ""
    side = even(ow * 0.06)   # L/R margin so libass wraps instead of overflowing the frame
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
        "Style: Slate,Helvetica,%d,&H0000F4FF,&H00FFFFFF,&H00000000,&HA0000000,"
        "-1,0,0,0,100,100,0,0,1,3,1,2,60,60,%d,1\n\n"
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
            k = max(1, int(round((nxt - ws) * 100)))
            parts.append("{\\k%d}%s" % (k, word.replace("{", "(").replace("}", ")")))
        lines.append("Dialogue: 0,%s,%s,Slate,,%d,%d,0,,%s"
                     % (_fmt_ts_ass(start), _fmt_ts_ass(end), side, side, " ".join(parts)))
    return header + "\n".join(lines) + "\n"


def concat_segments(seg_files, tmp, name="list.txt"):
    listfile = tmp / name
    listfile.write_text("".join("file '%s'\n" % f for f in seg_files))
    return listfile


def final_pass(b, listfile, ass_text, preview):
    """One final pass over the concatenated segments: loudnorm the audio (always) and burn the
    ASS captions IF present (the only place the finished video is re-encoded — segments were
    already the right size). With no captions, video is copied straight through (no 2nd encode).
    Returns (final_path, cap_desc)."""
    final = b.path / "final.mp4"
    base = [ffmpeg_cmd(), "-y", "-f", "concat", "-safe", "0", "-i", str(listfile)]
    if ass_text and not preview:
        (b.path / "final.ass").write_text(ass_text)
        vf = "ass=filename='%s'" % str(b.path / "final.ass")
        cmd = base + ["-vf", vf, "-af", LOUDNORM] + V_ENC_FINAL + \
            ["-c:a", "aac", "-ar", "48000", str(final)]
        cap_desc = "final.ass captions (burned in)"
    else:
        # No caption burn -> copy the already-correct video, only re-mux + loudnorm the audio.
        cmd = base + ["-map", "0:v", "-map", "0:a", "-c:v", "copy",
                      "-af", LOUDNORM, "-c:a", "aac", "-ar", "48000", str(final)]
        cap_desc = "final.srt (sidecar)" + ("  [preview: no burn]" if preview else "")
    run(cmd)
    return final, cap_desc


def render_course(b, pieces, kept, ow, oh, fps, cam_cfg, sx, sy, tmp, preview):
    """The screen's NATIVE aspect capped at 1920 long edge (no bars, no crop): full screen +
    corner camera bubble + burned ASS captions. Returns (final_path, ow, oh, cap_desc)."""
    frozen = extract_last_screen_frame(b, tmp)
    seg_files = []
    print("Rendering %d segment(s) at %dx%d…" % (len(pieces), ow, oh))
    for i, p in enumerate(pieces):
        seg_files.append(render_segment(b, i, p, ow, oh, fps, cam_cfg, tmp, sx, sy, frozen_png=frozen))
    listfile = concat_segments(seg_files, tmp)

    ass_text = ""
    if not preview and bool(b.load_edit().get("captions", {}).get("enabled", True)) \
            and ffmpeg_has_filter("ass"):
        font = even(oh * 0.040)
        margin_v = even(oh * 0.06)
        ass_text = build_ass_karaoke(b, kept, ow, oh, font, margin_v, max_words=7)
    final, cap_desc = final_pass(b, listfile, ass_text, preview)
    return final, ow, oh, cap_desc


def render_social_stacked(b, pieces, kept, ow, oh, fps, cam_cfg, sx, sy, tmp, preview):
    """Vertical 9:16 STACK: full screen on top, full camera below, captions at the bottom.
    Both panels keep their full aspect ratio (no cropping). Returns (final_path, ow, oh, cap_desc)."""
    sw_src, sh_src = b.stream("screen")["width"], b.stream("screen")["height"]
    panel_sh = even(ow * sh_src / sw_src)                       # screen panel height at full width
    cam_present = bool(cam_cfg) and bool(b.stream_path("camera"))
    if cam_present:
        cw_src, ch_src = b.stream("camera")["width"], b.stream("camera")["height"]
        panel_ch = even(ow * ch_src / cw_src)                  # camera panel height at full width
    else:
        panel_ch = 0
    top = even(oh * 0.03)
    gap = even(oh * 0.012)
    cam_y = top + panel_sh + gap

    frozen = extract_last_screen_frame(b, tmp)   # freeze the top panel past the screen's end
    seg_files = []
    print("Rendering %d segment(s) at %dx%d (stacked)…" % (len(pieces), ow, oh))
    for i, p in enumerate(pieces):
        seg_files.append(render_stacked_segment(
            b, i, p, ow, oh, top, panel_sh, cam_y, panel_ch, fps, cam_present, tmp, sx, sy,
            frozen_png=frozen))
    listfile = concat_segments(seg_files, tmp)

    ass_text = ""
    if not preview and ffmpeg_has_filter("ass"):
        margin_v = even(oh * 0.12)
        font = even(oh * 0.046)
        ass_text = build_ass_karaoke(b, kept, ow, oh, font, margin_v, max_words=4)
    final, cap_desc = final_pass(b, listfile, ass_text, preview)
    return final, ow, oh, cap_desc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--preset", choices=["course", "social"], default=None)
    ap.add_argument("--no-zoom", action="store_true")
    ap.add_argument("--no-camera", action="store_true")
    ap.add_argument("--preview", action="store_true",
                    help="cut-structure preview: low fps, no captions, no zoom (fast)")
    args = ap.parse_args()

    b = Bundle(args.bundle)
    edit = b.load_edit()
    if not edit:
        raise SystemExit("No edit.json — run propose_edit (or write one) first.")

    # Block the render on an invalid EDL — a bad hand-written edit.json renders as silent
    # garbage otherwise (out-of-range clamped, gaps vanished, content duplicated).
    try:
        warnings = validate(b, edit, verbose=True)
    except EditInvalid as e:
        raise SystemExit("Refusing to render — INVALID edit.json: %s" % e)
    for w in warnings:
        print("WARNING: %s" % w, file=sys.stderr)

    preset = args.preset or edit.get("preset", "course")
    screen = b.stream("screen")
    screen_w, screen_h = even(screen["width"]), even(screen["height"])

    if preset == "social":
        ow, oh = (1080, 1920)
        if args.preview:
            ow, oh = even(ow / 2), even(oh / 2)
        # screen panel is full output width; its height matches the source aspect.
        W = ow
    else:
        ow, oh = course_output_size(screen_w, screen_h)
        if args.preview:
            ow, oh = even(ow / 2), even(oh / 2)
        W = ow
    H = oh   # only used for the sx/sy zoom-anchor scaling below
    # sx/sy map display-local zoom pixels onto the SCREEN-PANEL pixels. For course the panel
    # is the full output frame (ow×oh); for social it's ow×panel_sh, but zoom x/y anchor on
    # width, and the vertical anchor scales with the panel — good enough for the crop-zoom.
    sx = ow / float(screen_w)
    sy = (oh if preset == "course" else (ow * screen_h / float(screen_w))) / float(screen_h)

    # meta.fps is a CAP: ScreenCaptureKit is VFR and only delivers on screen change, so
    # rendering at 60 just clones frames into a bloated file. 30 fps CFR is plenty; --preview
    # drops to a low fps for cut-structure speed.
    fps = PREVIEW_FPS if args.preview else min(b.fps, 30)

    kept = [s for s in edit["timeline"] if s["op"] != "cut"]
    ts, te = b.timeline_start(), b.timeline_end()
    kept = [{**s, "start": round(max(s["start"], ts), 3), "end": round(min(s["end"], te), 3)}
            for s in kept if min(s["end"], te) - max(s["start"], ts) > 0.01]
    if not kept:
        raise SystemExit("Timeline removes everything — nothing to render.")

    zooms = [] if (args.no_zoom or args.preview) else edit.get("zooms", [])
    cam_cfg = edit.get("camera", {}) if not args.no_camera else {}
    cam_cfg = cam_cfg if cam_cfg.get("enabled") and b.stream_path("camera") else None
    # Split at each stream's live/frozen boundary so a piece never straddles one (camera
    # warm-up start + camera end + screen end → clean freeze/suppress transitions).
    bounds = [b.stream_end("screen")]
    if cam_cfg:
        bounds += [b.offset("camera"), b.stream_end("camera")]
    pieces = split_for_zoom(kept, zooms, [x for x in bounds if x])

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        (b.path / "final.srt").write_text(build_srt(b, kept))    # sidecar always written
        if preset == "social":
            final, ow2, oh2, cap_desc = render_social_stacked(
                b, pieces, kept, ow, oh, fps, cam_cfg, sx, sy, tmp, args.preview)
        else:
            final, ow2, oh2, cap_desc = render_course(
                b, pieces, kept, ow, oh, fps, cam_cfg, sx, sy, tmp, args.preview)

    src_dur = b.timeline_end()
    print("\nRendered:", final)
    print("  preset:   %s%s  (%dx%d)" % (preset, "  [preview]" if args.preview else "", ow2, oh2))
    print("  length:   %.2fs  (from %.2fs source span)" % (probe_duration(final), src_dur))
    print("  captions: %s" % cap_desc)


if __name__ == "__main__":
    main()
