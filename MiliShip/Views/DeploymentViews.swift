import AppKit
import SwiftUI

struct BuildRow: View {
    let record: BuildRecord
    var showApp = false

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: record.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(showApp ? "\(record.appName) · \(record.tagName)" : record.tagName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(record.platforms.map(\.title).joined(separator: " + ")) · \(record.queuedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BuildDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var liveLog: LiveLog
    @StateObject private var fileLog = LiveLog()
    let record: BuildRecord

    init(record: BuildRecord) {
        self.record = record
    }

    private var isActive: Bool { model.activeBuildID == record.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            platformRow

            if !record.results.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(record.results, id: \.self) { line in
                        Label(line, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.primary)
                    }
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let reason = record.failureReason, record.status == .failed {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(reason)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: reason)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(alignment: .top, spacing: 12) {
                StepsTimeline(steps: record.steps)
                    .frame(width: 290)
                LogView(log: isActive ? liveLog : fileLog, fileURL: model.logURL(for: record))
            }
        }
        .padding(20)
        .navigationTitle("\(record.appName) · \(record.tagName)")
        .task(id: "\(record.id.uuidString)-\(isActive)") {
            if !isActive { fileLog.load(fileURL: model.logURL(for: record), for: record.id) }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(record.status.color.opacity(0.15)).frame(width: 44, height: 44)
                if record.status == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: record.status.symbol)
                        .font(.title2)
                        .foregroundStyle(record.status.color)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(record.appName).font(.title2.bold())
                    ModeBadge(mode: record.mode)
                    Text(record.tagName).font(.system(.title3, design: .monospaced)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let version = record.version { Label(version, systemImage: "number") }
                    if let commit = record.commit { Label(commit, systemImage: "point.3.connected.trianglepath.dotted") }
                    Label(record.trigger.prefix(1).uppercased() + record.trigger.dropFirst(),
                          systemImage: record.actionsRunURL != nil ? "arrow.triangle.2.circlepath.circle" : record.trigger == "auto" ? "eye" : "hand.tap")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(durationText(now: context.date), systemImage: "timer")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.app(record.appID) != nil {
                Button { model.selection = .app(record.appID) } label: {
                    Label("Application", systemImage: "arrow.up.left.square")
                }
            }
            if let run = record.actionsRunURL.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(run) } label: {
                    Label("GitHub Actions", systemImage: "arrow.up.forward.square")
                }
                .help("Open this run in GitHub Actions")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.logURL(for: record)])
            } label: {
                Label("Log File", systemImage: "doc.text.magnifyingglass")
            }
            if record.status.isFinished {
                Button { model.retry(record) } label: {
                    Label("Run Again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(role: .destructive) { model.cancel(record.id) } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .help("Cancel this deployment (⌘.)")
            }
        }
    }

    private var platformRow: some View {
        HStack(spacing: 10) {
            ForEach(record.platforms) { platform in
                let status = record.status(of: platform)
                HStack(spacing: 6) {
                    StatusIcon(status: status)
                    Text(platform.title).bold()
                    Text(record.mode == .release ? "→ \(platform.storeTitle)" : "→ Shorebird patch")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(status.color.opacity(0.12), in: Capsule())
            }
            Spacer()
        }
    }

    private func durationText(now: Date) -> String {
        guard let start = record.startedAt else {
            return "queued \(record.queuedAt.formatted(.relative(presentation: .named)))"
        }
        return formatDuration((record.finishedAt ?? now).timeIntervalSince(start))
    }
}

// MARK: - Steps

