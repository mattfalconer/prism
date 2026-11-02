import AVFoundation
import Foundation
import MLX
import Testing
@testable import StemSeparation

/// Model tests need local files:
///   STEM_SW_CHECKPOINT  BS-Roformer-SW.ckpt
///   STEM_SW_SAFETENSORS mlx-audio-separator's converted weights (reference for the converter)
///   STEM_SW_PARITY      folder with clip.wav and ref/clip_(<stem>)_BS-Roformer-SW.wav from the Python CLI
@Suite(.serialized) struct StemSeparationTests {
    nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static let checkpoint = env["STEM_SW_CHECKPOINT"].map(URL.init(fileURLWithPath:))
    nonisolated static let reference = env["STEM_SW_SAFETENSORS"].map(URL.init(fileURLWithPath:))
    nonisolated static let parity = env["STEM_SW_PARITY"].map(URL.init(fileURLWithPath:))

    @Test func stftRoundTripIsLossless() {
        let transform = SpectralTransform(nFFT: 2048, hop: 512)
        for length in [44_100, 409_600, 5_000] {
            let signal = MLXRandom.uniform(low: -1, high: 1, [2, length])
            let restored = transform.istft(transform.stft(signal), length: length)
            let error = abs(restored - signal).max().item(Float.self)
            #expect(error < 1e-4, "length \(length): max error \(error)")
        }
    }

    @Test func stftMatchesFramingConvention() {
        // center=True: frame 0 is centred on sample 0, so a lone impulse there lands in frame 0 only.
        let transform = SpectralTransform(nFFT: 2048, hop: 512)
        var samples = [Float](repeating: 0, count: 8_192)
        samples[4_096] = 1
        let spectrum = transform.stft(MLXArray(samples, [1, 8_192]))
        #expect(spectrum.shape == [1, 17, 1025])
        let energy = abs(spectrum).sum(axis: -1)[0].asArray(Float.self)
        #expect(energy.firstIndex(of: energy.max()!) == 8)
    }

    @Test func chunkStartsCoverTheTail() {
        #expect(StemSplitter.chunkStarts(length: 882_000, chunk: 409_600, step: 352_800) == [0, 352_800, 472_400])
        #expect(StemSplitter.chunkStarts(length: 409_600, chunk: 409_600, step: 352_800) == [0])
    }

