import AppKit
import Foundation
import PocketKit
import SwiftUI

/// How encoders are drawn: as knobs (like the FM-1) or as sliders (FM-1 Pocket Player's default).
enum ControlStyle: String, CaseIterable { case knobs, sliders }

/// What the faceplate shows for one control: a role (0...6 the encoders, 7 MASTER), the firmware's name for it
/// right now, its value text, and (when the firmware says so) a value to set outright.
struct ControlState: Equatable {
    var absolute = false
    var value = 0
    var lo = 0
    var hi = 0
    var name = ""
    var text = ""
}

/// Everything about the running firmware the info panel shows.
struct FirmwareInfo {
    var name = ""
    var version = ""
    var authors: [String] = []
    var license = ""
    var sourceURL = ""
    var glueURL: String?
    var builtBy: String?
    var core = ""
    var credits = ""
    var licenses: [RFM1File.License] = []
    var buildKey = ""
}

/// The running firmware: its sound, screen, lights, controls, MIDI, saved settings, and computer-keyboard input.
/// A Swift version of what FM-1 Pocket Player's src/app.js does around src/rfm1.js.
@MainActor
final class PlayerModel: ObservableObject {
    // what is running
    @Published private(set) var playingID: LibraryItem.ID?
    @Published private(set) var loadingID: LibraryItem.ID?
    @Published private(set) var title = ""
    @Published private(set) var info = FirmwareInfo()
    @Published var error: String?
    /// bumped on every Play, so the library opens (or brings forward) the player window
    @Published private(set) var showRequest = 0

    // the panel
    @Published private(set) var screen: CGImage?
    @Published private(set) var leds: FirmwareCore.LEDs?
    @Published private(set) var buttonNames: [String] = FM1Button.allCases.map(\.label)
    /// a live label of "" means the button has no job right now (drawn dimmer)
    @Published private(set) var buttonIdle: [Bool] = Array(repeating: false, count: 14)
    @Published private(set) var controls: [ControlState] = Array(repeating: ControlState(), count: 8)
    @Published private(set) var heldKeys: Set<Int> = []
    @Published private(set) var downButtons: Set<Int32> = []
    @Published private(set) var latchedButtons: Set<Int32> = []
    /// the accent colour: the firmware's (sim1), its skin's, or Pocket's green
    @Published private(set) var ink = PlayerModel.defaultInk
    @Published private(set) var skinImage: NSImage?
    @Published private(set) var skinDim = 0.0
    @Published private(set) var haltMessage: String?

    // the strip under the faceplate
    @Published private(set) var linkMs = 0.0
    @Published private(set) var cpu: Int?
    @Published private(set) var midiSources = 0
    @Published private(set) var log = ""
    /// a save from another build of this firmware, when this build has none (its StateStore key)
    @Published private(set) var otherBuildSettings: String?

