# FM-1 Pocket for macOS

A native Mac app for playing M-VAVE FM-1 firmware, inspired by [FM-1 Pocket Player](https://github.com/slowphase/fm1-pocket-player).
Discover like Finder. Play like an FM-1.

It reads FM-1 Pocket Player's published firmware catalogue and runs the same `.rfm1` firmware files natively: no
browser, no web view, no Electron. The firmware runs in a small WebAssembly interpreter (wasm3) inside the app, and
its sound goes through Core Audio.

**Status:** Milestones 1 to 3 are done: the native player, the automatic firmware library, the Finder-style library
window and the FM-1 faceplate. See [docs/MILESTONE-1.md](docs/MILESTONE-1.md) and
[docs/STORAGE.md](docs/STORAGE.md).

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

- **The library** works like Finder. The sidebar has All Firmware, Favourites, Recently Played, New (added to
  Pocket in the last 14 days) and the catalogue's categories. Show firmware as icons (⌘1) or a sortable list (⌘2),
  and search with the field in the toolbar ("kwa" finds K-WA SUB). Click a firmware to see its details; double-click,
  or press ⌘↩, to play it. Right-click for more.
- **More Firmware** (when Pocket publishes its expanded catalogue) lists firmware this app cannot download, each with
  the reason and its source page. **Experimental** gathers firmware that passed Pocket's checks but is not yet
  confirmed on macOS (tagged UNTESTED) or may run slowly. Makers are linked to their repositories in the details
  pane, and The Firmware Hub is credited at the bottom of the sidebar when its list was used.
- **Favourites:** the star in the details pane, the list's ★ column, the right-click menu, or ⌘D.
- **The player** is the FM-1 faceplate, laid out like FM-1 Pocket Player's and scaled to its window: PRESETS,
  ALGORITHM, SELECT and MASTER on the left, the screen in the middle, the four knobs and twelve buttons on the right,
  27 keys (F to G) below. Both windows remember where you left them (second monitor included). Closing the player
  stops the sound but not the app: **View › Show Library** (⌘0), **View › Show Player** (⌥⌘P) or the Dock icon
  bring windows back.
  - **Knobs or sliders** (toolbar): drag a knob up or down, or scroll over it. When a firmware says what a knob is
    tied to (h1 does), its name and value show and you can set it directly; otherwise it is an endless encoder.
  - **Buttons** show the firmware's own names and lights. Hold one as long as you like; **Shift-click** latches it
    down so the mouse is free to turn a knob.
  - **Keys:** where you click sets the velocity (near the front is loud); drag across them to play each in turn.
  - **Computer keys** (player window in front): **A W S E D R F G Y H U J K O L P ; [ '** play keys from F,
    **Z / X** octave, **← →** presets, **↑ ↓** algorithm, **, .** select, **1–4** knobs (Shift turns down).
  - **MIDI in:** any connected MIDI keyboard plays the firmware (toolbar toggle, on by default).
  - **Firmware › Power Cycle** (⌘R), **Mute** (⌥⌘M) and **Firmware Info** (⌘I): credits, licences, the firmware's
    log, and its saved settings (export, import, erase). Settings are saved per exact build; when a new version
    starts fresh, the player offers to try the previous version's settings (copied, never moved).
- The library downloads every approved firmware and screenshot automatically and works offline afterwards. Each
  firmware keeps its current and previous build. **FM-1 Pocket › Check for Firmware Updates…** syncs by hand and
  **Clean Up Old Downloads** removes downloads no longer kept. Your saved settings are never touched. Details:
  [docs/STORAGE.md](docs/STORAGE.md).

## How it is built

| Folder | What |
| --- | --- |
| `Sources/CWasm3` | wasm3 v0.5.0 (MIT), the WebAssembly interpreter |
| `Sources/FM1Host` | C: runs one `.rfm1` on wasm3. A port of Pocket Player's `src/rfm1.js` (same boot, clock, panel and audio) |
| `Sources/PocketKit` | Swift: the firmware library (sync, SHA-256-checked downloads, offline cache, two-build retention, safe cleanup), the firmware wrapper, Core Audio output, saved settings |
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
