import CoreGraphics

/// Types text into whatever app currently has keyboard focus by posting
/// synthetic key events — the only way text reaches a terminal's pty, since
/// terminals don't implement the NSTextInputClient protocol dictation relies on.
struct TextInjector {
    private static let backspaceKeyCode: CGKeyCode = 0x33

    static func typeUnicode(_ string: String) {
        guard !string.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        var chars = Array(string.utf16)
        chars.withUnsafeMutableBufferPointer { buffer in
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            down.post(tap: .cgSessionEventTap)

            guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.post(tap: .cgSessionEventTap)
        }
    }

    static func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: true)?.post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: false)?.post(tap: .cgSessionEventTap)
        }
    }
}
