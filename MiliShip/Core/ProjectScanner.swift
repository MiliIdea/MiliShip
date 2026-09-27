import Foundation

struct DetectedReactNative: Hashable {
    let usesExpo: Bool
    /// Expo app without committed native folders: `expo prebuild` generates them.
    let needsPrebuild: Bool
    let installCommand: String
    let podInstallCommand: String
    let iosWorkspace: String?
    let iosScheme: String?
}

struct DetectedProject: Identifiable, Hashable {
    var id: String { appPath }
    let framework: AppFramework
    let appPath: String
    let packageName: String
    let version: String?
    let hasAndroid: Bool
    let hasIOS: Bool
    let androidApplicationID: String?
    let iosBundleID: String?
    let iosTeamID: String?
    let usesShorebird: Bool
    let entryPoints: [String]
    let dartDefineFiles: [String]
    let exportOptionsFiles: [String]
    var reactNative: DetectedReactNative? = nil
}

struct RepoScan {
    let usesMelos: Bool
    let usesFVM: Bool
    let projects: [DetectedProject]
}

/// Finds Flutter applications (pubspec.yaml with `sdk: flutter` and an android/ or ios/ folder) and
/// React Native applications (package.json depending on react-native, with native folders or Expo)
/// anywhere in a repository — single apps and monorepos alike.
enum ProjectScanner {
    private static let skippedFolders: Set<String> = [
        "build", "Pods", "node_modules", "ephemeral", "DerivedData", "vendor",
    ]

