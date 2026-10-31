#!/usr/bin/env python3
"""Detect the final review verdict in a Fresh Eyes review file.

The ONE home for the verdict marker. Both fresheyes.sh (the launcher) and
fresheyes-progress.sh (the poller) call this file, so they can never disagree
about what a completed review looks like. Do not copy this regex elsewhere.

Usage: fresheyes-verdict.py <review-file>
Prints "passed" or "failed" (the LAST marker wins) and exits 0.
Exits 1 when the file is missing/unreadable or contains no verdict marker.

Usage: fresheyes-verdict.py --no-files-examined <review-file>
Exits 0 when the review's "Files Examined" section is present and lists no
file: the reviewer says it read nothing, so the text is not a review whatever
its verdict says. The section lists no file when its first line says so
("None.", "- n/a", ...), whatever bullets explain it below, or when it has no
list entry other than such a line. Exits 1 otherwise, including when the file
is unreadable or has no such section. The FIRST such heading is the review's
own; the prompt puts it first, and a later one is a quotation.
"""

import re
import sys
from pathlib import Path

FILES_HEADING = re.compile(r"^\s*#{1,6}\s*files\s+examined\s*:?\s*$", re.IGNORECASE)
SECTION_END = re.compile(r"^\s*(#{1,6}\s|-{3,}\s*$|\*{3,}\s*$|_{3,}\s*$)")
LIST_ENTRY = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+(.*\S)")
# A sentence that says no file was read may go on to say why. A short word
# ("None", "n/a", "nothing", "no files") must stand alone: then punctuation
# and a space or the end of the line, the end of the line, or a parenthesis or
# dash, with emphasis markup allowed around it. "None.", "**None.**",
# "None (reads failed)" and "No files were examined because ..." match; a file
# named none.py and prose like "None of these were modified" do not.
NO_FILE = re.compile(
    r"^[\s*_`]*(?:"
    r"(?:no\s+files?|nothing)\s+(?:(?:was|were)\s+)?(?:examined|read)\b"
    r"|"
    r"(?:none|n/?a|nothing|no\s+files?)[*_`]*"
    r"(?:[.:;,!][*_`]*(?=\s|$)|\s*$|\s+[(\u2014\u2013-])"
    r")",
    re.IGNORECASE,
)


def read(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def verdict(text: str) -> str:
    found = ""
    for match in re.finditer(r"INDEPENDENT CODE REVIEW\s+(PASSED|FAILED)\b", text, re.IGNORECASE):
        found = match.group(1).lower()
    return found


def examined_no_files(text: str) -> bool:
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if FILES_HEADING.match(line)), None)
    if start is None:
        return False
    first = True
    for line in lines[start + 1:]:
        if SECTION_END.match(line):
            break
        if not line.strip():
            continue
        entry = LIST_ENTRY.match(line)
        content = entry.group(1) if entry else line
        if first and NO_FILE.match(content):
            return True
        first = False
        if entry and not NO_FILE.match(content):
            return False
    return True


def main() -> int:
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--no-files-examined":
        text = read(args[1])
        return 0 if text is not None and examined_no_files(text) else 1
    if len(args) != 1:
        return 1
    text = read(args[0])
    if text is None:
        return 1
    found = verdict(text)
    if not found:
        return 1
    print(found)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
