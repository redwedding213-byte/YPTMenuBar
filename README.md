# YPT Menu Bar

A native macOS menu bar Pomodoro timer synced with your YPT account, so focus time started from the menu bar appears in the official YPT app, and timers started in the YPT app are mirrored in the menu bar.

Menu bar shows the countdown next to the clock. Focus is 50 minutes, break is 10 minutes. Focus time is logged to YPT. Break time is not.

## What it does

- Focus 50, Break 10, with overtime counting up past 50 minutes. Pausing in overtime stops the study session and starts the local 10 minute break.
- Two way sync with the YPT server: `POST /study/start`, `POST /study/stop`, and a 30 second poll of `GET /logs/day`.
- Timers started elsewhere, in the official app or on your phone, are mirrored ticking in the menu bar with their subject, and follow the same 50 minute Pomodoro countdown and overtime rules.
- Subject picker, using your real subject list from the YPT server, with General, Physics, Chemistry, and Maths as the fallback list. The picker is idle only, so a running session never gets mislabelled.
- Pause during focus stops the server timer, so paused time is never logged as study. Resume starts a fresh server session from the frozen countdown.
- Start break from idle is local only, no YPT session.
- Phase end sound plus macOS notification.
- Menu shows phase, time left, subject, and login state, with Start, Pause, End and reset, Log out, and Quit.

## Login

- Menu, Login via browser, opens `https://wannabeypt.vercel.app/google-login.html?mode=app` in your default browser.
- Sign in with Google there, exactly like the wannabeYPT web client.
- The helper redirects back to `yptmenu://auth?token=...`. The app extracts the token and saves it to the macOS Keychain only.
- There is no box to paste or type a token, and no password is ever asked for. The token lives only in Keychain and in the `authorization` header. It is never printed, logged, or shown in the menu.
- Log out deletes the Keychain entry and best effort stops any live timer.

## Build it

You need a Mac with Xcode installed, macOS 13 or later.

1. Xcode, File, New, Project, macOS, App.
2. Product Name: `YPTMenuBar`. Interface: SwiftUI. Language: Swift. Uncheck Include Tests.
3. Delete the generated `ContentView.swift`. This app has no window.
4. Replace the generated app file with `Sources/MyApp.swift`, and add the other files from `Sources/`. Drag the `Sources` folder into the project, tick Copy items if needed, and tick the YPTMenuBar target.
5. Target, General, Deployment Target, macOS 13.0 or later.
6. URL scheme for the login handoff. Target, Info, URL Types, add Identifier `YPT Menu Bar Auth`, URL Schemes `yptmenu`. Or use the provided `Info.plist`, which already contains it.
7. Menu bar only: add `Application is agent (UIElement)` = YES. The provided `Info.plist` already sets `LSUIElement`. No Dock icon, no window. Quit lives in the menu.
8. Signing: the default team is fine for running on your own Mac.
9. Product, Run. The menu bar should show the focus countdown.

## Files

- `Sources/MyApp.swift`, app entry, MenuBarExtra, URL scheme delegate.
- `Sources/PomodoroEngine.swift`, Pomodoro state machine, ticking, polling, overtime, external timer mirroring.
- `Sources/MenuBarView.swift`, menu content.
- `Sources/YPTAPIClient.swift`, start, stop, and day log calls, 15 second timeout.
- `Sources/DayLog.swift`, day log parsing, live session rule, subject lookup.
- `Sources/KeychainStore.swift`, JWT in Keychain via SecItem APIs.
- `Sources/NotificationManager.swift`, phase end notifications.
- `Info.plist`, bundle id `com.yptmenu.app`, LSUIElement, `yptmenu` URL scheme.

## Windows port wanted

There is no Windows version yet. A Windows port would be a system tray app with the same behavior: Focus 50, Break 10, overtime, subject picker, Pause, End and reset, login via the same browser helper, token stored in Windows Credential Manager instead of Keychain, and the same YPT start and stop calls. If you build it, open a pull request.

## Note

This uses the unofficial YPT API at `pi.tgclab.com`, the same API the wannabeYPT web client uses. It is not an official YPT app.
