# Firmware library: synchronisation and storage

How FM-1 Pocket for macOS keeps a local, offline copy of FM-1 Pocket Player's approved firmware. The code is in
`Sources/PocketKit`: `FirmwareLibrary.swift` (sync, downloads, playback, cleanup), `LibraryStorage.swift` (folders,
name checks, the registry), `DownloadScheduler.swift` and `StateStore.swift`. Tests are in
`Tests/PocketKitTests/LibraryTests.swift`.

The app only reads what Pocket Player publishes: `catalog-v2.json` (when published), `catalog.json`,
`fw/<id>-<sha8>.rfm1` and `shots/<id>-<sha8>.png` under `https://slowphase.github.io/fm1-pocket-player/data/`. It
never downloads firmware from anywhere else, so Pocket's review and approval stay the only way in.

## The two catalogues

- `catalog-v2.json` (schema 2) is tried first. It lists every firmware Pocket has discovered, with each player's
  status: **playable**, **experimental** (passed the checks, but not yet confirmed on macOS, or may run slowly),
  **unsupported** or **source-only** (no build Pocket may redistribute), with the reason and the test behind it,
  the makers linked to their repositories, and The Firmware Hub's credit when its list was used. The app downloads
  only entries that have a build *and* a Mac status of playable or experimental. Those carry exactly their
  `catalog.json` fields, so they are the same files. Everything else appears under **More Firmware** with its reason
  and a link to its source page; it is never downloaded. A state the app does not recognise counts as source-only.
- `catalog.json` (schema 1) is the fallback when v2 is missing, does not decode, has another schema or offers
  nothing downloadable. Builds up to 19 only ever read this file, and Pocket keeps it unchanged.
- Whichever feed is accepted is cached (`Managed/catalog-v2.json` or `Managed/catalog.json`). Falling back to v1
  removes a cached v2, so More Firmware never shows a stale list. The library works offline from either.
- A firmware whose Mac status changes to unsupported leaves the downloadable list, so it is treated like a withdrawn
  firmware: the downloaded copy and its saved settings are kept.

## Storage layout

Everything is under `~/Library/Application Support/FM-1 Pocket/`.

| Folder | Owner | Contents |
| --- | --- | --- |
| `Managed/catalog.json` | app | the last catalogue that downloaded and passed validation |
| `Managed/catalog-v2.json` | app | the same for the expanded catalogue, preferred when present |
| `Managed/registry.json`, `registry.bak.json` | app | what is installed (below) and its previous good copy |
| `Managed/firmware/<id>/<sha256>.rfm1` | app | verified firmware, named by content hash |
| `Managed/shots/<name>.png` | app | screenshots, named as the catalogue names them |
| `Managed/tmp/` | app | downloads in progress |
| `State/<id>/<version>@<sha12>.flash` (+ `.prev`) | **user** | saved settings, one per exact build, with the previous save as backup |
| `Imported/<id>-<sha12>.rfm1` | **user** | imported firmware (storage only; no import button yet) |
| `UserData/favourites.json` | **user** | favourites (storage only; no favourites button yet) |
| `Catalogue/` | app | Milestone 1's old download cache, removed by cleanup |

Sync and cleanup can only delete inside `Managed/` and the old `Catalogue/` cache. They never read, write or delete
anything in `State/`, `Imported/` or `UserData/`.

## What happens at launch

1. The cached catalogue and the registry are read from disk and the library is shown straight away, before any
   network request.
2. The catalogue is fetched. It is accepted only if it decodes, has schema 1 and still lists at least one usable
   firmware. Entries with an unsafe id, checksum or path are dropped one by one (an unsafe screenshot path just
   loses the screenshot). Only an accepted catalogue replaces the cached one. If it is refused, or the Mac is
   offline, nothing else happens: no downloads, no cleanup, and the downloaded library keeps working.
3. Firmware missing from the new catalogue is marked **withdrawn**. Firmware that reappears is listed again.
4. Every listed firmware whose current build is not on disk is downloaded, along with any screenshot not yet
   cached. A build is identified by firmware id plus SHA-256, so:
   - republished identical bytes are not an update and download nothing;
   - a rebuild with the same version string but different bytes *is* an update;
   - if the catalogue goes back to a build that is still installed, it is promoted to current with no download.
5. Cleanup runs (below).

The first launch downloads the whole approved library. Later launches download only what changed. **Check for
Firmware Updates…** in the app menu runs the same sync by hand.

