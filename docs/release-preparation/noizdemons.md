# NOIZ DEMONS catalogue correction prepared for review

Prepared on 2026-11-22 for FM-1 Pocket 0.9.1. This is an unpublished catalogue correction, not an app-side checksum override. No Player branch, published catalogue, release asset or deployment has been changed.

## What changed upstream

The maker replaced `noiz_demons.fwsc` under the existing `v666` release tag. Its release notes now describe **v666.1, VENOM by default**. The replacement asset was created on 2026-11-21 at 11:09:18 UTC. Pocket's saved Hub catalogue was fetched earlier that day, at 06:20:23.837 UTC.

| Evidence | SHA-256 |
| --- | --- |
| Saved Hub record and published Pocket catalogue | `b1c14859d45bd8ea1d5ea6ca630083e2a647178f1a45b33865e92da7a01e9b8a` |
| Fresh maker download and GitHub release asset digest | `c5607f06ff33288c92be1ba24a226d9c7b4ab1643aa82ecc994462ff036cc35a` |
| Maker's tracked `build/felucca.fwsc` at commit `09dc080da7a26c81c69f70ba2c7094e0a06ac12a` | `c5607f06ff33288c92be1ba24a226d9c7b4ab1643aa82ecc994462ff036cc35a` |

Both packages are recorded as 610,086 bytes. Equal size and an unchanged URL do not mean equal contents. A fresh download matched the maker's tracked binary byte for byte. The maker's commit describes the palette change; this explains the replacement, but does not establish that the new package passed Pocket's checks.

Sources: [maker release](https://github.com/SPIKE-the-Percussionist/noiz_demons/releases/tag/v666), [maker change](https://github.com/SPIKE-the-Percussionist/noiz_demons/commit/09dc080da7a26c81c69f70ba2c7094e0a06ac12a), [saved Hub catalogue](https://github.com/slowphase/fm1-pocket-player/releases/download/pocket-current/hub-catalog.json), [cached package manifest](https://github.com/slowphase/fm1-pocket-player/releases/download/pocket-packages/packages.json).

## Prepared correction

Pocket's existing `pocket/emu/packages.mjs` requires the maker's package to match the Hub checksum. Its incremental path reused the cached old package (`reused: true`), so the published catalogue still advertises bytes the maker's URL no longer serves. The Mac correctly rejects the replacement.

[noizdemons-package-correction.json](noizdemons-package-correction.json) is a replacement for **only the `noizdemons` row** in the cached packages manifest while this mismatch persists. It changes the row's status from `found` to `maker's packages differ from the Hub's SHA-256`, records the mismatched asset, and removes `reused`. The old checksum remains as the expected Hub checksum, not as permission to accept the replacement.

The existing `pocket/emu/catalog.py` was exercised with this corrected row and NOIZ DEMONS' published catalogue entry. The generated candidate:

- removes the downloadable emulator package;
- marks both Mac and web emulator status `unavailable`, with the mismatch reason;
- removes obsolete emulator confidence and preference;
- preserves the firmware id and its existing `.rfm1` status.

These properties were checked after running the generator. The app will show NOIZ DEMONS as a listing instead of repeatedly attempting an impossible checksum-checked download. Other firmware rows are outside this correction.

## Applying it later, after approval

1. Follow the normal Hub refresh schedule and re-evaluate the maker's package. Do not increase the Hub fetch frequency. The investigation reused Pocket's saved Hub catalogue.
2. If the current Hub checksum still differs from the maker's download, use the prepared row only after confirming the current `noizdemons` row still has the old checksum above and status `found`. Rebuild the catalogue through the existing generator and validation pipeline. Do not publish this single-row JSON as a complete catalogue.
3. If the refreshed Hub record matches the replacement, discard this temporary-unavailable correction. Fetch the replacement through `packages.mjs`, measure that exact checksum through the normal emulator checks, and regenerate its status and confidence from those results. Do not transfer the old package's test or listening records to the new bytes.
4. Review the staged catalogue diff, including NOIZ DEMONS' package, status, preference and confidence. Obtain approval before any catalogue deployment or release-asset update.

Publishing a catalogue correction is separate from merging or releasing the Mac app. Player PRs #17 and #18 remain untouched.
