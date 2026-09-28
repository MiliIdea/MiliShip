import Foundation

/// The GitHub Actions workflow Mili Ship adds to a repository. It only hands the tag to Mili Ship;
/// the build runs in the app, so the file never needs editing when the pipeline changes.
enum ActionsWorkflow {
    static func yaml(for app: AppConfig) -> String {
        var tagPatterns = ["'\(app.releaseTagPrefix)**'"]
        if app.supportsPatches { tagPatterns.append("'\(app.patchTagPrefix)**'") }
        let label = app.githubActions.runnerLabel.isEmpty ? "miliship" : app.githubActions.runnerLabel
        let options = ["all"] + app.enabledPlatforms.map(\.rawValue)
        return """
        # Deploys tags with Mili Ship (https://github.com/MiliIdea/MiliShip).
        # The job runs on the Mili Ship runner of this repository; the app on that Mac builds,
        # signs and publishes the tag and streams its log here. Managed by Mili Ship.
        name: Mili Ship
        run-name: Deploy ${{ github.ref_name }}

        on:
          push:
            tags:
        \(tagPatterns.map { "      - \($0)" }.joined(separator: "\n"))
          workflow_dispatch:
            inputs:
              platforms:
                description: Platforms to deploy
                type: choice
                options: [\(options.joined(separator: ", "))]
                default: all

        concurrency:
          group: miliship-${{ github.ref }}
          cancel-in-progress: false

        jobs:
          deploy:
            name: Deploy ${{ github.ref_name }}
            if: startsWith(github.ref, 'refs/tags/')
            runs-on: [self-hosted, \(label)]
            timeout-minutes: \(max(10, app.githubActions.timeoutMinutes))
            steps:
              - name: Build and publish with Mili Ship
                env:
                  MILISHIP_PLATFORMS: ${{ inputs.platforms || 'all' }}
                # exec: the script replaces the step's shell, so cancelling the run reaches it directly.
                run: |
                  exec "${MILISHIP_JOB:?This job must run on a Mili Ship runner}"

        """
    }

    /// The job step. Written on every launch so it always matches the installed app.
    static let jobScript = #"""
    #!/bin/bash
    # Mili Ship job step: hands the tag to the Mili Ship app on this Mac and streams its log.
    set -uo pipefail

    spool="${MILISHIP_SPOOL:?Not running on a Mili Ship runner}"
    app="${MILISHIP_APP_ID:?Not running on a Mili Ship runner}"
    id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
    dir="$spool/$id"
    open=0
    mkdir -p "$dir" "$spool/requests"
    parent=$PPID
    # Mili Ship stops the build when this step (or the runner process above it) disappears.
    echo $$ > "$dir/pid"
    echo "$parent" > "$dir/ppid"
    orphaned() { ! kill -0 "$parent" 2>/dev/null; }

