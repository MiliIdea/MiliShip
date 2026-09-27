import CryptoKit
import Foundation

/// Minimal App Store Connect API client: verifies the API key, finds the app and reads build numbers.
/// Uploading itself is done by `xcodebuild -exportArchive` with `destination = upload`.
final class AppStoreConnectClient: @unchecked Sendable {
    private let keyID: String
    private let issuerID: String
    private let key: P256.Signing.PrivateKey

    init(keyID: String, issuerID: String, keyURL: URL) throws {
        let pem = try String(contentsOf: keyURL, encoding: .utf8)
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw MiliShipError(message: "\(keyURL.lastPathComponent) is not a valid App Store Connect .p8 key.")
        }
        self.keyID = keyID
        self.issuerID = issuerID
    }

    convenience init(config: IOSConfig) throws {
        try self.init(
            keyID: requireValue(config.ascKeyID, "App Store Connect Key ID"),
            issuerID: requireValue(config.ascIssuerID, "App Store Connect Issuer ID"),
            keyURL: requireFile(config.ascKeyPath, "App Store Connect .p8 key")
        )
    }

    private func token() throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header = Base64URL.encode(try jsonData(["alg": "ES256", "kid": keyID, "typ": "JWT"]))
        let payload = Base64URL.encode(try jsonData([
            "iss": issuerID,
            "iat": now,
            "exp": now + 1200,
            "aud": "appstoreconnect-v1",
        ] as [String: Any]))
        let signingInput = "\(header).\(payload)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(Base64URL.encode(signature.rawRepresentation))"
    }

    private func get(_ pathAndQuery: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.appstoreconnect.apple.com\(pathAndQuery)") else {
            throw MiliShipError(message: "Invalid App Store Connect URL")
        }
        var request = URLRequest(url: url)
        let bearer = try token()
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            let first = (json["errors"] as? [[String: Any]])?.first
            let message = (first?["detail"] as? String) ?? (first?["title"] as? String) ?? "HTTP \(status)"
            let hint = status == 401 ? " — check Key ID, Issuer ID and that the .p8 belongs to this key." : ""
            throw MiliShipError(message: "App Store Connect API \(status): \(message)\(hint)")
        }
        return json
    }

    func app(bundleID: String) async throws -> (id: String, name: String) {
        let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? bundleID
        let json = try await get("/v1/apps?filter%5BbundleId%5D=\(encoded)&limit=1")
        guard let first = (json["data"] as? [[String: Any]])?.first, let id = first["id"] as? String else {
            throw MiliShipError(message: "No app with bundle ID \(bundleID) in App Store Connect (create the app record first, or the key's role can't see it).")
        }
        let name = ((first["attributes"] as? [String: Any])?["name"] as? String) ?? bundleID
        return (id, name)
    }

    /// Highest CFBundleVersion among the most recent uploads.
    func latestBuildNumber(bundleID: String) async throws -> Int? {
        let app = try await self.app(bundleID: bundleID)
        let json = try await get("/v1/builds?filter%5Bapp%5D=\(app.id)&sort=-uploadedDate&limit=50&fields%5Bbuilds%5D=version")
        let versions = (json["data"] as? [[String: Any]] ?? []).compactMap {
            ($0["attributes"] as? [String: Any])?["version"] as? String
        }
        return versions.compactMap { Int($0.split(separator: ".").last ?? "") }.max()
    }

    func testConnection(bundleID: String) async throws -> String {
        guard !bundleID.trimmed.isEmpty else {
            _ = try await get("/v1/apps?limit=1")
            return "API key works. Add the bundle ID to verify the app record."
        }
        let app = try await self.app(bundleID: bundleID.trimmed)
        let latest = try? await latestBuildNumber(bundleID: bundleID.trimmed)
        return "Connected. Found “\(app.name)”, latest build number: \(latest.map { String($0) } ?? "none yet")."
    }
}
