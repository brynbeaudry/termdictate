import AppKit
import ApplicationServices

/// Reads Terminal.app's focused text area via the Accessibility API.
/// Confirmed empirically: Terminal's AXTextArea exposes a readable AXValue
/// (full buffer text) and a readable AXSelectedTextRange (cursor position as
/// a CFRange), unlike the NSTextInputClient protocol dictation relies on,
/// which terminals don't implement at all.
///
/// This is read-only. Accessibility IPC and HID keystroke injection are two
/// independent pathways into Terminal that don't synchronize with each
/// other — setting the cursor via AX right before posting synthetic
/// keystrokes doesn't reliably redirect where those keystrokes land, so
/// there's no `setCursorOffset` here; only safe-checkpoint reads.
enum TerminalAX {
    static let bundleID = "com.apple.Terminal"

    static func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    private static func focusedTextArea() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleID else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    private static func currentCursorOffset(in element: AXUIElement) -> Int? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let axValue = rangeRef else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &cfRange) else { return nil }
        return cfRange.location
    }

    /// The character immediately before the cursor, or nil if unknown/at the
    /// start of the buffer.
    static func characterBeforeCursor() -> Character? {
        guard let element = focusedTextArea() else { return nil }
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String else { return nil }
        guard let offset = currentCursorOffset(in: element) else { return nil }
        let chars = Array(fullText)
        guard offset > 0, offset <= chars.count else { return nil }
        return chars[offset - 1]
    }
}
