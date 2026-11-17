# Midnight RPC health checker

`node_health.py` implements assessment Option C using Python 3.10 or later and the standard library. It reads `system_health`, `chain_getFinalizedHead`, and `chain_getHeader` over HTTP JSON-RPC. Run it on the node host to use its loopback RPC listener or point it at an authorised endpoint reachable from your machine.

From the repository root, start continuous polling or run a single check.

```sh
python3 scripts/node_health.py --rpc-url http://127.0.0.1:9944 \
  --interval 30 --timeout 5 --min-peers 2 --stall-after 300 \
  --output var/midnight-health.json

python3 scripts/node_health.py --once
python3 -m json.tool var/midnight-health.json
```

| Option | Default | Purpose |
|---|---|---|
| `--rpc-url` | `http://127.0.0.1:9944` | HTTP or HTTPS JSON-RPC URL. |
| `--interval` | 30 seconds | Time between poll starts when a poll finishes within the interval. |
| `--timeout` | 5 seconds | Timeout for an individual RPC request. |
| `--min-peers` | 2 | Minimum peer count. Tune it against the node's observed peer count. |
| `--stall-after` | 300 seconds | Elapsed time without observed progress before reporting a stalled head. |
| `--output` | `var/midnight-health.json` | Latest report. Use a separate file for each polling process. |
| `--once` | Continuous polling | Take one sample and return an exit status. |

| Status | Meaning |
|---|---|
| `observing` | RPC is responding and the node reports that it is out of replay. The checker is establishing progress baselines. |
| `syncing` | The node reports replay and has enough peers. The checker watches best-height progress and starts the finality stall window when replay ends. |
| `ready` | Replay has ended, both heights have advanced during observation, and the latest sample meets the configured checks. This is local readiness. Compare the finalized hash with an independent PreProd reference to confirm network catch-up. |
| `degraded` | The observation shows a health issue or RPC returned an invalid response. |
| `unreachable` | The RPC transport or HTTP request failed. |

`--once` returns `0` for `observing`, `syncing`, or `ready`, `1` for `degraded` or `unreachable`, and `2` for an invalid argument or report I/O failure. In continuous mode the checker prints state changes, new regressions, and recoveries, and keeps polling through RPC faults. Stop it with Ctrl+C.

The report is written through a temporary file and replaced atomically. Each poll completes before the next starts. The first poll loads the prior report for the same target, so consecutive `--once` runs can also detect changes. The report records issues, deltas against the last successful RPC observation, new regressions, and recoveries. If RPC fails, the last successful observation retains its original timestamp and remains available for comparison after recovery. The report stores a digest of the configured URL and summarised RPC errors.

Example report from a fixture where blocks advance and the peer count falls below the configured minimum.

```json
{
  "schema_version": 1,
  "target_id": "example-target-digest",
  "checked_at": "2026-11-17T09:00:30+00:00",
  "status": "degraded",
  "rpc_error": null,
  "issues": ["low_peer_count"],
  "last_successful_observation": {
    "sampled_at": "2026-11-17T09:00:30+00:00",
    "chain": {
      "peers": 1,
      "syncing": false,
      "best_height": 108,
      "finalized_height": 97,
      "finalized_hash": "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    },
    "best_tracking_since": "2026-11-17T09:00:00+00:00",
    "best_advanced_at": "2026-11-17T09:00:30+00:00",
    "finality_tracking_since": "2026-11-17T09:00:00+00:00",
    "finalized_advanced_at": "2026-11-17T09:00:30+00:00"
  },
  "changes": {
    "previous_status": "observing",
    "deltas": {"peers": -3, "best_height": 8, "finalized_height": 7},
    "regressions": ["low_peer_count"],
    "recoveries": []
  }
}
```

Run the tests with mocked RPC responses and temporary report files.

```sh
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

Live validation on the assessment node is pending.
