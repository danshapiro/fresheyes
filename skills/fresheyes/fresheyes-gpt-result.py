#!/usr/bin/env python3
"""Extract the final review or verdict from a Codex transcript."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path


HEADER = b"## Files Examined"
VERDICT = re.compile(rb"INDEPENDENT CODE REVIEW\s+(PASSED|FAILED)\b", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--result", action="store_true")
    mode.add_argument("--verdict", action="store_true")
    parser.add_argument("log_file")
    return parser.parse_args()


def final_review_offset(path: Path) -> int:
    start = 0
    with path.open("rb") as handle:
        while True:
            offset = handle.tell()
            line = handle.readline()
            if not line:
                return start
            if line.rstrip(b" \t\r\n") == HEADER:
                start = offset


def write_result(path: Path, start: int) -> int:
    with path.open("rb") as handle:
        handle.seek(start)
        shutil.copyfileobj(handle, sys.stdout.buffer)
    return 0


def write_verdict(path: Path, start: int) -> int:
    verdict = b""
    with path.open("rb") as handle:
        handle.seek(start)
        for line in handle:
            for match in VERDICT.finditer(line):
                verdict = match.group(1).lower()
    if not verdict:
        return 1
    sys.stdout.write(verdict.decode("ascii") + "\n")
    return 0


def main() -> int:
    args = parse_args()
    path = Path(args.log_file)
    try:
        start = final_review_offset(path)
        if args.result:
            return write_result(path, start)
        return write_verdict(path, start)
    except OSError as exc:
        print(f"Fresh Eyes: unable to read GPT review log: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
