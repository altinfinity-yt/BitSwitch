import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

struct AudioFormat: Equatable, CustomStringConvertible {
    let sampleRate: Float64
    let bitsPerChannel: Int

    var description: String {
        let rateKHz = sampleRate / 1000.0
        let rateStr = rateKHz.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rateKHz))"
            : String(format: "%.1f", rateKHz)
        return "\(rateStr)kHz / \(bitsPerChannel)-bit"
    }
}

enum AudioDeviceManager {
    // MARK: - Device Enumeration

    static func allOutputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioDevice? in
            guard hasOutputStreams(deviceID: id) else { return nil }
            guard let name = deviceName(id), let uid = deviceUID(id) else { return nil }
            return AudioDevice(id: id, name: name, uid: uid)
        }
    }

    static func defaultOutputDevice() -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        guard let name = deviceName(deviceID), let uid = deviceUID(deviceID) else { return nil }
        return AudioDevice(id: deviceID, name: name, uid: uid)
    }

    static func findDevice(nameContaining search: String) -> AudioDevice? {
        allOutputDevices().first { $0.name.localizedCaseInsensitiveContains(search) }
    }

    // MARK: - Format Query

    static func currentFormat(deviceID: AudioDeviceID) -> AudioFormat? {
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.stride)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate) == noErr else {
            return nil
        }

        let bitsPerChannel = currentBitDepth(deviceID: deviceID) ?? 0
        return AudioFormat(sampleRate: sampleRate, bitsPerChannel: bitsPerChannel)
    }

    // MARK: - Format Switching

    static func setSampleRate(deviceID: AudioDeviceID, sampleRate: Float64) -> Bool {
        var rate = sampleRate
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !isSettable(deviceID: deviceID, address: &address) { return false }

        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Float64>.stride), &rate
        )
        return status == noErr
    }

    static func setBitDepth(deviceID: AudioDeviceID, bitsPerChannel: Int) -> Bool {
        guard let streamID = firstOutputStream(deviceID: deviceID) else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var currentFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &currentFormat) == noErr else {
            return false
        }

        // Find the best matching format with desired bit depth
        if let bestFormat = findBestFormat(
            streamID: streamID,
            targetSampleRate: currentFormat.mSampleRate,
            targetBitsPerChannel: UInt32(bitsPerChannel)
        ) {
            var newFormat = bestFormat
            let status = AudioObjectSetPropertyData(
                streamID, &address, 0, nil,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.stride), &newFormat
            )
            return status == noErr
        }
        return false
    }

    static func switchFormat(deviceID: AudioDeviceID, sampleRate: Int, bitsPerChannel: Int) -> Bool {
        guard let streamID = firstOutputStream(deviceID: deviceID) else { return false }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let bestFormat = findBestFormat(
            streamID: streamID,
            targetSampleRate: Float64(sampleRate),
            targetBitsPerChannel: UInt32(bitsPerChannel)
        ) {
            var newFormat = bestFormat
            let status = AudioObjectSetPropertyData(
                streamID, &address, 0, nil,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.stride), &newFormat
            )
            if status == noErr {
                let rateOK = setSampleRate(deviceID: deviceID, sampleRate: Float64(sampleRate))
                return rateOK
            }
        }

        // Fallback: just set sample rate if stream format change fails
        return setSampleRate(deviceID: deviceID, sampleRate: Float64(sampleRate))
    }

    // MARK: - Available Formats

    static func availableFormats(deviceID: AudioDeviceID) -> [AudioStreamBasicDescription] {
        guard let streamID = firstOutputStream(deviceID: deviceID) else { return [] }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &size) == noErr else {
            return []
        }

        let rangeCount = Int(size) / MemoryLayout<AudioStreamRangedDescription>.stride
        var ranges = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(), count: rangeCount
        )
        guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }

        return ranges.map(\.mFormat)
    }

    // MARK: - Private Helpers

    private static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let cfStr = value else { return nil }
        return cfStr.takeUnretainedValue() as String
    }

    private static func firstOutputStream(deviceID: AudioDeviceID) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }

        let streamCount = Int(size) / MemoryLayout<AudioStreamID>.stride
        var streamIDs = [AudioStreamID](repeating: 0, count: streamCount)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streamIDs) == noErr else {
            return nil
        }
        return streamIDs.first
    }

    private static func currentBitDepth(deviceID: AudioDeviceID) -> Int? {
        guard let streamID = firstOutputStream(deviceID: deviceID) else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &format) == noErr else {
            return nil
        }
        return Int(format.mBitsPerChannel)
    }

    private static func isSettable(deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    private static func findBestFormat(
        streamID: AudioObjectID,
        targetSampleRate: Float64,
        targetBitsPerChannel: UInt32
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &size) == noErr else {
            return nil
        }

        let rangeCount = Int(size) / MemoryLayout<AudioStreamRangedDescription>.stride
        var ranges = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(), count: rangeCount
        )
        guard AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &ranges) == noErr else {
            return nil
        }

        // Exact match first
        for range in ranges {
            let fmt = range.mFormat
            if fmt.mBitsPerChannel == targetBitsPerChannel
                && range.mSampleRateRange.mMinimum <= targetSampleRate
                && range.mSampleRateRange.mMaximum >= targetSampleRate
                && fmt.mFormatID == kAudioFormatLinearPCM {
                var result = fmt
                result.mSampleRate = targetSampleRate
                return result
            }
        }

        // Closest bit depth match at target sample rate
        var bestMatch: AudioStreamBasicDescription?
        var bestDiff: UInt32 = .max
        for range in ranges {
            let fmt = range.mFormat
            guard fmt.mFormatID == kAudioFormatLinearPCM,
                  range.mSampleRateRange.mMinimum <= targetSampleRate,
                  range.mSampleRateRange.mMaximum >= targetSampleRate else { continue }
            let diff = fmt.mBitsPerChannel > targetBitsPerChannel
                ? fmt.mBitsPerChannel - targetBitsPerChannel
                : targetBitsPerChannel - fmt.mBitsPerChannel
            if diff < bestDiff {
                bestDiff = diff
                var result = fmt
                result.mSampleRate = targetSampleRate
                bestMatch = result
            }
        }
        return bestMatch
    }
}
