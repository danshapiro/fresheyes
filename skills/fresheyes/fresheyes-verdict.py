#!/usr/bin/env python3
"""Detect the final review verdict in a Fresh Eyes review file.

The ONE home for the verdict marker. Both fresheyes.sh (the launcher) and
fresheyes-progress.sh (the poller) call this file, so they can never disagree
about what a completed review looks like. Do not copy this regex elsewhere.

Usage: fresheyes-verdict.py <review-file>
Prints "passed" or "failed" (the LAST marker wins) and exits 0.
Exits 1 when the file is missing/unreadable or contains no verdict marker.
"""

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        return 1
    try:
        text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 1

    verdict = ""
    for match in re.finditer(r"INDEPENDENT CODE REVIEW\s+(PASSED|FAILED)\b", text, re.IGNORECASE):
        verdict = match.group(1).lower()
    if not verdict:
        return 1
    print(verdict)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
