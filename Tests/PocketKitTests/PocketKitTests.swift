import Foundation
import XCTest
@testable import PocketKit

/// the repository's Resources folder (h1.rfm1 is the same file the app bundles)
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources")
private func h1() throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent("h1.rfm1")) }
private func rms(_ a: [Float]) -> Double { (a.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(a.count, 1))).squareRoot() }
private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("fm1pocket-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// MARK: - the native firmware host

final class HostTests: XCTestCase {
    func testManifest() throws {
        let f = try RFM1File(h1())
        XCTAssertEqual(f.id, "h1")
        XCTAssertEqual(f.name, "h1")
        XCTAssertEqual(f.abi, 6)
        XCTAssertEqual(f.license, "MIT")
        XCTAssertEqual(f.authors, ["Jake Handy"])
        XCTAssertFalse(f.licenses.isEmpty)
        XCTAssertThrowsError(try RFM1File(Data([1, 2, 3, 4, 5, 6, 7, 8])))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try FirmwareCore(bytes: Data(repeating: 7, count: 64)))
    }

    /// The same checks as FM-1 Pocket Player's tests/run.js: powers on, draws, sounds when played, reacts, saves.
    func testH1BootsDrawsPlaysAndReacts() throws {
        let core = try FirmwareCore(bytes: h1())
        XCTAssertEqual(core.id, "h1")
        XCTAssertEqual(core.abi, 6)
        core.boot(flash: nil)
        core.run(milliseconds: 1500)
        XCTAssertFalse(core.isHalted, core.errorMessage)

        var px: [UInt8] = []
        let writes = core.screen(into: &px)
        var lit = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] | px[i + 1] | px[i + 2] != 0 { lit += 1 }
        XCTAssertGreaterThan(lit, 1000, "the screen should show h1's home screen")

        let idle = rms(core.pull(frames: 4410))
        for k in [7, 11, 14] { core.key(k, down: true, velocity: 100) }
        core.run(milliseconds: 50)
        let played = rms(core.pull(frames: 22050))
        for k in [7, 11, 14] { core.key(k, down: false) }
        XCTAssertGreaterThan(played, 0.01, "a held chord should be audible")
        XCTAssertGreaterThan(played, idle)

        core.turn(.knob1, by: 3)
        core.turn(.presets, by: 1)
        core.button(.home, down: true); core.run(milliseconds: 80); core.button(.home, down: false)
        core.run(milliseconds: 600)
        XCTAssertGreaterThan(core.lcdWrites, writes, "input should redraw the screen")
        XCTAssertFalse(core.isHalted, core.errorMessage)

        let flash = core.flashImage(sync: true)
        XCTAssertEqual(flash?.count, core.flashSize)
    }

    func testMidiNoteMakesSound() throws {
        let core = try FirmwareCore(bytes: h1())
        core.boot(flash: nil)
        core.run(milliseconds: 1000)
        _ = core.pull(frames: 4410)
        XCTAssertTrue(core.midi(0x90, 60, 100))
        let played = rms(core.pull(frames: 22050))
        core.midi(0x80, 60, 0)
        XCTAssertGreaterThan(played, 0.005, "MIDI note on should play")
    }

    func testSavedStateRoundTrip() throws {
        let store = StateStore(folder: tempDir())
        let core = try FirmwareCore(bytes: h1())
        core.boot(flash: nil)
        core.run(milliseconds: 500)
        let img = try XCTUnwrap(core.flashImage(sync: true))
        try store.save(img, id: core.id, version: core.version)
        XCTAssertEqual(store.load(id: core.id, version: core.version), img)
        XCTAssertNil(store.load(id: core.id, version: "9.9.9"), "states are kept apart by version")
        let again = try FirmwareCore(bytes: h1())
        again.boot(flash: img)
        again.run(milliseconds: 500)
        XCTAssertFalse(again.isHalted, again.errorMessage)
    }

    /// A save that exists but is empty (the emulator engine's "nothing differs from the package") is a real save:
    /// an older backup must not come back in its place. A missing save still falls back to its backup.
    func testAnEmptySaveIsNotReplacedByItsBackup() throws {
        let store = StateStore(folder: tempDir())
        let sha = String(repeating: "c", count: 64)
        try store.save(Data([1, 2, 3]), id: "x", version: "fm1-emu+1", sha256: sha)
        try store.save(Data(), id: "x", version: "fm1-emu+1", sha256: sha)          // the .prev now holds [1, 2, 3]
        XCTAssertNil(store.load(id: "x", version: "fm1-emu+1", sha256: sha))
        try FileManager.default.removeItem(at: store.url(id: "x", version: "fm1-emu+1", sha256: sha))
        XCTAssertEqual(store.load(id: "x", version: "fm1-emu+1", sha256: sha), Data([1, 2, 3]), "a missing save falls back to its backup")
    }

    /// Saves made by released builds (id, version and hash) keep their place and load unchanged.
    func testReleasedBuildSavesKeepTheirKey() throws {
        let store = StateStore(folder: tempDir())
        let sha = String(repeating: "d", count: 64)
        let old = store.folder.appendingPathComponent("h1/0.9@dddddddddddd.flash")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9, 8, 7]).write(to: old)
        XCTAssertEqual(store.url(id: "h1", version: "0.9", sha256: sha), old)
        XCTAssertEqual(store.load(id: "h1", version: "0.9", sha256: sha), Data([9, 8, 7]))
        XCTAssertNil(store.load(id: "h1", version: "fm1-emu+0.9", sha256: sha), "the emulator never reads an .rfm1 save")
    }

    /// Ten seconds of h1 with a chord held: how much faster than real time this machine runs it.
    func testSpeed() throws {
        let core = try FirmwareCore(bytes: h1())
        core.boot(flash: nil)
        core.run(milliseconds: 1000)
        for k in [7, 11, 14] { core.key(k, down: true) }
        let start = Date()
        var buf = [Float](repeating: 0, count: 512 * 2)
        for _ in 0..<(441000 / 512) { buf.withUnsafeMutableBufferPointer { core.pull($0.baseAddress!, frames: 512) } }
        let speed = 10.0 / Date().timeIntervalSince(start)
        print("h1 speed: \(String(format: "%.1f", speed))x realtime")
        XCTAssertFalse(core.isHalted, core.errorMessage)
        XCTAssertGreaterThan(speed, 1.5, "h1 must run faster than real time to play without dropouts")
    }
}

