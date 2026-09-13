#!/usr/bin/env python3
"""
Bulk-import embedded LRC lyrics from a music library into LyricsEmbed's cache.

Why this exists: the plugin ships `import-embedded-lyrics.sh`, but that script
writes `<fnv1a32>.json` while current Lyrics.qml reads
`<sanitized title> - <sanitized artist>_<fnv1a32>.json`. The plugin keeps a
legacy fallback so the old name still resolves, but writing the canonical name
avoids depending on that fallback and keeps the cache self-describing.

File naming mirrors Lyrics.qml exactly:
  _cacheKey      = fnv1a32((title + "\\x00" + artist).toLowerCase())
  _sanitizeName  = strip characters illegal in filenames
  _truncateBytes = cut to <=190 UTF-8 bytes
  final          = f"{readable}_{key}.json"

Existing cache entries are rewritten only when they lack lyrics, so any
manually tuned per-song offset is preserved.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

MUSIC_DIR = Path(
    sys.argv[1]
    if len(sys.argv) > 1
    else "/run/media/moshuinw/F09C84A7ADEF4F0E/System_Tools/Music"
)
CACHE_DIR = Path.home() / ".cache" / "Lyrics"

AUDIO_EXT = {".flac", ".mp3", ".ogg", ".m4a", ".wma", ".aac", ".opus", ".ape", ".wav"}
LYRIC_TAGS = ("LYRICS", "UNSYNCEDLYRICS", "SYNCEDLYRICS")
# source id 4 == embedded extraction, matching the plugin's own convention
SOURCE_EMBEDDED = 4

# Matches every plugin-side helper so the cache stays readable by the QML.
_ILLEGAL = re.compile(r'[/\\:*?"<>|\x00-\x1f]')
_TIMESTAMP = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")


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
    # Never split a multibyte codepoint; 4 bytes is the widest UTF-8 sequence.
    return data[:limit].decode("utf-8", errors="ignore")


def cache_key(title: str, artist: str) -> str:
    return fnv1a32(f"{title}\x00{artist}".lower())


def cache_path(title: str, artist: str) -> Path:
    readable = truncate_utf8(f"{sanitize(title)} - {sanitize(artist)}")
    return CACHE_DIR / f"{readable}_{cache_key(title, artist)}.json"


def parse_lrc(text: str) -> list[dict]:
    """Parse LRC into [{time, text}], mirroring the shell script's semantics."""
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
            # Untimed continuation line inherits the previous timestamp.
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
            capture_output=True,
            text=True,
            timeout=60,
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
    if not title:
        return "no-title"

    raw = next((upper[t] for t in LYRIC_TAGS if upper.get(t)), None)
    if not raw:
        return "no-lyrics"

    lines = parse_lrc(raw)
    if not lines:
        return "unparsable"

    target = cache_path(title, artist)

    # Preserve a manually calibrated offset across re-imports.
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
    print(f"\n缓存目录: {CACHE_DIR}  (共 {len(list(CACHE_DIR.glob('*.json')))} 个文件)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
