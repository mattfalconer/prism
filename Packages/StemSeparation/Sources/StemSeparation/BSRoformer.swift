import Foundation
import MLX

/// Hyper-parameters of a BS-Roformer checkpoint.
public struct BSRoformerConfig: Sendable {
    public var dim = 256
    public var depth = 12
    public var channels = 2
    public var timeTransformerDepth = 1
    public var freqTransformerDepth = 1
    public var dimHead = 64
    public var heads = 8
    public var maskEstimatorDepth = 2
    public var mlpExpansion = 4
    public var nFFT = 2048
    public var hop = 512
    /// STFT frames per inference chunk (the checkpoint's inference dim_t minus one).
    public var chunkFrames = 800
    public var freqsPerBand: [Int]
    /// Output order of the mask estimators.
    public var instruments: [String]

    /// The 62 bands both published checkpoints use.
    static let standardBands = Array(repeating: 2, count: 24) + Array(repeating: 4, count: 12)
        + Array(repeating: 12, count: 8) + Array(repeating: 24, count: 8)
        + Array(repeating: 48, count: 8) + [128, 129]

    /// BS-Roformer SW by jarredou: six stems, 62 bands.
    public static let sw = BSRoformerConfig(freqsPerBand: standardBands,
                                            instruments: ["bass", "drums", "other", "vocals", "guitar", "piano"])

    /// MVSep Mega v1 by ZFTurbo: 53 instrument categories. They overlap (drums also holds kick, snare,
    /// hh and toms; vocal holds lead-vocal and back-vocal; guitar the electric and acoustic ones), and
    /// most are silent in any one song.
    public static let mega53 = BSRoformerConfig(mlpExpansion: 2, chunkFrames: 1100, freqsPerBand: standardBands, instruments: [
        "accordion", "acoustic-guitar", "back-vocal", "banjo", "bass", "bassoon", "bells", "bowed_strings", "brass",
        "cello", "clarinet", "congas", "digital-piano", "dobro", "double-bass", "drums", "electric-guitar", "flute",
        "french-horn", "glockenspiel", "guitar", "harmonica", "harp", "harpsichord", "hh", "keys", "kick", "lead-vocal",
        "mandolin", "marimba", "oboe", "organ", "percussion", "piano", "saxophone", "sitar", "snare", "strings", "synth",
        "tambourine", "timpani", "toms", "triangle", "trombone", "trumpet", "tuba", "ukulele", "viola", "violin", "vocal",
        "wind", "wind-chimes", "woodwind",
    ])
}

/// Weights keyed by the mlx-audio-separator naming scheme (see `BSRoformerWeights`).
typealias Weights = [String: MLXArray]

enum ModelError: LocalizedError {
    case missingWeight(String)
    var errorDescription: String? {
        switch self {
        case .missingWeight(let key): "The stem model is incomplete (missing \(key)). Remove it in Settings and download it again."
        }
    }
}

private func weight(_ weights: Weights, _ key: String) throws -> MLXArray {
    guard let value = weights[key] else { throw ModelError.missingWeight(key) }
    return value
}

// MARK: - Layers

private struct Linear {
    let weight: MLXArray
    let bias: MLXArray?

    init(_ w: Weights, _ prefix: String, bias: Bool = true) throws {
        weight = try StemSeparation.weight(w, "\(prefix).weight").T
        self.bias = bias ? try StemSeparation.weight(w, "\(prefix).bias") : nil
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        if let bias { return addMM(bias, x, weight) }
        return matmul(x, weight)
    }
}

/// `x / max(‖x‖, ε) · √dim · γ` (lucidrains' RMSNorm, which is an L2 norm in disguise).
private struct L2Norm {
    let gain: MLXArray

    init(_ w: Weights, _ prefix: String) throws {
        let gamma = try weight(w, "\(prefix).weight")
        gain = gamma * Float(gamma.dim(0)).squareRoot()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let norm = sqrt(sum(x * x, axis: -1, keepDims: true))
        return x / maximum(norm, 1e-12) * gain
    }
}

private struct Attention {
    let norm: L2Norm
    let toQKV: Linear
    let toGates: Linear
    let toOut: Linear
    let heads: Int
    let dimHead: Int

