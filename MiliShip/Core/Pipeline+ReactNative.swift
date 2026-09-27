import Foundation

/// React Native build commands: Gradle for Android, CocoaPods + xcodebuild archive for iOS.
extension BuildPipeline {
    private var rn: ReactNativeConfig { app.reactNative }

    /// Only the platforms of this run are generated, so an Android-only build doesn't need CocoaPods.
    var expoPrebuildCommand: String {
        let platform = platforms.count == 1 ? platforms[0].rawValue : "all"
        return "npx expo prebuild --no-install --platform \(platform)"
    }

    var podInstallCommand: String? {
        let command = rn.podInstallCommand.trimmed
        return command.isEmpty ? nil : command
    }

    func reactNativeTools() async throws -> [String] {
        var tools = ["node"]
        if let manager = app.bootstrapCommand.trimmed.split(separator: " ").first { tools.append(String(manager)) }
        if platforms.contains(.android) { try await ensureJavaHome() }
        if platforms.contains(.ios) {
            tools.append("xcodebuild")
            if let pod = podInstallCommand?.split(separator: " ").first { tools.append(String(pod)) }
        }
        return tools
    }

    /// Gradle needs a JDK. /usr/bin/java is only a stub, so fall back to Android Studio's bundled JDK.
    private func ensureJavaHome() async throws {
        guard env["JAVA_HOME"]?.trimmed.isEmpty ?? true else { return }
        let output = try await sh("/usr/libexec/java_home 2>/dev/null || true", in: repoDir)
        let system = output.split(whereSeparator: \.isNewline).last.map { String($0).trimmed } ?? ""
        if !system.isEmpty, FileManager.default.fileExists(atPath: system) { return }
        let studio = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
        if FileManager.default.fileExists(atPath: studio) {
            env["JAVA_HOME"] = studio
            hooks.log("JAVA_HOME → Android Studio's bundled JDK\n")
        } else {
            hooks.log("⚠︎ No JDK found. Install one (e.g. brew install --cask zulu@17) or Android Studio.\n")
        }
    }

    // MARK: Android

    /// Hands the keystore to Gradle through Android's injected signing properties, so no file is written
    /// and the project's own signingConfig doesn't matter. Values travel in environment variables to keep
    /// them out of the command line.
    func prepareGradleSigning() throws {
        let keystore = try requireFile(app.android.keystorePath, app.android.signing == .ownKey ? "Android signing keystore" : "Android upload keystore")
        let storePassword = try requireSecret(.androidKeystorePassword)
        env["MILISHIP_STORE_FILE"] = keystore.path
        env["MILISHIP_STORE_PASSWORD"] = storePassword
        env["MILISHIP_KEY_ALIAS"] = try requireValue(app.android.keyAlias, "Android key alias")
        env["MILISHIP_KEY_PASSWORD"] = secrets[.androidKeyPassword] ?? storePassword
        hooks.log("Signing with \(keystore.lastPathComponent) (alias \(app.android.keyAlias.trimmed)) — passed to Gradle, nothing written\n")
    }

    func applyGradleVersion(_ version: VersionParts) throws {
        guard let url = ReactNativeProject.gradleURL(in: appDir), let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MiliShipError(message: "android/app/build.gradle not found.")
        }
        let updated = try ReactNativeProject.settingAndroidVersion(version, in: text)
        try writeTemporarily(Data(updated.utf8), to: url)
        hooks.log("build.gradle → versionName \"\(version.name)\"\(version.number.map { ", versionCode \($0)" } ?? "")\n")
    }

    /// Runs in android/.
    func reactNativeAndroidCommand() -> String {
        var parts = ["./gradlew", shq(app.reactNativeGradleTask)]
        if app.android.writesKeyProperties {
            parts += [
                #"-Pandroid.injected.signing.store.file="$MILISHIP_STORE_FILE""#,
                #"-Pandroid.injected.signing.store.password="$MILISHIP_STORE_PASSWORD""#,
                #"-Pandroid.injected.signing.key.alias="$MILISHIP_KEY_ALIAS""#,
                #"-Pandroid.injected.signing.key.password="$MILISHIP_KEY_PASSWORD""#,
            ]
        }
        parts.append(rn.extraGradleArgs.trimmed)
        return join(parts)
    }

    // MARK: iOS

    private func iosContainerArgs() throws -> (args: [String], scheme: String) {
        let configured = rn.iosWorkspace.trimmed
        let workspace = configured.isEmpty ? ReactNativeProject.workspace(in: appDir) : appDir.appendingPathComponent(configured)
        if let workspace, FileManager.default.fileExists(atPath: workspace.path) {
            let scheme = rn.iosScheme.trimmed.isEmpty ? workspace.deletingPathExtension().lastPathComponent : rn.iosScheme.trimmed
            return (["-workspace", shq(workspace.path)], scheme)
        }
        guard let project = ReactNativeProject.xcodeproj(in: appDir) else {
            throw MiliShipError(message: "No .xcworkspace or .xcodeproj in ios/. Check the app path, or turn on Expo prebuild.")
        }
        let scheme = rn.iosScheme.trimmed.isEmpty ? project.deletingPathExtension().lastPathComponent : rn.iosScheme.trimmed
        return (["-project", shq(project.path)], scheme)
    }

    private var authenticationArgs: [String] {
        guard needsASCKey, !app.ios.ascKeyPath.trimmed.isEmpty else { return [] }
        return [
            "-authenticationKeyPath \(shq(expandPath(app.ios.ascKeyPath).path))",
            "-authenticationKeyID \(shq(app.ios.ascKeyID.trimmed))",
            "-authenticationKeyIssuerID \(shq(app.ios.ascIssuerID.trimmed))",
        ]
    }

    func reactNativeArchiveCommand() throws -> String {
        let container = try iosContainerArgs()
        let configuration = rn.iosConfiguration.trimmed.isEmpty ? "Release" : rn.iosConfiguration.trimmed
        let archive = iosArchiveDirectory.appendingPathComponent("\(container.scheme).xcarchive")
        var parts = ["xcodebuild archive"] + container.args + [
            "-scheme \(shq(container.scheme))",
            "-configuration \(shq(configuration))",
            "-destination 'generic/platform=iOS'",
            "-archivePath \(shq(archive.path))",
            "-allowProvisioningUpdates",
        ] + authenticationArgs
        if app.ios.signing == .automatic, !app.ios.teamID.trimmed.isEmpty {
            parts.append("DEVELOPMENT_TEAM=\(shq(app.ios.teamID.trimmed))")
        }
        if let versionOverride {
            parts.append("MARKETING_VERSION=\(shq(versionOverride.name))")
            if let number = versionOverride.number { parts.append("CURRENT_PROJECT_VERSION=\(shq(number))") }
        }
        parts.append(rn.extraXcodebuildArgs.trimmed)
        return join(parts)
    }

    /// Only used when the build isn't uploaded; uploads export straight from the archive.
    func reactNativeExportCommand(exportOptions: URL) throws -> String {
        let archive = try newestItem(withExtension: "xcarchive", under: iosArchiveDirectory)
        hooks.log("The .ipa is written to \(iosIPADirectory.path)\n")
        return join([
            "xcodebuild -exportArchive",
            "-archivePath \(shq(archive.path))",
            "-exportOptionsPlist \(shq(exportOptions.path))",
            "-exportPath \(shq(iosIPADirectory.path))",
            "-allowProvisioningUpdates",
        ] + authenticationArgs)
    }
}