// MARK: - the catalogue

private let sampleCatalogue = """
{"schema":1,"updated":"2026-11-19T08:40:52.624Z","since":"2026-11-19","count":2,"firmwares":[
 {"id":"amb","name":"AMB-1","version":"1.3.2","authors":["Charles Vestal"],"category":"Other","tag":"Generative ambient",
  "about":"A generative ambient machine.","license":"MPL-2.0","source":"https://github.com/charlesvestal/fm1-amb",
  "commit":"7c538516d6c52216ff4c8a4881cf2f0dcb07c44b","glue":null,"builtBy":"fm1-base","abi":6,"beta":false,
  "file":"fw/amb-8a5014a6.rfm1","sha256":"8A5014A6DBB556774EFE0FAAC6ED46C7DA2CC2D8C257723D027364B491242936","size":200910,
  "added":"2026-11-19","updated":"2026-11-19","image":"shots/amb-8a5014a6.png","someFutureField":42},
 {"id":"tiny","name":"Tiny","file":"fw/tiny-00000000.rfm1","sha256":"00","license":"MIT"}
]}
"""

final class CatalogueTests: XCTestCase {
    func testDecodes() throws {
        let c = try Catalogue.decode(Data(sampleCatalogue.utf8))
        XCTAssertEqual(c.firmwares.count, 2)
        let a = c.firmwares[0]
        XCTAssertEqual(a.id, "amb")
        XCTAssertEqual(a.authors, ["Charles Vestal"])
        XCTAssertEqual(a.sha256, "8a5014a6dbb556774efe0faac6ed46c7da2cc2d8c257723d027364b491242936", "checksums are compared lower-case")
        XCTAssertEqual(c.firmwares[1].category, "Other", "missing fields get defaults")
        XCTAssertEqual(c.firmwares[1].authors, [])
    }

