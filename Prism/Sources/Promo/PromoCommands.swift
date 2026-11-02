#if PROMO
import AVFoundation
import Foundation
import StemSeparation

/// Tools behind the launch film (built only with `PRISM_PROMO=PROMO`, never in the shipping app).
nonisolated enum PromoCommands {
    /// Writes 32-bit float, so stems that sum past full scale aren't clipped.
    static func writeFloatWAV(_ channels: [[Float]], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 { channels[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: $0.count) } }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                                               AVLinearPCMIsFloatKey: true])
        try file.write(from: buffer)
    }

    /// `Prism --capture-app <bundle id> --seconds s --out file.wav`
    ///
    /// Records an app through the same tap the live engine uses. The app is muted while it runs,
    /// and nothing goes to the speakers.
    static func capture(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let bundle = value("--capture-app"), let out = value("--out") else { return 1 }
        let seconds = value("--seconds").flatMap(Double.init) ?? 30
        do {
            let target = TapTarget.apps([bundle])
            let processes = ProcessTap.processes(for: target)
            guard !processes.isEmpty else { print("\(bundle) has no audio process yet"); return 1 }
            let tap = try ProcessTap(target: target, processes: processes)
            let rate = tap.sampleRate
            let ring = RingBuffer(channels: 2, capacity: Int(rate * (seconds + 5)))
            try tap.start { input, stride, output, frames in
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                ring.write(interleaved: input, stride: stride, frames: frames)
            }
            print("recording \(Int(rate)) Hz")
            fflush(stdout)
            Thread.sleep(forTimeInterval: seconds)
            tap.stop()
            let audio = ring.readAll()
            guard audio.count == 2 else { print("nothing recorded"); return 1 }
            try writeFloatWAV(audio, rate: rate, to: URL(fileURLWithPath: out))
            print("wrote \(Double(audio[0].count) / rate) s")
            return 0
        } catch {
            print("capture failed: \(error)")
            return 1
        }
    }

    /// `Prism --promo-stems <audio> --out dir`
    ///
    /// Runs a whole file through the streaming separator with the Studio plan: the stems the live
    /// engine would produce, sample-aligned with the input, one WAV each at 44.1 kHz.
    static func stems(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let path = value("--promo-stems"), let out = value("--out") else { return 1 }
        do {
            let directory = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audio = try AudioDecoding.read(URL(fileURLWithPath: path), offset: 0, seconds: 3_600)
            let plan = StreamingPlan.seconds(context: 9.3, step: 3, lookahead: 3)   // Studio
            let separator = try ChunkSeparator(weights: ModelLocation.sw, precision: .bfloat16)
            let streaming = StreamingSeparator(separator: separator, plan: plan)
            // Silence after the end flushes the lookahead.
            let tail = [Float](repeating: 0, count: plan.latency + plan.step)
            streaming.append(left: audio.left + tail, right: audio.right + tail)
            var outputs = [[Float]](repeating: [], count: streaming.outputChannels)
            var chunk = 0
            while streaming.canProcess {
                let block = streaming.process()
                for c in block.indices { outputs[c] += block[c] }
                chunk += 1
                if chunk % 10 == 0 { print("chunk \(chunk)"); fflush(stdout) }
            }
            for (i, name) in separator.config.instruments.enumerated() {
                let left = Array(outputs[i * 2].prefix(audio.left.count)), right = Array(outputs[i * 2 + 1].prefix(audio.left.count))
                try writeFloatWAV([left, right], rate: StreamingSeparator.sampleRate,
                                  to: directory.appendingPathComponent("\(name).wav"))
            }
            try writeFloatWAV([audio.left, audio.right], rate: StreamingSeparator.sampleRate,
                              to: directory.appendingPathComponent("mix.wav"))
            print("wrote \(separator.config.instruments.count) stems")
            return 0
        } catch {
            print("stems failed: \(error)")
            return 1
        }
    }
}
#endif
