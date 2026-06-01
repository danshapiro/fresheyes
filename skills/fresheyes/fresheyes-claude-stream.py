#!/usr/bin/env python3
"""Parse Claude Code stream-json output for Fresh Eyes."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("manual", "automatic"), required=True)
    parser.add_argument("--review-log", required=True)
    parser.add_argument("--event-log", required=True)
    parser.add_argument("--stream-log", required=True)
    parser.add_argument("--automatic-output")
    return parser.parse_args()


def write_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True))
        handle.write("\n")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write(text)
        if text and not text.endswith("\n"):
            handle.write("\n")


def append_event(
    event_log: Path,
    *,
    severity: str,
    event: str,
    message: str | None = None,
    **fields: Any,
) -> None:
    record: dict[str, Any] = {
        "severity": severity,
        "event": event,
        "provider": "claude",
        "ts_epoch": time.time(),
    }
    if message:
        record["message"] = message
    for key, value in fields.items():
        if value not in (None, ""):
            record[key] = value
    write_jsonl(event_log, record)


def first_content_item(obj: dict[str, Any]) -> dict[str, Any]:
    message = obj.get("message")
    if not isinstance(message, dict):
        return {}
    content = message.get("content")
    if not isinstance(content, list):
        return {}
    for item in content:
        if isinstance(item, dict):
            return item
    return {}


def provider_fields(obj: dict[str, Any]) -> dict[str, Any]:
    item = first_content_item(obj)
    fields: dict[str, Any] = {
        "type": obj.get("type"),
        "subtype": obj.get("subtype"),
        "status": obj.get("status"),
        "session_id": obj.get("session_id"),
        "stream_event_type": obj.get("stream_event_type") or item.get("type"),
        "tool": obj.get("tool") or obj.get("name") or item.get("name"),
        "delta_type": obj.get("delta", {}).get("type")
        if isinstance(obj.get("delta"), dict)
        else None,
    }
    return {key: value for key, value in fields.items() if value not in (None, "")}


def failure_log(
    *,
    error: str,
    stream_lines: int,
    event_log: Path,
    stream_log: Path,
) -> str:
    return "\n".join(
        [
            "Fresh Eyes review failed before final output.",
            "",
            "provider=claude",
            f"error={error}",
            f"stream_lines={stream_lines}",
            "",
            "See sidecar logs:",
            f"- {event_log}",
            f"- {stream_log}",
            "",
        ]
    )


def parse_result_json(result: Any) -> Any | None:
    if not isinstance(result, str):
        return None
    try:
        return json.loads(result)
    except json.JSONDecodeError:
        return None


def write_automatic_output(
    output: Any,
    *,
    review_log: Path,
    automatic_output: Path,
) -> None:
    for path in (review_log, automatic_output):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            json.dump(output, handle, indent=2, sort_keys=True)
            handle.write("\n")


def main() -> int:
    args = parse_args()
    review_log = Path(args.review_log)
    event_log = Path(args.event_log)
    stream_log = Path(args.stream_log)

    if args.mode == "automatic" and not args.automatic_output:
        print("--automatic-output is required in automatic mode", file=sys.stderr)
        return 2

    stream_lines = 0
    final_result: dict[str, Any] | None = None

    append_event(event_log, severity="info", event="parser_started", mode=args.mode)

    with stream_log.open("a", encoding="utf-8") as raw_handle:
        for raw_line in sys.stdin:
            line = raw_line.rstrip("\n")
            if not line.strip():
                continue
            stream_lines += 1
            raw_handle.write(line)
            raw_handle.write("\n")
            raw_handle.flush()

            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                append_event(
                    event_log,
                    severity="error",
                    event="invalid_json",
                    message=str(exc),
                    stream_lines=stream_lines,
                )
                continue

            if not isinstance(obj, dict):
                append_event(
                    event_log,
                    severity="warning",
                    event="non_object_event",
                    stream_lines=stream_lines,
                )
                continue

            append_event(
                event_log,
                severity="info",
                event="provider_event",
                stream_lines=stream_lines,
                **provider_fields(obj),
            )

            if obj.get("type") == "result":
                final_result = obj
                break

    if final_result is None:
        text = failure_log(
            error="missing_result",
            stream_lines=stream_lines,
            event_log=event_log,
            stream_log=stream_log,
        )
        write_text(review_log, text)
        append_event(
            event_log,
            severity="error",
            event="missing_result",
            message="Claude stream ended before a final result event.",
            stream_lines=stream_lines,
        )
        print(text, end="")
        return 1

    result_text = final_result.get("result")
    if final_result.get("is_error") is True:
        error_text = result_text if isinstance(result_text, str) else json.dumps(final_result)
        write_text(review_log, error_text)
        append_event(
            event_log,
            severity="error",
            event="review_result",
            message=error_text[:500],
            stream_lines=stream_lines,
        )
        print(error_text)
        return 1

    if args.mode == "manual":
        text = result_text if isinstance(result_text, str) else json.dumps(final_result)
        write_text(review_log, text)
        append_event(
            event_log,
            severity="info",
            event="review_result",
            status="success",
            stream_lines=stream_lines,
        )
        print(text)
        return 0

    structured_output = final_result.get("structured_output")
    if structured_output is None:
        structured_output = parse_result_json(result_text)

    if structured_output is None:
        text = failure_log(
            error="structured_output_missing",
            stream_lines=stream_lines,
            event_log=event_log,
            stream_log=stream_log,
        )
        write_text(review_log, text)
        append_event(
            event_log,
            severity="error",
            event="structured_output_missing",
            message="Claude result did not include structured_output or JSON result text.",
            stream_lines=stream_lines,
        )
        print(text, end="")
        return 1

    write_automatic_output(
        structured_output,
        review_log=review_log,
        automatic_output=Path(args.automatic_output),
    )
    append_event(
        event_log,
        severity="info",
        event="review_result",
        status="success",
        stream_lines=stream_lines,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
