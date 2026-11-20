import Foundation
import XCTest
@testable import PocketKit

final class BrowsingTests: XCTestCase {
    private func root() -> LibraryPaths {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fm1browse-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return LibraryPaths(root: u)
    }

    func testSearchMatchesLikePocket() {
        let ksub = ["K-WA SUB", "1.0", "Someone", "A sub bass machine", "bass", "Synth"]
        XCTAssertTrue(LibrarySearch.matches("kwa", fields: ksub), "punctuation is ignored")
        XCTAssertTrue(LibrarySearch.matches("K-WA", fields: ksub))
        XCTAssertTrue(LibrarySearch.matches("sub bass", fields: ksub), "every word must match")
        XCTAssertFalse(LibrarySearch.matches("sub drums", fields: ksub))
        XCTAssertTrue(LibrarySearch.matches("", fields: ksub))
        XCTAssertTrue(LibrarySearch.matches("fm1", fields: ["FM-1 SID"]))
        XCTAssertTrue(LibrarySearch.matches("synth", fields: ksub), "categories are searched")
        XCTAssertFalse(LibrarySearch.matches("grimm", fields: ksub))
        XCTAssertTrue(LibrarySearch.matches("grimm", fields: ["GR!MM"]))
    }

    func testNamesThatMatchComeFirst() {
        XCTAssertEqual(LibrarySearch.rank(name: "SLOOP", query: "sl"), 0)
        XCTAssertEqual(LibrarySearch.rank(name: "Felucca Sloop", query: "sloop"), 1)
        XCTAssertEqual(LibrarySearch.rank(name: "AMB-1", query: "ambient"), 2)
    }

    func testNewBadge() {
        let now = NewBadge.date("2026-11-20")!
        XCTAssertTrue(NewBadge.isNew(added: "2026-11-19", since: "2026-11-01", now: now))
        XCTAssertTrue(NewBadge.isNew(added: "2026-11-06", since: "2026-11-01", now: now), "14 days is still new")
        XCTAssertFalse(NewBadge.isNew(added: "2026-11-05", since: "2026-11-01", now: now), "15 days is not")
        XCTAssertFalse(NewBadge.isNew(added: "2026-11-01", since: "2026-11-01", now: now), "part of the first catalogue")
        XCTAssertFalse(NewBadge.isNew(added: nil, since: "2026-11-01", now: now))
        XCTAssertFalse(NewBadge.isNew(added: "2026-11-19", since: nil, now: now))
    }

    func testRecentlyPlayedKeepsTheNewest() throws {
        let store = RecentStore(paths: root())
        XCTAssertEqual(store.load(), [:])
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<30 { try store.note("fw\(i)", at: t0.addingTimeInterval(Double(i))) }
        try store.note("fw3", at: t0.addingTimeInterval(100))
        let r = store.load()
        XCTAssertEqual(r.count, RecentStore.limit)
        XCTAssertNotNil(r["fw3"], "playing again brings it back")
        XCTAssertNotNil(r["fw29"])
        XCTAssertNil(r["fw5"], "the oldest drop off")
    }

    func testFavouritesPersist() throws {
        let paths = root()
        try FavouritesStore(paths: paths).save(["cat:amb", "builtin:h1"])
        XCTAssertEqual(FavouritesStore(paths: paths).load(), ["cat:amb", "builtin:h1"])
    }

    /// h1 has no catalogue screenshot, so the app makes one natively, as Pocket's pipeline does (six seconds in).
    func testScreenshotMakerDrawsH1() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/h1.rfm1"))
        let paths = root()
        let url = try XCTUnwrap(ScreenshotMaker.cachedScreenshot(for: bytes, paths: paths))
        let png = try Data(contentsOf: url)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4e, 0x47], "a PNG")
        XCTAssertGreaterThan(png.count, 500)
        XCTAssertTrue(LibraryPaths.isInside(url, paths.generated))
        let start = Date()
        XCTAssertEqual(ScreenshotMaker.cachedScreenshot(for: bytes, paths: paths), url)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "the second time it is read from the cache")
        // cleanup never touches generated screenshots
        let plan = CleanupPlanner.plan(registry: Registry(), catalogue: nil, paths: paths, active: [])
        XCTAssertFalse(plan.contains { LibraryPaths.isInside($0.url, paths.generated) })
        XCTAssertNil(ScreenshotMaker.png(for: Data("not firmware".utf8)))
    }
}
