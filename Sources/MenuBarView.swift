import SwiftUI

/// Menu content for the MenuBarExtra scene: status lines, actions, login, quit.
/// No token or credential is ever shown here.
struct MenuBarView: View {
    @ObservedObject var engine: PomodoroEngine

    var body: some View {
        Text(engine.phaseLine)
        Text(engine.subjectLine)
        Text(engine.loginLine)
        if let status = engine.statusMessage {
            Text(status)
        }
        Divider()
        Menu("Subject") {
            ForEach(engine.subjectOptions, id: \.self) { subject in
                Button("\(engine.subject == subject ? "✓ " : "")\(subject)") {
                    engine.setSubject(subject)
                }
            }
        }
        .disabled(engine.mode != .idle)
        Button(engine.primaryLabel) { engine.primaryAction() }
            .disabled(!engine.primaryEnabled)
        if engine.mode == .idle {
            Button("Start break") { engine.startBreak() }
        }
        if engine.mode == .breakRunning || engine.mode == .breakPaused {
            Button("Skip break") { engine.skipBreak() }
        }
        Button("End & reset") { engine.endAndReset() }
            .disabled(engine.mode == .idle)
        Divider()
        if engine.loginState == .loggedIn {
            Button("Log out") { engine.logout() }
        } else {
            Button("Login via browser") { engine.loginViaBrowser() }
        }
        Button("Quit") { engine.quit() }
    }
}
