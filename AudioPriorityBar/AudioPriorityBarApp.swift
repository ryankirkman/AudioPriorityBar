import SwiftUI
import CoreAudio

@main
struct AudioPriorityBarApp: App {
    @StateObject private var audioManager = AudioManager()

    init() {
        LoginItemCommand.runIfRequested()   // exits if a command-line flag asked for one
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(audioManager)
        } label: {
            MenuBarLabel(
                isOutputMuted: audioManager.isActiveOutputMuted,
                isInputMuted: audioManager.isActiveInputMuted,
                isCustomMode: audioManager.isCustomMode,
                mode: audioManager.currentMode,
                micFlash: audioManager.micFlashState
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar fits a single symbol, so the label picks one icon by
/// priority: alerts first, then whichever mode is active.
struct MenuBarLabel: View {
    let isOutputMuted: Bool
    let isInputMuted: Bool
    let isCustomMode: Bool
    let mode: OutputCategory
    let micFlash: Bool

    private var symbol: String {
        if isInputMuted {
            return micFlash ? "mic.fill" : "mic.slash.fill"
        }
        if isOutputMuted {
            return "speaker.slash.fill"
        }
        if isCustomMode {
            return "hand.raised.fill"
        }
        return mode.icon
    }

    var body: some View {
        Image(systemName: symbol)
    }
}

@MainActor
class AudioManager: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var speakerDevices: [AudioDevice] = []
    @Published var headphoneDevices: [AudioDevice] = []
    @Published var hiddenInputDevices: [AudioDevice] = []
    @Published var hiddenSpeakerDevices: [AudioDevice] = []
    @Published var hiddenHeadphoneDevices: [AudioDevice] = []
    @Published var currentInputId: AudioObjectID?
    @Published var currentOutputId: AudioObjectID?
    @Published var currentMode: OutputCategory = .speaker
    @Published var volume: Float = 0
    @Published var isEditMode: Bool = false
    @Published var isCustomMode: Bool = false
    // Kept per direction: a device with inputs and outputs has one ID for both.
    @Published var mutedInputIds: Set<AudioObjectID> = []
    @Published var mutedOutputIds: Set<AudioObjectID> = []
    @Published var isActiveOutputMuted: Bool = false
    @Published var isActiveInputMuted: Bool = false
    @Published var micFlashState: Bool = false

    private let deviceService = AudioDeviceService()
    private var micFlashTimer: Timer?
    let priorityManager = PriorityManager()
    private var connectedDeviceUIDs: Set<String> = []

    func refreshVolume() {
        volume = deviceService.getOutputVolume()
    }

    func refreshMuteStatus() {
        var mutedInputs: Set<AudioObjectID> = []
        for device in inputDevices where device.isConnected {
            if deviceService.isDeviceMuted(device.id, type: .input) {
                mutedInputs.insert(device.id)
            }
        }
        var mutedOutputs: Set<AudioObjectID> = []
        for device in speakerDevices + headphoneDevices where device.isConnected {
            if deviceService.isDeviceMuted(device.id, type: .output) {
                mutedOutputs.insert(device.id)
            }
        }
        mutedInputIds = mutedInputs
        mutedOutputIds = mutedOutputs
        isActiveOutputMuted = currentOutputId.map(mutedOutputs.contains) ?? false
        isActiveInputMuted = currentInputId.map(mutedInputs.contains) ?? false
        if isActiveInputMuted && micFlashTimer == nil {
            micFlashTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.micFlashState.toggle()
                }
            }
        } else if !isActiveInputMuted && micFlashTimer != nil {
            micFlashTimer?.invalidate()
            micFlashTimer = nil
            micFlashState = false
        }
    }

    func isDeviceMuted(_ device: AudioDevice) -> Bool {
        (device.type == .input ? mutedInputIds : mutedOutputIds).contains(device.id)
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        deviceService.setOutputVolume(newVolume)
    }

    var activeOutputDevices: [AudioDevice] {
        switch currentMode {
        case .speaker: return speakerDevices
        case .headphone: return headphoneDevices
        }
    }

    init() {
        currentMode = priorityManager.currentMode
        isCustomMode = priorityManager.isCustomMode
        refreshDevices()
        previousConnectedUIDs = connectedDeviceUIDs  // Initialize tracking
        refreshVolume()
        refreshMuteStatus()
        setupDeviceChangeListener()
        setupMuteVolumeListener()
        if !isCustomMode {
            // Covers quitting on headphones and launching without them.
            autoSwitchModeIfNeeded(newlyConnectedUIDs: [])
            applyHighestPriorityInput()
            applyHighestPriorityOutput()
        }
    }

    private func setupMuteVolumeListener() {
        deviceService.onMuteOrVolumeChanged = { [weak self] in
            Task { @MainActor in
                self?.handleMuteOrVolumeChange()
            }
        }
    }

    private func handleMuteOrVolumeChange() {
        refreshMuteStatus()
        refreshVolume()
    }

