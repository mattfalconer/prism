import Foundation

/// `Prism --perf-report [log.jsonl]`: summarises a live session's performance log (the newest one
/// in `~/Library/Logs/Prism` by default).
enum PerfReport {
    static func run(_ arguments: [String]) -> Int32 {
        let index = arguments.firstIndex(of: "--perf-report")!
        let explicit = arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil
        guard let url = explicit ?? newestLog() else {
            print("No performance logs in \(PerfRecorder.folder.path)")
            return 1
        }
        do {
            let log = try PerfAnalysis.load(url)
            print("Prism performance — \(url.lastPathComponent)")
            if let machine = log.session["machine"], let mode = log.session["mode"], let plan = log.session["plan"] {
                print("\(machine), \(mode) (\(plan)), output \(log.session["device"] ?? "?") at \(log.session["rate"] ?? "?") Hz")
            }
            if let first = log.samples.first?.time, let last = log.samples.last?.time {
                print(String(format: "%.1f minutes, %d chunks", last.timeIntervalSince(first) / 60, log.chunks.count))
            }
            guard let analysis = PerfAnalysis(chunks: log.chunks, samples: log.samples, events: log.events) else {
                print("No chunks recorded yet.")
                return 0
            }
            let ms = { (x: Double) in String(format: "%5.0f ms", x * 1000) }
            print("")
            print("Chunk time   typical \(ms(analysis.p50))   slow (p95) \(ms(analysis.p95))   worst \(ms(analysis.worst))   best \(ms(analysis.best))   budget \(ms(analysis.step))")
            let total = analysis.stages.map(\.seconds).reduce(0, +)
            for stage in analysis.stages {
                print("  " + stage.name.padding(toLength: 20, withPad: " ", startingAt: 0) + ms(stage.seconds) + String(format: "  %4.1f%%", stage.seconds / total * 100))
            }
            print(String(format: "Headroom     closest %.2f s, late chunks %d, underruns %d, catch-ups %d",
                         analysis.minHeadroom, analysis.lateChunks, analysis.underruns, analysis.catchUpChunks))
            print(String(format: "GPU          Prism %.0f%%, everything else %@", analysis.prismGPU * 100,
                         analysis.otherGPU.map { String(format: "%.0f%%", $0 * 100) } ?? "unknown"))
            if let slowdown = analysis.contentionSlowdown {
                print(String(format: "             chunks %.1f× slower while other apps load the GPU", slowdown))
            }
            print(String(format: "Delay        %.1f s", analysis.latency))
            print(String(format: "Audio thread slowest callback %.2f ms (%.2f ms CPU) of %.2f ms, late %d, Core Audio overloads %d",
                         analysis.callbackPeak * 1000, analysis.callbackPeakCPU * 1000, analysis.callbackBudget * 1000,
                         analysis.lateCallbacks, analysis.overloads))
            print("")
            for finding in analysis.findings {
                let mark = switch finding.severity { case .good: "✓"; case .note: "•"; case .warning: "!" }
                print("\(mark) \(finding.title): \(finding.detail)")
            }
            if !log.events.isEmpty {
                print("")
                print("Events")
                let format = Date.FormatStyle.dateTime.hour().minute().second()
                for event in log.events.suffix(30) {
                    print("  \(event.time.formatted(format))  \(event.name)\(event.detail.isEmpty ? "" : " — \(event.detail)")")
                }
            }
            return 0
        } catch {
            print("Couldn't read \(url.path): \(error)")
            return 1
        }
    }

    private static func newestLog() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: PerfRecorder.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return files.filter { $0.lastPathComponent.hasPrefix("perf-") }.max { modified($0) < modified($1) }
    }
}
