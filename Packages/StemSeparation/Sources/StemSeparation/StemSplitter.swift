import Accelerate
import Foundation
import MLX

/// One separated source at 44.1 kHz.
public struct SeparatedStem: Sendable {
    public let name: String
    public let left: [Float]
    public let right: [Float]
}

/// Splits a stereo mix into stems on the GPU with BS-Roformer.
///
/// Inference follows mlx-audio-separator's defaults for Roformer checkpoints: chunks of the
/// checkpoint's dim_t (9.3 s for SW, 12.8 s for Mega) every 8 seconds, recombined with a
/// Hamming-weighted overlap-add.
public final class StemSplitter: @unchecked Sendable {
    public static let sampleRate = 44_100.0

    public let config: BSRoformerConfig
    private let model: BSRoformer
    private let chunkLength: Int
    private let step: Int

    /// Loads converted weights (see `convertCheckpoint`). Half-precision weights are widened on load,
    /// so the model always runs in float32.
    public init(weights url: URL, config: BSRoformerConfig = .sw) throws {
        self.config = config
        let weights = try loadArrays(url: url).mapValues { $0.dtype == .float32 ? $0 : $0.asType(.float32) }
        model = try BSRoformer(weights: weights, config: config)
        chunkLength = config.hop * config.chunkFrames
        step = Int(8 * Self.sampleRate)
    }

    /// Separates a 44.1 kHz stereo mix. `progress` runs after each chunk; throws `CancellationError`
    /// between chunks once the calling task is cancelled.
    public func separate(left: [Float], right: [Float], progress: (Double) -> Void = { _ in }) throws -> [SeparatedStem] {
        let length = min(left.count, right.count)
        var output = [[Float]](repeating: [Float](repeating: 0, count: length), count: config.instruments.count * 2)
        try separate(left: left, right: right, progress: progress) { start, block in
            for s in block.indices {
                output[s].withUnsafeMutableBufferPointer { out in
                    block[s].withUnsafeBufferPointer { (out.baseAddress! + start).update(from: $0.baseAddress!, count: $0.count) }
                }
            }
        }
        return config.instruments.enumerated().map { i, name in
            SeparatedStem(name: name, left: output[i * 2], right: output[i * 2 + 1])
        }
    }

