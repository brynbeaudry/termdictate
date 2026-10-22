import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let detector = RightCommandTapDetector()
    private let dictation = DictationController()
    private var statusItem: NSStatusItem?
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        waitForAccessibility()
    }

    private func waitForAccessibility() {
        if detector.ensureAccessibilityTrust() {
            waitForMicAndSpeech()
            return
        }

        statusItem?.button?.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "TermDictate needs Accessibility access")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)

        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.detector.isAccessibilityTrusted() {
                timer.invalidate()
                self.waitForMicAndSpeech()
            }
        }
    }

    private func waitForMicAndSpeech() {
        dictation.requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "TermDictate needs Microphone/Speech access")
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)

                self.permissionPollTimer?.invalidate()
                self.permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    self.dictation.requestPermissions { granted in
                        if granted {
                            timer.invalidate()
                            self.startListening()
                        }
                    }
                }
                return
            }
            self.startListening()
        }
    }

    private func startListening() {
        guard !detector.isRunning else { return }

        dictation.onStateChange = { [weak self] listening, armed in
            self?.updateStatusIcon(listening: listening, armed: armed)
        }

        detector.onDoubleTap = { [weak self] in
            guard let self else { return }
            if self.dictation.isEnabled {
                self.dictation.stop()
            } else {
                self.dictation.start()
            }
        }

        observeFrontmostApp()

        guard detector.start() else {
            statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "TermDictate failed to start")
            return
        }
        updateStatusIcon(listening: false, armed: false)
    }

    /// A running session follows Terminal's focus: leaving Terminal releases
    /// the mic so the system's own Dictation can claim it in the app the user
    /// switched to, and returning picks the session back up.
    private func observeFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            log.info("frontmost -> \(app?.bundleIdentifier ?? "unknown")")
            if app?.bundleIdentifier == TerminalAX.bundleID {
                self.dictation.resume()
            } else {
                self.dictation.suspend()
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "TermDictate idle")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "TermDictate — right ⌘ twice in Terminal", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func updateStatusIcon(listening: Bool, armed: Bool) {
        let symbol: String
        let description: String
        switch (listening, armed) {
        case (true, _):
            symbol = "mic.fill"
            description = "TermDictate listening"
        case (false, true):
            symbol = "mic.circle"
            description = "TermDictate paused — mic released until Terminal is frontmost"
        case (false, false):
            symbol = "mic"
            description = "TermDictate idle"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