    @Test func overlapAddStreamsTheSameAsAWholeBuffer() throws {
        let (length, chunk, step, outputs) = (10_000, 1_500, 1_200, 3)
        var chunks: [Int: [Float]] = [:]
        let window = StemSplitter.hamming(chunk)
        for start in StemSplitter.chunkStarts(length: length, chunk: chunk, step: step) {
            chunks[start] = (0..<(outputs * chunk)).map { i in Float.random(in: -1...1) * window[i % chunk] }
        }
        // Reference: accumulate everything, then normalise.
        var sums = [[Float]](repeating: [Float](repeating: 0, count: length), count: outputs)
        var weights = [Float](repeating: 0, count: length)
        for (start, values) in chunks {
            for s in 0..<outputs { for i in 0..<chunk { sums[s][start + i] += values[s * chunk + i] } }
            for i in 0..<chunk { weights[start + i] += window[i] }
        }
        let expected = sums.map { sum in sum.indices.map { sum[$0] / max(weights[$0], 1e-10) * 0.5 } }

        var streamed = [[Float]](repeating: [], count: outputs)
        var next = 0
        try StemSplitter.overlapAdd(length: length, chunk: chunk, step: step, outputs: outputs, gain: 0.5, progress: { _ in },
                                    emit: { start, block in
                                        #expect(start == next)
                                        next = start + block[0].count
                                        for s in 0..<outputs { streamed[s] += block[s] }
                                    }, windowed: { chunks[$0]! })
        #expect(next == length)
        for s in 0..<outputs {
            let worst = zip(streamed[s], expected[s]).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-5, "output \(s): \(worst)")
        }
    }

    /// STEM_MEGA_SAFETENSORS (converted weights) and STEM_MEGA_PARITY (clip.wav plus
    /// ref/clip_(<stem>)_mega53.wav from mlx-audio-separator) compare MVSep Mega with the Python port.
    nonisolated static let megaWeights = env["STEM_MEGA_SAFETENSORS"].map(URL.init(fileURLWithPath:))
    nonisolated static let megaParity = env["STEM_MEGA_PARITY"].map(URL.init(fileURLWithPath:))

    @Test(.enabled(if: megaWeights != nil && megaParity != nil), .timeLimit(.minutes(10)))
    func megaSeparationMatchesPython() throws {
        let splitter = try StemSplitter(weights: Self.megaWeights!, config: .mega53)
        let mix = try Self.read(Self.megaParity!.appendingPathComponent("clip.wav"))
        let clock = ContinuousClock(), start = clock.now
        let stems = try splitter.separate(left: mix[0], right: mix[1])
        print("Separated \(mix[0].count) samples into \(stems.count) stems in \(clock.now - start)")
        var compared = 0
        for stem in stems {
            let expected = try Self.read(Self.megaParity!.appendingPathComponent("ref/clip_(\(stem.name))_mega53.wav"))
            var energy = 0.0
            for channel in expected { for sample in channel { energy += Double(sample) * Double(sample) } }
            let level = 10 * log10(energy / Double(expected[0].count * 2) + 1e-20)
            guard level > -60 else { continue }   // near-silent categories: the ratio means nothing
            let sdr = Self.sdr(reference: expected, estimate: [stem.left, stem.right])
            print("  \(stem.name): \(String(format: "%.1f", sdr)) dB vs Python (level \(String(format: "%.0f", level)) dB)")
            #expect(sdr > 30, "\(stem.name) differs from the Python reference")
            compared += 1
        }
        #expect(compared >= 5)
    }

    @Test func keyMappingMatchesReference() {
        let cases = [
            "band_split.to_features.3.0.gamma": "band_split.to_features_3.norm.weight",
            "band_split.to_features.3.1.bias": "band_split.to_features_3.linear.bias",
            "layers.4.0.layers.0.0.to_qkv.weight": "layers_4.time_transformer.layers_0.attn.to_qkv.weight",
            "layers.4.1.layers.0.0.to_out.0.weight": "layers_4.freq_transformer.layers_0.attn.to_out.layers.0.weight",
            "layers.4.1.layers.0.1.net.0.gamma": "layers_4.freq_transformer.layers_0.ff.net.layers.0.weight",
            "layers.4.1.layers.0.1.net.4.bias": "layers_4.freq_transformer.layers_0.ff.net.layers.4.bias",
            "mask_estimators.5.to_freqs.61.0.2.weight": "mask_estimators_5.to_freqs_61.layers.2.weight",
            "final_norm.gamma": "final_norm.weight",
        ]
        for (torch, mlx) in cases {
            #expect(StemSplitter.mlxName(forTorchKey: torch, hasLinearTransformers: false) == mlx)
        }
        #expect(StemSplitter.mlxName(forTorchKey: "layers.0.0.layers.0.0.rotary_embed.freqs", hasLinearTransformers: false) == nil)
    }

    @Test(.enabled(if: checkpoint != nil && reference != nil), .timeLimit(.minutes(5)))
    func checkpointConversionMatchesPython() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID()).safetensors")
        defer { try? FileManager.default.removeItem(at: output) }
        let count = try StemSplitter.convertCheckpoint(Self.checkpoint!, to: output)
        let ours = try loadArrays(url: output)
        let theirs = try loadArrays(url: Self.reference!)
        #expect(count == theirs.count)
        #expect(Set(ours.keys) == Set(theirs.keys))
        var worst: Float = 0
        for (key, value) in theirs {
            guard let mine = ours[key] else { continue }
            #expect(mine.shape == value.shape, "\(key)")
            worst = max(worst, abs(mine - value).max().item(Float.self))
        }
        #expect(worst == 0)
    }

    @Test(.enabled(if: reference != nil && parity != nil), .timeLimit(.minutes(5)))
    func separationMatchesPython() throws {
        let splitter = try StemSplitter(weights: Self.reference!)
        let mix = try Self.read(Self.parity!.appendingPathComponent("clip.wav"))
        let clock = ContinuousClock(), start = clock.now
        let stems = try splitter.separate(left: mix[0], right: mix[1])
        print("Separated \(mix[0].count) samples in \(clock.now - start)")
        for stem in stems {
            let expected = try Self.read(Self.parity!.appendingPathComponent("ref/clip_(\(stem.name))_BS-Roformer-SW.wav"))
            let sdr = Self.sdr(reference: expected, estimate: [stem.left, stem.right])
            print("  \(stem.name): \(String(format: "%.1f", sdr)) dB vs Python")
            #expect(sdr > 40, "\(stem.name) differs from the Python reference")
        }
    }

    // MARK: Helpers

    static func read(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: frames)) }
    }

    static func sdr(reference: [[Float]], estimate: [[Float]]) -> Double {
        var signal = 0.0, noise = 0.0
        for c in 0..<2 {
            let n = min(reference[c].count, estimate[c].count)
            for i in 0..<n {
                let r = Double(reference[c][i]), e = Double(estimate[c][i])
                signal += r * r
                noise += (r - e) * (r - e)
            }
        }
        return 10 * log10(signal / max(noise, 1e-20))
    }
}
