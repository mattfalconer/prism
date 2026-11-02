import Foundation

/// Turns perf records into numbers and plain-language findings (shared by the Performance window
/// and `Prism --perf-report`).
struct PerfAnalysis {
    struct Finding: Identifiable {
        enum Severity: Int, Comparable {
            case good, note, warning
            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }
        let id = UUID()
        var severity: Severity
        var title: String
        var detail: String
    }

    let chunkCount: Int
    let step: Double
    /// Chunk wall time percentiles, seconds.
    let p50: Double, p95: Double, worst: Double, best: Double
    /// Mean share of a chunk spent in each stage.
    let stages: [(name: String, seconds: Double)]
    let minHeadroom: Double
    let lateChunks: Int
    let catchUpChunks: Int
    let underruns: Int
    /// Mean GPU utilisation by everything else, when the driver reports it.
    let otherGPU: Double?
    let prismGPU: Double
    /// How much slower chunks run while other apps load the GPU (busy p50 / quiet p50).
    let contentionSlowdown: Double?
    let latency: Double
    let thermalTrouble: Double
    let lowPower: Bool
    let callbackPeak: Double
    let callbackBudget: Double
    /// Average GPU share of the busiest other apps.
    let topGPUApps: [(name: String, share: Double)]
    /// CPU the audio thread used in its slowest callback.
    let callbackPeakCPU: Double
    let lateCallbacks: Int
    let overloads: Int

    init?(chunks: [PerfRecorder.Chunk], samples: [PerfRecorder.SystemSample], events: [PerfRecorder.Event]) {
        let chunks = chunks.filter { $0.total > 0 }
        guard !chunks.isEmpty else { return nil }
        chunkCount = chunks.count
        step = chunks.last!.step
        let totals = chunks.map(\.total).sorted()
        func percentile(_ p: Double) -> Double { totals[min(totals.count - 1, Int(Double(totals.count - 1) * p))] }
        p50 = percentile(0.5)
        p95 = percentile(0.95)
        worst = totals.last!
        best = percentile(0.05)
        func mean(_ key: KeyPath<PerfRecorder.Chunk, Double>) -> Double { chunks.map { $0[keyPath: key] }.reduce(0, +) / Double(chunks.count) }
        stages = [("GPU", mean(\.gpu)), ("Graph build", mean(\.graph)),
                  ("Resampling", mean(\.resampleIn) + mean(\.resampleOut)),
                  ("Copies & crossfade", mean(\.prepare) + mean(\.readback) + mean(\.assemble))]
        // The first chunk after a start or skip lands in an empty buffer by design.
        let steady = chunks.enumerated().filter { index, chunk in index > 0 && chunk.afterRestart != true }.map(\.element)
        minHeadroom = steady.map(\.headroom).min() ?? 0
        lateChunks = steady.filter { $0.headroom < 0.01 }.count
        catchUpChunks = chunks.filter { $0.emitted > $0.step * 1.05 }.count
        underruns = events.filter { $0.name == "underrun" }.count

        let others = samples.compactMap { sample in sample.gpuDevice.map { max(0, $0 - sample.gpuPrism) } }
        otherGPU = others.isEmpty ? nil : others.reduce(0, +) / Double(others.count)
        prismGPU = samples.isEmpty ? 0 : samples.map(\.gpuPrism).reduce(0, +) / Double(samples.count)

        // Pair each chunk with the GPU load from everyone else around it.
        var quiet: [Double] = [], busy: [Double] = []
        for chunk in chunks {
            guard let sample = samples.min(by: { abs($0.time.timeIntervalSince(chunk.time)) < abs($1.time.timeIntervalSince(chunk.time)) }),
                  abs(sample.time.timeIntervalSince(chunk.time)) < 1.5, let device = sample.gpuDevice else { continue }
            if device - sample.gpuPrism > 0.3 { busy.append(chunk.gpu) } else { quiet.append(chunk.gpu) }
        }
        func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
        contentionSlowdown = quiet.count >= 3 && busy.count >= 3 ? median(busy) / median(quiet) : nil

        latency = samples.last(where: \.playing)?.latency ?? 0
        thermalTrouble = samples.isEmpty ? 0 : Double(samples.filter { $0.thermal == "serious" || $0.thermal == "critical" }.count) / Double(samples.count)
        lowPower = samples.contains(where: \.lowPower)
        callbackPeak = samples.map(\.callbackPeak).max() ?? 0
        callbackBudget = samples.last?.callbackBudget ?? 0
        let readings = samples.compactMap(\.gpuApps)
        var byApp: [String: Double] = [:]
        for reading in readings { for (app, share) in reading { byApp[app, default: 0] += share } }
        let count = Double(max(readings.count, 1))
        let averages: [(name: String, share: Double)] = byApp.map { (name: $0.key, share: $0.value / count) }
        topGPUApps = Array(averages.filter { $0.share >= 0.03 }.sorted { $0.share > $1.share }.prefix(3))
        let slowest = samples.max { $0.callbackPeak < $1.callbackPeak }
        callbackPeakCPU = slowest?.callbackPeakCPU ?? 0
        lateCallbacks = samples.last?.lateCallbacks ?? 0
        overloads = samples.last?.overloads ?? 0
    }

