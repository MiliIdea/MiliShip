import AppKit
import ServiceManagement
import SwiftUI

/// Settings shared by all applications. Per-app settings live in the application wizard.
struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var preflightOutput = ""
    @State private var runningPreflight = false
    @State private var importing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Mili Ship at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("General")
            } footer: {
                Text("Keeps watching your repositories from the menu bar after a restart. Closing the window doesn't quit Mili Ship; use the menu bar icon → Quit.")
            }

            Section {
                TextEditor(text: $model.global.extraPATH)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70)
                HStack {
                    Button(importing ? "Importing…" : "Import PATH from my zsh") { importPath() }
                        .disabled(importing)
                    Spacer()
                }
            } header: {
                Text("Shell PATH")
            } footer: {
                Text("Apps started from Finder don't see your terminal PATH. Add folders (one per line or separated by :) where flutter, fvm, shorebird, melos, node, yarn, pnpm, pod or java live. Homebrew, nvm, Volta, ~/.shorebird/bin and ~/.pub-cache/bin are included automatically.")
            }

            Section("Notifications") {
                Toggle("Notify about new tags and finished deployments", isOn: $model.global.notifications)
            }

            Section {
                ForEach(model.tools) { tool in
                    LabeledContent {
                        Text(tool.path ?? (tool.optional ? "not found (optional)" : "not found"))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(tool.found ? Color.secondary : (tool.optional ? Color.secondary : Color.red))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Label {
                            Text(tool.name).font(.system(.body, design: .monospaced))
                        } icon: {
                            Image(systemName: tool.found ? "checkmark.circle.fill" : (tool.optional ? "minus.circle" : "xmark.circle.fill"))
                                .foregroundStyle(tool.found ? Color.green : (tool.optional ? Color.secondary : Color.red))
                        }
                    }
                }
                HStack {
                    Button(model.checkingTools ? "Checking…" : "Check tools") { Task { await model.checkTools() } }
                        .disabled(model.checkingTools)
                    Button(runningPreflight ? "Collecting…" : "Show versions") { runPreflight() }
                        .disabled(runningPreflight)
                    if model.checkingTools || runningPreflight { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !preflightOutput.isEmpty {
                    ScrollView {
                        Text(preflightOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 200)
                }
            } header: {
                Text("Toolchain")
            } footer: {
                Text("Checked with the same PATH Mili Ship uses for builds.")
            }

            Section("Data") {
                LabeledContent("Settings & logs", value: abbreviatePath(AppPaths.support))
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.support) }
                    Spacer()
                }
                Text("Secrets (passwords, tokens) are stored in the macOS Keychain under “com.mili.MiliShip”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if model.tools.isEmpty { await model.checkTools() } }
    }

    @MainActor
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription). Move Mili Ship to /Applications and try again."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    @MainActor
    private func importPath() {
        importing = true
        Task {
            if let path = await model.importShellPath() {
                model.global.extraPATH = path
                    .split(separator: ":")
                    .map { String($0) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                await model.checkTools()
            }
            importing = false
        }
    }

    @MainActor
    private func runPreflight() {
        runningPreflight = true
        Task {
            preflightOutput = await model.runPreflight()
            runningPreflight = false
        }
    }
}
