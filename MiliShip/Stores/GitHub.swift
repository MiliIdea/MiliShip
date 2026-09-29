import Foundation

/// GitHub REST API, only what Mili Ship needs to run deployments as GitHub Actions jobs:
/// self-hosted runner registration, the workflow file, and workflow dispatches.
struct GitHubClient: Sendable {
    let token: String
    let repo: GitHubRepo

    struct Repository {
        let isPrivate: Bool
        let defaultBranch: String
        let canAdminister: Bool?
    }

    struct RunnerInfo {
        let id: Int
        let name: String
        let status: String
        let busy: Bool
    }

    enum WorkflowResult {
        case unchanged
        case committed(branch: String)
        case pullRequest(URL)
    }

    private var base: String { "https://api.github.com/repos/\(repo.owner)/\(repo.name)" }

    // MARK: Repository

    func repository() async throws -> Repository {
        let json = try await call("GET", base)
        return Repository(
            isPrivate: json["private"] as? Bool ?? true,
            defaultBranch: json["default_branch"] as? String ?? "main",
            canAdminister: (json["permissions"] as? [String: Any])?["admin"] as? Bool
        )
    }

    // MARK: Runners

    func runnerRegistrationToken() async throws -> String {
        let json = try await call("POST", "\(base)/actions/runners/registration-token")
        guard let token = json["token"] as? String else { throw MiliShipError(message: "GitHub didn't return a runner registration token.") }
        return token
    }

    func runnerRemovalToken() async throws -> String {
        let json = try await call("POST", "\(base)/actions/runners/remove-token")
        guard let token = json["token"] as? String else { throw MiliShipError(message: "GitHub didn't return a runner removal token.") }
        return token
    }

    func runners() async throws -> [RunnerInfo] {
        let json = try await call("GET", "\(base)/actions/runners?per_page=100")
        return (json["runners"] as? [[String: Any]] ?? []).compactMap { runner in
            guard let id = runner["id"] as? Int, let name = runner["name"] as? String else { return nil }
            return RunnerInfo(id: id, name: name, status: runner["status"] as? String ?? "offline", busy: runner["busy"] as? Bool ?? false)
        }
    }

    func deleteRunner(id: Int) async throws {
        _ = try await call("DELETE", "\(base)/actions/runners/\(id)")
    }

    // MARK: Workflow

    /// Starts the workflow for a tag. Fails when the workflow file doesn't exist at that tag.
    func dispatch(workflowFile: String, ref: String, inputs: [String: String]) async throws {
        _ = try await call("POST", "\(base)/actions/workflows/\(escape(workflowFile))/dispatches",
                           body: ["ref": ref, "inputs": inputs])
    }

    /// Commits the workflow to the default branch, or opens a pull request when the branch is protected.
    func installWorkflow(path: String, content: String, defaultBranch: String) async throws -> WorkflowResult {
        let existing = try await file(path: path, ref: defaultBranch)
        if existing?.content == content { return .unchanged }
        let message = existing == nil ? "Add Mili Ship deploy workflow" : "Update Mili Ship deploy workflow"
        do {
            try await putFile(path: path, content: content, message: message, branch: defaultBranch, sha: existing?.sha)
            return .committed(branch: defaultBranch)
        } catch let error as APIError where [403, 409, 422].contains(error.status) && !error.isPermissionProblem {
            // Protected branch or required reviews: propose it as a pull request instead.
            let branch = "miliship/deploy-workflow"
            let head = try await call("GET", "\(base)/git/ref/heads/\(escape(defaultBranch))")
            guard let sha = (head["object"] as? [String: Any])?["sha"] as? String else { throw error }
            do {
                _ = try await call("POST", "\(base)/git/refs", body: ["ref": "refs/heads/\(branch)", "sha": sha])
            } catch let refError as APIError where refError.status == 422 {
                _ = try await call("PATCH", "\(base)/git/refs/heads/\(branch)", body: ["sha": sha, "force": true])
            }
            let onBranch = try await file(path: path, ref: branch)
            try await putFile(path: path, content: content, message: message, branch: branch, sha: onBranch?.sha)
            let pull = try await call("POST", "\(base)/pulls", body: [
                "title": message,
                "head": branch,
                "base": defaultBranch,
                "body": "Runs tag deployments on the Mili Ship runner of this repository. Tags created after this is merged are deployed through GitHub Actions.",
            ])
            guard let url = (pull["html_url"] as? String).flatMap(URL.init(string:)) else { throw error }
            return .pullRequest(url)
        }
    }

