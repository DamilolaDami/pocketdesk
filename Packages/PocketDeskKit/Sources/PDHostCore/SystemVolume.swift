#if os(macOS)
import CoreAudio
import Foundation

/// The default output device's volume, 0–100, through Core Audio (AppleScript's
/// `set volume` silently does nothing from a hardened-runtime app).
enum SystemVolume {
    static func get() -> Int? {
        guard let device = defaultOutput() else { return nil }
        let levels = channels(of: device).compactMap { channel -> Float32? in
            var address = volumeAddress(channel)
            var level: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr ? level : nil
        }
        guard !levels.isEmpty else { return nil }
        return Int((levels.reduce(0, +) / Float32(levels.count) * 100).rounded())
    }

    @discardableResult
    static func set(_ percent: Int) -> Bool {
        guard let device = defaultOutput() else { return false }
        var level = Float32(min(max(percent, 0), 100)) / 100
        var changed = false
        for channel in channels(of: device) {
            var address = volumeAddress(channel)
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level) == noErr {
                changed = true
            }
        }
        return changed
    }

    /// The main element if the device has a master volume, else its left and right channels.
    private static func channels(of device: AudioObjectID) -> [UInt32] {
        var main = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { channel in
            var address = volumeAddress(channel)
            return AudioObjectHasProperty(device, &address)
        }
    }

    private static func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
#endif
