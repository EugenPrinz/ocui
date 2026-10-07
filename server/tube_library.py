#!/usr/bin/env python3
"""tube_library -- keeps a GitHub release ("videos") in sync with a
playlist file, for the ocui `tube` player. Runs inside the GitHub Actions
workflow of a videos repository (see tube-workflow.yml); uses the `gh` CLI.

videos.txt, one video per line (# starts a comment):

    # name      fps  source
    badapple    10   https://www.youtube.com/watch?v=FtutLA63Cp8
    demo        6    demo

  name    what you type in game: tube <name>   (letters, digits, - and _)
  fps     1..20; lower = sharper picture, choppier motion
  source  YouTube/any yt-dlp URL, a direct link to a video file, or demo;
          several separated by " | " are tried in order until one works
          (YouTube often refuses GitHub's servers, so put a mirror first)

    python tube_library.py sync videos.txt     # convert new/changed, delete removed
    python tube_library.py plan videos.txt     # only print what sync would do

The release also holds library.json (name -> source/fps/size), which is
how sync knows a video changed and what the player's library contains.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tube_server  # noqa: E402

RELEASE = "videos"
MANIFEST = "library.json"
MAX_SECONDS = 15 * 60
NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def parse_playlist(text):
    """Returns ({name: {"fps", "source"}}, [errors])."""
    entries, errors = {}, []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):  # whole-line comments only: URLs may contain '#'
            continue
        parts = line.split(None, 2)
        if len(parts) != 3:
            errors.append(f"line {lineno}: expected 'name fps source'")
            continue
        name, fps, source = parts
        if not NAME_RE.match(name):
            errors.append(f"line {lineno}: bad name {name!r} (letters, digits, - and _)")
            continue
        if not fps.isdigit() or not 1 <= int(fps) <= 20:
            errors.append(f"line {lineno}: fps must be 1..20")
            continue
        if name in entries:
            errors.append(f"line {lineno}: duplicate name {name!r}")
            continue
        entries[name] = {"fps": int(fps), "source": source.strip()}
    return entries, errors


def alternatives(source):
    """'a | b' -> ['a', 'b'] (URLs never contain ' | ')."""
    return [s.strip() for s in source.split(" | ") if s.strip()]


def plan(playlist, manifest, assets):
    """What to do: (convert: [name], delete: [name], keep: [name])."""
    convert, keep = [], []
    for name, entry in playlist.items():
        known = manifest.get(name)
        if (f"{name}.octv" in assets and known
                and known.get("source") == entry["source"] and known.get("fps") == entry["fps"]):
            keep.append(name)
        else:
            convert.append(name)
    delete = sorted(a[:-5] for a in assets if a.endswith(".octv") and a[:-5] not in playlist)
    return convert, delete, keep


# ------------------------------------------------------------------- gh --


def gh(*args, capture=False):
    result = subprocess.run(["gh", *args], check=True, text=True,
                            capture_output=capture)
    return result.stdout if capture else None


def ensure_release():
    try:
        gh("release", "view", RELEASE, capture=True)
    except subprocess.CalledProcessError:
        gh("release", "create", RELEASE, "--title", "tube videos", "--notes",
           "Videos converted for the ocui tube player (play one in game with: tube <name>). "
           "Managed by videos.txt -- don't upload here by hand.")


def release_assets():
    data = json.loads(gh("release", "view", RELEASE, "--json", "assets", capture=True))
    return {a["name"] for a in data.get("assets", [])}


def load_manifest(assets):
    if MANIFEST not in assets:
        return {}
    with tempfile.TemporaryDirectory() as tmp:
        gh("release", "download", RELEASE, "-p", MANIFEST, "-D", tmp)
        with open(os.path.join(tmp, MANIFEST), encoding="utf-8") as f:
            return json.load(f)


def save_manifest(manifest):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, MANIFEST)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
        gh("release", "upload", RELEASE, path, "--clobber")


# ----------------------------------------------------------------- main --


def summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    text = "\n".join(lines) + "\n"
    print(text)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)


def sync(playlist_path, dry_run=False):
    with open(playlist_path, encoding="utf-8") as f:
        playlist, errors = parse_playlist(f.read())
    for e in errors:
        print(f"::error::{playlist_path} {e}")
    if errors:
        return 1

    if dry_run:
        assets, manifest = set(), {}
    else:
        ensure_release()
        assets = release_assets()
        manifest = load_manifest(assets)
    to_convert, to_delete, keep = plan(playlist, manifest, assets)

    report = ["### tube library", ""]
    failed = []
    for name in to_delete:
        report.append(f"- removed `{name}`")
        if not dry_run:
            gh("release", "delete-asset", RELEASE, f"{name}.octv", "--yes")
        manifest.pop(name, None)
    for name in to_convert:
        entry = playlist[name]
        if dry_run:
            report.append(f"- would convert `{name}` at {entry['fps']} fps from {entry['source']}")
            continue
        out = f"{name}.octv"
        frames, used, attempts = None, None, []
        for src in alternatives(entry["source"]):
            try:
                frames = tube_server.convert(src, out, entry["fps"], 160, 50,
                                             tube_server.auto_budget(entry["fps"]), MAX_SECONDS, None)
                used = src
                break
            except Exception as e:  # noqa: BLE001 -- try the next source
                attempts.append(f"{src}: {e}")
                print(f"::warning::{name}: {src}: {e}")
        if frames is None:
            failed.append(name)
            report.append(f"- **FAILED** `{name}`: " + " || ".join(attempts))
            print(f"::error::{name}: every source failed")
            continue
        gh("release", "upload", RELEASE, out, "--clobber")
        size = os.path.getsize(out)
        manifest[name] = {"source": entry["source"], "used": used, "fps": entry["fps"],
                          "seconds": round(frames / entry["fps"]), "bytes": size}
        report.append(f"- converted `{name}` from {used}: {frames / entry['fps']:.0f} s, "
                      f"{size / 1048576:.2f} MB -- in game: `tube {name}`")
        for a in attempts:
            report.append(f"  - skipped {a}")
    for name in keep:
        report.append(f"- unchanged `{name}`")
    if not dry_run:
        save_manifest(manifest)
        repo = os.environ.get("GITHUB_REPOSITORY", "<you>/<repo>")
        report += ["", f"Library URL (tube.cfg): https://github.com/{repo}/releases/download/{RELEASE}/"]
    summary(report)
    return 1 if failed else 0


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("sync", "plan"):
        sys.exit(__doc__)
    sys.exit(sync(sys.argv[2], dry_run=sys.argv[1] == "plan"))


if __name__ == "__main__":
    main()
