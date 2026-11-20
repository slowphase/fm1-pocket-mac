import AVFoundation
import Foundation

/// Plays a firmware through Core Audio (AVAudioEngine). The render callback pulls samples from the firmware, which
/// runs the device clock forward exactly as far as the sound needs, as FM-1 Pocket Player's audio callback does.
/// The firmware renders at 44.1 kHz; the engine's mixer converts to the output device's rate.
public final class AudioOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var scratch: UnsafeMutablePointer<Float>?
    private static let chunk = 4096

    public init() {}

    public var isRunning: Bool { engine.isRunning }

    /// Mute keeps the firmware running (and its clock moving) but silences the output, as Pocket's mute does.
    public func setMuted(_ m: Bool) { engine.mainMixerNode.outputVolume = m ? 0 : 1 }

    public func start(_ core: FirmwareCore) throws {
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: FirmwareCore.sampleRate, channels: 2) else {
            throw PocketError.badFirmware("Could not set up the audio format.")
        }
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunk * 2)
        buf.initialize(repeating: 0, count: Self.chunk * 2)
        scratch = buf
        let chunk = Self.chunk
        let src = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let total = Int(frameCount)
            var done = 0
            while done < total {
                let n = min(total - done, chunk)
                core.pull(buf, frames: n)
                for ch in 0..<list.count {
                    guard let data = list[ch].mData else { continue }
                    let out = data.assumingMemoryBound(to: Float.self)
                    let side = min(ch, 1)
                    for i in 0..<n { out[done + i] = buf[2 * i + side] }
                }
                done += n
            }
            return noErr
        }
        node = src
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.stop()
        if let node {
            engine.detach(node)
            self.node = nil
        }
        if let scratch {
            scratch.deallocate()
            self.scratch = nil
        }
    }

    deinit { stop() }
}
