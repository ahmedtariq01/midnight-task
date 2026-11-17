#!/usr/bin/env bash
set -euo pipefail
umask 022

mount_root=/srv/midnight
config_dir=/etc/midnight/cardano-preprod
cardano_dir="$mount_root/cardano"
snapshot_dir="$mount_root/mithril"
cardano_version=11.0.1
mithril_version=2642.0
snapshot_digest=edab42a1e9ad419fcc37d27c43d55387d4bf55a7b0f1fc36eb24abe7fb949c9c

die() {
    printf 'Cardano relay setup stopped: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 && "$(uname -m)" == x86_64 ]] || die 'Run as root on the amd64 Ubuntu host.'
mountpoint -q "$mount_root" || die "$mount_root must be mounted first."
id -u cardano >/dev/null || die 'The cardano service account must exist.'
[[ -d "$cardano_dir" && -d "$snapshot_dir" ]] || die 'Create the service data directories first.'
runuser -u cardano -- test -w "$cardano_dir" || die 'The cardano account cannot write its chain directory.'
runuser -u cardano -- test -w "$snapshot_dir" || die 'The cardano account cannot write its Mithril staging directory.'

exec 9>/run/lock/midnight-cardano-relay.lock
flock -n 9 || die 'A Cardano relay setup is already running.'
tmp=$(mktemp -d "$mount_root/.relay-setup.XXXXXX")
incoming=''
cleanup() {
    rm -rf -- "$tmp"
    if [[ -n $incoming ]]; then
        rm -rf -- "$incoming"
    fi
}
trap cleanup EXIT

download() {
    curl --fail --silent --show-error --location --retry 4 --connect-timeout 15 \
        --max-time 1200 --proto '=https' --proto-redir '=https' --output "$2" "$1"
}

verify() {
    printf '%s  %s\n' "$1" "$2" | sha256sum --check --status || die "Checksum failed for $2."
}

if [[ ! -x "/opt/cardano-node/$cardano_version/bin/cardano-node" ||
      ! -x "/opt/cardano-node/$cardano_version/bin/cardano-cli" ||
      ! -s "$config_dir/config.json" || ! -s "$config_dir/topology.json" ]]; then
    printf 'Downloading Cardano node %s and its PreProd configuration.\n' "$cardano_version"
    archive="$tmp/cardano.tar.gz"
    download "https://github.com/IntersectMBO/cardano-node/releases/download/$cardano_version/cardano-node-$cardano_version-linux-amd64.tar.gz" "$archive"
    verify 40e88a543564251338c4888ef79fde51d2306c18b48ac308c9eab3220e3a13f0 "$archive"
    tar -xzf "$archive" -C "$tmp" --no-same-owner ./bin/cardano-node ./bin/cardano-cli ./share/preprod
    install -d -m 0755 "/opt/cardano-node/$cardano_version/bin" "$config_dir"
    install -m 0755 "$tmp/bin/cardano-node" "$tmp/bin/cardano-cli" "/opt/cardano-node/$cardano_version/bin/"
    install -m 0644 "$tmp/share/preprod/"*.json "$config_dir/"
fi
node_bin="/opt/cardano-node/$cardano_version/bin/cardano-node"
cli_bin="/opt/cardano-node/$cardano_version/bin/cardano-cli"
"$node_bin" --version
"$cli_bin" --version

chain_dir="$cardano_dir/db"
digest_file="$cardano_dir/mithril-snapshot-digest"
if [[ ! -d "$chain_dir/immutable" ]]; then
    if [[ -e "$chain_dir" ]]; then
        die "Unexpected existing chain path $chain_dir. Inspect it before proceeding."
    fi
    mithril_bin="/opt/mithril/$mithril_version/bin/mithril-client"
    if [[ ! -x "$mithril_bin" ]]; then
        printf 'Downloading Mithril client distribution %s.\n' "$mithril_version"
        archive="$tmp/mithril.tar.gz"
        download "https://github.com/IntersectMBO/mithril/releases/download/$mithril_version/mithril-$mithril_version-linux-x64.tar.gz" "$archive"
        verify aba4d675c2c1cf62bf16748a9d448e1a15bf410a142306e6548dfcc38ee89500 "$archive"
        tar -xzf "$archive" -C "$tmp" --no-same-owner mithril-client
        install -D -m 0755 "$tmp/mithril-client" "$mithril_bin"
    fi
    "$mithril_bin" --version
    key_file="$tmp/preprod-genesis.vkey"
    download "https://raw.githubusercontent.com/IntersectMBO/mithril/$mithril_version/mithril-infra/configuration/release-preprod/genesis.vkey" "$key_file"
    verify 90da9b6ce771e659b7e3386205a33a4f322cf89d0cb2e00d0a4870a78dcb88df "$key_file"

    printf 'Downloading and verifying Mithril PreProd snapshot %s.\n' "$snapshot_digest"
    incoming=$(runuser -u cardano -- mktemp -d "$snapshot_dir/.incoming.XXXXXX")
    # The aggregator used Cardano 11.1.3. Restore certified immutable files and let
    # the pinned 11.0.1 node rebuild its ledger in its own on-disk format.
    runuser -u cardano -- env \
        AGGREGATOR_ENDPOINT=https://aggregator.release-preprod.api.mithril.network/aggregator \
        GENESIS_VERIFICATION_KEY="$(cat "$key_file")" \
        "$mithril_bin" cardano-db download "$snapshot_digest" --download-dir "$incoming"
    [[ -n "$(find "$incoming/db/immutable" -maxdepth 1 -type f -name '*.chunk' -print -quit)" ]] \
        || die 'The verified snapshot lacks immutable blocks.'
    runuser -u cardano -- mv -- "$incoming/db" "$chain_dir"
    printf '%s\n' "$snapshot_digest" > "$digest_file"
fi

cat > /etc/systemd/system/cardano-node.service <<'UNIT'
[Unit]
Description=Cardano PreProd relay
Wants=network-online.target
After=network-online.target
RequiresMountsFor=/srv/midnight
ConditionPathIsMountPoint=/srv/midnight

[Service]
Type=simple
User=cardano
Group=cardano
UMask=0007
RuntimeDirectory=cardano-node
RuntimeDirectoryMode=0770
WorkingDirectory=/etc/midnight/cardano-preprod
ExecStart=/opt/cardano-node/11.0.1/bin/cardano-node run --config /etc/midnight/cardano-preprod/config.json --topology /etc/midnight/cardano-preprod/topology.json --database-path /srv/midnight/cardano/db --socket-path /run/cardano-node/node.socket --host-addr 0.0.0.0 --port 3001
Restart=on-failure
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=90
LimitNOFILE=32768
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now cardano-node.service
systemctl is-active cardano-node.service
printf 'Cardano network preprod, magic 1. The relay may still be replaying its ledger.\n'
if [[ -f "$digest_file" ]]; then
    printf 'Mithril snapshot %s\n' "$(cat "$digest_file")"
fi
