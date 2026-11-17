#!/usr/bin/env bash
set -euo pipefail
umask 077

service=${1:?Expected a systemd service name}
config="/etc/midnight-stack/credentials/$service.json"
directory="/run/midnight-stack/credentials/$service"
install -d -m 0700 "$directory"

references=$(jq -er 'to_entries[] | [.key, .value] | @tsv' "$config")
while IFS=$'\t' read -r file arn; do
  IFS=: read -r _ _ _ region _ _ <<< "$arn"
  temporary=$(mktemp "$directory/.pending.XXXXXX")
  if ! aws secretsmanager get-secret-value --region "$region" --secret-id "$arn" \
    --output json --no-cli-pager | jq -er '.SecretString | strings | select(length > 0)' >"$temporary"; then
    rm -f "$temporary"
    exit 1
  fi
  mv -f "$temporary" "$directory/$file"
done <<< "$references"