    var findings: [Finding] {
        let s = self
        var out: [Finding] = []
        let ms = { (x: Double) in "\(Int((x * 1000).rounded())) ms" }
        let total = s.stages.map(\.seconds).reduce(0, +)
        let share = { (name: String) in (s.stages.first { $0.name == name }?.seconds ?? 0) / max(total, 1e-9) }

        if s.underruns > 0 || s.lateChunks > 0 {
            out.append(.init(severity: .warning, title: "\(max(s.underruns, s.lateChunks)) dropout\(max(s.underruns, s.lateChunks) == 1 ? "" : "s")",
                             detail: "The slowest chunk took \(ms(s.worst)) against a \(ms(s.step)) step. Each dropout makes Prism buffer more, so they get rarer, at the cost of delay."))
        } else {
            out.append(.init(severity: .good, title: "No dropouts",
                             detail: "Closest call: \(String(format: "%.2f", s.minHeadroom)) s of audio still buffered when a chunk landed."))
        }

        let load = s.p50 / s.step
        if s.p95 > s.step * 0.8 {
            out.append(.init(severity: .warning, title: "Running at the limit",
                             detail: "Slow chunks (\(ms(s.p95)), 95th percentile) use most of the \(ms(s.step)) step. A mode with a longer step would have more slack."))
        } else {
            out.append(.init(severity: load > 0.5 ? .note : .good, title: "\(Int(load * 100))% of the time budget",
                             detail: "A typical chunk takes \(ms(s.p50)); slow ones \(ms(s.p95)); the best \(ms(s.best))."))
        }

        if let other = s.otherGPU, other > 0.25 {
            var detail = "Other apps kept the GPU about \(Int(other * 100))% busy"
            detail += s.topGPUApps.isEmpty ? "." : " (" + s.topGPUApps.map { "\($0.name) \(Int($0.share * 100))%" }.joined(separator: ", ") + ")."
            if let slowdown = s.contentionSlowdown, slowdown > 1.2 {
                detail += " Chunks ran \(String(format: "%.1f", slowdown))× slower while they did, so this is most of the variability."
            }
            out.append(.init(severity: .note, title: "Sharing the GPU", detail: detail))
        }

        if share("Graph build") > 0.12 {
            let graph = s.stages.first { $0.name == "Graph build" }!.seconds
            out.append(.init(severity: .note, title: "Graph building costs \(ms(graph))",
                             detail: "MLX rebuilds the model's graph on the CPU every chunk. Compiling the forward pass once (MLX compile) could save most of this."))
        }
        let cpuSide = share("Resampling") + share("Copies & crossfade")
        if cpuSide > 0.1 {
            out.append(.init(severity: .note, title: "\(Int(cpuSide * 100))% outside the model",
                             detail: "Resampling and copying are a noticeable slice; running the output at 44.1 kHz or vectorising the copies would trim it."))
        }
        if s.p95 > s.p50 * 1.6 {
            out.append(.init(severity: .note, title: "Uneven chunk times",
                             detail: "Slow chunks take \(String(format: "%.1f", s.p95 / s.p50))× as long as typical ones. Prism has to buffer for the slow ones, so steadier chunks would mean less delay."))
        }
        if s.thermalTrouble > 0.05 {
            out.append(.init(severity: .warning, title: "Thermal throttling",
                             detail: "The Mac reported serious heat \(Int(s.thermalTrouble * 100))% of the time, which slows the GPU."))
        }
        if s.lowPower {
            out.append(.init(severity: .warning, title: "Low Power Mode", detail: "Low Power Mode caps the GPU; chunks will run slower."))
        }
        if s.overloads > 0 || s.lateCallbacks > 0 {
            let f = { (x: Double) in String(format: "%.1f ms", x * 1000) }
            let waited = s.callbackPeakCPU < s.callbackPeak * 0.3
            out.append(.init(severity: s.overloads > 0 ? .warning : .note,
                             title: s.overloads > 0 ? "\(s.overloads) audio glitch\(s.overloads == 1 ? "" : "es")" : "\(s.lateCallbacks) late audio callback\(s.lateCallbacks == 1 ? "" : "s")",
                             detail: "The slowest callback took \(f(s.callbackPeak)) of its \(f(s.callbackBudget)) buffer but only used \(f(s.callbackPeakCPU)) of CPU"
                                 + (waited ? ": the system kept the audio thread waiting, so this is load on the Mac rather than Prism's code." : ".")))
        }
        if s.catchUpChunks > 0 {
            out.append(.init(severity: .note, title: "Caught up \(s.catchUpChunks) time\(s.catchUpChunks == 1 ? "" : "s")",
                             detail: "When input piled up, a chunk emitted extra audio to catch up instead of dropping out."))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

extension PerfAnalysis {
    /// Reads a `perf-*.jsonl` log.
    static func load(_ url: URL) throws -> (chunks: [PerfRecorder.Chunk], samples: [PerfRecorder.SystemSample],
                                            events: [PerfRecorder.Event], session: [String: Any]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var chunks: [PerfRecorder.Chunk] = [], samples: [PerfRecorder.SystemSample] = [], events: [PerfRecorder.Event] = []
        var session: [String: Any] = [:]
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            let data = Data(line.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "chunk": if let chunk = try? decoder.decode(PerfRecorder.Chunk.self, from: data) { chunks.append(chunk) }
            case "system": if let sample = try? decoder.decode(PerfRecorder.SystemSample.self, from: data) { samples.append(sample) }
            case "event": if let event = try? decoder.decode(PerfRecorder.Event.self, from: data) { events.append(event) }
            case "session": session = object
            default: break
            }
        }
        return (chunks, samples, events, session)
    }
}
