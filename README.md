# FM-1 Pocket for macOS

A native Mac app for playing M-VAVE FM-1 firmware, inspired by [FM-1 Pocket Player](https://github.com/slowphase/fm1-pocket-player).
Discover like Finder. Play like an FM-1.

It reads FM-1 Pocket Player's published firmware catalogue and runs the same `.rfm1` firmware files natively: no
browser, no web view, no Electron. The firmware runs in a small WebAssembly interpreter (wasm3) inside the app, and
its sound goes through Core Audio.

**Status: Milestone 1 (technical proof of concept).** See [docs/MILESTONE-1.md](docs/MILESTONE-1.md) for what works,
what has been tested and what is next.

## Getting the app

You never need to install developer tools. GitHub builds the app on one of its own Macs every time the code changes.

1. Open the **Actions** tab of this repository and click the latest green **Build Mac app** run.
2. Scroll to **Artifacts** at the bottom and click the **FM1-Pocket-…** entry. A `.zip` downloads.
3. Double-click the `.zip` to get the `.dmg`, then double-click the `.dmg`.
4. Drag **FM-1 Pocket** onto **Applications**.
5. The first time, macOS blocks it because it is not notarised by Apple. Follow
   [If the app will not open](docs/If%20the%20app%20will%20not%20open.txt) (also inside the DMG). Once only.

Versioned DMGs can also be published under **Releases** (see below).

## Using it

- The sidebar lists every firmware in the catalogue, plus h1, which is built in so there is always something to play
  offline. Search with the field at the top of the sidebar.
- Select a firmware and press **Play** (or ⌘↩). The first play downloads it; after that it works offline.
- Computer keys, as in Pocket Player: **A W S E D R F G Y H U J K O L P ; [ '** play notes, **Z / X** change octave,
  **← →** presets, **↑ ↓** algorithm, **, .** select, **1–4** knobs (hold Shift to turn down).
- **FM-1 Pocket › Check for Firmware Updates…** fetches the catalogue again (it is also checked at every launch).

## How it is built

| Folder | What |
| --- | --- |
| `Sources/CWasm3` | wasm3 v0.5.0 (MIT), the WebAssembly interpreter |
| `Sources/FM1Host` | C: runs one `.rfm1` on wasm3. A port of Pocket Player's `src/rfm1.js` (same boot, clock, panel and audio) |
| `Sources/PocketKit` | Swift: the catalogue client (with SHA-256 checks and an offline cache), the firmware wrapper, Core Audio output, saved settings |
| `Sources/FM1Pocket` | the SwiftUI app |
| `Tests/` | Swift tests (`PocketKitTests`) and a plain C test of the host (`ctest`) |
| `scripts/` | `build-app.sh` (assemble and ad-hoc sign the .app), `make-dmg.sh` |
| `.github/workflows/build.yml` | the build, tests, DMG and optional release |

The app only reads what FM-1 Pocket Player publishes (`https://slowphase.github.io/fm1-pocket-player/data/`). It
does not change or duplicate Pocket Player's nightly sync, approval or screenshot jobs.

## Publishing a release

**Actions › Build Mac app › Run workflow**, tick **Also publish this build as a GitHub Release**, type a version
(for example `0.1.0`) and click **Run workflow**. The DMG appears under **Releases** when it finishes.

## Cost

This repository is public, so GitHub Actions builds are free, Mac runners included. (A private repository would get
a small monthly allowance of Mac build time on GitHub's free plan, then be charged.)

## Licences

The app's own code is MIT. It includes wasm3 (MIT) and h1 (MIT, Jake Handy), and its firmware host is a port of
Jake Handy's MIT-licensed simulator code: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Every other firmware
is downloaded from FM-1 Pocket Player when you play it, and stays its authors' work under its own licence.
