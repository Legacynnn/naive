#!/usr/bin/env bash
# The Linux Rust tests that used to run as separate `cargo test` invocations in
# session-sync-regressions, cursor-compatibility and preview-tests, as ONE
# build and ONE nextest run (separate invocations recompiled the same
# dependency graph with different feature sets).
#
# Same coverage as the old invocations:
#   naive-harness  every test binary (cursor-compatibility ran `-p naive-harness`
#                  plus `--test pi_rpc` with native-fixture; native-fixture only
#                  adds the pi_rpc fixture binaries, so it is on for the whole build)
#   naive-preview  every test binary (preview-tests)
#   naive-doc      lib + persistence and memory regressions + attachments_roundtrip
#   naive-sync, naive-update   lib only (session-sync-regressions)
#   naive-cli, naive-launch, naive-notify   `naive`'s command line, the engine
#                  helper's start-up and the naive:// links, shared by the apps
#   naive-engine   lib + the integration tests named below (plugin_services: the
#                  plugin host's services, end to end; also on macOS in zgx-tests.yml). Engine has many other
#                  integration binaries (live agents etc.) that no workflow ran, so
#                  they are listed instead of globbed to avoid compiling them.
#   voice (moved from voice-tests.yml offline-linux, which ran them as 14 separate
#   `cargo test` builds): naive-voice-media, naive-voice-session and naive-orb
#                  lib, naive-proto lib `voice` tests, naive-mcp lib, naive-rpc
#                  device_room, engine voice_runtime and device_routing. They need no
#                  audio stack, and harness already depends on all of them.
# nextest does not run doctests; these crates have none (their doc comments
# contain no Rust code blocks).
# Extra arguments are passed to nextest (the nightly job adds `--release`).
# NEXTEST_PROFILE=ci (pull requests and main) leaves out the slow and soak tests
# that scripts/ci/nextest.toml lists; the nightly runs use the default profile.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Test binaries that run nothing on Linux are left out: they would still be
# compiled and linked. Windows-only files (#![cfg(windows)]), and files whose
# every test is #[ignore]d because it needs a live service or a real CLI.
skip=" codex_availability windows_native managed_install muse_account_live pi_live real_acp_lifecycle real_quiet_survey coordinator "
tests=()
for f in crates/harness/tests/*.rs crates/preview/tests/*.rs crates/doc/tests/*.rs; do
  name="$(basename "$f" .rs)"
  [[ "$skip" == *" $name "* ]] || tests+=(--test "$name")
done
# `misc` (harness, engine and preview): the small suites, one binary each.
# The orb geometry tests live in naive-orb's `geometry`. `restart_hook`
# stays a binary of its own: the hook it checks is process-wide.
for t in misc geometry session_publication restart_resume side_chats message_queue voice_runtime device_routing device_room plugin_services restart_hook; do
  tests+=(--test "$t")
done

exec cargo nextest run --config-file scripts/ci/nextest.toml --locked --no-fail-fast \
  -p naive-harness -p naive-engine -p naive-sync -p naive-update -p naive-doc -p naive-preview \
  -p naive-mcp -p naive-proto -p naive-rpc -p naive-orb -p naive-voice-session -p naive-voice-media \
  -p naive-cli -p naive-launch -p naive-notify \
  --features naive-harness/native-fixture \
  --lib --bins "${tests[@]}" \
  -E 'not ((package(naive-proto) & not test(voice)) | (package(naive-rpc) & kind(lib)))' "$@"
