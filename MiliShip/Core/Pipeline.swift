import Foundation

struct PipelineHooks {
    let log: (String) -> Void
    let stepStarted: @MainActor (String) -> Void
    let stepFinished: @MainActor (String, RunStatus) -> Void
    let platformStarted: @MainActor (TargetPlatform) -> Void
    let platformFinished: @MainActor (TargetPlatform, RunStatus) -> Void
    let commitResolved: @MainActor (String) -> Void
    let versionResolved: @MainActor (String) -> Void
    let result: @MainActor (String) -> Void
}

/// Generic mobile CI/CD:
/// checkout tag → resolve version → prepare → install deps → build → publish to the stores.
/// The shared flow and store uploads live here; the framework-specific build commands are in
/// Pipeline+Flutter.swift and Pipeline+ReactNative.swift.
final class BuildPipeline: @unchecked Sendable {
    let app: AppConfig
    let tag: ReleaseTag
    let platforms: [TargetPlatform]

    let secrets: [SecretKey: String]
    let hooks: PipelineHooks
    private let shell = ShellRunner()
    var env: [String: String]
    let scratch: URL

    /// Version to build instead of the one in the project (nil = build what the project says).
    var versionOverride: VersionParts?
    private var versionDisplay = ""
    var patchReleaseVersion = "latest"
    /// Files changed in the checkout for a build; restored (or removed) afterwards.
    private var fileBackups: [(url: URL, original: Data?)] = []

    init(app: AppConfig, tag: ReleaseTag, platforms: [TargetPlatform],
         secrets: [SecretKey: String], global: GlobalSettings, hooks: PipelineHooks) {
        self.app = app
        self.tag = tag
        self.platforms = platforms
        self.secrets = secrets
        self.hooks = hooks
        env = Toolchain.environment(global: global)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("miliship-\(UUID().uuidString)", isDirectory: true)
    }

    func cancel() {
        shell.cancel()
    }

    // MARK: - Derived

    var repoDir: URL { app.workspaceURL }
    var appDir: URL {
        let path = app.appPath.trimmed
        return path.isEmpty || path == "." ? repoDir : repoDir.appendingPathComponent(path, isDirectory: true)
    }
    var isFlutter: Bool { app.framework == .flutter }
    var isShorebird: Bool { app.usesShorebird }
    var isRelease: Bool { tag.mode == .release }
    private var uploadsAndroid: Bool { isRelease && app.android.upload }
    var uploadsIOS: Bool { isRelease && app.ios.upload }
    var needsASCKey: Bool { app.ios.signing == .automatic || uploadsIOS }
    private var buildTitle: String {
        switch app.framework {
        case .flutter: return isShorebird ? "shorebird \(tag.mode.rawValue)" : "flutter build"
        case .reactNative: return "build"
        }
    }

    private var preBuildCommands: [String] {
        app.preBuildCommands
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Flow

    func run() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            restoreFiles()
            try? FileManager.default.removeItem(at: scratch)
        }
        if let token = secrets[.shorebirdToken] { env["SHOREBIRD_TOKEN"] = token }

        hooks.log("Mili Ship · \(app.displayName) · \(tag.name) · \(tag.mode.title) → \(platforms.map(\.title).joined(separator: " + "))\n")

        try await step("Validate configuration") { try validateConfiguration() }

        try await step("Checkout \(tag.name)") {
            try await Git(app: app).prepareCheckout(tag: tag.name, shell: shell, env: env, log: hooks.log)
            let output = try await sh("git rev-parse --short HEAD", in: repoDir)
            let commit = output.split(whereSeparator: \.isNewline).last.map { String($0).trimmed } ?? ""
            await hooks.commitResolved(commit)
            let manifest = isFlutter ? "pubspec.yaml" : "package.json"
            guard FileManager.default.fileExists(atPath: appDir.appendingPathComponent(manifest).path) else {
                throw MiliShipError(message: "No \(manifest) at “\(app.appPath)” in \(tag.name). Check the app path.")
            }
        }

