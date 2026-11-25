#!/usr/bin/env bash
# Naive (apps/zgx) against the staging edge: a development build, which signs
# in through staging (https://staging.naive.sh, WorkOS's test environment)
# and starts its own engine for it, on port 27871 with its data in
# ~/.naive-staging (apps/zgx/src/engine/manager.rs). It runs beside an
# installed Naive, whose engine (port 27654, ~/.naive) it never uses.
#
#   scripts/staging-app.sh            # build the engine and the app, then open it
#   scripts/staging-app.sh gallery    # any of the app's launch words (apps/zgx/README.md)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# A shell inside Naive carries the installed app's settings (its edge, data
# dir, port, sign-in client): the build's staging defaults hold only without them.
unset NAIVE_APP NAIVE_ORIGIN NAIVE_MANAGED_ENGINE NAIVE_DATA_DIR NAIVE_IPC_PORT \
  NAIVE_EDGE_URL NAIVE_WORKOS_CLIENT_ID NAIVE_CALLBACK_PORT NAIVE_IPC_TOKEN NAIVE_IPC_TOKEN_FILE

# The engine it starts, built as releases build it (no Luau asserts).
(cd "$ROOT" && LUAU_CXXFLAGS=-DNDEBUG cargo build --release -p naive --bin naive-engine)
cd "$ROOT/apps/zgx"
NAIVE_ZGX_ENGINE_BIN="$ROOT/target/release/naive-engine" exec cargo run --release -- "${@:-main}"
