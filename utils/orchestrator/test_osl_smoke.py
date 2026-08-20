#!/usr/bin/env python3
import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import osl_smoke  # noqa: E402


class TestPlaywrightGrep(unittest.TestCase):
    def test_default_titles(self):
        self.assertEqual(
            osl_smoke.SMOKE_TITLES,
            [
                "Run Greeting workflow and verify Workflows tab",
                "Run Failswitch workflow and verify statuses",
                "Rerun Failswitch from failure point",
                "Execute token-propagation workflow via API",
            ],
        )

    def test_grep_joins_four_escaped_titles(self):
        pattern = osl_smoke.playwright_grep()
        self.assertIn("Run Greeting workflow and verify Workflows tab", pattern)
        self.assertIn("Run Failswitch workflow and verify statuses", pattern)
        self.assertIn("Rerun Failswitch from failure point", pattern)
        self.assertIn("Execute token-propagation workflow via API", pattern)
        self.assertNotIn("Verify Workflow All Runs", pattern)


class TestServiceUrl(unittest.TestCase):
    def test_absolute_http(self):
        self.assertTrue(
            osl_smoke.is_absolute_http_url(
                "http://greeting.orchestrator.svc.cluster.local"
            )
        )

    def test_absolute_https(self):
        self.assertTrue(osl_smoke.is_absolute_http_url("https://example.example"))

    def test_relative_path(self):
        self.assertFalse(osl_smoke.is_absolute_http_url("/greeting"))

    def test_empty_and_none(self):
        self.assertFalse(osl_smoke.is_absolute_http_url(""))
        self.assertFalse(osl_smoke.is_absolute_http_url(None))


class TestClassifyDefinitions(unittest.TestCase):
    def test_all_absolute_ok(self):
        result = osl_smoke.classify_definitions(
            [
                {
                    "id": "greeting",
                    "serviceUrl": "http://greeting.orchestrator.svc",
                    "endpoint": "http://greeting.orchestrator.svc/greeting",
                }
            ]
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["problems"], [])

    def test_relative_service_url_is_problem(self):
        result = osl_smoke.classify_definitions(
            [
                {
                    "id": "greeting",
                    "serviceUrl": "/greeting",
                    "endpoint": "http://greeting.orchestrator.svc/greeting",
                }
            ]
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["problems"][0]["id"], "greeting")
        self.assertEqual(result["problems"][0]["reason"], "relative-or-missing-serviceUrl")

    def test_empty_list_not_ok(self):
        result = osl_smoke.classify_definitions([])
        self.assertFalse(result["ok"])
        self.assertEqual(result["problems"][0]["reason"], "no-process-definitions")


class TestClassifyCli(unittest.TestCase):
    def test_classify_stdin_exit_2_on_relative(self):
        payload = json.dumps(
            {
                "data": {
                    "ProcessDefinitions": [
                        {"id": "greeting", "serviceUrl": "/greeting", "endpoint": "http://x/greeting"}
                    ]
                }
            }
        )
        proc = subprocess.run(
            [sys.executable, str(HERE / "osl_smoke.py"), "classify"],
            input=payload,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 2)


class TestProbeArgv(unittest.TestCase):
    def test_curl_targets_raw_data_index_not_rewrite(self):
        argv = osl_smoke.curl_probe_argv("orchestrator")
        joined = " ".join(argv)
        self.assertIn("sonataflow-platform-data-index-service.orchestrator.svc.cluster.local/graphql", joined)
        self.assertNotIn("osl-di-rewrite", joined)
        self.assertIn("ProcessDefinitions", joined)

    def test_graphql_query_asks_for_service_url_and_endpoint(self):
        q = osl_smoke.graphql_query()
        self.assertIn("serviceUrl", q)
        self.assertIn("endpoint", q)
        self.assertIn("ProcessDefinitions", q)


class TestDriverGrepWiring(unittest.TestCase):
    def test_run_script_mentions_osl_smoke_grep(self):
        text = Path(__file__).resolve().parents[2].joinpath("run-osl-regression.sh").read_text()
        self.assertIn("osl_smoke.py", text)
        self.assertIn("grep", text)
        self.assertIn("--grep", text)


if __name__ == "__main__":
    unittest.main()
