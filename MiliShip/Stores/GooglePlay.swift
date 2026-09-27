import Foundation
import Security

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])
}

/// Google Play Developer API v3 — publishes an .aab without fastlane.
/// Flow: service-account JWT → OAuth token → edits.insert → bundles.upload → tracks.update → edits.commit
final class GooglePlayClient: @unchecked Sendable {
    private struct ServiceAccount: Decodable {
        let client_email: String
        let private_key: String
        let token_uri: String?
    }

    let packageName: String
    private let account: ServiceAccount
    private let session: URLSession
    private var cachedToken: (value: String, expires: Date)?

    var clientEmail: String { account.client_email }

    init(serviceAccountURL: URL, packageName: String) throws {
        let data = try Data(contentsOf: serviceAccountURL)
        do {
            account = try JSONDecoder().decode(ServiceAccount.self, from: data)
        } catch {
            throw MiliShipError(message: "\(serviceAccountURL.lastPathComponent) is not a Google service account JSON key.")
        }
        self.packageName = packageName
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }

    private var base: String {
        "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/\(packageName)"
    }

    // MARK: Auth

    private func accessToken() async throws -> String {
        if let cached = cachedToken, cached.expires > Date() { return cached.value }

        let tokenURI = account.token_uri ?? "https://oauth2.googleapis.com/token"
        guard let tokenURL = URL(string: tokenURI) else { throw MiliShipError(message: "Invalid token_uri in service account JSON.") }

        let now = Int(Date().timeIntervalSince1970)
        let header = Base64URL.encode(try jsonData(["alg": "RS256", "typ": "JWT"]))
        let claims = Base64URL.encode(try jsonData([
            "iss": account.client_email,
            "scope": "https://www.googleapis.com/auth/androidpublisher",
            "aud": tokenURI,
            "iat": now,
            "exp": now + 3600,
        ] as [String: Any]))
        let signingInput = "\(header).\(claims)"

        let key = try RSAKeyLoader.privateKey(pem: account.private_key)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, Data(signingInput.utf8) as CFData, &error
        ) as Data? else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw MiliShipError(message: "Could not sign the Google token request: \(reason)")
        }
        let assertion = "\(signingInput).\(Base64URL.encode(signature))"

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)

        let json = try await send(request, authorized: false)
        guard let token = json["access_token"] as? String else {
            throw MiliShipError(message: "Google didn't return an access token.")
        }
        cachedToken = (token, Date().addingTimeInterval(3000))
        return token
    }

    // MARK: Transport

    private func send(_ original: URLRequest, authorized: Bool = true, uploadFile: URL? = nil) async throws -> [String: Any] {
        var request = original
        if authorized {
            let token = try await accessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let result: (Data, URLResponse)
        if let uploadFile {
            result = try await session.upload(for: request, fromFile: uploadFile)
        } else {
            result = try await session.data(for: request)
        }
        let (data, response) = result

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            var message = ((json["error"] as? [String: Any])?["message"] as? String)
                ?? (json["error_description"] as? String)
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            if status == 404 || message.localizedCaseInsensitiveContains("not found") {
                message += " — check the package name. Brand-new apps need their first build uploaded manually in Play Console."
            }
            if status == 403 {
                message += " — invite the service account in Play Console → Users and permissions and grant release permissions for this app."
            }
            throw MiliShipError(message: "Google Play API \(status): \(message)")
        }
        return json
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: path) else { throw MiliShipError(message: "Invalid URL \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try jsonData(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request)
    }

    // MARK: Edits

    private func insertEdit() async throws -> String {
        let json = try await call("POST", "\(base)/edits", body: [:])
        guard let id = json["id"] as? String else { throw MiliShipError(message: "Google Play didn't return an edit id.") }
        return id
    }

    private func deleteEdit(_ edit: String) async {
        _ = try? await call("DELETE", "\(base)/edits/\(edit)")
    }

    private func uploadedVersionCodes(edit: String) async throws -> [Int] {
        let bundles = try await call("GET", "\(base)/edits/\(edit)/bundles")
        let apks = (try? await call("GET", "\(base)/edits/\(edit)/apks")) ?? [:]
        let codes = (bundles["bundles"] as? [[String: Any]] ?? []) + (apks["apks"] as? [[String: Any]] ?? [])
        return codes.compactMap { ($0["versionCode"] as? NSNumber)?.intValue }
    }

    // MARK: Public API

    func latestVersionCode() async throws -> Int? {
        let edit = try await insertEdit()
        do {
            let codes = try await uploadedVersionCodes(edit: edit)
            await deleteEdit(edit)
            return codes.max()
        } catch {
            await deleteEdit(edit)
            throw error
        }
    }

    func testConnection() async throws -> String {
        let latest = try await latestVersionCode()
        let detail = latest.map { "highest versionCode \($0)" } ?? "no builds uploaded yet"
        return "Connected as \(clientEmail). \(packageName): \(detail)."
    }

    /// Uploads the bundle, assigns it to the track and commits. Returns the versionCode.
    func publish(bundle: URL, config: AndroidConfig, releaseName: String, log: @escaping (String) -> Void) async throws -> Int {
        let edit = try await insertEdit()
        log("Created Google Play edit \(edit)\n")
        do {
            let size = (try? bundle.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            log("Uploading \(bundle.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))…\n")

            let uploadPath = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/\(packageName)/edits/\(edit)/bundles?uploadType=media"
            guard let uploadURL = URL(string: uploadPath) else { throw MiliShipError(message: "Invalid upload URL") }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let uploaded = try await send(request, uploadFile: bundle)
            guard let versionCode = (uploaded["versionCode"] as? NSNumber)?.intValue else {
                throw MiliShipError(message: "Upload finished but Google Play returned no versionCode.")
            }
            log("Uploaded versionCode \(versionCode)\n")

            let track = config.track.trimmed.isEmpty ? "internal" : config.track.trimmed
            var release: [String: Any] = [
                "versionCodes": [String(versionCode)],
                "status": config.releaseStatus.rawValue,
                "name": releaseName,
            ]
            if config.releaseStatus == .inProgress {
                release["userFraction"] = min(0.99, max(0.01, config.rolloutPercent / 100))
            }
            let notes = config.releaseNotes.trimmed
            if !notes.isEmpty {
                let language = config.releaseNotesLanguage.trimmed.isEmpty ? "en-US" : config.releaseNotesLanguage.trimmed
                release["releaseNotes"] = [["language": language, "text": String(notes.prefix(500))]]
            }
            let trackPath = track.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track
            _ = try await call("PUT", "\(base)/edits/\(edit)/tracks/\(trackPath)", body: ["track": track, "releases": [release]])
            log("Assigned to track “\(track)” (\(config.releaseStatus.title))\n")

            let query = config.changesNotSentForReview ? "?changesNotSentForReview=true" : ""
            _ = try await call("POST", "\(base)/edits/\(edit):commit\(query)")
            log("Committed Google Play edit\n")
            return versionCode
        } catch {
            await deleteEdit(edit)
            throw error
        }
    }
}

// MARK: - RSA key from a PEM (PKCS#8 "BEGIN PRIVATE KEY" or PKCS#1 "BEGIN RSA PRIVATE KEY")

enum RSAKeyLoader {
    static func privateKey(pem: String) throws -> SecKey {
        let body = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard var der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            throw MiliShipError(message: "The service account private key is not valid PEM.")
        }
        if pem.contains("BEGIN PRIVATE KEY") { der = try pkcs1(fromPKCS8: der) }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw MiliShipError(message: "Could not load the service account private key: \(reason)")
        }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING privateKey }
    private static func pkcs1(fromPKCS8 der: Data) throws -> Data {
        var outer = DERReader(bytes: [UInt8](der))
        var info = DERReader(bytes: try outer.read(tag: 0x30))
        _ = try info.read(tag: 0x02)
        _ = try info.read(tag: 0x30)
        return Data(try info.read(tag: 0x04))
    }
}

private struct DERReader {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(tag: UInt8) throws -> [UInt8] {
        let invalid = MiliShipError(message: "Unexpected private key format.")
        guard index < bytes.count, bytes[index] == tag else { throw invalid }
        index += 1
        guard index < bytes.count else { throw invalid }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else { throw invalid }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard index + length <= bytes.count else { throw invalid }
        let content = Array(bytes[index..<(index + length)])
        index += length
        return content
    }
}