    /// Separates a 44.1 kHz stereo mix, handing over each stretch of the stems as soon as no later chunk
    /// can change it: `emit(start, block)`, where `block[stem * 2 + channel]` covers samples
    /// `start ..< start + block[0].count`. Stretches arrive in order and cover the mix exactly once, and
    /// memory stays at about one chunk per stem whatever the song's length (53 full-length stems would
    /// take gigabytes).
    public func separate(left: [Float], right: [Float], progress: (Double) -> Void = { _ in },
                         emit: (Int, [[Float]]) throws -> Void) throws {
        let length = min(left.count, right.count)
        let stems = config.instruments.count
        guard length > 0 else { return }

        // The reference implementation peak-normalises to 0.9; undo it afterwards so stems sum to the mix.
        var peak: Float = 0
        vDSP_maxmgv(left, 1, &peak, vDSP_Length(length))
        var peakRight: Float = 0
        vDSP_maxmgv(right, 1, &peakRight, vDSP_Length(length))
        peak = max(peak, peakRight)
        let gain: Float = peak > 0.9 ? 0.9 / peak : 1

        var planar = [Float](repeating: 0, count: 2 * length)
        planar.withUnsafeMutableBufferPointer { buffer in
            var g = gain
            vDSP_vsmul(left, 1, &g, buffer.baseAddress!, 1, vDSP_Length(length))
            vDSP_vsmul(right, 1, &g, buffer.baseAddress! + length, 1, vDSP_Length(length))
        }
        let mix = MLXArray(planar, [2, length])
        defer { Memory.clearCache() }
        var undo = 1 / gain

        if length <= chunkLength {
            // Short audio runs in one pass (padded so the STFT has room).
            let padded = length < config.nFFT ? MLX.padded(mix, widths: [0, [0, config.nFFT - length]]) : mix
            let separated = model(padded.expandedDimensions(axis: 0))[0, 0..., 0..., 0 ..< length]
            let values = separated.asArray(Float.self)
            var block = (0..<(stems * 2)).map { s in Array(values[(s * length)..<((s + 1) * length)]) }
            for s in block.indices where undo != 1 {
                block[s].withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &undo, $0.baseAddress!, 1, vDSP_Length(length)) }
            }
            try emit(0, block)
            progress(1)
            return
        }

        let windowArray = MLXArray(Self.hamming(chunkLength))
        try Self.overlapAdd(length: length, chunk: chunkLength, step: step, outputs: stems * 2, gain: undo, progress: progress,
                            emit: emit) { start in
            try Task.checkCancellation()
            let chunk = mix[0..., start ..< start + chunkLength].expandedDimensions(axis: 0)
            return (model(chunk)[0] * windowArray).asArray(Float.self)
        }
    }

    /// Hamming-weighted overlap-add of chunks every `step` samples, over a buffer one chunk long that
    /// slides along the song: before each chunk is added, everything ahead of its start is final, so
    /// it's normalised, scaled by `gain` and handed to `emit`. `windowed(start)` returns the chunk at
    /// `start` already multiplied by the window, all outputs back to back.
    static func overlapAdd(length: Int, chunk: Int, step: Int, outputs: Int, gain: Float, progress: (Double) -> Void,
                           emit: (Int, [[Float]]) throws -> Void, windowed: (Int) throws -> [Float]) throws {
        let window = hamming(chunk)
        var undo = gain
        var sums = [[Float]](repeating: [Float](repeating: 0, count: chunk), count: outputs)
        var weights = [Float](repeating: 0, count: chunk)
        var base = 0
        func release(upTo end: Int) throws {
            let count = end - base
            guard count > 0 else { return }
            var floor: Float = 1e-10
            var divisor = Array(weights[0..<count])
            vDSP_vthr(divisor, 1, &floor, &divisor, 1, vDSP_Length(count))
            var block: [[Float]] = []
            block.reserveCapacity(outputs)
            for s in sums.indices {
                var out = [Float](repeating: 0, count: count)
                vDSP_vdiv(divisor, 1, sums[s], 1, &out, 1, vDSP_Length(count))
                if undo != 1 { vDSP_vsmul(out, 1, &undo, &out, 1, vDSP_Length(count)) }
                block.append(out)
                slide(&sums[s], by: count)
            }
            slide(&weights, by: count)
            try emit(base, block)
            base = end
        }
        let starts = chunkStarts(length: length, chunk: chunk, step: step)
        for (index, start) in starts.enumerated() {
            try release(upTo: start)
            let values = try windowed(start)
            values.withUnsafeBufferPointer { v in
                for s in sums.indices {
                    sums[s].withUnsafeMutableBufferPointer { sum in
                        vDSP_vadd(sum.baseAddress!, 1, v.baseAddress! + s * chunk, 1, sum.baseAddress!, 1, vDSP_Length(chunk))
                    }
                }
            }
            vDSP_vadd(weights, 1, window, 1, &weights, 1, vDSP_Length(chunk))
            progress(Double(index + 1) / Double(starts.count))
        }
        try release(upTo: length)
    }

    /// Moves a buffer's contents `count` samples towards the front, zero-filling the end.
    private static func slide(_ buffer: inout [Float], by count: Int) {
        let total = buffer.count
        buffer.withUnsafeMutableBufferPointer { p in
            guard let start = p.baseAddress, count < total else {
                p.update(repeating: 0)
                return
            }
            memmove(start, start + count, (total - count) * MemoryLayout<Float>.stride)
            (start + total - count).update(repeating: 0, count: count)
        }
    }

    static func chunkStarts(length: Int, chunk: Int, step: Int) -> [Int] {
        let last = max(length - chunk, 0)
        var starts = Array(stride(from: 0, through: last, by: step))
        if starts.last != last { starts.append(last) }
        return starts
    }

    /// Symmetric Hamming window (numpy.hamming).
    static func hamming(_ count: Int) -> [Float] {
        guard count > 1 else { return [1] }
        return (0..<count).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(count - 1)) }
    }
}

