import AppKit
import ApplicationServices
import CoreGraphics

/// Watches for the right-Command double-tap gesture macOS's own Dictation is
/// configured to use, but only acts on it while Terminal is frontmost — where
/// native Dictation starts an audio session and then has nowhere to put the
/// result. When that happens we swallow the second tap so the system's own
/// (broken, in Terminal) attempt never fires, and call `onDoubleTap` instead.
final class RightCommandTapDetector {
    static let terminalBundleID = "com.apple.Terminal"
    private static let doubleTapThreshold: CFAbsoluteTime = 0.4
    private static let rightCommandKeyCode: Int64 = 54
    private static let rightCommandDeviceFlag: UInt64 = 0x10

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var rightCommandCurrentlyDown = false
    private var lastRightCommandDownTime: CFAbsoluteTime?
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
                let detector = Unmanaged<RightCommandTapDetector>.fromOpaque(refcon).takeUnretainedValue()
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
            // A real keystroke while Command is down means it's being used as a
            // modifier (e.g. Cmd+C), not tapped alone; don't count it.
            lastRightCommandDownTime = nil
            return Unmanaged.passRetained(event)
        }

        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightCommandKeyCode else {
            return Unmanaged.passRetained(event)
        }

        let rightCommandDown = event.flags.rawValue & Self.rightCommandDeviceFlag != 0

        if pendingSwallowRelease {
            pendingSwallowRelease = false
            rightCommandCurrentlyDown = rightCommandDown
            return nil
        }

        if rightCommandDown && !rightCommandCurrentlyDown {
            rightCommandCurrentlyDown = true
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastRightCommandDownTime, now - last < Self.doubleTapThreshold, isTerminalFrontmost() {
                lastRightCommandDownTime = nil
                pendingSwallowRelease = true
                DispatchQueue.main.async { [weak self] in self?.onDoubleTap?() }
                return nil
            }
            lastRightCommandDownTime = now
            return Unmanaged.passRetained(event)
        }

        if !rightCommandDown && rightCommandCurrentlyDown {
            rightCommandCurrentlyDown = false
        }

        return Unmanaged.passRetained(event)
    }
}