    static func scan(repo: URL) -> RepoScan {
        let fm = FileManager.default
        var projects: [DetectedProject] = []
        let rootDepth = repo.standardizedFileURL.pathComponents.count

        if let enumerator = fm.enumerator(
            at: repo,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    let depth = url.standardizedFileURL.pathComponents.count - rootDepth
                    if skippedFolders.contains(url.lastPathComponent) || depth > 5 { enumerator.skipDescendants() }
                    continue
                }
                if url.lastPathComponent == "pubspec.yaml", let project = inspect(pubspec: url, repo: repo) {
                    projects.append(project)
                } else if url.lastPathComponent == "package.json", let project = inspect(packageJSON: url, repo: repo) {
                    projects.append(project)
                }
            }
        }

        projects.sort { lhs, rhs in
            let l = lhs.appPath.split(separator: "/").count, r = rhs.appPath.split(separator: "/").count
            return l == r ? lhs.appPath < rhs.appPath : l < r
        }

        let rootPubspec = (try? String(contentsOf: repo.appendingPathComponent("pubspec.yaml"), encoding: .utf8)) ?? ""
        let usesMelos = fm.fileExists(atPath: repo.appendingPathComponent("melos.yaml").path)
            || rootPubspec.range(of: #"(?m)^melos:"#, options: .regularExpression) != nil
        let usesFVM = fm.fileExists(atPath: repo.appendingPathComponent(".fvmrc").path)
            || fm.fileExists(atPath: repo.appendingPathComponent(".fvm/fvm_config.json").path)

        return RepoScan(usesMelos: usesMelos, usesFVM: usesFVM, projects: projects)
    }

    static func pubspecVersion(in appDir: URL) -> String? {
        guard let text = try? String(contentsOf: appDir.appendingPathComponent("pubspec.yaml"), encoding: .utf8) else { return nil }
        return firstMatch(#"(?m)^version:\s*([^\s#]+)"#, in: text)
    }

    private static func inspect(pubspec: URL, repo: URL) -> DetectedProject? {
        guard let text = try? String(contentsOf: pubspec, encoding: .utf8),
              text.range(of: #"sdk:\s*flutter"#, options: .regularExpression) != nil
        else { return nil }

        let fm = FileManager.default
        let dir = pubspec.deletingLastPathComponent()
        let hasAndroid = fm.fileExists(atPath: dir.appendingPathComponent("android/app").path)
        let hasIOS = fm.fileExists(atPath: dir.appendingPathComponent("ios/Runner.xcodeproj").path)
        guard hasAndroid || hasIOS else { return nil } // a package, not an app

        let gradle = ["android/app/build.gradle.kts", "android/app/build.gradle"]
            .lazy
            .compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
            .first
        let pbxproj = try? String(
            contentsOf: dir.appendingPathComponent("ios/Runner.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        let libFiles = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("lib").path)) ?? []
        let entryPoints = libFiles
            .filter { $0.hasPrefix("main") && $0.hasSuffix(".dart") }
            .sorted()
            .map { "lib/\($0)" }

        return DetectedProject(
            framework: .flutter,
            appPath: relativePath(of: dir, in: repo),
            packageName: firstMatch(#"(?m)^name:\s*([A-Za-z0-9_]+)"#, in: text) ?? dir.lastPathComponent,
            version: firstMatch(#"(?m)^version:\s*([^\s#]+)"#, in: text),
            hasAndroid: hasAndroid,
            hasIOS: hasIOS,
            androidApplicationID: gradle.flatMap { firstMatch(#"applicationId\s*=?\s*["']([^"']+)["']"#, in: $0) },
            iosBundleID: pbxproj.flatMap { mainBundleID(in: $0) },
            iosTeamID: pbxproj.flatMap { firstMatch(#"DEVELOPMENT_TEAM = "?([A-Z0-9]{10})"?;"#, in: $0) },
            usesShorebird: fm.fileExists(atPath: dir.appendingPathComponent("shorebird.yaml").path),
            entryPoints: entryPoints,
            dartDefineFiles: files(in: dir, depth: 2) { name in
                let lower = name.lowercased()
                return (lower.contains("dart_define") || lower.contains("dart-define")) && !lower.hasSuffix(".dart")
            },
            exportOptionsFiles: files(in: dir.appendingPathComponent("ios"), depth: 1) {
                $0.hasPrefix("ExportOptions") && $0.hasSuffix(".plist")
            }.map { "ios/\($0)" }
        )
    }

    private static func inspect(packageJSON url: URL, repo: URL) -> DetectedProject? {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let dependencies = ["dependencies", "devDependencies"]
            .compactMap { json[$0] as? [String: Any] }
            .reduce(into: [String: Any]()) { $0.merge($1) { a, _ in a } }
        guard dependencies["react-native"] != nil else { return nil }

        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let usesExpo = dependencies["expo"] != nil
        let hasAndroidDir = fm.fileExists(atPath: dir.appendingPathComponent("android/app").path)
        let workspace = ReactNativeProject.workspace(in: dir)
        let hasIOSDir = workspace != nil || ReactNativeProject.xcodeproj(in: dir) != nil
        // Expo apps using continuous native generation have no native folders until prebuild.
        let needsPrebuild = usesExpo && !hasAndroidDir && !hasIOSDir
        guard hasAndroidDir || hasIOSDir || needsPrebuild else { return nil } // a library, not an app

        let expoConfig = readExpoConfig(in: dir)
        let gradle = ReactNativeProject.gradleText(in: dir)
        let pbxproj = ReactNativeProject.xcodeproj(in: dir).flatMap {
            try? String(contentsOf: $0.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        }
        let name = (expoConfig?["name"] as? String) ?? (json["name"] as? String) ?? dir.lastPathComponent
        let podCommand = fm.fileExists(atPath: dir.appendingPathComponent("Gemfile").path)
            ? "bundle install && bundle exec pod install"
            : "pod install"

        return DetectedProject(
            framework: .reactNative,
            appPath: relativePath(of: dir, in: repo),
            packageName: name,
            version: ReactNativeProject.nativeVersion(in: dir)?.full
                ?? (expoConfig?["version"] as? String) ?? (json["version"] as? String),
            hasAndroid: hasAndroidDir || needsPrebuild,
            hasIOS: hasIOSDir || needsPrebuild,
            androidApplicationID: gradle.flatMap { firstMatch(#"applicationId\s*=?\s*["']([^"']+)["']"#, in: $0) }
                ?? ((expoConfig?["android"] as? [String: Any])?["package"] as? String),
            iosBundleID: pbxproj.flatMap { mainBundleID(in: $0) }
                ?? ((expoConfig?["ios"] as? [String: Any])?["bundleIdentifier"] as? String),
            iosTeamID: pbxproj.flatMap { firstMatch(#"DEVELOPMENT_TEAM = "?([A-Z0-9]{10})"?;"#, in: $0) },
            usesShorebird: false,
            entryPoints: [],
            dartDefineFiles: [],
            exportOptionsFiles: files(in: dir.appendingPathComponent("ios"), depth: 1) {
                $0.hasPrefix("ExportOptions") && $0.hasSuffix(".plist")
            }.map { "ios/\($0)" },
            reactNative: DetectedReactNative(
                usesExpo: usesExpo,
                needsPrebuild: needsPrebuild,
                installCommand: installCommand(for: dir, repo: repo),
                podInstallCommand: podCommand,
                iosWorkspace: workspace.map { relativePath(of: $0, in: dir) },
                iosScheme: workspace?.deletingPathExtension().lastPathComponent
            )
        )
    }

    /// The `expo` object from app.json (app.config.js / .ts can't be read without running node).
    private static func readExpoConfig(in dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("app.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return json["expo"] as? [String: Any]
    }

    /// Picks the install command from the nearest lock file, walking up to the repository root (monorepos).
    private static func installCommand(for dir: URL, repo: URL) -> String {
        let fm = FileManager.default
        let root = repo.standardizedFileURL.path
        var current = dir.standardizedFileURL
        while true {
            func has(_ name: String) -> Bool { fm.fileExists(atPath: current.appendingPathComponent(name).path) }
            if has("pnpm-lock.yaml") { return "pnpm install --frozen-lockfile" }
            if has("bun.lockb") || has("bun.lock") { return "bun install --frozen-lockfile" }
            if has("yarn.lock") { return has(".yarnrc.yml") ? "yarn install --immutable" : "yarn install --frozen-lockfile" }
            if has("package-lock.json") { return "npm ci" }
            if current.path == root || current.pathComponents.count <= 1 || !current.path.hasPrefix(root) { break }
            current = current.deletingLastPathComponent()
        }
        return "npm install"
    }

    /// Shortest bundle identifier that isn't a test target or unresolved build setting.
    static func mainBundleID(in pbxproj: String) -> String? {
        allMatches(#"PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;"#, in: pbxproj)
            .filter { !$0.contains("Tests") && !$0.contains("$(") }
            .min { $0.count < $1.count }
    }

    private static func files(in dir: URL, depth: Int, matching: @escaping (String) -> Bool) -> [String] {
        var result: [String] = []
        func walk(_ url: URL, _ prefix: String, _ level: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
            for item in items.sorted() where !item.hasPrefix(".") && !skippedFolders.contains(item) {
                let child = url.appendingPathComponent(item)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    if level < depth { walk(child, prefix + item + "/", level + 1) }
                } else if matching(item) {
                    result.append(prefix + item)
                }
            }
        }
        walk(dir, "", 1)
        return result
    }

    private static func relativePath(of dir: URL, in repo: URL) -> String {
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let r = repo.standardizedFileURL.resolvingSymlinksInPath().path
        if d == r { return "." }
        if d.hasPrefix(r + "/") { return String(d.dropFirst(r.count + 1)) }
        return dir.lastPathComponent
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
