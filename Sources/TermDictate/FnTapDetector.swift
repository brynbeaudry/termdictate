import AppKit
import ApplicationServices
import CoreGraphics

/// Watches for the same fn-fn double-tap gesture macOS's own Dictation uses,
/// but only acts on it while Terminal is frontmost — where native Dictation
/// starts an audio session and then has nowhere to put the result. When that
/// happens we swallow the second tap so the system's own (broken, in Terminal)
/// attempt never fires, and call `onDoubleTap` instead.
final class FnTapDetector {
    static let terminalBundleID = "com.apple.Terminal"
    private static let doubleTapThreshold: CFAbsoluteTime = 0.4

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var fnCurrentlyDown = false
    private var lastFnDownTime: CFAbsoluteTime?
    private var pendingSwallowRelease = false

    var onDoubleTap: (() -> Void)?
    var isRunning: Bool { eventTap != nil }

    func ensureAccessibilityTrust() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let detector = Unmanaged<FnTapDetector>.fromOpaque(refcon).takeUnretainedValue()
                return detector.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func isTerminalFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.terminalBundleID
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            // A real keystroke while fn is down means fn is being used as a
            // modifier (e.g. fn+Delete), not tapped alone; don't count it.
            lastFnDownTime = nil
            return Unmanaged.passRetained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        let fnDown = event.flags.contains(.maskSecondaryFn)

        if pendingSwallowRelease {
            pendingSwallowRelease = false
            fnCurrentlyDown = fnDown
            return nil
        }

        if fnDown && !fnCurrentlyDown {
            fnCurrentlyDown = true
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastFnDownTime, now - last < Self.doubleTapThreshold, isTerminalFrontmost() {
                lastFnDownTime = nil
                pendingSwallowRelease = true
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
                return nil
            }
            lastFnDownTime = now
            return Unmanaged.passRetained(event)
        }

        if !fnDown && fnCurrentlyDown {
            fnCurrentlyDown = false
            return Unmanaged.passRetained(event)
        }

        return Unmanaged.passRetained(event)
    }
}
