import Foundation
import XCTest
@testable import PocketKit

// MARK: - A fake Pocket site

/// Serves a catalogue, firmware and screenshots from memory, records every request, and can hold, fail or corrupt
/// individual paths, so the sync tests never touch the network.
actor FakePocket: HTTPFetching {
    private(set) var files: [String: Data] = [:]
    private(set) var requests: [String] = []
    private var failing: Set<String> = []
    private var held: Set<String> = []
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    var offline = false

    func fetch(_ url: URL) async throws -> (Data, Int) {
        let path = url.path
        requests.append(path)
        if offline { throw URLError(.notConnectedToInternet) }
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if held.contains(path) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in gates[path, default: []].append(c) }
        }
        inFlight -= 1
        if failing.contains(path) { throw URLError(.networkConnectionLost) }
        guard let d = files[path] else { return (Data(), 404) }
        return (d, 200)
    }

    func set(_ path: String, _ data: Data?) { files[path] = data }
    func fail(_ path: String) { failing.insert(path) }
    func unfail(_ path: String) { failing.remove(path) }
    func hold(_ path: String) { held.insert(path) }
    func release(_ path: String) {
        held.remove(path)
        for c in gates.removeValue(forKey: path) ?? [] { c.resume() }
    }
    func releaseAll() { for p in held { release(p) } }
    func setOffline(_ v: Bool) { offline = v }
    func clearLog() { requests = []; maxInFlight = 0 }
    func count(_ path: String) -> Int { requests.filter { $0 == path }.count }
    func waiting(_ path: String) -> Bool { !(gates[path] ?? []).isEmpty }
}

private let base = URL(string: "https://pocket.test/data/")!
private let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data("fake screenshot".utf8)

/// One firmware as the fake site publishes it.
private struct FW {
    var id: String
    var version: String
    var data: Data
    var image: Data?
    init(_ id: String, _ version: String, salt: String = "", image: Data? = png) {
        self.id = id; self.version = version
        self.data = Data("\(id) \(version) \(salt) firmware bytes".utf8)
        self.image = image.map { $0 + Data("\(id) \(version) \(salt)".utf8) }
    }
    var sha: String { sha256Hex(data) }
    var file: String { "fw/\(id)-\(sha.prefix(8)).rfm1" }
    var imagePath: String? { image == nil ? nil : "shots/\(id)-\(sha.prefix(8)).png" }
    var entry: CatalogueEntry {
        CatalogueEntry(id: id, name: id.uppercased(), version: version, authors: ["Someone"], license: "MIT", file: file,
                       sha256: sha, size: data.count, image: imagePath)
    }
}

private func catalogueJSON(_ fws: [FW]) -> Data {
    let c = Catalogue(schema: 1, updated: "2026-11-20T00:00:00Z", since: nil, count: fws.count, firmwares: fws.map(\.entry))
    return try! JSONEncoder().encode(c)
}

/// Publishes these firmware (and only them) in the catalogue; their files are added to the site.
private func publish(_ fws: [FW], on site: FakePocket) async {
    for f in fws {
        await site.set("/data/" + f.file, f.data)
        if let p = f.imagePath { await site.set("/data/" + p, f.image) }
    }
    await site.set("/data/catalog.json", catalogueJSON(fws))
}

/// An expanded catalogue (schema 2) for these firmware: `downloadable` ones carry their catalog.json fields and the
/// given Mac state; `listed` ones have no build (source-only) or a build the Mac must not download (unsupported).
private func catalogueV2JSON(_ fws: [(FW, String)], listed: [(String, String, FW?)] = [], hub: Bool = false) -> Data {
    var list: [[String: Any]] = []
    for (f, mac) in fws {
        var e = (try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(f.entry))) as! [String: Any]
        e["makers"] = [["name": "Someone", "url": "https://example.test/\(f.id)"]]
        e["status"] = ["web": ["state": "playable"], "mac": ["state": mac, "reason": mac == "experimental" ? "Not yet tested on macOS." : NSNull()]]
        list.append(e)
    }
    for (id, mac, build) in listed {
        var e: [String: Any] = ["id": id, "name": id.uppercased(), "version": "1", "authors": ["Maker"], "license": "GPL-3.0",
                                "source": "https://example.test/\(id)", "category": "Synth",
                                "status": ["web": ["state": mac], "mac": ["state": mac, "reason": "Why \(id) is not here."]],
                                "restriction": ["code": "no-build", "reason": "No browser build has been published."]]
        if hub { e["provenance"] = ["hub": ["url": "https://thefirmwarehub.com/firmware/\(id)"]] }
        if let b = build { e["file"] = b.file; e["sha256"] = b.sha; e["size"] = b.data.count }
        list.append(e)
    }
    var c: [String: Any] = ["schema": 2, "snapshot": "2026-11-20T00:00:00Z", "updated": "2026-11-20T00:00:00Z", "firmwares": list]
    if hub {
        c["attribution"] = ["text": "Firmware list: The Firmware Hub – thefirmwarehub.com", "url": "https://thefirmwarehub.com",
                            "license": "CC BY 4.0", "licenseUrl": "https://creativecommons.org/licenses/by/4.0/"]
    }
    return try! JSONSerialization.data(withJSONObject: c)
}

