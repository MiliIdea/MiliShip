import Foundation

/// Git operations on an application's dedicated clone (never your own working copy).
struct Git {
    let repoURL: String
    let repoDir: URL

    init(app: AppConfig) {
        repoURL = app.repoURL.trimmed
        repoDir = app.workspaceURL
    }

    /// Returns true when a fresh clone was made.
    @discardableResult
    func ensureClone(shell: ShellRunner, env: [String: String], log: @escaping (String) -> Void) async throws -> Bool {
        guard !repoURL.isEmpty else { throw MiliShipError(message: "The repository URL is not set.") }
        let fm = FileManager.default
        if fm.fileExists(atPath: repoDir.appendingPathComponent(".git").path) {
            try await shell.run("git remote set-url origin \(shq(repoURL))", cwd: repoDir, env: env, log: log)
            return false
        }
        let parent = repoDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        log("Cloning \(repoURL) into \(repoDir.path)…\n")
        try await shell.run("git clone \(shq(repoURL)) \(shq(repoDir.path))", cwd: parent, env: env, log: log)
        return true
    }

    /// Fetches tags and returns the ones matching the app's release/patch prefixes, newest first.
    func fetchTags(for app: AppConfig, shell: ShellRunner, env: [String: String], log: @escaping (String) -> Void) async throws -> [TagEntry] {
        try await ensureClone(shell: shell, env: env, log: log)
        try await shell.run("git fetch --force --prune --prune-tags --tags origin", cwd: repoDir, env: env, log: log)

        let format = "%(refname)%09%(objectname:short)%09%(*objectname:short)%09%(creatordate:unix)"
        let output = try await shell.run(
            "git for-each-ref --sort=-creatordate --format=\(shq(format)) refs/tags",
            cwd: repoDir, env: env, log: { _ in }
        )

        let prefix = "refs/tags/"
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = String(line).components(separatedBy: "\t")
            guard columns.count >= 4, columns[0].hasPrefix(prefix),
                  let tag = app.releaseTag(named: String(columns[0].dropFirst(prefix.count)))
            else { return nil }
            let commit = columns[2].isEmpty ? columns[1] : columns[2] // annotated tags point at a commit
            let date = Double(columns[3]).map { Date(timeIntervalSince1970: $0) }
            return TagEntry(tag: tag, commit: commit, date: date)
        }
    }

    /// Used by the setup wizard: clone (or update) and check out the default branch for scanning.
    func checkoutDefaultBranch(shell: ShellRunner, env: [String: String], log: @escaping (String) -> Void) async throws {
        let fresh = try await ensureClone(shell: shell, env: env, log: log)
        guard !fresh else { return }
        try await shell.run(
            """
            git fetch --force --tags origin && \
            (git remote set-head origin --auto >/dev/null 2>&1 || true) && \
            git -c advice.detachedHead=false checkout --force --detach origin/HEAD && \
            git clean -ffd
            """,
            cwd: repoDir, env: env, log: log
        )
    }

    /// Clean checkout of a tag. Ignored files (build caches, .dart_tool) are kept for speed.
    func prepareCheckout(tag: String, shell: ShellRunner, env: [String: String], log: @escaping (String) -> Void) async throws {
        try await ensureClone(shell: shell, env: env, log: log)
        try await shell.run("git fetch --force --tags origin", cwd: repoDir, env: env, log: log)
        try await shell.run(
            "git -c advice.detachedHead=false checkout --force \(shq("refs/tags/" + tag))",
            cwd: repoDir, env: env, log: log
        )
        try await shell.run("git reset --hard HEAD && git clean -ffd", cwd: repoDir, env: env, log: log)
        try await shell.run(
            "if [ -f .gitmodules ]; then git submodule update --init --recursive; fi",
            cwd: repoDir, env: env, log: log
        )
    }
}
