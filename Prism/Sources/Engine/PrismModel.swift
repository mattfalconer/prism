import AppKit
import CoreAudio
import MLX
import ServiceManagement
import StemSeparation
import SwiftUI

/// One stem's channel strip.
struct Stem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    /// Fader position, 0…1 (gain is its square, so 1 is unity).
    var level: Double = 1
    var muted = false
    var soloed = false

    static let catalogue: [Stem] = [
        Stem(id: "vocals", title: "Vocals", symbol: "music.mic", color: Color(hex: 0xFF375F)),
        Stem(id: "drums", title: "Drums", symbol: "metronome", color: Color(hex: 0xFFD60A)),
        Stem(id: "bass", title: "Bass", symbol: "waveform.path", color: Color(hex: 0x5E5CE6)),
        Stem(id: "guitar", title: "Guitar", symbol: "guitars", color: Color(hex: 0xFF9F0A)),
        Stem(id: "piano", title: "Keys", symbol: "pianokeys", color: Color(hex: 0x66D4CF)),
        Stem(id: "other", title: "Other", symbol: "sparkles", color: Color(hex: 0x30B0C7)),
    ]
}

enum Preset: String, CaseIterable, Identifiable {
    case original, instrumental, karaoke, acappella, rhythm
    var id: Self { self }

    var title: String {
        switch self {
        case .original: "Original"
        case .instrumental: "Instrumental"
        case .karaoke: "Karaoke"
        case .acappella: "A Cappella"
        case .rhythm: "Rhythm"
        }
    }

    var symbol: String {
        switch self {
        case .original: "waveform"
        case .instrumental: "mic.slash"
        case .karaoke: "music.microphone"
        case .acappella: "person.wave.2"
        case .rhythm: "metronome"
        }
    }
}

/// How far behind real time Prism plays, traded against how much the model hears before deciding.
enum LatencyMode: String, CaseIterable, Identifiable {
    case responsive, balanced, studio
    var id: Self { self }

    var title: String {
        switch self {
        case .responsive: "Responsive"
        case .balanced: "Balanced"
        case .studio: "Studio"
        }
    }

    var detail: String {
        switch self {
        case .responsive: "about 1.5 s behind, works the GPU hardest"
        case .balanced: "about 3 s behind"
        case .studio: "about 6 s behind, cleanest and lightest"
        }
    }

    var plan: StreamingPlan {
        switch self {
        case .responsive: .seconds(context: 9.3, step: 1, lookahead: 0.5)
        case .balanced: .seconds(context: 9.3, step: 2, lookahead: 1)
        case .studio: .seconds(context: 9.3, step: 3, lookahead: 3)
        }
    }
}

@Observable
final class PrismModel {
    /// First run: where the stem model download has got to.
    struct Install: Equatable {
        enum Step: Equatable { case downloading, checking, preparing }
        var step = Step.downloading
        var received: Int64 = 0
        var total = ModelLocation.downloadBytes
        /// Smoothed estimate, once there's enough to go on.
        var secondsLeft: Double?
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    enum Status: Equatable {
        case off
        /// First run only: fetching and preparing the stem model.
        case installing(Install)
        case loading
        case waiting(String)
        case live
        case failed(String)
    }

    private(set) var status = Status.off {
        didSet {
            // Once Prism is listening, the first-run setup page has done its job.
            switch status {
            case .waiting, .live: settingUp = false
            default: break
            }
        }
    }
    var stems = Stem.catalogue {
        didSet {
            // Any change to the mix leaves the untouched original.
            if bypass, stems != Stem.catalogue { bypass = false }
            applyGains()
        }
    }
    var bypass = false { didSet { applyGains() } }
    private(set) var source = AudioSource.spotify
    private(set) var sources: [AudioSource] = []
    var mode: LatencyMode = LatencyMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .balanced {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            engine?.setPlan(mode.plan)
            if engine != nil { perf.event("mode", "\(mode.title): \(mode.plan)") }
        }
    }
    private(set) var stats: LiveEngine.Stats?
    private(set) var permissionProblem = false
    let nowPlaying = NowPlaying()
    let perf = PerfRecorder()

    private(set) var engine: LiveEngine?
    private var separator: ChunkSeparator?
    private var tappedProcesses: [AudioObjectID] = []
    private var listeners: [AudioListener] = []
    private var statsTimer: Timer?
    private var silentSince: Date?

