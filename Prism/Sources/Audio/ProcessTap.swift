import AudioToolbox
import CoreAudio
import Foundation

/// What to listen to.
enum TapTarget: Hashable, Sendable {
    /// Every process whose bundle ID starts with one of these (an app and its helpers).
    case apps([String])
    /// Everything the Mac plays except Prism itself.
    case system
    /// Specific processes (testing).
    case pids([pid_t])
}

/// A Core Audio process tap feeding a private aggregate device whose clock is the current output
/// device. The tapped apps are muted while the tap runs, and one IO callback both receives their
/// audio and writes to the speakers, so input and output can never drift apart.
nonisolated final class ProcessTap: @unchecked Sendable {
    typealias Render = (_ input: UnsafePointer<Float>?, _ inputStride: Int, _ output: UnsafeMutablePointer<AudioBufferList>,
                        _ frames: Int) -> Void

    let sampleRate: Double
    let outputDeviceName: String
    /// The output device the aggregate is clocked by.
    let outputDeviceID: AudioObjectID
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The aggregate device the IO callback runs on.
    var deviceID: AudioObjectID { aggregateID }
    private let tapIsInterleaved: Bool
    private let tapChannels: Int
    /// Non-interleaved taps are copied here so the renderer sees one layout.
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)

    /// Process objects matching `target`; empty when none of the apps has played audio yet.
    static func processes(for target: TapTarget) -> [AudioObjectID] {
        if case .pids(let pids) = target {
            return AudioObjects.processes.filter { pids.contains(AudioObjects.pid(ofProcess: $0)) }
        }
        guard case .apps(let bundleIDs) = target else { return [] }
        return AudioObjects.processes.filter { process in
            guard let id = AudioObjects.bundleID(ofProcess: process) else { return false }
            return bundleIDs.contains { id == $0 || id.hasPrefix($0 + ".") }
        }
    }

    init(target: TapTarget, processes: [AudioObjectID]) throws {
        let output = AudioObjects.defaultOutputDevice
        guard let outputUID = AudioObjects.uid(output) else {
            throw CoreAudioError(what: "Finding the output device", status: -1)
        }
        outputDeviceName = AudioObjects.name(output) ?? "Output"
        outputDeviceID = output
        // Tap what the processes send to the output device's first stream, in its own channel layout,
        // and read the front pair. A stereo mixdown would scale it: on a multichannel device (the
        // Studio Display has 8 channels) the HAL divides the fold-down by the channel count.
        let description: CATapDescription
        switch target {
        case .apps, .pids:
            description = CATapDescription(processes: processes, deviceUID: outputUID, stream: 0)
        case .system:
            let own = AudioObjects.processes.filter { AudioObjects.pid(ofProcess: $0) == getpid() }
            description = CATapDescription(excludingProcesses: own, deviceUID: outputUID, stream: 0)
        }
        description.name = "Prism"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the audio tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjects.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Reading the tap format")
        tapChannels = Int(format.mChannelsPerFrame)
        tapIsInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Prism",
            kAudioAggregateDeviceUIDKey: "com.mattfalconer.Prism.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        if status != noErr {
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(what: "Creating the aggregate device", status: status)
        }
        let rate = AudioObjects.sampleRate(aggregateID)
        sampleRate = rate > 0 ? rate : format.mSampleRate
    }

    deinit {
        stop()
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        scratch.deallocate()
    }

    /// Starts IO. `render` runs on the real-time thread with the tap's interleaved stereo (or nil)
    /// and the output device's buffers to fill.
    func start(_ render: @escaping Render) throws {
        let channels = tapChannels, interleaved = tapIsInterleaved, scratch = scratch
        let block: AudioDeviceIOBlock = { _, inputData, _, outputData, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            var frames = 0
            if let first = outputs.first, first.mNumberChannels > 0 {
                frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
            }
            var source: UnsafePointer<Float>?
            var stride = max(channels, 1)
            if interleaved, let tap = inputs.last, let data = tap.mData {
                stride = Int(max(tap.mNumberChannels, 1))
                let inputFrames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * stride)
                frames = frames == 0 ? inputFrames : min(frames, inputFrames)
                source = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            } else if !interleaved, inputs.count >= channels, channels > 0 {
                let planes = inputs.suffix(channels)
                let inputFrames = Int(planes.first!.mDataByteSize) / MemoryLayout<Float>.size
                frames = frames == 0 ? inputFrames : min(frames, inputFrames, 16_384 / channels)
                for (c, plane) in planes.enumerated() {
                    guard let data = plane.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { scratch[i * channels + c] = data[i] }
                }
                source = UnsafePointer(scratch)
            }
            render(source, stride, outputData, frames)
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block), "Creating the IO callback")
        try check(AudioDeviceStart(aggregateID, procID), "Starting audio")
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        self.procID = nil
    }
}
