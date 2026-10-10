"""Turns `flutter test --reporter json` output into GitHub annotations.

The CI log is not always downloadable, but annotations are shown on the run.
Each failing test becomes one ::error line with its name and message.

Usage: python3 tool/report_test_failures.py test-results.json
"""

import json
import sys


def escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(path: str) -> int:
    names: dict[int, str] = {}
    results: dict[int, str] = {}
    errors: dict[int, list[str]] = {}
    prints: dict[int, list[str]] = {}
    totals = {"passed": 0, "failed": 0, "skipped": 0}

    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            event = json.loads(line)
            kind = event.get("type")
            if kind == "testStart":
                names[event["test"]["id"]] = event["test"]["name"]
            elif kind == "error":
                errors.setdefault(event["testID"], []).append(
                    (event.get("error") or "")[:600]
                )
            elif kind == "print" and event.get("testID") is not None:
                # Flutter writes the real exception ("EXCEPTION CAUGHT ...") as
                # a print; the error event itself only says "see logs above".
                prints.setdefault(event["testID"], []).append(
                    event.get("message", "")
                )
            elif kind == "testDone" and not event.get("hidden", False):
                results[event["testID"]] = event["result"]

    for test_id, result in results.items():
        if result in ("failure", "error"):
            totals["failed"] += 1
            name = names.get(test_id, f"test {test_id}")
            lines = prints.get(test_id, [])[-40:] + errors.get(
                test_id, ["(no message)"]
            )
            message = "\n".join(lines)[-3000:]
            print(f"::error title=Test failed::{escape(name + ': ' + message)}")
        elif result == "success":
            totals["passed"] += 1
        else:
            totals["skipped"] += 1

    print(
        f"tests: {totals['passed']} passed, {totals['failed']} failed, "
        f"{totals['skipped']} skipped"
    )
    return 1 if totals["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
