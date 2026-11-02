import Foundation
import IOKit
import StemSeparation

/// Watches how hard live separation is working and why it falls behind.
///
/// Every chunk the engine runs is timed stage by stage; every half second the recorder adds what
/// the rest of the Mac is doing (GPU busy-ness, thermal state, CPU). Everything goes to a JSON-lines
/// file in `~/Library/Logs/Prism` for `Prism --perf-report`, and the recent past stays in memory
/// for the Performance window.
@Observable
final class PerfRecorder {
    struct SystemSample: Codable {
        var time: Date
        /// Whole-GPU utilisation from the driver, 0…1.
        var gpuDevice: Double?
        /// The share of the last interval Prism's chunks spent on the GPU, 0…1.
        var gpuPrism: Double
        var thermal: String
        var lowPower: Bool
        var load: Double
        /// Prism's CPU use, in cores.
        var cpu: Double
        var callbackPeak: Double
        var callbackPeakCPU: Double?
        var callbackBudget: Double
        /// Running totals: callbacks slower than their buffer, and Core Audio overloads (audible glitches).
        var lateCallbacks: Int?
        var overloads: Int?
        /// Every few seconds: GPU share by app (excluding Prism), from the driver's per-client accounting.
        var gpuApps: [String: Double]?
        var latency: Double
        var underruns: Int
        var mode: String
        var playing: Bool
    }

    struct Chunk: Codable, Identifiable {
        var id: Int
        var time: Date
        var emitted: Double
        var step: Double
        var backlog: Double
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
        var peakMemory: Int?
        var afterRestart: Bool?
    }

    struct Event: Codable, Identifiable {
        var id: Int
        var time: Date
        var name: String
        var detail: String
    }

