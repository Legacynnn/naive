#!/usr/bin/env bash
# Build this checkout's `naive` for Linux x86_64 (what Boat sandboxes run) in
# a Docker container, and package it as the tarball the Cloud install script
# downloads: target/package-dev/naive-<version>-linux-x86_64.tar.gz, plus
# target/package-dev/latest.txt naming that version.
#
# For trying unreleased engine changes on real Cloud machines
# (scripts/cloud-dev.sh MODE=boat serves these through the local edge).
# The image and the cargo caches are Docker volumes, so rebuilds are
# incremental. Thin LTO is off: this is a dev build, not a release.
#
# Usage: scripts/build-linux-dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="naive-linux-dev-build:1"
OUT="$ROOT/target/package-dev"
BASE="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
VERSION="$BASE-dev.$(date +%Y%m%d%H%M%S)"
mkdir -p "$OUT"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building the $IMAGE image (once)"
  docker build --platform linux/amd64 -t "$IMAGE" - <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# The release workflow's gpui system deps (.github/workflows/release.yml).
RUN apt-get update -qq && apt-get install -y -qq \
      build-essential curl git ca-certificates pkg-config cmake clang \
      libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev \
      libx11-dev libxcb1-dev libx11-xcb-dev \
      libfontconfig1-dev libfreetype-dev libasound2-dev \
      libvulkan-dev libwebkit2gtk-4.1-dev libjson-glib-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
DOCKERFILE
fi

echo "building naive $VERSION for linux-x86_64"
# RUSTUP_TOOLCHAIN: the image's own stable, not rust-toolchain.toml — its
# rustfmt/clippy components (unneeded for a build) make rustup update the
# toolchain in place, which fails on the image's overlay filesystem.
docker run --rm --platform linux/amd64 \
  -v "$ROOT:/src" \
  -v naive-linux-dev-target:/target \
  -v naive-linux-dev-registry:/opt/cargo/registry \
  -v naive-linux-dev-git:/opt/cargo/git \
  -e CARGO_TARGET_DIR=/target \
  -e CARGO_PROFILE_RELEASE_LTO=off \
  -e RUSTUP_TOOLCHAIN=stable \
  -w /src "$IMAGE" \
  sh -c "cargo build --release -p naive && cp /target/release/naive /src/target/package-dev/naive.linux-x86_64 && cp /target/release/naive-engine /src/target/package-dev/naive-engine.linux-x86_64"

STAGE="$OUT/naive-$VERSION-linux-x86_64"
rm -rf "$STAGE"
mkdir -p "$STAGE"
mv "$OUT/naive.linux-x86_64" "$STAGE/naive"
mv "$OUT/naive-engine.linux-x86_64" "$STAGE/naive-engine"
tar -czf "$STAGE.tar.gz" -C "$OUT" "$(basename "$STAGE")"
rm -rf "$STAGE"
echo "$VERSION" > "$OUT/latest.txt"
echo "built $STAGE.tar.gz ($(du -h "$STAGE.tar.gz" | cut -f1))"
