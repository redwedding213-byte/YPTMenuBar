import AppKit
import Combine
import Foundation

/// Pomodoro state machine + YPT sync. Timers this app starts follow
/// Pomodoro rules, and timers started elsewhere (official app, phone) are
/// mirrored with the same rules: their 50-min Pomodoro countdown, overtime
/// past it, and a local break when they end or pause in overtime.
@MainActor
final class PomodoroEngine: ObservableObject {
    enum Phase { case focus, breakTime }
    enum Mode { case idle, ownRunning, ownPaused, overtimeRunning, breakRunning, breakPaused, externalRunning }
    enum LoginState { case loggedOut, loggedIn, expired }

    static let focusDuration = 50 * 60
    static let breakDuration = 10 * 60
    private static let lastSubjectKey = "lastSubject"
    private static let subjectsKey = "subjects"
    private static let pollIntervalNs: UInt64 = 30 * 1_000_000_000
    private static let maxElapsed = 24 * 3600

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var phase: Phase = .focus
    @Published private(set) var remainingSeconds: Int = focusDuration
    @Published private(set) var overtimeSeconds: Int = 0
    @Published private(set) var externalElapsedSeconds: Int = 0
    @Published private(set) var externalRemainingSeconds: Int = focusDuration
    @Published private(set) var externalOvertimeSeconds: Int = 0
    @Published private(set) var externalPomoDoneNotified: Bool = false
    /// The account's real subject titles, from the day log's sbs (server order).
    @Published private(set) var subjects: [String] = []
    @Published private(set) var externalSubject: String?
    @Published private(set) var subject: String = "General"
    @Published private(set) var loginState: LoginState = .loggedOut
    @Published private(set) var statusMessage: String?

    private let api: YPTAPIClient
    private var token: String?
    private var endDate: Date?
    /// Start of the server timer this app currently has running, if any.
    private var serverStartedAtMs: Int?
    /// Most recent start this app made, kept so the 30s poll never mistakes
    /// our own just-stopped session (stop call still in flight) for an
    /// external one.
    private var lastOwnStartedAtMs: Int?
    /// Server stop that failed when a break started; End & reset / Log out retry it.
    private var pendingStopStartedAtMs: Int?
    private var externalStart: Date?
    private var externalStartedAtMs: Int?
    private var tickTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var authObserver: NSObjectProtocol?

