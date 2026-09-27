import AppKit
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Welcome to Mili Ship").font(.largeTitle.bold())
                    Text("CI/CD for Flutter and React Native on your Mac. Push a tag and Mili Ship builds it with Flutter, Shorebird or Gradle + Xcode, then ships it to Google Play and App Store Connect.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560)
                }
                .padding(.top, 10)

                HStack(alignment: .top, spacing: 14) {
                    StepCard(number: 1, symbol: "arrow.triangle.branch", title: "Connect a repository",
                             text: "Any Flutter or React Native app, including monorepos and Expo. Mili Ship keeps its own clone and detects your app.")
                    StepCard(number: 2, symbol: "slider.horizontal.3", title: "Set up the stores",
                             text: "Guided Google Play and App Store Connect setup, with connection tests.")
                    StepCard(number: 3, symbol: "tag", title: "Push a tag",
                             text: "release/1.2.0+45 ships to the stores. patch/… ships a Shorebird patch.")
                }
                .frame(maxWidth: 780)

                Button { model.beginAddApp() } label: {
                    Label("Add Application", systemImage: "plus")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                ToolChecklist()
                    .frame(maxWidth: 780)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StepCard: View {
    let number: Int
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(verbatim: "\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.secondary.opacity(0.12), in: Circle())
                }
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shows which build tools Mili Ship can find with the PATH it uses for builds.
struct ToolChecklist: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Toolchain on this Mac", systemImage: "wrench.and.screwdriver")
                        .font(.headline)
                    Spacer()
                    if model.checkingTools {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check again") { Task { await model.checkTools() } }
                        .disabled(model.checkingTools)
                    Button("Settings…") { openSettingsWindow() }
                }

                if model.tools.isEmpty {
                    Text(model.checkingTools ? "Looking for git, flutter, node, shorebird, xcodebuild…" : "Not checked yet.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                              alignment: .leading, spacing: 8) {
                        ForEach(model.tools) { tool in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: tool.found ? "checkmark.circle.fill" : (tool.optional ? "minus.circle" : "xmark.circle.fill"))
                                    .foregroundStyle(tool.found ? Color.green : (tool.optional ? Color.secondary : Color.red))
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(tool.name).font(.system(.body, design: .monospaced).weight(.medium))
                                        if tool.optional && !tool.found {
                                            Text("optional").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(tool.path ?? tool.purpose)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if model.tools.contains(where: { !$0.found && !$0.optional }) {
                        Text("Missing tools? GUI apps don't inherit your terminal PATH. Open Settings → Import PATH from my zsh.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .task {
            if model.tools.isEmpty { await model.checkTools() }
        }
    }
}
