import Foundation

/// Flutter / Shorebird build commands.
extension BuildPipeline {
    var flutter: String { app.flutterCommand.trimmed.isEmpty ? "flutter" : app.flutterCommand.trimmed }

    var flutterTools: [String] {
        var tools = [String(flutter.split(separator: " ").first ?? "flutter")]
        if isShorebird { tools.append("shorebird") }
        if platforms.contains(.ios) { tools.append("xcodebuild") }
        return tools
    }

    func flutterAndroidCommand() -> String {
        switch (app.buildTool, tag.mode) {
        case (.flutter, _):
            return join([flutter, "build appbundle --release"] + flavorTargetArgs + dartDefineArgs + versionArgs + extraArgs)
        case (.shorebird, .release):
            return join(["shorebird release android"] + shorebirdReleaseFlags + flavorTargetArgs
                + passthrough(dartDefineArgs + versionArgs + extraArgs))
        case (.shorebird, .patch):
            return join(["shorebird patch android", "--release-version=\(shq(patchReleaseVersion))"] + shorebirdPatchFlags
                + flavorTargetArgs + passthrough(dartDefineArgs + extraArgs))
        }
    }

    /// The standard Flutter setup: android/app/build.gradle reads key.properties.
    func writeKeyProperties() throws {
        let keystore = try requireFile(app.android.keystorePath, app.android.signing == .ownKey ? "Android signing keystore" : "Android upload keystore")
        let storePassword = try requireSecret(.androidKeystorePassword)
        let keyPassword = secrets[.androidKeyPassword] ?? storePassword
        let alias = try requireValue(app.android.keyAlias, "Android key alias")
        let relative = app.android.keyPropertiesPath.trimmed.isEmpty ? "android/key.properties" : app.android.keyPropertiesPath.trimmed
        let url = appDir.appendingPathComponent(relative)

        func escape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\") }
        let content = """
        storePassword=\(escape(storePassword))
        keyPassword=\(escape(keyPassword))
        keyAlias=\(escape(alias))
        storeFile=\(escape(keystore.path))

        """
        try writeTemporarily(Data(content.utf8), to: url)
        hooks.log("Wrote \(relative) → \(keystore.lastPathComponent) (removed again after the build)\n")
    }

    func flutterIOSCommand(exportOptions: URL) -> String {
        let exportArg = "--export-options-plist=\(shq(exportOptions.path))"
        switch (app.buildTool, tag.mode) {
        case (.flutter, _):
            return join([flutter, "build ipa --release"] + flavorTargetArgs + [exportArg] + dartDefineArgs + versionArgs + extraArgs)
        case (.shorebird, .release):
            return join(["shorebird release ios"] + shorebirdReleaseFlags + flavorTargetArgs
                + ["--", exportArg] + dartDefineArgs + versionArgs + extraArgs)
        case (.shorebird, .patch):
            return join(["shorebird patch ios", "--release-version=\(shq(patchReleaseVersion))"] + shorebirdPatchFlags
                + flavorTargetArgs + ["--", exportArg] + dartDefineArgs + extraArgs)
        }
    }

    // MARK: Arguments

    private var flavorTargetArgs: [String] {
        var args: [String] = []
        if !app.flavor.trimmed.isEmpty { args.append("--flavor=\(shq(app.flavor.trimmed))") }
        if !app.target.trimmed.isEmpty { args.append("--target=\(shq(app.target.trimmed))") }
        return args
    }

    /// --build-name / --build-number when the version doesn't come from pubspec.yaml.
    private var versionArgs: [String] {
        guard let versionOverride else { return [] }
        var args = ["--build-name=\(versionOverride.name)"]
        if let number = versionOverride.number { args.append("--build-number=\(number)") }
        return args
    }

    private var dartDefineArgs: [String] {
        app.dartDefineFile.trimmed.isEmpty ? [] : ["--dart-define-from-file=\(shq(app.dartDefineFile.trimmed))"]
    }

    /// Passed through verbatim so users can write normal CLI flags.
    private var extraArgs: [String] {
        app.extraBuildArgs.trimmed.isEmpty ? [] : [app.extraBuildArgs.trimmed]
    }

    private var shorebirdReleaseFlags: [String] {
        app.shorebird.flutterVersion.trimmed.isEmpty ? [] : ["--flutter-version=\(shq(app.shorebird.flutterVersion.trimmed))"]
    }

    private var shorebirdPatchFlags: [String] {
        var flags: [String] = []
        if app.shorebird.allowNativeDiffs { flags.append("--allow-native-diffs") }
        if app.shorebird.allowAssetDiffs { flags.append("--allow-asset-diffs") }
        return flags
    }
}