    init(_ w: Weights, _ prefix: String, heads: Int, dimHead: Int) throws {
        norm = try L2Norm(w, "\(prefix).norm")
        toQKV = try Linear(w, "\(prefix).to_qkv", bias: false)
        toGates = try Linear(w, "\(prefix).to_gates")
        toOut = try Linear(w, "\(prefix).to_out.layers.0", bias: false)
        self.heads = heads
        self.dimHead = dimHead
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        let batch = input.dim(0), length = input.dim(1)
        let x = norm(input)
        // (b, n, 3·h·d) → 3 × (b, h, n, d)
        let qkv = toQKV(x).reshaped(batch, length, 3, heads, dimHead).transposed(2, 0, 3, 1, 4)
        // Interleaved rotary embeddings, as rotary-embedding-torch applies them.
        let q = RoPE(qkv[0], dimensions: dimHead, traditional: true, base: 10_000, scale: 1, offset: 0)
        let k = RoPE(qkv[1], dimensions: dimHead, traditional: true, base: 10_000, scale: 1, offset: 0)
        var out = scaledDotProductAttention(queries: q, keys: k, values: qkv[2],
                                            scale: 1 / Float(dimHead).squareRoot(), mask: nil)
        // Per-head sigmoid gates: (b, n, h) → (b, h, n, 1).
        let gates = sigmoid(toGates(x)).transposed(0, 2, 1).expandedDimensions(axis: -1)
        out = (out * gates).transposed(0, 2, 1, 3).reshaped(batch, length, heads * dimHead)
        return toOut(out)
    }
}

private struct FeedForward {
    let norm: L2Norm
    let up: Linear
    let down: Linear

    init(_ w: Weights, _ prefix: String) throws {
        norm = try L2Norm(w, "\(prefix).net.layers.0")
        up = try Linear(w, "\(prefix).net.layers.1")
        down = try Linear(w, "\(prefix).net.layers.4")
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = up(norm(x))
        // Exact (erf) GELU, matching PyTorch's default.
        return down(0.5 * h * (1 + erf(h / Float(2).squareRoot())))
    }
}

private struct Transformer {
    let layers: [(attention: Attention, feedForward: FeedForward)]

    init(_ w: Weights, _ prefix: String, depth: Int, config: BSRoformerConfig) throws {
        layers = try (0..<depth).map { i in
            (try Attention(w, "\(prefix).layers_\(i).attn", heads: config.heads, dimHead: config.dimHead),
             try FeedForward(w, "\(prefix).layers_\(i).ff"))
        }
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        var x = input
        for layer in layers {
            x = layer.attention(x) + x
            x = layer.feedForward(x) + x
        }
        return x
    }
}

/// One small MLP per band, ending in a GLU.
private struct MaskEstimator {
    let bands: [(first: Linear, last: Linear)]

    init(_ w: Weights, _ prefix: String, bandCount: Int) throws {
        bands = try (0..<bandCount).map { i in
            (try Linear(w, "\(prefix).to_freqs_\(i).layers.0"), try Linear(w, "\(prefix).to_freqs_\(i).layers.2"))
        }
    }

    /// (b, t, bands, dim) → (b, t, Σ band inputs)
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let outputs = bands.enumerated().map { i, mlp in
            let h = mlp.last(tanh(mlp.first(x[.ellipsis, i, 0...])))
            let halves = h.split(parts: 2, axis: -1)
            return halves[0] * sigmoid(halves[1])
        }
        return concatenated(outputs, axis: -1)
    }
}

// MARK: - Model

/// Band-Split RoFormer (Lu et al., 2023) for music source separation, ported from
/// mlx-audio-separator's MLX implementation (MIT).
final class BSRoformer {
    let config: BSRoformerConfig
    private let spectral: SpectralTransform
    private let bandSplit: [(norm: L2Norm, linear: Linear)]
    private let bandSplitPoints: [Int]
    private let blocks: [(time: Transformer, freq: Transformer)]
    private let finalNorm: L2Norm
    private let maskEstimators: [MaskEstimator]
    private let computeType: DType

