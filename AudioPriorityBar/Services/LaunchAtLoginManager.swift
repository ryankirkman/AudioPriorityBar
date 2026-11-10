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

/// `AudioPriorityBar --register-login-item` is the same as switching "Login" on in the
/// popover; `--unregister-login-item` is used by `make uninstall`, because the registration
/// lives with the system, not in the bundle, and only the app itself can remove it.
enum LoginItemCommand {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        if arguments.contains("--register-login-item") {
            do {
                try SMAppService.mainApp.register()
                print("Launch at login: on")
            } catch {
                print("Couldn't turn on launch at login: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }
    }
}
