#!/bin/sh
# Copies example plugins into a Naive data dir's plugins folder and signs
# them as that engine's account (`naive plugin sign`), for a scratch engine:
#
#   ./install.sh <data-dir> <port> [plugin ...]     (default: every one here)
#
# The engine must be running (its IPC on <port>, its token in <data-dir>).
# Never the production engine: port 27654, ~/.naive and ~/.comet-native
# (and anything under them) are refused.
# `focus` is meant to be signed by another account: install it on that
# account's engine, then copy its signed folder over (see rig/).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
data=${1:?usage: install.sh <data-dir> <port> [plugin ...]}
port=${2:?usage: install.sh <data-dir> <port> [plugin ...]}
shift 2
case "$port" in 27654) echo "refusing the production engine's port" >&2; exit 1 ;; esac
[ -d "$data" ] || { echo "no such data dir: $data (the engine makes it)" >&2; exit 1; }
real=$(cd "$data" && pwd -P)
for prod in "$HOME/.naive" "$HOME/.comet-native"; do
  prod_real=$( (cd "$prod" 2>/dev/null && pwd -P) || echo "$prod")
  for p in "$prod" "$prod_real"; do
    case "$real" in "$p" | "$p"/*) echo "refusing the production engine's data ($prod)" >&2; exit 1 ;; esac
  done
done
if [ $# -eq 0 ]; then
  for dir in "$here"/*/; do
    if [ -f "$dir/naive-plugin.json" ]; then set -- "$@" "$(basename "$dir")"; fi
  done
fi
naive=${NAIVE_BIN:-$root/target/debug/naive}
mkdir -p "$data/plugins"
for id in "$@"; do
  rm -rf "$data/plugins/$id"
  cp -R "$here/$id" "$data/plugins/$id"
  cp "$root/apps/zgx/plugins-sdk/naive.luau" "$data/plugins/$id/naive.luau"
done
sleep 1
for id in "$@"; do
  env -u NAIVE_IPC_TOKEN NAIVE_IPC_PORT="$port" NAIVE_DATA_DIR="$data" NAIVE_IPC_TOKEN_FILE="$data/ipc-token" "$naive" plugin sign "$id"
done
env -u NAIVE_IPC_TOKEN NAIVE_IPC_PORT="$port" NAIVE_DATA_DIR="$data" NAIVE_IPC_TOKEN_FILE="$data/ipc-token" "$naive" plugin list
