import XCTest
@testable import FM1Pocket
@testable import PocketKit

/// The library's items and footer count firmwares, not files: a firmware with an .rfm1 build and an original
/// package is one item and one count, and a package whose emu entry went away while its build is still listed is not
/// "No Longer Listed".
@MainActor
final class LibraryCountsTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)

    private func entry(_ id: String, installed: Bool, prefer: String? = nil) -> FirmwareLibrary.Entry {
        let e = CatalogueEntry(id: id, name: id.capitalized, version: "1", license: "MIT", file: "fw/\(id).rfm1", sha256: sha, size: 1)
        let b = InstalledBuild(id: id, name: id, version: "1", sha256: sha, file: "f", size: 1, installedAt: Date(), origin: .catalogue)
        return FirmwareLibrary.Entry(entry: e, availability: installed ? .installed : .notDownloaded, downloading: false,
                                     lastError: nil, current: installed ? b : nil, previous: nil, screenshotFile: nil, mac: nil,
                                     preferredEngine: prefer)
    }
    private func withdrawn(_ id: String) -> FirmwareRecord {
        let e = CatalogueEntry(id: id, name: id.capitalized, version: "1", license: "MIT", file: "fw/\(id).rfm1", sha256: sha, size: 1)
        let b = InstalledBuild(id: id, name: id, version: "1", sha256: sha, file: "f", size: 1, installedAt: Date(), origin: .catalogue)
        return FirmwareRecord(id: id, builds: [b], status: .withdrawn, entry: e)
    }

    func testOneItemAndOneCountPerFirmware() {
        let snap = FirmwareLibrary.Snapshot(
            entries: [entry("alpha", installed: false, prefer: "fm1-emu"), entry("alpha.fwsc", installed: true, prefer: "fm1-emu"),
                      entry("beta", installed: false), entry("gamma.fwsc", installed: true, prefer: "fm1-emu")],
            withdrawn: [withdrawn("beta.fwsc"), withdrawn("delta"), withdrawn("delta.fwsc")],
            imports: [], catalogueUpdated: nil, catalogueSince: nil, registryLoad: .loaded)
        let m = LibraryModel.merged(snap, choices: [:], base: URL(string: "https://example.test/")!, paths: LibraryPaths(root: FileManager.default.temporaryDirectory),
                                    builtin: nil)
        XCTAssertEqual(m.items.map(\.id), ["cat:alpha", "cat:beta", "cat:gamma"])
        XCTAssertEqual(m.items[0].engine, "fm1-emu")
        XCTAssertEqual(m.items[0].engines, ["rfm1", "fm1-emu"])
        XCTAssertEqual(m.withdrawn.map(\.id), ["cat:delta"], "beta is still listed; delta's two files are one firmware")
        XCTAssertEqual(m.withdrawn.first?.engine, "rfm1")
        let c = LibraryCounts(items: m.items, more: [], withdrawn: m.withdrawn)
        XCTAssertEqual(c.library, 3)
        XCTAssertEqual(c.readyOffline, 2, "alpha (its package is downloaded and chosen) and gamma; beta is not downloaded")
        XCTAssertEqual(c.withdrawn, 1)
        XCTAssertEqual(c.line, "3 firmwares in the library · 2 ready offline · 1 no longer listed")
        // choosing alpha's .rfm1 build: still one item, now not ready offline
        let r = LibraryModel.merged(snap, choices: ["alpha": "rfm1"], base: URL(string: "https://example.test/")!,
                                    paths: LibraryPaths(root: FileManager.default.temporaryDirectory), builtin: nil)
        XCTAssertEqual(r.items.count, 3)
        XCTAssertEqual(LibraryCounts(items: r.items, more: [], withdrawn: []).readyOffline, 1)
        XCTAssertEqual(LibraryCounts.baseID("alpha.fwsc"), "alpha")
        // confidence is counted on each firmware's chosen engine, never upgraded from automated to listened
        var items = m.items
        items[0].confidence = CatalogueV2.Confidence(level: .listened)
        items[1].confidence = CatalogueV2.Confidence(level: .knownIssue, note: "x")
        XCTAssertEqual(LibraryCounts.confidenceLine(items), "Listened to: 1 · automated checks only: 1 · known issues: 1")
        XCTAssertEqual(items[2].compatibilityText, "Plays · automated checks only")
        XCTAssertEqual(items[0].compatibilityText, "Plays · listened to in FM-1 Pocket")
        XCTAssertEqual(items[1].compatibilityText, "Known issue: x")
        var exp = items[2]
        exp.macState = .experimental
        XCTAssertEqual(exp.compatibilityText, "May not work fully · automated checks only")
        exp.confidence = CatalogueV2.Confidence(level: .listened)
        XCTAssertEqual(exp.compatibilityText, "Plays · listened to in FM-1 Pocket", "a person's listening is not contradicted by the automated flag")
        for i in items { XCTAssertFalse(i.compatibilityText.contains("this Mac"), "never about the user's own Mac") }
    }

    /// Latest Release: newest release first, unknown release dates last; A–Z by name; New to Library from the listed day.
    func testSortByLatestReleaseAndNewToLibrary() {
        var a = entry("alpha", installed: true), b = entry("beta", installed: true), c = entry("gamma", installed: true)
        a.release = CatalogueV2.Release(version: "1", date: "2026-10-01T00:00:00Z")
        b.release = CatalogueV2.Release(version: "1", date: "2026-11-13T00:00:00Z")
        a.listed = "2020-01-01"
        b.listed = ISO8601DateFormatter().string(from: Date()).prefix(10).description
        let snap = FirmwareLibrary.Snapshot(entries: [a, b, c], withdrawn: [], imports: [], catalogueUpdated: nil, catalogueSince: nil, registryLoad: .loaded)
        let items = LibraryModel.merged(snap, choices: [:], base: URL(string: "https://example.test/")!,
                                        paths: LibraryPaths(root: FileManager.default.temporaryDirectory), builtin: nil).items
        XCTAssertEqual(LibraryModel.ordered(items, by: .latestRelease).map(\.name), ["Beta", "Alpha", "Gamma"])
        XCTAssertEqual(LibraryModel.ordered(items, by: .name).map(\.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(items.filter(\.isNew).map(\.name), ["Beta"], "listed today; alpha's release is recent but it is not new to the library")
        XCTAssertEqual(SortKey(rawValue: "added"), nil, "the old Date Added sort is gone (it falls back to Latest Release)")
    }
}
