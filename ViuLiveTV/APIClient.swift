//
//  APIClient.swift
//  Viu Live TV
//
//  async/await URLSession client matching the decompiled viuapp v1.12 API.
//
//  Key facts baked in from the decompile:
//   - Login field is "user" (not "username").
//   - Token lives in the URL PATH for most endpoints, e.g.
//       /api/4/live-tv/links/{stream_id}/{token}
//       /api/4/accountinfo/{token}
//       /api/4/logout/{token}
//       /api/4/checkservice/{token}
//   - Channel list = EPG from epgjsonV2.php (NO token).
//   - User-Agent header must be "viutvapp/1.12 LH".
//   - Without a token many endpoints return plain text "Error 2" — so we
//     never assume a JSON body and surface a readable error instead.
//

import Foundation

enum APIError: LocalizedError {
    case badURL
    case transport(Error)
    case http(Int, String?)
    case nonJSON(String)          // body was plain text (e.g. "Error 2")
    case decoding(Error)
    case api(code: Int, message: String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .badURL:                return "Could not build the request URL."
        case .transport(let e):      return e.localizedDescription
        case .http(let code, let b): return "Server error \(code)." + (b.map { " \($0)" } ?? "")
        case .nonJSON(let body):
            let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "The server returned an unexpected response." : t
        case .decoding:              return "Could not read the server response."
        case .api(_, let message):   return message
        case .notAuthenticated:      return "You are not signed in."
        }
    }
}

