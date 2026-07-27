import Foundation
import ServiceManagement

/// Start-at-login via SMAppService. Only functional when running from a real
/// .app bundle (DMG/Homebrew cask install); the bare npm/launchd install
/// manages login via its own LaunchAgent plist instead.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItem toggle failed: \(error)")
        }
    }
}