struct StepsTimeline: View {
    let steps: [StepRecord]

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Steps").font(.headline)
                    Spacer()
                    Text("\(steps.filter { $0.status == .succeeded }.count)/\(steps.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if steps.isEmpty {
                            Text("Waiting to start…").foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 0) {
                                    StatusIcon(status: step.status)
                                    if index < steps.count - 1 {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.25))
                                            .frame(width: 1.5)
                                            .frame(minHeight: 14, maxHeight: .infinity)
                                    }
                                }
                                Text(step.name)
                                    .font(.callout)
                                    .foregroundStyle(step.status == .failed ? Color.red : Color.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.bottom, 10)
                                Spacer(minLength: 4)
                                if let start = step.startedAt {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(formatDuration((step.finishedAt ?? context.date).timeIntervalSince(start)))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

// MARK: - Log

struct LogView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case problems = "Errors & warnings"
        case steps = "Steps & commands"
        var id: String { rawValue }
    }

    @ObservedObject var log: LiveLog
    let fileURL: URL?
    @State private var follow = true
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var fontSize: Double = 11

    init(log: LiveLog, fileURL: URL? = nil) {
        self.log = log
        self.fileURL = fileURL
    }

    private var visibleLines: [LiveLog.Line] {
        let query = search.trimmed.lowercased()
        return log.lines.filter { line in
            let kind = LogLineKind(line.text)
            switch filter {
            case .all: break
            case .problems: if kind != .error && kind != .warning { return false }
            case .steps: if kind != .step && kind != .command && kind != .success { return false }
            }
            return query.isEmpty || line.text.lowercased().contains(query)
        }
    }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                let lines = visibleLines
                if lines.isEmpty {
                    EmptyState(
                        symbol: log.lines.isEmpty ? "text.alignleft" : "line.3.horizontal.decrease.circle",
                        title: log.lines.isEmpty ? "No output yet" : "No matching lines",
                        message: log.lines.isEmpty ? "Output appears here as soon as the deployment starts." : "Change the filter or the search text."
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines) { line in
                                    LogLineView(line: line, fontSize: fontSize, highlight: search.trimmed)
                                        .id(line.id)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .onChange(of: log.lines.last?.id) { lastID in
                            guard follow, filter == .all, search.isEmpty, let lastID else { return }
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                        .onAppear {
                            if let last = lines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Log").font(.headline)
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search log", text: $search).textFieldStyle(.plain).frame(minWidth: 120)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            Spacer()
            Text("\(log.lines.count) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
            ControlGroup {
                Button { fontSize = max(9, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                Button { fontSize = min(18, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
            }
            .fixedSize()
            CopyButton(text: visibleLines.map(\.text).joined(separator: "\n"))
                .labelStyle(.iconOnly)
                .help("Copy visible lines")
            if let fileURL {
                Button { NSWorkspace.shared.open(fileURL) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open the full log in the default text editor")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

enum LogLineKind {
    case step, command, error, warning, success, normal

    init(_ text: String) {
        if text.hasPrefix("▶") { self = .step; return }
        if text.hasPrefix("$ ") { self = .command; return }
        if text.hasPrefix("=== SUCCEEDED") || text.hasPrefix("✓") { self = .success; return }
        let lower = text.lowercased()
        if text.hasPrefix("✖") || text.hasPrefix("=== FAILED") || lower.contains("error:") || lower.contains("failure:")
            || lower.contains("exception:") || lower.hasPrefix("error ") { self = .error; return }
        if text.hasPrefix("⚠") || lower.contains("warning:") { self = .warning; return }
        self = .normal
    }

    var color: Color {
        switch self {
        case .step: return .accentColor
        case .command: return .secondary
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .normal: return .primary
        }
    }
}

private struct LogLineView: View {
    let line: LiveLog.Line
    let fontSize: Double
    let highlight: String

    var body: some View {
        let kind = LogLineKind(line.text)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: String(line.id + 1))
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 44, alignment: .trailing)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: fontSize, weight: kind == .step ? .semibold : .regular, design: .monospaced))
                .foregroundColor(kind.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, kind == .step ? 3 : 0)
        .background(background(kind))
    }

    private func background(_ kind: LogLineKind) -> Color {
        if !highlight.isEmpty && line.text.localizedCaseInsensitiveContains(highlight) { return Color.yellow.opacity(0.18) }
        switch kind {
        case .step: return Color.accentColor.opacity(0.08)
        case .error: return Color.red.opacity(0.06)
        default: return .clear
        }
    }
}
