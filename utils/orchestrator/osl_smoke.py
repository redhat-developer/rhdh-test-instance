#!/usr/bin/env python3
"""OSL RC smoke helpers: Playwright grep and Data Index serviceUrl contract."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import Any, Optional

GRAPHQL_QUERY = "{ ProcessDefinitions { id serviceUrl endpoint } }"

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


def graphql_query() -> str:
    return GRAPHQL_QUERY


def curl_probe_argv(namespace: str) -> list[str]:
    body = json.dumps({"query": graphql_query()})
    url = (
        f"http://sonataflow-platform-data-index-service.{namespace}"
        ".svc.cluster.local/graphql"
    )
    return [
        "oc",
        "exec",
        "-n",
        namespace,
        "deploy/redhat-developer-hub",
        "--",
        "curl",
        "-sS",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-d",
        body,
        url,
    ]


def _cmd_probe(namespace: str, allow_relative: bool) -> int:
    argv = curl_probe_argv(namespace)
    proc = subprocess.run(argv, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr or proc.stdout or "oc exec curl failed\n")
        return 1
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        sys.stderr.write(f"Data Index did not return JSON: {proc.stdout[:500]}\n")
        return 1
    if payload.get("errors"):
        sys.stderr.write(json.dumps(payload["errors"]) + "\n")
        return 1
    definitions = (payload.get("data") or {}).get("ProcessDefinitions") or []
    result = classify_definitions(definitions)
    json.dump(result, sys.stderr, indent=2)
    sys.stderr.write("\n")
    if result["ok"]:
        return 0
    if allow_relative:
        sys.stderr.write(
            "WARNING: relative/missing serviceUrl allowed by ALLOW_RELATIVE_SERVICE_URL\n"
        )
        return 0
    if result["problems"] and result["problems"][0]["reason"] == "no-process-definitions":
        return 1
    return 2


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
    probe_p = sub.add_parser("probe")
    probe_p.add_argument("--namespace", required=True)
    probe_p.add_argument("--allow-relative", action="store_true")
    args = parser.parse_args(argv)
    if args.cmd == "grep":
        return _cmd_grep()
    if args.cmd == "probe":
        allow = args.allow_relative or os.environ.get("ALLOW_RELATIVE_SERVICE_URL") == "1"
        return _cmd_probe(args.namespace, allow)
    return _cmd_classify()


if __name__ == "__main__":
    sys.exit(main())
