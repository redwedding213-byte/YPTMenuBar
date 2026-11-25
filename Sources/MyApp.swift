import AppKit
import SwiftUI

/// Menu-bar-only app: no window, no Dock icon (LSUIElement in Info.plist).
/// Quit lives in the menu.
@main
@MainActor
struct YPTMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = PomodoroEngine()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(engine.menuBarText)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.35), value: engine.menuBarText)
            }
            .scaleEffect(0.92)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Forwards yptmenu:// URLs (from the browser login helper) to the engine.
/// The token itself is never logged, printed, or stored anywhere but Keychain.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(
                name: .yptMenuBarAuthURL, object: nil, userInfo: ["url": url])
        }
    }
}

extension Notification.Name {
    static let yptMenuBarAuthURL = Notification.Name("YPTMenuBarAuthURL")
}
