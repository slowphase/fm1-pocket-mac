import XCTest
@testable import PocketKit

/// Release preflight (FM1_PREFLIGHT=DIR): the library exactly as a release build runs it, with no emu-preview.json,
/// against the live catalogue. It must find original packages, prefer the emulator for most of them and download
/// them (SHA-256 checked). It writes DIR/preflight.json with the counts and a few downloaded packages for the
/// packaged app to play (`--selftest-fwsc`).
final class PreflightTests: XCTestCase {
    func testProductionLibraryFindsAndDownloadsOriginalPackages() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FM1_PREFLIGHT"] else {
            throw XCTSkip("set FM1_PREFLIGHT=DIR for the release preflight")
        }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let paths = LibraryPaths(root: root.appendingPathComponent("library", isDirectory: true))
        // FM1_PREFLIGHT_BASE: another catalogue folder or site (the expanded catalogue in CI); the live site otherwise
        let base = ProcessInfo.processInfo.environment["FM1_PREFLIGHT_BASE"].map { $0.hasPrefix("http") ? URL(string: $0)! : URL(fileURLWithPath: $0, isDirectory: true) }
        let lib = FirmwareLibrary(paths: paths, base: base ?? CatalogueService.defaultBase, emuPreview: nil)
        let r = await lib.sync()
        XCTAssertNil(r.catalogueError, "the live catalogue could not be read")
        let snap = await lib.snapshot()
        let packages = snap.entries.filter { $0.entry.isPackage }
        let installed = packages.filter { $0.availability == .installed }
        let preferEmu = packages.filter { $0.preferredEngine == "fm1-emu" }
        let playable = installed.filter { $0.preferredEngine == "fm1-emu" && $0.emu?.mac.state == .playable }
        let pick = Array(playable.sorted { $0.entry.size < $1.entry.size }.prefix(5))
        let discovery = await lib.discovery
        // A fresh preflight skips an alternative engine until the user chooses it. Do not call that a failure.
        let skipped = snap.entries.filter {
            $0.availability != .installed && $0.current == nil && r.failed[$0.entry.id] == nil
                && discovery?.alternative(for: $0.entry.id) == true
        }
        let skippedIDs = Set(skipped.map { $0.entry.id })
        let pending = snap.entries.filter {
            $0.availability != .installed && r.failed[$0.entry.id] == nil && !skippedIDs.contains($0.entry.id)
        }
        func detail(_ item: FirmwareLibrary.Entry) -> [String: String] {
            let e = item.entry
            return ["id": e.id, "name": e.name, "kind": e.isPackage ? "package" : "rfm1",
                    "url": e.remoteURL ?? (base ?? CatalogueService.defaultBase).appendingPathComponent(e.file).absoluteString,
                    "preferredEngine": item.preferredEngine ?? "?"]
        }
        let failures = r.failed.keys.sorted().map { id -> [String: String] in
            var row = snap.entries.first(where: { $0.entry.id == id }).map(detail) ?? ["id": id]
            row["error"] = r.failed[id]
            return row
        }
        let summary: [String: Any] = [
            "feed": r.feed ?? "?", "entries": snap.entries.count, "packages": packages.count,
            "packagesDownloaded": installed.count, "preferEmulator": preferEmu.count,
            "failedDownloads": r.failed.count,
            "failedPackageDownloads": packages.filter { r.failed[$0.entry.id] != nil }.count,
            "downloadFailures": failures,
            "packagesSkipped": skipped.filter { $0.entry.isPackage }.count,
            "skippedAlternatives": skipped.map { item -> [String: String] in
                var row = detail(item)
                row["reason"] = "Alternative engine; downloaded only when chosen."
                return row
            }.sorted { $0["id"]! < $1["id"]! },
            "notDownloaded": pending.map(detail).sorted { $0["id"]! < $1["id"]! },
            "play": pick.map { ["id": $0.entry.id, "name": $0.entry.name,
                                "file": paths.firmwareFile(id: $0.entry.id, sha256: $0.entry.sha256).path] }
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("preflight.json"))
        XCTAssertEqual(r.feed, "v2", "a release reads catalog-v2.json")
        XCTAssertGreaterThan(packages.count, 100, "original packages in the live catalogue")
        XCTAssertGreaterThan(preferEmu.count, 100, "the emulator preferred for most of them")
        XCTAssertGreaterThan(installed.count, 100, "original packages downloaded and checked")
        XCTAssertEqual(pick.count, 5)
    }
}
