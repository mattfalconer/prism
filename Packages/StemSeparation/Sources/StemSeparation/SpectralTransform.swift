import Foundation
import MLX

/// `torch.stft`/`torch.istft` as BS-Roformer uses them: `center=True` with reflect padding,
/// a periodic Hann window, one-sided spectrum, no normalisation.
///
/// Frames are built from hop-sized blocks, so `nFFT` must be a multiple of `hop`.
struct SpectralTransform {
    let nFFT: Int
    let hop: Int
    private let window: MLXArray
    private let windowSquared: [Float]

    init(nFFT: Int, hop: Int) {
        precondition(nFFT % hop == 0, "nFFT must be a multiple of hop")
        self.nFFT = nFFT
        self.hop = hop
        let hann = (0..<nFFT).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(nFFT)) }
        window = MLXArray(hann)
        windowSquared = hann.map { $0 * $0 }
    }

    private var blocksPerFrame: Int { nFFT / hop }

    /// Number of frames `stft` produces for `length` samples.
    func frameCount(for length: Int) -> Int { 1 + length / hop }

    /// (batch, samples) real → (batch, frames, nFFT/2 + 1) complex.
    func stft(_ signal: MLXArray) -> MLXArray {
        let batch = signal.dim(0), length = signal.dim(1)
        let pad = nFFT / 2
        precondition(length > pad, "signal too short for reflect padding")
        // Reflect padding mirrors around the edge samples without repeating them.
        let left = signal.take(MLXArray((1...pad).reversed().map(Int32.init)), axis: 1)
        let right = signal.take(MLXArray((length - pad - 1 ..< length - 1).reversed().map(Int32.init)), axis: 1)
        let padded = concatenated([left, signal, right], axis: 1)

        let frames = frameCount(for: length)
        let k = blocksPerFrame
        let blocks = padded[0..., 0 ..< (frames + k - 1) * hop].reshaped(batch, frames + k - 1, hop)
        // Frame f is blocks f ..< f + k laid end to end.
        let framed = concatenated((0..<k).map { blocks[0..., $0 ..< $0 + frames, 0...] }, axis: -1)
        return rfft(framed * window, axis: -1)
    }

    /// (batch, frames, nFFT/2 + 1) complex → (batch, length) real.
    func istft(_ spectrum: MLXArray, length: Int) -> MLXArray {
        istft(spectrum, firstFrame: 0, totalFrames: spectrum.dim(1), samples: 0 ..< length)
    }

    /// Samples `samples` of the inverse transform of a `totalFrames`-frame spectrum, given only its
    /// frames from `firstFrame` on (enough of them to cover `samples`).
    func istft(_ spectrum: MLXArray, firstFrame: Int, totalFrames: Int, samples: Range<Int>) -> MLXArray {
        let batch = spectrum.dim(0), frames = spectrum.dim(1)
        let k = blocksPerFrame
        let framed = (irfft(spectrum, n: nFFT, axis: -1) * window).reshaped(batch, frames, k, hop)

        // Overlap-add: output block j collects block i of frame j − i.
        var sum = padded(framed[0..., 0..., 0, 0...], widths: [0, [0, k - 1], 0])
        for i in 1..<k {
            sum = sum + padded(framed[0..., 0..., i, 0...], widths: [0, [i, k - 1 - i], 0])
        }
        let signal = sum.reshaped(batch, (frames + k - 1) * hop)

        // Padded position p = n + nFFT/2 sits at p − firstFrame·hop in `signal`.
        let start = samples.lowerBound + nFFT / 2 - firstFrame * hop
        precondition(start >= 0 && start + samples.count <= signal.dim(1), "the frames don't cover the samples")
        let envelope = squaredWindowEnvelope(frames: totalFrames)[samples.lowerBound + nFFT / 2 ..< samples.upperBound + nFFT / 2]
        return signal[0..., start ..< start + samples.count] / maximum(MLXArray(Array(envelope)), 1e-11)
    }

    /// Overlap-added squared window, which `istft` divides out for perfect reconstruction.
    private func squaredWindowEnvelope(frames: Int) -> [Float] {
        var envelope = [Float](repeating: 0, count: (frames - 1) * hop + nFFT)
        for f in 0..<frames {
            let offset = f * hop
            for n in 0..<nFFT { envelope[offset + n] += windowSquared[n] }
        }
        return envelope
    }
}
