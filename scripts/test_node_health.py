from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from io import BytesIO, StringIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.error import URLError

import node_health as health


RPC_URL = "http://127.0.0.1:9944"
NOW = datetime(2025, 1, 1, tzinfo=timezone.utc)
HASH_A = "0x" + "a" * 64
HASH_B = "0x" + "b" * 64


def chain(best=100, finalized=90, peers=4, syncing=False, block_hash=HASH_A):
    return health.ChainState(peers, syncing, best, finalized, block_hash)


def sample(current=None, previous=None, elapsed=0, error=None):
    return health.evaluate(current, error, previous, NOW + timedelta(seconds=elapsed), "test", 2, 300)


class RpcTests(unittest.TestCase):
    def test_builds_read_only_requests_and_decodes_heights(self):
        responses = [
            ("system_health", [], {"peers": 5, "isSyncing": True}),
            ("chain_getFinalizedHead", [], HASH_A),
            ("chain_getHeader", [HASH_A], {"number": "0x5a"}),
            ("chain_getHeader", [], {"number": "0x64"}),
        ]
        seen = []

        def respond(request, *, timeout):
            method, params, result = responses[len(seen)]
            seen.append(method)
            self.assertEqual(request.full_url, RPC_URL)
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(timeout, 3)
            self.assertEqual(json.loads(request.data), {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
            return BytesIO(json.dumps({"jsonrpc": "2.0", "id": 1, "result": result}).encode())

        with patch.object(health, "urlopen", side_effect=respond):
            self.assertEqual(health.query_chain(RPC_URL, 3), chain(peers=5, syncing=True))
        self.assertEqual(len(seen), 4)

    def test_reports_transport_failure_and_does_not_disclose_error_text(self):
        with patch.object(health, "urlopen", side_effect=URLError("private-details")):
            with self.assertRaises(health.RpcError) as raised:
                health.query_chain(RPC_URL, 3)
        self.assertEqual(raised.exception.code, "rpc_unavailable")
        self.assertNotIn("private-details", str(raised.exception))

    def test_rejects_malformed_and_rpc_error_responses(self):
        messages = [
            b"not json",
            b'{"jsonrpc":"2.0","id":true,"result":{}}',
            b'{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"private-details"}}',
            b'{"jsonrpc":"2.0","id":1,"result":null}',
        ]
        for message in messages:
            with self.subTest(message=message), patch.object(health, "urlopen", return_value=BytesIO(message)):
                with self.assertRaises(health.RpcError) as raised:
                    health.query_chain(RPC_URL, 3)
                self.assertEqual(raised.exception.code, "rpc_invalid_response")
                self.assertNotIn("private-details", str(raised.exception))


class HealthTests(unittest.TestCase):
    def test_replay_checks_best_progress_without_premature_finality_warning(self):
        first = sample(chain(syncing=True))
        progressing = sample(chain(best=101, syncing=True), first, elapsed=299)
        stalled = sample(chain(best=101, syncing=True), progressing, elapsed=599)
        self.assertEqual(progressing.status, "syncing")
        self.assertEqual(progressing.changes["deltas"]["best_height"], 1)
        self.assertEqual(stalled.status, "degraded")
        self.assertEqual(stalled.changes["regressions"], ["best_height_stalled"])

    def test_finality_grace_period_and_recovery(self):
        start = sample(chain(syncing=True))
        leaving_replay = sample(chain(best=102), start, elapsed=400)
        ready = sample(chain(best=108, finalized=97, block_hash=HASH_B), leaving_replay, elapsed=430)
        stalled = sample(chain(best=110, finalized=97, block_hash=HASH_B), ready, elapsed=730)
        recovered = sample(chain(best=112, finalized=98), stalled, elapsed=760)
        self.assertEqual(leaving_replay.status, "observing")
        self.assertEqual(ready.status, "ready")
        self.assertEqual(stalled.changes["regressions"], ["finalized_height_stalled"])
        self.assertEqual(recovered.status, "ready")
        self.assertEqual(recovered.changes["recoveries"], ["finalized_height_stalled"])

    def test_surfaces_peer_loss_and_changed_finalized_hash(self):
        first = sample(chain())
        degraded = sample(chain(best=99, peers=0, block_hash=HASH_B), first, elapsed=30)
        self.assertEqual(first.status, "observing")
        self.assertEqual(degraded.changes["deltas"], {"peers": -4, "best_height": -1, "finalized_height": 0})
        self.assertEqual(degraded.changes["regressions"], [
            "best_height_decreased", "finalized_hash_changed", "low_peer_count",
        ])
        finalized_drop = sample(chain(best=100, finalized=89), degraded, elapsed=60)
        self.assertIn("finalized_height_decreased", finalized_drop.changes["regressions"])

    def test_rpc_failure_retains_previous_observation_and_does_not_fake_recovery(self):
        first = sample(chain(peers=0))
        offline = sample(previous=first, elapsed=30, error=health.RpcError("rpc_unavailable", "timeout"))
        recovered = sample(chain(best=106, finalized=96, block_hash=HASH_B), offline, elapsed=60)
        self.assertEqual(offline.status, "unreachable")
        self.assertEqual(offline.last_successful_observation, first.last_successful_observation)
        self.assertEqual(offline.changes["regressions"], ["rpc_unavailable"])
        self.assertEqual(offline.changes["recoveries"], [])
        self.assertEqual(recovered.status, "ready")
        self.assertEqual(recovered.changes["recoveries"], ["low_peer_count", "rpc_unavailable"])


class ReportTests(unittest.TestCase):
    def test_continuous_polls_compare_each_committed_report(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "health.json"
            with patch.object(health, "query_chain", side_effect=[chain(), chain(best=103, peers=0)]):
                with patch.object(health.time, "sleep", side_effect=[None, KeyboardInterrupt()]):
                    with redirect_stdout(StringIO()):
                        self.assertEqual(health.main(["--output", str(path)]), 0)
            report = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(report["changes"]["previous_status"], "observing")
            self.assertEqual(report["changes"]["deltas"]["best_height"], 3)
            self.assertEqual(report["changes"]["regressions"], ["low_peer_count"])

    def test_once_compares_persisted_report_and_returns_health_status(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "new-directory" / "health.json"
            args = ["--output", str(path), "--once"]
            with patch.object(health, "query_chain", side_effect=[chain(), chain(best=101, peers=0)]):
                with redirect_stdout(StringIO()):
                    self.assertEqual(health.main(args), 0)
                    self.assertEqual(health.main(args), 1)
            report = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "degraded")
            self.assertEqual(report["changes"]["previous_status"], "observing")
            self.assertEqual(report["changes"]["deltas"]["best_height"], 1)
            self.assertEqual(report["changes"]["regressions"], ["low_peer_count"])

    def test_failed_replace_preserves_previous_report_and_cleans_temp_file(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "health.json"
            first = sample(chain())
            health.write_report(path, first)
            previous_bytes = path.read_bytes()
            self.assertEqual(health.read_previous(path, "test"), first)
            with patch.object(health.os, "replace", side_effect=OSError("replace failed")):
                with self.assertRaises(OSError):
                    health.write_report(path, sample(chain(best=102), first, elapsed=30))
            self.assertEqual(path.read_bytes(), previous_bytes)
            self.assertEqual(list(Path(directory).iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
