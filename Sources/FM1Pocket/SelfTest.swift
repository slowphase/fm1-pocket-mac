import Foundation
import PocketKit

/// `FM1Pocket --selftest [result.json]`: boots the bundled h1 inside the built app, without a window or sound, and
/// checks that it draws and plays. GitHub Actions runs it on the packaged .app before making the DMG.
enum SelfTest {
    static func run(writingTo path: String?) -> Int32 {
        var r: [String: Any] = [:]
        var ok = false
        do {
            guard let url = Bundle.main.url(forResource: "h1", withExtension: "rfm1") else {
                throw PocketError.badFirmware("h1.rfm1 is missing from the app bundle")
            }
            let bytes = try Data(contentsOf: url)
            let file = try RFM1File(bytes)
            let start = Date()
            let core = try FirmwareCore(bytes: bytes)
            core.boot(flash: nil)
            core.run(milliseconds: 1500)
            var px: [UInt8] = []
            core.screen(into: &px)
            var lit = 0
            for i in stride(from: 0, to: px.count, by: 4) where px[i] | px[i + 1] | px[i + 2] != 0 { lit += 1 }
            for k in [7, 11, 14] { core.key(k, down: true) }
            core.run(milliseconds: 50)
            let a = core.pull(frames: 22050)
            let rms = (a.reduce(0) { $0 + Double($1 * $1) } / Double(a.count)).squareRoot()
            let wall = Date().timeIntervalSince(start)
            // steady-state speed: 10 s of device time with the chord held, pulled in 512-frame buffers like Core Audio
            var buf = [Float](repeating: 0, count: 1024)
            let t0 = Date()
            for _ in 0..<(441000 / 512) { buf.withUnsafeMutableBufferPointer { core.pull($0.baseAddress!, frames: 512) } }
            let speed = 10.0 / max(Date().timeIntervalSince(t0), 0.001)
            ok = !core.isHalted && lit > 0 && rms > 0.001 && speed > 1.5
            r = ["firmware": "\(file.name) \(file.version)", "halted": core.haltCode, "litPixels": lit,
                 "playedRms": rms, "bootSeconds": wall, "speedXRealtime": speed]
        } catch {
            r["error"] = error.localizedDescription
        }
        r["ok"] = ok
        let json = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        if let path { try? json.write(to: URL(fileURLWithPath: path)) }
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        return ok ? 0 : 1
    }

    /// `FM1Pocket --selftest-fwsc PACKAGE.fwsc [result.json]` (evaluation): the same checks on the emulator engine,
    /// with an original package: boots, draws, sounds from keys / MIDI / PLAY, keeps up, and a save survives a reboot.
    static func runPackage(_ pkg: String, writingTo path: String?) -> Int32 {
        var r: [String: Any] = ["package": pkg, "engine": "fm1-emu \(EmuCore.upstreamCommit.prefix(7))"]
        var ok = false
        do {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: pkg))
            r["sha256"] = sha256Hex(bytes)
            let core = try EmuCore(package: bytes, id: "selftest", name: "selftest", version: "0")
            let start = Date()
            core.boot(flash: nil)
            guard core.isBooted else { throw PocketError.badFirmware("the package did not unpack") }
            var buf = [Float](repeating: 0, count: 1024)
            func rms(_ seconds: Double) -> Double {
                var s = 0.0, n = 0
                for _ in 0..<Int(seconds * 44100 / 512) {
                    buf.withUnsafeMutableBufferPointer { core.pull($0.baseAddress!, frames: 512) }
                    for x in buf { s += Double(x * x) }; n += buf.count
                }
                return (s / Double(max(n, 1))).squareRoot()
            }
            _ = rms(3)
            var px: [UInt8] = []
            core.screen(into: &px)
            var lit = 0
            for i in stride(from: 0, to: px.count, by: 4) where px[i] | px[i + 1] | px[i + 2] > 24 { lit += 1 }
            for k in [7, 11, 14] { core.key(k, down: true, velocity: 110) }
            let keys = rms(1)
            for k in [7, 11, 14] { core.key(k, down: false, velocity: 0) }
            _ = rms(0.3)
            core.midi(0x90, 60, 110); let midi = rms(0.5); core.midi(0x80, 60, 0)
            core.button(.play, down: true); _ = rms(0.1); core.button(.play, down: false)
            let play = rms(4)
            core.button(.play, down: true); _ = rms(0.1); core.button(.play, down: false)
            let t0 = Date()
            _ = rms(10)
            let speed = 10.0 / max(Date().timeIntervalSince(t0), 0.001)
            // a save survives a reboot: one sector, in upstream's record format, restored and read back
            var rec = Data(); var off = UInt32(0xFF000).littleEndian
            withUnsafeBytes(of: &off) { rec.append(contentsOf: $0) }
            rec.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }))
            let again = try EmuCore(package: bytes, id: "selftest", name: "selftest", version: "0")
            again.boot(flash: rec)
            let back = again.flashImage(sync: true) ?? Data()
            let saveOK = back.range(of: rec) != nil
            let sounds = keys > 0.0002 || midi > 0.0002 || play > 0.0002
            ok = !again.isHalted && lit > 0 && sounds && saveOK
            r.merge(["halted": again.haltCode, "litPixels": lit, "keysRms": keys, "midiRms": midi, "playRms": play,
                     "speedXRealtime": speed, "saveRoundTrip": saveOK, "seconds": Date().timeIntervalSince(start)]) { $1 }
        } catch {
            r["error"] = error.localizedDescription
        }
        r["ok"] = ok
        let json = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        if let path { try? json.write(to: URL(fileURLWithPath: path)) }
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        return ok ? 0 : 1
    }
}
