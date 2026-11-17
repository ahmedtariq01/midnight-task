#!/usr/bin/env bash
set -euo pipefail

stage=${1:?Choose cardano, db-sync, or midnight-node}
# Managed by cloud-init from environment input.
source /etc/midnight-stack/network.env

cardano_network=(--mainnet)
if [[ -n "$CARDANO_MAGIC" ]]; then
  cardano_network=(--testnet-magic "$CARDANO_MAGIC")
fi

cardano_tip() {
  timeout 5s cardano-cli query tip --socket-path "$CARDANO_SOCKET_PATH" "${cardano_network[@]}"
}

cardano_ready() {
  [[ -S "$CARDANO_SOCKET_PATH" ]] &&
    runuser -u postgres -- pg_isready -q -t 2 -d cexplorer &&
    cardano_tip | jq -e '.block | numbers | . > 0' >/dev/null
}

ready_cardano_tip() {
  jq -er 'select(.syncProgress == "100.00") | "\(.block)|\(.slot)|\(.hash)"'
}

db_sync_ready() {
  local before database after
  before=$(cardano_tip | ready_cardano_tip) || return 1
  database=$(timeout 5s runuser -u postgres -- psql -XAtq -v ON_ERROR_STOP=1 -d cexplorer \
    -c "SELECT block_no, slot_no, encode(hash, 'hex') FROM block WHERE block_no IS NOT NULL ORDER BY id DESC LIMIT 1") || return 1
  after=$(cardano_tip | ready_cardano_tip) || return 1
  [[ "$database" == "$before" || "$database" == "$after" ]]
}

midnight_rpc() {
  curl -fsS --max-time 5 -H 'Content-Type: application/json' \
    --data "$1" http://127.0.0.1:9944
}

midnight_ready() {
  local responses finalized
  responses=$(midnight_rpc '[
    {"jsonrpc":"2.0","id":1,"method":"system_health","params":[]},
    {"jsonrpc":"2.0","id":2,"method":"system_syncState","params":[]},
    {"jsonrpc":"2.0","id":3,"method":"chain_getFinalizedHead","params":[]}
  ]') || return 1
  finalized=$(jq -er '
    def result($id): first(.[] | select(.id == $id) | .result);
    result(1) as $health | result(2) as $sync | result(3) as $finalized
    | select($health.isSyncing == false and ($health.peers // 0) > 0)
    | select($sync.highestBlock == null or $sync.currentBlock >= $sync.highestBlock)
    | $finalized | strings | select(test("^0x[0-9a-fA-F]{64}$"))
  ' <<< "$responses") || return 1
  midnight_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"chain_getHeader\",\"params\":[\"$finalized\"]}" |
    jq -e '.result.number | strings | test("^0x[0-9a-fA-F]*[1-9a-fA-F][0-9a-fA-F]*$")' >/dev/null
}

case "$stage" in
  cardano) probe=cardano_ready ;;
  db-sync) probe=db_sync_ready ;;
  midnight-node) probe=midnight_ready ;;
  *) echo "Unknown readiness stage: $stage" >&2; exit 2 ;;
esac

deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
  if "$probe"; then
    echo "Readiness passed: $stage"
    exit 0
  fi
  sleep 5
done
echo "Readiness timed out: $stage" >&2
exit 1
