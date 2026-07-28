import CoreAudio
import CoreMediaIO
import Foundation
import IOKit

/// The environmental signals the scheduler reads. All are pure reads of public
/// system properties: no capture, no special permission, no blocking.
enum Signals {

    /// True when a call is likely in progress: any audio **input** device is
    /// capturing, OR any camera is running. Deliberately app-agnostic (works for
    /// Zoom, Teams, Meet, FaceTime, huddles) and device-agnostic (checks every
    /// input device, not just the system default, so AirPods / interfaces count).
    /// The camera check catches the muted-but-on-video case.
    ///
    /// Remaining gap: muted with the camera off leaves no signal to read. Use
    /// Pause for those.
    static func inCall() -> Bool { anyInputRunning() || anyCameraRunning() }

    // Kept for the older call sites / `--check`.
    static func micInUse() -> Bool { anyInputRunning() }

    // MARK: audio

    private static func anyInputRunning() -> Bool {
        audioDevices().contains { hasInputChannels($0) && isRunningSomewhere($0) }
    }

    private static func audioDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInputChannels(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0
        else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: camera (CoreMediaIO)

    private static func anyCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
        else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr
        else { return false }

        var runAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        for id in ids {
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var u: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &runAddr, 0, nil, s, &u, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    // MARK: idle

    /// Seconds since the last human input event (keyboard/mouse/trackpad),
    /// system-wide. Read from IOHIDSystem's HIDIdleTime. Not keylogging: an
    /// aggregate idle counter, no permission needed.
    static func idleSeconds() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let idleNanos = dict["HIDIdleTime"] as? UInt64
        else { return 0 }
        return Double(idleNanos) / 1_000_000_000.0
    }
}
