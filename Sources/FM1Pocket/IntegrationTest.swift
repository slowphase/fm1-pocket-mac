import Foundation
import PocketKit

/// `FM1Pocket --integration SCENARIOS.json RESULT.json`: the app's own playback path, end to end, without a window.
///
/// Unlike `--selftest-fwsc` (an engine on its own), this drives the app's `PlayerModel`: the same `start` that Play
/// uses (engine choice by file, saved settings loaded by build and engine), the same input handlers the faceplate,
/// the computer keyboard and CoreMIDI call (`key`, `buttonPressed`/`buttonReleased`, `turn`, `computerKey`, the MIDI
/// handler), the same `AudioOutput` graph (its source node and mixer, rendered offline instead of to a device), the
/// same 60 Hz timer work between audio buffers (which saves settings once a second), and the same stop and quit path
/// (`stop()`, which saves). Saves go to a temporary folder through the app's `StateStore`.
///
/// For each firmware in SCENARIOS.json it records the sound of each step (idle, mouse keys, a computer-keyboard
/// chord, MIDI, PLAY, plus any firmware-specific steps), checks the steps the firmware is known to answer, checks
/// mute, and, where a save recipe is given, saves with the firmware's own controls, quits, starts again in a fresh
/// player (a relaunch) and compares the screen and the restored flash.
///
/// What it cannot verify: whether it sounds right (pitch, timbre, timing feel: only listening tells), the real
/// output device and its sample rate, mouse gestures and SwiftUI layout (the handlers are called directly), MIDI
/// from real hardware (the handler is called directly), and anything a recipe does not exercise.
@MainActor
enum IntegrationTest {
    struct Scenario: Decodable {
        var id: String
        var kind: String
        var file: String
        var bootMs: Int?
        /// steps that must make sound: idle, keys, computer, midi, play, or a custom step's name
        var expect: [String]
        /// extra steps before the battery (e.g. a drum machine's pattern), and custom sounding steps
        var prelude: [String]?
        var custom: [Custom]?
        var save: Save?
        /// another file of the same firmware on the other engine, for the engine-switch check
        var other: String?
        struct Custom: Decodable { var name: String; var steps: [String]; var ms: Int; var after: [String]? }
        /// `screen`: "same" (the view looks as it did before quitting), "differsFromFresh" (the view differs from a
        /// fresh start without the save: for firmwares that boot on a default sound but list what was saved), or
        /// "none" (the restored flash is the only check)
        struct Save: Decodable { var steps: [String]; var view: [String]; var screen: String? }
    }
    struct Scenarios: Decodable { var firmwares: [Scenario] }

    static func run(_ scenarioPath: String, writingTo path: String?) -> Int32 {
        var results: [[String: Any]] = []
        var allOK = true
        do {
            let base = URL(fileURLWithPath: scenarioPath).deletingLastPathComponent()
            let list = try JSONDecoder().decode(Scenarios.self, from: Data(contentsOf: URL(fileURLWithPath: scenarioPath)))
            for sc in list.firmwares {
                let r = runOne(sc, base: base)
                if (r["ok"] as? Bool) != true { allOK = false }
                results.append(r)
                FileHandle.standardError.write("\(sc.id): \((r["ok"] as? Bool) == true ? "ok" : "FAIL") \(r["failures"] ?? "")\n".data(using: .utf8)!)
            }
        } catch {
            results.append(["error": error.localizedDescription, "ok": false])
            allOK = false
        }
        let out: [String: Any] = ["ok": allOK, "kind": "automated app-level checks (nobody listened)", "firmwares": results]
        let json = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        if let path { try? json.write(to: URL(fileURLWithPath: path)) }
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        return allOK ? 0 : 1
    }

    static let silent = 0.0002

    static func item(_ url: URL, id: String) -> LibraryItem {
        if url.pathExtension == "fwsc" {
            var it = LibraryItem.package(url)
            it.id = "test:" + id
            return it
        }
        var it = LibraryItem(source: .builtin(url), id: "test:" + id, name: id, version: "", authors: "", category: "",
                             tag: "", about: "", license: "", sourceURL: nil, imageURL: nil, screenshotFile: nil, size: 0,
                             download: .installed, downloading: false, lastError: nil)
        it.engine = "rfm1"
        return it
    }

