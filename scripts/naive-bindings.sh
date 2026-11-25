#!/usr/bin/env bash
# Regenerates the committed iOS bindings from a host build; their checksums
# depend on the crate name, so upstream's copies never match ours.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
cargo build --locked -p naive-mobile --lib
cargo build --locked -p naive-mobile --bin uniffi-bindgen --features bindgen
LIB="target/debug/libnaive_mobile.dylib"
[[ -f "$LIB" ]] || LIB="target/debug/libnaive_mobile.so"
GEN="$(mktemp -d)"
target/debug/uniffi-bindgen generate --library "$LIB" --language swift --out-dir "$GEN" >/dev/null
cp "$GEN/naive_core.swift" apps/ios/Naive/Core/Generated/naive_core.swift
cp "$GEN/naive_coreFFI.h" apps/ios/CoreFFI/naive_coreFFI.h
cp "$GEN/naive_coreFFI.modulemap" apps/ios/CoreFFI/module.modulemap
git status --short apps/ios/Naive/Core/Generated apps/ios/CoreFFI
