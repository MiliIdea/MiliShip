import Foundation

/// In-memory tail of a build log for display. Mutate only on the main thread.
final class LiveLog: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    private(set) var buildID: UUID?

    private var nextID = 0
    private var partial = ""
    private let maxLines = 4000
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    func reset(for id: UUID?) {
        lines = []
        partial = ""
        buildID = id
    }

    func appendIfCurrent(_ chunk: String, buildID id: UUID) {
        guard buildID == id else { return }
        append(chunk)
    }

    func load(fileURL: URL, for id: UUID) {
        reset(for: id)
        guard let data = try? Data(contentsOf: fileURL) else {
            append("No log file at \(fileURL.path)\n")
            return
        }
        append(String(decoding: data.suffix(1_500_000), as: UTF8.self))
        if !partial.isEmpty {
            lines.append(Line(id: nextID, text: partial))
            nextID += 1
            partial = ""
        }
    }

    func append(_ chunk: String) {
        let cleaned = Self.clean(partial + chunk)
        var parts = cleaned.components(separatedBy: "\n")
        partial = parts.removeLast()
        guard !parts.isEmpty else { return }

        var updated = lines
        for part in parts {
            // Progress bars rewrite the line with \r; keep what would be visible.
            let visible = part.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? ""
            updated.append(Line(id: nextID, text: visible))
            nextID += 1
        }
        if updated.count > maxLines { updated.removeFirst(updated.count - maxLines) }
        lines = updated
    }

    private static func clean(_ text: String) -> String {
        ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}

/// Writes the full log to disk (secrets masked) and delivers batched chunks to the main thread.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let handle: FileHandle?
    private let masks: [String]
    private let deliver: (String) -> Void
    private var timer: DispatchSourceTimer?

    init(fileURL: URL, masks: [String], deliver: @escaping (String) -> Void) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        self.masks = masks.filter { $0.count >= 6 }
        self.deliver = deliver

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    func write(_ text: String) {
        var safe = text
        for secret in masks { safe = safe.replacingOccurrences(of: secret, with: "••••••") }
        lock.lock()
        handle?.write(Data(safe.utf8))
        pending += safe
        lock.unlock()
    }

    func close() {
        timer?.cancel()
        timer = nil
        flush()
        lock.lock()
        try? handle?.close()
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let chunk = pending
        pending = ""
        lock.unlock()
        guard !chunk.isEmpty else { return }
        let deliver = self.deliver
        DispatchQueue.main.async { deliver(chunk) }
    }
}
