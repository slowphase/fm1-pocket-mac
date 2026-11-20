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
}
