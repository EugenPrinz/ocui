#!/usr/bin/env python3
"""tube_server -- streams video to OpenComputers as half-block frames for
the ocui `tube` player.

Runs on a normal PC. For each connection it decodes the requested video
(YouTube/any yt-dlp URL, a local file, or the built-in `demo`), scales it
to the player's text grid with two pixels per character cell (the upper
half block "\u2580": foreground = top pixel, background = bottom pixel),
maps the colors onto the exact 256-color palette of a tier 3 screen, and
sends only what changed -- within a byte budget per frame, because an
Internet Card reads at most 2048 bytes per server tick (~40 KB/s).

Requirements: Python 3.8+. For URLs: yt-dlp + ffmpeg in PATH; for files:
ffmpeg. The `demo` source needs nothing.

    python tube_server.py                  # listen on 127.0.0.1:4123
    python tube_server.py --host 0.0.0.0 --port 4123 --media D:\\videos

In single-player, OpenComputers blocks connections to private addresses
by default: add "allow ip:127.0.0.1" before "deny private" in
filteringRules in config/OpenComputers.cfg.

Protocol v1 (TCP, all integers big-endian, unsigned)
----------------------------------------------------
client -> server, one line:
    PLAY fps=<1..30> cols=<1..255> rows=<1..255> budget=<bytes/frame, 0=unlimited> src=<source>\\n
  then optionally, any time:  PAUSE\\n  RESUME\\n  STOP\\n
server -> client:
    "OCTV" u8 version=1, u8 cols, u8 rows, u8 fps
    then messages:
      'F' u24 len, payload      frame delta
      'M' u16 len, utf-8        info text (title)
      'E' u16 len, utf-8        end of stream / error text; server closes
  frame payload:
      u16 groupCount, then per group:
        u8 fg, u8 bg (palette indices), u16 runCount, then per run:
          u8 x, u8 y (0-based cell), u8 length
      every cell of a run shows "\u2580" with that fg/bg.
  The client starts from a screen cleared to palette index 16 (black).
"""

import argparse
import importlib.util
import math
import os
import select
import shutil
import socket
import subprocess
import sys
import threading
import time

VERSION = 1
DEFAULT_PORT = 4123
BLACK = 16  # palette index of 0x000000 in the color cube

# --------------------------------------------------------------- palette --