    private(set) var chunks: [Chunk] = []
    private(set) var samples: [SystemSample] = []
    private(set) var events: [Event] = []
    private(set) var fileURL: URL?

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var lastSampleTime = Date()
    @ObservationIgnored private var lastCPU = PerfRecorder.cpuSeconds()
    @ObservationIgnored private var lastUnderruns = 0
    @ObservationIgnored private var lastOverloads = 0
    @ObservationIgnored private var lastGPUTimes: [String: UInt64] = [:]
    @ObservationIgnored private var lastGPUTimesAt = Date.distantPast
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Prism", isDirectory: true)
    }

    /// Opens a new log for a session on `engine`.
    func begin(mode: LatencyMode, engine: LiveEngine, source: String) {
        end()
        lastUnderruns = 0
        lastOverloads = 0
        chunks = []
        samples = []
        events = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = Self.folder.appendingPathComponent("perf-\(stamp).jsonl")
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        fileURL = url
        pruneOldLogs()
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        write(["type": "session", "time": Date().timeIntervalSince1970 * 1000, "machine": String(cString: model),
               "os": ProcessInfo.processInfo.operatingSystemVersionString, "mode": mode.rawValue,
               "plan": mode.plan.description, "step": Double(mode.plan.step) / StreamingSeparator.sampleRate,
               "device": engine.outputDeviceName, "rate": engine.sampleRate, "source": source])
    }

    func end() {
        try? handle?.close()
        handle = nil
    }

    func event(_ name: String, _ detail: String = "") {
        let event = Event(id: nextID, time: Date(), name: name, detail: detail)
        nextID += 1
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        write(event, type: "event")
    }

    /// Collects the engine's chunk records and one system sample.
    func tick(engine: LiveEngine, stats: LiveEngine.Stats, mode: LatencyMode) {
        let now = Date()
        let interval = max(now.timeIntervalSince(lastSampleTime), 0.05)
        lastSampleTime = now
        let step = Double(stats.plan.step) / StreamingSeparator.sampleRate

        var gpuSeconds = 0.0
        for record in engine.drainChunkRecords() {
            let chunk = Chunk(id: nextID, time: record.time, emitted: record.emitted, step: step, backlog: record.backlog,
                              headroom: record.headroom, resampleIn: record.resampleIn, prepare: record.prepare,
                              graph: record.graph, gpu: record.gpu, readback: record.readback, assemble: record.assemble,
                              resampleOut: record.resampleOut, total: record.total,
                              activeMemory: record.activeMemory, cacheMemory: record.cacheMemory, peakMemory: record.peakMemory,
                              afterRestart: record.afterRestart)
            nextID += 1
            gpuSeconds += record.gpu
            chunks.append(chunk)
            write(chunk, type: "chunk")
        }
        if chunks.count > 400 { chunks.removeFirst(chunks.count - 400) }

        if stats.underruns > lastUnderruns {
            event("underrun", String(format: "headroom ran out; delay now %.1f s", stats.latency))
        }
        lastUnderruns = stats.underruns

        let cpu = Self.cpuSeconds()
        let callback = engine.drainCallbackReport()
        if callback.overloads > lastOverloads {
            event("overload", String(format: "audio glitch: slowest callback %.1f ms (%.1f ms CPU) of %.1f ms",
                                     callback.peak * 1000, callback.peakCPU * 1000, Double(callback.frames) / engine.sampleRate * 1000))
        }
        lastOverloads = callback.overloads

        var gpuApps: [String: Double]?
        if now.timeIntervalSince(lastGPUTimesAt) >= 5 {
            let times = Self.gpuTimeByApp()
            let elapsed = now.timeIntervalSince(lastGPUTimesAt)
            if elapsed < 30 {
                var shares: [String: Double] = [:]
                for (app, time) in times where app != "Prism" {
                    let share = Double(time &- (lastGPUTimes[app] ?? time)) / 1e9 / elapsed
                    if share > 0.01 { shares[app] = min(share, 1) }
                }
                gpuApps = shares
            }
            lastGPUTimes = times
            lastGPUTimesAt = now
        }
        let sample = SystemSample(
            time: now, gpuDevice: Self.gpuUtilization(), gpuPrism: min(gpuSeconds / interval, 1),
            thermal: Self.thermalName, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, load: Self.loadAverage,
            cpu: (cpu - lastCPU) / interval, callbackPeak: callback.peak, callbackPeakCPU: callback.peakCPU,
            callbackBudget: Double(callback.frames) / engine.sampleRate, lateCallbacks: callback.late,
            overloads: callback.overloads, gpuApps: gpuApps, latency: stats.latency,
            underruns: stats.underruns, mode: mode.rawValue, playing: stats.playing)
        lastCPU = cpu
        samples.append(sample)
        if samples.count > 720 { samples.removeFirst(samples.count - 720) }
        write(sample, type: "system")
    }

    // MARK: Writing

    private func write<T: Encodable>(_ value: T, type: String) {
        guard let handle, var data = try? encoder.encode(value),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        object["type"] = type
        guard let line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data = line + Data("\n".utf8)
        try? handle.write(contentsOf: data)
    }

    private func write(_ object: [String: Any]) {
        guard let handle, let line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? handle.write(contentsOf: line + Data("\n".utf8))
    }

    /// Keeps the newest 20 logs.
    private func pruneOldLogs() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let logs = files.filter { $0.lastPathComponent.hasPrefix("perf-") }.sorted { modified($0) > modified($1) }
        for old in logs.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: System readings

    /// The GPU's own utilisation figure (what Activity Monitor's GPU History shows).
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let statistics = property.takeRetainedValue() as? [String: Any],
                  let utilisation = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            result = max(result ?? 0, utilisation / 100)
        }
        return result
    }

    /// Total GPU time (ns) per app so far, from each GPU client's `AppUsage`, keyed by process name.
    static func gpuTimeByApp() -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                // "pid 123, Name"
                let name = creator.split(separator: ",", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? creator
                let time = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, +)
                result[name, default: 0] += time
            }
        }
        return result
    }

    static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static var loadAverage: Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    /// CPU time this process has used, user plus system.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