    /// one step: wait:MS, key:N+ / key:N- (mouse on the keybed), ckey:CODE+ / ckey:CODE- (computer keyboard),
    /// tap:LABEL (mouse press, 100 ms, release), hold:LABEL:MS, turn:ROLE:DETENTS (0 SELECT, 1 ALGORITHM, 2 PRESETS,
    /// 3..6 K1..K4), midi:HEX (two or three bytes)
    static func step(_ p: PlayerModel, _ s: String) -> Double? {
        let f = s.split(separator: ":").map(String.init)
        guard let op = f.first else { return nil }
        func button(_ l: String) -> FM1Button? { FM1Button.allCases.first { $0.label == l.uppercased() } }
        switch op {
        case "wait": return p.testRun(ms: Int(f[1]) ?? 0)
        case "key":
            let a = f[1]; let k = Int(a.dropLast()) ?? 0
            p.key(k, down: a.hasSuffix("+"), velocity: 110)
        case "ckey":
            let a = f[1]; let c = UInt16(a.dropLast()) ?? 0
            _ = p.computerKey(c, down: a.hasSuffix("+"))
        case "tap", "hold":
            guard let b = button(f[1]) else { return nil }
            p.buttonPressed(b, shift: false)
            _ = p.testRun(ms: op == "hold" ? Int(f[2]) ?? 1000 : 100)
            p.buttonReleased(b)
        case "turn": p.turn(Int(f[1]) ?? 0, Int(f[2]) ?? 0)
        case "midi":
            let h = f[1]; var b: [UInt8] = []
            var i = h.startIndex
            while i < h.endIndex, let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex) { b.append(UInt8(h[i..<j], radix: 16) ?? 0); i = j }
            if b.count >= 2 { p.testMIDI(b[0], b[1], b.count > 2 ? b[2] : 0) }
        default: return nil
        }
        return nil
    }
    static func steps(_ p: PlayerModel, _ list: [String]) { for s in list { _ = step(p, s) } }

    static func runOne(_ sc: Scenario, base: URL) -> [String: Any] {
        var r: [String: Any] = ["id": sc.id, "kind": sc.kind, "file": sc.file]
        var failures: [String] = []
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fm1-integration-\(sc.id)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let states = StateStore(folder: folder)
        do {
            let url = URL(fileURLWithPath: sc.file, relativeTo: base).absoluteURL
            let bytes = try Data(contentsOf: url)
            let sha = sha256Hex(bytes)
            r["sha256"] = sha
            let it = item(url, id: sc.id)
            let p = PlayerModel(states: states, audio: AudioOutput(manual: true))
            try p.testStart(bytes: bytes, sha256: sha, item: it)
            r["engine"] = p.testEngine
            var sound: [String: Double] = [:]
            sound["idle"] = p.testRun(ms: sc.bootMs ?? 8000)
            steps(p, sc.prelude ?? [])
            // mouse keys: three keys of the keybed held, as the faceplate does
            for k in [7, 11, 14] { p.key(k, down: true, velocity: 110) }
            sound["keys"] = p.testRun(ms: 1000)
            // mute while they sound: the output goes silent, the firmware keeps running
            p.muted = true
            let muted = p.testRun(ms: 300)
            p.muted = false
            let unmuted = p.testRun(ms: 200)
            sound["muted"] = muted
            if sc.expect.contains("keys") && muted > silent { failures.append("mute left \(muted) RMS") }
            if sc.expect.contains("keys") && unmuted <= silent { failures.append("no sound after unmuting") }
            for k in [7, 11, 14] { p.key(k, down: false) }
            _ = p.testRun(ms: 400)
            // a computer-keyboard chord (G J L: the same three keys), pressed between two audio buffers
            for c: UInt16 in [5, 38, 37] { _ = p.computerKey(c, down: true) }
            sound["computer"] = p.testRun(ms: 1000)
            for c: UInt16 in [5, 38, 37] { _ = p.computerKey(c, down: false) }
            _ = p.testRun(ms: 400)
            p.testMIDI(0x90, 60, 110)
            sound["midi"] = p.testRun(ms: 600)
            p.testMIDI(0x80, 60, 0)
            _ = p.testRun(ms: 400)
            p.buttonPressed(.play, shift: false); _ = p.testRun(ms: 100); p.buttonReleased(.play)
            sound["play"] = p.testRun(ms: 4000)
            p.buttonPressed(.play, shift: false); _ = p.testRun(ms: 100); p.buttonReleased(.play)
            _ = p.testRun(ms: 500)
            for c in sc.custom ?? [] {
                steps(p, c.steps)
                sound[c.name] = p.testRun(ms: c.ms)
                steps(p, c.after ?? [])
            }
            r["rms"] = sound
            for e in sc.expect where (sound[e] ?? 0) <= silent { failures.append("no sound from \(e)") }
            if p.testHalted { failures.append("the firmware stopped") }

            if let save = sc.save {
                // fresh, so the save recipe starts from the firmware's own first screen
                p.stop()
                try? FileManager.default.removeItem(at: folder)
                let a = PlayerModel(states: states, audio: AudioOutput(manual: true))
                try a.testStart(bytes: bytes, sha256: sha, item: it)
                _ = a.testRun(ms: sc.bootMs ?? 8000)
                steps(a, save.steps)
                _ = a.testRun(ms: 1500)                  // the timer's once-a-second save while it plays
                let savedWhilePlaying = a.testSavedFlash
                steps(a, save.view)
                _ = a.testRun(ms: 800)
                let before = a.testScreenHash
                let saveID = a.testSaveID
                let flashBefore = a.testCurrentFlash
                a.stop()                                 // what quitting does (willTerminate -> stop -> save)
                let onDisk = states.savedKeys(id: saveID)
                // relaunch: a new player, the same save folder, the same firmware
                let b = PlayerModel(states: states, audio: AudioOutput(manual: true))
                try b.testStart(bytes: bytes, sha256: sha, item: it)
                _ = b.testRun(ms: sc.bootMs ?? 8000)
                steps(b, save.view)
                _ = b.testRun(ms: 800)
                let after = b.testScreenHash
                let flashAfter = b.testCurrentFlash
                var sv: [String: Any] = ["savedWhilePlaying": savedWhilePlaying.map { !$0.isEmpty } ?? false, "saveID": saveID,
                                         "filesOnDisk": onDisk, "sameScreenAfterRelaunch": before == after,
                                         "sameFlashAfterRelaunch": flashBefore == flashAfter]
                if flashBefore != flashAfter { failures.append("the restored flash differs from the saved one") }
                if savedWhilePlaying == nil || savedWhilePlaying!.isEmpty { failures.append("nothing saved within 1.5 s of the firmware's save") }
                if onDisk.isEmpty { failures.append("no save on disk after quitting") }
                let mode = save.screen ?? "same"
                if mode == "same" && before != after { failures.append("the screen after a relaunch differs from before quitting") }
                if mode == "differsFromFresh" {
                    let freshFolder = folder.appendingPathExtension("fresh")
                    defer { try? FileManager.default.removeItem(at: freshFolder) }
                    let c = PlayerModel(states: StateStore(folder: freshFolder), audio: AudioOutput(manual: true))
                    try c.testStart(bytes: bytes, sha256: sha, item: it)
                    _ = c.testRun(ms: sc.bootMs ?? 8000)
                    steps(c, save.view)
                    _ = c.testRun(ms: 800)
                    let fresh = c.testScreenHash
                    c.stop()
                    sv["differsFromFresh"] = fresh != after
                    if fresh == after { failures.append("after a relaunch the firmware shows nothing of what was saved") }
                }
                // the engine switch: the other engine's file of the same firmware runs with its own (separate) save,
                // and coming back finds this engine's save as it was
                if let other = sc.other {
                    let ou = URL(fileURLWithPath: other, relativeTo: base).absoluteURL
                    let ob = try Data(contentsOf: ou)
                    try b.testStart(bytes: ob, sha256: sha256Hex(ob), item: item(ou, id: sc.id))
                    let otherEngine = b.testEngine
                    let otherIDNow = b.testSaveID
                    _ = b.testRun(ms: sc.bootMs ?? 8000)
                    let otherHalted = b.testHalted
                    try b.testStart(bytes: bytes, sha256: sha, item: it)
                    _ = b.testRun(ms: sc.bootMs ?? 8000)
                    steps(b, save.view)
                    _ = b.testRun(ms: 800)
                    let back = b.testScreenHash
                    let otherID = otherIDNow
                    sv["switch"] = ["otherEngine": otherEngine, "otherRan": !otherHalted, "sameScreenAfterSwitchingBack": back == before,
                                    "saveKeys": states.savedKeys(id: saveID), "otherSaveID": otherID,
                                    "otherSaveKeys": states.savedKeys(id: otherID)]
                    if otherHalted { failures.append("the other engine's file stopped") }
                    if mode == "same" && back != before { failures.append("switching engines lost the save") }
                    if back != after { failures.append("coming back from the other engine, the firmware looks different") }
                }
                b.stop()
                r["save"] = sv
            } else {
                p.stop()
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        r["failures"] = failures
        r["ok"] = failures.isEmpty
        return r
    }
}
