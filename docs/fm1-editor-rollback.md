# FM1 Editor rollback preparation

This branch reverts the PR #11 merge `b7160bd95284fec730e95e38deef17fcce7f671e`. Editor credits, descriptions, links, notices, listed-only favourites, Editor ID aliases and expanded-catalogue UI/CI fixtures are removed. It does not change the published catalogue or user storage paths.

The following independent changes are retained in separate commits because they affect the existing 285-entry Hub/RemoteFM1FW flow:

| Original change | Existing-catalogue example | Retained scope |
| --- | --- | --- |
| `52cbf2d` diagnostics | AMB-1 has both an original package and an RFM1 build. Its non-preferred engine is deliberately skipped, not a failed download. NOIZ DEMONS previously exposed a maker/Hub hash mismatch needing a named failure report. | Detailed live-preflight failure/skip/missing reports, logs and summary script; no Editor fixture or expanded-catalogue preflight. |
| `903ac8b` shared-package installation | Argo and Felucca 8 Patterns share SHA-256 `89dc21f01e99cb03d50aeb3f5f51141f028d349174dd79fcf4e246ed28957734`, but need separate files and registry entries. | Installation keyed by firmware ID plus hash, including separate playback/offline records and failure handling. |
| `0fe35a2` missing-install assertion | A skipped registry/file for Argo or Felucca 8 must be reported, even if over 100 other packages installed successfully. | Fail preflight for an unexplained missing installation. Correction preparation documents are not reintroduced. |
| `c767083` scheduling check | A user choosing an existing queued firmware during the normal background sync must get priority. Task arrival order is not guaranteed. | Exercise an actually queued item instead of assuming fixed arrival order. No scheduler or playback engine change. |

The additional Editor-specific fallback tests, UI snapshot machinery and fixtures are not retained. The version remains 0.9.1 **unreleased**, with aligned local/CI build defaults and notes describing only the retained work.

Do not merge, close other PRs, delete branches, pause publishing, create a tag, publish a release or deploy as part of preparing this branch. Before a separately approved merge session, briefly pause publishing, merge, verify the unchanged catalogue, then ask to resume the normal two-source nightly in that same session. Stored Editor snapshot deletion is separately approved and handled in the Player/archive workflow.
