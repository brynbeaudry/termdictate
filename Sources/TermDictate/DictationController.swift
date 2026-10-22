import AVFoundation
import Speech

/// Streams speech recognition and types the growing transcript into Terminal.
/// Already-finalized utterances are locked and never revised again, but the
/// current in-flight one can still self-correct live as recognition refines
/// its guess — the same model Apple's own Dictation uses.
///
/// SFSpeechRecognizer finalizes its recognition task after a pause in speech
/// — it's built for one utterance, not open-ended dictation — so a
/// finalized/errored task is silently replaced with a fresh one while the
/// audio engine keeps running, giving the illusion of one continuous session.
/// A new task's first words are checked against the tail of the committed
/// text to drop any echoed words the recognizer re-hears across that seam.
///
/// Cursor position is read via `TerminalAX` only at safe checkpoints (session
/// start, and each new utterance after a pause) to decide whether a leading
/// space is needed — never re-read right after we've just posted synthetic
/// keystrokes. Accessibility IPC (reading/setting the cursor) and HID
/// keystroke injection are two independent pathways into Terminal that don't
/// synchronize with each other; trying to reposition the cursor via AX
/// immediately before typing doesn't reliably redirect where the keystrokes
/// land, so dictated text always lands wherever the keystroke stream is
/// already at, not at an arbitrarily repositioned cursor.
///
/// A session has two independent pieces of state: `enabled` is the user's
/// intent, toggled by the gesture, and `active` is whether the mic and
/// recognizer are actually running. They diverge whenever Terminal stops
/// being frontmost — the session is suspended, releasing the audio input so
/// the system's own Dictation can use it, and it resumes on return. Without
/// that, both the mic and the synthetic-keystroke stream follow focus into
/// whatever app the user switched to.
final class DictationController {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var active = false
    private var enabled = false

    /// Dedupe reference only: normalized text of past utterances this session.
    private var committedText = ""
    /// The current utterance's live, still-revisable raw transcript.
    private var livePartialText = ""
    /// What's actually been typed into Terminal for the current utterance.
    private var typedForTask = ""
    /// Whether the next utterance's first inserted character needs a leading
    /// space. Established once per utterance from a real cursor read at a
    /// safe checkpoint, then advanced purely by computation from here on.
    private var needsLeadingSpace = false
    /// Logging only: tracks whether injection is currently being dropped, so a
    /// suppression episode logs one line instead of one per partial result.
    private var suppressingInjection = false

    var onStateChange: ((Bool, Bool) -> Void)?
    var isRunning: Bool { active }
    var isEnabled: Bool { enabled }

