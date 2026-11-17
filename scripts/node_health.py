#!/usr/bin/env python3
"""Poll a Midnight node and compare the latest health report with the prior one."""

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
from http.client import HTTPException
import json
import math
import os
from pathlib import Path
import re
import sys
from tempfile import NamedTemporaryFile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


SCHEMA_VERSION = 1
MAX_RESPONSE_BYTES = 1024 * 1024
BLOCK_HASH = re.compile(r"0x[0-9a-fA-F]{64}")
BLOCK_NUMBER = re.compile(r"0x[0-9a-fA-F]{1,16}")


class RpcError(Exception):
    def __init__(self, code, description):
        super().__init__(description)
        self.code = code


@dataclass(frozen=True)
class ChainState:
    peers: int
    syncing: bool
    best_height: int
    finalized_height: int
    finalized_hash: str

    def __post_init__(self):
        heights = (self.best_height, self.finalized_height)
        if (
            type(self.peers) is not int or self.peers < 0
            or type(self.syncing) is not bool
            or any(type(height) is not int or height < 0 for height in heights)
            or self.finalized_height > self.best_height
            or not isinstance(self.finalized_hash, str)
            or not BLOCK_HASH.fullmatch(self.finalized_hash)
        ):
            raise ValueError("invalid chain state")


@dataclass(frozen=True)
class Observation:
    sampled_at: datetime
    chain: ChainState
    best_tracking_since: datetime
    best_advanced_at: datetime | None
    finality_tracking_since: datetime | None
    finalized_advanced_at: datetime | None


@dataclass(frozen=True)
class Report:
    schema_version: int
    target_id: str
    checked_at: datetime
    status: str
    rpc_error: str | None
    issues: list[str]
    last_successful_observation: Observation | None
    changes: dict


def rpc_call(url, method, params, timeout):
    request = Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
    except HTTPError as error:
        raise RpcError("rpc_unavailable", f"{method} returned HTTP {error.code}") from error
    except (URLError, OSError, HTTPException) as error:
        raise RpcError("rpc_unavailable", f"{method} could not reach the RPC endpoint") from error

    if len(payload) > MAX_RESPONSE_BYTES:
        raise RpcError("rpc_invalid_response", f"{method} response exceeded the size limit")
    try:
        message = json.loads(payload)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise RpcError("rpc_invalid_response", f"{method} returned invalid JSON") from error
    if (
        not isinstance(message, dict) or message.get("jsonrpc") != "2.0"
        or type(message.get("id")) is not int or message["id"] != 1
    ):
        raise RpcError("rpc_invalid_response", f"{method} returned an invalid JSON-RPC envelope")
    if "error" in message or "result" not in message:
        raise RpcError("rpc_invalid_response", f"{method} returned a JSON-RPC error or no result")
    return message["result"]


def block_height(header):
    number = header.get("number") if isinstance(header, dict) else None
    if not isinstance(number, str) or not BLOCK_NUMBER.fullmatch(number):
        raise RpcError("rpc_invalid_response", "chain_getHeader returned an invalid block number")
    return int(number, 16)


def query_chain(url, timeout):
    health = rpc_call(url, "system_health", [], timeout)
    if not isinstance(health, dict):
        raise RpcError("rpc_invalid_response", "system_health returned an invalid result")
    finalized_hash = rpc_call(url, "chain_getFinalizedHead", [], timeout)
    if not isinstance(finalized_hash, str) or not BLOCK_HASH.fullmatch(finalized_hash):
        raise RpcError("rpc_invalid_response", "chain_getFinalizedHead returned an invalid hash")
    finalized = block_height(rpc_call(url, "chain_getHeader", [finalized_hash], timeout))
    best = block_height(rpc_call(url, "chain_getHeader", [], timeout))
    try:
        return ChainState(health.get("peers"), health.get("isSyncing"), best, finalized, finalized_hash.lower())
    except ValueError as error:
        raise RpcError("rpc_invalid_response", "RPC returned invalid or inconsistent chain fields") from error


def observe(chain, previous, now):
    if previous is None:
        return Observation(
            sampled_at=now,
            chain=chain,
            best_tracking_since=now,
            best_advanced_at=None,
            finality_tracking_since=None if chain.syncing else now,
            finalized_advanced_at=None,
        )
    best_advanced = chain.best_height > previous.chain.best_height
    finalized_advanced = chain.finalized_height > previous.chain.finalized_height
    # Start the stall window again when the node leaves initial replay.
    tracking_finality = None if chain.syncing else (previous.finality_tracking_since or now)
    return Observation(
        sampled_at=now,
        chain=chain,
        best_tracking_since=previous.best_tracking_since,
        best_advanced_at=now if best_advanced else previous.best_advanced_at,
        finality_tracking_since=tracking_finality,
        finalized_advanced_at=now if finalized_advanced else previous.finalized_advanced_at,
    )


