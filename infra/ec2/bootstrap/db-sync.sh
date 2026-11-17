#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 && $(uname -m) == x86_64 ]] || { echo 'Run as root on x86_64.' >&2; exit 1; }
mountpoint -q /srv/midnight || { echo '/srv/midnight must be mounted.' >&2; exit 1; }
cd /
umask 022

version=13.7.1.0
release="/opt/cardano-db-sync/$version"
config=/etc/midnight/cardano-db-sync-preprod.json
node_config=/etc/midnight/cardano-preprod/config.json
pgpass=/etc/midnight/dbsync.pgpass
state=/srv/midnight/db-sync/state

test -r "$node_config"
test "$(stat -c '%U:%G:%a' "$pgpass")" = 'dbsync:dbsync:600'
runuser -u dbsync -- test -r "$node_config"
runuser -u dbsync -- env PGPASSFILE="$pgpass" psql -X -A -t -w \
  -h 127.0.0.1 -p 5432 -U dbsync -d cexplorer \
  -v ON_ERROR_STOP=1 -c 'SELECT current_database(), current_user;'

install -d -m 0750 -o dbsync -g dbsync "$state"
install -d -m 0755 /opt/cardano-db-sync
work=$(mktemp -d /opt/cardano-db-sync/.setup.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

if [[ ! -e "$release" ]]; then
  asset="cardano-db-sync-$version-linux.tar.gz"
  curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 4 \
    "https://github.com/IntersectMBO/cardano-db-sync/releases/download/$version/$asset" \
    --output "$work/$asset"
  (cd "$work" && printf '%s  %s\n' '2e35bdfe91490acafa030afa07bb9a504a6ed48d8fa5eeb0ecee65b034975b75' "$asset" | sha256sum --check)
  install -d -m 0755 "$work/release"
  tar -xzf "$work/$asset" -C "$work/release" --no-same-owner --no-same-permissions ./bin/cardano-db-sync ./schema
  test -x "$work/release/bin/cardano-db-sync"
  test -f "$work/release/schema/migration-2-0048-20260520.sql"
  mv -T -- "$work/release" "$release"
fi
test -f "$release/schema/migration-2-0048-20260520.sql"
"$release/bin/cardano-db-sync" --version

curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location --retry 4 \
  https://book.world.dev.cardano.org/environments/preprod/db-sync-config.json \
  --output "$work/preprod.json"
python3 - "$work/preprod.json" "$work/config.json" "$node_config" <<'PY'
import json
import sys

source, destination, node_path = sys.argv[1:]
with open(source, encoding="utf-8") as file:
    config = json.load(file)
if config.get("NetworkName", "").lower() != "preprod":
    raise SystemExit("The DB Sync configuration must target PreProd.")
config["NodeConfigFile"] = node_path
with open(destination, "w", encoding="utf-8") as file:
    json.dump(config, file, indent=2)
    file.write("\n")
PY
install -m 0644 "$work/config.json" "$config"

cat >"$work/cardano-db-sync.service" <<'UNIT'
[Unit]
Description=Cardano DB Sync (PreProd)
Wants=network-online.target
Requires=cardano-node.service postgresql@17-main.service
After=network-online.target cardano-node.service postgresql@17-main.service
RequiresMountsFor=/srv/midnight
ConditionPathIsMountPoint=/srv/midnight

[Service]
Type=simple
User=dbsync
Group=dbsync
SupplementaryGroups=cardano
Environment=PGPASSFILE=/etc/midnight/dbsync.pgpass
WorkingDirectory=/srv/midnight/db-sync
ExecStartPre=/usr/bin/bash -c 'for attempt in {1..120}; do test -S /run/cardano-node/node.socket && exit 0; sleep 1; done; echo "Cardano relay socket unavailable" >&2; exit 1'
ExecStart=/opt/cardano-db-sync/13.7.1.0/bin/cardano-db-sync --config /etc/midnight/cardano-db-sync-preprod.json --socket-path /run/cardano-node/node.socket --schema-dir /opt/cardano-db-sync/13.7.1.0/schema --state-dir /srv/midnight/db-sync/state
Restart=on-failure
RestartSec=10s
TimeoutStartSec=130s
TimeoutStopSec=120s
KillSignal=SIGINT
UMask=0027
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/srv/midnight/db-sync
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
install -m 0644 "$work/cardano-db-sync.service" /etc/systemd/system/cardano-db-sync.service
systemctl daemon-reload
systemctl enable --now cardano-db-sync.service
systemctl show -p ActiveState -p SubState -p MainPID cardano-db-sync.service
