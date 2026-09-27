import Foundation

/// Reads and edits the native projects of a React Native app (android/ and ios/ inside the app folder).
enum ReactNativeProject {
    static func gradleURL(in appDir: URL) -> URL? {
        ["android/app/build.gradle", "android/app/build.gradle.kts"]
            .map { appDir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func gradleText(in appDir: URL) -> String? {
        gradleURL(in: appDir).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The only (or first) .xcworkspace in ios/. Exists once CocoaPods ran, which RN projects commit.
    static func workspace(in appDir: URL) -> URL? {
        items(withExtension: "xcworkspace", in: appDir.appendingPathComponent("ios")).first
    }

    static func xcodeproj(in appDir: URL) -> URL? {
        items(withExtension: "xcodeproj", in: appDir.appendingPathComponent("ios"))
            .first { $0.lastPathComponent != "Pods.xcodeproj" }
    }

    private static func items(withExtension ext: String, in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".\(ext)") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: Versions

    private static let versionNamePattern = #"(versionName\s*=?\s*)["']([^"']*)["']"#
    private static let versionCodePattern = #"(versionCode\s*=?\s*)(\d+)"#

    /// versionName+versionCode from build.gradle, or MARKETING_VERSION+CURRENT_PROJECT_VERSION when there's no Android app.
    static func nativeVersion(in appDir: URL) -> VersionParts? {
        if let gradle = gradleText(in: appDir) {
            if let name = match(versionNamePattern, group: 2, in: gradle) {
                return VersionParts(name: name, number: match(versionCodePattern, group: 2, in: gradle))
            }
        }
        guard let project = xcodeproj(in: appDir),
              let pbxproj = try? String(contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8),
              let name = match(#"MARKETING_VERSION = "?([^";$]+)"?;"#, group: 1, in: pbxproj)
        else { return nil }
        return VersionParts(name: name, number: match(#"CURRENT_PROJECT_VERSION = "?(\d+)"?;"#, group: 1, in: pbxproj))
    }

    /// Rewrites every literal versionName / versionCode in build.gradle. Returns the new file contents.
    static func settingAndroidVersion(_ version: VersionParts, in gradle: String) throws -> String {
        var text = gradle
        guard match(versionNamePattern, group: 2, in: text) != nil else {
            throw MiliShipError(message: "build.gradle has no literal versionName \"…\" to replace. Use “Use the project as-is”, or write the version literally.")
        }
        text = replace(versionNamePattern, in: text, with: "$1\"\(version.name)\"")
        if let number = version.number {
            guard match(versionCodePattern, group: 2, in: text) != nil else {
                throw MiliShipError(message: "build.gradle has no literal versionCode to replace.")
            }
            text = replace(versionCodePattern, in: text, with: "$1\(number)")
        }
        return text
    }

    private static func match(_ pattern: String, group: Int, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
