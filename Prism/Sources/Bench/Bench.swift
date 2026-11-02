import AVFoundation
import Foundation
import MLX
import StemSeparation

/// `Prism --bench <audio> [--offset s] [--seconds s] [--out dir] [--plans name,…]`
///
/// Streams an excerpt through each plan as fast as the GPU allows and compares the stems with an
/// offline separation of the same excerpt (full quality), printing per-stem SDR and the
/// model's time per chunk. `--out` also writes each plan's instrumental and vocals for listening.
nonisolated enum Bench {
    struct Candidate {
        let name: String
        let precision: ComputePrecision
        let plan: StreamingPlan
    }

    /// Parses `bf16:9.3/1/1[/0.05]` (precision:context/step/lookahead[/crossfade], seconds).
    static func candidate(_ name: String) -> Candidate? {
        let parts = name.split(separator: ":")
        guard parts.count == 2, let precision = ["f32": ComputePrecision.float32, "bf16": .bfloat16, "f16": .float16, "q8": .int8, "q4": .int4][String(parts[0])]
        else { return nil }
        let numbers = parts[1].split(separator: "/").compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        return Candidate(name: name, precision: precision,
                         plan: .seconds(context: numbers[0], step: numbers[1], lookahead: numbers[2],
                                        crossfade: numbers.count > 3 ? numbers[3] : 0.05))
    }

    static let defaultPlans = "bf16:9.3/2/1,bf16:9.3/1/1,bf16:9.3/1/0.5,bf16:6/1/1"

    static func run(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let path = value("--bench") else { print("usage: --bench <audio>"); return 1 }
        let offset = value("--offset").flatMap(Double.init) ?? 30
        let seconds = value("--seconds").flatMap(Double.init) ?? 60
        let out = value("--out").map { URL(fileURLWithPath: $0) }
        let candidates = (value("--plans") ?? defaultPlans).split(separator: ",").compactMap { candidate(String($0)) }
        let weights = value("--weights").map { URL(fileURLWithPath: $0) } ?? ModelLocation.sw

        do {
            let audio = try AudioDecoding.read(URL(fileURLWithPath: path), offset: offset, seconds: seconds)
            let length = audio.left.count
            print("Excerpt: \(String(format: "%.1f", Double(length) / 44_100)) s of \(URL(fileURLWithPath: path).lastPathComponent)")

            let clock = ContinuousClock()
            var started = clock.now
            let reference = try StemSplitter(weights: weights).separate(left: audio.left, right: audio.right)
            print("Offline reference: \(clock.now - started)")
            let names = reference.map(\.name)
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try write(instrumentalAndVocals(reference.flatMap { [$0.left, $0.right] }, names: names, length: length),
                          to: out, name: "offline")
            }

            var separators: [ComputePrecision: ChunkSeparator] = [:]
            print("plan".padding(toLength: 22, withPad: " ", startingAt: 0)
                  + "latency  chunk ms (p95)  load   " + names.map { $0.prefix(6).padding(toLength: 7, withPad: " ", startingAt: 0) }.joined()
                  + "instr  min-instr  peak MB")
            for candidate in candidates {
                let before = Memory.activeMemory
                let separator = try separators[candidate.precision]
                    ?? ChunkSeparator(weights: weights, precision: candidate.precision)
                if separators[candidate.precision] == nil {
                    print("\(candidate.precision.rawValue) weights: \((Memory.activeMemory - before) / 1_000_000) MB")
                }
                separators[candidate.precision] = separator
                let streaming = StreamingSeparator(separator: separator, plan: candidate.plan)
                // Warm up the kernels for this chunk size before timing.
                streaming.append(left: Array(audio.left.prefix(candidate.plan.context)), right: Array(audio.right.prefix(candidate.plan.context)))
                while streaming.canProcess { _ = streaming.process() }
                streaming.reset()

                streaming.append(left: audio.left, right: audio.right)
                Memory.peakMemory = 0
                var outputs = [[Float]](repeating: [], count: streaming.outputChannels)
                var times: [Double] = []
                while streaming.canProcess {
                    started = clock.now
                    let block = streaming.process()
                    times.append((clock.now - started).seconds)
                    for c in block.indices { outputs[c] += block[c] }
                }
                let emitted = outputs[0].count
                let stemChannels = Array(outputs.prefix(names.count * 2))
                var line = candidate.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                line += String(format: "%5.2f s  ", Double(candidate.plan.latency) / 44_100)
                let sorted = times.dropFirst().sorted()
                let mean = sorted.reduce(0, +) / Double(max(sorted.count, 1))
                let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                line += String(format: "%5.0f (%4.0f)    ", mean * 1000, p95 * 1000)
                line += String(format: "%3.0f%%   ", 100 * mean / (Double(candidate.plan.step) / 44_100))
                for (i, stem) in reference.enumerated() {
                    let sdr = sdr(reference: [Array(stem.left.prefix(emitted)), Array(stem.right.prefix(emitted))],
                                  estimate: [stemChannels[i * 2], stemChannels[i * 2 + 1]])
                    line += String(format: "%5.1f  ", sdr)
                }
                // Instrumental (everything but vocals): overall and its worst 2 s window.
                let vocal = names.firstIndex(of: "vocals")!
                let ref = instrumentalAndVocals(reference.flatMap { [Array($0.left.prefix(emitted)), Array($0.right.prefix(emitted))] },
                                                names: names, length: emitted)
                let est = instrumentalAndVocals(stemChannels, names: names, length: emitted)
                line += String(format: "%5.1f  ", sdr(reference: [ref[0], ref[1]], estimate: [est[0], est[1]]))
                let window = 88_200
                var worst = Double.infinity
                for start in stride(from: 0, to: emitted - window, by: window / 2) {
                    let r = [Array(ref[0][start ..< start + window]), Array(ref[1][start ..< start + window])]
                    let e = [Array(est[0][start ..< start + window]), Array(est[1][start ..< start + window])]
                    worst = min(worst, sdr(reference: r, estimate: e))
                }
                line += String(format: "%5.1f  %6d", worst, Memory.peakMemory / 1_000_000)
                _ = vocal
                print(line)
                if let out { try write(est, to: out, name: candidate.name) }
            }
            return 0
        } catch {
            print("Bench failed: \(error)")
            return 1
        }
    }

    /// `[instrumental L, R, vocals L, R]` from interleaved stem channels.
    static func instrumentalAndVocals(_ channels: [[Float]], names: [String], length: Int) -> [[Float]] {
        var result = [[Float]](repeating: [Float](repeating: 0, count: length), count: 4)
        for (i, name) in names.enumerated() {
            for side in 0..<2 {
                let target = name == "vocals" ? 2 + side : side
                for n in 0..<length { result[target][n] += channels[i * 2 + side][n] }
            }
        }
        return result
    }

    static func write(_ channels: [[Float]], to folder: URL, name: String) throws {
        for (label, pair) in [("instrumental", 0), ("vocals", 2)] {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[pair].count))!
            buffer.frameLength = buffer.frameCapacity
            for side in 0..<2 {
                channels[pair + side].withUnsafeBufferPointer {
                    buffer.floatChannelData![side].update(from: $0.baseAddress!, count: $0.count)
                }
            }
            let url = folder.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "_"))-\(label).wav")
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                                   AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                                   AVLinearPCMIsFloatKey: false])
            try file.write(from: buffer)
        }
    }

    /// Signal-to-distortion ratio in dB (plain energy ratio, as MUSDB's "SDR" is usually quoted).
    static func sdr(reference: [[Float]], estimate: [[Float]]) -> Double {
        var signal = 0.0, noise = 0.0
        for c in reference.indices {
            for i in 0..<min(reference[c].count, estimate[c].count) {
                let r = Double(reference[c][i]), e = Double(estimate[c][i])
                signal += r * r
                noise += (r - e) * (r - e)
            }
        }
        return 10 * log10((signal + 1e-9) / (noise + 1e-9))
    }
}

extension Duration {
    nonisolated var seconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
