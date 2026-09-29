import Foundation
import Security

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("MiliShip", isDirectory: true)
        // The app was called Cilutter before: take over its apps, history and logs.
        let legacy = base.appendingPathComponent("Cilutter", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: folder)
        }
        return ensureDirectory(folder)
    }()

    static let logs: URL = ensureDirectory(support.appendingPathComponent("logs", isDirectory: true))

    /// GitHub Actions runners and job handoff. Outside Application Support because the runner's
    /// scripts don't cope with spaces in their path.
    static let actionsHome: URL = ensureDirectory(
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".miliship", isDirectory: true)
    )
    static var runnerDistributions: URL { ensureDirectory(actionsHome.appendingPathComponent("runner/dist", isDirectory: true)) }
    static func runnerDirectory(for appID: UUID) -> URL {
        actionsHome.appendingPathComponent("runner/apps/\(appID.uuidString)", isDirectory: true)
    }
    static var runnersRoot: URL { ensureDirectory(actionsHome.appendingPathComponent("runner/apps", isDirectory: true)) }
    static var jobs: URL { ensureDirectory(actionsHome.appendingPathComponent("jobs", isDirectory: true)) }
    static var jobRequests: URL { ensureDirectory(jobs.appendingPathComponent("requests", isDirectory: true)) }
    static var jobScript: URL { ensureDirectory(actionsHome.appendingPathComponent("bin", isDirectory: true)).appendingPathComponent("miliship-job") }

    static var appsFile: URL { support.appendingPathComponent("apps.json") }
    static var historyFile: URL { support.appendingPathComponent("history.json") }
    static var seenTagsFile: URL { support.appendingPathComponent("seen_tags.json") }
    static var globalFile: URL { support.appendingPathComponent("settings.json") }

    /// ~/MiliShip/<name>-<id> — a dedicated clone per application.
    static func defaultWorkspace(for app: AppConfig) -> URL {
        let slug = app.name.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        let folder = "\(slug.isEmpty ? "app" : slug)-\(app.id.uuidString.prefix(6).lowercased())"
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let clone = home.appendingPathComponent("MiliShip", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        // Keep using clones made while the app was called Cilutter.
        let legacy = home.appendingPathComponent("Cilutter", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        let fm = FileManager.default
        return !fm.fileExists(atPath: clone.path) && fm.fileExists(atPath: legacy.path) ? legacy : clone
    }

    private static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Persistence {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Decodes saved JSON on top of a default value, so fields added in newer versions keep their defaults.
    static func merged<T: Codable>(_ defaults: T, with saved: [String: Any]) -> T? {
        guard let baseData = try? encoder.encode(defaults),
              let base = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: deepMerge(base, saved))
        else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func loadMerged<T: Codable>(_ defaults: T, from url: URL) -> T {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return defaults }
        return merged(defaults, with: saved) ?? defaults
    }

    static func loadApps() -> [AppConfig] {
        guard let data = try? Data(contentsOf: AppPaths.appsFile),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { merged(AppConfig(), with: $0) }
    }

    private static func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let nestedBase = base[key] as? [String: Any], let nestedOverride = value as? [String: Any] {
                result[key] = deepMerge(nestedBase, nestedOverride)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

// MARK: - Keychain (per application)

enum SecretKey: String, CaseIterable, Identifiable {
    case shorebirdToken
    case androidKeystorePassword
    case androidKeyPassword
    case githubToken

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shorebirdToken: return "Shorebird token"
        case .androidKeystorePassword: return "Keystore password"
        case .androidKeyPassword: return "Key password"
        case .githubToken: return "GitHub token"
        }
    }
}

enum Keychain {
    private static let service = "com.mili.MiliShip"

    /// Secrets always live in the login keychain, even when a CI script (fastlane create_keychain, setup_ci…)
    /// left a locked keychain as the default one. Otherwise macOS asks for that keychain's password.
    private static let loginKeychain: SecKeychain? = {
        let path = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        var keychain: SecKeychain?
        guard FileManager.default.fileExists(atPath: path), SecKeychainOpen(path, &keychain) == errSecSuccess else { return nil }
        return keychain
    }()

    private static func query(_ key: SecretKey, app: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(app.uuidString).\(key.rawValue)",
        ]
    }

    /// Lookups and deletes, limited to the login keychain.
    private static func search(_ key: SecretKey, app: UUID) -> [String: Any] {
        var request = query(key, app: app)
        if let loginKeychain { request[kSecMatchSearchList as String] = [loginKeychain] }
        return request
    }

    static func get(_ key: SecretKey, app: UUID) -> String? {
        read(search(key, app: app))
    }

    private static func read(_ base: [String: Any]) -> String? {
        var request = base
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: SecretKey, app: UUID) {
        SecItemDelete(search(key, app: app) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query(key, app: app)
        add[kSecValueData as String] = Data(value.utf8)
        if let loginKeychain { add[kSecUseKeychain as String] = loginKeychain }
        SecItemAdd(add as CFDictionary, nil)
    }

    enum Availability { case missing, readable, blocked }

    /// Whether a secret exists and can be read without asking. Never shows a system prompt.
    static func availability(_ key: SecretKey, app: UUID) -> Availability {
        var request = search(key, app: app)
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var attributes = request
        attributes[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess else { return .missing }
        var data = request
        data[kSecReturnData as String] = true
        return SecItemCopyMatching(data as CFDictionary, &item) == errSecSuccess ? .readable : .blocked
    }

    /// Secrets that are saved but that macOS won't hand to this build without asking — typically items
    /// written by another tool or by a build signed differently.
    static func blockedKeys(for app: UUID) -> [SecretKey] {
        SecretKey.allCases.filter { availability($0, app: app) == .blocked }
    }

    /// Reads each blocked secret once (macOS asks the user to allow it) and saves it again from this app,
    /// so later reads never prompt. Returns the keys that are still unreadable.
    @discardableResult
    static func repair(app: UUID) -> [SecretKey] {
        var failed: [SecretKey] = []
        for key in blockedKeys(for: app) {
            if let value = get(key, app: app), !value.isEmpty {
                set(value, for: key, app: app)
            } else {
                failed.append(key)
            }
        }
        return failed
    }

    static func all(for app: UUID) -> [SecretKey: String] {
        var result: [SecretKey: String] = [:]
        for key in SecretKey.allCases {
            if let value = get(key, app: app), !value.isEmpty { result[key] = value }
        }
        return result
    }

    static func removeAll(for app: UUID) {
        for key in SecretKey.allCases { set("", for: key, app: app) }
    }
}
