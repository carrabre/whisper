import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    fileprivate let deviceID: AudioDeviceID
}

final class AudioDeviceManager {
    enum AudioDeviceError: LocalizedError {
        case inputDeviceUnavailable
        case couldNotSwitchInputDevice

        var errorDescription: String? {
            switch self {
            case .inputDeviceUnavailable:
                return "The selected microphone is no longer available."
            case .couldNotSwitchInputDevice:
                return "spk could not switch to the selected microphone."
            }
        }
    }

    func inputDevices() -> [AudioInputDevice] {
        systemDeviceIDs()
            .filter(hasInputChannels)
            .compactMap { deviceID in
                guard
                    let uniqueID = stringProperty(
                        selector: kAudioDevicePropertyDeviceUID,
                        deviceID: deviceID,
                        scope: kAudioObjectPropertyScopeGlobal
                    ),
                    let name = stringProperty(
                        selector: kAudioObjectPropertyName,
                        deviceID: deviceID,
                        scope: kAudioObjectPropertyScopeGlobal
                    )
                else {
                    return nil
                }

                return AudioInputDevice(id: uniqueID, name: name, deviceID: deviceID)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func defaultInputDeviceID() -> String? {
        guard let deviceID = defaultInputDevice() else { return nil }
        return stringProperty(
            selector: kAudioDevicePropertyDeviceUID,
            deviceID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func defaultInputDeviceName() -> String? {
        guard let deviceID = defaultInputDevice() else { return nil }
        return stringProperty(
            selector: kAudioObjectPropertyName,
            deviceID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func setDefaultInputDevice(id uniqueID: String) throws {
        guard let device = inputDevices().first(where: { $0.id == uniqueID }) else {
            throw AudioDeviceError.inputDeviceUnavailable
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = device.deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &deviceID
        )

        guard status == noErr else {
            throw AudioDeviceError.couldNotSwitchInputDevice
        }
    }

    private func defaultInputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID = AudioDeviceID(0)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    private func systemDeviceIDs() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.filter { $0 != kAudioObjectUnknown }
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &propertyAddress) else {
            return false
        }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            bufferListPointer.deallocate()
        }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, audioBufferList) == noErr else {
            return false
        }

        return UnsafeMutableAudioBufferListPointer(audioBufferList).contains { $0.mNumberChannels > 0 }
    }

    private func stringProperty(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &propertyAddress) else {
            return nil
        }

        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                valuePointer
            )
        }

        guard status == noErr, let value else {
            return nil
        }

        return value as String
    }
}
