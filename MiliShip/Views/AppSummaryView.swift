import SwiftUI

/// Read-only summary of an application's configuration, as Form sections.
/// Used by the wizard's Review step and the app page's Configuration tab.
struct AppSummarySections: View {
    let app: AppConfig
    var onEdit: ((WizardStep) -> Void)?

    init(app: AppConfig, onEdit: ((WizardStep) -> Void)? = nil) {
        self.app = app
        self.onEdit = onEdit
    }

    var body: some View {
        Section {
            row("Name", app.displayName, mono: false)
            row("Git URL", app.repoURL)
            row("Clone", abbreviatePath(app.workspaceURL))
        } header: {
            header("Repository", .repository)
        }

        Section {
            row("App path", app.appPath)
            row("Framework", app.framework.title, mono: false)
            row("Dependencies", app.bootstrapCommand)
            switch app.framework {
            case .flutter:
                row("Flutter", app.flutterCommand)
                row("Flavor", app.flavor)
                row("Entry point", app.target)
                row("Dart defines", app.dartDefineFile)
                row("Extra arguments", app.extraBuildArgs)
            case .reactNative:
                if app.reactNative.expoPrebuild { row("Expo", "prebuild before building", mono: false) }
                row("Gradle task", app.reactNativeGradleTask)
                row("iOS workspace", app.reactNative.iosWorkspace.trimmed.isEmpty ? "auto-detect" : app.reactNative.iosWorkspace)
                row("iOS scheme", app.reactNative.iosScheme)
                row("CocoaPods", app.reactNative.podInstallCommand)
            }
        } header: {
            header("Project", .project)
        }

        Section {
            if app.fileInjections.isEmpty {
                row("Local files", "")
            } else {
                ForEach(app.fileInjections) { injection in
                    row((injection.source as NSString).lastPathComponent, "→ \(injection.destination)")
                }
            }
            row("Pre-build commands", preBuildSummary)
        } header: {
            header("Prepare", .prepare)
        }

        Section {
            row("Build tool", app.buildToolTitle, mono: false)
            row("Release tags", "\(app.releaseTagPrefix)…")
            if app.supportsPatches {
                row("Patch tags", "\(app.patchTagPrefix)…")
                row("Patch flags", patchFlags)
            }
            row("Versioning", app.versionStrategy.title(for: app.framework), mono: false)
            row("Automation", automation, mono: false)
        } header: {
            header("Build & versioning", .build)
        }

        Section {
            if app.android.enabled {
                row("Signing", app.android.writesKeyProperties
                    ? "\(app.android.effectiveSigning == .playAppSigning ? "Play App Signing · " : "")\((app.android.keystorePath as NSString).lastPathComponent) · alias \(app.android.keyAlias)"
                    : AndroidSigning.gradle.title, mono: false)
                if app.android.upload {
                    row("Package", app.android.packageName)
                    row("Track", "\(app.android.track) · \(app.android.releaseStatus.title)")
                    row("Service account", (app.android.serviceAccountPath as NSString).lastPathComponent)
                } else {
                    row("Publishing", "Build only", mono: false)
                }
            } else {
                row("Android", "Off", mono: false)
            }
        } header: {
            header("Google Play", .googlePlay)
        }

        Section {
            if app.ios.enabled {
                row("Bundle ID", app.ios.bundleID)
                row("Team ID", app.ios.teamID)
                row("Signing", app.ios.signing == .automatic ? "Automatic" : app.ios.exportOptionsPath,
                    mono: app.ios.signing != .automatic)
                row("API key", app.ios.ascKeyID)
                row("Publishing", app.ios.upload ? "Upload to App Store Connect" : "Build only", mono: false)
            } else {
                row("iOS", "Off", mono: false)
            }
        } header: {
            header("App Store", .appStore)
        }
    }

    @ViewBuilder
    private func header(_ title: String, _ step: WizardStep) -> some View {
        HStack {
            Label(title, systemImage: step.symbol)
            Spacer()
            if let onEdit {
                Button("Edit") { onEdit(step) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = true) -> some View {
        LabeledContent(title) {
            if value.trimmed.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                Text(value)
                    .font(mono ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private var preBuildSummary: String {
        let count = app.preBuildCommands
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .count
        return count == 0 ? "" : "\(count) command\(count == 1 ? "" : "s")"
    }

    private var patchFlags: String {
        var flags: [String] = []
        if app.shorebird.allowNativeDiffs { flags.append("--allow-native-diffs") }
        if app.shorebird.allowAssetDiffs { flags.append("--allow-asset-diffs") }
        return flags.joined(separator: " ")
    }

    private var automation: String {
        guard app.watchTags else { return "Manual deployments only" }
        return "Checks every \(app.pollMinutes) min · " + (app.autoBuild ? "deploys new tags" : "notifies only")
    }
}
