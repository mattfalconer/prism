import Accelerate
import AVFoundation
import Foundation
import StemSeparation

/// `Prism --live-test <audio> [--offset s] [--seconds s] [--mode balanced] [--out dir]`
///
/// The whole live path without a sound: plays an excerpt with `afplay`, taps that process (which
/// mutes it), runs the real engine with the speakers silenced, records what would have played
/// (instrumental preset), then aligns it with an offline separation and reports the SDR and the
/// measured delay.
enum LiveTest {
    static func run(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let path = value("--live-test") else { return 1 }
        let offset = value("--offset").flatMap(Double.init) ?? 30
        let seconds = value("--seconds").flatMap(Double.init) ?? 30
        let mode = value("--mode").flatMap(LatencyMode.init(rawValue:)) ?? .balanced
        let out = URL(fileURLWithPath: value("--out") ?? NSTemporaryDirectory())
        let preset = value("--preset") ?? "instrumental"
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let audio = try AudioDecoding.read(URL(fileURLWithPath: path), offset: offset, seconds: seconds)
            // Two seconds of silence first, so nothing is heard before the tap exists.
            let lead = 88_200
            let clip = out.appendingPathComponent("live-input.wav")
            try writeWAV([Array(repeating: 0, count: lead) + audio.left, Array(repeating: 0, count: lead) + audio.right],
                         rate: 44_100, to: clip)

            print("Loading model (\(mode.title): \(mode.plan))")
            let separator = try ChunkSeparator(weights: ModelLocation.sw, precision: .bfloat16)
            let warm = [Float](repeating: 1e-4, count: mode.plan.context)
            warm.withUnsafeBufferPointer { _ = separator.separate(left: $0.baseAddress!, right: $0.baseAddress!, count: mode.plan.context) }

            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [clip.path]
            try player.run()
            var processes: [AudioObjectID] = []
            for _ in 0..<60 where processes.isEmpty {
                usleep(25_000)
                processes = ProcessTap.processes(for: .pids([player.processIdentifier]))
            }
            guard !processes.isEmpty else { print("afplay never appeared to Core Audio"); player.terminate(); return 1 }
            let tap = try ProcessTap(target: .pids([player.processIdentifier]), processes: processes)
            print("Tapping afplay → \(tap.outputDeviceName) at \(Int(tap.sampleRate)) Hz")
            let engine = LiveEngine(tap: tap, separator: separator, plan: mode.plan)
            let recording = RingBuffer(channels: 2, capacity: Int(tap.sampleRate * (seconds + 20)))
            engine.recording = recording
            engine.silenceOutput = true
            // instrumental: everything but the vocals; all: every stem at unity; original: the dry mix.
            for (slot, name) in engine.stemNames.enumerated() {
                engine.targetGains[slot] = preset == "original" || (preset == "instrumental" && name == "vocals") ? 0 : 1
            }
            engine.targetGains[engine.stemNames.count] = preset == "original" ? 1 : 0
            try engine.start()

            var recorded: [[Float]] = [[], []]
            let started = Date()
            var maxLatency = 0.0
            while player.isRunning || Date().timeIntervalSince(started) < seconds + 2 + 6 {
                usleep(100_000)
                let block = recording.readAll()
                if !block.isEmpty { recorded[0] += block[0]; recorded[1] += block[1] }
                let stats = engine.stats
                if stats.playing { maxLatency = max(maxLatency, stats.latency) }
                if !player.isRunning && Date().timeIntervalSince(started) > seconds + 2 + 6 { break }
            }
            let stats = engine.stats
            engine.stop()
            print(String(format: "Model %d ms per step (%.0f%% load), underruns %d, reported delay up to %.2f s",
                         stats.chunkMilliseconds, stats.load * 100, stats.underruns, maxLatency))

            // Back to 44.1 kHz for comparison.
            var output = recorded
            if tap.sampleRate != 44_100, let resampler = StreamResampler(from: tap.sampleRate, to: 44_100, channels: 2) {
                output = resampler.process(recorded)
            }
            try writeWAV(output, rate: 44_100, to: out.appendingPathComponent("live-\(mode.rawValue)-\(preset).wav"))

            let length = audio.left.count
            var instrumental: [[Float]] = [audio.left, audio.right]
            if preset == "instrumental" {
                instrumental = [[Float](repeating: 0, count: length), [Float](repeating: 0, count: length)]
            }
            let reference = preset == "instrumental" ? try StemSplitter(weights: ModelLocation.sw).separate(left: audio.left, right: audio.right) : []
            for stem in reference where stem.name != "vocals" {
                vDSP_vadd(instrumental[0], 1, stem.left, 1, &instrumental[0], 1, vDSP_Length(length))
                vDSP_vadd(instrumental[1], 1, stem.right, 1, &instrumental[1], 1, vDSP_Length(length))
            }
            try writeWAV(instrumental, rate: 44_100, to: out.appendingPathComponent("reference-\(preset).wav"))
            guard let lag = align(output[0], to: instrumental[0]) else { print("Couldn't align the recording"); return 1 }
            let overlap = min(length, output[0].count - lag)
            let estimate = output.map { Array($0[lag ..< lag + overlap]) }
            let ref = instrumental.map { Array($0[0 ..< overlap]) }
            let sdr = Bench.sdr(reference: ref, estimate: estimate)
            // The tap adds its own offset before the pipeline; this is everything, sound in to sound out.
            print(String(format: "End to end: delay %.3f s after the clip's lead-in, %.1f s compared, \(preset) SDR vs reference %.1f dB",
                         Double(lag) / 44_100 - 2, Double(overlap) / 44_100, sdr))
            return 0
        } catch {
            print("Live test failed: \(error)")
            return 1
        }
    }

    /// Offset of `reference` inside `signal`, by coarse cross-correlation then a fine search.
    static func align(_ signal: [Float], to reference: [Float]) -> Int? {
        let factor = 8
        func decimate(_ x: [Float]) -> [Float] { stride(from: 0, to: x.count - factor, by: factor).map { x[$0] } }
        let s = decimate(signal), r = Array(decimate(reference).dropFirst(44_100 / factor).prefix(10 * 44_100 / factor))
        let skip = 44_100 / factor
        guard s.count > r.count else { return nil }
        let lags = s.count - r.count
        var correlation = [Float](repeating: 0, count: lags)
        vDSP_conv(s, 1, r, 1, &correlation, 1, vDSP_Length(lags), vDSP_Length(r.count))
        guard let best = correlation.indices.max(by: { correlation[$0] < correlation[$1] }) else { return nil }
        let coarse = (best - skip) * factor
        var bestLag = coarse, bestScore = -Float.infinity
        let window = Array(reference[44_100 ..< min(reference.count, 44_100 * 6)])
        for lag in max(0, coarse - 2 * factor)...(coarse + 2 * factor) {
            guard lag + 44_100 + window.count <= signal.count else { continue }
            var score: Float = 0
            signal.withUnsafeBufferPointer { vDSP_dotpr($0.baseAddress! + lag + 44_100, 1, window, 1, &score, vDSP_Length(window.count)) }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        return bestLag
    }

    static func writeWAV(_ channels: [[Float]], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 { channels[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: $0.count) } }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                                                               AVLinearPCMIsFloatKey: false])
        try file.write(from: buffer)
    }
}
