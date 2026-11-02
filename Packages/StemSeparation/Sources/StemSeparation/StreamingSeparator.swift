import Accelerate
import Foundation
import MLX

/// Precision the transformer layers run in. The STFT, masks and inverse STFT always stay in float32.
public enum ComputePrecision: String, Sendable, CaseIterable {
    case float32, float16, bfloat16

    var dtype: DType {
        switch self {
        case .float32: .float32
        case .float16: .float16
        case .bfloat16: .bfloat16
        }
    }
}

/// Runs BS-Roformer on one stretch of 44.1 kHz stereo at a time, for callers that schedule their own chunks.
public final class ChunkSeparator: @unchecked Sendable {
    public let config: BSRoformerConfig
    private let model: BSRoformer

    public init(weights url: URL, config: BSRoformerConfig = .sw, precision: ComputePrecision = .float32) throws {
        self.config = config
        let dtype = precision.dtype
        let weights = try loadArrays(url: url).mapValues { $0.dtype == dtype ? $0 : $0.asType(dtype) }
        model = try BSRoformer(weights: weights, config: config)
    }

    public var stemCount: Int { config.instruments.count }

    /// Where the last `separate` call spent its time, in seconds.
    public struct Timing: Sendable {
        /// Scaling and copying the input in.
        public var prepare: Double
        /// Building MLX's lazy graph on the CPU.
        public var graph: Double
        /// Running the graph on the GPU (includes any wait for the GPU to be free).
        public var gpu: Double
        /// Copying the stems back out and undoing the scaling.
        public var readback: Double
        public var total: Double { prepare + graph + gpu + readback }
    }

    public private(set) var lastTiming = Timing(prepare: 0, graph: 0, gpu: 0, readback: 0)

    /// Separates `count` samples starting at each pointer. Returns the stems back to back,
    /// `[stem0 left, stem0 right, stem1 left, …]`, each `count` samples long.
    public func separate(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) -> [Float] {
        let clock = ContinuousClock()
        let started = clock.now
        // The model was trained on mixes peaking at 0.9 or less; scale louder chunks down and undo it after.
        var peak: Float = 0, peakRight: Float = 0
        vDSP_maxmgv(left, 1, &peak, vDSP_Length(count))
        vDSP_maxmgv(right, 1, &peakRight, vDSP_Length(count))
        peak = max(peak, peakRight)
        var gain: Float = peak > 0.9 ? 0.9 / peak : 1

        var planar = [Float](repeating: 0, count: 2 * count)
        planar.withUnsafeMutableBufferPointer { buffer in
            vDSP_vsmul(left, 1, &gain, buffer.baseAddress!, 1, vDSP_Length(count))
            vDSP_vsmul(right, 1, &gain, buffer.baseAddress! + count, 1, vDSP_Length(count))
        }
        let padding = max(config.nFFT - count, 0)
        var mix = MLXArray(planar, [2, count])
        if padding > 0 { mix = MLX.padded(mix, widths: [0, [0, padding]]) }
        let prepared = clock.now
        let output = model(mix.expandedDimensions(axis: 0))[0, 0..., 0..., 0 ..< count]
        let built = clock.now
        eval(output)
        let evaluated = clock.now
        var values = output.asArray(Float.self)
        if gain != 1 {
            var undo = 1 / gain
            vDSP_vsmul(values, 1, &undo, &values, 1, vDSP_Length(values.count))
        }
        let finished = clock.now
        lastTiming = Timing(prepare: (prepared - started).seconds, graph: (built - prepared).seconds,
                            gpu: (evaluated - built).seconds, readback: (finished - evaluated).seconds)
        return values
    }

    /// Frees MLX's buffer cache (call when separation pauses for a while).
    public func releaseCache() { Memory.clearCache() }
}

/// How live separation slices the incoming stream.
///
/// Each chunk feeds the model `context` samples ending `lookahead` samples after the stretch it
/// emits, so the model hears what comes next before committing to a stem. Consecutive emissions
/// overlap by `crossfade` samples, which are blended so chunk seams don't click. From a sample
/// arriving to its stems being ready takes `latency` samples plus the time the model takes.
public struct StreamingPlan: Sendable, Hashable, CustomStringConvertible {
    public var context: Int
    public var step: Int
    public var lookahead: Int
    public var crossfade: Int

    public init(context: Int, step: Int, lookahead: Int, crossfade: Int = 2_048) {
        precondition(step > 0 && lookahead >= 0 && crossfade >= 0 && context >= step + lookahead + crossfade)
        self.context = context
        self.step = step
        self.lookahead = lookahead
        self.crossfade = crossfade
    }

    /// Plan in seconds at 44.1 kHz.
    public static func seconds(context: Double, step: Double, lookahead: Double, crossfade: Double = 0.05) -> StreamingPlan {
        let rate = StreamingSeparator.sampleRate
        return StreamingPlan(context: Int(context * rate), step: Int(step * rate), lookahead: Int(lookahead * rate),
                             crossfade: Int(crossfade * rate))
    }

