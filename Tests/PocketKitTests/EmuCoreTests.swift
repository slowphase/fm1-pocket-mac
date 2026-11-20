import Foundation
import XCTest
@testable import PocketKit

/// The emulator engine (evaluation). Needs an original package: CI downloads Felucca from its maker's release
/// (Tests/emu-packages.json, SHA-256 checked) and sets FM1_FWSC; without one these tests are skipped.
final class EmuCoreTests: XCTestCase {
    private func package() throws -> Data {
        guard let p = ProcessInfo.processInfo.environment["FM1_FWSC"], let d = FileManager.default.contents(atPath: p) else {
            throw XCTSkip("no FM1_FWSC package")
        }
        return d
    }

    func testBootsDrawsAndPlaysAKey() throws {
        let core = try EmuCore(package: try package(), id: "felucca", name: "Felucca", version: "1.8.2")
        core.boot(flash: nil)
        XCTAssertTrue(core.isBooted)
        core.run(milliseconds: 3000)
        var px: [UInt8] = []
        let rev = core.screen(into: &px)
        XCTAssertGreaterThan(rev, 0, "the screen was drawn")
        XCTAssertEqual(px.count, 240 * 240 * 4)
        core.key(12, down: true, velocity: 110)
        var buf = [Float](repeating: 0, count: 2 * 22050)
        buf.withUnsafeMutableBufferPointer { core.pull($0.baseAddress!, frames: 22050) }
        let rms = (buf.reduce(0) { $0 + Double($1 * $1) } / Double(buf.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.001, "a key sounds")
        XCTAssertFalse(core.isHalted)
    }

    func testSavesAreSectorRecordsAndSurviveAReboot() throws {
        let pkg = try package()
        let a = try EmuCore(package: pkg, id: "felucca", name: "Felucca", version: "1.8.2")
        a.boot(flash: nil)
        XCTAssertEqual(a.flashImage(sync: true), Data(), "a fresh boot differs from the package in no sector")
        var rec = Data(); var off = UInt32(0xFF000).littleEndian
        withUnsafeBytes(of: &off) { rec.append(contentsOf: $0) }
        rec.append(Data(repeating: 0x5a, count: 4096))
        let b = try EmuCore(package: pkg, id: "felucca", name: "Felucca", version: "1.8.2")
        b.boot(flash: rec)
        XCTAssertEqual(b.flashImage(sync: true), rec, "the saved sector comes back, and nothing else")
        XCTAssertFalse(a.isBooted, "one machine per process: the newer core took it over")
        a.key(0, down: true, velocity: 100)   // does nothing, and must not crash
    }

    func testAnRFM1IsNotAPackage() {
        XCTAssertThrowsError(try EmuCore(package: Data([0, 0x61, 0x73, 0x6d]), id: "x", name: "x", version: "1"))
    }

    func testButtonAndEncoderMapsCoverEveryControlOnce() {
        XCTAssertEqual(Set(FM1Button.allCases.map(EmuCore.matrixID)).count, 14)
        XCTAssertEqual(Set(FM1Button.allCases.map(EmuCore.matrixID)), Set(0...13))
        XCTAssertEqual(Set(FM1Encoder.allCases.map(EmuCore.encoderID)), Set(0...6))
    }
}
