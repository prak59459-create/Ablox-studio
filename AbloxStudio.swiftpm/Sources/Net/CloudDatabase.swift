import Foundation
import Security

// Talking to the family's Firebase Realtime Database over plain HTTPS: an
// anonymous sign-in (Firebase Authentication's REST interface), reads and
// writes (the database's REST interface) and streamed changes (its
// server-sent events). No SDK, so nothing to add to the playground.

public enum CloudError: Error, Equatable, LocalizedError {
    case notConfigured
    case refused(String)
    case denied
    case http(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return L("The internet settings aren't filled in yet.")
        case let .refused(reason): return L("The database refused to sign in: {}", reason)
        case .denied: return L("The database's rules don't allow that. Check the rules in Settings → Family → Internet.")
        case let .http(status): return L("The database answered with an error ({}).", status)
        case .badResponse: return L("The database sent something Ablox didn't understand.")
        }
    }
}

// MARK: - Signing in

/// Signs this iPad in to the database as an anonymous user, and keeps it
/// signed in: the refresh token lives in the keychain, so the same iPad is
/// the same user (and keeps its friends) from one launch to the next.
public actor CloudAuth {
    private struct Stored: Codable {
        var uid: String
        var idToken: String
        var refreshToken: String
        var expires: Date
    }

    public let config: CloudConfig
    private let urlSession: URLSession
    private let account: String
    private var stored: Stored?
    private var inFlight: Task<Stored, Error>?

    public init(config: CloudConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
        account = "cloud." + (config.baseURL?.host ?? "none")
        stored = Keychain.read(account: account).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    public var uid: String? { stored?.uid }

    /// A token good for a few more minutes.
    public func token() async throws -> String {
        if let stored, stored.expires.timeIntervalSinceNow > 300 { return stored.idToken }
        if let inFlight { return try await inFlight.value.idToken }
        let previous = stored
        let task = Task { () throws -> Stored in
            if let previous {
                do {
                    return try await self.refresh(previous.refreshToken)
                } catch CloudError.refused {
                    // The user was removed from the console: start again.
                }
            }
            return try await self.signUp()
        }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        stored = fresh
        if let data = try? JSONEncoder().encode(fresh) { Keychain.write(data, account: account) }
        return fresh.idToken
    }

    /// Makes sure there is a user, and says who.
    public func signIn() async throws -> String {
        _ = try await token()
        guard let uid = stored?.uid else { throw CloudError.badResponse }
        return uid
    }

    /// Forgets this iPad's user (its friends go with it).
    public func forget() {
        stored = nil
        Keychain.delete(account: account)
    }

    private func signUp() async throws -> Stored {
        guard config.isUsable else { throw CloudError.notConfigured }
        var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp")!
        components.queryItems = [URLQueryItem(name: "key", value: config.trimmedKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.httpBody = Data(#"{"returnSecureToken":true}"#.utf8)
        let body = try await send(request)
        guard let uid = body["localId"].string, let token = body["idToken"].string, let refresh = body["refreshToken"].string else {
            throw CloudError.badResponse
        }
        let seconds = Double(body["expiresIn"].string ?? "") ?? 3600
        return Stored(uid: uid, idToken: token, refreshToken: refresh, expires: Date().addingTimeInterval(seconds))
    }

    private func refresh(_ refreshToken: String) async throws -> Stored {
        guard config.isUsable else { throw CloudError.notConfigured }
        var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token")!
        components.queryItems = [URLQueryItem(name: "key", value: config.trimmedKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Bundle.main.bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refreshToken)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let body = try await send(request)
        guard let uid = body["user_id"].string, let token = body["id_token"].string, let refresh = body["refresh_token"].string else {
            throw CloudError.badResponse
        }
        let seconds = Double(body["expires_in"].string ?? "") ?? 3600
        return Stored(uid: uid, idToken: token, refreshToken: refresh, expires: Date().addingTimeInterval(seconds))
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONValue(data: data)) ?? .null
        guard (200..<300).contains(status) else {
            // "ADMIN_ONLY_OPERATION": anonymous sign-in is switched off.
            throw CloudError.refused(body["error"]["message"].string ?? "HTTP \(status)")
        }
        return body
    }
}

/// The keychain, for the one secret Ablox keeps: the sign-in's refresh token.
enum Keychain {
    private static let service = "Ablox"

    static func read(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Reading and writing

public final class CloudDatabase: @unchecked Sendable {
    public let auth: CloudAuth
    private let base: URL
    private let urlSession: URLSession

    public init?(auth: CloudAuth, urlSession: URLSession = .shared) {
        guard let base = auth.config.baseURL else { return nil }
        self.auth = auth
        self.base = base
        self.urlSession = urlSession
    }

    private func url(_ path: String, _ query: [URLQueryItem], token: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path + ".json"), resolvingAgainstBaseURL: false)!
        components.queryItems = query + [URLQueryItem(name: "auth", value: token)]
        return components.url!
    }

    private func perform(_ method: String, _ path: String, _ query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let token = try await auth.token()
        var request = URLRequest(url: url(path, query, token: token))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data
        }
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CloudError.denied }
        guard (200..<300).contains(status) else { throw CloudError.http(status) }
        if data.isEmpty { return .null }
        return (try? JSONValue(data: data)) ?? .null
    }

    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try await perform("GET", path, query)
    }

    public func put(_ path: String, _ value: JSONValue) async throws {
        _ = try await perform("PUT", path, [URLQueryItem(name: "print", value: "silent")], body: value)
    }

    /// Several children at once; a nil-valued key removes that child.
    public func update(_ path: String, _ values: [String: JSONValue]) async throws {
        _ = try await perform("PATCH", path, [URLQueryItem(name: "print", value: "silent")], body: .object(values))
    }

    /// Adds under a new key that sorts after everything before it.
    public func add(_ path: String, _ value: JSONValue) async throws -> String {
        let answer = try await perform("POST", path, body: value)
        guard let name = answer["name"].string else { throw CloudError.badResponse }
        return name
    }

    public func delete(_ path: String) async throws {
        _ = try await perform("DELETE", path, [URLQueryItem(name: "print", value: "silent")])
    }

    /// Every change under `path`, from its whole value first, until the
    /// task is cancelled. Reconnects by itself (a token lasts an hour; a
    /// dropped network comes back), each time starting with the whole value
    /// again.
    public func stream(_ path: String) -> AsyncStream<CloudEvent> {
        AsyncStream { continuation in
            let task = Task {
                var failures = 0
                while !Task.isCancelled {
                    do {
                        let token = try await auth.token()
                        var request = URLRequest(url: url(path, [], token: token))
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = 90
                        let (bytes, response) = try await urlSession.bytes(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 || status == 403 {
                            continuation.yield(CloudEvent(kind: .cancel, path: [], data: .null))
                            throw CloudError.denied
                        }
                        guard (200..<300).contains(status) else { throw CloudError.http(status) }
                        failures = 0
                        var parser = CloudEventParser()
                        var line = [UInt8]()
                        streaming: for try await byte in bytes {
                            if byte == 10 {
                                if let event = parser.feed(String(decoding: line, as: UTF8.self)) {
                                    switch event.kind {
                                    case .cancel:
                                        // No longer allowed to read it (deleted,
                                        // or the rules changed): say so.
                                        continuation.yield(event)
                                        break streaming
                                    case .authRevoked: break streaming
                                    case .keepAlive: break
                                    case .put, .patch: continuation.yield(event)
                                    }
                                }
                                line.removeAll(keepingCapacity: true)
                            } else {
                                line.append(byte)
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        failures += 1
                    }
                    // A short wait, longer after each failure, before trying again.
                    let wait = min(30, 1 << min(failures, 5))
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