    func refreshDevices() {
        let allConnectedDevices = deviceService.getDevices()
        connectedDeviceUIDs = Set(allConnectedDevices.map { $0.uid })
        priorityManager.rememberDevices(allConnectedDevices)
        let connectedInputs = allConnectedDevices.filter { $0.type == .input }
        let connectedOutputs = allConnectedDevices.filter { $0.type == .output }

        if isEditMode {
            let knownDevices = priorityManager.getKnownDevices()
            var allInputs: [AudioDevice] = connectedInputs
            for stored in knownDevices where stored.isInput {
                if !connectedDeviceUIDs.contains(stored.uid) {
                    allInputs.append(.disconnected(uid: stored.uid, name: stored.name, type: .input))
                }
            }
            var allOutputs: [AudioDevice] = connectedOutputs
            for stored in knownDevices where !stored.isInput {
                if !connectedDeviceUIDs.contains(stored.uid) {
                    allOutputs.append(.disconnected(uid: stored.uid, name: stored.name, type: .output))
                }
            }
            inputDevices = priorityManager.sortByPriority(allInputs, type: .input)
            hiddenInputDevices = []
            let speakers = allOutputs.filter { priorityManager.getCategory(for: $0) == .speaker }
            let headphones = allOutputs.filter { priorityManager.getCategory(for: $0) == .headphone }
            speakerDevices = priorityManager.sortByPriority(speakers, category: .speaker)
            headphoneDevices = priorityManager.sortByPriority(headphones, category: .headphone)
            hiddenSpeakerDevices = []
            hiddenHeadphoneDevices = []
        } else {
            // Filter out hidden and never-use devices in normal mode
            let visibleInputs = connectedInputs.filter { !priorityManager.isHidden($0) && !priorityManager.isNeverUse($0) }
            // Hidden inputs: regular hidden first, then never-use
            let regularHiddenInputs = connectedInputs.filter { priorityManager.isHidden($0) && !priorityManager.isNeverUse($0) }
            let neverUseInputs = connectedInputs.filter { priorityManager.isNeverUse($0) }
            inputDevices = priorityManager.sortByPriority(visibleInputs, type: .input)
            hiddenInputDevices = regularHiddenInputs + neverUseInputs

            let speakers = connectedOutputs.filter { priorityManager.getCategory(for: $0) == .speaker }
            let headphones = connectedOutputs.filter { priorityManager.getCategory(for: $0) == .headphone }
            let visibleSpeakers = speakers.filter { !priorityManager.isHidden($0, inCategory: .speaker) && !priorityManager.isNeverUse($0) }
            let visibleHeadphones = headphones.filter { !priorityManager.isHidden($0, inCategory: .headphone) && !priorityManager.isNeverUse($0) }
            // Hidden outputs: regular hidden first, then never-use
            let regularHiddenSpeakers = speakers.filter { priorityManager.isHidden($0, inCategory: .speaker) && !priorityManager.isNeverUse($0) }
            let neverUseSpeakers = speakers.filter { priorityManager.isNeverUse($0) }
            let regularHiddenHeadphones = headphones.filter { priorityManager.isHidden($0, inCategory: .headphone) && !priorityManager.isNeverUse($0) }
            let neverUseHeadphones = headphones.filter { priorityManager.isNeverUse($0) }
            speakerDevices = priorityManager.sortByPriority(visibleSpeakers, category: .speaker)
            headphoneDevices = priorityManager.sortByPriority(visibleHeadphones, category: .headphone)
            hiddenSpeakerDevices = regularHiddenSpeakers + neverUseSpeakers
            hiddenHeadphoneDevices = regularHiddenHeadphones + neverUseHeadphones
        }
        currentInputId = deviceService.getCurrentDefaultDevice(type: .input)
        currentOutputId = deviceService.getCurrentDefaultDevice(type: .output)
    }

    func toggleEditMode() {
        isEditMode.toggle()
        refreshDevices()
    }

    /// Tracks device UIDs from the previous refresh to detect new connections
    private var previousConnectedUIDs: Set<String> = []
    
    func setMode(_ mode: OutputCategory) {
        currentMode = mode
        priorityManager.currentMode = mode
        if !isCustomMode {
            applyHighestPriorityOutput()
        }
    }

    func setCustomMode(_ enabled: Bool) {
        isCustomMode = enabled
        priorityManager.isCustomMode = enabled
        if !enabled {
            applyHighestPriorityInput()
            applyHighestPriorityOutput()
        }
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        priorityManager.setCategory(category, for: device)
        refreshDevices()
        if !isCustomMode {
            applyHighestPriorityOutput()
        }
    }

    func hideDevice(_ device: AudioDevice, category: OutputCategory? = nil) {
        if device.type == .input {
            priorityManager.hideDevice(device)
        } else if let cat = category {
            priorityManager.hideDevice(device, inCategory: cat)
        } else {
            priorityManager.hideDevice(device)
        }
        refreshDevices()
        if !isCustomMode {
            if device.type == .input {
                applyHighestPriorityInput()
            } else {
                applyHighestPriorityOutput()
            }
        }
    }

    func hideDeviceEntirely(_ device: AudioDevice) {
        priorityManager.hideDevice(device, inCategory: .speaker)
        priorityManager.hideDevice(device, inCategory: .headphone)
        refreshDevices()
        if !isCustomMode {
            applyHighestPriorityOutput()
        }
    }

