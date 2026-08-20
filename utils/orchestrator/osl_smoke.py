#!/usr/bin/env python3
"""OSL RC smoke helpers: Playwright grep and Data Index serviceUrl contract."""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Optional

SMOKE_TITLES = [
    "Run Greeting workflow and verify Workflows tab",
    "Run Failswitch workflow and verify statuses",
    "Rerun Failswitch from failure point",
    "Execute token-propagation workflow via API",
]


def playwright_grep() -> str:
    return "|".join(SMOKE_TITLES)


def is_absolute_http_url(value: Optional[str]) -> bool:
    if not value:
        return False
    return value.startswith("http://") or value.startswith("https://")


def classify_definitions(definitions: list) -> dict[str, Any]:
    if not definitions:
        return {
            "ok": False,
            "problems": [
                {
                    "id": None,
                    "serviceUrl": None,
                    "endpoint": None,
                    "reason": "no-process-definitions",
                }
            ],
        }
    problems = []
    for item in definitions:
        service_url = item.get("serviceUrl")
        if not is_absolute_http_url(service_url):
            problems.append(
                {
                    "id": item.get("id"),
                    "serviceUrl": service_url,
                    "endpoint": item.get("endpoint"),
                    "reason": "relative-or-missing-serviceUrl",
                }
            )
    return {"ok": not problems, "problems": problems}


def _cmd_grep() -> int:
    print(playwright_grep())
    return 0


def _cmd_classify() -> int:
    payload = json.load(sys.stdin)
    definitions = (payload.get("data") or {}).get("ProcessDefinitions") or []
    result = classify_definitions(definitions)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    if result["ok"]:
        return 0
    if result["problems"] and result["problems"][0]["reason"] == "no-process-definitions":
        return 1
    return 2


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="osl_smoke.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("grep")
    sub.add_parser("classify")
    args = parser.parse_args(argv)
    if args.cmd == "grep":
        return _cmd_grep()
    return _cmd_classify()


if __name__ == "__main__":
    sys.exit(main())
