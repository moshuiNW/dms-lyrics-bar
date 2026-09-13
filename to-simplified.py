#!/usr/bin/env python3
"""
Convert traditional-Chinese lyrics to simplified on stdin -> stdout.

lrclib.net is a mostly-Western catalogue: its Chinese entries are frequently
indexed in traditional characters, while local music libraries are usually
tagged in simplified. Reading along therefore shows the "wrong" script even
though the lyrics are correct.

Uses OpenCC when available (the standard tool for this conversion). The
`著` character needs one extra rule: OpenCC leaves it alone because 著 is
legitimate simplified in words like 著作 / 著名, but in lyrics it is almost
always the particle "zhe" and should become 着.

Fails open: if OpenCC is missing, the input is passed through unchanged so the
caller still gets usable lyrics.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys

# 著 (zhù, "to write / famous") keeps its form in these contexts.
_ZHU_CONTEXT = re.compile(r"著[作名述称者]|[编論论专專原]著")


def _fix_zhe(text: str) -> str:
    """Convert 著 -> 着 except where it means zhù."""
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


def to_simplified(text: str) -> str:
    if not text:
        return text

    binary = shutil.which("opencc")
    if not binary:
        return text   # fail open

    try:
        result = subprocess.run(
            [binary, "-c", "t2s"],
            input=text, capture_output=True, text=True, timeout=20,
        )
        if result.returncode != 0 or not result.stdout:
            return text
        converted = result.stdout
    except (subprocess.SubprocessError, OSError):
        return text

    return _fix_zhe(converted)


def main() -> int:
    data = sys.stdin.read()
    sys.stdout.write(to_simplified(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
