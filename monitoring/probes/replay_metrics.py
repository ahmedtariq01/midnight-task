#!/usr/bin/env python3
"""Write local Cardano and Midnight replay gauges for Node Exporter."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


STATE = Path("/var/lib/midnight-ops/last-success.json")
METRICS = STATE.parent / "metrics" / "midnight-replay.prom"
NODE_RPC = "http://127.0.0.1:9944"
INDEXER = "http://127.0.0.1:8088"


def run_json(args, env=None):
    result = subprocess.run(args, check=True, capture_output=True, timeout=5, env=env)
    return json.loads(result.stdout)


def post(url, payload):
    request = Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=4) as response:
        data = json.load(response)
    if data.get("error") or data.get("errors"):
        raise ValueError("RPC or GraphQL returned an error")
    return data


def rpc(method, *params):
    return post(NODE_RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})["result"]


def endpoint_ok(path):
    try:
        with urlopen(f"{INDEXER}/{path}", timeout=4) as response:
            return int(response.status == 200)
    except HTTPError as error:
        if error.code == 503:
            return 0
        raise


def cardano_sample():
    tip = run_json([
        "runuser", "-u", "cardano", "--", "/opt/cardano-node/11.0.1/bin/cardano-cli",
        "query", "tip", "--socket-path", "/run/cardano-node/node.socket", "--testnet-magic", "1",
    ])
    relay_height = int(tip["block"])
    sql = """
      WITH recent AS (
        SELECT id, block_no, encode(hash, 'hex') AS hash
        FROM public.block
        WHERE block_no IS NOT NULL
        ORDER BY id DESC
        LIMIT 32
      )
      SELECT json_build_object(
        'height', (SELECT block_no FROM recent ORDER BY id DESC LIMIT 1),
        'matches', EXISTS (
          SELECT 1 FROM recent WHERE block_no = :'height'::bigint AND hash = :'hash'
        )
      );
    """
    result = subprocess.run(
        ["runuser", "-u", "postgres", "--", "psql", "-XAtw", "-d", "cexplorer",
         "-v", "ON_ERROR_STOP=1", "-v", f"height={relay_height}", "-v", f"hash={tip['hash']}"],
        input=sql.encode(), check=True, capture_output=True, timeout=5,
        env={**os.environ, "PGOPTIONS": "-c statement_timeout=3500 -c default_transaction_read_only=on"},
    )
    database = json.loads(result.stdout)
    return {
        "cardano_relay_height": relay_height,
        "cardano_db_height": int(database["height"]),
        "cardano_db_matches_sampled_tip": int(database["matches"]),
    }


def indexer_sample():
    live, ready = endpoint_ok("live"), endpoint_ok("ready")
    indexed = post(f"{INDEXER}/api/v4/graphql", {"query": "{ block { height hash } }"})["data"]["block"]
    indexed_height = int(indexed["height"])
    local_hash = rpc("chain_getBlockHash", indexed_height)
    finalized_hash = rpc("chain_getFinalizedHead")
    finalized_height = int(rpc("chain_getHeader", finalized_hash)["number"], 16)
    hash_match = bool(local_hash) and (
        local_hash.lower().removeprefix("0x") == indexed["hash"].lower().removeprefix("0x")
    )
    return {
        "indexer_height": indexed_height,
        "indexer_node_finalized_height": finalized_height,
        "indexer_live": live,
        "indexer_ready": ready,
        "indexer_same_height_hash_match": int(hash_match),
    }


def replace_file(path, contents, mode):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            file.write(contents)
            file.flush()
            os.fchmod(file.fileno(), mode)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    try:
        previous = json.loads(STATE.read_text())
    except (FileNotFoundError, ValueError):
        previous = {}
    lines = []
    for name, collect in (("cardano", cardano_sample), ("indexer", indexer_sample)):
        labels = f'{{component="{name}"}}'
        try:
            values = collect()
        except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
            # Publish failure without URLs, subprocess output, or a stale height.
            print(f"{name} probe failed: {type(error).__name__}", file=sys.stderr)
            lines.append(f"midnight_ops_probe_success{labels} 0")
        else:
            previous[name] = int(time.time())
            lines.extend(f"midnight_ops_{key} {value}" for key, value in values.items())
            lines.append(f"midnight_ops_probe_success{labels} 1")
        if name in previous:
            lines.append(f"midnight_ops_probe_last_success_timestamp_seconds{labels} {previous[name]}")
    replace_file(STATE, json.dumps(previous) + "\n", 0o600)
    replace_file(METRICS, "\n".join(lines) + "\n", 0o644)


if __name__ == "__main__":
    main()
