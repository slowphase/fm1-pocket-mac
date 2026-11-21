import CFM1Emu
import Foundation

/// An author's original FM-1 update package (.fwsc) running on upstream fm1-emu (joakimeriksson/fm1-emu, MIT), its
/// own C functions linked unchanged (Sources/CFM1Emu). The second engine beside FirmwareCore.
///
/// Upstream keeps one machine per process, so only one EmuCore may exist at a time: a new one takes the machine
/// over, and every call on an older one does nothing. Calls are serialised with a lock, so the audio thread can
/// render while the UI sends input or reads the screen.
public final class EmuCore: @unchecked Sendable {
    public static let flashBytes = 1 << 20
    private static let lock = NSLock()
    private static var current: ObjectIdentifier?

    public let engine = "fm1-emu"
    public let id: String
    public let name: String
    public let version: String
    public let license: String
    public let sourceURL: String
    public let credits: String
    public var family: String { "fm1-emu \(Self.upstreamCommit.prefix(7))" }
    public let abi = 0
    public let sim1Version = 0
    /// Emu/Cargo.toml's pin
    public static let upstreamCommit = "09aeae3e9d78db52c3b9f5ceed93bd1120ccf444"

    private let package: Data
    private var booted = false
    /// the firmware's audio has started (upstream's worklet then caps a render at 1.5 quanta)
    private var playing = false

    /// upstream's run budgets (web/worklet.js): while the firmware boots, 20 ms of emulated time per render, so a
    /// firmware with no audio yet cannot hold the caller; once audio plays, 1.5 times the frames asked for
    private func budget(_ frames: Int) -> UInt32 {
        playing ? UInt32(240e6 * 1.5 * Double(frames) / 44100) : UInt32(240e6 * 0.02)
    }
    private func render(_ n: Int) -> Int {
        let got = Int(fm1_render(UInt32(n), budget(n)))
        if got > 0 { playing = true }
        // every scripted key event queued before this render has now been delivered (each is due "now")
        pendingKeys.removeAll(keepingCapacity: true)
        let rev = fm1_flash_revision()
        if rev != lastFlashRevision { lastFlashRevision = rev; flashChangedMs = fm1_ms() }
        return got
    }
    /// Scripted key events not yet delivered. Upstream's script call replaces the whole queue, so each new event is
    /// queued together with those still waiting; otherwise two keys pressed between two renders (a chord from the
    /// computer keyboard) would lose the first, and a quick tap's release could overtake its press.
    private var pendingKeys: [String] = []
    /// the emulated time of the last flash write, so a save is only taken once the firmware has finished writing
    private var flashChangedMs: UInt32 = 0
    private func queueKey(_ event: String) {
        pendingKeys.append(event)
        let s = Array(pendingKeys.joined(separator: ",").utf8)
        if let p = fm1_alloc(UInt32(s.count)) { p.update(from: s, count: s.count); _ = fm1_bench_script(p, UInt32(s.count)) }
    }
    private var masterValue = 512
    private var lastFlashRevision: UInt32 = 0

    /// `package`: the .fwsc bytes; the rest describes it (a package carries no manifest).
    public init(package: Data, id: String, name: String, version: String, license: String = "", sourceURL: String = "",
                credits: String = "") throws {
        guard package.count > 4096 else { throw PocketError.badFirmware("That file is not an FM-1 update package (.fwsc).") }
        self.package = package
        self.id = id; self.name = name; self.version = version; self.license = license; self.sourceURL = sourceURL
        self.credits = credits.isEmpty ? "Runs on fm1-emu by Joakim Eriksson (MIT), https://github.com/joakimeriksson/fm1-emu" : credits
    }

