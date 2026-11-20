import FM1Host
import Foundation

/// The FM-1's 14 labelled buttons, in the ABI's order.
public enum FM1Button: Int32, CaseIterable, Identifiable {
    case fx = 0, sel, env, lfo, edit, glo, home, save, arp, seq, play, rec, octDown, octUp
    public var id: Int32 { rawValue }
    public var label: String {
        ["FX", "SEL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE", "ARP", "SEQ", "PLAY", "REC", "OCT-", "OCT+"][Int(rawValue)]
    }
}

/// The FM-1's encoders.
public enum FM1Encoder: Int32, CaseIterable, Identifiable {
    case select = 0, algorithm, presets, knob1, knob2, knob3, knob4
    public var id: Int32 { rawValue }
    public var label: String { ["SELECT", "ALGORITHM", "PRESETS", "KNOB 1", "KNOB 2", "KNOB 3", "KNOB 4"][Int(rawValue)] }
}

/// One running .rfm1 firmware, on the native wasm3 host (Sources/FM1Host). Thread-safe: the host serialises access,
/// so the audio thread can pull samples while the UI sends input or reads the screen.
public final class FirmwareCore: @unchecked Sendable {
    public static let sampleRate = 44100.0
    public static let screenSize = 240
    public static let keyCount = 27

    let h: OpaquePointer

    public init(bytes: Data) throws {
        var err = [CChar](repeating: 0, count: 400)
        let cap = err.count
        let ptr: OpaquePointer? = bytes.withUnsafeBytes { raw -> OpaquePointer? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return err.withUnsafeMutableBufferPointer { e in fm1h_create(base, raw.count, e.baseAddress, cap) }
        }
        guard let ptr else {
            let msg = String(cString: err)
            throw PocketError.badFirmware(msg.isEmpty ? "The firmware could not be loaded." : msg)
        }
        h = ptr
    }

    deinit { fm1h_destroy(h) }

    // MARK: facts
    public var abi: Int { Int(fm1h_abi(h)) }
    private func info(_ field: Int32) -> String { String(cString: fm1h_info(h, field)) }
    public var id: String { info(0) }
    public var name: String { info(1) }
    public var version: String { info(2) }
    public var sourceURL: String { info(3) }
    public var family: String { info(4) }
    public var license: String { info(5) }
    public var credits: String { info(6) }
    public func buttonName(_ b: FM1Button) -> String { String(cString: fm1h_button_name(h, b.rawValue)) }
    public var flashSize: Int { Int(fm1h_flash_size(h)) }