    init(api: YPTAPIClient = YPTAPIClient()) {
        self.api = api
        self.token = KeychainStore.load()
        self.loginState = token == nil ? .loggedOut : .loggedIn
        self.subject = UserDefaults.standard.string(forKey: Self.lastSubjectKey) ?? "General"
        self.subjects = UserDefaults.standard.stringArray(forKey: Self.subjectsKey) ?? []
        startTick()
        authObserver = NotificationCenter.default.addObserver(
            forName: .yptMenuBarAuthURL, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { await self?.handleAuthURL(url) }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNs)
                await self?.pollDayLog()
            }
        }
        if loginState == .loggedIn {
            Task { await pollDayLog() }
        }
    }

    deinit {
        tickTimer?.invalidate()
        pollTask?.cancel()
        if let authObserver { NotificationCenter.default.removeObserver(authObserver) }
    }

    // MARK: - Menu text

    var menuBarText: String {
        switch mode {
        case .idle: formatCountdown(Self.focusDuration)
        case .ownRunning, .ownPaused: formatCountdown(remainingSeconds)
        case .overtimeRunning: "+\(formatCountdown(overtimeSeconds))"
        case .breakRunning, .breakPaused: formatCountdown(remainingSeconds)
        case .externalRunning: externalPomoDoneNotified ? "+\(formatCountdown(externalOvertimeSeconds))" : formatCountdown(externalRemainingSeconds)
        }
    }

    var phaseLine: String {
        switch mode {
        case .idle: "Ready — Focus 50:00"
        case .ownRunning: "Focus — \(formatCountdown(remainingSeconds)) left"
        case .ownPaused: "Focus paused — \(formatCountdown(remainingSeconds)) left"
        case .overtimeRunning: "Overtime +\(formatCountdown(overtimeSeconds)) — pause starts break"
        case .breakRunning: "Break — \(formatCountdown(remainingSeconds)) left"
        case .breakPaused: "Break paused — \(formatCountdown(remainingSeconds)) left"
        case .externalRunning: externalPomoDoneNotified ? "Overtime +\(formatCountdown(externalOvertimeSeconds)) — pause starts break" : "YPT timer — \(formatCountdown(externalRemainingSeconds)) left"
        }
    }

    /// Subjects for the menu picker: the account's real list once fetched,
    /// else a bootstrap list until the first fetch lands.
    var subjectOptions: [String] {
        subjects.isEmpty ? ["General", "Physics", "Chemistry", "Maths"] : subjects
    }

    var subjectLine: String {
        if mode == .externalRunning {
            return "Subject: \(externalSubject ?? "From YPT app")"
        }
        return "Subject: \(subject)"
    }

    var loginLine: String {
        switch loginState {
        case .loggedOut: "Not logged in"
        case .loggedIn: "Logged in"
        case .expired: "Session expired — log in again"
        }
    }

    var primaryLabel: String {
        switch mode {
        case .idle: "Start focus"
        case .ownRunning: "Pause"
        case .ownPaused: "Resume"
        case .overtimeRunning: "Pause"
        case .breakRunning: "Pause break"
        case .breakPaused: "Resume break"
        case .externalRunning: externalPomoDoneNotified ? "Pause" : "Stop YPT timer"
        }
    }

    var primaryEnabled: Bool {
        // Starting needs a session; every other action is local or a stop.
        if mode == .idle { return loginState == .loggedIn }
        return true
    }

    // MARK: - Menu actions

    func primaryAction() {
        switch mode {
        case .idle: startFocus()
        case .ownRunning: pauseOwn()
        case .ownPaused: resumeOwn()
        case .overtimeRunning: pauseOvertime()
        case .breakRunning: pauseBreak()
        case .breakPaused: resumeBreak()
        case .externalRunning: externalPomoDoneNotified ? pauseExternalOvertime() : stopExternal()
        }
    }

    /// Subject for the next focus. Only changeable from idle (the menu
    /// disables the picker otherwise) so a running session's subject
    /// never gets mislabelled.
    func setSubject(_ newSubject: String) {
        subject = newSubject
        UserDefaults.standard.set(newSubject, forKey: Self.lastSubjectKey)
    }

    func startFocus() {
        guard loginState == .loggedIn, let token else {
            statusMessage = "Log in first"
            return
        }
        // Notification permission is asked here, once, never mid-focus.
        NotificationManager.requestIfNeeded()
        UserDefaults.standard.set(subject, forKey: Self.lastSubjectKey)
        Task {
            do {
                try await api.start(token: token, subject: subject)
                let now = Date()
                let started = Int(now.timeIntervalSince1970 * 1000)
                serverStartedAtMs = started
                lastOwnStartedAtMs = started
                endDate = now.addingTimeInterval(TimeInterval(remainingSeconds))
                mode = .ownRunning
                statusMessage = nil
            } catch {
                handleError(error)
            }
        }
    }

    /// Pause stops the server timer too, so paused time is never logged as
    /// study. Resume starts a fresh server session from the frozen countdown.
    /// On stop failure the timer keeps running and the error is shown.
    func pauseOwn() {
        guard let token, let started = serverStartedAtMs else { return }
        Task {
            do {
                try await api.stop(token: token, startedAtMs: started)
                remainingSeconds = max(0, Int(endDate?.timeIntervalSinceNow ?? 0))
                serverStartedAtMs = nil
                endDate = nil
                mode = .ownPaused
            } catch {
                handleError(error)
            }
        }
    }

    func resumeOwn() {
        guard loginState == .loggedIn, let token else {
            statusMessage = "Log in first"
            return
        }
        Task {
            do {
                try await api.start(token: token, subject: subject)
                let now = Date()
                let started = Int(now.timeIntervalSince1970 * 1000)
                serverStartedAtMs = started
                lastOwnStartedAtMs = started
                endDate = now.addingTimeInterval(TimeInterval(remainingSeconds))
                mode = .ownRunning
                statusMessage = nil
            } catch {
                handleError(error)
            }
        }
    }

    /// Pause during overtime: stops the study session (50 min + overtime)
    /// and starts the local 10-minute break.
    func pauseOvertime() {
        let started = serverStartedAtMs
        let tokenSnapshot = token
        serverStartedAtMs = nil
        phase = .breakTime
        remainingSeconds = Self.breakDuration
        endDate = Date().addingTimeInterval(TimeInterval(Self.breakDuration))
        mode = .breakRunning
        statusMessage = nil
        if let started, let tokenSnapshot {
            Task {
                do {
                    try await api.stop(token: tokenSnapshot, startedAtMs: started)
                } catch {
                    self.pendingStopStartedAtMs = started
                    self.statusMessage = "Break started, but the study timer did not stop — tap End & reset."
                }
            }
        }
    }

    func pauseBreak() {
        remainingSeconds = max(0, Int(endDate?.timeIntervalSinceNow ?? 0))
        endDate = nil
        mode = .breakPaused
    }

    func resumeBreak() {
        endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        mode = .breakRunning
    }

    /// Manual break from idle: local-only countdown, no YPT session.
    func startBreak() {
        phase = .breakTime
        remainingSeconds = Self.breakDuration
        endDate = Date().addingTimeInterval(TimeInterval(Self.breakDuration))
        mode = .breakRunning
        statusMessage = nil
    }

    func skipBreak() {
        mode = .idle
        phase = .focus
        remainingSeconds = Self.focusDuration
        endDate = nil
        statusMessage = nil
    }

    /// Stops whichever server timer is live (own, pending, or external),
    /// best effort, then returns to the Focus ready state.
    func endAndReset() {
        let started = serverStartedAtMs
        let pending = pendingStopStartedAtMs
        let ext = externalStartedAtMs
        let tokenSnapshot = token
        serverStartedAtMs = nil
        pendingStopStartedAtMs = nil
        externalStartedAtMs = nil
        externalStart = nil
        externalSubject = nil
        externalElapsedSeconds = 0
        externalRemainingSeconds = 0
        externalOvertimeSeconds = 0
        externalPomoDoneNotified = false
        mode = .idle
        phase = .focus
        remainingSeconds = Self.focusDuration
        overtimeSeconds = 0
        endDate = nil
        statusMessage = nil
        if let tokenSnapshot {
            stopServerTimers(token: tokenSnapshot, started: started, pending: pending, external: ext)
        }
    }

    func stopExternal() {
        let started = externalStartedAtMs
        let tokenSnapshot = token
        externalStartedAtMs = nil
        externalStart = nil
        externalSubject = nil
        externalElapsedSeconds = 0
        externalRemainingSeconds = 0
        externalOvertimeSeconds = 0
        externalPomoDoneNotified = false
        mode = .idle
        phase = .focus
        remainingSeconds = Self.focusDuration
        endDate = nil
        // On stop failure the poll re-adopts the still-live session within
        // 30s, so the timer reappears instead of silently vanishing.
        if let started, let tokenSnapshot {
            Task {
                do {
                    try await api.stop(token: tokenSnapshot, startedAtMs: started)
                    statusMessage = nil
                } catch {
                    handleError(error)
                }
            }
        }
    }

    /// Pause during external overtime: stops the YPT session and starts
    /// the local 10-minute break.
    func pauseExternalOvertime() {
        let started = externalStartedAtMs
        let tokenSnapshot = token
        externalStartedAtMs = nil
        externalStart = nil
        externalSubject = nil
        externalElapsedSeconds = 0
        externalRemainingSeconds = 0
        externalOvertimeSeconds = 0
        externalPomoDoneNotified = false
        phase = .breakTime
        remainingSeconds = Self.breakDuration
        endDate = Date().addingTimeInterval(TimeInterval(Self.breakDuration))
        mode = .breakRunning
        statusMessage = nil
        if let started, let tokenSnapshot {
            Task {
                do {
                    try await api.stop(token: tokenSnapshot, startedAtMs: started)
                } catch {
                    self.pendingStopStartedAtMs = started
                    self.statusMessage = "Break started, but the study timer did not stop — tap End & reset."
                }
            }
        }
    }

    func loginViaBrowser() {
        if let url = URL(string: "https://wannabeypt.vercel.app/google-login.html?mode=app") {
            NSWorkspace.shared.open(url)
        }
    }

    func logout() {
        let started = serverStartedAtMs
        let pending = pendingStopStartedAtMs
        let ext = externalStartedAtMs
        let tokenSnapshot = token
        serverStartedAtMs = nil
        pendingStopStartedAtMs = nil
        externalStartedAtMs = nil
        externalStart = nil
        externalSubject = nil
        token = nil
        loginState = .loggedOut
        externalElapsedSeconds = 0
        externalRemainingSeconds = 0
        externalOvertimeSeconds = 0
        externalPomoDoneNotified = false
        mode = .idle
        phase = .focus
        remainingSeconds = Self.focusDuration
        overtimeSeconds = 0
        endDate = nil
        statusMessage = nil
        KeychainStore.delete()
        if let tokenSnapshot {
            stopServerTimers(token: tokenSnapshot, started: started, pending: pending, external: ext)
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Browser login handoff (yptmenu://auth?token=...)

    /// Saves the session to Keychain and marks the app logged in.
    /// The token is never logged or printed anywhere in this path.
    private func handleAuthURL(_ url: URL) {
        guard url.scheme == "yptmenu" else { return }
        guard let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value,
            !token.isEmpty else {
            statusMessage = "Login did not return a session"
            return
        }
        if KeychainStore.save(token: token) {
            self.token = token
            loginState = .loggedIn
            statusMessage = "Logged in"
            Task { await pollDayLog() }
        } else {
            statusMessage = "Could not save login — try again"
        }
    }

    // MARK: - Tick + phase ends

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
    }

    private func tick() {
        switch mode {
        case .ownRunning, .breakRunning:
            guard let end = endDate else { return }
            remainingSeconds = max(0, Int(end.timeIntervalSinceNow))
            if remainingSeconds == 0 {
                if mode == .ownRunning { focusCompleted() } else { breakEnded() }
            }
        case .overtimeRunning:
            if let end = endDate {
                overtimeSeconds = max(0, Int(Date().timeIntervalSince(end)))
            }
        case .externalRunning:
            if let start = externalStart {
                externalElapsedSeconds = min(Int(Date().timeIntervalSince(start)), Self.maxElapsed)
                // Two-way Pomodoro: a YPT-app Pomodoro runs 50 min from the
                // session start. Show its countdown, then overtime.
                let deadline = start.addingTimeInterval(TimeInterval(Self.focusDuration))
                if Date() >= deadline {
                    externalRemainingSeconds = 0
                    externalOvertimeSeconds = max(0, Int(Date().timeIntervalSince(deadline)))
                    if !externalPomoDoneNotified {
                        externalPomoDoneNotified = true
                        playPhaseSound()
                        NotificationManager.phaseEnded(title: "50-minute session complete", body: "Keep going or pause to start your break.")
                        statusMessage = "50 min done — overtime running"
                    }
                } else {
                    externalRemainingSeconds = max(0, Int(deadline.timeIntervalSinceNow))
                    externalOvertimeSeconds = 0
                }
            }
        default:
            break
        }
    }

    /// The 50 minutes are done: notify, then keep counting up with a +
    /// sign. The study session keeps running (overtime is still study);
    /// it stops when he pauses (break starts) or ends/resets.
    private func focusCompleted() {
        mode = .overtimeRunning
        overtimeSeconds = 0
        playPhaseSound()
        NotificationManager.phaseEnded(title: "50-minute session complete", body: "Keep going or pause to start your break.")
        statusMessage = "50 min done — overtime running"
    }

    private func breakEnded() {
        mode = .idle
        phase = .focus
        remainingSeconds = Self.focusDuration
        endDate = nil
        playPhaseSound()
        NotificationManager.phaseEnded(title: "Break over", body: "Ready for the next focus.")
        statusMessage = "Break over — press Start for focus"
    }

    // MARK: - Two-way reflection (30s day-log poll)

    /// Adopts timers started elsewhere, but only from the idle state:
    /// a paused timer is the user's explicit state and is never hijacked,
    /// and an own running timer is never re-adopted as external.
    private func pollDayLog() async {
        guard loginState == .loggedIn, let token else { return }
        guard mode == .idle || mode == .externalRunning else { return }
        do {
            let day = try await api.dayLog(token: token, date: todayString())
            if !day.subjectTitles.isEmpty {
                subjects = day.subjectTitles
                UserDefaults.standard.set(day.subjectTitles, forKey: Self.subjectsKey)
                if !day.subjectTitles.contains(subject) {
                    subject = day.subjectTitles[0]
                    UserDefaults.standard.set(subject, forKey: Self.lastSubjectKey)
                }
            }
            guard let live = day.liveSession else {
                if mode == .externalRunning {
                    // Stopped elsewhere: back to ready, unless the Pomodoro
                    // already ended — then the break starts, as asked.
                    let wasPastDeadline = externalPomoDoneNotified
                    externalStartedAtMs = nil
                    externalStart = nil
                    externalSubject = nil
                    externalElapsedSeconds = 0
                    externalRemainingSeconds = 0
                    externalOvertimeSeconds = 0
                    externalPomoDoneNotified = false
                    if wasPastDeadline {
                        phase = .breakTime
                        remainingSeconds = Self.breakDuration
                        endDate = Date().addingTimeInterval(TimeInterval(Self.breakDuration))
                        mode = .breakRunning
                        statusMessage = "Break started"
                    } else {
                        mode = .idle
                        phase = .focus
                        remainingSeconds = Self.focusDuration
                    }
                }
                return
            }
            // Never adopt our own session (a stop call may still be in flight).
            if live.startedAtMs == serverStartedAtMs || live.startedAtMs == lastOwnStartedAtMs { return }
            if mode == .externalRunning, live.startedAtMs == externalStartedAtMs {
                externalSubject = live.subject // refresh the label only
                return
            }
            externalStartedAtMs = live.startedAtMs
            externalStart = live.start
            externalSubject = live.subject
            externalElapsedSeconds = min(Int(Date().timeIntervalSince(live.start)), Self.maxElapsed)
            mode = .externalRunning
            // Two-way Pomodoro: seed the countdown (or overtime, if the
            // deadline already passed — no stale notification then).
            NotificationManager.requestIfNeeded()
            let deadline = live.start.addingTimeInterval(TimeInterval(Self.focusDuration))
            if Date() >= deadline {
                externalPomoDoneNotified = true
                externalRemainingSeconds = 0
                externalOvertimeSeconds = max(0, Int(Date().timeIntervalSince(deadline)))
            } else {
                externalPomoDoneNotified = false
                externalRemainingSeconds = max(0, Int(deadline.timeIntervalSinceNow))
                externalOvertimeSeconds = 0
            }
        } catch {
            if case YPTError.unauthorized = error {
                loginState = .expired
                statusMessage = "Session expired — log in again"
            }
            // Other poll failures stay silent; the next poll retries in 30s.
        }
    }

    // MARK: - Helpers

    private func stopServerTimers(token: String, started: Int?, pending: Int?, external: Int?) {
        if let started { Task { try? await api.stop(token: token, startedAtMs: started) } }
        if let pending, pending != started { Task { try? await api.stop(token: token, startedAtMs: pending) } }
        if let external, external != started, external != pending {
            Task { try? await api.stop(token: token, startedAtMs: external) }
        }
    }

    private func handleError(_ error: Error) {
        if case YPTError.unauthorized = error {
            loginState = .expired
            statusMessage = "Session expired — log in again"
        } else if let e = error as? YPTError {
            statusMessage = e.localizedDescription
        } else {
            statusMessage = "Something went wrong"
        }
    }

    private func playPhaseSound() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    /// Local date in the same yyyy-MM-dd format the web client passes to
    /// dayLogRaw/dayLogSubjects.
    private func todayString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func formatCountdown(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let capped = min(seconds, Self.maxElapsed)
        if capped >= 3600 {
            return String(format: "%d:%02d:%02d", capped / 3600, (capped % 3600) / 60, capped % 60)
        }
        return String(format: "%02d:%02d", capped / 60, capped % 60)
    }
}
