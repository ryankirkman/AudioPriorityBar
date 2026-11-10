import Foundation
import CoreAudio
import AudioToolbox

class AudioDeviceService {
    var onDevicesChanged: (() -> Void)?
    var onMuteOrVolumeChanged: (() -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteVolumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var monitoredDeviceIds: Set<AudioObjectID> = []

    private func allDeviceIds() -> [AudioObjectID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIds = [AudioObjectID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIds
        )

        guard status == noErr else { return [] }

        return deviceIds
    }

    func getDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []

        for deviceId in allDeviceIds() {
            if let inputDevice = createDevice(id: deviceId, type: .input) {
                devices.append(inputDevice)
            }
            if let outputDevice = createDevice(id: deviceId, type: .output) {
                devices.append(outputDevice)
            }
        }

        return devices
    }

    func getCurrentDefaultDevice(type: AudioDeviceType) -> AudioObjectID? {
        let selector: AudioObjectPropertySelector = type == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceId: AudioObjectID = 0
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceId
        )

        return status == noErr ? deviceId : nil
    }

    func setDefaultDevice(_ deviceId: AudioObjectID, type: AudioDeviceType) {
        let selector: AudioObjectPropertySelector = type == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableDeviceId = deviceId
        let dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            dataSize,
            &mutableDeviceId
        )
    }

    func getOutputVolume() -> Float {
        guard let deviceId = getCurrentDefaultDevice(type: .output) else { return 0 }
        return outputVolume(of: deviceId) ?? 0
    }

    func setOutputVolume(_ volume: Float) {
        guard let deviceId = getCurrentDefaultDevice(type: .output) else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableVolume = volume
        let dataSize = UInt32(MemoryLayout<Float32>.size)

        AudioObjectSetPropertyData(
            deviceId,
            &propertyAddress,
            0,
            nil,
            dataSize,
            &mutableVolume
        )
    }

    func isDeviceMuted(_ deviceId: AudioObjectID, type: AudioDeviceType) -> Bool {
        let scope: AudioObjectPropertyScope = type == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput

        // Try kAudioDevicePropertyMute (per-channel, element 0 is master)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        var status = AudioObjectGetPropertyData(
            deviceId,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &muted
        )

        if status == noErr && muted != 0 {
            return true
        }

        // Try element 1 (first channel) if master didn't work
        propertyAddress.mElement = 1
        status = AudioObjectGetPropertyData(
            deviceId,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &muted
        )

        if status == noErr && muted != 0 {
            return true
        }

        // Check if volume is essentially zero (some devices report this as muted)
        if type == .output {
            if let volume = outputVolume(of: deviceId), volume < 0.01 {
                return true
            }
        }

        return false
    }

    /// The device's main output volume, or nil if it has no volume control.
    private func outputVolume(of deviceId: AudioObjectID) -> Float? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(
            deviceId,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &volume
        )

        return status == noErr ? volume : nil
    }

    func startListening() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        listenerBlock = { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        // Only a change to the device list needs the per-device mute/volume listeners
        // re-registered; a change of default device doesn't.
        deviceListListenerBlock = { [weak self] _, _ in
            self?.onDevicesChanged?()
            self?.updateMuteVolumeListeners()
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            deviceListListenerBlock!
        )

        // Also listen to default device changes
        var inputDefaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputDefaultAddress,
            DispatchQueue.main,
            listenerBlock!
        )

        var outputDefaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputDefaultAddress,
            DispatchQueue.main,
            listenerBlock!
        )

        // Initial setup of mute/volume listeners
        updateMuteVolumeListeners()
    }

    private func updateMuteVolumeListeners() {
        // Remove old listeners
        removeMuteVolumeListeners()

        // Create listener block
        muteVolumeListenerBlock = { [weak self] _, _ in
            self?.onMuteOrVolumeChanged?()
        }

        // Register listeners for each device
        for deviceId in allDeviceIds() {
            // Listen to mute on output scope
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                deviceId,
                &muteAddress,
                DispatchQueue.main,
                muteVolumeListenerBlock!
            )

            // Listen to mute on input scope
            muteAddress.mScope = kAudioDevicePropertyScopeInput
            AudioObjectAddPropertyListenerBlock(
                deviceId,
                &muteAddress,
                DispatchQueue.main,
                muteVolumeListenerBlock!
            )

            // Listen to volume changes
            var volumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                deviceId,
                &volumeAddress,
                DispatchQueue.main,
                muteVolumeListenerBlock!
            )

            monitoredDeviceIds.insert(deviceId)
        }
    }

    private func removeMuteVolumeListeners() {
        guard let block = muteVolumeListenerBlock else { return }

        for deviceId in monitoredDeviceIds {
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceId, &muteAddress, DispatchQueue.main, block)

            muteAddress.mScope = kAudioDevicePropertyScopeInput
            AudioObjectRemovePropertyListenerBlock(deviceId, &muteAddress, DispatchQueue.main, block)

            var volumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceId, &volumeAddress, DispatchQueue.main, block)
        }

        monitoredDeviceIds.removeAll()
        muteVolumeListenerBlock = nil
    }

    func stopListening() {
        // Remove mute/volume listeners first
        removeMuteVolumeListeners()

        guard let block = listenerBlock, let deviceListBlock = deviceListListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            deviceListBlock
        )

        // Also remove default device change listeners
        var inputDefaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputDefaultAddress,
            DispatchQueue.main,
            block
        )

        var outputDefaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputDefaultAddress,
            DispatchQueue.main,
            block
        )

        listenerBlock = nil
        deviceListListenerBlock = nil
    }

    private func createDevice(id: AudioObjectID, type: AudioDeviceType) -> AudioDevice? {
        let scope: AudioObjectPropertyScope = type == .input
            ? kAudioDevicePropertyScopeInput
            : kAudioDevicePropertyScopeOutput

        guard hasStreams(deviceId: id, scope: scope) else { return nil }

        guard let name = getDeviceName(id: id) else { return nil }
        guard let uid = getDeviceUID(id: id) else { return nil }

        return AudioDevice(id: id, uid: uid, name: name, type: type)
    }

    private func hasStreams(deviceId: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceId,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }

    private func getDeviceName(id: AudioObjectID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceNameCFString, of: id)
    }

    private func getDeviceUID(id: AudioObjectID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: id)
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // CoreAudio hands back a retained CFString; Unmanaged takes ownership of it.
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            id,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    deinit {
        stopListening()
    }
}
