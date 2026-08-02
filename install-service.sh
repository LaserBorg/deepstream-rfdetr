#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
service_name='inferencer.service'
service_source="$project_root/$service_name"
service_destination="/etc/systemd/system/$service_name"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run with sudo: sudo $0" >&2
  exit 1
fi

run_user="${SUDO_USER:-$(stat -c '%U' "$project_root")}" 
run_group=$(id -gn "$run_user")
run_home=$(getent passwd "$run_user" | cut -d: -f6)

if [[ ! -f "$project_root/.env" ]]; then
  echo "ERROR: missing $project_root/.env" >&2
  exit 1
fi
if ! grep -q '^INFERENCER_API_KEY=' "$project_root/.env"; then
  echo "ERROR: INFERENCER_API_KEY is missing from $project_root/.env" >&2
  exit 1
fi

sed \
  -e "s|__USER__|$run_user|g" \
  -e "s|__GROUP__|$run_group|g" \
  -e "s|__HOME__|$run_home|g" \
  -e "s|__REPO__|$project_root|g" \
  "$service_source" > "$service_destination"

chmod 600 "$project_root/.env"
systemctl daemon-reload
systemctl enable "$service_name"
systemctl restart "$service_name"

echo "Installed and started $service_name"
systemctl --no-pager --full status "$service_name" || true