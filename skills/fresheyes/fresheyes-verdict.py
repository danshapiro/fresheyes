#!/usr/bin/env python3
"""Detect the final review verdict in a Fresh Eyes review file.

The ONE home for the verdict marker. Both fresheyes.sh (the launcher) and
fresheyes-progress.sh (the poller) call this file, so they can never disagree
about what a completed review looks like. Do not copy this regex elsewhere.

Usage: fresheyes-verdict.py <review-file> [<run-handle>]
Prints "passed" or "failed" and exits 0.
Exits 1 when the file is missing/unreadable or carries no verdict of its own.

A review quotes what it reads, so the marker phrase anywhere in the file is not
a verdict (upstream #5, #13). Two rules decide which line is:

- The marker is a whole line of its own, flush left, plain, in bold or as a
  heading. An indented, line-numbered, blockquoted or inline copy is a quote.
- With a run handle, the verdict is bound to the run: the last FRESHEYES-RUN
  line in the file must carry this handle, and the line just above it (blank
  lines aside) must be the marker. A quoted pair carries another run's handle,
  and a run's handle is unknown before the run starts, so no file can carry it.
  Without a handle (a record from before the run marker existed) the last
  flush-left marker wins.

The run marker itself is read by fresheyes-handle.py, its one home.
"""

import importlib.util
import re
import sys
from pathlib import Path

VERDICT_RE = re.compile(
    r"^(?:#{1,6}[ \t]+)?(?:\*\*|__)?INDEPENDENT CODE REVIEW[ \t]+(PASSED|FAILED)\b"
    r"[ \t]*(?:\*\*|__)?[ \t]*$",
    re.IGNORECASE,
)


def load_marker_re():
    path = Path(__file__).resolve().with_name("fresheyes-handle.py")
    spec = importlib.util.spec_from_file_location("fresheyes_handle", path)
    module = importlib.util.module_from_spec(spec)
    # The poller promises to write nothing; no __pycache__ beside the skill.
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    return module.MARKER_RE


def verdict_of(line):
    match = VERDICT_RE.match(line)
    return match.group(1).lower() if match else ""


def bound_verdict(lines, handle):
    marker_re = load_marker_re()
    for index in range(len(lines) - 1, -1, -1):
        found = marker_re.match(lines[index])
        if not found:
            continue
        if found.group(1) != handle:
            return ""
        for above in range(index - 1, -1, -1):
            if lines[above].strip():
                return verdict_of(lines[above])
        return ""
    return ""


def main() -> int:
    if len(sys.argv) not in (2, 3):
        return 1
    try:
        text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 1
    lines = text.splitlines()

    handle = sys.argv[2] if len(sys.argv) == 3 else ""
    if handle:
        verdict = bound_verdict(lines, handle)
    else:
        verdict = ""
        for line in lines:
            verdict = verdict_of(line) or verdict
    if not verdict:
        return 1
    print(verdict)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
