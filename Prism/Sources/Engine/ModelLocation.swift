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

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: sw.path) }

    enum InstallError: LocalizedError {
        case corrupt
        case server(Int)
        var errorDescription: String? {
            switch self {
            case .corrupt: "The download was damaged. Turn Prism on to try again."
            case .server(let status): "The download server answered \(status). Try again in a minute."
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
        // The extension tells MLX the format, so the half-written copy keeps it until it's moved into place.
        let partial = folder.appendingPathComponent("BS-Roformer-SW.partial.safetensors")
        defer {
            try? FileManager.default.removeItem(at: checkpoint)
            try? FileManager.default.removeItem(at: partial)
        }
        var attempt = 1
        while true {
            do {
                try await download(to: checkpoint, report: report)
                break
            } catch let error as URLError where attempt < 4 && error.code != .cancelled {
            } catch InstallError.server(let status) where attempt < 4 && [403, 408, 429, 500, 502, 503, 504].contains(status) {
            }
            try await Task.sleep(for: .milliseconds(800 * attempt))
            attempt += 1
        }
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            report(.checking)
            guard try sha256(of: checkpoint) == digest else { throw InstallError.corrupt }
            report(.preparing)
            _ = try StemSplitter.convertCheckpoint(checkpoint, to: partial, config: .sw, widen: true)
            if isInstalled { return }   // another copy of Prism finished first
            try FileManager.default.moveItem(at: partial, to: sw)
        }.value
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static func download(to file: URL, report: @escaping @Sendable (Step) -> Void) async throws {
        let task = Box<URLSessionDownloadTask?>(nil)
        let observation = Box<NSKeyValueObservation?>(nil)
        defer { observation.value?.invalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let download = URLSession.shared.downloadTask(with: source) { location, response, error in
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