private func freshRoot() -> LibraryPaths {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("fm1lib-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return LibraryPaths(root: u)
}

private func eventually(_ seconds: Double = 5, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await cond()
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
private func h1Fixture() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/h1.rfm1"))
}

// MARK: - Tests

final class LibrarySyncTests: XCTestCase {
    private func library(_ paths: LibraryPaths, _ site: FakePocket, limit: Int = 2) -> FirmwareLibrary {
        FirmwareLibrary(paths: paths, base: base, fetcher: site, scheduler: DownloadScheduler(limit: limit))
    }

    // 1
    func testInitialFullSync() async throws {
        let site = FakePocket(), paths = freshRoot()
        let fws = [FW("alpha", "1.0"), FW("beta", "2.1"), FW("gamma", "0.3", image: nil)]
        await publish(fws, on: site)
        let lib = library(paths, site)
        XCTAssertEqual(lib.registryLoad, .fresh)
        let r = await lib.sync()
        XCTAssertNil(r.catalogueError)
        XCTAssertEqual(r.installed, ["alpha", "beta", "gamma"])
        XCTAssertEqual(r.screenshotsDownloaded, 2)
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries.map(\.availability), [.installed, .installed, .installed])
        XCTAssertNotNil(snap.entries[0].screenshotFile)
        XCTAssertNil(snap.entries[2].screenshotFile)
        for f in fws { XCTAssertEqual(try Data(contentsOf: paths.firmwareFile(id: f.id, sha256: f.sha)), f.data) }
        XCTAssertTrue(exists(paths.catalogue))
        XCTAssertTrue(exists(paths.registry))
        let maxInFlight = await site.maxInFlight
        XCTAssertLessThanOrEqual(maxInFlight, 2, "background downloads are limited to two at a time")
    }

    // 2
    func testRelaunchWithNoChangesDownloadsNothing() async throws {
        let site = FakePocket(), paths = freshRoot()
        await publish([FW("alpha", "1.0"), FW("beta", "2.1")], on: site)
        _ = await library(paths, site).sync()
        await site.clearLog()
        let again = library(paths, site)
        XCTAssertEqual(again.registryLoad, .loaded)
        let r = await again.sync()
        XCTAssertEqual(r.installed, [])
        let reqs = await site.requests
        XCTAssertEqual(reqs, ["/data/catalog-v2.json", "/data/catalog.json"],
                       "only the catalogue is fetched when nothing changed (v2 first, then v1 when the site has no v2)")
    }

    // 3
    func testOneUpdateDownloadsOnlyThatFirmware() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), b1 = FW("beta", "1.0")
        await publish([a, b1], on: site)
        let lib = library(paths, site)
        _ = await lib.sync()
        await site.clearLog()
        let b2 = FW("beta", "1.1")
        await publish([a, b2], on: site)
        let r = await lib.sync()
        XCTAssertEqual(r.installed, ["beta"])
        let reqs = await site.requests
        XCTAssertEqual(Set(reqs), Set(["/data/catalog-v2.json", "/data/catalog.json", "/data/" + b2.file, "/data/" + b2.imagePath!]))
    }

    // 4
    func testTwoVersionRetention() async throws {
        let site = FakePocket(), paths = freshRoot()
        let v1 = FW("sloop", "3.4"), v2 = FW("sloop", "3.5"), v3 = FW("sloop", "3.6")
        let lib = library(paths, site)
        await publish([v1], on: site); _ = await lib.sync()
        await publish([v2], on: site); _ = await lib.sync()
        var rec = await lib.registry.firmwares["sloop"]!
        XCTAssertEqual(rec.builds.map(\.version), ["3.5", "3.4"])
        XCTAssertTrue(exists(paths.firmwareFile(id: "sloop", sha256: v1.sha)), "previous kept after first update")
        await publish([v3], on: site)
        let r = await lib.sync()
        rec = await lib.registry.firmwares["sloop"]!
        XCTAssertEqual(rec.builds.map(\.version), ["3.6", "3.5"])
        XCTAssertTrue(exists(paths.firmwareFile(id: "sloop", sha256: v3.sha)))
        XCTAssertTrue(exists(paths.firmwareFile(id: "sloop", sha256: v2.sha)))
        XCTAssertFalse(exists(paths.firmwareFile(id: "sloop", sha256: v1.sha)), "the third-newest build is cleaned up")
        XCTAssertTrue(r.cleaned.contains { $0.reason == .superseded })
        XCTAssertFalse(exists(paths.screenshotFile(SafeName.lastComponent(v1.imagePath!))), "its screenshot goes too")
        XCTAssertTrue(exists(paths.screenshotFile(SafeName.lastComponent(v2.imagePath!))), "the previous build's screenshot stays")
    }

    // 5
    func testRebuildWithSameVersionIsADistinctBuild() async throws {
        let site = FakePocket(), paths = freshRoot()
        let first = FW("felucca", "1.8.2"), rebuilt = FW("felucca", "1.8.2", salt: "rebuilt")
        XCTAssertNotEqual(first.sha, rebuilt.sha)
        let lib = library(paths, site)
        await publish([first], on: site); _ = await lib.sync()
        await publish([rebuilt], on: site)
        let r = await lib.sync()
        XCTAssertEqual(r.installed, ["felucca"], "same version, new bytes: an update")
        let rec = await lib.registry.firmwares["felucca"]!
        XCTAssertEqual(rec.builds.map(\.sha256), [rebuilt.sha, first.sha])
        // saved settings for the two builds are kept apart
        let states = StateStore(folder: paths.state)
        try states.save(Data([1, 2, 3]), id: "felucca", version: "1.8.2", sha256: first.sha)
        XCTAssertNil(states.load(id: "felucca", version: "1.8.2", sha256: rebuilt.sha), "a rebuild never picks up another build's save")
        XCTAssertNotEqual(states.url(id: "felucca", version: "1.8.2", sha256: first.sha),
                          states.url(id: "felucca", version: "1.8.2", sha256: rebuilt.sha))
        // republishing identical bytes is not an update
        await site.clearLog()
        await publish([rebuilt], on: site)
        let again = await lib.sync()
        XCTAssertEqual(again.installed, [])
    }

    // 6
    func testFailedDownloadKeepsLastGoodVersion() async throws {
        let site = FakePocket(), paths = freshRoot()
        let v1 = FW("amb", "1.3.1"), v2 = FW("amb", "1.3.2")
        let lib = library(paths, site)
        await publish([v1], on: site); _ = await lib.sync()
        await publish([v2], on: site)
        await site.fail("/data/" + v2.file)
        let r = await lib.sync()
        XCTAssertNotNil(r.failed["amb"])
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries[0].availability, .olderInstalled)
        XCTAssertNotNil(snap.entries[0].lastError)
        XCTAssertEqual(try Data(contentsOf: paths.firmwareFile(id: "amb", sha256: v1.sha)), v1.data)
        let play = try await lib.firmwareForPlayback(id: "amb")
        XCTAssertTrue(play.isFallback)
        XCTAssertEqual(play.data, v1.data, "the last good version still plays")
        await site.unfail("/data/" + v2.file)
        let fixed = await lib.sync()
        XCTAssertEqual(fixed.installed, ["amb"])
        let after = await lib.snapshot()
        XCTAssertNil(after.entries[0].lastError)
    }

    // 7
    func testWrongChecksumIsNeverInstalled() async throws {
        let site = FakePocket(), paths = freshRoot()
        let f = FW("grimm", "2.0.2")
        await publish([f], on: site)
        await site.set("/data/" + f.file, Data("tampered".utf8))
        let lib = library(paths, site)
        let r = await lib.sync()
        XCTAssertNotNil(r.failed["grimm"])
        XCTAssertFalse(exists(paths.firmwareFile(id: "grimm", sha256: f.sha)))
        XCTAssertEqual(LibrarySyncTests.files(paths.tmp), [], "the bad download is not left behind")
        let rec = await lib.registry.firmwares["grimm"]
        XCTAssertEqual(rec?.builds ?? [], [])
        do { _ = try await lib.firmwareForPlayback(id: "grimm"); XCTFail("must not play unverified bytes") }
        catch { XCTAssertEqual(error as? PocketError, .checksumMismatch("GRIMM")) }
    }

    // 8
    func testInterruptedSyncRecovers() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), b = FW("beta", "1.0")
        await publish([a, b], on: site)
        // a crash part-way through: beta finished installing, alpha was written to its place but never recorded,
        // and a half-written download was left in tmp
        let first = library(paths, site)
        await site.fail("/data/" + a.file)
        _ = await first.sync()
        try FileManager.default.createDirectory(at: paths.firmwareFile(id: "alpha", sha256: a.sha).deletingLastPathComponent(), withIntermediateDirectories: true)
        try a.data.write(to: paths.firmwareFile(id: "alpha", sha256: a.sha))
        try Data("partial".utf8).write(to: paths.tmp.appendingPathComponent("\(a.sha).download"))
        await site.unfail("/data/" + a.file)
        await site.clearLog()
        let relaunched = library(paths, site)
        let snapBefore = await relaunched.snapshot()
        XCTAssertEqual(snapBefore.entries.first { $0.entry.id == "beta" }?.availability, .installed, "the finished install survived")
        let r = await relaunched.sync()
        XCTAssertEqual(r.installed, ["alpha"])
        let n = await site.count("/data/" + a.file)
        XCTAssertEqual(n, 0, "the verified file left behind is adopted, not downloaded again")
        XCTAssertTrue(r.cleaned.contains { $0.reason == .temporary }, "the abandoned partial download is removed")
        XCTAssertEqual(LibrarySyncTests.files(paths.tmp), [])
    }

    // 9
    func testOfflineStartupWithFullCache() async throws {
        let site = FakePocket(), paths = freshRoot()
        let fws = [FW("alpha", "1.0"), FW("beta", "2.0")]
        await publish(fws, on: site)
        _ = await library(paths, site).sync()
        await site.setOffline(true)
        let offline = library(paths, site)
        let before = await offline.snapshot()
        XCTAssertEqual(before.entries.count, 2, "the cached catalogue shows at once")
        XCTAssertEqual(before.entries.map(\.availability), [.installed, .installed])
        XCTAssertEqual(before.entries[0].entry.authors, ["Someone"])
        XCTAssertEqual(before.entries[0].entry.license, "MIT")
        XCTAssertNotNil(before.entries[0].screenshotFile, "screenshots work offline")
        let r = await offline.sync()
        XCTAssertNotNil(r.catalogueError)
        XCTAssertEqual(r.cleaned, [], "no cleanup without a good catalogue")
        let play = try await offline.firmwareForPlayback(id: "beta")
        XCTAssertEqual(play.data, fws[1].data)
        XCTAssertFalse(play.isFallback)
    }

    // 10
    func testOfflineStartupWithIncompleteCache() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), b = FW("beta", "2.0")
        await publish([a, b], on: site)
        await site.fail("/data/" + b.file)
        _ = await library(paths, site).sync()
        await site.setOffline(true)
        let offline = library(paths, site)
        let snap = await offline.snapshot()
        XCTAssertEqual(snap.entries.map(\.availability), [.installed, .notDownloaded])
        _ = try await offline.firmwareForPlayback(id: "alpha")
        do { _ = try await offline.firmwareForPlayback(id: "beta"); XCTFail("beta was never downloaded") } catch {}
    }

    // 14
    func testWithdrawalKeepsFilesAndSavesAndIsNotRedownloaded() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), gone = FW("gone", "0.9")
        let lib = library(paths, site)
        await publish([a, gone], on: site); _ = await lib.sync()
        let states = StateStore(folder: paths.state)
        try states.save(Data([9]), id: "gone", version: "0.9", sha256: gone.sha)
        await publish([a], on: site)
        let r = await lib.sync()
        XCTAssertEqual(r.withdrawn, ["gone"])
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries.map(\.entry.id), ["alpha"], "withdrawn firmware leaves the catalogue view")
        XCTAssertEqual(snap.withdrawn.map(\.id), ["gone"])
        XCTAssertEqual(snap.withdrawn.first?.entry?.version, "0.9", "its description is kept")
        XCTAssertTrue(exists(paths.firmwareFile(id: "gone", sha256: gone.sha)), "its file is not erased")
        XCTAssertEqual(states.load(id: "gone", version: "0.9", sha256: gone.sha), Data([9]))
        await site.clearLog()
        _ = await lib.sync()
        let n = await site.count("/data/" + gone.file)
        XCTAssertEqual(n, 0, "never downloaded again")
        await publish([a, gone], on: site)
        _ = await lib.sync()
        let back = await lib.snapshot()
        XCTAssertEqual(back.entries.map(\.entry.id), ["alpha", "gone"], "a firmware that comes back is listed again")
        XCTAssertEqual(back.withdrawn, [])
    }

    // 16
    func testMissingScreenshotDoesNotBlockFirmware() async throws {
        let site = FakePocket(), paths = freshRoot()
        let f = FW("alpha", "1.0")
        await publish([f], on: site)
        await site.set("/data/" + f.imagePath!, nil)                     // 404
        let lib = library(paths, site)
        let r = await lib.sync()
        XCTAssertEqual(r.installed, ["alpha"])
        XCTAssertEqual(r.failed, [:])
        let snap = await lib.snapshot()
        XCTAssertNil(snap.entries[0].screenshotFile)
        _ = try await lib.firmwareForPlayback(id: "alpha")
        // a non-image response is not cached as a screenshot either
        await site.set("/data/" + f.imagePath!, Data("<html>not found</html>".utf8))
        _ = await lib.sync()
        let snap2 = await lib.snapshot()
        XCTAssertNil(snap2.entries[0].screenshotFile)
    }

    // 17
    func testConcurrentRequestsShareOneDownload() async throws {
        let site = FakePocket(), paths = freshRoot()
        let f = FW("alpha", "1.0", image: nil)
        await publish([f], on: site)
        await site.hold("/data/" + f.file)
        let lib = library(paths, site)
        let s = Task { await lib.sync() }
        let started = await eventually { await site.waiting("/data/" + f.file) }
        XCTAssertTrue(started, "the sync's download is in progress")
        let p1 = Task { try await lib.ensureInstalled(f.entry, priority: .background) }
        let p2 = Task { try await lib.firmwareForPlayback(id: "alpha") }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await site.release("/data/" + f.file)
        _ = await s.value
        let b1 = try await p1.value
        let play = try await p2.value
        XCTAssertEqual(b1.sha256, f.sha)
        XCTAssertEqual(play.data, f.data)
        let n = await site.count("/data/" + f.file)
        XCTAssertEqual(n, 1, "one download, however many asked for it")
    }

    /// ARGO and Felucca 8 Patterns list the same original package under different library ids.
    /// Both need their own install record and file, including on an offline relaunch.
    func testIdenticalPackagesUnderDifferentIDsAreBothInstalled() async throws {
        let site = FakePocket(), paths = freshRoot()
        let data = Data("shared original package".utf8)
        let maker = "/maker/releases/download/v1/shared.fwsc"
        let ids = ["argo", "felucca8"]
        let entries: [[String: Any]] = ids.map { id in
            ["id": id, "name": id, "status": ["mac": ["state": "source-only"]],
             "emu": ["package": ["url": "https://github.com" + maker, "sha256": sha256Hex(data), "size": data.count],
                     "mac": ["state": "playable"], "preferred": ["mac": ["engine": "fm1-emu"]]]]
        }
        await site.set("/data/catalog-v2.json", try JSONSerialization.data(withJSONObject:
            ["schema": 2, "snapshot": "test", "updated": "test", "firmwares": entries]))
        await site.set(maker, data)
        await site.hold(maker)
        let lib = library(paths, site)
        let sync = Task { await lib.sync() }
        let bothStarted = await eventually { await site.count(maker) == 2 }
        await site.release(maker)      // also releases the held request when this regression fails
        let report = await sync.value
        XCTAssertTrue(bothStarted, "different ids must not reuse a task that installs only one id")
        XCTAssertEqual(report.failed, [:])
        XCTAssertEqual(Set(report.installed), Set(ids.map { $0 + ".fwsc" }))
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries.map(\.availability), [.installed, .installed])
        for id in ids {
            let key = id + ".fwsc"
            XCTAssertEqual(try Data(contentsOf: paths.firmwareFile(id: key, sha256: sha256Hex(data))), data)
            let play = try await lib.firmwareForPlayback(id: key)
            XCTAssertEqual(play.build.id, key, "playback and saved state belong to this firmware")
        }
        await site.clearLog()
        let again = await lib.sync()
        XCTAssertTrue(again.installed.isEmpty)
        let requests = await site.requests
        XCTAssertFalse(requests.contains(maker), "neither installed entry is downloaded again")
        await site.setOffline(true)
        let offline = library(paths, site)
        let cached = await offline.snapshot()
        XCTAssertEqual(cached.entries.map(\.availability), [.installed, .installed])
        for id in ids {
            let play = try await offline.firmwareForPlayback(id: id + ".fwsc")
            XCTAssertEqual(play.build.id, id + ".fwsc")
            XCTAssertEqual(play.data, data)
        }
    }

    func testIdenticalHashesDoNotHideAnotherFirmwaresDownloadFailure() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0", image: nil)
        var b = FW("beta", "1.0", image: nil)
        b.data = a.data
        await publish([a, b], on: site)
        await site.hold("/data/" + a.file)
        await site.hold("/data/" + b.file)
        await site.fail("/data/" + b.file)
        let lib = library(paths, site)
        let sync = Task { await lib.sync() }
        let bothStarted = await eventually {
            let first = await site.waiting("/data/" + a.file)
            let second = await site.waiting("/data/" + b.file)
            return first && second
        }
        await site.releaseAll()
        let report = await sync.value
        XCTAssertTrue(bothStarted)
        XCTAssertEqual(report.installed, ["alpha"])
        XCTAssertEqual(Set(report.failed.keys), ["beta"])
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries.map(\.availability), [.installed, .notDownloaded])
        XCTAssertNil(snap.entries[0].lastError)
        XCTAssertNotNil(snap.entries[1].lastError)
        XCTAssertTrue(snap.entries.allSatisfy { !$0.downloading })
    }

    // 18
    func testPlaybackJumpsTheQueue() async throws {
        let site = FakePocket(), paths = freshRoot()
        let fws = (1...5).map { FW("fw\($0)", "1.0", image: nil) }
        await publish(fws, on: site)
        for f in fws { await site.hold("/data/" + f.file) }
        let lib = library(paths, site)
        let syncTask = Task { await lib.sync() }
        let twoRunning = await eventually {
            let w0 = await site.waiting("/data/" + fws[0].file)
            let w1 = await site.waiting("/data/" + fws[1].file)
            return w0 && w1
        }
        XCTAssertTrue(twoRunning, "two background downloads start")
        let threeQueued = await eventually { await lib.scheduler.queued.count == 3 }
        XCTAssertTrue(threeQueued, "the other three wait")
        let inFlight = await site.inFlight
        XCTAssertEqual(inFlight, 2)
        let playTask = Task { try await lib.firmwareForPlayback(id: "fw5") }
        let promoted = await eventually { await site.waiting("/data/" + fws[4].file) }
        XCTAssertTrue(promoted, "the firmware chosen for playback starts at once")
        let n3 = await site.count("/data/" + fws[2].file)
        XCTAssertEqual(n3, 0, "ahead of the queued background downloads")
        await site.release("/data/" + fws[4].file)
        let play = try await playTask.value
        XCTAssertEqual(play.data, fws[4].data)
        await site.releaseAll()
        let r = await syncTask.value
        XCTAssertEqual(Set(r.failed.keys), [])
        let n5 = await site.count("/data/" + fws[4].file)
        XCTAssertEqual(n5, 1)
    }

    func testUnsafeCatalogueEntriesAreRefused() async throws {
        let site = FakePocket(), paths = freshRoot()
        let good = FW("alpha", "1.0")
        var bad1 = FW("evil", "1.0").entry; bad1.file = "../../../etc/passwd"
        var bad2 = FW("x", "1.0").entry; bad2.id = "../escape"
        var bad3 = FW("y", "1.0").entry; bad3.file = "https://elsewhere.test/fw.rfm1"
        var bad4 = FW("z", "1.0").entry; bad4.image = "/abs/shot.png"
        let c = Catalogue(schema: 1, updated: "2026-11-20T00:00:00Z", since: nil, count: 5, firmwares: [good.entry, bad1, bad2, bad3, bad4])
        await publish([good], on: site)
        await site.set("/data/catalog.json", try JSONEncoder().encode(c))
        let lib = library(paths, site)
        _ = await lib.sync()
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries.map(\.entry.id), ["alpha", "z"])
        XCTAssertNil(snap.entries[1].entry.image, "an unsafe screenshot path is dropped, not followed")
        let reqs = await site.requests
        XCTAssertFalse(reqs.contains { $0.contains("..") || $0.contains("passwd") || $0.hasPrefix("/abs") })
        XCTAssertEqual(LibrarySyncTests.files(paths.root).filter { !LibraryPaths.isInside($0, paths.managed) }, [])
    }

    func testBadOrEmptyCatalogueNeverReplacesTheGoodOne() async throws {
        let site = FakePocket(), paths = freshRoot()
        let lib = library(paths, site)
        await publish([FW("alpha", "1.0")], on: site); _ = await lib.sync()
        let good = try Data(contentsOf: paths.catalogue)
        for body in [Data("{not json".utf8), Data(#"{"schema":1,"updated":"x","firmwares":[]}"#.utf8), Data(#"{"schema":9,"updated":"x","firmwares":[]}"#.utf8)] {
            await site.set("/data/catalog.json", body)
            let r = await lib.sync()
            XCTAssertNotNil(r.catalogueError)
            XCTAssertEqual(try Data(contentsOf: paths.catalogue), good)
            let snap = await lib.snapshot()
            XCTAssertEqual(snap.entries.map(\.availability), [.installed])
        }
    }

    static func files(_ dir: URL) -> [URL] { FirmwareLibrary.files(under: dir) }

    // v2: the expanded catalogue
    func testV2IsPreferredAndOnlyMacDownloadableBuildsAreFetched() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), b = FW("beta", "2.0"), bad = FW("broken", "1.0")
        await publish([a, b], on: site)                                   // catalog.json (v1) lists alpha and beta
        await site.set("/data/" + bad.file, bad.data)
        await site.set("/data/catalog-v2.json", catalogueV2JSON([(a, "playable"), (b, "experimental")],
            listed: [("nobuild", "source-only", nil), ("broken", "unsupported", bad)], hub: true))
        let lib = library(paths, site)
        let r = await lib.sync()
        XCTAssertNil(r.catalogueError)
        XCTAssertEqual(r.feed, "v2")
        XCTAssertEqual(r.installed, ["alpha", "beta"])
        let reqs = await site.requests
        XCTAssertFalse(reqs.contains("/data/catalog.json"), "v1 is not needed when v2 is usable")
        XCTAssertFalse(reqs.contains("/data/" + bad.file), "an unsupported build is never downloaded")
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.feed, "v2")
        XCTAssertEqual(snap.entries.map(\.entry.id), ["alpha", "beta"])
        XCTAssertEqual(snap.entries.map { $0.mac?.state }, [.playable, .experimental])
        XCTAssertEqual(snap.entries[0].makers.first?.url, "https://example.test/alpha")
        XCTAssertEqual(Set(snap.more.map(\.id)), ["nobuild", "broken"])
        XCTAssertEqual(snap.more.first { $0.id == "nobuild" }?.hubURL, "https://thefirmwarehub.com/firmware/nobuild")
        XCTAssertEqual(snap.attribution?.license, "CC BY 4.0")
        XCTAssertTrue(snap.withdrawn.isEmpty)
        XCTAssertTrue(exists(paths.catalogueV2))

        // relaunch offline: the cached v2 still drives the library
        await site.setOffline(true)
        let again = library(paths, site)
        let snap2 = await again.snapshot()
        XCTAssertEqual(snap2.feed, "v2")
        XCTAssertEqual(snap2.more.count, 2)
        XCTAssertEqual(snap2.entries.map(\.availability), [.installed, .installed])
    }

    func testBadV2FallsBackToV1() async throws {
        for body in [Data("{not json".utf8), Data(#"{"schema":3,"snapshot":"x","updated":"x","firmwares":[]}"#.utf8),
                     catalogueV2JSON([], listed: [("nobuild", "source-only", nil)])] {
            let site = FakePocket(), paths = freshRoot()
            let a = FW("alpha", "1.0")
            await publish([a], on: site)
            await site.set("/data/catalog-v2.json", body)
            let lib = library(paths, site)
            let r = await lib.sync()
            XCTAssertNil(r.catalogueError)
            XCTAssertEqual(r.feed, "v1")
            XCTAssertEqual(r.installed, ["alpha"])
            let snap = await lib.snapshot()
            XCTAssertEqual(snap.feed, "v1")
            XCTAssertTrue(snap.more.isEmpty)
            XCTAssertNil(snap.attribution)
            XCTAssertFalse(exists(paths.catalogueV2), "an unusable v2 is never kept")
        }
    }

    /// A firmware Pocket keeps under a permanent id (first listed from FM1 Editor, later built by RemoteFM1FW):
    /// catalog.json uses the build's own id. After a night on catalog.json alone, the library still knows it by its
    /// Pocket id: the same downloaded build, no second download, nothing "No Longer Listed", also offline.
    func testPromotedBuildKeepsItsPocketIDOnCatalogJSONAlone() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), g = FW("glitchdrums", "0.4.0")
        await publish([a, g], on: site)
        var v2 = try JSONSerialization.jsonObject(with: catalogueV2JSON([(a, "playable"), (g, "playable")])) as! [String: Any]
        var list = v2["firmwares"] as! [[String: Any]]
        list[1]["id"] = "glitch-ttreu"
        list[1]["aliases"] = ["glitchdrums"]
        v2["firmwares"] = list
        await site.set("/data/catalog-v2.json", try JSONSerialization.data(withJSONObject: v2))
        let r1 = await library(paths, site).sync()
        XCTAssertEqual(r1.feed, "v2")
        XCTAssertEqual(Set(r1.installed), ["alpha", "glitch-ttreu"])

        await site.set("/data/catalog-v2.json", nil)
        await site.clearLog()
        let lib = library(paths, site)
        let r2 = await lib.sync()
        XCTAssertNil(r2.catalogueError)
        XCTAssertEqual(r2.feed, "v1")
        XCTAssertTrue(r2.installed.isEmpty, "nothing is downloaded again")
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries.map(\.entry.id), ["alpha", "glitch-ttreu"])
        XCTAssertEqual(snap.entries.map(\.availability), [.installed, .installed])
        XCTAssertTrue(snap.withdrawn.isEmpty, "nothing reads No Longer Listed")
        let reqs = await site.requests
        XCTAssertFalse(reqs.contains("/data/" + g.file))

        await site.setOffline(true)
        let again = await library(paths, site).snapshot()
        XCTAssertEqual(again.entries.map(\.entry.id), ["alpha", "glitch-ttreu"], "the cached catalog.json too")
    }

    func testV2WithdrawnFromSiteRetiresTheCachedCopy() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0")
        await publish([a], on: site)
        await site.set("/data/catalog-v2.json", catalogueV2JSON([(a, "playable")], listed: [("nobuild", "source-only", nil)]))
        _ = await library(paths, site).sync()
        XCTAssertTrue(exists(paths.catalogueV2))
        await site.set("/data/catalog-v2.json", nil)
        let lib = library(paths, site)
        let r = await lib.sync()
        XCTAssertEqual(r.feed, "v1")
        XCTAssertFalse(exists(paths.catalogueV2))
        let snap = await lib.snapshot()
        XCTAssertTrue(snap.more.isEmpty)
        XCTAssertEqual(snap.entries.map(\.availability), [.installed], "nothing is re-downloaded")
    }

    /// The contract between the two repositories, on real data: the dry-run v2 that Pocket's discover.mjs built
    /// from the 2026-11-19 catalogue gives this app exactly catalog.json's downloads, nothing more.
    func testRealV2DryRunMatchesV1Downloads() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let v1 = try Catalogue.decode(Data(contentsOf: dir.appendingPathComponent("catalog-v1-2026-11-19.json"))).validated()
        let v2 = try CatalogueV2.decode(Data(contentsOf: dir.appendingPathComponent("catalog-v2-dry.json")))
        let mac = try v2.macCatalogue()
        XCTAssertEqual(mac.firmwares.count, 95)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: mac.firmwares.map { ($0.id, $0) }),
                       Dictionary(uniqueKeysWithValues: v1.firmwares.map { ($0.id, $0) }))
        XCTAssertEqual(v2.firmwares.count, 118 - 1, "118 discovered, h1 is built in")
        XCTAssertTrue(v2.notDownloadable.allSatisfy { $0.mac.reason?.isEmpty == false }, "every firmware the app cannot get says why")
        XCTAssertTrue(v2.notDownloadable.allSatisfy { $0.source != nil }, "and links to where it came from")
    }

    func testMacVerificationLevels() throws {
        func status(_ json: String) throws -> CatalogueV2.Status { try JSONDecoder().decode(CatalogueV2.Status.self, from: Data(json.utf8)) }
        XCTAssertEqual(try status(#"{"state":"playable","verification":"macos"}"#).macVerification, .macos)
        let rep = try status(#"{"state":"playable","verification":"representative","tested":{"macos":{"sample":true}}}"#)
        XCTAssertEqual(rep.macVerification, .representative)
        XCTAssertEqual(rep.tested?.macos?.sample, true)
        let slow = try status(#"{"state":"experimental","verification":"representative","performance":"may-stutter"}"#)
        XCTAssertTrue(slow.mayStutter)
        // catalogues from before the field: worked out from the test record
        XCTAssertEqual(try status(#"{"state":"playable","tested":{"macos":{"outcome":"pass"}}}"#).macVerification, .macos)
        XCTAssertEqual(try status(#"{"state":"playable","tested":{"macos":{"date":"d"}}}"#).macVerification, .representative)
        XCTAssertEqual(try status(#"{"state":"experimental","tested":{"runtime":"x"}}"#).macVerification, .linux)
        XCTAssertEqual(try status(#"{"state":"playable","verification":"teleported"}"#).macVerification, .none)
    }

    /// catalog-v2.json's emu block: the maker's original package, as `<id>.fwsc`, downloaded from the maker (never from
    /// Pocket), checked against its hash; only the preferred engine in the background; saved under `.fwsc` paths.
    func testV2EmuPackagesComeFromTheMakerAndOnlyThePreferredInTheBackground() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), b = FW("beta", "2.0")
        let pkgA = Data("alpha original package bytes".utf8), pkgC = Data("gamma original package bytes".utf8)
        let makerA = "/maker/alpha/releases/download/v1.1/alpha-1.1.fwsc", makerC = "/maker/gamma/releases/download/v3/gamma-3.fwsc"
        await publish([a, b], on: site)
        await site.set(makerA, pkgA)
        await site.set(makerC, pkgC)
        var v2 = try JSONSerialization.jsonObject(with: catalogueV2JSON([(a, "playable"), (b, "playable")],
            listed: [("gamma", "source-only", nil)], hub: true)) as! [String: Any]
        var list = v2["firmwares"] as! [[String: Any]]
        func emu(_ url: String, _ data: Data, prefer: String) -> [String: Any] {
            ["package": ["url": "https://github.com" + url, "sha256": sha256Hex(data), "size": data.count, "version": "1.1", "license": "GPL-3.0",
                         "source": "https://github.com/maker/x/tree/v1.1", "file": "pkg/x.fwsc"],
             "mac": ["state": "playable", "reason": "Played the scripted session.", "tested": ["machine": "Darwin arm64, Apple M1", "speed": 3.1, "engine": "fm1-emu@09aeae3e9d78"]],
             "web": ["state": "playable"], "preferred": ["mac": ["engine": prefer, "reason": "why"], "web": ["engine": prefer]],
             "listened": []]
        }
        list[0]["emu"] = emu(makerA, pkgA, prefer: "fm1-emu")       // alpha: both engines, the emulator preferred
        list[1]["emu"] = ["package": NSNull(), "mac": ["state": "unavailable"], "web": ["state": "unavailable"], "preferred": ["mac": ["engine": "rfm1"]]]
        list[2]["emu"] = emu(makerC, pkgC, prefer: "fm1-emu")       // gamma: no build, the package only
        v2["firmwares"] = list
        await site.set("/data/catalog-v2.json", try JSONSerialization.data(withJSONObject: v2))
        let lib = library(paths, site)
        let r = await lib.sync()
        XCTAssertNil(r.catalogueError)
        XCTAssertEqual(r.installed, ["alpha.fwsc", "beta", "gamma.fwsc"], "alpha's .rfm1 is the alternative: not downloaded in the background")
        let reqs = await site.requests
        XCTAssertTrue(reqs.contains(makerA) && reqs.contains(makerC), "packages come from the makers' releases")
        XCTAssertFalse(reqs.contains("/data/pkg/x.fwsc"), "never Pocket's hosted copy")
        XCTAssertFalse(reqs.contains("/data/" + a.file))
        XCTAssertTrue(exists(paths.firmwareFile(id: "alpha.fwsc", sha256: sha256Hex(pkgA))))
        XCTAssertTrue(paths.firmwareFile(id: "alpha.fwsc", sha256: sha256Hex(pkgA)).path.hasSuffix(".fwsc"))
        let snap = await lib.snapshot()
        XCTAssertEqual(snap.entries.map(\.entry.id), ["alpha", "alpha.fwsc", "beta", "gamma.fwsc"])
        XCTAssertEqual(snap.entries[1].mac?.state, .playable)
        XCTAssertEqual(snap.entries[1].emu?.macTested?.speed, 3.1)
        XCTAssertFalse(snap.more.contains { $0.id == "gamma" }, "a firmware the emulator plays is in the library, not under More")
        // choosing the other engine downloads it on demand
        let p = try await lib.firmwareForPlayback(id: "alpha")
        XCTAssertEqual(p.data, a.data)
        let q = try await lib.firmwareForPlayback(id: "alpha.fwsc")
        XCTAssertEqual(q.data, pkgA)
        // a package that does not match its hash is never used
        await site.set(makerC, Data("tampered".utf8))
        let fresh = library(freshRoot(), site)
        let r2 = await fresh.sync()
        XCTAssertNotNil(r2.failed["gamma.fwsc"])
        // the registry rebuilt from disk keeps packages as packages
        let v2data = await site.files["/data/catalog-v2.json"]!
        let rebuilt = RegistryStore(paths: paths).rebuild(catalogue: try CatalogueV2.decode(v2data).macCatalogue())
        XCTAssertEqual(rebuilt.firmwares["alpha.fwsc"]?.current?.sha256, sha256Hex(pkgA))
    }

    func testEmuPreviewFillsOnlyMissingBlocksForTheSameHubVersion() throws {
        let sha = String(repeating: "b", count: 64)
        let json = #"{"schema":2,"snapshot":"s","updated":"u","firmwares":[{"id":"x","name":"X","file":"fw/x.rfm1","sha256":"\#(String(repeating: "a", count: 64))","size":1,"status":{"web":{"state":"playable"},"mac":{"state":"playable"}},"provenance":{"hub":{"version":"2.0"}}},{"id":"y","name":"Y","status":{"mac":{"state":"source-only"}},"provenance":{"hub":{"version":"1.0"}}}]}"#
        let preview = #"{"firmwares":{"x":{"hubVersion":"2.0","emu":{"package":{"url":"https://github.com/m/x/releases/download/v2/x.fwsc","sha256":"\#(sha)","version":"2.0"},"mac":{"state":"playable"},"preferred":{"mac":{"engine":"fm1-emu"}}},"confidence":{"mac":{"fm1-emu":{"level":"listened","note":"n"},"rfm1":{"level":"known-issue","note":"k"}}},"listened":[{"firmware":"x","player":"mac","engine":"fm1-emu","verdict":"good"}]},"y":{"hubVersion":"0.9","emu":{"package":{"url":"https://github.com/m/y/releases/download/v1/y.fwsc","sha256":"\#(sha)"},"mac":{"state":"playable"}}}}}"#
        let c = try CatalogueV2.decode(Data(json.utf8)).withPreview(Data(preview.utf8))
        XCTAssertEqual(c.firmwares[0].emu?.package?.sha256, sha)
        XCTAssertNil(c.firmwares[1].emu, "a preview made for another Hub version is not used")
        XCTAssertEqual(c.firmwares[0].confidence["fm1-emu"]?.level, .listened)
        XCTAssertEqual(c.firmwares[0].confidence["rfm1"], CatalogueV2.Confidence(level: .knownIssue, note: "k"))
        XCTAssertEqual(c.firmwares[0].listened.count, 1)
        XCTAssertEqual(c.firmwares[0].preferredMacEngine, "fm1-emu")
        XCTAssertEqual(c.alternative(for: "x"), true)
        XCTAssertEqual(c.alternative(for: "x.fwsc"), false)
        XCTAssertEqual(try c.macCatalogue().firmwares.map(\.id), ["x", "x.fwsc"])
        XCTAssertEqual(try c.macCatalogue().firmwares[1].makerURL?.host, "github.com")
        // once the catalogue has its own emu blocks, the preview is ignored
        let own = try CatalogueV2.decode(Data(json.replacingOccurrences(of: #""provenance":{"hub":{"version":"1.0"}}"#, with: #""provenance":{"hub":{"version":"1.0"}},"emu":{"mac":{"state":"unavailable"}}"#).utf8))
        XCTAssertNil(own.withPreview(Data(preview.utf8)).firmwares[0].emu)
        // a package on a host that is not a maker's release is never downloaded
        var odd = try c.macCatalogue().firmwares[1]
        odd.remoteURL = "http://example.test/x.fwsc"
        XCTAssertNil(odd.makerURL)
    }

    /// Discovery dates: the firmware's real release (version and date) and the day it was first listed; a missing
    /// release stays unknown; a test build's preview fills them in where the catalogue lacks them.
    func testV2ReleaseAndListedDates() throws {
        let sha = String(repeating: "a", count: 64)
        let json = #"{"schema":2,"snapshot":"s","updated":"u","firmwares":[{"id":"x","name":"X","file":"fw/x.rfm1","sha256":"\#(sha)","size":1,"status":{"mac":{"state":"playable"}},"release":{"version":"1.8.2","date":"2026-11-13T04:17:47Z","source":"The Firmware Hub"},"listed":"2026-10-08"},{"id":"y","name":"Y","status":{"mac":{"state":"source-only"}},"release":null,"provenance":{"hub":{"version":"1.0"}}}]}"#
        let c = try CatalogueV2.decode(Data(json.utf8))
        XCTAssertEqual(c.firmwares[0].release?.version, "1.8.2")
        XCTAssertEqual(c.firmwares[0].release?.day, ISO8601DateFormatter().date(from: "2026-11-13T04:17:47Z"))
        XCTAssertEqual(c.firmwares[0].listed, "2026-10-08")
        XCTAssertNil(c.firmwares[1].release)
        let preview = #"{"firmwares":{"y":{"hubVersion":"1.0","release":{"version":"1.0","date":"2026-11-02T00:00:00Z"},"listed":"2026-11-15"}}}"#
        let p = c.withPreview(Data(preview.utf8))
        XCTAssertEqual(p.firmwares[1].release?.version, "1.0")
        XCTAssertEqual(p.firmwares[1].listed, "2026-11-15")
        XCTAssertEqual(p.firmwares[0].release?.version, "1.8.2", "the catalogue's own dates win")
    }

    func testEngineChoicesAreKept() throws {
        let paths = freshRoot(), store = EngineChoiceStore(paths: paths)
        XCTAssertEqual(store.load(), [:])
        try store.save(["alpha": "rfm1", "beta": "fm1-emu"])
        XCTAssertEqual(store.load(), ["alpha": "rfm1", "beta": "fm1-emu"])
    }

    func testV2DecodingToleratesUnknownStatesAndFields() throws {
        let json = #"{"schema":2,"snapshot":"s","updated":"u","future":true,"firmwares":[{"id":"x","name":"X","file":"fw/x.rfm1","sha256":"\#(String(repeating: "a", count: 64))","size":1,"status":{"web":{"state":"playable"},"mac":{"state":"teleported"}}},{"id":"y"}]}"#
        let c = try CatalogueV2.decode(Data(json.utf8))
        XCTAssertEqual(c.firmwares[0].mac.state, .sourceOnly, "an unknown state is never downloadable")
        XCTAssertFalse(c.firmwares[0].macDownloadable)
        XCTAssertEqual(c.firmwares[1].mac.state, .sourceOnly)
        XCTAssertThrowsError(try c.macCatalogue(), "nothing downloadable: v1 is used instead")
    }
}

final class LibraryStorageTests: XCTestCase {
    private func library(_ paths: LibraryPaths, _ site: FakePocket) -> FirmwareLibrary {
        FirmwareLibrary(paths: paths, base: base, fetcher: site)
    }

    /// user-owned files of every kind, to check nothing ever touches them
    private func makeUserData(_ paths: LibraryPaths) throws -> [URL: Data] {
        var made: [URL: Data] = [:]
        let states = StateStore(folder: paths.state)
        try states.save(Data([1]), id: "alpha", version: "1.0", sha256: String(repeating: "a", count: 64))
        try states.save(Data([2]), id: "alpha", version: "1.0", sha256: String(repeating: "a", count: 64))   // makes a .prev
        try states.save(Data([3]), id: "old", version: "0.1")
        try FavouritesStore(paths: paths).save(["alpha", "beta"])
        let export = paths.userData.appendingPathComponent("my backup.flash")
        try Data([7, 7]).write(to: export)
        let fm = FileManager.default
        for u in FirmwareLibrary.files(under: paths.state) + FirmwareLibrary.files(under: paths.userData) + FirmwareLibrary.files(under: paths.imported) {
            made[u] = try Data(contentsOf: u)
        }
        XCTAssertTrue(fm.fileExists(atPath: states.url(id: "alpha", version: "1.0", sha256: String(repeating: "a", count: 64)).path + ".prev"))
        return made
    }

    // 11
    func testCleanupNeverTouchesUserData() async throws {
        let site = FakePocket(), paths = freshRoot()
        let lib = library(paths, site)
        let h1 = FileManager.default.temporaryDirectory.appendingPathComponent("h1-\(UUID().uuidString).rfm1")
        try h1Fixture().write(to: h1)
        try await lib.importFirmware(from: h1)
        let user = try makeUserData(paths)
        XCTAssertGreaterThanOrEqual(user.count, 6)
        await publish([FW("alpha", "1.0")], on: site)
        _ = await lib.sync()
        // junk in every managed folder
        let fm = FileManager.default
        try fm.createDirectory(at: paths.firmware.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.firmware.appendingPathComponent("alpha/notes.txt"))
        try fm.createDirectory(at: paths.firmware.appendingPathComponent("unknown"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.firmware.appendingPathComponent("unknown/\(String(repeating: "b", count: 64)).rfm1"))
        try Data("x".utf8).write(to: paths.shots.appendingPathComponent("stale.png"))
        try Data("x".utf8).write(to: paths.tmp.appendingPathComponent("abandoned.download"))
        try fm.createDirectory(at: paths.legacyCatalogue.appendingPathComponent("fw"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.legacyCatalogue.appendingPathComponent("fw/old-12345678.rfm1"))
        try Data("{}".utf8).write(to: paths.legacyCatalogue.appendingPathComponent("catalog.json"))
        let plan = await lib.cleanupPlan()
        XCTAssertEqual(Set(plan.map(\.reason)), [.invalid, .obsoleteScreenshot, .temporary, .legacyCache])
        let removed = await lib.cleanUp()
        XCTAssertEqual(removed.count, plan.count)
        for (u, d) in user { XCTAssertEqual(try Data(contentsOf: u), d, "\(u.lastPathComponent) must be untouched") }
        let imports = await lib.registry.imports
        XCTAssertEqual(imports.count, 1)
        XCTAssertTrue(exists(paths.imported.appendingPathComponent(imports[0].file)))
        XCTAssertTrue(exists(paths.firmwareFile(id: "alpha", sha256: FW("alpha", "1.0").sha)), "kept firmware stays")
        XCTAssertEqual(FavouritesStore(paths: paths).load(), ["alpha", "beta"])
        let usage = await lib.storageUsage()
        XCTAssertGreaterThan(usage.currentFirmware, 0)
        XCTAssertGreaterThan(usage.savedStates, 0)
        XCTAssertGreaterThan(usage.imported, 0)
        XCTAssertGreaterThan(usage.screenshotsAndMetadata, 0)
        XCTAssertEqual(usage.temporary, 0)
    }

    // 12
    func testCleanupRefusesAPlayingFirmware() async throws {
        let site = FakePocket(), paths = freshRoot()
        let v1 = FW("sloop", "1"), v2 = FW("sloop", "2"), v3 = FW("sloop", "3")
        let lib = library(paths, site)
        await publish([v1], on: site); _ = await lib.sync()
        let playing = try await lib.firmwareForPlayback(id: "sloop")
        await lib.markActive(sha256: playing.build.sha256)
        await publish([v2], on: site); _ = await lib.sync()
        await publish([v3], on: site); _ = await lib.sync()
        XCTAssertTrue(exists(paths.firmwareFile(id: "sloop", sha256: v1.sha)), "never delete the firmware that is playing")
        let manual = await lib.cleanUp()
        XCTAssertFalse(manual.contains { $0.url.lastPathComponent.hasPrefix(v1.sha) })
        await lib.markInactive(sha256: playing.build.sha256)
        let later = await lib.cleanUp()
        XCTAssertTrue(later.contains { $0.reason == .superseded && $0.url.lastPathComponent == "\(v1.sha).rfm1" })
        XCTAssertFalse(exists(paths.firmwareFile(id: "sloop", sha256: v1.sha)))
        XCTAssertTrue(exists(paths.firmwareFile(id: "sloop", sha256: v2.sha)))
    }

    // 13
    func testImportsAreNeverReplacedOrRemoved() async throws {
        let site = FakePocket(), paths = freshRoot()
        let lib = library(paths, site)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("h1-\(UUID().uuidString).rfm1")
        let bytes = try h1Fixture()
        try bytes.write(to: src)
        let imported = try await lib.importFirmware(from: src)
        XCTAssertEqual(imported.origin, .imported)
        XCTAssertEqual(imported.id, "h1")
        let again = try await lib.importFirmware(from: src)
        XCTAssertEqual(again.file, imported.file, "the same bytes are imported once")
        // the catalogue publishes a different "h1", it updates, then disappears
        let c1 = FW("h1", "9.9"), c2 = FW("h1", "10.0")
        await publish([c1], on: site); _ = await lib.sync()
        await publish([c2], on: site); _ = await lib.sync()
        await publish([FW("other", "1")], on: site); _ = await lib.sync()
        _ = await lib.cleanUp()
        let file = paths.imported.appendingPathComponent(imported.file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let imports = await lib.registry.imports
        XCTAssertEqual(imports, [imported])
        do { _ = try await lib.importFirmware(from: URL(fileURLWithPath: "/nonexistent.rfm1")); XCTFail() } catch {}
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).rfm1")
        try Data("not wasm".utf8).write(to: junk)
        do { _ = try await lib.importFirmware(from: junk); XCTFail("a non-.rfm1 file is refused") } catch {}
    }

    // 15
    func testDamagedRegistryFallsBackThenRebuilds() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a1 = FW("alpha", "1.0"), a2 = FW("alpha", "1.1"), b = FW("beta", "2.0")
        let lib = library(paths, site)
        await publish([a1, b], on: site); _ = await lib.sync()
        await publish([a2, b], on: site); _ = await lib.sync()
        let good = await lib.registry
        try Data("garbage{".utf8).write(to: paths.registry)
        let fromBackup = library(paths, site)
        XCTAssertEqual(fromBackup.registryLoad, .fromBackup)
        let fbReg = await fromBackup.registry
        XCTAssertEqual(fbReg.firmwares["beta"]?.current?.sha256, b.sha)
        try Data("garbage{".utf8).write(to: paths.registry)
        try Data().write(to: paths.registryBackup)
        let rebuilt = library(paths, site)
        XCTAssertEqual(rebuilt.registryLoad, .rebuilt)
        let reg = await rebuilt.registry
        XCTAssertEqual(reg.firmwares["alpha"]?.builds.map(\.sha256), good.firmwares["alpha"]?.builds.map(\.sha256),
                       "current (from the catalogue) and previous are worked out from disk")
        XCTAssertEqual(reg.firmwares["alpha"]?.current?.version, "1.1")
        XCTAssertEqual(reg.firmwares["beta"]?.current?.sha256, b.sha)
        await site.clearLog()
        let r = await rebuilt.sync()
        XCTAssertEqual(r.installed, [], "nothing is downloaded again")
        XCTAssertTrue(exists(paths.firmwareFile(id: "alpha", sha256: a1.sha)), "no verified firmware lost")
        // a firmware file that no longer matches its name is not trusted
        try Data("corrupt".utf8).write(to: paths.firmwareFile(id: "beta", sha256: b.sha))
        try FileManager.default.removeItem(at: paths.registry)
        try FileManager.default.removeItem(at: paths.registryBackup)
        let again = library(paths, site)
        let reg2 = await again.registry
        XCTAssertNil(reg2.firmwares["beta"])
        let r2 = await again.sync()
        XCTAssertEqual(r2.installed, ["beta"], "the corrupt file is replaced by a verified download")
    }

    // 19
    func testSavedStatesOutliveObsoleteFirmware() async throws {
        let site = FakePocket(), paths = freshRoot()
        let v1 = FW("sloop", "3.4"), v2 = FW("sloop", "3.5"), v3 = FW("sloop", "3.6")
        let lib = library(paths, site)
        let states = StateStore(folder: paths.state)
        await publish([v1], on: site); _ = await lib.sync()
        try states.save(Data([0xaa, 0xbb]), id: "sloop", version: "3.4", sha256: v1.sha)
        await publish([v2], on: site); _ = await lib.sync()
        await publish([v3], on: site); _ = await lib.sync()
        XCTAssertFalse(exists(paths.firmwareFile(id: "sloop", sha256: v1.sha)), "3.4's binary is gone")
        XCTAssertEqual(states.load(id: "sloop", version: "3.4", sha256: v1.sha), Data([0xaa, 0xbb]), "its save is kept")
        XCTAssertNil(states.load(id: "sloop", version: "3.6", sha256: v3.sha), "and not copied to 3.6")
        let keys = states.savedKeys(id: "sloop")
        XCTAssertEqual(keys, [StateStore.buildKey(version: "3.4", sha256: v1.sha)])
        await lib.noteStateFromOtherBuild(id: "sloop", otherKey: keys.first)
        let note = await lib.registry.firmwares["sloop"]?.stateFromOtherBuild
        XCTAssertEqual(note, keys.first, "the chance to offer the old settings is recorded")
        let reloaded = library(paths, site)
        let persisted = await reloaded.registry.firmwares["sloop"]?.stateFromOtherBuild
        XCTAssertEqual(persisted, keys.first)
    }

    // 20
    func testTornRegistryWriteRecovers() async throws {
        let site = FakePocket(), paths = freshRoot()
        let a = FW("alpha", "1.0"), b = FW("beta", "1.0")
        let lib = library(paths, site)
        await publish([a, b], on: site); _ = await lib.sync()
        let full = try Data(contentsOf: paths.registry)
        try full.prefix(full.count / 2).write(to: paths.registry)          // power cut half-way through a write
        let relaunched = library(paths, site)
        XCTAssertEqual(relaunched.registryLoad, .fromBackup)
        let snap = await relaunched.snapshot()
        XCTAssertTrue(snap.entries.allSatisfy { $0.availability == .installed })
        _ = await relaunched.cleanUp()
        XCTAssertTrue(exists(paths.firmwareFile(id: "alpha", sha256: a.sha)))
        XCTAssertTrue(exists(paths.firmwareFile(id: "beta", sha256: b.sha)))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try dec.decode(Registry.self, from: Data(contentsOf: paths.registry)), "the registry is whole again")
    }

    func testSchedulerPassesSlotsInOrderAndPromotes() async {
        let s = DownloadScheduler(limit: 2)
        let g1 = await s.acquire(tag: "a", priority: .background)
        let g2 = await s.acquire(tag: "b", priority: .background)
        XCTAssertEqual([g1, g2], [.background, .background])
        let t3 = Task { await s.acquire(tag: "c", priority: .background) }
        let t4 = Task { await s.acquire(tag: "d", priority: .background) }
        let bothQueued = await eventually { await s.queued.count == 2 }
        XCTAssertTrue(bothQueued)
        let gi = await s.acquire(tag: "i", priority: .interactive)
        XCTAssertEqual(gi, .interactive, "interactive never waits")
        let queuedNow = await s.queued
        let promotedTask = queuedNow[1] == "d" ? t4 : t3
        let otherTask = queuedNow[1] == "d" ? t3 : t4
        await s.promote(tag: queuedNow[1])
        let promotedGrant = await promotedTask.value
        XCTAssertEqual(promotedGrant, .interactive)
        await s.release(g1)
        let other = await otherTask.value
        XCTAssertEqual(other, .background)
        let q = await s.queued
        XCTAssertEqual(q, [])
    }
}
