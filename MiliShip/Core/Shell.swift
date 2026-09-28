import Foundation

/// Single-quotes a value for safe use in a zsh command line.
func shq(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct CommandFailure: LocalizedError {
    let command: String
    let status: Int32
    let tail: String

    var errorDescription: String? {
        let first = command.split(separator: "\n").first.map { String($0) } ?? command
        return "Command failed (exit \(status)): \(first)"
    }
}

func describe(_ error: Error) -> String {
    if let failure = error as? CommandFailure {
        let tail = failure.tail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(8)
            .joined(separator: "\n")
        return "\(failure.errorDescription ?? "Command failed")\n\(tail)"
    }
    if error is CancellationError { return "Cancelled" }
    return error.localizedDescription
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let limit = 1_000_000

    func append(_ text: String) {
        lock.lock()
        buffer += text
        if buffer.utf8.count > limit { buffer = String(buffer.suffix(limit / 2)) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Runs commands through a zsh login shell (so Homebrew, rbenv, fvm… resolve),
/// streams output, and kills the whole process tree on cancel.
final class ShellRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    func run(
        _ command: String,
        cwd: URL,
        env: [String: String],
        interactive: Bool = false,
        log: @escaping (String) -> Void
    ) async throws -> String {
        if isCancelled { throw CancellationError() }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [interactive ? "-ilc" : "-lc", command]
            process.currentDirectoryURL = cwd
            process.environment = env
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let output = OutputCollector()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                output.append(text)
                log(text)
            }

            process.terminationHandler = { [weak self] finished in
                // Let the reader drain the pipe; don't wait for EOF (daemons may keep it open).
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self?.clearCurrent(finished)
                    if self?.isCancelled == true {
                        continuation.resume(throwing: CancellationError())
                    } else if finished.terminationStatus == 0 {
                        continuation.resume(returning: output.text)
                    } else {
                        continuation.resume(throwing: CommandFailure(
                            command: command,
                            status: finished.terminationStatus,
                            tail: String(output.text.suffix(4000))
                        ))
                    }
                }
            }

            lock.lock()
            current = process
            lock.unlock()

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                clearCurrent(process)
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = current
        lock.unlock()

        guard let process, process.isRunning else { return }
        let root = process.processIdentifier
        let tree = [root] + Self.descendants(of: root)
        for pid in tree.reversed() { kill(pid, SIGTERM) }

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(root, SIGKILL) }
        }
    }

    private func clearCurrent(_ process: Process) {
        lock.lock()
        if current === process { current = nil }
        lock.unlock()
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        for child in childPIDs(of: pid) {
            result.append(child)
            result.append(contentsOf: descendants(of: child))
        }
        return result
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }
}

enum Toolchain {
    /// GUI apps don't inherit the terminal PATH, so common tool locations are added explicitly.
    static func environment(global: GlobalSettings) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()

        let custom = global.extraPATH
            .split(whereSeparator: { $0 == ":" || $0.isNewline })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
        let common = [
            "\(home)/.shorebird/bin",
            "\(home)/.pub-cache/bin",
            "\(home)/fvm/default/bin",
            "\(home)/development/flutter/bin",
            "\(home)/flutter/bin",
            "\(home)/.rbenv/shims",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
        ] + nvmNodeBin(home: home) + [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
        ]
        let system = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (custom + common + [system]).joined(separator: ":")

        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["CI"] = "true"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["FLUTTER_SUPPRESS_ANALYTICS"] = "true"
        env["COCOAPODS_DISABLE_STATS"] = "true"
        // Flutter writes android/local.properties itself; plain Gradle builds (React Native) need the SDK location.
        let sdk = "\(home)/Library/Android/sdk"
        if env["ANDROID_HOME"] == nil, env["ANDROID_SDK_ROOT"] == nil, FileManager.default.fileExists(atPath: sdk) {
            env["ANDROID_HOME"] = sdk
        }

        for key in [
            "SHOREBIRD_TOKEN",
            "APP_STORE_CONNECT_API_KEY_KEY_ID",
            "APP_STORE_CONNECT_API_KEY_ISSUER_ID",
            "APP_STORE_CONNECT_API_KEY_KEY_FILEPATH",
        ] {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// nvm is loaded from ~/.zshrc, which non-interactive shells skip: use nvm's default Node (or the newest installed).
    private static func nvmNodeBin(home: String) -> [String] {
        let versions = "\(home)/.nvm/versions/node"
        let installed = ((try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? []).filter { $0.hasPrefix("v") }
        guard !installed.isEmpty else { return [] }
        let alias = (try? String(contentsOfFile: "\(home)/.nvm/alias/default", encoding: .utf8))?.trimmed ?? ""
        let wanted = alias.hasPrefix("v") ? alias : "v" + alias
        let match = installed.filter { $0 == wanted || $0.hasPrefix(wanted + ".") }
        let pick = (match.isEmpty ? installed : match).max { $0.compare($1, options: .numeric) == .orderedAscending }
        return pick.map { ["\(versions)/\($0)/bin"] } ?? []
    }

    static let preflightScript = #"""
    echo "PATH used by builds:"
    echo "$PATH" | tr ':' '\n' | sed 's/^/  /'
    echo
    for tool in git flutter fvm dart shorebird melos node npm yarn pnpm xcodebuild pod java; do
      printf '%-11s' "$tool"
      command -v "$tool" || echo "not found"
    done
    echo
    flutter --version 2>&1 | head -n 1
    shorebird --version 2>&1 | head -n 2
    node --version 2>&1 | head -n 1
    xcodebuild -version 2>&1 | head -n 1
    true
    """#
}
