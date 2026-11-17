#!/usr/bin/env bash
set -euo pipefail
umask 022
die() { printf >&2 'Storage/PostgreSQL setup stopped: %s\n' "$*"; exit 1; }
[[ $EUID == 0 ]] || die 'run as root'
[[ $# == 3 ]] || die 'usage: storage-postgres.sh storage|postgres|all EC2_INSTANCE_ID EBS_VOLUME_ID'
stage=$1
[[ "$stage" == storage || "$stage" == postgres || "$stage" == all ]] || die 'expected storage, postgres, or all'
[[ "$2" =~ ^i-[0-9a-f]+$ && "$3" =~ ^vol-[0-9a-f]+$ ]] || die 'invalid EC2 instance or EBS volume ID'
expected_instance=$2
expected_serial=vol${3#vol-}
mount_path=/srv/midnight
pg_data=$mount_path/postgresql/17/main
pg_conf=/etc/postgresql/17/main
pg_pass=/etc/midnight/dbsync.pgpass
metadata=http://169.254.169.254/latest
token=$(curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "$metadata/api/token")
instance=$(curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 \
    -H "X-aws-ec2-metadata-token: $token" "$metadata/meta-data/instance-id")
unset token
[[ "$instance" == "$expected_instance" ]] || die 'EC2 instance ID does not match'

disk_listing=$(lsblk -dnpo PATH,TYPE,SERIAL)
mapfile -t matches < <(awk -v serial="$expected_serial" \
    '$2 == "disk" { sub(/^vol-/, "vol", $3); if ($3 == serial) print $1 }' <<<"$disk_listing")
[[ ${#matches[@]} == 1 ]] || die 'expected exactly one disk with the approved EBS serial'
disk=$(readlink -f "${matches[0]}")
[[ -b "$disk" && $(blockdev --getsize64 "$disk") == 536870912000 ]] || die 'approved device is not a 500 GiB block device'
[[ $(lsblk -nrpo PATH "$disk") == "$disk" ]] || die 'approved disk has partitions or dependent devices'
root_device=$(findmnt -nro SOURCE --mountpoint /)
[[ $(readlink -f "$root_device") != "$disk" ]] || die 'approved disk resolves to the root filesystem'

verify_mount() {
    local source
    source=$(findmnt -nro SOURCE --mountpoint "$mount_path") || die 'data filesystem is not mounted'
    [[ $(readlink -f "$source") == "$disk" ]] || die 'wrong source mounted at data path'
    [[ $(findmnt -nro FSTYPE --mountpoint "$mount_path") == ext4 ]] || die 'wrong data filesystem type'
}

if [[ "$stage" != postgres ]]; then
    [[ ! -L "$mount_path" ]] || die 'mountpoint is a symlink'
    mkdir -p "$mount_path"
    signatures=$(wipefs --no-act --noheadings --output TYPE "$disk")
    file_type=$(blkid -p -s TYPE -o value "$disk" || true)
    actual_label=$(blkid -p -s LABEL -o value "$disk" || true)
    disk_mounts=$(lsblk -dnro MOUNTPOINTS "$disk")
    if [[ -n "$disk_mounts" ]]; then
        [[ "$disk_mounts" == "$mount_path" ]] || die 'data disk is mounted elsewhere'
        verify_mount
    elif mountpoint -q "$mount_path"; then
        die 'another filesystem is mounted at the data path'
    fi
    if [[ -z "$signatures" && -z "$file_type" ]]; then
        [[ -z "$disk_mounts" ]] || die 'unidentified filesystem already mounted'
        [[ -z $(find "$mount_path" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'mountpoint directory contains data'
        [[ -z $(awk -v path="$mount_path" '$1 !~ /^#/ && $2==path' /etc/fstab) ]] || die 'fstab already has an entry for the unformatted volume'
        mkfs.ext4 -q -m 0 -L midnight-data "$disk"
    else
        [[ "$signatures" == ext4 && "$file_type" == ext4 && "$actual_label" == midnight-data ]] \
            || die 'existing disk signatures do not match the Midnight filesystem'
    fi
    uuid=$(blkid -p -s UUID -o value "$disk")
    [[ "$uuid" =~ ^[a-fA-F0-9-]{36}$ ]] || die 'could not read the ext4 UUID'
    mapfile -t mount_entries < <(awk -v path="$mount_path" '$1 !~ /^#/ && $2==path {print $1, $3}' /etc/fstab)
    if [[ ${#mount_entries[@]} == 0 ]]; then
        printf 'UUID=%s %s ext4 defaults,nofail,x-systemd.device-timeout=15s 0 2\n' "$uuid" "$mount_path" >> /etc/fstab
    else
        [[ ${#mount_entries[@]} == 1 && "${mount_entries[0]}" == "UUID=$uuid ext4" ]] || die 'fstab has a conflicting mount entry'
    fi
    if ! mountpoint -q "$mount_path"; then
        [[ -z $(find "$mount_path" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'mountpoint directory contains data'
        mount "$mount_path"
    fi
    verify_mount
    systemctl daemon-reload
    for account in cardano dbsync; do
        if ! id "$account" >/dev/null 2>&1; then
            useradd --system --user-group --no-create-home --home-dir "$mount_path" --shell /usr/sbin/nologin "$account"
        fi
    done
    install -d -m 0755 /etc/midnight
    install -d -o cardano -g cardano -m 0750 "$mount_path/cardano" "$mount_path/mithril"
    install -d -o dbsync -g dbsync -m 0750 "$mount_path/db-sync"
    findmnt -nro SOURCE,TARGET,FSTYPE --mountpoint "$mount_path"
    printf 'MIDNIGHT_STORAGE_READY serial=%s uuid=%s\n' "$expected_serial" "$uuid"
fi

[[ "$stage" != storage ]] || exit 0
verify_mount
id dbsync >/dev/null 2>&1 || die 'run the storage stage first'
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_CODENAME" == noble && $(dpkg --print-architecture) == amd64 ]] || die 'expected Ubuntu 24.04 amd64'
export DEBIAN_FRONTEND=noninteractive
apt_opts=(-o DPkg::Lock::Timeout=180 -o Acquire::Retries=3)
key_dir=/usr/share/postgresql-common/pgdg
key_file=$key_dir/apt.postgresql.org.asc
if [[ ! -x /usr/lib/postgresql/17/bin/postgres ]]; then
    apt-get "${apt_opts[@]}" update -qq
    apt-get "${apt_opts[@]}" install -y -qq --no-install-recommends curl ca-certificates gnupg openssl
    install -d -m 0755 "$key_dir"
    key_tmp=$(mktemp)
    trap 'rm -f "$key_tmp"' EXIT
    curl -fsS --retry 3 https://www.postgresql.org/media/keys/ACCC4CF8.asc -o "$key_tmp"
    fingerprints=$(gpg --batch --with-colons --show-keys "$key_tmp")
    fingerprint=$(awk -F: '$1 == "fpr" {print $10; exit}' <<<"$fingerprints")
    [[ "$fingerprint" == B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8 ]] || die 'PGDG apt key fingerprint mismatch'
    install -m 0644 "$key_tmp" "$key_file"
    rm -f "$key_tmp"
    trap - EXIT
    cat > /etc/apt/sources.list.d/pgdg.sources <<APT
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: noble-pgdg
Architectures: amd64
Components: main
Signed-By: $key_file
APT
    apt-get "${apt_opts[@]}" update -qq
    apt-get "${apt_opts[@]}" install -y -qq --no-install-recommends postgresql-common
    sed -i '/^[[:space:]#]*create_main_cluster[[:space:]]*=/d' /etc/postgresql-common/createcluster.conf
    printf 'create_main_cluster = false\n' >> /etc/postgresql-common/createcluster.conf
    apt-get "${apt_opts[@]}" install -y -qq --no-install-recommends postgresql-17
fi
if [[ ! -e $pg_conf/postgresql.conf ]]; then
    [[ ! -e $pg_data ]] || die 'found PostgreSQL data without the expected cluster configuration'
    install -d -o postgres -g postgres -m 0750 "$mount_path/postgresql/17"
    pg_createcluster --datadir="$pg_data" --port=5432 --start-conf=auto 17 main
fi
configured_data=$(pg_conftool --short 17 main show data_directory)
[[ "$configured_data" == "$pg_data" ]] || die 'PostgreSQL 17 main uses an unexpected data directory'
install -d -m 0755 "$pg_conf/conf.d" /etc/systemd/system/postgresql@17-main.service.d
config_changed=0
if ! awk '/^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*\047conf[.]d\047/ { found=1 } END { exit !found }' "$pg_conf/postgresql.conf"; then
    printf "\ninclude_dir = 'conf.d'\n" >> "$pg_conf/postgresql.conf"
    config_changed=1
fi
write_if_changed() {
    local target=$1 mode=$2 owner=$3 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if ! cmp -s "$tmp" "$target"; then
        install -o "$owner" -g "$owner" -m "$mode" "$tmp" "$target"
        config_changed=1
    fi
    rm -f "$tmp"
}
write_if_changed "$pg_conf/conf.d/10-midnight.conf" 0644 postgres <<'CONF'
listen_addresses = '127.0.0.1'
port = 5432
password_encryption = 'scram-sha-256'
CONF
write_if_changed "$pg_conf/pg_hba.conf" 0640 postgres <<'HBA'
local   all         postgres                       peer
host    cexplorer   dbsync     127.0.0.1/32         scram-sha-256
HBA
write_if_changed /etc/systemd/system/postgresql@17-main.service.d/storage.conf 0644 root <<'SYSTEMD'
[Unit]
RequiresMountsFor=/srv/midnight
ConditionPathIsMountPoint=/srv/midnight
SYSTEMD
systemctl daemon-reload
if systemctl is-active --quiet postgresql@17-main.service && [[ $config_changed == 1 ]]; then
    systemctl restart postgresql@17-main.service
else
    systemctl start postgresql@17-main.service
fi
systemctl enable postgresql.service >/dev/null

as_postgres() { runuser -u postgres -- psql -Xq -w -v ON_ERROR_STOP=1 "$@"; }
as_dbsync() {
    runuser -u dbsync -- env "PGPASSFILE=$pg_pass" \
        psql -Xq -w -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U dbsync -d cexplorer "$@"
}
if [[ ! -e "$pg_pass" && ! -L "$pg_pass" ]]; then
    pass_tmp=$(mktemp /etc/midnight/.dbsync-pgpass.XXXXXX)
    chmod 0600 "$pass_tmp"
    builtin printf '127.0.0.1:5432:cexplorer:dbsync:%s\n' "$(openssl rand -hex 32)" > "$pass_tmp"
    chown dbsync:dbsync "$pass_tmp"
    mv -T "$pass_tmp" "$pg_pass"
fi
[[ -f "$pg_pass" && ! -L "$pg_pass" && $(stat -c '%U:%G:%a' "$pg_pass") == dbsync:dbsync:600 ]] \
    || die 'DB Sync password file has unexpected ownership or permissions'
IFS=: read -r pg_host pg_port pg_db pg_user password < "$pg_pass"
[[ "$pg_host:$pg_port:$pg_db:$pg_user" == 127.0.0.1:5432:cexplorer:dbsync && "$password" =~ ^[a-f0-9]{64}$ ]] \
    || die 'DB Sync password file has an unexpected format'
as_postgres -d postgres <<'SQL'
SELECT 'CREATE ROLE dbsync LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dbsync')\gexec
SELECT 'CREATE DATABASE cexplorer OWNER dbsync'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cexplorer')\gexec
SQL
[[ $(as_postgres -d postgres -Atc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='cexplorer'") == dbsync ]] \
    || die 'cexplorer has an unexpected owner'
if ! as_dbsync -c 'SELECT 1' >/dev/null 2>&1; then
    builtin printf "SET log_statement = 'none';\nSET log_min_error_statement = 'panic';\nALTER ROLE dbsync PASSWORD '%s';\n" "$password" \
        | as_postgres -d postgres >/dev/null 2>&1 || die 'could not initialize DB Sync login'
fi
unset password
as_dbsync -Atc "SELECT 'MIDNIGHT_POSTGRES_READY database=' || current_database() || ' user=' || current_user"
as_postgres -d postgres -Atc "SELECT 'PostgreSQL ' || current_setting('server_version') || ', data directory ' || current_setting('data_directory')"
