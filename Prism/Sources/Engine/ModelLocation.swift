import AVFoundation
import CryptoKit
import Foundation
import StemSeparation

/// The converted BS-Roformer weights. On first run Prism downloads the public checkpoint (700 MB),
/// checks it and converts it for MLX, then keeps it here.
nonisolated enum ModelLocation {
    /// `PRISM_MODEL_DIR` points a copy of the app at another folder (to test a first-run download).
    static let folder = ProcessInfo.processInfo.environment["PRISM_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL.applicationSupportDirectory.appendingPathComponent("Prism/Models", isDirectory: true)
    static let sw = folder.appendingPathComponent("BS-Roformer-SW.safetensors")
    /// python-audio-separator's public release of the six-stem BS-Roformer SW checkpoint.
    static let source = URL(string: "https://github.com/nomadkaraoke/python-audio-separator/releases/download/model-configs/BS-Roformer-SW.ckpt")!
    static let digest = "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"
    static let downloadBytes: Int64 = 699_412_152
    /// Size of the converted weights, to tell a damaged copy from a good one.
    static let installedBytes: Int64 = 698_849_201
    /// Other places to fetch the same checkpoint, `{"urls": […]}`, tried before `source`. Whatever is
    /// downloaded must still match `digest`, so this can only add copies of the same file: if the original
    /// release ever moves, pointing this at a new copy keeps first runs working without an app update.
    static let mirrors = URL(string: "https://prism.mattfalconer.com/model.json")!

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: sw.path) }

    /// True when the installed weights are missing or the wrong size (a disk error or a copy cut short).
    static var isDamaged: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: sw.path)[.size] as? Int64) ?? nil
        return size != installedBytes
    }

    enum InstallError: LocalizedError {
        case corrupt
        case server(Int)
        case space(needed: Int64)
        var errorDescription: String? {
            switch self {
            case .corrupt: "The downloaded file was damaged."
            case .server(let status): "The download server answered \(status). Try again in a minute."
            case .space(let needed):
                "Prism needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of free space to set up. Free up some space, then try again."
            }
        }
    }

    enum Step: Sendable {
        case downloading(received: Int64, total: Int64)
        case checking
        case preparing
    }

    /// Downloads, verifies and converts the model, reporting each step (and the bytes so far) as it goes.
    /// Cancelling the task stops the download.
    static func install(report: @escaping @Sendable (Step) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let checkpoint = folder.appendingPathComponent("BS-Roformer-SW.ckpt")
        // Where the converter writes before moving the finished file into place.
        let partial = sw.deletingPathExtension().appendingPathExtension("partial.safetensors")
        func removeLeftovers() {
            try? FileManager.default.removeItem(at: checkpoint)
            try? FileManager.default.removeItem(at: partial)
        }
        removeLeftovers()   // from a setup that was quit halfway
        defer { removeLeftovers() }
        // The checkpoint and its converted copy sit side by side for a moment, plus some room to spare.
        let needed = downloadBytes + installedBytes + 200_000_000
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw InstallError.space(needed: needed)
        }
        let sources = await sources()
        var lastError: any Error = InstallError.corrupt
        downloading: for (index, url) in sources.enumerated() {
            let isLast = index == sources.count - 1
            var attempt = 1
            while true {
                do {
                    try await download(url, to: checkpoint, report: report)
                    report(.checking)
                    let matches = try await Task.detached(priority: .userInitiated) { try sha256(of: checkpoint) == digest }.value
                    guard matches else { throw InstallError.corrupt }
                    break downloading
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch {
                    try Task.checkCancellation()
                    lastError = error
                    let retryable = switch error {
                    case is URLError: true
                    case InstallError.server(let status): [403, 408, 429, 500, 502, 503, 504].contains(status)
                    default: false
                    }
                    // Retry this copy a few times, then move on to the next; the last one's error is the one shown.
                    guard retryable && attempt < 4 else {
                        if isLast { throw lastError }
                        continue downloading
                    }
                }
                try await Task.sleep(for: .milliseconds(800 * attempt))
                attempt += 1
            }
        }
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            report(.preparing)
            if isInstalled { return }   // another copy of Prism finished first
            // Writes beside `sw` and moves the finished file into place, so `sw` is never half-written.
            _ = try StemSplitter.convertCheckpoint(checkpoint, to: sw, config: .sw, widen: true)
        }.value
    }

    /// Gives up on a stalled connection after 30 s without data (the default is 60), so a dead
    /// mirror falls through to the next quickly.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// The mirrors listed on prism.mattfalconer.com (if it answers quickly), then the original release.
    private static func sources() async -> [URL] {
        struct List: Decodable { let urls: [String] }
        var request = URLRequest(url: mirrors, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let listed = await (try? URLSession.shared.data(for: request))
            .flatMap { data, response in (response as? HTTPURLResponse)?.statusCode == 200 ? try? JSONDecoder().decode(List.self, from: data) : nil }?
            .urls.compactMap { URL(string: $0) }.filter { $0.scheme == "https" } ?? []
        var seen = Set<URL>()
        return (listed + [source]).filter { seen.insert($0).inserted }
    }

    private static func download(_ source: URL, to file: URL, report: @escaping @Sendable (Step) -> Void) async throws {
        let task = Box<URLSessionDownloadTask?>(nil)
        let observation = Box<NSKeyValueObservation?>(nil)
        defer { observation.value?.invalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let download = session.downloadTask(with: source) { location, response, error in
                    if let error { return continuation.resume(throwing: error) }
                    guard let location, let http = response as? HTTPURLResponse else {
                        return continuation.resume(throwing: URLError(.badServerResponse))
                    }
                    guard (200..<300).contains(http.statusCode) else { return continuation.resume(throwing: InstallError.server(http.statusCode)) }
                    do {
                        try? FileManager.default.removeItem(at: file)
                        try FileManager.default.moveItem(at: location, to: file)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                // The task's own byte counts: its `progress` object counts in percent units here.
                observation.value = download.observe(\.countOfBytesReceived) { task, _ in
                    let expected = task.countOfBytesExpectedToReceive
                    report(.downloading(received: task.countOfBytesReceived, total: expected > 0 ? expected : downloadBytes))
                }
                task.value = download
                // Cancelled before the task existed: the handler below had nothing to cancel.
                if Task.isCancelled { download.cancel() }
                download.resume()
            }
        } onCancel: {
            task.value?.cancel()
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum AudioDecoding {
    /// Reads `seconds` of a file from `offset` as 44.1 kHz stereo float.
    static func read(_ url: URL, offset: Double = 0, seconds: Double = .infinity) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let startFrame = AVAudioFramePosition(offset * source.sampleRate)
        file.framePosition = min(startFrame, file.length)
        let frames = AVAudioFrameCount(min(Double(file.length - file.framePosition), seconds * source.sampleRate))
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames)!
        try file.read(into: input, frameCount: frames)

        let target = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let converter = AVAudioConverter(from: source, to: target)!
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 44_100 / source.sampleRate) + 4_096
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let count = Int(output.frameLength)
        let left = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
        let right = source.channelCount > 1 || target.channelCount > 1
            ? Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: count)) : left
        return (left, right)
    }
}