## Downloads

- At most **two background transfers** run at once; the rest queue, first come first served.
- Pressing **Play** on a firmware that is not downloaded starts it at once, ahead of the queue. If that firmware is
  already queued, it is promoted.
- Each build downloads **once**, however many things ask for it at the same time.
- A download goes to `Managed/tmp/`, its SHA-256 is checked against the catalogue, and only then is it moved to
  `Managed/firmware/<id>/<sha256>.rfm1` and recorded in the registry. A wrong checksum or a failed transfer
  installs nothing and leaves the previous build in place.
- Screenshots are optional. A missing one, or a response that is not a PNG or JPEG, never stops a firmware from
  downloading or playing.
- Every install is committed on its own, so an interrupted sync keeps every install that finished.

## Retention: the current and one previous build

Each firmware keeps **the latest and the previous successfully installed build**: the last distinct build this Mac
installed, not necessarily the previous upstream release. When a third build installs, the oldest one drops out of
the registry and its file is deleted by the cleanup that follows, never before the new build is verified and
committed.

Example: SLOOP 3.4 installed. Then 3.5 arrives: 3.5 is current, 3.4 is previous. Then 3.6: 3.6 current, 3.5 previous,
3.4 deleted.

A firmware that is **playing** is never deleted, even once it falls out of the two kept builds. It goes at the first
cleanup after it stops.

## Playing

Play uses the catalogue's current build, downloading it first if needed. If that fails (offline, server error) the
newest installed build that still verifies is played instead, and the player's title says so. A file that no longer
matches its hash is dropped and downloaded again.

## Saved settings

Saved settings are user data, kept for every build indefinitely, even after that build's firmware file has been
cleaned up. They are keyed by **exact build** (`<version>@<first 12 hex digits of its SHA-256>`), so a rebuild that
keeps its version string can never load another build's settings.

Settings are never copied between builds automatically, because releases can store settings differently. When a
build has no save but another build of the same firmware does, the registry records it
(`stateFromOtherBuild`), so a later version of the app can offer "start fresh" (the default) or "try my previous
settings" (copying, never moving, the original). There is no prompt yet.

The existing safety net is unchanged: every write goes to a temporary file first, and the previous save is kept as
`.prev`.

## The registry

`Managed/registry.json` records, for each firmware: its kept builds (version, SHA-256, file, size, install time,
screenshot, origin, last played), whether it is listed or withdrawn (and since when), its last catalogue entry (so a
withdrawn firmware can still be described), its last download error, and any saved-settings note. Imported files
have their own list.

"In use" is tracked in memory while the app runs, not on disk, so a crash can never leave a firmware wrongly marked
as in use for ever.

Writes are atomic (temporary file, then rename), and the previous good registry is kept as `registry.bak.json`. On
launch:

1. `registry.json` is used if it reads correctly.
2. Otherwise `registry.bak.json` is used, then any verified catalogue build already in place (the backup can be one
   install behind) is added back.
3. If both are damaged, the registry is **rebuilt from disk**: every `firmware/<id>/<sha256>.rfm1` whose content
   still matches its name is kept (the cached catalogue's current build first, then newest first, two per
   firmware), plus every valid `.rfm1` in `Imported/`. Files that do not verify are left out and cleaned up later,
   and replaced by fresh downloads at the next sync.

Damaged metadata never costs a verified firmware file.

## Withdrawal

When a firmware disappears from Pocket's catalogue it is hidden from the library, marked withdrawn, and never
downloaded again. Its installed builds, saved settings and any imported copies are all kept. If it comes back, it is
listed again with nothing downloaded twice.

## Cleanup

`CleanupPlanner` first works out a list of deletions without touching anything, then only regular files inside the
managed folders are removed. It looks in exactly these places, never recursing further:

| Where | Deleted |
| --- | --- |
| `Managed/firmware/<id>/` | builds the two-build rule no longer keeps (unless playing); files with the wrong name or for an unknown firmware |
| `Managed/shots/` | screenshots used by no kept build and no listed firmware (a new screenshot always downloads before the old one becomes unused) |
| `Managed/tmp/` | abandoned downloads (not ones in progress) |
| `Catalogue/` | Milestone 1's `catalog.json` and `fw/*.rfm1` |

It runs automatically after every sync that got a good catalogue, and by hand from **Clean Up Old Downloads** in
the app menu.

## Storage use