def evaluate(chain, rpc_error, previous, now, target_id, min_peers, stall_after):
    last = previous.last_successful_observation if previous else None
    issues = []
    deltas = {"peers": None, "best_height": None, "finalized_height": None}

    if rpc_error:
        issues.append(rpc_error.code)
        observation = last  # Keep explicitly dated observations available across RPC failures.
        status = "unreachable" if rpc_error.code == "rpc_unavailable" else "degraded"
    else:
        observation = observe(chain, last, now)
        if chain.peers < min_peers:
            issues.append("low_peer_count")
        if last:
            deltas = {key: getattr(chain, key) - getattr(last.chain, key) for key in deltas}
            if deltas["best_height"] < 0:
                issues.append("best_height_decreased")
            if deltas["finalized_height"] < 0:
                issues.append("finalized_height_decreased")
            if deltas["finalized_height"] == 0 and chain.finalized_hash != last.chain.finalized_hash:
                issues.append("finalized_hash_changed")
        best_since = observation.best_advanced_at or observation.best_tracking_since
        if (now - best_since).total_seconds() >= stall_after:
            issues.append("best_height_stalled")
        finality_since = observation.finality_tracking_since
        if finality_since is not None:
            finalized_since = max(finality_since, observation.finalized_advanced_at or finality_since)
            if (now - finalized_since).total_seconds() >= stall_after:
                issues.append("finalized_height_stalled")

        if issues:
            status = "degraded"
        elif chain.syncing:
            status = "syncing"
        elif observation.best_advanced_at and observation.finalized_advanced_at:
            status = "ready"
        else:
            status = "observing"

    old_issues = set(previous.issues) if previous else set()
    # Loss of an RPC sample cannot prove that previously observed conditions recovered.
    recovered = old_issues - set(issues) if rpc_error is None else set()
    if rpc_error:
        issues.extend(code for code in sorted(old_issues) if not code.startswith("rpc_"))
    return Report(
        schema_version=SCHEMA_VERSION,
        target_id=target_id,
        checked_at=now,
        status=status,
        rpc_error=str(rpc_error) if rpc_error else None,
        issues=issues,
        last_successful_observation=observation,
        changes={
            "previous_status": previous.status if previous else None,
            "deltas": deltas,
            "regressions": sorted(set(issues) - old_issues),
            "recoveries": sorted(recovered),
        },
    )


def utc_datetime(value):
    if not isinstance(value, str):
        raise ValueError("expected a timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("expected a timezone")
    return parsed.astimezone(timezone.utc)


def read_previous(path, target_id):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data["schema_version"] != SCHEMA_VERSION or data["target_id"] != target_id:
            raise ValueError("report version or RPC target changed")
        data["checked_at"] = utc_datetime(data["checked_at"])
        if data["checked_at"] > datetime.now(timezone.utc):
            raise ValueError("report timestamp is in the future")
        if not isinstance(data["issues"], list) or any(not isinstance(code, str) for code in data["issues"]):
            raise ValueError("invalid issue history")
        observation = data["last_successful_observation"]
        if observation is not None:
            observation["chain"] = ChainState(**observation["chain"])
            for field in ("sampled_at", "best_tracking_since"):
                observation[field] = utc_datetime(observation[field])
            for field in ("best_advanced_at", "finality_tracking_since", "finalized_advanced_at"):
                if observation[field] is not None:
                    observation[field] = utc_datetime(observation[field])
            data["last_successful_observation"] = Observation(**observation)
        return Report(**data)
    except FileNotFoundError:
        return None
    except (ValueError, TypeError, KeyError, RecursionError):
        print("Previous report is incompatible or unreadable as JSON. Starting a new baseline.", file=sys.stderr)
        return None


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        # Write in the same directory so readers see either the previous or the complete new report.
        with NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
            temporary = stream.name
            json.dump(asdict(report), stream, default=datetime.isoformat, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("expected a finite number of seconds greater than zero")
    return seconds


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", default="http://127.0.0.1:9944", help="HTTP(S) JSON-RPC endpoint")
    parser.add_argument("--output", type=Path, default=Path("var/midnight-health.json"),
                        help="path of the latest JSON report (default var/midnight-health.json)")
    parser.add_argument("--interval", type=positive_seconds, default=30, help="seconds between polls (default 30)")
    parser.add_argument("--timeout", type=positive_seconds, default=5, help="RPC request timeout (default 5 seconds)")
    parser.add_argument("--min-peers", type=int, default=2, help="minimum peer count (default 2)")
    parser.add_argument("--stall-after", type=positive_seconds, default=300, help="seconds without progress (default 300)")
    parser.add_argument("--once", action="store_true", help="sample once and exit")
    args = parser.parse_args(argv)
    if args.min_peers < 1:
        parser.error("--min-peers must be at least one")
    try:
        url = urlsplit(args.rpc_url)
        valid_url = url.scheme in {"http", "https"} and url.hostname and url.username is None and not url.fragment
        if not valid_url or url.password is not None or url.port == 0:
            raise ValueError
    except ValueError:
        parser.error("--rpc-url must be a valid HTTP(S) URL without credentials or a fragment")

    target_id = hashlib.sha256(args.rpc_url.encode()).hexdigest()
    try:
        previous = read_previous(args.output, target_id)
        while True:
            started = time.monotonic()
            chain, rpc_error = None, None
            try:
                chain = query_chain(args.rpc_url, args.timeout)
            except RpcError as error:
                rpc_error = error
            now = datetime.now(timezone.utc)
            report = evaluate(chain, rpc_error, previous, now, target_id, args.min_peers, args.stall_after)
            write_report(args.output, report)
            if args.once or report.status != report.changes["previous_status"] or any(
                report.changes[key] for key in ("regressions", "recoveries")
            ):
                regressions = ",".join(report.changes["regressions"]) or "none"
                recoveries = ",".join(report.changes["recoveries"]) or "none"
                print(f"{now.isoformat()} {report.status} regressions={regressions} recoveries={recoveries}", flush=True)
            if args.once:
                return 1 if report.issues else 0
            previous = report
            time.sleep(max(0, args.interval - (time.monotonic() - started)))
    except KeyboardInterrupt:
        return 0
    except OSError as error:
        print(f"Could not read or write health report: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
