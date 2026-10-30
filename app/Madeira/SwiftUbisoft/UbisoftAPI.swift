// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security

// Ubisoft's ubi-services (docs/UBISOFT.md): the same HTTPS endpoints Ubisoft
// Connect and the connect.ubisoft.com web login use, and that the GOG Galaxy
// Uplay integration (FriendsOfGalaxy/galaxy-integration-uplay) uses on the
// desktop. Sign-in is Ubisoft's own web login: when it finishes, the page's
// local storage holds the session ticket and the remember-me ticket, which
// Madeira reads and keeps in one Keychain item. Madeira never sees or stores
// the account password, and two-factor sign-ins complete inside the web view.
// Tickets are bound to the app id they were issued for, so every call sends
// the same club app id the web login used. Log lines name methods and short
// reason codes only, never a ticket, name or account id.

/// The signed-in account, as stored in the Keychain.
struct UbisoftSession: Codable, Sendable {
    var userId: String
    var username: String
    var ticket: String
    var sessionId: String
    var rememberMeTicket: String?
    /// When the ticket stops being accepted; nil when Ubisoft did not say.
    var expiration: Date?
}

enum UbisoftAPIError: LocalizedError, Equatable {
    case signedOut
    case http(Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to Ubisoft Connect to continue."
        case .http(let status): return "Ubisoft's server answered with HTTP \(status). Try again later."
        case .invalid(let what): return "Ubisoft sent an unexpected answer (\(what))."
        }
    }

    /// Short and credential-free, for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .http(let status): return "http-\(status)"
        case .invalid(let what): return "invalid-\(what)"
        }
    }
}

/// One game the account owns (the club GraphQL "Game" node).
struct UbisoftOwnedGameRaw: Sendable, Hashable {
    /// The GraphQL game id: for most PC games the Uplay product id, as text.
    var productId: String
    var spaceId: String
    var name: String
    /// The owned platform groups' platform types ("PC", "XBOX", ...).
    var platforms: [String]
    var isPC: Bool { platforms.contains("PC") }
}

/// The Keychain item: service `madeira.ubisoft.tokens`, this device only, while unlocked.
enum UbisoftTokenStore {
    private static let service = "madeira.ubisoft.tokens"
    private static let account = "session"

    static func load() -> UbisoftSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(UbisoftSession.self, from: data)
    }

    @discardableResult static func save(_ session: UbisoftSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                   kSecAttrSynchronizable as String: false]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