    func testRejectsOtherSchemas() {
        XCTAssertThrowsError(try Catalogue.decode(Data(#"{"schema":2,"updated":"x","firmwares":[]}"#.utf8)))
        XCTAssertThrowsError(try Catalogue.decode(Data("not json".utf8)))
    }

    func testURLs() throws {
        let s = CatalogueService(cacheDir: tempDir())
        let c = try Catalogue.decode(Data(sampleCatalogue.utf8))
        XCTAssertEqual(s.url(for: c.firmwares[0].file).absoluteString,
                       "https://slowphase.github.io/fm1-pocket-player/data/fw/amb-8a5014a6.rfm1")
        XCTAssertEqual(s.imageURL(for: c.firmwares[0])?.absoluteString,
                       "https://slowphase.github.io/fm1-pocket-player/data/shots/amb-8a5014a6.png")
    }

    func testDownloadIsVerifiedAndCached() async throws {
        let fw = try h1()
        let good = CatalogueEntry(id: "h1", name: "h1", version: "0.2.1", license: "MIT", file: "fw/h1-test.rfm1",
                                  sha256: sha256Hex(fw), size: fw.count)
        let bad = CatalogueEntry(id: "x", name: "Broken", version: "1", license: "MIT", file: "fw/x-test.rfm1",
                                 sha256: String(repeating: "0", count: 64), size: fw.count)
        StubProtocol.responses = [
            "/data/catalog.json": (200, Data(#"{"schema":1,"updated":"2026-11-20T00:00:00Z","firmwares":[]}"#.utf8)),
            "/data/fw/h1-test.rfm1": (200, fw),
            "/data/fw/x-test.rfm1": (200, fw),
        ]
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let s = CatalogueService(base: URL(string: "https://example.test/data/")!, cacheDir: tempDir(), session: URLSession(configuration: cfg))

        XCTAssertNil(s.cachedCatalogue())
        _ = try await s.fetchCatalogue()
        XCTAssertNotNil(s.cachedCatalogue(), "a good catalogue is kept for offline use")

        StubProtocol.responses["/data/catalog.json"] = (500, Data())
        do { _ = try await s.fetchCatalogue(); XCTFail("a server error should throw") } catch {}
        XCTAssertNotNil(s.cachedCatalogue(), "a failed update keeps the last good catalogue")

        let bytes = try await s.firmware(for: good)
        XCTAssertEqual(bytes, fw)
        XCTAssertTrue(s.isCached(good))
        StubProtocol.responses["/data/fw/h1-test.rfm1"] = (404, Data())
        let again = try await s.firmware(for: good)
        XCTAssertEqual(again, fw, "a cached firmware needs no download")

        do { _ = try await s.firmware(for: bad); XCTFail("a checksum mismatch must be refused") }
        catch { XCTAssertEqual(error as? PocketError, .checksumMismatch("Broken")) }
        XCTAssertFalse(s.isCached(bad), "a file that fails its checksum is never stored")
    }

    /// Runs only when FM1_LIVE=1 (GitHub Actions sets it): the real published catalogue, its smallest firmware
    /// downloaded, verified and booted.
    func testLiveCatalogue() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FM1_LIVE"] == "1", "set FM1_LIVE=1 to test the live catalogue")
        let s = CatalogueService(cacheDir: tempDir())
        let c = try await s.fetchCatalogue()
        print("live catalogue: \(c.firmwares.count) firmwares, updated \(c.updated)")
        XCTAssertGreaterThan(c.firmwares.count, 0)
        let small = try XCTUnwrap(c.firmwares.min { $0.size < $1.size })
        let bytes = try await s.firmware(for: small)
        let core = try FirmwareCore(bytes: bytes)
        core.boot(flash: nil)
        core.run(milliseconds: 1500)
        print("live firmware: \(small.name) \(small.version), halted=\(core.haltCode)")
        XCTAssertFalse(core.isHalted, core.errorMessage)
    }
}

/// Serves canned responses by URL path, so download tests need no network.
final class StubProtocol: URLProtocol {
    static var responses: [String: (Int, Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.responses[request.url?.path ?? ""] ?? (404, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