    /// Contents of a file on a branch, or nil when it doesn't exist.
    func fileContent(path: String, ref: String) async throws -> String? {
        try await file(path: path, ref: ref)?.content
    }

    private func file(path: String, ref: String) async throws -> (sha: String, content: String)? {
        do {
            let json = try await call("GET", "\(base)/contents/\(path)?ref=\(escape(ref))")
            guard let sha = json["sha"] as? String else { return nil }
            let encoded = (json["content"] as? String ?? "").replacingOccurrences(of: "\n", with: "")
            let content = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return (sha, content)
        } catch let error as APIError where error.status == 404 {
            return nil
        }
    }

    private func putFile(path: String, content: String, message: String, branch: String, sha: String?) async throws {
        var body: [String: Any] = ["message": message, "content": Data(content.utf8).base64EncodedString(), "branch": branch]
        if let sha { body["sha"] = sha }
        _ = try await call("PUT", "\(base)/contents/\(path)", body: body)
    }

    // MARK: Transport

    struct APIError: LocalizedError {
        let status: Int
        let message: String

        /// Token scopes rather than branch protection.
        var isPermissionProblem: Bool {
            message.localizedCaseInsensitiveContains("not accessible")
                || message.localizedCaseInsensitiveContains("workflow scope")
                || message.localizedCaseInsensitiveContains("permission")
        }

        var errorDescription: String? {
            var text = "GitHub API \(status): \(message)"
            if status == 401 { text += " — the token is invalid or expired." }
            if status == 404 { text += " — check the repository URL and that the token can access it." }
            if status == 403 || isPermissionProblem {
                text += " — the token needs Administration, Actions, Contents and Workflows (read and write) for this repository."
            }
            return text
        }
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: path) else { throw MiliShipError(message: "Invalid URL \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MiliShip", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try jsonData(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: json["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
        return json
    }
}

/// Downloads GitHub's official runner (github.com/actions/runner) for this Mac.
enum RunnerDistribution {
    static var assetSuffix: String {
        #if arch(arm64)
        return "osx-arm64"
        #else
        return "osx-x64"
        #endif
    }

    /// The newest runner already downloaded, or a fresh download of the latest release.
    static func ensureLatest(log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let root = AppPaths.runnerDistributions
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/actions/runner/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MiliShip", forHTTPHeaderField: "User-Agent")

        let release: [String: Any]
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            release = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        } catch {
            if let installed = newestInstalled() { return installed } // offline: reuse what we have
            throw error
        }
        guard let assets = release["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.contains(assetSuffix) == true
                                                && ($0["name"] as? String)?.hasSuffix(".tar.gz") == true }),
              let name = asset["name"] as? String,
              let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:))
        else {
            if let installed = newestInstalled() { return installed }
            throw MiliShipError(message: "Couldn't find the GitHub Actions runner for macOS (\(assetSuffix)) in the latest release.")
        }

        let version = (release["tag_name"] as? String ?? name).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let target = root.appendingPathComponent(version, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.appendingPathComponent("config.sh").path) { return target }

        log("Downloading GitHub Actions runner \(version)…\n")
        let (download, response) = try await URLSession.shared.download(from: link)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiliShipError(message: "Downloading the runner failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let staging = root.appendingPathComponent(".\(version)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: download) }
        try await ShellRunner().run("/usr/bin/tar -xzf \(shq(download.path)) -C \(shq(staging.path))",
                                    cwd: root, env: ProcessInfo.processInfo.environment, log: { _ in })
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        log("Runner \(version) ready\n")
        return target
    }

    private static func newestInstalled() -> URL? {
        let root = AppPaths.runnerDistributions
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/config.sh").path) }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }
}
