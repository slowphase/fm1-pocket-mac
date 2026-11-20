import Foundation
import XCTest
@testable import PocketKit

private func h1() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/h1.rfm1"))
}

/// a minimal WebAssembly file holding just these custom sections
private func wasm(custom: [(String, Data)]) -> Data {
    func leb(_ v: Int) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }
    var d = Data([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])
    for (name, body) in custom {
        let n = Array(name.utf8)
        let payload = leb(n.count) + n + [UInt8](body)
        d.append(0)
        d.append(contentsOf: leb(payload.count))
        d.append(contentsOf: payload)
    }
    return d
}

final class FaceplateTests: XCTestCase {
    /// h1 has the sim1 extension: its knobs report what they are tied to, and can be set outright
    func testH1ControlsAndAccent() throws {
        let core = try FirmwareCore(bytes: h1())
        core.boot(flash: nil)
        core.run(milliseconds: 1500)
        XCTAssertEqual(core.sim1Version, 1)
        let tempo = try XCTUnwrap(core.control(.select))
        XCTAssertTrue(tempo.absolute)
        XCTAssertEqual(tempo.name, "TEMPO")
        XCTAssertEqual(tempo.lo, 40)
        XCTAssertEqual(tempo.hi, 240)
        core.setControl(.select, to: 150)
        core.run(milliseconds: 50)
        XCTAssertEqual(core.control(.select)?.value, 150, "a sim1 value is set outright")
        XCTAssertTrue(core.control(.select)?.text.contains("150") ?? false)
        for e in FM1Encoder.allCases { XCTAssertNotNil(core.control(e), "\(e.label) reports a control") }
        XCTAssertNotNil(core.accent, "h1 gives an accent colour")
        XCTAssertEqual(core.labelsEpoch, 0, "h1 has no live labels")
        XCTAssertNotNil(core.stats())
        // MASTER: what the firmware set, then what the panel sets
        XCTAssertTrue((0...1023).contains(core.master))
        core.setMaster(300)
        XCTAssertEqual(core.master, 300)
        var px: [UInt8] = []
        core.screen(into: &px)
        XCTAssertGreaterThan(core.screenChangedBytes, 0, "the first screen copy counts every changed row")
        core.screen(into: &px)
        XCTAssertEqual(core.screenChangedBytes, 0, "nothing changed since")
        XCTAssertFalse(core.isHalted, core.errorMessage)
    }

    func testRelativeEncoderStillTurns() throws {
        let core = try FirmwareCore(bytes: h1())
        core.boot(flash: nil)
        core.run(milliseconds: 1000)
        let before = try XCTUnwrap(core.control(.knob1)).value
        core.turn(.knob1, by: 3)
        core.run(milliseconds: 50)
        XCTAssertNotEqual(core.control(.knob1)?.value, before, "detents move the value too")
    }

    func testSkinIsRead() throws {
        let manifest = Data(#"{"rfm1":1,"abi":6,"id":"t","name":"T","version":"1","license":"MIT","source_url":"https://x"}"#.utf8)
        let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let f = try RFM1File(wasm(custom: [
            ("rfm1", manifest),
            ("rfm1.skin", Data(#"{"skin":1,"dim":0.9,"theme":{"led":"#ff8800","body":"#101010","knob":"bad"}}"#.utf8)),
            ("rfm1.skin.background", png),
        ]))
        let skin = try XCTUnwrap(f.skin)
        XCTAssertEqual(skin.led, "#ff8800")
        XCTAssertEqual(skin.body, "#101010")
        XCTAssertEqual(skin.dim, 0.8, "dim is capped at 0.8")
        XCTAssertEqual(skin.wideImage, png)
        XCTAssertNil(try RFM1File(h1()).skin, "h1 has no skin")
        let plain = try RFM1File(wasm(custom: [("rfm1", manifest)]))
        XCTAssertNil(plain.skin)
    }

    func testMIDIParsing() {
        // UMP: a MIDI 1.0 note on (type 2), a system message (type 1, skipped), a MIDI 2.0 note (type 4, two words, skipped),
        // a pitch bend, a program change
        let words: [UInt32] = [0x2090_3C64, 0x10F8_0000, 0x4090_3C00, 0xFFFF_0000, 0x20E0_0040, 0x20C1_0500]
        let m = MIDIInput.channelMessages(words)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m[0].0, 0x90); XCTAssertEqual(m[0].1, 60); XCTAssertEqual(m[0].2, 100)
        XCTAssertEqual(m[1].0, 0xE0); XCTAssertEqual(m[1].2, 0x40)
        XCTAssertEqual(m[2].0, 0xC1); XCTAssertEqual(m[2].1, 5)
        XCTAssertTrue(MIDIInput.channelMessages([]).isEmpty)
    }

    func testMIDINoteThroughTheCore() throws {
        let core = try FirmwareCore(bytes: h1())
        core.boot(flash: nil)
        core.run(milliseconds: 800)
        _ = core.pull(frames: 4410)
        for (s, d1, d2) in MIDIInput.channelMessages([0x2090_4064]) { core.midi(s, d1, d2) }
        let a = core.pull(frames: 22050)
        let rms = (a.reduce(0.0) { $0 + Double($1 * $1) } / Double(a.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.005)
    }

    func testEraseAndLoadByKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fm1state-\(UUID().uuidString)")
        let s = StateStore(folder: dir)
        let sha = String(repeating: "c", count: 64)
        try s.save(Data([1]), id: "x", version: "2.0", sha256: sha)
        try s.save(Data([2]), id: "x", version: "2.0", sha256: sha)                // and a .prev backup
        try s.save(Data([9]), id: "x", version: "1.0", sha256: String(repeating: "d", count: 64))
        let key = StateStore.buildKey(version: "1.0", sha256: String(repeating: "d", count: 64))
        XCTAssertEqual(s.load(id: "x", key: key), Data([9]))
        XCTAssertNil(s.load(id: "x", key: "../escape"))
        try s.erase(id: "x", version: "2.0", sha256: sha)
        XCTAssertNil(s.load(id: "x", version: "2.0", sha256: sha), "the save and its backup are gone")
        XCTAssertEqual(s.load(id: "x", key: key), Data([9]), "other builds' saves are untouched")
    }
}