// MARK: - Checkpoints

extension StemSplitter {
    /// Converts a PyTorch BS-Roformer checkpoint to safetensors (mlx-audio-separator key names),
    /// which loads in about a second. Returns the number of tensors written.
    /// `widen` stores float32; otherwise tensors keep the checkpoint's precision (half the size for a
    /// float16 checkpoint; `StemSplitter` widens them as it loads).
    @discardableResult
    public static func convertCheckpoint(_ checkpoint: URL, to destination: URL, config: BSRoformerConfig = .sw,
                                         widen: Bool = true) throws -> Int {
        let tensors = try TorchCheckpoint.read(checkpoint)
        let hasLinear = tensors.keys.contains { $0.wholeMatch(of: /layers\.\d+\.2\..+/) != nil }
        var converted: [String: MLXArray] = [:]
        for (key, value) in tensors {
            guard let name = mlxName(forTorchKey: key, hasLinearTransformers: hasLinear) else { continue }
            converted[name] = widen ? value.asType(.float32) : value
        }
        // Fail now rather than at first use if the checkpoint doesn't fit this architecture.
        _ = try BSRoformer(weights: converted, config: config)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.safetensors")
        try save(arrays: converted, metadata: ["format": "mlx", "source": checkpoint.lastPathComponent], url: partial)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return converted.count
    }

    /// Port of mlx-audio-separator's `convert_torch_to_mlx_weights` key mapping.
    static func mlxName(forTorchKey key: String, hasLinearTransformers: Bool) -> String? {
        if key.contains("rotary_embed.freqs") { return nil }
        var name = key.replacingOccurrences(of: ".gamma", with: ".weight")

        if name.contains("band_split.to_features.") {
            let parts = name.split(separator: ".").map(String.init)
            if parts.count >= 5, Int(parts[2]) != nil {
                let rest = parts[4...].joined(separator: ".")
                if parts[3] == "0" { name = "band_split.to_features_\(parts[2]).norm.\(rest)" }
                if parts[3] == "1" { name = "band_split.to_features_\(parts[2]).linear.\(rest)" }
            }
        }

        if let match = name.wholeMatch(of: /layers\.(\d+)\.([012])\.(.+)/) {
            let names = hasLinearTransformers
                ? ["linear_transformer", "time_transformer", "freq_transformer"]
                : ["time_transformer", "freq_transformer", "freq_transformer"]
            name = "layers_\(match.1).\(names[Int(match.2)!]).\(match.3)"
        }

        if let match = name.firstMatch(of: /(\.layers)\.(\d+)\.([01])\./) {
            let sub = match.3 == "0" ? "attn" : "ff"
            name = "\(name[..<match.range.lowerBound]).layers_\(match.2).\(sub).\(name[match.range.upperBound...])"
        }

        if name.contains("mask_estimators.") {
            name = name.replacing(/mask_estimators\.(\d+)/) { "mask_estimators_\($0.1)" }
            name = name.replacing(/to_freqs\.(\d+)\.0\./) { "to_freqs_\($0.1)." }
        }

        name = name.replacing(/\.net\.(\d+)\./) { ".net.layers.\($0.1)." }
        name = name.replacing(/\.to_out\.(\d+)\./) { ".to_out.layers.\($0.1)." }
        name = name.replacing(/(to_freqs_\d+)\.(\d+)\./) { "\($0.1).layers.\($0.2)." }
        return name
    }
}
