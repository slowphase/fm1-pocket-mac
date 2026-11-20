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
    /// rendered offline on request instead of to the output device (the integration test)
    private let manual: Bool

    public init(manual: Bool = false) { self.manual = manual }

    public var isRunning: Bool { engine.isRunning }

    /// Mute keeps the firmware running (and its clock moving) but silences the output, as Pocket's mute does.
    public func setMuted(_ m: Bool) { engine.mainMixerNode.outputVolume = m ? 0 : 1 }

    public func start(_ core: any PlayerEngine) throws {
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
        if manual {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(Self.chunk))
        }
        engine.prepare()
        try engine.start()
    }

    /// Manual mode only: `frames` of what the output would play (the firmware, through the mixer, muted or not):
    /// the sum of squared samples and their count.
    public func renderOffline(frames: Int) -> (Double, Int)? {
        guard manual, engine.isRunning,
              let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames)),
              (try? engine.renderOffline(AVAudioFrameCount(frames), to: buf)) == .success,
              let ch = buf.floatChannelData else { return nil }
        var s = 0.0
        let n = Int(buf.frameLength)
        for c in 0..<Int(buf.format.channelCount) { for i in 0..<n { s += Double(ch[c][i] * ch[c][i]) } }
        return (s, n * Int(buf.format.channelCount))
    }

    public func stop() {
        engine.stop()
        if manual && engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
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
