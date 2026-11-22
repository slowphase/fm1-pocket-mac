#!/usr/bin/env python3
"""Show preflight diagnostics without changing the preflight's pass/fail policy."""
import json
import sys


def cell(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace("|", "&#124;").replace("\r", " ").replace("\n", " ")


for path in sys.argv[1:]:
    with open(path) as source:
        p = json.load(source)
    print(f"## Preflight: {cell(path)}\n")
    print(f"Feed {cell(p['feed'])}: {p['entries']} library entries. Original packages: "
          f"{p['packages']} total, {p['packagesDownloaded']} installed and checked, "
          f"{p['packagesSkipped']} intentionally skipped alternatives, {p['failedPackageDownloads']} failed.\n")
    print(f"All engines: {p['failedDownloads']} failed downloads. "
          "Alternative engines are downloaded only when chosen.\n")
    for title, key, reason in (("Download failures", "downloadFailures", "error"),
                               ("Intentionally skipped alternatives", "skippedAlternatives", "reason"),
                               ("Other entries not installed (investigate)", "notDownloaded", None)):
        rows = p[key]
        print(f"### {title}: {len(rows)}\n")
        if not rows:
            continue
        print("| ID | Firmware | Kind | Preferred engine | URL | Detail |")
        print("| --- | --- | --- | --- | --- | --- |")
        for row in rows:
            values = [row.get(k, "") for k in ("id", "name", "kind", "preferredEngine", "url")]
            values.append(row.get(reason, "") if reason else "Not installed and not reported as failed or intentionally skipped.")
            print("| " + " | ".join(map(cell, values)) + " |")
        print()