    func unhideDevice(_ device: AudioDevice, category: OutputCategory? = nil) {
        if device.type == .input {
            priorityManager.unhideDevice(device)
        } else if let cat = category {
            priorityManager.unhideDevice(device, fromCategory: cat)
        } else {
            priorityManager.unhideDevice(device)
        }
        refreshDevices()
    }

    func isDeviceIgnored(_ device: AudioDevice, inCategory category: OutputCategory? = nil) -> Bool {
        if device.type == .input {
            return priorityManager.isHidden(device)
        } else if let cat = category {
            return priorityManager.isHidden(device, inCategory: cat)
        } else {
            return priorityManager.isHidden(device)
        }
    }

    func isNeverUse(_ device: AudioDevice) -> Bool {
        priorityManager.isNeverUse(device)
    }

    func setNeverUse(_ device: AudioDevice, neverUse: Bool) {
        priorityManager.setNeverUse(device, neverUse: neverUse)
        refreshDevices()
        if !isCustomMode {
            if device.type == .input {
                applyHighestPriorityInput()
            } else {
                applyHighestPriorityOutput()
            }
        }
    }

    func moveInputDevice(from source: IndexSet, to destination: Int) {
        inputDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(inputDevices, type: .input)
        if !isCustomMode {
            applyHighestPriorityInput()
        }
    }

    func moveSpeakerDevice(from source: IndexSet, to destination: Int) {
        speakerDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(speakerDevices, category: .speaker)
        if !isCustomMode {
            applyHighestPriorityOutput()
        }
    }

    func moveHeadphoneDevice(from source: IndexSet, to destination: Int) {
        headphoneDevices.move(fromOffsets: source, toOffset: destination)
        priorityManager.savePriorities(headphoneDevices, category: .headphone)
        if !isCustomMode {
            applyHighestPriorityOutput()
        }
    }

    func setInputDevice(_ device: AudioDevice) {
        applyInputDevice(device)
    }

    func setOutputDevice(_ device: AudioDevice) {
        applyOutputDevice(device)
    }

    private func applyInputDevice(_ device: AudioDevice) {
        deviceService.setDefaultDevice(device.id, type: .input)
        currentInputId = device.id
    }

    private func applyOutputDevice(_ device: AudioDevice) {
        deviceService.setDefaultDevice(device.id, type: .output)
        currentOutputId = device.id
    }

    /// Whether auto-switching may pick this device. Edit mode lists ignored devices too,
    /// so being in a list isn't enough.
    private func isAutoSelectable(_ device: AudioDevice) -> Bool {
        device.isConnected && !priorityManager.isNeverUse(device) && !priorityManager.isHidden(device)
    }

    private func applyHighestPriorityInput() {
        if let first = inputDevices.first(where: isAutoSelectable) {
            applyInputDevice(first)
        }
    }

    private func applyHighestPriorityOutput() {
        if let first = activeOutputDevices.first(where: isAutoSelectable) {
            applyOutputDevice(first)
        }
        refreshMuteStatus()
    }

    private func setupDeviceChangeListener() {
        deviceService.onDevicesChanged = { [weak self] in
            Task { @MainActor in
                self?.handleDeviceChange()
            }
        }
        deviceService.startListening()
    }

    private func handleDeviceChange() {
        let oldConnectedUIDs = previousConnectedUIDs
        refreshDevices()
        refreshMuteStatus()
        refreshVolume()   // the default output may be a different device now

        // Detect newly connected devices
        let newlyConnectedUIDs = connectedDeviceUIDs.subtracting(oldConnectedUIDs)
        previousConnectedUIDs = connectedDeviceUIDs
        
        if !isCustomMode {
            // Auto-switch mode only when a new headphone connects or all headphones disconnect
            autoSwitchModeIfNeeded(newlyConnectedUIDs: newlyConnectedUIDs)
            applyHighestPriorityInput()
            applyHighestPriorityOutput()
        }
    }
    
    /// Automatically switches between headphone and speaker mode based on device connections.
    /// Only triggers on:
    /// 1. A new headphone device connects → switch to headphone mode
    /// 2. All headphones disconnect → switch to speaker mode
    private func autoSwitchModeIfNeeded(newlyConnectedUIDs: Set<String>) {
        let connectedHeadphones = headphoneDevices.filter(isAutoSelectable)
        let hasConnectedHeadphones = !connectedHeadphones.isEmpty
        let hasConnectedSpeakers = speakerDevices.contains(where: isAutoSelectable)
        
        // Check if a new headphone just connected
        let newHeadphoneConnected = connectedHeadphones.contains { newlyConnectedUIDs.contains($0.uid) }
        
        if newHeadphoneConnected && currentMode != .headphone {
            // A new headphone just connected - switch to headphone mode
            currentMode = .headphone
            priorityManager.currentMode = .headphone
        } else if !hasConnectedHeadphones && hasConnectedSpeakers && currentMode == .headphone {
            // All headphones disconnected - switch back to speaker mode
            currentMode = .speaker
            priorityManager.currentMode = .speaker
        }
    }
}
