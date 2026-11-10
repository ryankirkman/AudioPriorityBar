import Foundation
import ServiceManagement

@MainActor
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    private init() {}

    func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Failed to change launch at login: \(error)")
        }
        refresh()
    }

    /// Re-reads the real state, which can also change in System Settings.
    func refresh() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != isEnabled {
            isEnabled = enabled
        }
    }
}