def oc_palette():
    """The 256 colors of an OpenComputers tier 3 screen (8-bit depth), as in
    li.cil.oc.util.PackedColor.HybridFormat: 16 grays (the default
    palette) followed by a 6x8x5 RGB cube."""
    pal = []
    for i in range(16):
        shade = 255 * (i + 1) // 17
        pal.append((shade, shade, shade))
    for index in range(240):
        b = index % 5
        g = (index // 5) % 8
        r = (index // 40) % 6
        pal.append((int(r * 255 / 5 + 0.5), int(g * 255 / 7 + 0.5), int(b * 255 / 4 + 0.5)))
    return pal


PALETTE = oc_palette()


def color_distance(c1, c2):
    """Perceptual-ish RGB distance ("redmean")."""
    r1, g1, b1 = c1
    r2, g2, b2 = c2
    rm = (r1 + r2) / 2
    dr, dg, db = r1 - r2, g1 - g2, b1 - b2
    return math.sqrt((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db)


# DIST[a][b]: distance between palette entries, for change weights
DIST = [[color_distance(a, b) for b in PALETTE] for a in PALETTE]


class Quantizer:
    """Nearest palette index for an RGB color, cached at 5 bits/channel."""

    def __init__(self):
        self.lut = [-1] * 32768

    def nearest(self, rgb):
        best, best_d = 0, float("inf")
        for i, p in enumerate(PALETTE):
            d = color_distance(rgb, p)
            if d < best_d:
                best, best_d = i, d
        return best

    def index(self, r, g, b):
        key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
        v = self.lut[key]
        if v < 0:
            # bucket center
            v = self.nearest(((r >> 3) * 8 + 4, (g >> 3) * 8 + 4, (b >> 3) * 8 + 4))
            self.lut[key] = v
        return v


def frame_to_cells(rgb, cols, rows, quant):
    """rgb24 bytes of a cols x (rows*2) image -> list of top*256+bottom."""
    width3 = cols * 3
    lut = quant.lut
    index = quant.index
    cells = [0] * (cols * rows)
    k = 0
    for y in range(rows):
        top = 2 * y * width3
        bot = top + width3
        for x in range(cols):
            i = top + 3 * x
            r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
            t = lut[((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)]
            if t < 0:
                t = index(r, g, b)
            i = bot + 3 * x
            r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
            u = lut[((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)]
            if u < 0:
                u = index(r, g, b)
            cells[k] = (t << 8) | u
            k += 1
    return cells


# --------------------------------------------------------------- encoder --


class Encoder:
    """Delta encoder against what the client currently shows. With a byte
    budget, sends the most visible changes first; the rest stays pending
    (and gains priority with age) for the next frames."""

    AGE_BONUS = 0.25  # weight multiplier added per frame a change waits

    def __init__(self, cols, rows, budget=0):
        self.cols, self.rows, self.budget = cols, rows, budget
        n = cols * rows
        self.sent = [(BLACK << 8) | BLACK] * n
        self.age = [0] * n

    def encode(self, cells):
        cols, rows = self.cols, self.rows
        sent, age = self.sent, self.age
        runs = []  # (score, x, y, length, pair)
        total = 2
        groups_seen = set()
        for y in range(rows):
            base = y * cols
            x = 0
            while x < cols:
                i = base + x
                c = cells[i]
                if sent[i] == c:
                    age[i] = 0
                    x += 1
                    continue
                start = x
                weight = 0.0
                ct, cb = c >> 8, c & 0xFF
                while x < cols and x - start < 255:
                    j = base + x
                    if cells[j] != c or sent[j] == c:
                        break
                    s = sent[j]
                    weight += (DIST[s >> 8][ct] + DIST[s & 0xFF][cb]) * (1 + self.AGE_BONUS * age[j])
                    x += 1
                runs.append((weight, start, y, x - start, c))
                total += 3
                if c not in groups_seen:
                    groups_seen.add(c)
                    total += 4

        if self.budget > 0 and total > self.budget:
            runs.sort(key=lambda r: r[0], reverse=True)
            chosen, used, groups_seen = [], 2, set()
            for run in runs:
                cost = 3 + (0 if run[4] in groups_seen else 4)
                if used + cost > self.budget:
                    continue
                used += cost
                groups_seen.add(run[4])
                chosen.append(run)
        else:
            chosen = runs

        # apply: chosen cells are now shown; changed-but-unsent cells age
        chosen_cells = set()
        groups = {}
        for _, x, y, n, c in chosen:
            groups.setdefault(c, []).append((x, y, n))
            base = y * cols + x
            for j in range(base, base + n):
                sent[j] = c
                age[j] = 0
                chosen_cells.add(j)
        if len(chosen) < len(runs):
            for _, x, y, n, c in runs:
                base = y * cols + x
                for j in range(base, base + n):
                    if j not in chosen_cells:
                        age[j] += 1

        out = bytearray(len(groups).to_bytes(2, "big"))
        for c, rs in groups.items():
            out += bytes((c >> 8, c & 0xFF))
            out += len(rs).to_bytes(2, "big")
            for x, y, n in rs:
                out += bytes((x, y, n))
        return bytes(out)


def frame_message(payload):
    return b"F" + len(payload).to_bytes(3, "big") + payload


def text_message(kind, text):
    data = text.encode("utf-8")[:65535]
    return kind + len(data).to_bytes(2, "big") + data


def stream_header(cols, rows, fps):
    return b"OCTV" + bytes((VERSION, cols, rows, fps))


# --------------------------------------------------------------- sources --


class DemoSource:
    """Procedural animation: drifting color bands and a bouncing ball. Needs
    no external tools -- for checking the in-game setup."""

    title = "demo (built-in test animation)"

    def __init__(self, width, height, fps, seconds=120):
        self.w, self.h, self.fps = width, height, fps
        self.frames = int(seconds * fps)
        self.i = 0

    def read_frame(self):
        if self.i >= self.frames:
            return None
        t = self.i / self.fps
        self.i += 1
        w, h = self.w, self.h
        bx = (math.sin(t * 1.3) * 0.5 + 0.5) * (w - 1)
        by = abs(math.sin(t * 2.1)) * (h - 1)
        radius = max(min(w, h) / 6, 2)
        out = bytearray(w * h * 3)
        k = 0
        for y in range(h):
            for x in range(w):
                dx, dy = x - bx, y - by
                if dx * dx + dy * dy <= radius * radius:
                    r, g, b = 255, 255, 255
                else:
                    v = (x / w + t * 0.15) % 1.0
                    r = int(127 + 127 * math.sin(6.283 * v))
                    g = int(127 + 127 * math.sin(6.283 * (v + 0.33)))
                    b = int(127 + 127 * math.sin(6.283 * (v + 0.66)) * (1 - y / h))
                out[k], out[k + 1], out[k + 2] = r, g, max(b, 0)
                k += 3
        return bytes(out)

    def close(self):
        pass


def find_ytdlp():
    exe = shutil.which("yt-dlp")
    if exe:
        return [exe]
    if importlib.util.find_spec("yt_dlp"):
        return [sys.executable, "-m", "yt_dlp"]
    return None


class FFmpegSource:
    """Decodes with ffmpeg into rgb24 frames scaled/padded to the grid.
    Sources: "test" (ffmpeg pattern); an http(s) link straight to a video
    file (read by ffmpeg); any other URL (fetched by yt-dlp and piped in);
    a local path -- confined to `media_dir` when one is given (the live
    server), unrestricted when it is None (--convert on your own machine)."""

    VIDEO_EXTENSIONS = (".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v")

    def __init__(self, src, width, height, fps, media_dir, max_seconds=None):
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise RuntimeError("ffmpeg not found in PATH")
        self.w, self.h = width, height
        self.procs = []
        vf = (f"fps={fps},scale={width}:{height}:force_original_aspect_ratio=decrease:flags=area,"
              f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1")
        out_args = ["-an", "-vf", vf, "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]
        if max_seconds:
            out_args = ["-t", str(max_seconds)] + out_args
        stdin = None
        if src == "test":
            in_args = ["-f", "lavfi", "-i", f"testsrc2=size=320x200:rate={fps}", "-t", "60"]
            self.title = "ffmpeg test pattern"
        elif src.startswith(("http://", "https://")):
            if src.lower().split("?")[0].endswith(self.VIDEO_EXTENSIONS):
                self.title = src.split("?")[0].rsplit("/", 1)[-1] or src
                in_args = ["-i", src]
            else:
                ytdlp = find_ytdlp()
                if not ytdlp:
                    raise RuntimeError("yt-dlp not found (pip install yt-dlp)")
                self.title = self._title(ytdlp, src)
                dl = subprocess.Popen(
                    ytdlp + ["-q", "--no-warnings", "-f", "bv*[height<=480]/b[height<=480]/wv*/w",
                             "-o", "-", src],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self._tail(dl, "yt-dlp")
                self.procs.append(dl)
                stdin = dl.stdout
                in_args = ["-i", "pipe:0"]
        elif media_dir is None:
            if not os.path.isfile(src):
                raise RuntimeError(f"no such file: {src}")
            self.title = os.path.basename(src)
            in_args = ["-i", src]
        else:
            path = os.path.realpath(os.path.join(media_dir, src))
            root = os.path.realpath(media_dir)
            if not (path == root or path.startswith(root + os.sep)) or not os.path.isfile(path):
                raise RuntimeError(f"no such file in the media directory: {src}")
            self.title = os.path.basename(path)
            in_args = ["-i", path]
        self.ff = subprocess.Popen(
            [ffmpeg, "-hide_banner", "-loglevel", "error"] + in_args + out_args,
            stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self._tail(self.ff, "ffmpeg")
        self.procs.append(self.ff)

    # last lines of each tool's stderr, for error reports
    def _tail(self, proc, label):
        if not hasattr(self, "stderr_tails"):
            self.stderr_tails = {}
        lines = []
        self.stderr_tails[label] = lines

        def pump():
            for raw in proc.stderr:
                text = raw.decode("utf-8", "replace").rstrip()
                if text:
                    print(f"[{label}] {text}", file=sys.stderr, flush=True)
                    lines.append(text)
                    del lines[:-8]

        threading.Thread(target=pump, daemon=True).start()

    def diagnostics(self):
        """What the external tools complained about (empty if nothing)."""
        for p in self.procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        time.sleep(0.2)  # let the stderr pumps drain
        parts = []
        for label, lines in getattr(self, "stderr_tails", {}).items():
            if lines:
                parts.append(f"{label}: " + " / ".join(lines[-3:]))
        return "; ".join(parts)

    def _title(self, ytdlp, url):
        try:
            out = subprocess.run(ytdlp + ["--no-warnings", "--skip-download", "--print", "title", url],
                                 capture_output=True, text=True, timeout=60)
            title = out.stdout.strip().splitlines()
            if not title and out.stderr.strip():
                print(f"[yt-dlp] {out.stderr.strip()}", file=sys.stderr, flush=True)
            return title[0] if title else url
        except (OSError, subprocess.SubprocessError):
            return url

    def read_frame(self):
        size = self.w * self.h * 3
        buf = bytearray()
        while len(buf) < size:
            chunk = self.ff.stdout.read(size - len(buf))
            if not chunk:
                return None
            buf += chunk
        return bytes(buf)

    def close(self):
        for p in self.procs:
            try:
                p.kill()
            except OSError:
                pass


def open_source(src, width, height, fps, media_dir, max_seconds=None):
    if src == "demo":
        return DemoSource(width, height, fps, seconds=min(max_seconds or 120, 120))
    return FFmpegSource(src, width, height, fps, media_dir, max_seconds)


def auto_budget(fps):
    """Bytes per frame an Internet Card can take: ~20 reads of 2048 bytes
    per second, minus about one tick per frame for pushing the picture to
    the screen, with some slack. Mirrors ocui.apps.tube.autoBudget."""
    reads_per_second = max(20 - fps, 2)
    return int(reads_per_second * 2048 * 0.85 / fps)


def convert(src, out_path, fps, cols, rows, budget, max_seconds, media_dir, log=print):
    """Encodes a whole video into a .octv file (the same stream the live
    server sends) for playback over HTTP, e.g. from a GitHub release."""
    source = open_source(src, cols, rows * 2, fps, media_dir, max_seconds)
    try:
        quant = Quantizer()
        enc = Encoder(cols, rows, budget)
        frames = 0
        size = 0
        with open(out_path, "wb") as out:
            for chunk in (stream_header(cols, rows, fps), text_message(b"M", source.title)):
                out.write(chunk)
                size += len(chunk)
            while True:
                rgb = source.read_frame()
                if rgb is None:
                    break
                msg = frame_message(enc.encode(frame_to_cells(rgb, cols, rows, quant)))
                out.write(msg)
                size += len(msg)
                frames += 1
                if frames % (fps * 30) == 0:
                    log(f"  {frames // fps} s encoded ({size / 1048576:.1f} MB)")
            end = text_message(b"E", "end of video")
            out.write(end)
            size += len(end)
        if frames == 0:
            why = source.diagnostics() if hasattr(source, "diagnostics") else ""
            raise RuntimeError("no frames decoded" + (f" -- {why}" if why else
                                                      " (unsupported or unreachable source?)"))
        log(f"{source.title}: {frames} frames, {frames / fps:.0f} s, {size / 1048576:.2f} MB -> {out_path}")
        return frames
    finally:
        source.close()


# --------------------------------------------------------------- session --


def parse_request(line):
    """'PLAY fps=6 cols=160 rows=50 budget=4500 src=<rest of line>'"""
    line = line.strip()
    if not line.startswith("PLAY "):
        raise ValueError("expected PLAY")
    head, sep, src = line[5:].partition("src=")
    if not sep or not src.strip():
        raise ValueError("missing src=")
    opts = {}
    for part in head.split():
        k, _, v = part.partition("=")
        opts[k] = v
    req = {
        "fps": int(opts.get("fps", 6)),
        "cols": int(opts.get("cols", 160)),
        "rows": int(opts.get("rows", 50)),
        "budget": int(opts.get("budget", 0)),
        "src": src.strip(),
    }
    if not (1 <= req["fps"] <= 30 and 1 <= req["cols"] <= 255 and 1 <= req["rows"] <= 255):
        raise ValueError("fps/cols/rows out of range")
    return req


def read_line(conn, limit=4096):
    data = bytearray()
    while not data.endswith(b"\n"):
        chunk = conn.recv(1)
        if not chunk:
            break
        data += chunk
        if len(data) > limit:
            raise ValueError("request too long")
    return data.decode("utf-8", "replace")


def serve_client(conn, addr, media_dir, log):
    source = None
    try:
        conn.settimeout(15)
        try:
            req = parse_request(read_line(conn))
        except ValueError as e:
            conn.sendall(stream_header(1, 1, 1) + text_message(b"E", f"bad request: {e}"))
            return
        cols, rows, fps = req["cols"], req["rows"], req["fps"]
        log(f"{addr[0]}: {req['src']} {cols}x{rows}@{fps} budget={req['budget']}")
        conn.sendall(stream_header(cols, rows, fps))
        try:
            source = open_source(req["src"], cols, rows * 2, fps, media_dir)
        except Exception as e:  # noqa: BLE001 -- reported to the player
            conn.sendall(text_message(b"E", f"cannot open {req['src']}: {e}"))
            return
        conn.sendall(text_message(b"M", source.title))
        conn.settimeout(None)

        quant = Quantizer()
        enc = Encoder(cols, rows, req["budget"])
        period = 1.0 / fps
        start = time.monotonic()
        n = 0
        paused = False
        pending = b""
        while True:
            # control commands (non-blocking)
            while select.select([conn], [], [], 0)[0]:
                data = conn.recv(1024)
                if not data:
                    return
                pending += data
                while b"\n" in pending:
                    cmd, pending = pending.split(b"\n", 1)
                    cmd = cmd.strip().upper()
                    if cmd == b"PAUSE":
                        paused = True
                    elif cmd == b"RESUME" and paused:
                        paused = False
                        start = time.monotonic() - n * period
                    elif cmd == b"STOP":
                        return
            if paused:
                time.sleep(0.05)
                continue

            rgb = source.read_frame()
            if rgb is None:
                conn.sendall(text_message(b"E", "end of video"))
                return
            n += 1
            due = start + n * period
            now = time.monotonic()
            if now > due + period:
                continue  # behind (slow client/decoder): skip this frame
            conn.sendall(frame_message(enc.encode(frame_to_cells(rgb, cols, rows, quant))))
            delay = due - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    except (ConnectionError, OSError) as e:
        log(f"{addr[0]}: connection ended ({e})")
    finally:
        if source:
            source.close()
        try:
            conn.close()
        except OSError:
            pass


def serve(host, port, media_dir):
    def log(msg):
        print(time.strftime("%H:%M:%S"), msg, flush=True)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(4)
    log(f"tube_server listening on {host}:{port}, media dir {os.path.abspath(media_dir)}")
    if not shutil.which("ffmpeg"):
        log("note: ffmpeg not found -- only src=demo will work")
    elif not find_ytdlp():
        log("note: yt-dlp not found -- URLs won't work (pip install yt-dlp)")
    try:
        while True:
            conn, addr = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=serve_client, args=(conn, addr, media_dir, log), daemon=True).start()
    except KeyboardInterrupt:
        log("bye")


# ----------------------------------------------------------------- tests --


def decode_stream(data):
    """Reference decoder (mirrors ocui/tubeproto.lua): returns (header,
    final cells, frame count, texts)."""
    assert data[:4] == b"OCTV", "bad magic"
    _, cols, rows, fps = data[4:8]
    cells = [(BLACK << 8) | BLACK] * (cols * rows)
    i, frames, texts = 8, 0, []
    while i < len(data):
        kind = data[i:i + 1]
        if kind == b"F":
            n = int.from_bytes(data[i + 1:i + 4], "big")
            p, end = i + 4, i + 4 + n
            groups = int.from_bytes(data[p:p + 2], "big")
            p += 2
            for _ in range(groups):
                fg, bg = data[p], data[p + 1]
                runs = int.from_bytes(data[p + 2:p + 4], "big")
                p += 4
                for _ in range(runs):
                    x, y, ln = data[p], data[p + 1], data[p + 2]
                    p += 3
                    for k in range(ln):
                        cells[y * cols + x + k] = (fg << 8) | bg
            assert p == end, "frame length mismatch"
            i = end
            frames += 1
        else:
            n = int.from_bytes(data[i + 1:i + 3], "big")
            texts.append((kind.decode(), data[i + 3:i + 3 + n].decode("utf-8")))
            i += 3 + n
    return (cols, rows, fps), cells, frames, texts


def synthetic_stream(cols, rows, fps, frames, budget):
    src = DemoSource(cols, rows * 2, fps, seconds=frames / fps)
    quant = Quantizer()
    enc = Encoder(cols, rows, budget)
    out = bytearray(stream_header(cols, rows, fps) + text_message(b"M", src.title))
    while True:
        rgb = src.read_frame()
        if rgb is None:
            break
        out += frame_message(enc.encode(frame_to_cells(rgb, cols, rows, quant)))
    out += text_message(b"E", "end of video")
    return bytes(out), enc.sent


def selftest():
    # palette matches OpenComputers' formulas
    assert len(PALETTE) == 256 and PALETTE[BLACK] == (0, 0, 0) and PALETTE[255] == (255, 255, 255)
    assert PALETTE[0] == (15, 15, 15) and PALETTE[15] == (240, 240, 240)
    q = Quantizer()
    assert q.index(0, 0, 0) == BLACK and q.index(255, 255, 255) == 255
    # unlimited budget: decoded stream == every frame exactly
    for budget in (0, 300):
        data, sent = synthetic_stream(40, 12, 10, 30, budget)
        (cols, rows, fps), cells, frames, texts = decode_stream(data)
        assert (cols, rows, fps) == (40, 12, 10) and frames == 30
        assert cells == sent, "decoder state must equal encoder's view of the client"
        assert texts[-1] == ("E", "end of video")
        if budget:
            sizes, i = [], 8
            while i < len(data):
                if data[i:i + 1] == b"F":
                    n = int.from_bytes(data[i + 1:i + 4], "big")
                    sizes.append(n)
                    i += 4 + n
                else:
                    i += 3 + int.from_bytes(data[i + 1:i + 3], "big")
            assert max(sizes) <= budget, f"frame over budget: {max(sizes)}"
    # a full last frame is reproduced exactly without a budget
    src = DemoSource(40, 24, 10, seconds=1)
    frames = []
    while True:
        f = src.read_frame()
        if f is None:
            break
        frames.append(f)
    enc = Encoder(40, 12)
    for f in frames:
        enc.encode(frame_to_cells(f, 40, 12, q))
    assert enc.sent == frame_to_cells(frames[-1], 40, 12, q)
    assert parse_request("PLAY fps=6 cols=160 rows=50 budget=4500 src=https://x.y/watch?v=a b")["src"] \
        == "https://x.y/watch?v=a b"
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--media", default=".", help="directory local files are played from")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--convert", metavar="SRC",
                    help="encode SRC (URL, video file or 'demo') into a .octv file for HTTP playback")
    ap.add_argument("--out", metavar="FILE", help="output file for --convert")
    ap.add_argument("--max-seconds", type=int, default=600, help="--convert: cut the video after this long")
    ap.add_argument("--dump-synthetic", metavar="OUT",
                    help="(tests) write a demo stream to OUT and the expected final cells to OUT.cells")
    ap.add_argument("--frames", type=int, default=30, help="(tests) frames for --dump-synthetic")
    ap.add_argument("--cols", type=int, help="grid width in cells (convert: 160, tests: 40)")
    ap.add_argument("--rows", type=int, help="grid height in cells (convert: 50, tests: 12)")
    ap.add_argument("--fps", type=int, help="frames per second (convert: 6, tests: 10)")
    ap.add_argument("--budget", type=int,
                    help="bytes per frame (convert: derived from fps; tests: 0 = unlimited)")
    args = ap.parse_args()
    if args.selftest:
        selftest()
    elif args.convert:
        fps = args.fps or 6
        if not args.out:
            ap.error("--convert needs --out FILE")
        if not 1 <= fps <= 30:
            ap.error("--fps must be 1..30")
        budget = args.budget if args.budget is not None else auto_budget(fps)
        try:
            convert(args.convert, args.out, fps, args.cols or 160, args.rows or 50, budget,
                    args.max_seconds, None)
        except RuntimeError as e:
            sys.exit(f"convert failed: {e}")
    elif args.dump_synthetic:
        args.cols, args.rows = args.cols or 40, args.rows or 12
        args.fps, args.budget = args.fps or 10, args.budget or 0
        data, sent = synthetic_stream(args.cols, args.rows, args.fps, args.frames, args.budget)
        with open(args.dump_synthetic, "wb") as f:
            f.write(data)
        with open(args.dump_synthetic + ".cells", "w") as f:
            f.write(" ".join(str(c) for c in sent))
    else:
        serve(args.host, args.port, args.media)


if __name__ == "__main__":
    main()