    var isOn: Bool { status != .off }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "source"),
           let match = AudioSource.available().first(where: { $0.id == saved }) ?? (saved == "system" ? .system : nil) {
            source = match
        }
        nowPlaying.bundleID = source.bundleID
        nowPlaying.onEvent = { [weak self] event in self?.handle(event) }
        nowPlaying.refresh()
        refreshSources()
    }

    // MARK: Presets

    var activePreset: Preset? {
        if bypass { return .original }
        // Every stem at unity is the song: the Original tile lights up by itself.
        return Preset.allCases.first { stems == configured($0) }
    }

    func apply(_ preset: Preset) {
        withAnimation(.snappy(duration: 0.25)) {
            if preset == .original {
                stems = Stem.catalogue
                bypass = true
                return
            }
            bypass = false
            stems = configured(preset)
        }
    }

    private func configured(_ preset: Preset) -> [Stem] {
        Stem.catalogue.map { stem in
            var stem = stem
            switch preset {
            case .original: break
            case .instrumental: stem.muted = stem.id == "vocals"
            case .karaoke: if stem.id == "vocals" { stem.level = 0.4 }   // a faint guide vocal (−16 dB)
            case .acappella: stem.muted = stem.id != "vocals"
            case .rhythm: stem.muted = !["drums", "bass"].contains(stem.id)
            }
            return stem
        }
    }

    func toggleMute(_ id: String) {
        guard let i = stems.firstIndex(where: { $0.id == id }) else { return }
        bypass = false
        stems[i].muted.toggle()
    }

    func toggleSolo(_ id: String) {
        guard let i = stems.firstIndex(where: { $0.id == id }) else { return }
        bypass = false
        stems[i].soloed.toggle()
    }

    /// Gains in the engine's slot order.
    private func applyGains() {
        guard let engine else { return }
        let soloing = stems.contains(where: \.soloed)
        for (slot, name) in engine.stemNames.enumerated() {
            guard let stem = stems.first(where: { $0.id == name }) else { continue }
            let audible = !bypass && (soloing ? stem.soloed : !stem.muted)
            engine.targetGains[slot] = audible ? Float(stem.level * stem.level) : 0
        }
        engine.targetGains[engine.stemNames.count] = bypass ? 1 : 0
    }

    #if PROMO
    /// A take shows the app live on a given track without running the engine.
    func promoGoLive(title: String, artist: String, album: String, artwork: URL, latency: Double) {
        nowPlaying.promoShow(title: title, artist: artist, album: album, artwork: artwork)
        status = .live
        stats = LiveEngine.Stats(latency: latency, chunkMilliseconds: 600, load: 0.2, underruns: 0, receivingAudio: true,
                                 playing: true, plan: mode.plan)
    }
    #endif

    /// The gain a stem is heard at (for the UI).
    func isAudible(_ stem: Stem) -> Bool {
        let soloing = stems.contains(where: \.soloed)
        return (soloing ? stem.soloed : !stem.muted) && stem.level > 0
    }

    // MARK: Sources

    func refreshSources() {
        var list = AudioSource.available()
        if !list.contains(source), source != .system { list.insert(source, at: 0) }
        sources = list
    }

    /// Debug: listen to one process, with the speakers silent.
    func debugTap(pid: pid_t) {
        source = AudioSource(id: "pid-\(pid)", name: "Test player", target: .pids([pid]), bundleID: nil)
        debugSilent = true
    }

    private var debugSilent = false

    func select(_ newSource: AudioSource) {
        guard newSource != source else { return }
        source = newSource
        UserDefaults.standard.set(newSource.id, forKey: "source")
        nowPlaying.bundleID = newSource.bundleID
        nowPlaying.refresh()
        if isOn { rebuild() }
    }

    // MARK: On / off

    func setOn(_ on: Bool) {
        if on { turnOn() } else { turnOff() }
    }

    func turnOn() {
        guard status == .off || { if case .failed = status { true } else { false } }() else { return }
        UserDefaults.standard.set(true, forKey: "on")
        if ModelLocation.isInstalled { load() } else { download() }
    }

    private var downloadTask: Task<Void, Never>?
    /// True from a first-run download until Prism is up, so the panel shows its setup page throughout.
    private(set) var settingUp = false
    var showsSetup: Bool {
        guard settingUp else { return false }
        switch status {
        case .installing, .loading, .failed: return true
        default: return false
        }
    }
    private var installing: Bool { if case .installing = status { true } else { false } }
    private var lastSample: (time: Date, bytes: Int64)?
    private var bytesPerSecond: Double?
    private var downloadStart = Date()

    /// First run: fetch the stem model, then carry on starting up.
    private func download() {
        settingUp = true
        status = .installing(Install())
        lastSample = nil
        bytesPerSecond = nil
        downloadStart = Date()
        downloadTask = Task {
            do {
                try await ModelLocation.install { step in
                    Task { @MainActor in self.record(step) }
                }
                guard installing else { return }
                load()
            } catch {
                guard installing else { return }   // turned off meanwhile
                status = .failed("Couldn't download what Prism needs. \(error.localizedDescription)")
            }
        }
    }

    private func record(_ step: ModelLocation.Step) {
        guard case .installing(var install) = status else { return }
        switch step {
        case .checking: install.step = .checking; install.received = install.total; install.secondsLeft = nil
        case .preparing: install.step = .preparing; install.received = install.total; install.secondsLeft = nil
        case .downloading(let received, let total):
            guard install.step == .downloading else { return }
            let now = Date()
            if let last = lastSample {
                let dt = now.timeIntervalSince(last.time)
                guard dt >= 0.25 || received >= total else { return }   // a few updates a second is plenty
                // A slow average keeps the estimate from jumping with every burst of the connection.
                let instant = Double(received - last.bytes) / dt
                bytesPerSecond = bytesPerSecond.map { $0 * 0.94 + instant * 0.06 } ?? instant   // about a 4 s average
            }
            lastSample = (now, received)
            install.received = received
            install.total = total
            if let rate = bytesPerSecond, rate > 0, now.timeIntervalSince(downloadStart) > 2 {
                install.secondsLeft = Double(max(0, total - received)) / rate
            }
        }
        status = .installing(install)
    }

    private func load() {
        status = .loading
        let plan = mode.plan
        Task.detached(priority: .userInitiated) {
            do {
                let separator = try ChunkSeparator(weights: ModelLocation.sw, precision: .bfloat16)
                // MLX keeps freed buffers for reuse and by default lets that cache grow to gigabytes.
                // One chunk peaks at about 1.5 GB, so this still covers reuse, and the rest of the
                // Mac gets its memory back (paging under pressure is what made the audio glitch).
                Memory.cacheLimit = 1_600_000_000
                // Compile the kernels for this chunk size now, not on the first second of music.
                let silence = [Float](repeating: 1e-4, count: plan.context)
                silence.withUnsafeBufferPointer { s in _ = separator.separate(left: s.baseAddress!, right: s.baseAddress!, count: plan.context) }
                await MainActor.run {
                    self.separator = separator
                    guard self.status == .loading else { return }
                    self.startListening()
                    self.rebuild()
                }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    func turnOff() {
        downloadTask?.cancel()
        downloadTask = nil
        settingUp = false
        if engine != nil { perf.event("off") }
        perf.end()
        engine?.stop()
        engine = nil
        listeners = []
        statsTimer?.invalidate()
        statsTimer = nil
        stats = nil
        tappedProcesses = []
        status = .off
        UserDefaults.standard.set(false, forKey: "on")
        // Keep the model for a quick restart, but give its GPU buffers back.
        separator?.releaseCache()
    }

    /// Rebuilds the tap when the output device or the source's processes change.
    private func startListening() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listeners = [
            AudioObjects.listen(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                MainActor.assumeIsolated { self?.rebuild() }
            },
            AudioObjects.listen(system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
                MainActor.assumeIsolated { self?.processesChanged() }
            },
        ]
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStats() }
        }
    }

    private func processesChanged() {
        refreshSources()
        guard isOn, source.target != .system else { return }
        if ProcessTap.processes(for: source.target) != tappedProcesses { rebuild() }
    }

    private func rebuild() {
        guard let separator, status != .off else { return }
        engine?.stop()
        engine = nil
        let processes = ProcessTap.processes(for: source.target)
        tappedProcesses = processes
        if source.target != .system && processes.isEmpty {
            status = .waiting("Play something in \(source.name)")
            return
        }
        do {
            let tap = try ProcessTap(target: source.target, processes: processes)
            let engine = LiveEngine(tap: tap, separator: separator, plan: mode.plan)
            self.engine = engine
            engine.silenceOutput = debugSilent
            MeterHub.shared.engine = engine
            applyGains()
            if nowPlaying.supportsTransport { engine.setHold(!nowPlaying.isPlaying && nowPlaying.track != nil) }
            try engine.start()
            status = .live
            perf.begin(mode: mode, engine: engine, source: source.name)
            perf.event("start", "\(source.name) → \(engine.outputDeviceName) at \(Int(engine.sampleRate)) Hz")
        } catch {
            engine = nil
            status = .failed(error.localizedDescription)
        }
    }

    private func handle(_ event: NowPlaying.Event) {
        guard let engine else { return }
        prismLog.notice("event \(String(describing: event), privacy: .public)")
        perf.event(String(describing: event), nowPlaying.track.map { "\($0.title) — \($0.artist)" } ?? "")
        switch event {
        case .paused: engine.setHold(true)
        case .resumed: engine.setHold(false)
        case .jumped: engine.flush()
        }
    }

    private func updateStats() {
        guard let engine else { return }
        let latest = engine.stats
        perf.tick(engine: engine, stats: latest, mode: mode)
        if stats?.latency.rounded(toPlaces: 1) != latest.latency.rounded(toPlaces: 1) || stats?.playing != latest.playing
            || stats?.receivingAudio != latest.receivingAudio || stats?.chunkMilliseconds != latest.chunkMilliseconds
            || stats?.underruns != latest.underruns {
            if stats?.playing != latest.playing || stats?.receivingAudio != latest.receivingAudio || stats?.underruns != latest.underruns {
                prismLog.notice("output \(latest.playing ? "playing" : "stopped", privacy: .public), input \(latest.receivingAudio ? "sound" : "silent", privacy: .public), latency \(latest.latency), chunk \(latest.chunkMilliseconds) ms, load \(latest.load), underruns \(latest.underruns)")
            }
            stats = latest
        }
        // The player says it's playing but the tap hears nothing: almost always the audio-capture permission.
        if nowPlaying.isPlaying, !latest.receivingAudio {
            silentSince = silentSince ?? Date()
            permissionProblem = Date().timeIntervalSince(silentSince!) > 4
        } else {
            silentSince = nil
            permissionProblem = false
        }
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = Foundation.pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
