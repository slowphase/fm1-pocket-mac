import Foundation
import XCTest
@testable import PocketKit

/// The emulator engine. Needs an original package: CI downloads Felucca from its maker's release
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

    private func energy(_ core: EmuCore, frames: Int) -> Double {
        var buf = [Float](repeating: 0, count: 2 * frames)
        buf.withUnsafeMutableBufferPointer { core.pull($0.baseAddress!, frames: frames) }
        return buf.reduce(0) { $0 + Double($1 * $1) }
    }

    /// Keys pressed between two audio buffers (a chord from the computer keyboard) all arrive: upstream's script
    /// call replaces its queue, which used to drop all but the last key. Needs a polyphonic synth (AMB-1).
    func testAChordPressedBetweenTwoBuffersPlaysEveryKey() throws {
        guard let dir = ProcessInfo.processInfo.environment["FM1_FWSC_DIR"],
              let pkg = FileManager.default.contents(atPath: dir + "/amb.fwsc") else { throw XCTSkip("no FM1_FWSC_DIR/amb.fwsc") }
        func play(_ keys: [Int]) -> Double {
            let c = try! EmuCore(package: pkg, id: "amb", name: "AMB-1", version: "t")
            c.boot(flash: nil)
            c.run(milliseconds: 8000)
            for k in keys { c.key(k, down: true, velocity: 110) }
            return energy(c, frames: 44100)
        }
        let chord = play([7, 11, 14]), last = play([14])
        XCTAssertGreaterThan(chord, 0.01)
        XCTAssertNotEqual(chord, last, accuracy: last * 0.001, "the chord sounds different from its last key alone")
    }

    /// A save is only taken once the firmware has finished writing (nil while it writes); a stop waits for it.
    /// Felucca's own save: SAVE, then OCT+ twice.
    func testASaveWaitsForTheFirmwareToFinishWriting() throws {
        let pkg = try package()
        let c = try EmuCore(package: pkg, id: "felucca", name: "Felucca", version: "1.8.2")
        c.boot(flash: nil)
        c.run(milliseconds: 8000)
        for b in [FM1Button.save, .octUp, .octUp] {
            c.button(b, down: true); c.run(milliseconds: 100); c.button(b, down: false); c.run(milliseconds: 800)
        }
        let rev = c.flashDirty
        XCTAssertGreaterThan(rev, 0, "Felucca wrote its user preset")
        // the moment of a write: no save yet
        let d = try EmuCore(package: pkg, id: "felucca", name: "Felucca", version: "1.8.2")
        d.boot(flash: nil)
        d.run(milliseconds: 8000)
        for b in [FM1Button.save, .octUp] { d.button(b, down: true); d.run(milliseconds: 100); d.button(b, down: false); d.run(milliseconds: 800) }
        d.button(.octUp, down: true); d.run(milliseconds: 100); d.button(.octUp, down: false)
        var waited = 0
        while d.flashDirty == 0 && waited < 3000 { d.run(milliseconds: 1); waited += 1 }
        XCTAssertGreaterThan(d.flashDirty, 0)
        XCTAssertNil(d.flashImage(sync: false), "no save while the firmware is writing")
        let saved = d.flashImage(sync: true)
        XCTAssertEqual(saved.map { $0.count % 4100 }, 0)
        XCTAssertGreaterThan(saved?.count ?? 0, 0, "a stop waits for the writes and keeps them")
        // and it comes back
        let e = try EmuCore(package: pkg, id: "felucca", name: "Felucca", version: "1.8.2")
        e.boot(flash: saved)
        XCTAssertEqual(e.flashImage(sync: true), saved)
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
