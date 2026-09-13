#!/usr/bin/env python3
"""
Bulk-import embedded LRC lyrics from a music library into the DMS Lyrics Bar
cache (~/.cache/Lyrics/).

File naming mirrors LyricsBar.qml exactly:
  cacheKey   = fnv1a32((title + "\\x00" + artist).toLowerCase())
  final      = f"{sanitized title} - {sanitized artist}_{cacheKey}.json"

Features:
  - Parallel scanning with ffprobe
  - Traditional -> simplified conversion via OpenCC (optional)
  - WAV tag mojibake recovery (falls back to filename)
  - Non-standard lyric tag names (LYRICS-XXX) via prefix matching
  - --artist-hints for files whose tags are unreadable
  - Suspicious-title reporting
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_MUSIC_DIR = Path.home() / "Music"

# Filled in by parse_args() before any work happens.
MUSIC_DIR = Path(os.environ.get("LYRICS_MUSIC_DIR") or DEFAULT_MUSIC_DIR)
CACHE_DIR = Path.home() / ".cache" / "Lyrics"

AUDIO_EXT = {".flac", ".mp3", ".ogg", ".m4a", ".wma", ".aac", ".opus", ".ape", ".wav"}
LYRIC_TAGS = ("LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS")
# Some taggers write non-standard names such as `LYRICS-XXX` (seen on WAV files
# produced by Sound Forge). Match those by prefix as a fallback.
LYRIC_TAG_PREFIXES = ("LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS", "LYRIC")
# source id 4 == embedded extraction, matching the plugin's own convention
SOURCE_EMBEDDED = 4

# Matches every plugin-side helper so the cache stays readable by the QML.
_ILLEGAL = re.compile(r'[/\\:*?"<>|\x00-\x1f]')
_TIMESTAMP = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")
# Garbled tags arrive in a few shapes. ffprobe most often emits U+FFFD
# (the Unicode replacement character) plus stray codepoints when it cannot
# decode a tag, which is unrecoverable. A pure Latin-1 run is the other
# common shape. Either way the filename is the better source.
_MOJIBAKE = re.compile(r"[\ufffd]|[\u0080-\u00ff]{2,}")

# Convert traditional lyrics to simplified during import (overridable with
# --no-simplify). Local libraries are usually simplified already, so this only
# affects rips whose embedded lyrics are traditional.
CONVERT_TO_SIMPLIFIED = True

# True when filenames are "Artist - Title"; False for "Title - Artist".
# Overridable with --artist-first. Most libraries put the title first.
FILENAME_ARTIST_LAST = True

# Optional map of filename-stem (or one side of it) -> real artist name, used
# to disambiguate the filename order when tags are unreadable.
ARTIST_HINTS: dict[str, str] = {}

# Names collected during the run that still look wrong, reported at the end.
REPORT_SUSPICIOUS: set[str] = set()


def _looks_garbled(text: str) -> bool:
    """
    Heuristic for a tag that cannot be right.

    Beyond the obvious U+FFFD / Latin-1 runs, this catches short garbled values
    such as a misread of 唯一 that contain no replacement character at all.
    """
    if not text:
        return False
    if _MOJIBAKE.search(text):
        return True
    unusual = sum(
        1 for ch in text
        if not (
            "\u4e00" <= ch <= "\u9fff"
            or "\u3040" <= ch <= "\u30ff"
            or ch.isascii() and (ch.isalnum() or ch in " -_&'.,()[]!?+/:")
            or ch.isspace()
        )
    )
    return unusual >= 2 or (unusual >= 1 and len(text) <= 3)


def _same_text(a: str, b: str) -> bool:
    norm = lambda s: re.sub(r"\s+", "", (s or "")).lower()
    return bool(a) and bool(b) and norm(a) == norm(b)


# 著 means "to write / famous" (zhù) in these contexts and keeps its form.
_ZHU_CONTEXT = re.compile(r"著[作名述称者]|[编論论专專原]著")


def _fix_zhe(text: str) -> str:
    """OpenCC leaves 著 alone (valid simplified in 著作), but lyrics use zhe."""
    if "著" not in text:
        return text
    out = []
    for i, ch in enumerate(text):
        if ch == "著":
            window = text[max(0, i - 1):i + 2]
            out.append("著" if _ZHU_CONTEXT.search(window) else "着")
        else:
            out.append(ch)
    return "".join(out)


def opencc_available() -> bool:
    return shutil.which("opencc") is not None


def to_simplified(text: str) -> str:
    """
    Convert traditional lyrics to simplified via OpenCC.

    OpenCC is an OPTIONAL external dependency, not bundled here. When it is
    absent the text is returned unchanged (fail open) and main() prints a hint.
    """
    if not text or not opencc_available():
        return text
    try:
        result = subprocess.run(["opencc", "-c", "t2s"], input=text,
                                capture_output=True, text=True, timeout=30)
        if result.returncode == 0 and result.stdout:
            return _fix_zhe(result.stdout)
    except (subprocess.SubprocessError, OSError):
        pass
    return text


def fnv1a32(text: str) -> str:
    h = 0x811C9DC5
    for ch in text:
        h = ((h ^ ord(ch)) * 0x01000193) & 0xFFFFFFFF
    return f"{h:08x}"


def sanitize(name: str) -> str:
    return _ILLEGAL.sub("_", name).strip().strip(".")


def truncate_utf8(text: str, limit: int = 190) -> str:
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text
    return data[:limit].decode("utf-8", errors="ignore")


def cache_key(title: str, artist: str) -> str:
    return fnv1a32(f"{title}\x00{artist}".lower())


def cache_path(title: str, artist: str) -> Path:
    readable = truncate_utf8(f"{sanitize(title)} - {sanitize(artist)}")
    return CACHE_DIR / f"{readable}_{cache_key(title, artist)}.json"


def parse_lrc(text: str) -> list[dict]:
    lines: list[dict] = []
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        stamps = _TIMESTAMP.findall(raw)
        content = _TIMESTAMP.sub("", raw).strip()
        if not content:
            continue
        if stamps:
            for mins, secs in stamps:
                lines.append(
                    {"time": round(int(mins) * 60 + float(secs), 2), "text": content}
                )
        elif lines:
            lines.append({"time": lines[-1]["time"], "text": content})
    seen: set[tuple] = set()
    unique: list[dict] = []
    for line in lines:
        pair = (line["time"], line["text"])
        if pair not in seen:
            seen.add(pair)
            unique.append(line)
    return unique


def probe(path: Path) -> dict | None:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", str(path)],
            capture_output=True, text=True, timeout=60,
        )
        if out.returncode != 0:
            return None
        return json.loads(out.stdout).get("format", {}).get("tags", {}) or {}
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return None


def import_one(path: Path) -> str:
    tags = probe(path)
    if not tags:
        return "unreadable"

    upper = {k.upper(): v for k, v in tags.items()}
    title = (upper.get("TITLE") or "").strip()
    artist = (upper.get("ARTIST") or "").strip()

    if not title or _looks_garbled(title) or _looks_garbled(artist):
        stem = path.stem
        parts = [p.strip() for p in re.split(r"\s*-\s*", stem) if p.strip()]
        file_title = stem
        file_artist = ""
        if len(parts) >= 2:
            left, right = parts[0], " - ".join(parts[1:])
            hint = (ARTIST_HINTS.get(stem) or ARTIST_HINTS.get(left)
                    or ARTIST_HINTS.get(right) or "").strip()
            if hint and (_same_text(right, hint) or _same_text(left, hint)):
                file_artist = hint
                file_title = left if _same_text(right, hint) else right
            elif hint:
                file_artist = hint
                file_title = left if not _same_text(left, hint) else right
            else:
                file_title, file_artist = ((left, right) if FILENAME_ARTIST_LAST
                                           else (right, left))
        else:
            file_title = stem
            file_artist = (ARTIST_HINTS.get(stem) or "").strip()

        if not title or _looks_garbled(title):
            title = file_title
        if _looks_garbled(artist) or not artist:
            artist = file_artist

    if not title:
        return "no-title"

    if _looks_garbled(title) or _looks_garbled(artist):
        REPORT_SUSPICIOUS.add(f"{path.name}  ->  title={title!r} artist={artist!r}")

    raw = next((upper[t] for t in LYRIC_TAGS if upper.get(t)), None)
    if not raw:
        for key, value in upper.items():
            if value and key.startswith(LYRIC_TAG_PREFIXES):
                raw = value
                break
    if not raw:
        return "no-lyrics"

    if CONVERT_TO_SIMPLIFIED:
        raw = to_simplified(raw)

    lines = parse_lrc(raw)
    if not lines:
        return "unparsable"

    target = cache_path(title, artist)

    offset = 0
    if target.exists():
        try:
            old = json.loads(target.read_text(encoding="utf-8"))
            if isinstance(old.get("offset"), (int, float)):
                offset = old["offset"]
            if old.get("lines"):
                return "already-cached"
        except (json.JSONDecodeError, OSError):
            pass

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "lines": lines,
        "source": SOURCE_EMBEDDED,
        "cachedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "offset": offset,
    }
    tmp = target.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(target)
    return "imported"


def parse_args(argv: list[str]) -> None:
    global MUSIC_DIR, FILENAME_ARTIST_LAST, ARTIST_HINTS, CONVERT_TO_SIMPLIFIED

    ap = argparse.ArgumentParser(
        description="Import embedded LRC lyrics into the DMS Lyrics Bar cache."
    )
    ap.add_argument("music_dir", nargs="?", default=str(MUSIC_DIR),
                    help="directory to scan (default: $LYRICS_MUSIC_DIR or ~/Music)")
    ap.add_argument("--no-simplify", action="store_true",
                    help="keep traditional characters (default: convert to simplified)")
    ap.add_argument("--artist-first", action="store_true",
                    help='filenames are "Artist - Title" instead of default "Title - Artist"')
    ap.add_argument("--artist-hints", metavar="JSON",
                    help="JSON file mapping a filename to the real artist name")
    args = ap.parse_args(argv)

    MUSIC_DIR = Path(args.music_dir).expanduser()
    FILENAME_ARTIST_LAST = not args.artist_first
    CONVERT_TO_SIMPLIFIED = not args.no_simplify

    if args.artist_hints:
        try:
            data = json.loads(Path(args.artist_hints).read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("expected a JSON object")
            ARTIST_HINTS = {str(k): str(v) for k, v in data.items()}
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"ERROR: cannot read --artist-hints: {exc}", file=sys.stderr)
            raise SystemExit(1)


def main() -> int:
    if not MUSIC_DIR.is_dir():
        print(f"ERROR: music dir not found: {MUSIC_DIR}", file=sys.stderr)
        return 1

    files = sorted(
        p for p in MUSIC_DIR.rglob("*") if p.is_file() and p.suffix.lower() in AUDIO_EXT
    )
    print(f"Scanning {len(files)} audio files under {MUSIC_DIR}\n")

    tally: dict[str, int] = {}
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        for result in pool.map(import_one, files):
            tally[result] = tally.get(result, 0) + 1

    labels = {
        "imported": "导入",
        "already-cached": "已存在(跳过)",
        "no-lyrics": "无内嵌歌词",
        "no-title": "无标题标签",
        "unparsable": "歌词无法解析",
        "unreadable": "文件读取失败",
    }
    print()
    for key in ("imported", "already-cached", "no-lyrics", "no-title", "unparsable", "unreadable"):
        if tally.get(key):
            print(f"  {labels[key]}: {tally[key]}")

    suspicious = sorted(REPORT_SUSPICIOUS)
    if suspicious:
        print(f"\n⚠ {len(suspicious)} 首的标题/歌手可能仍是乱码（缓存键将无法匹配）：")
        for name in suspicious[:20]:
            print(f"    {name}")
        if len(suspicious) > 20:
            print(f"    … 另有 {len(suspicious) - 20} 首")
        print("  处理：用 --artist-hints 提供正确名称，或重新标记这些文件。")

    if CONVERT_TO_SIMPLIFIED and not opencc_available():
        print("\n⚠ 已请求繁体转简体，但未安装 OpenCC，本次导入保留了原始字形。")
        print("  安装后重新运行即可转换：")
        print("    Fedora: sudo dnf install opencc-tools")
        print("    Arch:   sudo pacman -S opencc")
        print("    Debian: sudo apt install opencc")

    print(f"\n缓存目录: {CACHE_DIR}  (共 {len(list(CACHE_DIR.glob('*.json')))} 个文件)")
    return 0


if __name__ == "__main__":
    parse_args(sys.argv[1:])
    raise SystemExit(main())
