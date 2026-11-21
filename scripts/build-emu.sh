#!/usr/bin/env bash
# Builds upstream fm1-emu's machine (Emu/: its crates/fm1-web at the pinned commit, unchanged) as one universal static
# library for both Mac architectures: Vendor/fm1emu/libfm1emu_pocket.a. Needs rustup.
set -euo pipefail
cd "$(dirname "$0")/.."
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
for t in aarch64-apple-darwin x86_64-apple-darwin; do
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --locked --manifest-path Emu/Cargo.toml --target "$t"
done
mkdir -p Vendor/fm1emu
lipo -create -output Vendor/fm1emu/libfm1emu_pocket.a \
  Emu/target/aarch64-apple-darwin/release/libfm1emu_pocket.a Emu/target/x86_64-apple-darwin/release/libfm1emu_pocket.a
lipo -info Vendor/fm1emu/libfm1emu_pocket.a
