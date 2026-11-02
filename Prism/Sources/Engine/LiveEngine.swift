import Accelerate
import AudioToolbox
import Foundation
import MLX
import StemSeparation
import Synchronization
import os

/// The live pipeline: tap → input ring → worker (resample, BS-Roformer, resample) → output ring →
/// real-time mixer → speakers.
///
/// Every stem reaches the output ring separately, so gains, mutes and presets act at the speaker
/// end and are heard instantly, whatever the separation latency.
nonisolated final class LiveEngine: @unchecked Sendable {
    /// Gain slots: one per model stem (model order), then the dry mix.
    let stemNames: [String]
    var slotCount: Int { stemNames.count + 1 }

    private let tap: ProcessTap
    private let separator: ChunkSeparator
    private let inputRing: RingBuffer
    private let outputRing: RingBuffer
    private let rate: Double

    // Shared with the UI. Plain floats: word-sized and only ever written whole.
    let targetGains: UnsafeMutablePointer<Float>
    private let currentGains: UnsafeMutablePointer<Float>
    /// Peak level per slot since the UI last read it (pre-fader, so muted stems still show activity).
    let meters: UnsafeMutablePointer<Float>

    // Control.
    private let hold = Atomic<Bool>(false)
    private let flushRequests = Atomic<Int>(0)
    private let discardTarget = Atomic<Int>(-1)
    private let planRequest = Mutex<StreamingPlan?>(nil)
    private let running = Atomic<Bool>(true)
    private let gpuFailed = Atomic<Bool>(false)

    // Statistics.
    private let fedFrames = Atomic<Int>(0)
    private let playedFrames = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)
    private let chunkMilliseconds = Atomic<Int>(0)
    private let inputActive = Atomic<Bool>(false)
    private let playing = Atomic<Bool>(false)
    private let currentPlan: Mutex<StreamingPlan>
    /// The plan's latency in model samples, for the real-time thread.
    private let planLatency: Atomic<Int>
    /// The plan's step in device frames: the most compute headroom worth buffering.
    private let planStep: Atomic<Int>

    // Performance records, drained by the UI's recorder.
    private let chunkRecords = Mutex<[ChunkRecord]>([])
    private let callbackPeakNanos = Atomic<Int>(0)
    /// CPU time the audio thread itself used in the slowest callback: far below the wall time
    /// means the thread was kept waiting (preempted), not slow.
    private let callbackPeakCPUNanos = Atomic<Int>(0)
    private let lateCallbacks = Atomic<Int>(0)
    private let overloads = Atomic<Int>(0)
    private var overloadListener: AudioListener?
    private let callbackFrames = Atomic<Int>(0)
    private let signposter = OSSignposter(subsystem: "com.mattfalconer.Prism", category: .pointsOfInterest)

    // Real-time thread state (touched only by the IO callback).
    private enum OutputState { case buffering, priming(Int), playing }
    private var outputState = OutputState.buffering
    private var master: Float = 0
    private var silentRun = 0
    private var pendingSilence = 0
    /// Extra buffering learned from underruns (device frames).
    private var marginBump = 0
    private var lastDiscard = -1
    private let mixLeft: UnsafeMutablePointer<Float>
    private let mixRight: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private static let maxFrames = 4_096


    /// Testing: also copy the speaker feed here, and optionally keep the speakers silent.
    var recording: RingBuffer?
    var silenceOutput = false

    init(tap: ProcessTap, separator: ChunkSeparator, plan: StreamingPlan) {
        self.tap = tap
        self.separator = separator
        stemNames = separator.config.instruments
        rate = tap.sampleRate
        let slots = separator.config.instruments.count + 1
        inputRing = RingBuffer(channels: 2, capacity: Int(rate * 20))
        // Even Studio with catch-up keeps under ~12 s queued.
        outputRing = RingBuffer(channels: slots * 2, capacity: Int(rate * 20))
        targetGains = .allocate(capacity: slots)
        targetGains.initialize(repeating: 1, count: slots)
        targetGains[slots - 1] = 0
        currentGains = .allocate(capacity: slots)
        currentGains.initialize(from: targetGains, count: slots)
        meters = .allocate(capacity: slots)
        meters.initialize(repeating: 0, count: slots)
        mixLeft = .allocate(capacity: Self.maxFrames)
        mixRight = .allocate(capacity: Self.maxFrames)
        scratch = .allocate(capacity: Self.maxFrames * 2)
        currentPlan = Mutex(plan)
        planLatency = Atomic(plan.latency)
        planStep = Atomic(Int(Double(plan.step) * tap.sampleRate / StreamingSeparator.sampleRate))
    }

    deinit {
        targetGains.deallocate()
        currentGains.deallocate()
        meters.deallocate()
        mixLeft.deallocate()
        mixRight.deallocate()
        scratch.deallocate()
    }

    var sampleRate: Double { rate }
    var outputDeviceName: String { tap.outputDeviceName }
    var outputDeviceID: AudioObjectID { tap.outputDeviceID }

    // MARK: Lifecycle

    func start() throws {
        let plan = currentPlan.withLock { $0 }
        // The worker holds the engine until it has finished its last chunk, so stopping never waits on
        // the GPU and the engine can be let go straight away. (The separator lets one chunk run at a time.)
        let retained = Unmanaged.passRetained(self)
        let thread = Thread { retained.takeRetainedValue().work(plan: plan) }
        thread.name = "Prism separation"
        thread.qualityOfService = .userInteractive
        thread.start()
        overloadListener = AudioObjects.listen(tap.deviceID, kAudioDeviceProcessorOverload, queue: .global()) { [weak self] in
            self?.overloads.add(1, ordering: .relaxed)
        }
        do {
            try tap.start { [unowned self] input, stride, output, frames in
                self.render(input: input, stride: stride, output: output, frames: frames)
            }
        } catch {
            stop()
            throw error
        }
    }

    /// Stops the audio at once (the app is unmuted) and tells the worker to finish; it lets go of the
    /// engine when its current chunk is done.
    func stop() {
        overloadListener = nil
        tap.stop()
        running.store(false, ordering: .releasing)
    }

    /// True once several chunks in a row have failed on the GPU.
    var hasFailed: Bool { gpuFailed.load(ordering: .relaxed) }

    // MARK: Control (any thread)

    /// Stops the output instantly and freezes the pipeline (the source paused). Resuming plays on
    /// from exactly where it stopped, so pausing costs no latency.
    func setHold(_ value: Bool) { hold.store(value, ordering: .releasing) }

    /// Drops everything in flight (a new track or a seek).
    func flush() { flushRequests.add(1, ordering: .releasing) }

    func setPlan(_ plan: StreamingPlan) { planRequest.withLock { $0 = plan } }

    /// One model step, timed end to end.
    struct ChunkRecord: Sendable {
        var time: Date
        /// Seconds the chunk emitted (more than the plan's step when catching up).
        var emitted: Double
        /// Input waiting beyond this chunk, seconds (how far behind the worker is).
        var backlog: Double
        /// Separated audio left to play when the chunk landed: zero means it arrived too late.
        var headroom: Double
        var resampleIn: Double
        var prepare: Double
        var graph: Double
        var gpu: Double
        var readback: Double
        var assemble: Double
        var resampleOut: Double
        var total: Double
        var activeMemory: Int
        var cacheMemory: Int
        /// The most MLX memory in use at once during the chunk.
        var peakMemory: Int
        /// The first chunk after a start, skip or mode change: it lands in an empty buffer by design.
        var afterRestart: Bool
    }

    /// Records since the last call.
    func drainChunkRecords() -> [ChunkRecord] { chunkRecords.withLock { records in defer { records = [] }; return records } }

    struct CallbackReport {
        /// The slowest callback since the last call, wall clock and the thread's own CPU, seconds.
        var peak: Double
        var peakCPU: Double
        /// The buffer the callback has to fill, frames.
        var frames: Int
        /// Callbacks that took longer than their buffer lasts, and Core Audio's overload count (glitches).
        var late: Int
        var overloads: Int
    }

    func drainCallbackReport() -> CallbackReport {
        CallbackReport(peak: Double(callbackPeakNanos.exchange(0, ordering: .relaxed)) / 1e9,
                       peakCPU: Double(callbackPeakCPUNanos.exchange(0, ordering: .relaxed)) / 1e9,
                       frames: callbackFrames.load(ordering: .relaxed),
                       late: lateCallbacks.load(ordering: .relaxed), overloads: overloads.load(ordering: .relaxed))
    }

    struct Stats {
        var latency: Double
        var chunkMilliseconds: Int
        var load: Double
        var underruns: Int
        var receivingAudio: Bool
        var playing: Bool
        var plan: StreamingPlan
    }

    var stats: Stats {
        let plan = currentPlan.withLock { $0 }
        let ms = chunkMilliseconds.load(ordering: .relaxed)
        let latency = Double(fedFrames.load(ordering: .relaxed) - playedFrames.load(ordering: .relaxed)) / rate
        return Stats(latency: max(latency, 0), chunkMilliseconds: ms,
                     load: Double(ms) / 1000 / (Double(plan.step) / StreamingSeparator.sampleRate),
                     underruns: underrunCount.load(ordering: .relaxed), receivingAudio: inputActive.load(ordering: .relaxed),
                     playing: playing.load(ordering: .relaxed), plan: plan)
    }

    // MARK: Worker

    private func work(plan initial: StreamingPlan) {
        var streaming = StreamingSeparator(separator: separator, plan: initial)
        let toModel = rate == StreamingSeparator.sampleRate ? nil
            : StreamResampler(from: rate, to: StreamingSeparator.sampleRate, channels: 2)
        let fromModel = rate == StreamingSeparator.sampleRate ? nil
            : StreamResampler(from: StreamingSeparator.sampleRate, to: rate, channels: slotCount * 2)
        var flushes = flushRequests.load(ordering: .acquiring)
        let clock = ContinuousClock()
        var idleSince = clock.now
        var resampleIn = 0.0

        var failedInARow = 0
        var restarted = true
        func restart() {
            restarted = true
            streaming.reset()
            toModel?.reset()
            fromModel?.reset()
            inputRing.consume(inputRing.available)
            discardTarget.store(outputRing.writePosition, ordering: .releasing)
        }

        while running.load(ordering: .acquiring) {
            if let plan = planRequest.withLock({ request -> StreamingPlan? in defer { request = nil }; return request }) {
                streaming = StreamingSeparator(separator: separator, plan: plan)
                currentPlan.withLock { $0 = plan }
                planLatency.store(plan.latency, ordering: .relaxed)
                planStep.store(Int(Double(plan.step) * rate / StreamingSeparator.sampleRate), ordering: .relaxed)
                restart()
            }
            let requested = flushRequests.load(ordering: .acquiring)
            if requested != flushes {
                flushes = requested
                restart()
            }

            let input = inputRing.readAll()
            let resampleStarted = clock.now
            if !input.isEmpty {
                let converted = toModel?.process(input) ?? input
                if let left = converted.first, !left.isEmpty { streaming.append(left: left, right: converted[1]) }
                resampleIn += (clock.now - resampleStarted).seconds
            }
            guard streaming.canProcess else {
                if clock.now - idleSince > .seconds(20) {
                    separator.releaseCache()
                    idleSince = clock.now
                }
                usleep(4_000)
                continue
            }
            let pendingBefore = streaming.pending
            Memory.peakMemory = 0
            let signpost = signposter.beginInterval("chunk")
            let started = clock.now
            let failuresBefore = separator.failures
            let block = streaming.process()
            let elapsed = clock.now - started
            if separator.failures != failuresBefore {
                failedInARow += 1
                if failedInARow >= 3 { gpuFailed.store(true, ordering: .relaxed) }
            } else {
                failedInARow = 0
            }
            let timing = separator.lastTiming
            chunkMilliseconds.store(Int(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000),
                                    ordering: .relaxed)
            idleSince = clock.now
            // A flush that arrived mid-chunk makes this block stale.
            guard flushRequests.load(ordering: .acquiring) == flushes else { signposter.endInterval("chunk", signpost); continue }
            let outStarted = clock.now
            let resampled = fromModel?.process(block) ?? block
            let resampleOut = (clock.now - outStarted).seconds
            let headroom = Double(outputRing.available) / rate
            outputRing.write(resampled)
            signposter.endInterval("chunk", signpost)
            let emitted = Double(block.first?.count ?? 0) / StreamingSeparator.sampleRate
            let record = ChunkRecord(
                time: Date(), emitted: emitted,
                backlog: Double(pendingBefore - streaming.plan.lookahead - streaming.plan.crossfade) / StreamingSeparator.sampleRate - emitted,
                headroom: headroom, resampleIn: resampleIn,
                prepare: timing.prepare, graph: timing.graph, gpu: timing.gpu, readback: timing.readback,
                assemble: elapsed.seconds - timing.total, resampleOut: resampleOut,
                total: resampleIn + elapsed.seconds + resampleOut,
                activeMemory: Memory.activeMemory, cacheMemory: Memory.cacheMemory, peakMemory: Memory.peakMemory,
                afterRestart: restarted)
            restarted = false
            resampleIn = 0
            chunkRecords.withLock { records in
                records.append(record)
                if records.count > 600 { records.removeFirst(records.count - 600) }
            }
        }
    }

    // MARK: Real-time

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanos(_ ticks: UInt64) -> UInt64 { ticks * UInt64(timebase.numer) / UInt64(timebase.denom) }

    private func render(input: UnsafePointer<Float>?, stride: Int, output: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        guard frames > 0, frames <= Self.maxFrames else { return }
        let callbackStarted = mach_absolute_time()
        let cpuStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer {
            let nanos = Int(Self.nanos(mach_absolute_time() - callbackStarted))
            if nanos > callbackPeakNanos.load(ordering: .relaxed) {
                callbackPeakNanos.store(nanos, ordering: .relaxed)
                callbackPeakCPUNanos.store(Int(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStarted), ordering: .relaxed)
            }
            if Double(nanos) > Double(frames) / rate * 1e9 { lateCallbacks.add(1, ordering: .relaxed) }
            callbackFrames.store(frames, ordering: .relaxed)
        }
        feed(input: input, stride: stride, frames: frames)
        mix(frames: frames)
        if let recording {
            for i in 0..<frames { scratch[2 * i] = mixLeft[i]; scratch[2 * i + 1] = mixRight[i] }
            recording.write(interleaved: scratch, stride: 2, frames: frames)
        }
        if silenceOutput { return }
        // Write stereo to the first two channels the device offers.
        var channel = 0
        for buffer in buffers where channel < 2 {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let width = Int(buffer.mNumberChannels)
            for c in 0..<width where channel < 2 {
                let source = channel == 0 ? mixLeft : mixRight
                for i in 0..<frames { data[i * width + c] = source[i] }
                channel += 1
            }
        }
        if channel == 1, let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
            // Mono device: fold the right channel in.
            for i in 0..<frames { data[i] = 0.5 * (mixLeft[i] + mixRight[i]) }
        }
    }

    /// Passes the tap's audio to the worker. The first moments of silence are held back, because a
    /// pause notification usually arrives just after the player goes quiet and that silence shouldn't
    /// end up in the pipeline. After that silence is fed, so the last notes leave the model's lookahead
    /// on time, until there's been enough to flush it; beyond that nothing is fed until sound returns.
    private func feed(input: UnsafePointer<Float>?, stride: Int, frames: Int) {
        var peak: Float = 0
        if let input { vDSP_maxmgv(input, 1, &peak, vDSP_Length(frames * stride)) }
        let drain = Int(Double(planLatency.load(ordering: .relaxed)) * rate / StreamingSeparator.sampleRate) + Int(rate * 0.1)
        if peak > 0 {
            if pendingSilence > 0 {
                inputRing.write(interleaved: nil, stride: 1, frames: pendingSilence)
                fedFrames.add(pendingSilence, ordering: .relaxed)
                pendingSilence = 0
            }
            inputRing.write(interleaved: input, stride: stride, frames: frames)
            fedFrames.add(frames, ordering: .relaxed)
            silentRun = 0
            inputActive.store(true, ordering: .relaxed)
            return
        }
        if hold.load(ordering: .relaxed) {
            pendingSilence = 0
            return
        }
        guard silentRun < drain else {
            inputActive.store(false, ordering: .relaxed)
            return
        }
        silentRun += frames
        pendingSilence += frames
        if pendingSilence >= Int(rate * 0.15) || silentRun >= drain {
            inputRing.write(interleaved: nil, stride: 1, frames: pendingSilence)
            fedFrames.add(pendingSilence, ordering: .relaxed)
            pendingSilence = 0
        }
    }

    /// How long to buffer before playing, beyond the first chunk's own compute time. A chunk that
    /// runs longer than the first did by more than this is an audible gap, and on a busy Mac chunk
    /// times vary several-fold, so the headroom is half a step to start with and grows by a quarter
    /// step with each underrun. Past a whole step it can't help: the model is simply too slow.
    private var primingMargin: Int {
        let step = planStep.load(ordering: .relaxed)
        return min(max(Int(rate * 0.25), step / 2) + marginBump, step)
    }

    private func mix(frames: Int) {
        let target = discardTarget.exchange(-1, ordering: .acquiring)
        if target >= 0 {
            outputRing.discard(upTo: target)
            // Discarded audio will never play; count it as gone so the reported delay stays true.
            playedFrames.store(fedFrames.load(ordering: .relaxed), ordering: .relaxed)
            outputState = .buffering
            master = 0
        }
        memset(mixLeft, 0, frames * MemoryLayout<Float>.size)
        memset(mixRight, 0, frames * MemoryLayout<Float>.size)

        let available = outputRing.available
        switch outputState {
        case .buffering:
            if available > 0 { outputState = .priming(primingMargin) }
            playing.store(false, ordering: .relaxed)
            return
        case .priming(let remaining):
            outputState = remaining > frames ? .priming(remaining - frames) : .playing
            return
        case .playing:
            break
        }

        let held = hold.load(ordering: .relaxed)
        let goal: Float = held ? 0 : 1
        if held && master == 0 { return }
        playing.store(!held, ordering: .relaxed)

        let count = min(frames, available)
        let rampStep: Float = 1 / Float(rate * 0.012)
        let slots = slotCount
        for slot in 0..<slots {
            let from = currentGains[slot], to = targetGains[slot]
            currentGains[slot] = to
            var peak: Float = 0
            for side in 0..<2 {
                outputRing.peek(channel: slot * 2 + side, into: scratch, frames: count)
                var level: Float = 0
                vDSP_maxmgv(scratch, 1, &level, vDSP_Length(count))
                peak = max(peak, level)
                guard from != 0 || to != 0 else { continue }
                let destination = side == 0 ? mixLeft : mixRight
                // Ramp the gain across the buffer so fader moves never click.
                var start = from, step = count > 1 ? (to - from) / Float(count) : 0
                vDSP_vrampmuladd(scratch, 1, &start, &step, destination, 1, vDSP_Length(count))
            }
            meters[slot] = max(meters[slot], peak)
        }
        // Master fade for hold/resume.
        var m = master
        for i in 0..<count {
            m += m < goal ? min(rampStep, goal - m) : -min(rampStep, m - goal)
            mixLeft[i] *= m
            mixRight[i] *= m
        }
        master = m
        outputRing.consume(count)
        playedFrames.add(count, ordering: .relaxed)

        if count < frames {
            outputState = .buffering
            if silentRun == 0 {
                // Starved while the source is still playing: the model fell behind. Buffer a bit more.
                underrunCount.add(1, ordering: .relaxed)
                marginBump += planStep.load(ordering: .relaxed) / 4
            }
        }
    }
}
