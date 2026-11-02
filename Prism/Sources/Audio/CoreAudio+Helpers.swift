import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (\(status))" }
}

nonisolated func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError(what: what, status: status) }
}

nonisolated enum AudioObjects {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var address = address(selector, scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static var defaultOutputDevice: AudioDeviceID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
    }

    static func uid(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ device: AudioDeviceID) -> String? { string(device, kAudioObjectPropertyName) }

    static func sampleRate(_ device: AudioDeviceID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    /// Audio-producing processes the HAL knows about.
    static var processes: [AudioObjectID] {
        list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    static func bundleID(ofProcess process: AudioObjectID) -> String? { string(process, kAudioProcessPropertyBundleID) }
    static func pid(ofProcess process: AudioObjectID) -> pid_t { value(process, kAudioProcessPropertyPID, default: pid_t(-1)) }
    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        value(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
    }

    /// Calls `handler` on `queue` whenever a property changes. Returns a token that removes the listener.
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, queue: DispatchQueue = .main,
                       handler: @escaping @Sendable () -> Void) -> AudioListener {
        var address = address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        return AudioListener(object: object, address: address, queue: queue, block: block)
    }
}

nonisolated final class AudioListener: @unchecked Sendable {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
         block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
}
