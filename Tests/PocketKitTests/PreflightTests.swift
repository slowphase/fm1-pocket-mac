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
        let lib = FirmwareLibrary(paths: paths, emuPreview: nil)
        let r = await lib.sync()
        XCTAssertNil(r.catalogueError, "the live catalogue could not be read")
        let snap = await lib.snapshot()
        let packages = snap.entries.filter { $0.entry.isPackage }
        let installed = packages.filter { $0.availability == .installed }
        let preferEmu = packages.filter { $0.preferredEngine == "fm1-emu" }
        let playable = installed.filter { $0.preferredEngine == "fm1-emu" && $0.emu?.mac.state == .playable }
        let pick = Array(playable.sorted { $0.entry.size < $1.entry.size }.prefix(5))
        let summary: [String: Any] = [
            "feed": r.feed ?? "?", "entries": snap.entries.count, "packages": packages.count,
            "packagesDownloaded": installed.count, "preferEmulator": preferEmu.count,
            "failedDownloads": r.failed.count,
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
