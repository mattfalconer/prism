import Foundation

/// A prepared pair travels to one LiveEngine worker, which alone renders and resets the graphs.
nonisolated final class NativeAudioMix: @unchecked Sendable {
    static let sampleRate = NativeAudioGraph.sampleRate
    static let blockSize = NativeAudioGraph.blockSize
    static let stemNames = ["vocals", "backing"]
    static var hasSystemAssets: Bool { NativeAudioGraph.hasSystemAssets }

    private let directory: URL
    private var dialogue: NativeAudioGraph
    private var music: NativeAudioGraph
    private var dialogueDelay: StereoDelay
    private var musicDelay: StereoDelay
    private var priming: Int
    let latencyFrames: Int

    @concurrent
    static func prepare() async throws -> NativeAudioMix {
        try Task.checkCancellation()
        return try NativeAudioMix()
    }

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Prism-AudioMix-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            dialogue = try NativeAudioGraph(node: "aunnet_dialog", directory: directory)
            music = try NativeAudioGraph(node: "aunnet_music", directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        dialogueDelay = StereoDelay(frames: dialogue.latencyFrames)
        musicDelay = StereoDelay(frames: music.latencyFrames)
        latencyFrames = dialogue.latencyFrames + music.latencyFrames
        priming = latencyFrames
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func reset() throws {
        // AudioUnitReset leaves the neural networks' temporal state in place on tested builds.
        // Recreate both graphs on the worker so no audio from the previous track leaks through.
        let newDialogue = try NativeAudioGraph(node: "aunnet_dialog", directory: directory)
        let newMusic = try NativeAudioGraph(node: "aunnet_music", directory: directory)
        guard newDialogue.latencyFrames == dialogue.latencyFrames, newMusic.latencyFrames == music.latencyFrames else {
            throw NativeAudioGraph.Failure(operation: "Apple Audio Mix changed its latency while resetting.")
        }
        dialogue = newDialogue
        music = newMusic
        dialogueDelay.reset()
        musicDelay.reset()
        priming = latencyFrames
    }

    /// Vocals L/R, backing L/R, and the matching dry L/R used by the Original preset.
    func process(left: ArraySlice<Float>, right: ArraySlice<Float>) throws -> [[Float]] {
        let stereo = zip(left, right).map { SIMD2($0, $1) }
        let voice = try dialogue.process(stereo)
        let aligned = stereo.map { dialogueDelay.push($0) }
        let backing = try music.process(zip(aligned, voice).map { $0 - $1 })
        let dry = aligned.map { musicDelay.push($0) }
        let skip = min(priming, Self.blockSize)
        priming -= skip

        var stems = [[Float]](repeating: [], count: 6)
        for index in skip..<Self.blockSize {
            let instrumental = backing[index]
            let original = dry[index]
            let vocal = original - instrumental
            guard instrumental.x.isFinite, instrumental.y.isFinite else {
                throw NativeAudioGraph.Failure(operation: "Apple Audio Mix produced invalid audio.")
            }
            stems[0].append(vocal.x)
            stems[1].append(vocal.y)
            stems[2].append(instrumental.x)
            stems[3].append(instrumental.y)
            stems[4].append(original.x)
            stems[5].append(original.y)
        }
        return stems
    }

    private struct StereoDelay {
        private var samples: [SIMD2<Float>]
        private var index = 0

        init(frames: Int) { samples = [SIMD2<Float>](repeating: .zero, count: frames) }

        mutating func push(_ sample: SIMD2<Float>) -> SIMD2<Float> {
            let delayed = samples[index]
            samples[index] = sample
            index += 1
            if index == samples.count { index = 0 }
            return delayed
        }

        mutating func reset() {
            for i in samples.indices { samples[i] = .zero }
            index = 0
        }
    }
}