    func requestPermissions(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    completion(speechStatus == .authorized && micGranted)
                }
            }
        }
    }

    func start() {
        log.info("gesture: start requested")
        enabled = true
        beginSession()
    }

    func stop() {
        log.info("gesture: stop requested")
        enabled = false
        endSession()
    }

    /// Releases the mic and the keystroke stream while Terminal isn't
    /// frontmost, leaving the user's intent intact so `resume()` can pick the
    /// session back up.
    func suspend() {
        guard enabled, active else {
            log.info("suspend: no-op (enabled=\(enabled) active=\(active))")
            return
        }
        log.info("suspend: releasing mic")
        endSession()
    }

    func resume() {
        guard enabled, !active else {
            log.info("resume: no-op (enabled=\(enabled) active=\(active))")
            return
        }
        log.info("resume: reclaiming mic")
        beginSession()
    }

    private func beginSession() {
        guard !active, let recognizer = recognizer, recognizer.isAvailable else {
            log.error("beginSession: refused (active=\(active) recognizerAvailable=\(recognizer?.isAvailable ?? false))")
            return
        }
        active = true
        suppressingInjection = false
        committedText = ""
        needsLeadingSpace = TerminalAX.characterBeforeCursor().map { !$0.isWhitespace } ?? false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            FileHandle.standardError.write("TermDictate: failed to start audio engine: \(error)\n".data(using: .utf8)!)
            active = false
            audioEngine.inputNode.removeTap(onBus: 0)
            log.error("audio engine failed to start: \(error.localizedDescription)")
            onStateChange?(false, enabled)
            return
        }

        log.info("session active: mic open")
        onStateChange?(true, enabled)
        beginRecognitionTask(recognizer: recognizer)
    }

    private func endSession() {
        guard active else {
            onStateChange?(false, enabled)
            return
        }
        active = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        livePartialText = ""
        typedForTask = ""
        log.info("session inactive: mic released (still enabled=\(enabled))")
        onStateChange?(false, enabled)
    }

    private func beginRecognitionTask(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        livePartialText = ""
        typedForTask = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.active else { return }

            if let result = result {
                let newText = result.bestTranscription.formattedString
                // The recognizer can quietly shrink its transcript back to just
                // the newest phrase after a gap in speech, without ever firing
                // isFinal. Lock in whatever was there before that happens.
                if newText.count < self.livePartialText.count {
                    self.commitCurrentUtterance()
                }
                self.livePartialText = newText
                self.applyCorrection(target: self.decorated(self.normalizedPunctuationSpacing(newText)))
            }

            if result?.isFinal == true || error != nil {
                self.commitCurrentUtterance()
                DispatchQueue.main.async {
                    guard self.active else { return }
                    self.beginRecognitionTask(recognizer: recognizer)
                }
            }
        }
    }

    private func commitCurrentUtterance() {
        let trimmed = decorated(normalizedPunctuationSpacing(dedupeAgainstCommitted(livePartialText)))
        applyCorrection(target: trimmed)
        if !trimmed.isEmpty {
            committedText = joined(committedText, trimmed)
        }
        // Advance purely from what we know we just typed — never re-read the
        // cursor here, since the keystrokes for `trimmed` may not have been
        // processed by Terminal yet.
        if let last = typedForTask.last {
            needsLeadingSpace = !last.isWhitespace
        }
        livePartialText = ""
        typedForTask = ""
    }

    private func decorated(_ text: String) -> String {
        (needsLeadingSpace && !text.isEmpty) ? " " + text : text
    }

    /// Reconciles Terminal's visible text for the current utterance to match
    /// `target`, using plain backspace/type — the cursor is trusted to
    /// already sit wherever our own last correction left it.
    private func applyCorrection(target: String) {
        guard target != typedForTask else { return }
        // Recognition callbacks arrive off the main queue and can land in the
        // gap between focus leaving Terminal and `suspend()` running, so the
        // frontmost check is repeated here rather than trusted from `active`.
        guard TerminalAX.isFrontmost() else {
            if !suppressingInjection {
                suppressingInjection = true
                log.error("injection dropped: Terminal not frontmost while session still active")
            }
            return
        }
        if suppressingInjection {
            suppressingInjection = false
            log.info("injection resumed: Terminal frontmost again")
        }

        let commonPrefixCount = zip(typedForTask, target).prefix { $0 == $1 }.count
        let deleteCount = typedForTask.count - commonPrefixCount
        let insertion = String(target.dropFirst(commonPrefixCount))

        TextInjector.backspace(count: deleteCount)
        TextInjector.typeUnicode(insertion)
        typedForTask = target
    }

    /// The recognizer inconsistently inserts a space before spoken
    /// punctuation ("period", "colon", ...); collapse "word ." into "word.".
    private func normalizedPunctuationSpacing(_ text: String) -> String {
        var result = text
        for mark in [".", ",", ":", ";", "!", "?"] {
            result = result.replacingOccurrences(of: " \(mark)", with: mark)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    private func joined(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        return (a.last?.isWhitespace == true) ? a + b : a + " " + b
    }

    /// Drops any leading words of a new utterance that echo the tail of what's
    /// already committed, since the recognizer sometimes re-hears a little
    /// trailing audio right at a task-restart boundary.
    private func dedupeAgainstCommitted(_ text: String) -> String {
        let priorTokens = committedText.split(separator: " ")
        let nextTokens = text.split(separator: " ")
        let maxOverlap = min(priorTokens.count, nextTokens.count, 8)

        func normalized(_ token: Substring) -> String {
            token.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        for k in stride(from: maxOverlap, through: 1, by: -1) {
            if priorTokens.suffix(k).map(normalized) == nextTokens.prefix(k).map(normalized) {
                return nextTokens.dropFirst(k).joined(separator: " ")
            }
        }
        return text
    }
}
