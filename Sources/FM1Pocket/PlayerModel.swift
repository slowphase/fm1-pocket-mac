import AppKit
import Foundation
import PocketKit

/// The running firmware: its sound, its screen and lights, its saved settings, and input from the computer keyboard.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var playingID: LibraryItem.ID?
    @Published private(set) var title = ""
    @Published private(set) var screen: CGImage?
    @Published private(set) var leds: FirmwareCore.LEDs?
    @Published private(set) var buttonNames: [String] = FM1Button.allCases.map(\.label)
    @Published private(set) var heldKeys: Set<Int> = []
    @Published private(set) var loadingID: LibraryItem.ID?
    @Published var error: String?

    private var core: FirmwareCore?
    private var flashID = "", flashVersion = "", flashSHA = ""
    private var activeIn: FirmwareLibrary?          // the library told this build is playing (so cleanup keeps it)
    private var flashSeen: UInt32 = 0
    private let audio = AudioOutput()
    private let states = StateStore()
    private var timer: Timer?
    private var lastWrites: UInt32 = .max
    private var pixels: [UInt8] = []
    private var ticks = 0
    private var keyMonitor: Any?
    private var keyHeld: [UInt16: Int] = [:]

    func play(_ item: LibraryItem, library: LibraryModel) {
        error = nil
        loadingID = item.id
        Task {
            defer { loadingID = nil }
            do {
                let fw = try await library.playable(for: item)
                let next = try FirmwareCore(bytes: fw.data)
                stop()
                // saved settings belong to this exact build (id, version and content hash); never another build's
                let saved = states.load(id: next.id, version: next.version, sha256: fw.sha256)
                if let catID = fw.catalogueID {
                    let mine = StateStore.buildKey(version: next.version, sha256: fw.sha256)
                    let other = saved == nil ? states.savedKeys(id: next.id).first(where: { $0 != mine }) : nil
                    await library.library.noteStateFromOtherBuild(id: catID, otherKey: other)
                    await library.library.markActive(sha256: fw.sha256)
                    activeIn = library.library
                }
                next.boot(flash: saved)
                if next.isHalted { throw PocketError.badFirmware("\(item.name) stopped while starting: \(next.errorMessage)") }
                core = next
                flashID = next.id
                flashVersion = next.version
                flashSHA = fw.sha256
                flashSeen = next.flashDirty
                title = "\(item.name) \(fw.version)" + (fw.isFallback ? " (previous download: the update could not be fetched)" : "")
                buttonNames = FM1Button.allCases.map { next.buttonName($0) }
                playingID = item.id
                lastWrites = .max
                do { try audio.start(next) } catch { self.error = "No sound: \(error.localizedDescription)" }
                startTimer()
                installKeyboard()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        saveFlash(sync: true)
        core?.shutdown()
        audio.stop()
        if let lib = activeIn {
            let sha = flashSHA
            Task { await lib.markInactive(sha256: sha) }
            activeIn = nil
        }
        timer?.invalidate()
        timer = nil
        core = nil
        playingID = nil
        screen = nil
        leds = nil
        heldKeys = []
        keyHeld = [:]
    }

    /// saves the firmware's flash when it changed (sync: ask the firmware to finish its writes first)
    func saveFlash(sync: Bool) {
        guard let core, !core.isHalted else { return }
        let d = core.flashDirty
        if d == flashSeen && !sync { return }
        if let img = core.flashImage(sync: sync) {
            do { try states.save(img, id: flashID, version: flashVersion, sha256: flashSHA) } catch { self.error = "Could not save settings: \(error.localizedDescription)" }
        }
        flashSeen = core.flashDirty
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        guard let core else { return }
        if !audio.isRunning { core.run(milliseconds: 33) }      // no sound device: keep the clock going anyway
        let w = core.lcdWrites
        if w != lastWrites {
            lastWrites = core.screen(into: &pixels)
            screen = Self.image(pixels)
        }
        let l = core.leds()
        if l != leds { leds = l }
        ticks += 1
        if ticks % 30 == 0 { saveFlash(sync: false) }
        if core.isHalted && error == nil { error = "The firmware stopped: \(core.errorMessage)" }
    }

    static func image(_ rgba: [UInt8]) -> CGImage? {
        let n = FirmwareCore.screenSize
        guard rgba.count == n * n * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: input
    func key(_ k: Int, down: Bool) {
        guard let core else { return }
        if down { if heldKeys.insert(k).inserted { core.key(k, down: true, velocity: 100) } }
        else if heldKeys.remove(k) != nil { core.key(k, down: false) }
    }
    func button(_ b: FM1Button, down: Bool) { core?.button(b, down: down) }
    func tap(_ b: FM1Button) {
        button(b, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.button(b, down: false) }
    }
    func turn(_ e: FM1Encoder, _ d: Int) { core?.turn(e, by: d) }

    /// The same computer-keyboard layout as FM-1 Pocket Player: A W S E D … play keys, Z/X octave, arrows and
    /// , . for the main encoders, 1–4 (Shift: down) for the knobs. Physical key codes, so it works on any layout.
    static let keyMap: [UInt16: Int] = [0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 15: 5, 3: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11,
                                        40: 12, 31: 13, 37: 14, 35: 15, 41: 16, 33: 17, 39: 18]

    private func installKeyboard() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] ev in
            guard let self else { return ev }
            let used = MainActor.assumeIsolated { self.handle(ev) }
            return used ? nil : ev
        }
    }

    private func handle(_ ev: NSEvent) -> Bool {
        guard core != nil else { return false }
        if !ev.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if ev.window?.firstResponder is NSText { return false }        // typing in the search field
        let code = ev.keyCode
        if let k = Self.keyMap[code] {
            if ev.type == .keyDown { if !ev.isARepeat { keyHeld[code] = k; key(k, down: true) } }
            else if let held = keyHeld.removeValue(forKey: code) { key(held, down: false) }
            return true
        }
        guard ev.type == .keyDown else { return false }
        let shift = ev.modifierFlags.contains(.shift)
        switch code {
        case 6: if !ev.isARepeat { tap(.octDown) }
        case 7: if !ev.isARepeat { tap(.octUp) }
        case 124: turn(.presets, 1)
        case 123: turn(.presets, -1)
        case 126: turn(.algorithm, 1)
        case 125: turn(.algorithm, -1)
        case 47: turn(.select, 1)
        case 43: turn(.select, -1)
        case 18: turn(.knob1, shift ? -1 : 1)
        case 19: turn(.knob2, shift ? -1 : 1)
        case 20: turn(.knob3, shift ? -1 : 1)
        case 21: turn(.knob4, shift ? -1 : 1)
        default: return false
        }
        return true
    }
}