        try await step("Resolve version") { try await resolveVersion() }
        try await step("Check toolchain") { try await checkToolchain() }

        if !app.fileInjections.isEmpty {
            try await step("Copy local files") { try injectFiles() }
        }
        if !app.bootstrapCommand.trimmed.isEmpty {
            try await step("Install dependencies") { try await sh(app.bootstrapCommand.trimmed) }
        }
        if app.framework == .reactNative && app.reactNative.expoPrebuild {
            try await step("Expo prebuild") { try await sh(expoPrebuildCommand) }
        }
        let commands = preBuildCommands
        if !commands.isEmpty {
            try await step("Pre-build commands") {
                for command in commands { try await sh(command) }
            }
        }
        try await step("Clean previous artifacts") { cleanArtifacts() }

        var failures: [String] = []
        for platform in platforms {
            try Task.checkCancellation()
            await hooks.platformStarted(platform)
            do {
                switch platform {
                case .android: try await runAndroid()
                case .ios: try await runIOS()
                }
                await hooks.platformFinished(platform, .succeeded)
            } catch is CancellationError {
                await hooks.platformFinished(platform, .cancelled)
                throw CancellationError()
            } catch {
                await hooks.platformFinished(platform, .failed)
                failures.append("\(platform.title): \(error.localizedDescription)")
                hooks.log("\n✖ \(platform.title) failed — continuing with the remaining platforms.\n")
            }
        }

