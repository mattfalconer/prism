import AudioToolbox
import AVFoundation
import Foundation

/// Hosts one of the system's internal neural audio units between a forward and inverse FFT.
/// macOS provides the model and tunings. The graph file only describes the probe's signal path.
nonisolated final class NativeAudioGraph {
    static let sampleRate = 48_000.0
    static let blockSize = 1_024
    private static let channels = 4

    struct Failure: LocalizedError {
        let operation: String
        var errorDescription: String? { operation }
    }

    private static let tuningDirectory = URL(fileURLWithPath:
        "/System/Library/Audio/Tunings/Generic/CinematicSeparation/Tunings")
    private static let tuning = tuningDirectory.appendingPathComponent("separate_and_remix_music")
    private let unit: AudioUnit
    private let input: UnsafeMutablePointer<Float>
    private let output: AVAudioPCMBuffer
    private var sampleTime: Double = 0
    let latencyFrames: Int

    static var hasSystemAssets: Bool {
        let system = tuningDirectory.deletingLastPathComponent()
        let models = ["D_FOA", "D_Music"].flatMap { model in
            ["aufx-nnet-appl.plist", "vi-nnet.mil", "weights/vi-nnet.weight.bin"].map {
                system.appendingPathComponent("shared/\(model)/AU/\($0)")
            }
        }
        return (models + ["propstrip", "austrip"].map(tuning.appendingPathExtension))
            .allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    init(node: String, directory: URL) throws {
        // Opening AUAudioMix registers Apple's internal graph and the audio units it hosts.
        let host = try Self.open(type: kAudioUnitType_FormatConverter, subtype: kAudioUnitSubType_AUAudioMix)
        defer { AudioComponentInstanceDispose(host) }
        let graph = try Self.open(type: kAudioUnitType_Effect, subtype: 0x64737067) // dspg
        var keepGraph = false
        defer { if !keepGraph { AudioComponentInstanceDispose(graph) } }

        let path = directory.appendingPathComponent("\(node).dspg")
        try Self.graphText(node: node).write(to: path, atomically: true, encoding: .utf8)
        try Self.setReference(path.path as CFString, property: 0x64737067, on: graph, operation: "load graph")
        try Self.setReference(Self.properties(for: node), property: 0x70727370, on: graph, operation: "load properties")
        try Self.setReference(Self.presets(for: node), property: 0x61757370, on: graph, operation: "load presets")

        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(Self.channels)) else {
            throw Failure(operation: "Could not configure the Apple Audio Mix channel layout.")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channelLayout: layout)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(Self.blockSize)) else {
            throw Failure(operation: "Could not allocate the Apple Audio Mix buffer.")
        }
        output.frameLength = output.frameCapacity
        var stream = format.streamDescription.pointee
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            try Self.check(AudioUnitSetProperty(graph, kAudioUnitProperty_StreamFormat, scope, 0,
                                                &stream, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set format")
        }

        let input = UnsafeMutablePointer<Float>.allocate(capacity: Self.channels * Self.blockSize)
        var keepInput = false
        defer { if !keepInput { input.deallocate() } }
        var callback = AURenderCallbackStruct(inputProc: Self.renderInput, inputProcRefCon: input)
        try Self.check(AudioUnitSetProperty(graph, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try Self.check(AudioUnitInitialize(graph), "initialize")

        var latency = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        try Self.check(AudioUnitGetProperty(graph, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
                                            &latency, &size), "read latency")
        guard latency > 0, latency < 2 else {
            throw Failure(operation: "Apple Audio Mix returned an unsupported model latency.")
        }
        latencyFrames = Int((latency * Self.sampleRate).rounded())
        self.unit = graph
        self.input = input
        self.output = output
        keepInput = true
        keepGraph = true
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        input.deallocate()
    }

    func process(_ stereo: [SIMD2<Float>]) throws -> [SIMD2<Float>] {
        let frames = Self.blockSize
        precondition(stereo.count == frames)
        for (index, sample) in stereo.enumerated() {
            let mid = (sample.x + sample.y) * 0.5
            input[index] = mid                                   // W
            input[frames + index] = (sample.x - sample.y) * 0.5   // Y
            input[2 * frames + index] = 0                        // Z
            input[3 * frames + index] = mid * 0.8660254            // X
        }
        output.frameLength = UInt32(frames)
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid
        var flags: AudioUnitRenderActionFlags = []
        let buffers = output.mutableAudioBufferList
        try Self.check(AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(frames), buffers), "render")
        sampleTime += Double(frames)

        let rendered = UnsafeMutableAudioBufferListPointer(buffers)
        guard let mid = rendered[0].mData?.assumingMemoryBound(to: Float.self),
              let side = rendered[1].mData?.assumingMemoryBound(to: Float.self) else {
            throw Failure(operation: "Apple Audio Mix returned no audio buffers.")
        }
        return (0..<frames).map { SIMD2(mid[$0] + side[$0], mid[$0] - side[$0]) }
    }

    private static let renderInput: AURenderCallback = { context, _, _, _, frames, data in
        guard let data, frames == UInt32(blockSize) else {
            return kAudioUnitErr_InvalidPropertyValue
        }
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        guard buffers.count == channels else { return kAudioUnitErr_FormatNotSupported }
        let source = context.assumingMemoryBound(to: Float.self)
        let bytes = Int(frames) * MemoryLayout<Float>.size
        for channel in buffers.indices {
            let plane = source + channel * blockSize
            if let destination = buffers[channel].mData {
                guard buffers[channel].mDataByteSize >= UInt32(bytes) else { return kAudioUnitErr_InvalidPropertyValue }
                memcpy(destination, plane, bytes)
            } else {
                buffers[channel].mData = UnsafeMutableRawPointer(plane)
            }
            buffers[channel].mDataByteSize = UInt32(bytes)
        }
        return noErr
    }

    private static func open(type: OSType, subtype: OSType) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: type, componentSubType: subtype,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure(operation: "This macOS build does not expose the Apple Audio Mix graph.")
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "open")
        guard let unit else { throw Failure(operation: "Could not open Apple Audio Mix.") }
        return unit
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Failure(operation: "Apple Audio Mix could not \(operation) (\(status)).") }
    }

    private static func setReference(_ value: CFTypeRef, property: AudioUnitPropertyID, on unit: AudioUnit,
                                     operation: String) throws {
        // These three properties take a pointer to a CF object reference, as opposed to its bytes.
        var reference = Unmanaged.passUnretained(value).toOpaque()
        try withExtendedLifetime(value) {
            try check(AudioUnitSetProperty(unit, property, kAudioUnitScope_Global, 0,
                                          &reference, UInt32(MemoryLayout.size(ofValue: reference))), operation)
        }
    }

    private static func plist(_ ext: String) throws -> [String: Any] {
        let data = try Data(contentsOf: tuning.appendingPathExtension(ext))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure(operation: "This macOS build has an unsupported Apple Audio Mix configuration.")
        }
        return plist
    }

    private static func properties(for node: String) throws -> CFDictionary {
        let boxes = try plist("propstrip")["Boxes"] as? [[String: Any]]
        guard let box = boxes?.first(where: { $0["Name"] as? String == node }) else {
            throw Failure(operation: "An Apple Audio Mix model configuration is missing.")
        }
        return ["Boxes": [box]] as CFDictionary
    }

    private static func presets(for node: String) throws -> CFDictionary {
        let strips = try plist("austrip")["strips"] as? [[String: Any]]
        let effects = strips?.first?["effects"] as? [[String: Any]]
        guard let effect = effects?.first(where: { $0["displayname"] as? String == node }) else {
            throw Failure(operation: "An Apple Audio Mix model preset is missing.")
        }
        return ["strips": [["effects": [effect]]]] as CFDictionary
    }

    private static func graphText(node: String) -> String {
        """
        graphName "Prism Native Separation"
        [def numChannelsIn 4]
        [def numChannelsOut 4]
        [def sampleRateIn 48000]
        [def sampleRateOut 48000]
        [def blockSizeIn 1024]
        [def blockSizeOut 1024]
        format inputFormat ([sampleRateIn] [numChannelsIn] [blockSizeIn])
        format outputFormat ([sampleRateOut] [numChannelsOut] [blockSizeOut])
        format spectrum (freq 48000 4 1024)
        in input
        out output
        box analysis fft 1 1
        box \(node) (aufx nnet appl) 1 1
        box synthesis fft 1 1
        wire input analysis inputFormat
        wire analysis \(node) spectrum
        wire \(node) synthesis spectrum
        wire synthesis output outputFormat

        """
    }
}
