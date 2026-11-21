# Developing FM-1 Pocket for macOS

Notes for people working on the app. The [README](../README.md) is for people using it.

You never need developer tools on your own Mac to get a build: GitHub builds, tests and packages the app on its own
Macs every time the code changes.

## How it is built

| Folder | What |
| --- | --- |
| `Sources/CWasm3` | wasm3 v0.5.0 (MIT), the WebAssembly interpreter for `.rfm1` builds |
| `Sources/FM1Host` | C: runs one `.rfm1` on wasm3. A port of FM-1 Pocket Player's `src/rfm1.js` (same boot, clock, panel and audio) |
| `Emu/`, `Sources/CFM1Emu` | the emulator engine: upstream [fm1-emu](https://github.com/joakimeriksson/fm1-emu) compiled unchanged into a static library (`scripts/build-emu.sh`), pinned in `Emu/Cargo.toml` |
| `Sources/PocketKit` | Swift: the firmware library (sync, SHA-256-checked downloads, offline cache, two-build retention, safe cleanup), both engines behind one `PlayerEngine` protocol, Core Audio output, saved settings |
| `Sources/FM1Pocket` | the SwiftUI app, and its self-tests (`--selftest`, `--selftest-fwsc`, `--integration`) |
| `Tests/` | Swift tests (`PocketKitTests`, `FM1PocketTests`), a plain C test of the host (`ctest`), the integration test's scenarios |
| `scripts/` | `build-app.sh` (assemble and ad-hoc sign the .app), `build-emu.sh`, `make-zip.sh`, `make-icon.py`, `make-hero.py` |
| `.github/workflows/build.yml` | the build, tests, packaging and optional release |

The app reads what FM-1 Pocket Player publishes (`https://slowphase.github.io/fm1-pocket-player/data/`) and
downloads original packages from their makers' GitHub releases, each checked against its SHA-256. It does not change
or duplicate FM-1 Pocket Player's nightly sync, approval or screenshot jobs.

More: [STORAGE.md](STORAGE.md) (the library, engines, saves and files on disk) and [MILESTONE-1.md](MILESTONE-1.md).

## Getting a test build

1. Open the **Actions** tab and click the latest green **Build Mac app** run.
2. Scroll to **Artifacts** and download the **FM1-Pocket-…** entry.
3. Unzip it and install it as the README describes. Test builds are
   not notarised either.

## Publishing a release

**Actions › Build Mac app › Run workflow**, tick **Also publish this build as a GitHub Release**, type a version (for
example `0.9.0`) and click **Run workflow**. Pushing a tag such as `v0.9.0` does the same. The zip appears under
**Releases** when it finishes.

A release is a normal GitHub Release (not a pre-release), marked as the latest, and leaves out
`Resources/emu-preview.json` (the test builds' stand-in emulator data). Build it only once FM-1 Pocket Player has
published its emulator catalogue, or emulator firmware will not show.

After the first release exists, point the README's **Download for macOS** button and install step at
`/releases/latest` instead of `/releases`.

## The emulator engine

fm1-emu is pinned in `Emu/Cargo.toml`, independently of FM-1 Pocket Player's pin. Move it only to a commit listed in
FM-1 Pocket Player's `pocket/emu/verified.json` (its upgrade check and a listening test); the build warns otherwise.

## Cost

This repository is public, so GitHub Actions builds are free, Mac runners included.