`FirmwareLibrary.storageUsage()` reports bytes for: current firmware, previous firmware, firmware awaiting cleanup,
screenshots and catalogue metadata, saved settings (with backups and favourites), imported files, and temporary
downloads. It is ready for a future Manage Storage window; there is no window yet.

## Tests

`Tests/PocketKitTests/LibraryTests.swift` runs against `FakePocket`, an in-memory stand-in for Pocket's site that
records every request and can hold, fail or corrupt any file, so no test touches the network. The live-catalogue test
from Milestone 1 still runs separately in CI.

| # | Test | What it checks |
| --- | --- | --- |
| 1 | `testInitialFullSync` | first launch downloads every firmware and screenshot, never more than two at once |
| 2 | `testRelaunchWithNoChangesDownloadsNothing` | a relaunch fetches only the catalogue |
| 3 | `testOneUpdateDownloadsOnlyThatFirmware` | one update downloads just that firmware and its screenshot |
| 4 | `testTwoVersionRetention` | first and second updates keep current + previous; the third build and its screenshot go |
| 5 | `testRebuildWithSameVersionIsADistinctBuild` | same version, new checksum is an update with separate saves; identical republish is not |
| 6 | `testFailedDownloadKeepsLastGoodVersion` | a failed update leaves the old build playing; a retry succeeds |
| 7 | `testWrongChecksumIsNeverInstalled` | a bad SHA-256 installs nothing and leaves nothing behind |
| 8 | `testInterruptedSyncRecovers` | finished installs survive; a verified file left by a crash is adopted; partial downloads are removed |
| 9 | `testOfflineStartupWithFullCache` | offline: library, metadata, screenshots and playback all work; no cleanup |
| 10 | `testOfflineStartupWithIncompleteCache` | offline with gaps: downloaded firmware plays, the rest says not downloaded |
| 11 | `testCleanupNeverTouchesUserData` | cleanup removes managed junk only; saves, `.prev` backups, favourites, exports and imports are byte-for-byte intact |
| 12 | `testCleanupRefusesAPlayingFirmware` | a playing build outside the kept two survives until it stops |
| 13 | `testImportsAreNeverReplacedOrRemoved` | an import survives a catalogue firmware with the same id updating and disappearing |
| 14 | `testWithdrawalKeepsFilesAndSavesAndIsNotRedownloaded` | withdrawal hides, keeps files and saves, never re-downloads; reappearing relists |
| 15 | `testDamagedRegistryFallsBackThenRebuilds` | backup first, then a rebuild from disk; nothing downloaded again; corrupt files not trusted |
| 16 | `testMissingScreenshotDoesNotBlockFirmware` | 404 or non-image screenshots never block a firmware |
| 17 | `testConcurrentRequestsShareOneDownload` | sync, a background request and Play for one build make one download |
| 18 | `testPlaybackJumpsTheQueue` | Play starts at once while two background downloads run and three queue |
| 19 | `testSavedStatesOutliveObsoleteFirmware` | a save outlives its build's file, is not copied forward, and the note is recorded |
| 20 | `testTornRegistryWriteRecovers` | a half-written registry recovers from the backup with every file kept |
| | `testUnsafeCatalogueEntriesAreRefused` | `..`, absolute and foreign-host paths and bad ids are dropped and never fetched |
| | `testBadOrEmptyCatalogueNeverReplacesTheGoodOne` | broken, empty and wrong-schema catalogues change nothing |
| | `testSchedulerPassesSlotsInOrderAndPromotes` | the two-slot queue, interactive bypass and promotion |

## Limitations and not yet done

- **Not yet tried on a real Mac.** All of this is tested on GitHub's Mac runner against a fake site plus one live
  catalogue check; first-launch download of the full live library (about 95 firmwares) has not been watched on your
  Mac.
- No user interface yet for imports, favourites, withdrawn firmware, storage use, or the "try previous settings"
  offer (later milestones). The storage for each is in place.
- Downloads are whole-file (firmware is 0.2 to 3 MB); an interrupted transfer starts again rather than resuming.
- Screenshots have no published checksum, so they are only checked for being a PNG or JPEG.
- A rebuild of the same firmware gets a new screenshot name from Pocket, so the screenshot is downloaded again even
  if the picture did not change. The old copy is cleaned up once no kept build uses it.
- Saves written by the Milestone 1 build (keyed by version only) are kept but not loaded automatically, because
  they cannot be tied to an exact build.