actor UbisoftAPI {
    static let shared = UbisoftAPI()

    // The Ubisoft Club / Connect web app id: the ticket the web login issues is
    // bound to it, so session, refresh and GraphQL calls all send it (the GOG
    // Galaxy Uplay integration's CLUB_APPID / CLUB_GENOME_ID).
    static let appId = "b8fde481-327d-4031-85ce-7c10a202a700"
    static let genomeId = "fbd6791c-a6c6-4206-a75e-77234080b87b"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private static let servicesHost = "https://public-ubiservices.ubi.com"

    /// Ubisoft's web login; when it finishes the browser lands on /ready with
    /// the session in local storage (see `captureScript`).
    static let loginURL: URL = {
        let next = "https://connect.ubisoft.com/ready".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://connect.ubisoft.com/login?appId=\(appId)&genomeId=\(genomeId)&lang=en-US&nextUrl=\(next)")!
    }()
    static func isReadyPage(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased() == "connect.ubisoft.com" else { return false }
        return url.path.lowercased().hasPrefix("/ready") || url.path.lowercased().hasPrefix("/change_domain")
    }

    /// Reads the three local-storage items the web login leaves behind. Run in
    /// the login web view once it reaches the ready page; the result is a JSON
    /// text `session(fromCapture:)` understands.
    static let captureScript = """
        (function() {
          try {
            return JSON.stringify({
              loginData: localStorage.getItem('PRODloginData'),
              rememberMe: localStorage.getItem('PRODrememberMe'),
              lastProfile: localStorage.getItem('PRODlastProfile')
            });
          } catch (e) { return ''; }
        })()
        """

    /// A session from a capture text: the storage values merged, each itself a
    /// JSON object (or a JSON text naming one). The ticket, session id and user
    /// id must all be there; the remember-me ticket and the user name are
    /// taken when present. Pure, so the host checks can drive it.
    static func session(fromCapture text: String) -> UbisoftSession? {
        guard let data = text.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var merged: [String: Any] = [:]
        for key in ["loginData", "rememberMe", "lastProfile"] {
            guard let raw = outer[key] else { continue }
            if let object = raw as? [String: Any] {
                for (name, value) in object where merged[name] == nil { merged[name] = value }
            } else if let string = raw as? String, let inner = string.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] {
                for (name, value) in object where merged[name] == nil { merged[name] = value }
            }
        }
        guard let ticket = merged["ticket"] as? String, !ticket.isEmpty,
              let sessionId = merged["sessionId"] as? String, !sessionId.isEmpty,
              let userId = merged["userId"] as? String, !userId.isEmpty else { return nil }
        return UbisoftSession(userId: userId,
                              username: (merged["nameOnPlatform"] as? String) ?? (merged["username"] as? String) ?? "",
                              ticket: ticket, sessionId: sessionId,
                              rememberMeTicket: merged["rememberMeTicket"] as? String,
                              expiration: (merged["expiration"] as? String).flatMap(parseDate))
    }

    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private let http: URLSession
    private var session: UbisoftSession?
    private var loaded = false
    private var refreshing: Task<UbisoftSession, Error>?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        http = URLSession(configuration: config)
    }

    private func stored() -> UbisoftSession? {
        if !loaded { session = UbisoftTokenStore.load(); loaded = true }
        return session
    }

    /// The stored account, if any, without contacting Ubisoft.
    func account() -> (id: String, name: String)? {
        stored().map { ($0.userId, $0.username) }
    }

    // MARK: Sign-in

    /// Stores a session captured from the web login, then proves it with a
    /// ticket refresh; a capture Ubisoft no longer accepts is a sign-out.
    func signIn(capture: UbisoftSession) async throws -> UbisoftSession {
        session = capture; loaded = true
        UbisoftTokenStore.save(capture)
        do {
            let fresh = try await refreshTicket()
            UbisoftLog.event("[ubisoft-signin] signed in")
            return fresh
        } catch {
            // The captured ticket may already be spent (the page sat open);
            // the remember-me ticket is the second chance before giving up.
            if capture.rememberMeTicket != nil {
                let fresh = try await refreshRememberMe()
                UbisoftLog.event("[ubisoft-signin] signed in via remember-me")
                return fresh
            }
            throw error
        }
    }

    func signOut() {
        refreshing?.cancel(); refreshing = nil
        session = nil; loaded = true
        UbisoftTokenStore.delete()
        UbisoftLog.event("[ubisoft-signin] signed out")
    }

    /// A session whose ticket is good for at least five more minutes.
    func validSession() async throws -> UbisoftSession {
        guard let current = stored() else { throw UbisoftAPIError.signedOut }
        if let expiration = current.expiration, expiration.timeIntervalSinceNow > 300 { return current }
        if let expiration = current.expiration, expiration.timeIntervalSinceNow > 0, current.rememberMeTicket == nil { return current }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refreshWithFallback() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refreshWithFallback() async throws -> UbisoftSession {
        do { return try await refreshTicket() }
        catch UbisoftAPIError.signedOut {
            signOut()
            throw UbisoftAPIError.signedOut
        } catch {
            guard stored()?.rememberMeTicket != nil else { throw error }
            do { return try await refreshRememberMe() }
            catch UbisoftAPIError.signedOut {
                signOut()
                throw UbisoftAPIError.signedOut
            }
        }
    }

    /// PUT /v3/profiles/sessions with the current ticket (ticket refresh).
    private func refreshTicket() async throws -> UbisoftSession {
        guard let current = stored() else { throw UbisoftAPIError.signedOut }
        var request = URLRequest(url: URL(string: Self.servicesHost + "/v3/profiles/sessions")!)
        request.httpMethod = "PUT"
        applyHeaders(&request, authorization: "Ubi_v1 t=\(current.ticket)", sessionId: current.sessionId)
        return try await adopt(request, method: "refresh-ticket")
    }

    /// POST /v3/profiles/sessions with the remember-me ticket (rm_v1).
    private func refreshRememberMe() async throws -> UbisoftSession {
        guard let current = stored(), let remember = current.rememberMeTicket else { throw UbisoftAPIError.signedOut }
        var request = URLRequest(url: URL(string: Self.servicesHost + "/v3/profiles/sessions")!)
        request.httpMethod = "POST"
        applyHeaders(&request, authorization: "rm_v1 t=\(remember)", sessionId: current.sessionId)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"rememberMe\": true}".utf8)
        return try await adopt(request, method: "refresh-remember-me")
    }

    /// Sends a session request and adopts its answer as the stored session.
    private func adopt(_ request: URLRequest, method: String) async throws -> UbisoftSession {
        let json = try await object(request, method: method)
        guard let ticket = json["ticket"] as? String, !ticket.isEmpty,
              let sessionId = json["sessionId"] as? String, !sessionId.isEmpty else { throw UbisoftAPIError.invalid(method) }
        var next = stored() ?? UbisoftSession(userId: "", username: "", ticket: ticket, sessionId: sessionId, rememberMeTicket: nil, expiration: nil)
        next.ticket = ticket
        next.sessionId = sessionId
        if let userId = json["userId"] as? String, !userId.isEmpty { next.userId = userId }
        if let name = (json["username"] as? String) ?? (json["nameOnPlatform"] as? String) { next.username = name }
        if let remember = json["rememberMeTicket"] as? String, !remember.isEmpty { next.rememberMeTicket = remember }
        if let expiration = json["expiration"] as? String { next.expiration = Self.parseDate(expiration) }
        session = next; loaded = true
        UbisoftTokenStore.save(next)
        return next
    }

    private func applyHeaders(_ request: inout URLRequest, authorization: String, sessionId: String?) {
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(Self.appId, forHTTPHeaderField: "Ubi-AppId")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Ubi-SessionId") }
        request.setValue("uplay", forHTTPHeaderField: "Ubi-RequestedPlatformType")
        request.setValue("https://connect.ubisoft.com", forHTTPHeaderField: "Origin")
        request.setValue("https://connect.ubisoft.com", forHTTPHeaderField: "Referer")
    }

    // MARK: Requests

    /// Sends a request and returns its body; a 401 is a sign-out, any other
    /// failure an HTTP error (ubi-services answers errors as JSON, with no
    /// stable public error code to switch on).
    private func send(_ request: URLRequest, method: String) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            UbisoftLog.event("[ubisoft-api] \(method) failed reason=http-401")
            throw UbisoftAPIError.signedOut
        }
        if status >= 400 || status == 0 {
            UbisoftLog.event("[ubisoft-api] \(method) failed reason=http-\(status)")
            throw UbisoftAPIError.http(status)
        }
        return data
    }

    private func object(_ request: URLRequest, method: String) async throws -> [String: Any] {
        let data = try await send(request, method: method)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UbisoftAPIError.invalid(method) }
        return json
    }

    private func authorized(_ url: URL, method: String) async throws -> URLRequest {
        let session = try await validSession()
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyHeaders(&request, authorization: "Ubi_v1 t=\(session.ticket)", sessionId: session.sessionId)
        return request
    }

    // MARK: Library

    /// The account's owned games (the club GraphQL AllGames query, as the
    /// Connect web app and the GOG integration send it).
    func ownedGames() async throws -> [UbisoftOwnedGameRaw] {
        var request = try await authorized(URL(string: Self.servicesHost + "/v1/profiles/me/uplay/graphql")!, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let query = "query AllGames { viewer { id ...ownedGamesList } } "
            + "fragment gameProps on Game { id spaceId name } "
            + "fragment ownedGameProps on Game { ...gameProps viewer { meta { id ownedPlatformGroups { id name type } } } } "
            + "fragment ownedGamesList on User { ownedGames: games(filterBy: {isOwned: true}) { totalCount nodes { ...ownedGameProps } } }"
        let payload: [String: Any] = ["operationName": "AllGames", "variables": ["owned": true], "query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let json = try await object(request, method: "owned-games")
        return Self.parseOwnedGames(json)
    }

    /// The owned-games GraphQL answer → the games, PC and otherwise. The
    /// platform groups arrive either as groups of platform objects or as one
    /// flat list; both shapes are read. Pure, so the host checks can drive it.
    static func parseOwnedGames(_ json: [String: Any]) -> [UbisoftOwnedGameRaw] {
        let viewer = (json["data"] as? [String: Any])?["viewer"] as? [String: Any]
        let owned = viewer?["ownedGames"] as? [String: Any]
        let nodes = owned?["nodes"] as? [[String: Any]] ?? []
        var games: [UbisoftOwnedGameRaw] = []
        for node in nodes {
            guard let spaceId = node["spaceId"] as? String, !spaceId.isEmpty,
                  let name = node["name"] as? String, !name.isEmpty else { continue }
            var platforms: [String] = []
            let meta = ((node["viewer"] as? [String: Any])?["meta"] as? [String: Any])
            for group in meta?["ownedPlatformGroups"] as? [Any] ?? [] {
                if let platform = group as? [String: Any], let type = platform["type"] as? String {
                    platforms.append(type)
                } else if let members = group as? [[String: Any]] {
                    for platform in members { if let type = platform["type"] as? String { platforms.append(type) } }
                }
            }
            games.append(UbisoftOwnedGameRaw(productId: node["id"] as? String ?? "",
                                             spaceId: spaceId, name: name, platforms: platforms))
        }
        return games
    }
}

enum UbisoftLog {
    static func event(_ message: String) {
        LogStore.shared.log(message)
    }
}
