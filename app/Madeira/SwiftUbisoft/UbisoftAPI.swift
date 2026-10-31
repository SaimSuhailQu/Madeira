// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security

// Ubisoft's ubi-services (docs/UBISOFT.md): the same HTTPS endpoints Ubisoft
// Connect and the connect.ubisoft.com web login use, and that the GOG Galaxy
// Uplay integration (FriendsOfGalaxy/galaxy-integration-uplay) uses on the
// desktop. Sign-in is direct by default: the account's email and password go
// to Ubisoft's session service in one HTTPS call — the login its own mobile
// app makes — and Madeira keeps only the ticket that buys, in one Keychain
// item; the password itself is never stored or logged. (The older web-page
// sign-in remains as a fallback; there the password stays inside Ubisoft's
// page and is never seen at all.) Two-factor codes complete the same call.
// Tickets are bound to the app id they were issued for, so session calls
// send the club app id, exchanging a ticket first when it was issued under
// another app id. Log lines name methods and short reason codes only, never
// a ticket, name or account id.

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
    /// The credentials (or a 2FA code) were refused by the session service.
    case rejected(Int)
    /// The login needs the account's 2-Step Verification code next. The
    /// pending exchange is kept inside the API actor, not in this value.
    case twoFactor

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to Ubisoft Connect to continue."
        case .http(let status): return "Ubisoft's server answered with HTTP \(status). Try again later."
        case .invalid(let what): return "Ubisoft sent an unexpected answer (\(what))."
        case .rejected: return "Ubisoft refused those sign-in details. Check them and try again."
        case .twoFactor: return "Enter the 2-Step Verification code for this account."
        }
    }

    /// Short and credential-free, for the log.
    var reason: String {
        switch self {
        case .signedOut: return "signed-out"
        case .http(let status): return "http-\(status)"
        case .invalid(let what): return "invalid-\(what)"
        case .rejected(let status): return "rejected-\(status)"
        case .twoFactor: return "two-factor"
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
            var object: [String: Any]?
            if let dict = raw as? [String: Any] { object = dict }
            else if let string = raw as? String, let inner = string.data(using: .utf8) {
                object = try? JSONSerialization.jsonObject(with: inner) as? [String: Any]
            }
            guard let object else { continue }
            for (name, value) in object where merged[name] == nil { merged[name] = value }
            // Ubisoft has nested the payload before; a key missing at the top
            // level is looked for one level down rather than giving up.
            for name in ["ticket", "sessionId", "userId", "rememberMeTicket", "nameOnPlatform", "username", "expiration"]
            where merged[name] == nil {
                if let value = deepValue(name, in: object) { merged[name] = value }
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

    /// The first value stored under `key` anywhere inside a parsed JSON value.
    private static func deepValue(_ key: String, in value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if let hit = dict[key] { return hit }
            for child in dict.values { if let hit = deepValue(key, in: child) { return hit } }
        } else if let array = value as? [Any] {
            for child in array { if let hit = deepValue(key, in: child) { return hit } }
        }
        return nil
    }

    /// Which of the capture's storage items carried anything, as short labels
    /// for the log and the sign-in sheet's status line — never values.
    static func captureParts(in text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let labels = ["loginData": "login", "rememberMe": "remember", "lastProfile": "profile"]
        return labels.filter { key, _ in
            if let string = outer[key] as? String { return !string.isEmpty && string != "null" }
            return outer[key] is [String: Any]
        }.map { $0.value }.sorted()
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
        pendingTwoFactor = nil
        session = nil; loaded = true
        UbisoftTokenStore.delete()
        UbisoftLog.event("[ubisoft-signin] signed out")
    }

    // MARK: Direct sign-in

    /// The app id Ubisoft's own mobile app presents for password logins —
    /// the documented first hop for credential sign-in. Used only when the
    /// club app id refuses a password login; that session is then exchanged
    /// for a club-bound one before anything is stored.
    static let authAppId = "4391c956-8943-48eb-8859-07b0778f47b9"

    /// A 2-Step Verification exchange in flight: the limited ticket and the
    /// app id the password login used (the completion must use the same).
    private var pendingTwoFactor: (ticket: String, clubDirect: Bool)?

    /// Signs in with the account's email and password, sent only to
    /// Ubisoft's session service over HTTPS — the login its mobile app
    /// makes, with no web page involved. The password builds the request's
    /// Basic header and is never stored or logged; the ticket it buys is
    /// kept exactly like a web-login ticket. Throws
    /// `UbisoftAPIError.twoFactor` when the account asks for its code;
    /// then call `completeTwoFactor(code:)`.
    func signIn(email: String, password: String) async throws -> UbisoftSession {
        let basic = Data("\(email):\(password)".utf8).base64EncodedString()
        do {
            let json = try await passwordLogin(appId: Self.appId, basic: basic, method: "login-password")
            return try await finishLogin(json, clubDirect: true, method: "login-password")
        } catch UbisoftAPIError.rejected {
            // The club app id takes its logins through the web page, not a
            // password — go in through the mobile app id and exchange.
            let json = try await passwordLogin(appId: Self.authAppId, basic: basic, method: "login-password-alt")
            return try await finishLogin(json, clubDirect: false, method: "login-password-alt")
        }
    }

    /// Completes a two-factor sign-in with the account's 6-digit code.
    func completeTwoFactor(code: String) async throws -> UbisoftSession {
        guard let pending = pendingTwoFactor else { throw UbisoftAPIError.invalid("2fa-state") }
        var request = sessionsRequest(appId: pending.clubDirect ? Self.appId : Self.authAppId)
        request.httpMethod = "POST"
        request.setValue("Ubi_2fa_v1 t=\(pending.ticket)", forHTTPHeaderField: "Authorization")
        request.setValue(code, forHTTPHeaderField: "ubi-2facode")
        request.httpBody = Data("{\"rememberMe\": true}".utf8)
        let json = try await loginObject(request, method: "login-2fa")
        return try await finishLogin(json, clubDirect: pending.clubDirect, method: "login-2fa")
    }

    private func passwordLogin(appId: String, basic: String, method: String) async throws -> [String: Any] {
        var request = sessionsRequest(appId: appId)
        request.httpMethod = "POST"
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"rememberMe\": true}".utf8)
        return try await loginObject(request, method: method)
    }

    /// A login answer: a full session (adopted, exchanged first when it was
    /// issued under the mobile app id), or the two-factor ask — a 200 with
    /// no ticket but a two-factor ticket is not a failed login.
    private func finishLogin(_ json: [String: Any], clubDirect: Bool, method: String) async throws -> UbisoftSession {
        if let ticket = json["ticket"] as? String, !ticket.isEmpty {
            pendingTwoFactor = nil
            if clubDirect {
                let session = try adoptJSON(json, method: method)
                UbisoftLog.event("[ubisoft-signin] signed in (direct)")
                return session
            }
            let session = try await exchange(ticket: ticket, sessionId: json["sessionId"] as? String)
            UbisoftLog.event("[ubisoft-signin] signed in (direct)")
            return session
        }
        if let twoFactor = json["twoFactorAuthenticationTicket"] as? String, !twoFactor.isEmpty {
            pendingTwoFactor = (ticket: twoFactor, clubDirect: clubDirect)
            throw UbisoftAPIError.twoFactor
        }
        throw UbisoftAPIError.invalid(method)
    }

    /// Exchanges a session issued under another app id for one bound to the
    /// club app id (POST /v3/profiles/sessions with the ticket).
    private func exchange(ticket: String, sessionId: String?) async throws -> UbisoftSession {
        var request = sessionsRequest(appId: Self.appId)
        request.httpMethod = "POST"
        request.setValue("Ubi_v1 t=\(ticket)", forHTTPHeaderField: "Authorization")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Ubi-SessionId") }
        request.httpBody = Data("{\"rememberMe\": true}".utf8)
        return try await adopt(request, method: "login-exchange")
    }

    private func sessionsRequest(appId: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.servicesHost + "/v3/profiles/sessions")!)
        request.setValue(appId, forHTTPHeaderField: "Ubi-AppId")
        request.setValue("uplay", forHTTPHeaderField: "Ubi-RequestedPlatformType")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// The login calls' own send: a 401 or 403 here means the credentials
    /// (or the code) were refused — not the stored-session sign-out the
    /// shared send() reports.
    private func loginObject(_ request: URLRequest, method: String) async throws -> [String: Any] {
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UbisoftAPIError.rejected(status) }
        if status >= 400 || status == 0 {
            UbisoftLog.event("[ubisoft-api] \(method) failed reason=http-\(status)")
            throw UbisoftAPIError.http(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UbisoftAPIError.invalid(method) }
        return json
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
        try adoptJSON(await object(request, method: method), method: method)
    }

    /// Adopts a session payload as the stored session (refresh answers, the
    /// ticket exchange, a completed direct login).
    private func adoptJSON(_ json: [String: Any], method: String) throws -> UbisoftSession {
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
