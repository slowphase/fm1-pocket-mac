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

    private let h: OpaquePointer

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