    // MARK: power and clock
    public func boot(flash: Data?) {
        if let flash, !flash.isEmpty {
            flash.withUnsafeBytes { raw in fm1h_boot(h, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
        } else {
            fm1h_boot(h, nil, 0)
        }
    }
    public func run(milliseconds: Int) { fm1h_run_ms(h, Int32(milliseconds)) }
    /// Fills `frames` interleaved stereo frames (2 floats each) at 44.1 kHz, running the device clock as needed.
    public func pull(_ out: UnsafeMutablePointer<Float>, frames: Int) { fm1h_pull(h, out, Int32(frames)) }
    public func pull(frames: Int) -> [Float] {
        var a = [Float](repeating: 0, count: frames * 2)
        a.withUnsafeMutableBufferPointer { fm1h_pull(h, $0.baseAddress, Int32(frames)) }
        return a
    }
    public var deviceMilliseconds: Int { Int(fm1h_device_ms(h)) }

    // MARK: panel
    public func key(_ k: Int, down: Bool, velocity: Int = 100) { fm1h_key(h, Int32(k), down ? 1 : 0, Int32(velocity)) }
    public func button(_ b: FM1Button, down: Bool) { fm1h_button(h, b.rawValue, down ? 1 : 0) }
    public func turn(_ e: FM1Encoder, by detents: Int) { fm1h_turn(h, e.rawValue, Int32(detents)) }
    public func setMaster(_ value: Int) { fm1h_set_master(h, Int32(value)) }
    @discardableResult
    public func midi(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> Bool { fm1h_midi(h, status, d1, d2) != 0 }

    /// Copies the 240x240 screen as RGBA8 into `buffer` (resized if needed); returns the panel's write counter.
    @discardableResult
    public func screen(into buffer: inout [UInt8]) -> UInt32 {
        let n = Self.screenSize * Self.screenSize * 4
        if buffer.count != n { buffer = [UInt8](repeating: 0, count: n) }
        return buffer.withUnsafeMutableBufferPointer { fm1h_screen_rgba(h, $0.baseAddress) }
    }
    public var lcdWrites: UInt32 { fm1h_lcd_writes(h) }

    public struct LEDs: Equatable { public var buttons: [UInt8]; public var keys: [UInt8]; public var playGreen: UInt8 }
    public func leds() -> LEDs {
        var b = [UInt8](repeating: 0, count: 14), k = [UInt8](repeating: 0, count: Self.keyCount), g: UInt8 = 0
        b.withUnsafeMutableBufferPointer { bp in k.withUnsafeMutableBufferPointer { kp in fm1h_leds(h, bp.baseAddress, kp.baseAddress, &g) } }
        return LEDs(buttons: b, keys: k, playGreen: g)
    }

    // MARK: flash (the firmware's saved settings)
    public var flashDirty: UInt32 { fm1h_flash_dirty(h) }
    public func flashImage(sync: Bool) -> Data? {
        let size = flashSize
        guard size > 0 else { return nil }
        var d = Data(count: size)
        let n = d.withUnsafeMutableBytes { raw in fm1h_flash_copy(h, sync ? 1 : 0, raw.bindMemory(to: UInt8.self).baseAddress, size) }
        return n > 0 ? d.prefix(n) : nil
    }
    public func shutdown() { fm1h_shutdown(h) }

    // MARK: health
    /// 0 while running; otherwise why it stopped (see fm1host.h)
    public var haltCode: Int { Int(fm1h_halted(h)) }
    public var isHalted: Bool { haltCode != 0 }
    public var errorMessage: String { String(cString: fm1h_error(h)) }
    public func takeLog() -> String {
        var buf = [CChar](repeating: 0, count: 8192)
        let cap = buf.count
        _ = buf.withUnsafeMutableBufferPointer { fm1h_log_take(h, $0.baseAddress, cap) }
        return String(cString: buf)
    }
}

// MARK: - optional extras (sim1, live labels, stats)

extension FirmwareCore {
    /// What an encoder role is tied to right now, for firmware with the sim1 extension.
    public struct Control: Equatable, Sendable {
        /// true: a value a slider or knob may set outright; false: a relative encoder (name and text still show)
        public var absolute: Bool
        public var value: Int
        public var lo: Int
        public var hi: Int
        public var name: String
        public var text: String

        public init(absolute: Bool, value: Int, lo: Int, hi: Int, name: String, text: String) {
            self.absolute = absolute; self.value = value; self.lo = lo; self.hi = hi; self.name = name; self.text = text
        }
    }

    /// the sim1 version, 0 without it
    public var sim1Version: Int { Int(fm1h_sim1(h)) }

    public func control(_ role: FM1Encoder) -> Control? {
        var c = fm1h_ctl()
        let r = fm1h_ctl_info(h, role.rawValue, &c)
        guard r >= 0 else { return nil }
        func str<T>(_ t: T) -> String {
            withUnsafeBytes(of: t) { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[0..<end], as: UTF8.self)
            }
        }
        return Control(absolute: r == 1, value: Int(c.value), lo: Int(c.lo), hi: Int(c.hi), name: str(c.name), text: str(c.text))
    }

    public func setControl(_ role: FM1Encoder, to value: Int) { fm1h_ctl_set(h, role.rawValue, Int32(clamping: value)) }

    /// the firmware's accent colour right now (0xRRGGBB), if it gives one
    public var accent: UInt32? {
        let a = fm1h_accent(h)
        return a < 0 ? nil : UInt32(a) & 0xffffff
    }
    /// bytes the last frame sent to the panel, if the firmware reports it
    public var linkBytes: Int? {
        let b = fm1h_link_bytes(h)
        return b < 0 ? nil : Int(b)
    }
    /// bytes of the screen that changed at the last `screen(into:)`
    public var screenChangedBytes: Int { Int(fm1h_screen_changed_bytes(h)) }
    /// the MASTER pot (0...1023) as the panel holds it
    public var master: Int { Int(fm1h_master(h)) }

    /// 0 when the firmware gives no live labels; changes whenever one changes
    public var labelsEpoch: UInt32 { fm1h_labels_epoch(h) }

    /// The 49 live labels: 0..7 the knob roles and MASTER, 8..21 the buttons, 22..37 the white keys, 38..48 the
    /// black keys. nil = not given, "" = no job right now.
    public func labels() -> [String?] {
        var buf = [CChar](repeating: 0, count: 20)
        let cap = Int32(buf.count)
        return (0..<49).map { i in
            let n = buf.withUnsafeMutableBufferPointer { fm1h_label(h, Int32(i), $0.baseAddress, cap) }
            return n < 0 ? nil : String(cString: buf)
        }
    }

    /// the firmware's own CPU figure (percent) and shed count, if it reports them
    public func stats() -> (cpu: Int, shed: Int)? {
        var shed: UInt32 = 0, cpu: UInt32 = 0
        return fm1h_stats(h, &shed, &cpu) != 0 ? (Int(cpu), Int(shed)) : nil
    }
}