    finish() {
      [ "$open" = 1 ] && echo "::endgroup::"
      if [ -f "$dir/summary.md" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$dir/summary.md" >> "$GITHUB_STEP_SUMMARY"; fi
      code="$(cat "$dir/result" 2>/dev/null || echo 1)"
      rm -rf "$dir"
      exit "$code"
    }

    cancelled() {
      trap '' INT TERM
      echo "::warning::Cancelled in GitHub. Stopping the deployment in Mili Ship…"
      touch "$dir/cancel"
      # The runner force-kills the step ~10 s after cancelling; Mili Ship finishes stopping on its own.
      for _ in $(seq 1 6); do [ -f "$dir/result" ] && break; sleep 1; done
      [ -f "$dir/result" ] || echo 130 > "$dir/result"
      finish
    }
    trap cancelled INT TERM

    {
      echo "app=$app"
      echo "ref=${GITHUB_REF:-}"
      echo "tag=${GITHUB_REF_NAME:-}"
      echo "sha=${GITHUB_SHA:-}"
      echo "platforms=${MILISHIP_PLATFORMS:-all}"
      echo "actor=${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"
      echo "event=${GITHUB_EVENT_NAME:-}"
      echo "run_url=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
    } > "$spool/requests/.$id.tmp"
    mv "$spool/requests/.$id.tmp" "$spool/requests/$id.req"

    for _ in $(seq 1 60); do
      { [ -f "$dir/accepted" ] || [ -f "$dir/rejected" ]; } && break
      orphaned && cancelled
      sleep 1
    done
    if [ -f "$dir/rejected" ]; then
      echo "::error title=Mili Ship::$(cat "$dir/rejected")"
      echo 1 > "$dir/result"; finish
    fi
    if [ ! -f "$dir/accepted" ]; then
      rm -f "$spool/requests/$id.req"
      echo "::error title=Mili Ship::Mili Ship didn't respond. Make sure the app is running on this Mac."
      echo 1 > "$dir/result"; finish
    fi
    log="$(sed -n 's/^log=//p' "$dir/accepted")"
    echo "Mili Ship accepted ${GITHUB_REF_NAME:-the tag} — $(sed -n 's/^title=//p' "$dir/accepted")"

    last=""
    while [ ! -f "$dir/started" ] && [ ! -f "$dir/result" ]; do
      status="$(cat "$dir/status" 2>/dev/null || true)"
      if [ -n "$status" ] && [ "$status" != "$last" ]; then echo "⏳ $status"; last="$status"; fi
      orphaned && cancelled
      sleep 2
    done

    # Each pipeline step becomes a collapsible group; failed steps become annotations.
    emit() {
      case "$1" in
        "▶ "*) [ "$open" = 1 ] && echo "::endgroup::"; echo "::group::${1#▶ }"; open=1 ;;
        "✖ "*) printf '%s\n' "$1"; echo "::error title=Mili Ship::${1#✖ }" ;;
        "=== "*) [ "$open" = 1 ] && echo "::endgroup::"; open=0; printf '%s\n' "$1" ;;
        *) printf '%s\n' "$1" ;;
      esac
    }

    # Follow the log without tail, so nothing has to be killed at the end.
    for _ in $(seq 1 30); do [ -f "$log" ] && break; sleep 1; done
    exec 3<"$log"
    partial=""
    while :; do
      if IFS= read -r line <&3; then
        emit "$partial$line"; partial=""
      else
        partial="$partial$line"
        if [ -f "$dir/result" ]; then
          # Drain what was written right before the result.
          while IFS= read -r line <&3; do emit "$partial$line"; partial=""; done
          partial="$partial$line"
          [ -n "$partial" ] && emit "$partial"
          break
        fi
        orphaned && cancelled
        sleep 0.5
      fi
    done
    exec 3<&-
    finish
    """#
}

/// Picks up job requests from the runner's job step, queues them as normal deployments and reports
/// progress back through files in ~/.miliship/jobs/<request id>/.
@MainActor
final class ActionsBridge {
    struct Request {
        let id: String
        let fields: [String: String]
        subscript(_ key: String) -> String { fields[key] ?? "" }
    }

    private struct Job {
        let directory: URL
        let recordID: UUID
        var started = false
        var cancelRequested = false
        var lastStatus = ""
    }

    private weak var model: AppModel?
    private var jobs: [String: Job] = [:]
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        installJobScript()
        cleanUp()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func installJobScript() {
        let url = AppPaths.jobScript
        try? ActionsWorkflow.jobScript.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Leftovers from runs that ended while Mili Ship wasn't running.
    private func cleanUp() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: AppPaths.jobs.path)) ?? [] where name != "requests" {
            try? fm.removeItem(at: AppPaths.jobs.appendingPathComponent(name))
        }
    }

    private func tick() {
        guard let model else { return }
        for url in pendingRequests() { accept(url, model: model) }
        for (id, job) in jobs { follow(id, job, model: model) }
    }

    private func pendingRequests() -> [URL] {
        let dir = AppPaths.jobRequests
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".req") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    private func accept(_ url: URL, model: AppModel) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        let request = Request(id: url.deletingPathExtension().lastPathComponent, fields: fields)
        let directory = AppPaths.jobs.appendingPathComponent(request.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch model.acceptActionsJob(request) {
        case .failure(let error):
            write(error.message, "rejected", in: directory)
        case .success(let record):
            write("record=\(record.id.uuidString)\nlog=\(model.logURL(for: record).path)\ntitle=\(record.appName) \(record.platforms.map(\.title).joined(separator: " + "))\n",
                  "accepted", in: directory)
            jobs[request.id] = Job(directory: directory, recordID: record.id)
        }
    }

    private func follow(_ id: String, _ job: Job, model: AppModel) {
        var job = job
        let directory = job.directory
        let fm = FileManager.default
        guard let record = model.history.first(where: { $0.id == job.recordID }) else {
            write("1", "result", in: directory)
            jobs[id] = nil
            return
        }
        let stepAlive = Self.stepIsAlive(in: directory)

        // Cancelled in GitHub (the step says so), or the step vanished: the runner force-killed it,
        // crashed, or the job hit its time limit. Either way nobody waits for this build any more.
        if !job.cancelRequested, !record.status.isFinished,
           fm.fileExists(atPath: directory.appendingPathComponent("cancel").path) || !stepAlive {
            job.cancelRequested = true
            model.cancel(record.id, reason: stepAlive ? "Cancelled in GitHub Actions" : "The GitHub Actions job ended (cancelled or timed out)")
        }

        switch record.status {
        case .queued:
            let ahead = model.history.filter { $0.status == .queued && $0.queuedAt < record.queuedAt }.count
                + (model.activeBuildID == nil ? 0 : 1)
            let status = ahead == 0 ? "Starting…" : "Waiting for Mili Ship — \(ahead) deployment\(ahead == 1 ? "" : "s") ahead"
            if status != job.lastStatus { write(status, "status", in: directory); job.lastStatus = status }
        case .running:
            if !job.started { write("", "started", in: directory); job.started = true }
        default:
            write(Self.summary(for: record), "summary.md", in: directory)
            let code: String
            switch record.status {
            case .succeeded: code = "0"
            case .cancelled: code = "130"
            default: code = "1"
            }
            write(code, "result", in: directory)
            jobs[id] = nil
            // A live step removes its folder after reading the result; clean up after a dead one.
            if !stepAlive { try? fm.removeItem(at: directory) }
            return
        }
        jobs[id] = job
    }

    /// False once the job step — or the runner process that started it — is gone.
    private static func stepIsAlive(in directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        for name in ["pid", "ppid"] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
                  let pid = pid_t(text.trimmed)
            else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { return false }
        }
        return true
    }

    private func write(_ text: String, _ name: String, in directory: URL) {
        let url = directory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func summary(for record: BuildRecord) -> String {
        let icon: String
        switch record.status {
        case .succeeded: icon = "✅"
        case .cancelled: icon = "⏹️"
        default: icon = "❌"
        }
        let verb = record.status == .succeeded ? (record.mode == .patch ? "patched" : "deployed") : record.status.title.lowercased()
        var lines = ["### \(icon) \(record.appName) \(record.version ?? record.tagName) \(verb)", ""]
        lines.append("| | |")
        lines.append("|---|---|")
        lines.append("| Tag | `\(record.tagName)` |")
        if let commit = record.commit { lines.append("| Commit | `\(commit)` |") }
        let platforms = record.platforms.map { platform -> String in
            let status = record.status(of: platform)
            let mark = status == .succeeded ? "✅" : status == .failed ? "❌" : status == .cancelled ? "⏹️" : "➖"
            return "\(platform.title) \(mark)"
        }
        lines.append("| Platforms | \(platforms.joined(separator: " · ")) |")
        if let start = record.startedAt, let end = record.finishedAt {
            let seconds = Int(end.timeIntervalSince(start))
            lines.append("| Duration | \(seconds / 60)m \(seconds % 60)s |")
        }
        if !record.results.isEmpty {
            lines += ["", "**Results**", ""] + record.results.map { "- \($0)" }
        }
        if let reason = record.failureReason, record.status != .succeeded {
            lines += ["", "**Reason**", "", "```", reason, "```"]
        }
        lines += ["", "<sub>Built on a self-hosted Mac with [Mili Ship](https://github.com/MiliIdea/MiliShip)</sub>", ""]
        return lines.joined(separator: "\n")
    }
}