    init(weights w: Weights, config: BSRoformerConfig) throws {
        self.config = config
        computeType = try weight(w, "final_norm.weight").dtype
        spectral = SpectralTransform(nFFT: config.nFFT, hop: config.hop)
        let bandInputs = config.freqsPerBand.map { $0 * 2 * config.channels }
        var points: [Int] = []
        var total = 0
        for width in bandInputs.dropLast() { total += width; points.append(total) }
        bandSplitPoints = points
        bandSplit = try bandInputs.indices.map { i in
            (try L2Norm(w, "band_split.to_features_\(i).norm"), try Linear(w, "band_split.to_features_\(i).linear"))
        }
        blocks = try (0..<config.depth).map { i in
            (try Transformer(w, "layers_\(i).time_transformer", depth: config.timeTransformerDepth, config: config),
             try Transformer(w, "layers_\(i).freq_transformer", depth: config.freqTransformerDepth, config: config))
        }
        finalNorm = try L2Norm(w, "final_norm")
        maskEstimators = try config.instruments.indices.map {
            try MaskEstimator(w, "mask_estimators_\($0)", bandCount: bandInputs.count)
        }
    }

    /// (batch, channels, samples) → (batch, stems, channels, samples)
    func callAsFunction(_ audio: MLXArray) -> MLXArray {
        let batch = audio.dim(0), channels = audio.dim(1), length = audio.dim(2)
        let bins = config.nFFT / 2 + 1

        // Complex spectrum, (b·c, t, f) → features (b, t, f·c·2) ordered [freq][channel][re, im].
        let spectrum = spectral.stft(audio.reshaped(batch * channels, length))
        let frames = spectrum.dim(1)
        let real = spectrum.realPart(), imag = spectrum.imaginaryPart()
        // The transformer runs in the weights' precision; the STFT and masking stay in float32.
        let features = stacked([real, imag], axis: -1)
            .reshaped(batch, channels, frames, bins, 2)
            .transposed(0, 2, 3, 1, 4)
            .reshaped(batch, frames, bins * channels * 2)
            .asType(computeType)

        // Band split → (b, t, bands, dim)
        let splits = split(features, indices: bandSplitPoints, axis: -1)
        var x = stacked(zip(splits, bandSplit).map { $1.linear($1.norm($0)) }, axis: -2)

        let bands = x.dim(2), dim = config.dim
        for block in blocks {
            // Attend across time within each band, then across bands within each frame.
            var y = x.transposed(0, 2, 1, 3).reshaped(batch * bands, frames, dim)
            y = block.time(y)
            x = y.reshaped(batch, bands, frames, dim).transposed(0, 2, 1, 3)
            y = block.freq(x.reshaped(batch * frames, bands, dim))
            x = y.reshaped(batch, frames, bands, dim)
        }
        x = finalNorm(x)

        // Complex masks (b, s, t, f, c, 2) applied to the mixture spectrum (b, 1, t, f, c).
        let stems = config.instruments.count
        let masks = stacked(maskEstimators.map { $0(x) }, axis: 1)
            .reshaped(batch, stems, frames, bins, channels, 2)
            .asType(.float32)
        let maskReal = masks[.ellipsis, 0], maskImag = masks[.ellipsis, 1]
        let mixReal = real.reshaped(batch, channels, frames, bins).transposed(0, 2, 3, 1).expandedDimensions(axis: 1)
        let mixImag = imag.reshaped(batch, channels, frames, bins).transposed(0, 2, 3, 1).expandedDimensions(axis: 1)
        let outReal = mixReal * maskReal - mixImag * maskImag
        let outImag = mixReal * maskImag + mixImag * maskReal

        // (b, s, t, f, c) → (b·s·c, t, f) for the inverse transform.
        let toFrames = { (part: MLXArray) in
            part.transposed(0, 1, 4, 2, 3).reshaped(batch * stems * channels, frames, bins)
        }
        let separated = toFrames(outReal) + toFrames(outImag) * MLXArray(real: 0, imaginary: 1)
        return spectral.istft(separated, length: length).reshaped(batch, stems, channels, length)
    }
}
