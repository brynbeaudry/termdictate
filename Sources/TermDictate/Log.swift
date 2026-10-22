import Foundation

/// Appends to `~/Library/Logs/TermDictate.log`. The unified log would be the
/// natural home for this, but `log stream` requires admin rights, so a plain
/// file keeps the trace readable by whoever is running the app.
struct FileLog {
    static let shared = FileLog()

    private let url: URL
    private let queue = DispatchQueue(label: "com.brynbeaudry.termdictate.log")

    private init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("TermDictate.log")
    }

    func info(_ message: String) { write("INFO ", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let timestamp = Date()
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let line = "\(formatter.string(from: timestamp)) \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.url)
            }
        }
    }
}

let log = FileLog.shared