    public var latency: Int { step + crossfade + lookahead }

    public var description: String {
        let s = { (n: Int) in String(format: "%.2f", Double(n) / StreamingSeparator.sampleRate) }
        return "context \(s(context)) step \(s(step)) lookahead \(s(lookahead)) xfade \(s(crossfade))"
    }
}

/// Separates an endless 44.1 kHz stereo stream in fixed steps.
///
/// Not thread-safe: append and process from one thread.
public final class StreamingSeparator: @unchecked Sendable {
    public static let sampleRate = 44_100.0

    public let separator: ChunkSeparator
    public private(set) var plan: StreamingPlan

    /// Input history. `history[0]` is absolute sample `origin`.
    private var historyLeft: [Float] = []
    private var historyRight: [Float] = []
    private var origin = 0
    private var received = 0
    private var emitted = 0
    /// The previous chunk's estimate of the next `crossfade` samples, per output channel.
    private var tail: [[Float]] = []
    private let fadeIn: [Float]

    public init(separator: ChunkSeparator, plan: StreamingPlan) {
        self.separator = separator
        self.plan = plan
        fadeIn = (0..<plan.crossfade).map { Float($0 + 1) / Float(plan.crossfade + 1) }
    }

    /// Stems plus the dry mix: `[stem0 L, stem0 R, …, mix L, mix R]`.
    public var outputChannels: Int { separator.stemCount * 2 + 2 }

    /// Samples received but not yet emitted.
    public var pending: Int { received - emitted }

    /// True once there's enough audio for the next step.
    public var canProcess: Bool { received - emitted >= plan.latency }

    public func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        historyLeft.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
        historyRight.append(contentsOf: UnsafeBufferPointer(start: right, count: count))
        received += count
    }

    public func append(left: [Float], right: [Float]) {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in append(left: l.baseAddress!, right: r.baseAddress!, count: min(l.count, r.count)) }
        }
    }

    /// Forgets everything (a new track, a seek).
    public func reset() {
        historyLeft.removeAll(keepingCapacity: true)
        historyRight.removeAll(keepingCapacity: true)
        origin = 0
        received = 0
        emitted = 0
        tail = []
    }

    /// Longest stretch one chunk may emit when catching up: whatever leaves the model two seconds
    /// of past context.
    private var maximumStep: Int {
        max(plan.step, plan.context - plan.lookahead - plan.crossfade - Int(2 * Self.sampleRate))
    }

    /// Runs the model once and returns the next stretch of every output channel: `plan.step`
    /// samples, or more (up to `maximumStep`) when audio has piled up because the model fell
    /// behind, so a slow GPU costs latency rather than dropouts. Call only when `canProcess`.
    public func process() -> [[Float]] {
        precondition(canProcess)
        let step = min(max(plan.step, received - emitted - plan.lookahead - plan.crossfade), maximumStep)
        let fade = plan.crossfade
        let end = emitted + step + fade + plan.lookahead
        // Early in a stream there's less history than a full context. Pad it with silence so every
        // chunk costs the same: a short first chunk would finish quickly and set up an underrun
        // when the next, longer one doesn't.
        let start = end - plan.context
        let count = plan.context
        let stems: [Float]
        if start >= origin {
            let offset = start - origin
            stems = historyLeft.withUnsafeBufferPointer { l in
                historyRight.withUnsafeBufferPointer { r in
                    separator.separate(left: l.baseAddress! + offset, right: r.baseAddress! + offset, count: count)
                }
            }
        } else {
            let padding = [Float](repeating: 0, count: origin - start)
            let left = padding + historyLeft[0 ..< end - origin], right = padding + historyRight[0 ..< end - origin]
            stems = left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in separator.separate(left: l.baseAddress!, right: r.baseAddress!, count: count) }
            }
        }

        // The emitted stretch plus the crossfade tail sit at `emitted - start` within the chunk.
        let first = emitted - start
        let channels = outputChannels
        var output = [[Float]](repeating: [], count: channels)
        var nextTail = [[Float]](repeating: [], count: channels)
        for c in 0..<(channels - 2) {
            let base = c * count + first
            var block = Array(stems[base ..< base + step])
            if tail.count == channels {
                // Blend the previous chunk's estimate into this one.
                for i in 0..<fade { block[i] = tail[c][i] + (block[i] - tail[c][i]) * fadeIn[i] }
            }
            output[c] = block
            nextTail[c] = Array(stems[base + step ..< base + step + fade])
        }
        let mixStart = emitted - origin
        output[channels - 2] = Array(historyLeft[mixStart ..< mixStart + step])
        output[channels - 1] = Array(historyRight[mixStart ..< mixStart + step])
        tail = nextTail
        emitted += step

        // Drop history the next chunk won't need.
        let keepFrom = max(origin, emitted + plan.latency - plan.context)
        let drop = keepFrom - origin
        if drop > 44_100 {
            historyLeft.removeFirst(drop)
            historyRight.removeFirst(drop)
            origin = keepFrom
        }
        return output
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
