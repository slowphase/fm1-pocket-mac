# Qualified library visibility — preparation only

This branch prepares option B: hide listing-only and experimental-only entries.
Keep the complete catalogue, permanent IDs, attribution, registry, downloads,
favourites and saves. Built-in firmware and user imports are unaffected.

Each engine is filtered separately before the library combines the alternatives.
An old saved engine preference cannot select an unqualified alternative. Hidden
records do not reappear in More Firmware or No Longer Listed. No record is deleted
or marked withdrawn merely because its view is hidden.

The report-only Player branch supplies additive `qualification.mac` decisions for
all internal records. An exact last-good original package carries its own package
fingerprint and test status; the app consumes that package rather than substituting
the failed update. Unknown or malformed qualification decisions fail closed.
The Mac consumer verifies the selected package fingerprint matches the decision.

For an older v2 feed without decisions, only explicit playable states without known
issues/restrictions are displayed. This compatibility path does not replace the
production qualification gate. A legacy v1 feed has no per-platform verification;
the app retains it internally but does not infer a passing library view from it.

The automated policy, five audit safeguards, frozen existing web-delivery list and
report job are prepared in fm1-pocket-player's `qualification/report-only` branch.
The RemoteFM1FW approval policy and existing engine pins are unchanged.

This branch does not change a version, workflow, engine, release setting or published
catalogue. Before any production rollout, approve the qualification stage in sync
and verify the feed/client combination. App publication remains separately forbidden.

`Tests/qualification-preview.swift`, compiled alongside the actual `LibraryModel`,
checks that the real Mac snapshot/selection agrees with the report, preserves all
internal records, keeps stored favourites and hides SLOOP/Araminta/SHIFL. The normal
unit suite also covers malformed decisions, fingerprint binding, missing original
packages, alternative engines and hidden installed records.