        if !failures.isEmpty {
            throw MiliShipError(message: failures.joined(separator: "\n"))
        }
    }

    // MARK: - Android

    private func runAndroid() async throws {
        if app.android.writesKeyProperties {
            try await step("Android · signing") {
                if isFlutter { try writeKeyProperties() } else { try prepareGradleSigning() }
            }
        }
        if !isFlutter, let versionOverride {
            try await step("Android · set version") { try applyGradleVersion(versionOverride) }
        }

        try await step("Android · \(buildTitle)") { try await sh(isFlutter ? flutterAndroidCommand() : reactNativeAndroidCommand(), in: androidBuildDirectory) }

        if uploadsAndroid {
            let track = app.android.track.trimmed.isEmpty ? "internal" : app.android.track.trimmed
            try await step("Android · publish to Google Play (\(track))") {
                let bundle = try newestItem(withExtension: "aab", under: androidBundleDirectory)
                hooks.log("Bundle: \(bundle.path)\n")
                let client = try GooglePlayClient(
                    serviceAccountURL: requireFile(app.android.serviceAccountPath, "Google Play service account JSON"),
                    packageName: requireValue(app.android.packageName, "Android package name")
                )
                let releaseName = VersionParts(parsing: versionDisplay)?.pretty ?? (versionDisplay.isEmpty ? tag.suffix : versionDisplay)
                let versionCode = try await client.publish(bundle: bundle, config: app.android, releaseName: releaseName, log: hooks.log)
                await hooks.result("Google Play: versionCode \(versionCode) → \(track) (\(app.android.releaseStatus.title))")
            }
        } else if isRelease {
            await hooks.result("Android: built \(versionDisplay) (store upload disabled)")
        } else {
            await hooks.result("Android: Shorebird patch published for release \(patchReleaseVersion)")
        }
    }

    /// Writes a file in the checkout, remembering the original so it's put back after the build.
    func writeTemporarily(_ data: Data, to url: URL) throws {
        if !fileBackups.contains(where: { $0.url == url }) {
            fileBackups.append((url, try? Data(contentsOf: url)))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func restoreFiles() {
        for backup in fileBackups.reversed() {
            if let original = backup.original {
                try? original.write(to: backup.url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: backup.url)
            }
        }
        fileBackups = []
    }

    // MARK: - iOS

    private func runIOS() async throws {
        var exportOptions = scratch
        try await step("iOS · signing & export options") {
            if needsASCKey {
                let key = try requireFile(app.ios.ascKeyPath, "App Store Connect .p8 key")
                // Picked up by Flutter/Shorebird for xcodebuild automatic signing.
                env["APP_STORE_CONNECT_API_KEY_KEY_ID"] = try requireValue(app.ios.ascKeyID, "App Store Connect Key ID")
                env["APP_STORE_CONNECT_API_KEY_ISSUER_ID"] = try requireValue(app.ios.ascIssuerID, "App Store Connect Issuer ID")
                env["APP_STORE_CONNECT_API_KEY_KEY_FILEPATH"] = key.path
                hooks.log("App Store Connect API key \(app.ios.ascKeyID.trimmed) is available to Xcode\n")
            }
            exportOptions = try writeExportOptions(destination: "export")
            hooks.log("Signing: \(app.ios.signing.title)\n")
        }

        if !isFlutter {
            if let podInstall = podInstallCommand {
                try await step("iOS · CocoaPods") { try await sh(podInstall, in: appDir.appendingPathComponent("ios")) }
            }
            try await step("iOS · archive") { try await sh(try reactNativeArchiveCommand()) }
            if !uploadsIOS {
                try await step("iOS · export .ipa") { try await sh(try reactNativeExportCommand(exportOptions: exportOptions)) }
            }
        } else {
            try await step("iOS · \(buildTitle)") { try await sh(flutterIOSCommand(exportOptions: exportOptions)) }
        }

        if uploadsIOS {
            try await step("iOS · upload to App Store Connect") {
                let archive = try newestItem(withExtension: "xcarchive", under: iosArchiveDirectory)
                hooks.log("Archive: \(archive.path)\n")
                let uploadOptions = try writeExportOptions(destination: "upload")
                let key = try requireFile(app.ios.ascKeyPath, "App Store Connect .p8 key")
                try await sh(join([
                    "xcodebuild -exportArchive",
                    "-archivePath \(shq(archive.path))",
                    "-exportOptionsPlist \(shq(uploadOptions.path))",
                    "-exportPath \(shq(scratch.appendingPathComponent("ios-upload").path))",
                    "-allowProvisioningUpdates",
                    "-authenticationKeyPath \(shq(key.path))",
                    "-authenticationKeyID \(shq(app.ios.ascKeyID.trimmed))",
                    "-authenticationKeyIssuerID \(shq(app.ios.ascIssuerID.trimmed))",
                ]))
                await hooks.result("App Store Connect: \(versionDisplay) uploaded — available in TestFlight after Apple's processing")
            }
        } else if isRelease {
            await hooks.result("iOS: built \(versionDisplay) (store upload disabled)")
        } else {
            await hooks.result("iOS: Shorebird patch published for release \(patchReleaseVersion)")
        }
    }

    func writeExportOptions(destination: String) throws -> URL {
        var options: [String: Any]
        switch app.ios.signing {
        case .automatic:
            options = [
                "method": "app-store-connect",
                "signingStyle": "automatic",
                "teamID": try requireValue(app.ios.teamID, "Apple team ID"),
                "uploadSymbols": true,
                "manageAppVersionAndBuildNumber": false,
            ]
        case .exportOptionsFile:
            let relative = try requireValue(app.ios.exportOptionsPath, "ExportOptions.plist path")
            let url = appDir.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url),
                  let parsed = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { throw MiliShipError(message: "Could not read \(url.path)") }
            options = parsed
        }
        options["destination"] = destination
        let output = scratch.appendingPathComponent("ExportOptions.\(destination).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0)
        try data.write(to: output)
        return output
    }

    // MARK: - Shared steps

    // MARK: - Output locations

    private var androidBuildDirectory: URL { isFlutter ? appDir : appDir.appendingPathComponent("android") }
    private var androidBundleDirectory: URL {
        appDir.appendingPathComponent(isFlutter ? "build/app/outputs/bundle" : "android/app/build/outputs/bundle")
    }
    var iosArchiveDirectory: URL { appDir.appendingPathComponent(isFlutter ? "build/ios/archive" : "ios/build/miliship-archive") }
    var iosIPADirectory: URL { appDir.appendingPathComponent(isFlutter ? "build/ios/ipa" : "ios/build/miliship-ipa") }

    private func validateConfiguration() throws {
        if isShorebird && secrets[.shorebirdToken] == nil {
            hooks.log("⚠︎ No Shorebird token stored — relying on `shorebird login` on this Mac.\n")
        }
        if platforms.contains(.android) {
            if app.android.writesKeyProperties {
                _ = try requireFile(app.android.keystorePath, app.android.signing == .ownKey ? "Android signing keystore" : "Android upload keystore")
                _ = try requireValue(app.android.keyAlias, "Android key alias")
                _ = try requireSecret(.androidKeystorePassword)
            }
            if uploadsAndroid {
                _ = try requireFile(app.android.serviceAccountPath, "Google Play service account JSON")
                _ = try requireValue(app.android.packageName, "Android package name")
            }
        }
        if platforms.contains(.ios) {
            if needsASCKey {
                _ = try requireValue(app.ios.ascKeyID, "App Store Connect Key ID")
                _ = try requireValue(app.ios.ascIssuerID, "App Store Connect Issuer ID")
                _ = try requireFile(app.ios.ascKeyPath, "App Store Connect .p8 key")
            }
            if app.ios.signing == .automatic { _ = try requireValue(app.ios.teamID, "Apple team ID") }
            if app.ios.signing == .exportOptionsFile { _ = try requireValue(app.ios.exportOptionsPath, "ExportOptions.plist path") }
        }
        for injection in app.fileInjections {
            _ = try requireFile(injection.source, "Local file for \(injection.destination)")
        }
        hooks.log("Configuration OK\n")
    }

    private func resolveVersion() async throws {
        let source = app.framework.versionSource
        let pubspecRaw = isFlutter ? ProjectScanner.pubspecVersion(in: appDir) : ReactNativeProject.nativeVersion(in: appDir)?.full
        let pubspec = pubspecRaw.flatMap { VersionParts(parsing: $0) }
        let tagVersion = tag.version
        let tagRaw = tag.suffix.hasPrefix("v") ? String(tag.suffix.dropFirst()) : tag.suffix
        hooks.log("Version in \(source): \(pubspecRaw ?? "not set") · tag: \(tag.suffix)\n")

        if tag.mode == .patch {
            if let tagVersion, tagVersion.number != nil {
                patchReleaseVersion = tagVersion.full
            } else if let tagVersion, let pubspec, pubspec.name == tagVersion.name, pubspec.number != nil {
                patchReleaseVersion = pubspec.full
            } else {
                patchReleaseVersion = "latest"
            }
            versionDisplay = "patch for \(patchReleaseVersion)"
            hooks.log("Shorebird patch targets release \(patchReleaseVersion)\n")
            await hooks.versionResolved(versionDisplay)
            return
        }

        versionDisplay = pubspecRaw ?? source
        switch app.versionStrategy {
        case .pubspec:
            break

        case .pubspecMatchesTag:
            guard let pubspecRaw else { throw MiliShipError(message: "No version found in \(source).") }
            let matches = tagRaw == pubspecRaw || (tagVersion?.number == nil && pubspecRaw.hasPrefix(tagRaw + "+"))
            guard matches else {
                throw MiliShipError(message: "Tag version \(tagRaw) doesn't match \(source) (\(pubspecRaw)). Bump the version or re-tag.")
            }

        case .tag:
            guard let tagVersion else {
                throw MiliShipError(message: "Tag \(tag.name) doesn't contain a version like 1.2.0+45.")
            }
            versionOverride = tagVersion
            versionDisplay = tagVersion.number == nil ? "\(tagVersion.name)+\(pubspec?.number ?? "?")" : tagVersion.full

        case .storeIncrement:
            guard let name = tagVersion?.name ?? pubspec?.name else {
                throw MiliShipError(message: "No version name in the tag or in \(source).")
            }
            var numbers: [Int] = []
            if let number = pubspec?.number.flatMap({ Int($0) }) { numbers.append(number) }
            if platforms.contains(.android), !app.android.serviceAccountPath.trimmed.isEmpty {
                let client = try GooglePlayClient(
                    serviceAccountURL: requireFile(app.android.serviceAccountPath, "Google Play service account JSON"),
                    packageName: requireValue(app.android.packageName, "Android package name")
                )
                let latest = try await client.latestVersionCode()
                hooks.log("Google Play highest versionCode: \(latest.map { String($0) } ?? "none")\n")
                if let latest { numbers.append(latest) }
            }
            if platforms.contains(.ios), !app.ios.ascKeyPath.trimmed.isEmpty, !app.ios.bundleID.trimmed.isEmpty {
                let latest = try await AppStoreConnectClient(config: app.ios).latestBuildNumber(bundleID: app.ios.bundleID.trimmed)
                hooks.log("App Store Connect latest build number: \(latest.map { String($0) } ?? "none")\n")
                if let latest { numbers.append(latest) }
            }
            let next = (numbers.max() ?? 0) + 1
            versionOverride = VersionParts(name: name, number: String(next))
            versionDisplay = "\(name)+\(next)"
        }

        hooks.log("Building version \(versionDisplay)\n")
        await hooks.versionResolved(versionDisplay)
    }

    private func checkToolchain() async throws {
        let tools = isFlutter ? flutterTools : try await reactNativeTools()
        let script = Array(NSOrderedSet(array: ["git"] + tools)).compactMap { $0 as? String }.map { tool in
            "command -v \(tool) >/dev/null 2>&1 || { echo \"Missing tool: \(tool). Add its folder in Mili Ship → Settings → Shell PATH.\"; exit 127; }"
        }.joined(separator: "\n")
        try await sh(script, in: repoDir)
        if isFlutter {
            try await sh("\(flutter) --version")
            if isShorebird { try await sh("shorebird --version") }
        } else {
            try await sh("node --version")
        }
    }

    private func injectFiles() throws {
        let fm = FileManager.default
        for injection in app.fileInjections {
            let source = try requireFile(injection.source, "Local file")
            let relative = try requireValue(injection.destination, "Destination for \(source.lastPathComponent)")
            let destination = repoDir.appendingPathComponent(relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            hooks.log("Copied \(source.lastPathComponent) → \(relative)\n")
        }
    }

    private func cleanArtifacts() {
        for directory in [androidBundleDirectory, iosArchiveDirectory, iosIPADirectory] {
            try? FileManager.default.removeItem(at: directory)
        }
        hooks.log("Removed old .aab / .xcarchive / .ipa outputs\n")
    }

    // MARK: - Arguments

    func passthrough(_ args: [String]) -> [String] {
        args.isEmpty ? [] : ["--"] + args
    }

    func join(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Plumbing

    func step(_ name: String, _ body: () async throws -> Void) async throws {
        try Task.checkCancellation()
        await hooks.stepStarted(name)
        hooks.log("\n▶ \(name)\n")
        do {
            try await body()
            await hooks.stepFinished(name, .succeeded)
        } catch is CancellationError {
            await hooks.stepFinished(name, .cancelled)
            throw CancellationError()
        } catch {
            hooks.log("✖ \(name): \(error.localizedDescription)\n")
            await hooks.stepFinished(name, .failed)
            throw error
        }
    }

    @discardableResult
    func sh(_ command: String, in directory: URL? = nil) async throws -> String {
        hooks.log("$ \(command.split(separator: "\n").first ?? "")\n")
        return try await shell.run(command, cwd: directory ?? appDir, env: env, log: hooks.log)
    }

    func newestItem(withExtension ext: String, under directory: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw MiliShipError(message: "\(directory.path) doesn't exist — the build produced no output there.")
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var newest: (url: URL, date: Date)?
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == ext else { continue }
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        guard let newest else { throw MiliShipError(message: "No .\(ext) found under \(directory.path)") }
        return newest.url
    }

    func requireSecret(_ key: SecretKey) throws -> String {
        guard let value = secrets[key], !value.isEmpty else {
            throw MiliShipError(message: "\(key.title) is not stored. Edit the application → Google Play step.")
        }
        return value
    }
}
