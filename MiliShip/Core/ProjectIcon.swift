import AppKit

/// Finds the app's own launcher icon in its clone (Flutter and React Native layouts alike).
enum ProjectIcon {
    private static var cache: [String: (date: Date, image: NSImage?)] = [:]

    /// Cached per app folder; looked up again when the clone changes (a new checkout touches the folder).
    @MainActor
    static func image(for app: AppConfig) -> NSImage? {
        let path = app.appPath.trimmed
        let dir = path.isEmpty || path == "." ? app.workspaceURL : app.workspaceURL.appendingPathComponent(path, isDirectory: true)
        let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let hit = cache[dir.path], hit.date == date { return hit.image }
        let image = find(in: dir).flatMap { NSImage(contentsOf: $0) }
        cache[dir.path] = (date, image)
        return image
    }

    static func find(in appDir: URL) -> URL? {
        iosAppIcon(in: appDir) ?? declaredIcon(in: appDir) ?? androidLauncherIcon(in: appDir)
    }

    /// Largest image in ios/**/AppIcon.appiconset (Runner/Assets.xcassets for Flutter, <Name>/Images.xcassets for RN).
    private static func iosAppIcon(in appDir: URL) -> URL? {
        let fm = FileManager.default
        let ios = appDir.appendingPathComponent("ios")
        guard let enumerator = fm.enumerator(at: ios, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        let rootDepth = ios.pathComponents.count
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if ["Pods", "build", "DerivedData"].contains(name) || url.pathComponents.count - rootDepth > 3 {
                enumerator.skipDescendants()
                continue
            }
            guard name == "AppIcon.appiconset" else { continue }
            enumerator.skipDescendants()
            if let best = largestImage(in: url) { return best }
        }
        return nil
    }

    /// Expo's `icon` in app.json, or flutter_launcher_icons' `image_path` (pubspec.yaml / flutter_launcher_icons.yaml).
    private static func declaredIcon(in appDir: URL) -> URL? {
        var candidates: [String] = []
        if let data = try? Data(contentsOf: appDir.appendingPathComponent("app.json")),
           let expo = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["expo"] as? [String: Any] {
            candidates += [(expo["ios"] as? [String: Any])?["icon"] as? String, expo["icon"] as? String].compactMap { $0 }
        }
        for file in ["flutter_launcher_icons.yaml", "pubspec.yaml"] {
            guard let text = try? String(contentsOf: appDir.appendingPathComponent(file), encoding: .utf8) else { continue }
            candidates += ProjectScanner.allMatches(#"(?m)^\s*image_path(?:_ios)?:\s*["']?([^"'\s#]+)"#, in: text)
        }
        return candidates.lazy
            .map { appDir.appendingPathComponent($0.hasPrefix("./") ? String($0.dropFirst(2)) : $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func androidLauncherIcon(in appDir: URL) -> URL? {
        let res = appDir.appendingPathComponent("android/app/src/main/res")
        for density in ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi"] {
            for name in ["ic_launcher.png", "ic_launcher.webp", "ic_launcher_round.png", "ic_launcher_round.webp"] {
                let url = res.appendingPathComponent("mipmap-\(density)/\(name)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private static func largestImage(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .max { size($0) < size($1) }
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