actor APIClient {
    static let shared = APIClient()

    // Bases
    private let apiBase = "https://api.viu.rs/api/4/"
    private let rootBase = "https://api.viu.rs/"

    private let userAgent = "viutvapp/1.12 LH"

    private let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 40
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Token management (cached in-actor; source of truth is Keychain)

    private var cachedToken: String?

    func setToken(_ token: String?) {
        cachedToken = token
        Keychain.shared.token = token
    }

    func currentToken() -> String? {
        if let cachedToken { return cachedToken }
        let t = Keychain.shared.token
        cachedToken = t
        return t
    }

    private func requireToken() throws -> String {
        guard let t = currentToken(), !t.isEmpty else { throw APIError.notAuthenticated }
        return t
    }

    // MARK: - Low-level request

    private func makeRequest(url: URL, method: String, jsonBody: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            req.httpBody = jsonBody
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Performs the request and returns the raw Data + the decoded UTF-8 body
    /// string (used to detect "Error 2" plain-text responses).
    private func perform(_ request: URLRequest) async throws -> (Data, String, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.nonJSON(String(data: data, encoding: .utf8) ?? "")
        }
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, bodyString.isEmpty ? nil : bodyString)
        }
        return (data, bodyString, http)
    }

    /// True when a body is clearly not JSON (plain-text error like "Error 2").
    private func looksLikeJSON(_ body: String) -> Bool {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    /// Decode JSON, converting plain-text bodies into readable errors.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, body: String) throws -> T {
        guard looksLikeJSON(body) else {
            throw APIError.nonJSON(body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw APIError.decoding(error) }
    }

    // MARK: - Auth

    /// POST /api/4/authenticate  { "user": ..., "password": ... }
    func authenticate(user: String, password: String) async throws -> LoginApiCallResult {
        guard let url = URL(string: apiBase + "authenticate") else { throw APIError.badURL }
        let body = try encodeBody(["user": user, "password": password])
        let req = makeRequest(url: url, method: "POST", jsonBody: body)
        let (data, bodyStr, _) = try await perform(req)
        let result = try decode(LoginApiCallResult.self, from: data, body: bodyStr)
        if result.isSuccess, let token = result.token {
            setToken(token)
        }
        return result
    }

    /// GET /api/4/logout/{token}
    func logout() async {
        guard let token = currentToken(), !token.isEmpty,
              let url = URL(string: apiBase + "logout/" + pathEscaped(token)) else {
            setToken(nil); return
        }
        let req = makeRequest(url: url, method: "GET")
        _ = try? await perform(req)   // best-effort; clear locally regardless
        setToken(nil)
    }

    /// GET /api/4/checkservice/{token}
    @discardableResult
    func checkService() async throws -> SimpleResult {
        let token = try requireToken()
        guard let url = URL(string: apiBase + "checkservice/" + pathEscaped(token)) else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode(SimpleResult.self, from: data, body: bodyStr)
    }

    /// GET /api/4/accountinfo/{token}
    func accountInfo() async throws -> AccountInfo {
        let token = try requireToken()
        guard let url = URL(string: apiBase + "accountinfo/" + pathEscaped(token)) else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode(AccountInfo.self, from: data, body: bodyStr)
    }

    // MARK: - Channels / EPG

    /// GET https://api.viu.rs/epgjsonV2.php   (NO token) → [EPGChannel]
    func fetchChannels() async throws -> [EPGChannel] {
        guard let url = URL(string: rootBase + "epgjsonV2.php") else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode([EPGChannel].self, from: data, body: bodyStr)
    }

    /// GET https://api.viu.rs/epgjsonV2.php?token={token}
    /// The plain V2 feed started answering "Error 2" without a token, so the
    /// store also tries this tokenised variant of the same feed.
    func fetchChannelsV2WithToken() async throws -> [EPGChannel] {
        let token = try requireToken()
        var comps = URLComponents(string: rootBase + "epgjsonV2.php")
        comps?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps?.url else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode([EPGChannel].self, from: data, body: bodyStr)
    }

    /// GET https://api.viu.rs/epgjson.php?token={token}&tag={tag}
    /// Returned shape is the same channel array, filtered/grouped by tag.
    func fetchChannels(tag: String) async throws -> [EPGChannel] {
        let token = try requireToken()
        var comps = URLComponents(string: rootBase + "epgjson.php")
        comps?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "tag", value: tag)
        ]
        guard let url = comps?.url else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode([EPGChannel].self, from: data, body: bodyStr)
    }

    /// GET https://api.viu.rs/epg_tags.php?token={token} → [EPGTag]
    func fetchTags() async throws -> [EPGTag] {
        let token = try requireToken()
        var comps = URLComponents(string: rootBase + "epg_tags.php")
        comps?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps?.url else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode([EPGTag].self, from: data, body: bodyStr)
    }

    // MARK: - Live links

    /// GET /api/4/live-tv/links/{stream_id}/{token}
    func liveLinks(streamID: Int) async throws -> LiveLinks {
        let token = try requireToken()
        guard let url = URL(string: apiBase + "live-tv/links/\(streamID)/" + pathEscaped(token)) else {
            throw APIError.badURL
        }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        let links = try decode(LiveLinks.self, from: data, body: bodyStr)
        if links.hasError {
            throw APIError.api(code: links.error ?? -1,
                               message: links.message ?? "No playable link for this channel.")
        }
        return links
    }

    // MARK: - Favorites (server-side)

    /// POST /api/4/save/stream/favorite/{token}
    @discardableResult
    func saveFavorite(streamID: Int, titleID: Int = 0, titleType: Int = 0) async throws -> SimpleResult {
        try await favorite(path: "save/stream/favorite/", streamID: streamID, titleID: titleID, titleType: titleType)
    }

    /// POST /api/4/remove/stream/favorite/{token}
    @discardableResult
    func removeFavorite(streamID: Int, titleID: Int = 0, titleType: Int = 0) async throws -> SimpleResult {
        try await favorite(path: "remove/stream/favorite/", streamID: streamID, titleID: titleID, titleType: titleType)
    }

    private func favorite(path: String, streamID: Int, titleID: Int, titleType: Int) async throws -> SimpleResult {
        let token = try requireToken()
        guard let url = URL(string: apiBase + path + pathEscaped(token)) else { throw APIError.badURL }
        let body = try encodeBody(FavoriteRequest(stream_id: streamID, title_id: titleID, title_type: titleType))
        let req = makeRequest(url: url, method: "POST", jsonBody: body)
        let (data, bodyStr, _) = try await perform(req)
        return try decode(SimpleResult.self, from: data, body: bodyStr)
    }

    // MARK: - History / error reporting (best-effort, fire-and-forget)

    /// POST /api/4/save/livetv/history/{token}
    func reportHistory(streamID: Int, streamName: String, device: String) async {
        await postLiveEvent(path: "save/livetv/history/", streamID: streamID, streamName: streamName, device: device)
    }

    /// POST /api/4/save/livestream/error/{token}
    func reportStreamError(streamID: Int, streamName: String, device: String) async {
        await postLiveEvent(path: "save/livestream/error/", streamID: streamID, streamName: streamName, device: device)
    }

    private func postLiveEvent(path: String, streamID: Int, streamName: String, device: String) async {
        guard let token = currentToken(), !token.isEmpty,
              let url = URL(string: apiBase + path + pathEscaped(token)) else { return }
        guard let body = try? encodeBody(LiveEventRequest(device: device, stream_id: streamID, stream_name: streamName)) else { return }
        let req = makeRequest(url: url, method: "POST", jsonBody: body)
        _ = try? await perform(req)
    }

    // MARK: - Helpers

    /// Percent-escape a token for safe inclusion in a URL path segment.
    private func pathEscaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