    private var mine: Bool { Self.current == ObjectIdentifier(self) }
    @discardableResult private func locked<T>(_ fallback: T, _ body: () -> T) -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return mine && booted ? body() : fallback
    }

    /// Boots the package; `flash`: a save from saveRecords (upstream's record format: 4-byte little-endian offset +
    /// a 4096-byte sector, for each sector that differs from the package's own).
    public func boot(flash: Data?) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let n = UInt32(package.count)
        guard let p = fm1_alloc(n) else { return }
        package.withUnsafeBytes { raw in p.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: package.count) }
        fm1_jit(1, 0)
        fm1_ahead(1024)
        if fm1_boot_fwsc(p, n, nil, 0, 240) != 0 { booted = false; return }
        Self.current = ObjectIdentifier(self)
        booted = true
        playing = false
        if let flash, !flash.isEmpty, flash.count % (4096 + 4) == 0, let r = fm1_alloc(UInt32(flash.count)) {
            flash.withUnsafeBytes { raw in r.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: flash.count) }
            _ = fm1_flash_restore(r, UInt32(flash.count))
        }
        fm1_pot(UInt32(masterValue))
        lastFlashRevision = fm1_flash_revision()
        flashChangedMs = 0
        pendingKeys = []
    }

    public var isBooted: Bool { Self.lock.lock(); defer { Self.lock.unlock() }; return booted && mine }

    public func run(milliseconds: Int) {
        let frames = max(0, milliseconds) * 441 / 10
        var left = frames
        while left > 0 { let n = min(left, 1024); locked(()) { _ = render(n) }; left -= n }
    }

    /// Interleaved stereo at 44.1 kHz, as FirmwareCore.pull.
    public func pull(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(frames - done, 1024)
            let ok: Bool = locked(false) {
                _ = render(n)
                guard let l = fm1_out_l(), let r = fm1_out_r() else { return false }
                for i in 0..<n { out[2 * (done + i)] = l[i]; out[2 * (done + i) + 1] = r[i] }
                return true
            }
            if !ok { for i in 0..<n { out[2 * (done + i)] = 0; out[2 * (done + i) + 1] = 0 } }
            done += n
        }
    }

    public func shutdown() { Self.lock.lock(); booted = false; Self.lock.unlock() }

    // MARK: panel (upstream's matrix ids: 0 OCT-, 1 OCT+, 2 FX, 3 SCL, 4 ENV, 5 LFO, 6 EDIT, 7 GLO, 8 HOME, 9 SAVE,
    // 10 ARP, 11 SEQ, 12 PLAY, 13 REC; 14 + n the note keys from F3)
    static func matrixID(_ b: FM1Button) -> UInt32 {
        switch b {
        case .octDown: return 0
        case .octUp: return 1
        case .fx: return 2
        case .sel: return 3
        case .env: return 4
        case .lfo: return 5
        case .edit: return 6
        case .glo: return 7
        case .home: return 8
        case .save: return 9
        case .arp: return 10
        case .seq: return 11
        case .play: return 12
        case .rec: return 13
        }
    }
    /// upstream's encoders: 0 SELECT, 1 ALGORITHM, 2..5 K1..K4, 6 PRESETS
    static func encoderID(_ e: FM1Encoder) -> UInt32 {
        switch e {
        case .select: return 0
        case .algorithm: return 1
        case .presets: return 6
        case .knob1: return 2
        case .knob2: return 3
        case .knob3: return 4
        case .knob4: return 5
        }
    }

    public func key(_ k: Int, down: Bool, velocity: Int) {
        guard k >= 0, k < FirmwareCore.keyCount else { return }
        locked(()) {
            // presses and releases both go through upstream's input script, in order: the velocity has no other way
            // in (Action::KeyVel), and a release sent directly could overtake a press still waiting in the script
            let ms = fm1_ms()
            queueKey(down ? "\(ms):\(14 + k)@\(max(1, min(127, velocity)))" : "\(ms):\(14 + k)^")
        }
    }
    public func button(_ b: FM1Button, down: Bool) { locked(()) { fm1_key(Self.matrixID(b), down ? 1 : 0) } }
    public func turn(_ e: FM1Encoder, by detents: Int) { locked(()) { fm1_enc(Self.encoderID(e), Int32(clamping: detents)) } }
    public func setMaster(_ value: Int) {
        masterValue = max(0, min(1023, value))
        locked(()) { fm1_pot(UInt32(masterValue)) }
    }
    public var master: Int { masterValue }
    @discardableResult
    public func midi(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> Bool {
        let n = status >= 0xc0 && status < 0xe0 ? 2 : 3
        return locked(false) {
            fm1_midi(UInt32(status)); fm1_midi(UInt32(d1)); if n == 3 { fm1_midi(UInt32(d2)) }
            return true
        }
    }
    public func buttonName(_ b: FM1Button) -> String { b.label }
    public func control(_ role: FM1Encoder) -> FirmwareCore.Control? { nil }
    public func setControl(_ role: FM1Encoder, to value: Int) {}

    // MARK: screen and lights
    @discardableResult
    public func screen(into buffer: inout [UInt8]) -> UInt32 {
        let n = FirmwareCore.screenSize * FirmwareCore.screenSize
        if buffer.count != n * 4 { buffer = [UInt8](repeating: 0, count: n * 4) }
        return buffer.withUnsafeMutableBufferPointer { out -> UInt32 in
            locked(0) {
                guard let fb = fm1_lcd() else { return 0 }
                for i in 0..<n {
                    let p = fb[i]
                    out[4 * i] = UInt8((p >> 11) & 31) << 3 | UInt8((p >> 13) & 7)
                    out[4 * i + 1] = UInt8((p >> 5) & 63) << 2 | UInt8((p >> 9) & 3)
                    out[4 * i + 2] = UInt8(p & 31) << 3 | UInt8((p >> 2) & 7)
                    out[4 * i + 3] = 255
                }
                return fm1_lcd_revision()
            }
        }
    }
    public var lcdWrites: UInt32 { locked(0) { fm1_lcd_revision() } }
    public var linkBytes: Int? { nil }
    public var screenChangedBytes: Int { 0 }
    public func leds() -> FirmwareCore.LEDs {
        locked(FirmwareCore.LEDs(buttons: .init(repeating: 0, count: 14), keys: .init(repeating: 0, count: 27), playGreen: 0)) {
            guard let l = fm1_leds() else {
                return FirmwareCore.LEDs(buttons: .init(repeating: 0, count: 14), keys: .init(repeating: 0, count: 27), playGreen: 0)
            }
            let v = { (i: Int) -> UInt8 in UInt8(max(0, min(1, l[i])) * 255) }
            let buttons = FM1Button.allCases.map { v(Int(Self.matrixID($0))) }
            let keys = (0..<27).map { v(14 + $0) }
            return FirmwareCore.LEDs(buttons: buttons, keys: keys, playGreen: 0)
        }
    }
    public var labelsEpoch: UInt32 { 0 }
    public func labels() -> [String?] { [] }
    public var accent: UInt32? { nil }
    public func stats() -> (cpu: Int, shed: Int)? { nil }

    // MARK: saved settings: the sectors that differ from the package's own flash, in upstream's record format
    /// the largest save: every sector as a record (an imported settings file is checked against this)
    public var flashSize: Int { (Self.flashBytes / 4096) * (4096 + 4) }
    public var flashDirty: UInt32 { locked(0) { fm1_flash_revision() } }
    /// The firmware has finished writing: no write in progress and none for 250 ms of emulated time (upstream's web
    /// player waits the same before it keeps a save), so a save never holds a half-written sector.
    private var flashQuiet: Bool { fm1_flash_busy() == 0 && fm1_ms() &- flashChangedMs >= 250 }
    /// The save: `nil` while the firmware is still writing (unless `sync`). With `sync` (stopping, quitting,
    /// switching), the emulated FM-1 runs on, silently, for up to 1.5 s of its time until its writes finish.
    public func flashImage(sync: Bool) -> Data? {
        locked(nil) {
            if !flashQuiet {
                guard sync else { return nil }
                var waited = 0
                while !flashQuiet && waited < 1500 { _ = render(441); waited += 10 }
            }
            guard let now = fm1_flash(), let base = fm1_flash_base() else { return nil }
            let len = Int(fm1_flash_len())
            var out = Data()
            var at = 0
            while at < len {
                if memcmp(now + at, base + at, 4096) != 0 {
                    var off = UInt32(at).littleEndian
                    withUnsafeBytes(of: &off) { out.append(contentsOf: $0) }
                    out.append(now + at, count: 4096)
                }
                at += 4096
            }
            return out
        }
    }

    public var haltCode: Int { locked(0) { Int(fm1_halted()) } }
    public var isHalted: Bool { haltCode != 0 }
    public var errorMessage: String { isHalted ? "the emulated FM-1 stopped (a CPU exception)" : "" }
    public func takeLog() -> String { "" }
}

extension EmuCore: PlayerEngine {}
