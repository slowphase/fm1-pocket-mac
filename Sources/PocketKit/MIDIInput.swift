import CoreMIDI
import Foundation

/// MIDI in through CoreMIDI: listens to every connected MIDI source (and ones plugged in later) and hands channel
/// messages (notes, controllers, pitch bend...) to `onMessage`, as FM-1 Pocket Player does with Web MIDI.
/// `onMessage` is called on CoreMIDI's own thread.
public final class MIDIInput {
    public var onMessage: ((UInt8, UInt8, UInt8) -> Void)?
    /// called on the main thread when sources come or go
    public var onSourcesChanged: ((Int) -> Void)?
    public private(set) var sourceCount = 0
    public private(set) var isRunning = false

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    public init() {}

    /// Starts listening. Returns false if CoreMIDI is not available.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        var c = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("FM-1 Pocket" as CFString, &c) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectAll() }
            }
        }
        guard status == noErr else { return false }
        client = c
        var p = MIDIPortRef()
        let ps = MIDIInputPortCreateWithProtocol(client, "FM-1 Pocket in" as CFString, ._1_0, &p) { [weak self] list, _ in
            guard let self, let handler = self.onMessage else { return }
            for packet in list.unsafeSequence() {
                let n = Int(packet.pointee.wordCount)
                let words: [UInt32] = withUnsafeBytes(of: packet.pointee.words) { raw in
                    Array(raw.bindMemory(to: UInt32.self).prefix(min(n, 64)))
                }
                for m in Self.channelMessages(words) { handler(m.0, m.1, m.2) }
            }
        }
        guard ps == noErr else {
            MIDIClientDispose(client)
            return false
        }
        port = p
        isRunning = true
        connectAll()
        return true
    }

    public func stop() {
        guard isRunning else { return }
        MIDIPortDispose(port)
        MIDIClientDispose(client)
        isRunning = false
        sourceCount = 0
        onSourcesChanged?(0)
    }

    private func connectAll() {
        guard isRunning else { return }
        let n = MIDIGetNumberOfSources()
        for i in 0..<n { MIDIPortConnectSource(port, MIDIGetSource(i), nil) }
        sourceCount = n
        onSourcesChanged?(n)
    }

    /// Picks the MIDI 1.0 channel messages (status 0x80...0xEF) out of Universal MIDI Packet words.
    public static func channelMessages(_ words: [UInt32]) -> [(UInt8, UInt8, UInt8)] {
        // words per message, by message type (the top four bits)
        let lengths = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
        var out: [(UInt8, UInt8, UInt8)] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let type = Int(w >> 28)
            if type == 2 {                                  // MIDI 1.0 channel voice
                let status = UInt8((w >> 16) & 0xff)
                if status >= 0x80 && status < 0xf0 {
                    out.append((status, UInt8((w >> 8) & 0x7f), UInt8(w & 0x7f)))
                }
            }
            i += lengths[type]
        }
        return out
    }
}
