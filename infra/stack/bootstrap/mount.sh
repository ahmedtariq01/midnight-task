#!/usr/bin/env bash
set -euo pipefail

: "${VOLUME_ID:?Expected an EBS volume ID}"
disk_link="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}"
mount_dir=/srv/midnight

for attempt in {1..60}; do
  [[ -b "$disk_link" ]] && break
  sleep 5
done
[[ -b "$disk_link" ]] || { echo "EBS disk did not attach: $VOLUME_ID" >&2; exit 1; }

disk=$(readlink -f "$disk_link")
install -d -m 0755 "$mount_dir"
existing=$(findmnt -nro SOURCE --mountpoint "$mount_dir" || true)
if [[ -z "$existing" ]]; then
  if findmnt -nr --source "$disk" >/dev/null; then
    echo "EBS disk is already mounted elsewhere: $disk" >&2
    exit 1
  fi

  filesystem=$(blkid -p -s TYPE -o value "$disk" || true)
  case "$filesystem" in
    ext4) ;;
    "")
      signatures=$(wipefs --noheadings --output TYPE "$disk")
      devices=$(lsblk --noheadings --raw --output TYPE "$disk")
      if [[ -n "$signatures" || "$devices" != disk ]]; then
        echo "Unexpected disk signatures or partitions on $disk" >&2
        exit 1
      fi
      mkfs.ext4 -q -m 0 "$disk"
      ;;
    *) echo "Expected ext4 on $disk, found $filesystem" >&2; exit 1 ;;
  esac

  mount -t ext4 -o nodev,nosuid "$disk" "$mount_dir"
elif [[ "$existing" != "$disk" ]]; then
  echo "$mount_dir is mounted from $existing" >&2
  exit 1
fi

for directory in "$@"; do
  if [[ -L "$directory" ]]; then
    echo "Unexpected symlink for component data: $directory" >&2
    exit 1
  fi
  [[ -d "$directory" ]] || install -d -m 0750 "$directory"
done
