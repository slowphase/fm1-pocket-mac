import Foundation

/// What the player needs from an engine. Two engines:
///   FirmwareCore  an .rfm1 build on the native wasm3 host (Sources/FM1Host), the app's engine since Milestone 1;
///   EmuCore       an author's original .fwsc package on upstream fm1-emu (Sources/CFM1Emu, MIT).
/// Saved settings are kept apart per engine: StateStore keys an emulator save as "fm1-emu+VERSION@SHA12", so an
/// .rfm1 save and an emulator save of the same firmware never meet (their flash layouts are not the same thing).
public protocol PlayerEngine: AnyObject, Sendable {
    /// "rfm1" or "fm1-emu"
    var engine: String { get }
    var id: String { get }
    var name: String { get }
    var version: String { get }
    var license: String { get }
    var sourceURL: String { get }
    var credits: String { get }
    var family: String { get }
    var abi: Int { get }
    var sim1Version: Int { get }

    func boot(flash: Data?)
    func run(milliseconds: Int)
    func pull(_ out: UnsafeMutablePointer<Float>, frames: Int)
    func shutdown()

    func key(_ k: Int, down: Bool, velocity: Int)
    func button(_ b: FM1Button, down: Bool)
    func turn(_ e: FM1Encoder, by detents: Int)
    func setMaster(_ value: Int)
    @discardableResult func midi(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> Bool
    var master: Int { get }
    func buttonName(_ b: FM1Button) -> String
    func control(_ role: FM1Encoder) -> FirmwareCore.Control?
    func setControl(_ role: FM1Encoder, to value: Int)

    @discardableResult func screen(into buffer: inout [UInt8]) -> UInt32
    var lcdWrites: UInt32 { get }
    var linkBytes: Int? { get }
    var screenChangedBytes: Int { get }
    func leds() -> FirmwareCore.LEDs
    var labelsEpoch: UInt32 { get }
    func labels() -> [String?]
    var accent: UInt32? { get }
    func stats() -> (cpu: Int, shed: Int)?

    var flashSize: Int { get }
    var flashDirty: UInt32 { get }
    func flashImage(sync: Bool) -> Data?

    var haltCode: Int { get }
    var isHalted: Bool { get }
    var errorMessage: String { get }
    func takeLog() -> String
}

extension FirmwareCore: PlayerEngine {
    public var engine: String { "rfm1" }
}
