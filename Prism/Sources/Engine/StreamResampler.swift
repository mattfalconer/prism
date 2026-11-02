import AVFoundation
import Foundation

/// Streaming sample-rate conversion of planar blocks; keeps its filter state between calls.
nonisolated final class StreamResampler {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let ratio: Double
    let channels: Int

    init?(from source: Double, to target: Double, channels: Int) {
        func format(_ rate: Double) -> AVAudioFormat? {
            if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) }
            guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return nil }
            return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        }
        guard let input = format(source), let output = format(target),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        self.input = input
        self.output = output
        self.channels = channels
        ratio = target / source
    }

    func reset() { converter.reset() }

    func process(_ blocks: [[Float]]) -> [[Float]] {
        let frames = blocks.first?.count ?? 0
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            blocks[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: frames) }
        }
        let capacity = AVAudioFrameCount(Double(frames) * ratio + 256)
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        let count = Int(converted.frameLength)
        return (0..<channels).map { Array(UnsafeBufferPointer(start: converted.floatChannelData![$0], count: count)) }
    }
}
