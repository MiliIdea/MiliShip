import AppKit
import SwiftUI

// MARK: - Containers

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var detail: String?
    let symbol: String
    var tint: Color = .accentColor
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            Card(padding: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.caption).foregroundStyle(.secondary)
                        Text(value)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            actions
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Status

struct StatusIcon: View {
    let status: RunStatus

    var body: some View {
        if status == .running {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .frame(width: 16, height: 16)
        }
    }
}

struct StatusPill: View {
    let status: RunStatus
    var text: String?

    var body: some View {
        HStack(spacing: 5) {
            StatusIcon(status: status).scaleEffect(0.85)
            Text(text ?? status.title)
        }
        .font(.caption.weight(.medium))
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .foregroundStyle(status == .queued || status == .skipped ? Color.secondary : status.color)
        .background(status.color.opacity(0.12), in: Capsule())
    }
}

struct ModeBadge: View {
    let mode: ReleaseMode

    var body: some View {
        let color: Color = mode == .release ? .blue : .purple
        Text(mode.title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct Chip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

struct Banner: View {
    let symbol: String
    let color: Color
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The app's own icon from its clone, or a letter badge until the repository has been cloned.
struct AppGlyph: View {
    let app: AppConfig
    var size: CGFloat = 28

    var body: some View {
        if let icon = ProjectIcon.image(for: app) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        } else {
            letterBadge
        }
    }

    private var letterBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initials)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let words = app.displayName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Stable colour per app so it's recognisable in the sidebar.
    private var gradient: [Color] {
        let palettes: [[Color]] = [
            [.cyan, .blue], [.blue, .indigo], [.teal, .green], [.orange, .pink],
            [.purple, .indigo], [.pink, .red], [.mint, .teal], [.yellow, .orange],
        ]
        let hash = app.id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palettes[hash % palettes.count]
    }
}

// MARK: - Actions

struct CopyButton: View {
    let text: String
    var title: String
    @State private var copied = false

    init(text: String, title: String = "Copy") {
        self.text = text
        self.title = title
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

// MARK: - Helpers

extension RunStatus {
    var color: Color {
        switch self {
        case .queued: return .secondary
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .skipped: return .secondary
        }
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// https URL for a git remote (git@host:org/repo.git, ssh://…, https://…), for "Open on GitHub".
func repositoryWebURL(_ remote: String) -> URL? {
    var text = remote.trimmed
    if text.hasSuffix(".git") { text.removeLast(4) }
    if text.hasPrefix("git@"), let colon = text.firstIndex(of: ":") {
        let host = text[text.index(text.startIndex, offsetBy: 4)..<colon]
        let path = text[text.index(after: colon)...]
        return URL(string: "https://\(host)/\(path)")
    }
    if text.hasPrefix("ssh://") {
        var rest = String(text.dropFirst(6))
        if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if let colon = rest.firstIndex(of: ":"), let slash = rest.firstIndex(of: "/"), colon < slash {
            rest.removeSubrange(colon..<slash) // drop an ssh port
        }
        return URL(string: "https://\(rest)")
    }
    if text.hasPrefix("https://") || text.hasPrefix("http://") { return URL(string: text) }
    return nil
}
