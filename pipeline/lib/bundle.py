"""Shared helpers for reading/writing a Slate take bundle and doing timeline math.

A take bundle is a folder with screen.mov / camera.mov / audio.wav / events.jsonl /
meta.json (see repo README). All editing artifacts (transcript.json, edit.json,
frames/) are written back into the same folder.

The one rule that matters: every stream and every event lives on a single GLOBAL
timeline (t=0 at record start). Each media file's own internal clock starts at ~0, and
`meta.streams[x].startOffset` says where that file sits on the global timeline. So:

    global_time  = file_local_time + startOffset
    file_local   = global_time      - startOffset
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


class Bundle:
    def __init__(self, path):
        self.path = Path(path).expanduser().resolve()
        if not self.path.is_dir():
            raise SystemExit("Not a take bundle (folder not found): %s" % self.path)
        self.meta = self._load_json("meta.json", required=True)

    # ---- paths -------------------------------------------------------------
    def file(self, name):
        return self.path / name

    def stream(self, key):
        return self.meta.get("streams", {}).get(key)

    def stream_path(self, key):
        s = self.stream(key)
        if not s:
            return None
        p = self.path / s["file"]
        return p if p.exists() else None

    def offset(self, key):
        s = self.stream(key)
        return float(s["startOffset"]) if s else 0.0

    @property
    def fps(self):
        return int(self.meta.get("fps", 30))

    @property
    def display(self):
        return self.meta.get("display", {})

    # ---- timeline ----------------------------------------------------------
    def to_local(self, key, global_t):
        """Global time -> a stream file's own local time (for ffmpeg -ss)."""
        return max(0.0, global_t - self.offset(key))

    def to_global(self, key, local_t):
        return local_t + self.offset(key)

    # ---- stream extents (one authoritative timeline) -----------------------
    def present_streams(self):
        """Keys of streams whose file actually exists on disk."""
        return [k for k in ("screen", "camera", "audio") if self.stream_path(k)]

    def stream_end(self, key):
        """Global time at which a stream's content ends = offset + file duration.
        None if the stream/file is absent."""
        p = self.stream_path(key)
        if not p:
            return None
        return self.offset(key) + probe_duration(p)

    def timeline_end(self):
        """The one authoritative end of the take: the EARLIEST stream end among
        present streams. Past this instant at least one track has run out, so
        seeking it would read past EOF — every consumer should stop here. Falls
        back to 0.0 if nothing is present."""
        ends = [self.stream_end(k) for k in self.present_streams()]
        ends = [e for e in ends if e is not None]
        return min(ends) if ends else 0.0

    def timeline_start(self):
        """Earliest global time at which the PRIMARY streams (screen + audio) BOTH exist.
        Before this, nothing was captured yet (record was pressed but the first frame/sample
        hadn't arrived), so the editable timeline begins here. Seeking earlier would clamp
        to_local() to 0 and duplicate/early-shift content at the boundary. The camera is not
        a primary stream — its later warm-up is handled by camera_live_at()."""
        offs = [self.offset(k) for k in ("screen", "audio") if self.stream_path(k)]
        return max(offs) if offs else 0.0

    def camera_live_at(self, global_t):
        """True once real camera frames exist at this global time. Before the
        camera's startOffset there is no footage (warm-up), so the PIP must be
        suppressed rather than seeking the camera to a frozen frame 0."""
        if not self.stream_path("camera"):
            return False
        start = self.offset("camera")
        end = self.stream_end("camera")
        return global_t >= start and (end is None or global_t < end)

    # ---- events ------------------------------------------------------------
    def events(self):
        p = self.file("events.jsonl")
        out = []
        if p.exists():
            for line in p.read_text().splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        return out

    def clicks(self):
        return [e for e in self.events() if e.get("type") == "click"]

    # ---- artifact IO -------------------------------------------------------
    def load_transcript(self):
        return self._load_json("transcript.json", required=False)

    def load_edit(self):
        return self._load_json("edit.json", required=False)

    def write_json(self, name, obj):
        (self.path / name).write_text(json.dumps(obj, indent=2, sort_keys=True))
        return self.path / name

    def _load_json(self, name, required):
        p = self.path / name
        if not p.exists():
            if required:
                raise SystemExit("Missing %s in %s" % (name, self.path))
            return None
        return json.loads(p.read_text())


# ---- ffprobe / ffmpeg conveniences ----------------------------------------

def probe_duration(path):
    """Seconds (float) of a media file, via ffprobe."""
    out = subprocess.run(
        [ffprobe_cmd(), "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nokey=1:noprint_wrappers=1", str(path)],
        capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def run(cmd, **kw):
    """Run a command, raising with captured stderr on failure."""
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise RuntimeError("Command failed (%d): %s\n%s" %
                           (r.returncode, " ".join(str(c) for c in cmd), r.stderr[-2000:]))
    return r


def ffmpeg_cmd():
    """Path to the ffmpeg binary the pipeline should use.

    Prefers a bundled build at `pipeline/bin/ffmpeg` (the libass-enabled evermeet
    binary) so caption burn-in works. Falls back to system `ffmpeg`. Override with
    `SLATE_FFMPEG=/path/to/ffmpeg`.
    """
    env = os.environ.get("SLATE_FFMPEG")
    if env and Path(env).exists():
        return env
    here = Path(__file__).resolve().parent.parent       # .../pipeline/
    local = here / "bin" / "ffmpeg"
    if local.exists():
        return str(local)
    return "ffmpeg"


def ffprobe_cmd():
    """ffprobe doesn't need libass — system ffprobe is fine."""
    return os.environ.get("SLATE_FFPROBE") or "ffprobe"


def ffmpeg_has_filter(name):
    try:
        r = subprocess.run([ffmpeg_cmd(), "-hide_banner", "-filters"],
                           capture_output=True, text=True)
        return any(line.split()[1:2] == [name] for line in r.stdout.splitlines()
                   if len(line.split()) > 1)
    except Exception:
        return False


def fmt_ts_srt(seconds):
    """SRT timestamp: HH:MM:SS,mmm"""
    if seconds < 0:
        seconds = 0
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return "%02d:%02d:%02d,%03d" % (h, m, s, ms)