    // preferences
    @Published var style: ControlStyle = ControlStyle(rawValue: UserDefaults.standard.string(forKey: "player.style") ?? "") ?? .knobs {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "player.style") }
    }
    @Published var midiEnabled: Bool = UserDefaults.standard.object(forKey: "player.midi") as? Bool ?? true {
        didSet { UserDefaults.standard.set(midiEnabled, forKey: "player.midi"); updateMIDI() }
    }
    @Published var muted = false { didSet { audio.setMuted(muted) } }

    /// the player window; computer keys only play the firmware while it is the key window
    weak var playerWindow: NSWindow? {
        didSet {
            guard playerWindow !== oldValue else { return }
            if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
            resignObserver = playerWindow.map { w in
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseComputerKeys() }
                }
            }
        }
    }

    nonisolated static let defaultInk = Color(red: 0xc8 / 255, green: 0xff / 255, blue: 0x4a / 255)

    private var core: FirmwareCore?
    private let coreBox = CoreBox()
    private var bytes = Data()
    private var file: RFM1File?
    private var current: LibraryItem?
    private var catalogueID: String?
    private var flashID = "", flashVersion = "", flashSHA = ""
    private var flashSeen: UInt32 = 0
    private var activeIn: FirmwareLibrary?
    private let audio = AudioOutput()
    private let states = StateStore()
    private let midi = MIDIInput()
    private var timer: Timer?
    private var lastWrites: UInt32 = .max
    private var pixels: [UInt8] = []
    private var ticks = 0
    private var labelsEpoch: UInt32 = 0
    private var skinInk: Color?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var keyHeld: [UInt16: Int] = [:]
    private var keyCount: [Int: Int] = [:]

    init() {
        midi.onMessage = { [coreBox] s, d1, d2 in coreBox.core?.midi(s, d1, d2) }
        midi.onSourcesChanged = { [weak self] n in self?.midiSources = n }
    }

    // MARK: - playing

    func play(_ item: LibraryItem, library: LibraryModel) {
        guard item.canPlay else { return }
        error = nil
        loadingID = item.id
        showRequest += 1
        Task {
            defer { loadingID = nil }
            do {
                let fw = try await library.playable(for: item)
                try start(bytes: fw.data, sha256: fw.sha256, item: item, catalogueID: fw.catalogueID, library: library.library,
                          fallback: fw.isFallback, saveCurrent: true)
                library.notePlayed(item)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Boots `bytes` with this build's saved settings (or `flash` when given), replacing whatever runs now.
    private func start(bytes: Data, sha256: String, item: LibraryItem, catalogueID: String?, library: FirmwareLibrary?,
                       fallback: Bool, saveCurrent: Bool, flash: Data? = nil) throws {
        let next = try FirmwareCore(bytes: bytes)
        let parsed = try? RFM1File(bytes)
        stop(save: saveCurrent)
        // saved settings belong to this exact build (id, version and content hash); never another build's
        let saved = flash ?? states.load(id: next.id, version: next.version, sha256: sha256)
        let mine = StateStore.buildKey(version: next.version, sha256: sha256)
        let other = saved == nil ? states.savedKeys(id: next.id).first(where: { $0 != mine && $0.contains("@") }) : nil
        next.boot(flash: saved)
        if next.isHalted { throw PocketError.badFirmware("\(item.name) stopped while starting: \(next.errorMessage)") }

        core = next
        coreBox.core = next
        self.bytes = bytes
        file = parsed
        current = item
        self.catalogueID = catalogueID
        flashID = next.id
        flashVersion = next.version
        flashSHA = sha256
        flashSeen = next.flashDirty
        otherBuildSettings = other
        if let catalogueID, let library {
            Task { await library.noteStateFromOtherBuild(id: catalogueID, otherKey: other) }
            Task { await library.markActive(sha256: sha256) }
            activeIn = library
        }

        title = "\(parsed?.name ?? item.name) \(next.version)" + (fallback ? " (previous download: the update could not be fetched)" : "")
        info = FirmwareInfo(name: parsed?.name ?? next.name, version: next.version, authors: parsed?.authors ?? [],
                            license: parsed?.license ?? next.license, sourceURL: parsed?.sourceURL ?? next.sourceURL,
                            glueURL: parsed?.glueURL, builtBy: parsed?.builtBy,
                            core: "fm1core ABI \(next.abi)" + (next.family.isEmpty ? "" : ", \(next.family) family")
                                + (next.sim1Version > 0 ? ", with the sim1 extension" : ""),
                            credits: parsed?.credits.isEmpty == false ? parsed!.credits : next.credits,
                            licenses: parsed?.licenses ?? [], buildKey: mine)
        let skin = parsed?.skin
        skinImage = skin?.wideImage.flatMap { NSImage(data: $0) }
        skinDim = skin?.wideImage == nil ? 0 : (skin.map { $0.dim > 0 ? $0.dim : 0.35 } ?? 0)
        skinInk = skin?.led.flatMap(Self.color(hex:))
        ink = skinInk ?? Self.defaultInk
        labelsEpoch = 0
        nameButtons(nil)
        haltMessage = nil
        log = ""
        playingID = item.id
        lastWrites = .max
        do { try audio.start(next); audio.setMuted(muted) } catch { self.error = "No sound: \(error.localizedDescription)" }
        startTimer()
        installKeyboard()
        updateMIDI()
        refresh()
    }

    func stop() { stop(save: true) }

    private func stop(save: Bool) {
        if save { saveFlash(sync: true) }
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
        coreBox.core = nil
        playingID = nil
        screen = nil
        leds = nil
        heldKeys = []
        keyHeld = [:]
        keyCount = [:]
        downButtons = []
        latchedButtons = []
        haltMessage = nil
        cpu = nil
        updateMIDI()
    }

    /// Power cycle: save, then boot the same firmware again (also "power on again" after a crash).
    func powerCycle() {
        guard let item = current else { return }
        let saveFirst = core.map { !$0.isHalted } ?? false
        relaunch(item: item, save: saveFirst, flash: nil)
    }

    private func relaunch(item: LibraryItem, save: Bool, flash: Data?) {
        do {
            try start(bytes: bytes, sha256: flashSHA, item: item, catalogueID: catalogueID, library: activeIn,
                      fallback: false, saveCurrent: save, flash: flash)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - saved settings

    /// saves the firmware's flash when it changed (sync: ask the firmware to finish its writes first)
    func saveFlash(sync: Bool) {
        guard let core, !core.isHalted else { return }
        let d = core.flashDirty
        if d == flashSeen && !sync { return }
        if let img = core.flashImage(sync: sync) {
            do { try states.save(img, id: flashID, version: flashVersion, sha256: flashSHA) }
            catch { self.error = "Could not save settings: \(error.localizedDescription)" }
        }
        flashSeen = core.flashDirty
    }

    /// Erase Saved Settings: delete this build's save and start it fresh.
    func eraseSavedSettings() {
        guard let item = current else { return }
        do { try states.erase(id: flashID, version: flashVersion, sha256: flashSHA) }
        catch { self.error = "Could not erase the saved settings: \(error.localizedDescription)"; return }
        relaunch(item: item, save: false, flash: nil)
    }

    /// Export Settings…: the current flash image as a file.
    func exportSettings(to url: URL) {
        guard let core, let img = core.flashImage(sync: true) else { error = "This firmware has no saved settings to export."; return }
        do { try img.write(to: url, options: .atomic) } catch { self.error = "Could not export: \(error.localizedDescription)" }
    }

    /// Import Settings…: a flash image from a file, kept as this build's save, then booted.
    func importSettings(from url: URL) {
        guard let item = current, let core else { return }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty, data.count <= core.flashSize else {
                error = "That file is not a settings file for this firmware (it should be \(core.flashSize) bytes)."
                return
            }
            try states.save(data, id: flashID, version: flashVersion, sha256: flashSHA)
            relaunch(item: item, save: false, flash: data)
        } catch {
            self.error = "Could not import: \(error.localizedDescription)"
        }
    }

    /// Try the settings saved by another build (copied, never moved: the original save is kept).
    func useOtherBuildSettings() {
        guard let item = current, let key = otherBuildSettings, let data = states.load(id: flashID, key: key) else { return }
        do { try states.save(data, id: flashID, version: flashVersion, sha256: flashSHA) }
        catch { self.error = "Could not copy the settings: \(error.localizedDescription)"; return }
        relaunch(item: item, save: false, flash: data)
    }

    func dismissOtherBuildSettings() {
        otherBuildSettings = nil
        if let lib = activeIn, let id = catalogueID { Task { await lib.noteStateFromOtherBuild(id: id, otherKey: nil) } }
    }

    /// the version a StateStore build key was saved with ("3.4@1a2b..." -> "3.4")
    nonisolated static func version(ofKey key: String) -> String { key.split(separator: "@").first.map(String.init) ?? key }

    // MARK: - the frame loop

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        guard let core else { return }
        if core.isHalted {
            if haltMessage == nil {
                haltMessage = core.haltCode == 0x1ff || core.haltCode == 0x1fe
                    ? "The firmware crashed: \(core.errorMessage)"
                    : "The firmware stopped (it asked to reboot, code \(core.haltCode & 0xff))."
            }
            return
        }
        if !audio.isRunning { core.run(milliseconds: 16) }      // no sound device: keep the clock going anyway
        let w = core.lcdWrites
        if w != lastWrites {
            lastWrites = core.screen(into: &pixels)
            screen = Self.image(pixels)
            let bytes = core.linkBytes ?? core.screenChangedBytes
            linkMs += (Double(bytes) * 8 / 44000 - linkMs) * 0.08
        }
        let l = core.leds()
        if l != leds { leds = l }
        ticks += 1

        let epoch = core.labelsEpoch
        if epoch != labelsEpoch {
            labelsEpoch = epoch
            nameButtons(epoch == 0 ? nil : core.labels())
        }
        syncControls(core)
        if ticks % 7 == 0 {                                     // about every 120 ms, as Pocket does
            let a = core.accent.map { Self.color(rgb: $0) } ?? skinInk ?? Self.defaultInk
            if a != ink { ink = a }
        }
        if ticks % 30 == 0 {
            let c = core.stats()?.cpu
            if c != cpu { cpu = c }
            let t = core.takeLog()
            if !t.isEmpty { log = String((log + t).suffix(4000)) }
        }
        if ticks % 60 == 0 { saveFlash(sync: false) }
    }

    private var liveLabels: [String?]?

    private func nameButtons(_ live: [String?]?) {
        liveLabels = live
        guard let core else { return }
        var names: [String] = []
        var idle: [Bool] = []
        for b in FM1Button.allCases {
            let l = live?[8 + Int(b.rawValue)] ?? nil
            let n = l.flatMap { $0.isEmpty ? nil : $0 } ?? core.buttonName(b)
            names.append(n == "OCT-" ? "OCT −" : (n == "OCT+" ? "OCT +" : n))
            idle.append(l == "")
        }
        if names != buttonNames { buttonNames = names }
        if idle != buttonIdle { buttonIdle = idle }
    }

    private func syncControls(_ core: FirmwareCore) {
        var next = controls
        for e in FM1Encoder.allCases {
            let i = Int(e.rawValue)
            if let c = core.control(e) {
                next[i] = ControlState(absolute: c.absolute, value: c.value, lo: c.lo, hi: c.hi, name: c.name, text: c.text)
            } else if let l = liveLabels?[i] ?? nil {
                next[i] = ControlState(name: l)
            } else {
                next[i] = ControlState()
            }
        }
        let m = core.master
        next[7] = ControlState(absolute: true, value: m, lo: 0, hi: 1023, name: "VOLUME", text: "\(Int((Double(m) / 10.23).rounded()))%")
        if next != controls { controls = next }
    }

    nonisolated static func image(_ rgba: [UInt8]) -> CGImage? {
        let n = FirmwareCore.screenSize
        guard rgba.count == n * n * 4, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    nonisolated static func color(rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }
    nonisolated static func color(hex: String) -> Color? {
        guard hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return color(rgb: v)
    }

    // MARK: - MIDI

    private func updateMIDI() {
        if midiEnabled && core != nil { midi.start() } else if !midiEnabled { midi.stop() }
    }

    // MARK: - input from the faceplate

    /// a key goes down (velocity from where it was hit) or up; mouse and computer keyboard can both hold one
    func key(_ k: Int, down: Bool, velocity: Int = 100) {
        guard let core, k >= 0, k < FirmwareCore.keyCount else { return }
        if down {
            keyCount[k, default: 0] += 1
            if keyCount[k] == 1 { core.key(k, down: true, velocity: velocity); heldKeys.insert(k) }
        } else if let n = keyCount[k], n > 0 {
            keyCount[k] = n - 1
            if n == 1 { core.key(k, down: false); heldKeys.remove(k) }
        }
    }

    /// Mouse press on a button. Shift-click latches it down until the next click, so the mouse is free to turn an
    /// encoder while the firmware sees the button held, as in Pocket.
    func buttonPressed(_ b: FM1Button, shift: Bool) {
        if latchedButtons.contains(b.rawValue) {
            latchedButtons.remove(b.rawValue)
            button(b, down: false)
            return
        }
        if shift { latchedButtons.insert(b.rawValue) }
        button(b, down: true)
    }
    func buttonReleased(_ b: FM1Button) {
        if !latchedButtons.contains(b.rawValue) { button(b, down: false) }
    }

    func button(_ b: FM1Button, down: Bool) {
        if down { downButtons.insert(b.rawValue) } else { downButtons.remove(b.rawValue) }
        core?.button(b, down: down)
    }
    func tap(_ b: FM1Button) {
        button(b, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.button(b, down: false) }
    }

    /// role 0...6: detents on an encoder; 7: MASTER
    func turn(_ role: Int, _ detents: Int) {
        guard let core, detents != 0 else { return }
        if role == 7 { setValue(7, core.master + detents * 32); return }
        guard let e = FM1Encoder(rawValue: Int32(role)) else { return }
        core.turn(e, by: detents)
    }

    /// set a role that takes values outright (sim1, or MASTER)
    func setValue(_ role: Int, _ value: Int) {
        guard let core else { return }
        if role == 7 { core.setMaster(max(0, min(1023, value))) }
        else if let e = FM1Encoder(rawValue: Int32(role)) { core.setControl(e, to: value) }
        syncControls(core)
    }

    // MARK: - the computer keyboard (only while the player window is in front)

    /// The same layout as FM-1 Pocket Player: A W S E D … play keys (from F), Z/X octave, arrows and , . for the
    /// main encoders, 1–4 (Shift: down) for the knobs. Physical key codes, so it works on any keyboard layout.
    nonisolated static let keyMap: [UInt16: Int] = [0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 15: 5, 3: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11,
                                        40: 12, 31: 13, 37: 14, 35: 15, 41: 16, 33: 17, 39: 18]
    /// the computer key printed on each piano key
    nonisolated static let keyLetters: [Int: String] = [0: "A", 1: "W", 2: "S", 3: "E", 4: "D", 5: "R", 6: "F", 7: "G", 8: "Y", 9: "H",
                                            10: "U", 11: "J", 12: "K", 13: "O", 14: "L", 15: "P", 16: ";", 17: "[", 18: "'"]

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
        if ev.window?.firstResponder is NSText { return false }
        guard let w = playerWindow, ev.window === w else { return false }
        let code = ev.keyCode
        if let k = Self.keyMap[code] {
            if ev.type == .keyDown { if !ev.isARepeat && keyHeld[code] == nil { keyHeld[code] = k; key(k, down: true) } }
            else if let held = keyHeld.removeValue(forKey: code) { key(held, down: false) }
            return true
        }
        guard ev.type == .keyDown else { return false }
        let shift = ev.modifierFlags.contains(.shift)
        let repeats: Set<UInt16> = [126, 125, 47, 43, 18, 19, 20, 21]   // ↑ ↓ . , and 1-4 auto-repeat, as in Pocket
        if ev.isARepeat && !repeats.contains(code) { return [6, 7, 124, 123].contains(code) }
        switch code {
        case 6: tap(.octDown)
        case 7: tap(.octUp)
        case 124: turn(2, 1)
        case 123: turn(2, -1)
        case 126: turn(1, 1)
        case 125: turn(1, -1)
        case 47: turn(0, 1)
        case 43: turn(0, -1)
        case 18, 19, 20, 21: turn(Int(code) - 15, shift ? -1 : 1)
        default: return false
        }
        return true
    }

    /// lets go of every computer key (the player window lost focus)
    private func releaseComputerKeys() {
        for (_, k) in keyHeld { key(k, down: false) }
        keyHeld = [:]
    }
}

/// The running core, for CoreMIDI's thread.
final class CoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FirmwareCore?
    var core: FirmwareCore? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
