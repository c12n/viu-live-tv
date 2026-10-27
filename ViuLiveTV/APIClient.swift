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
    case sessionExpired

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
        case .sessionExpired:        return "Your Viu session has expired. Sign out and sign in again to refresh it."
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
        // Match the Android app exactly: User-Agent only on GETs (OkHttp sends
        // no Accept header); POSTs add the JSON content type.
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let jsonBody {
            req.httpBody = jsonBody
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Strip a UTF-8 BOM. OkHttp removes it when decoding the body as a
    /// string; URLSession does not, and a BOM breaks both the JSON sniff
    /// check and JSONDecoder. (PHP scripts commonly emit one.)
    private func stripBOM(_ data: Data) -> Data {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return data.dropFirst(3)
        }
        return data
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
        let cleanData = stripBOM(data)
        let bodyString = String(data: cleanData, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, bodyString.isEmpty ? nil : bodyString)
        }
        return (cleanData, bodyString, http)
    }

    /// True when a body is clearly not JSON (plain-text error like "Error 2").
    private func looksLikeJSON(_ body: String) -> Bool {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    /// Decode JSON, converting plain-text bodies into readable errors.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, body: String) throws -> T {
        // The .php EPG endpoints answer the literal string "expired" when the
        // token is no longer accepted — surface that as a distinct state.
        if body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "expired" {
            throw APIError.sessionExpired
        }
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

    /// The /api/4/ endpoints answer auth failures with a JSON error envelope
    /// ({"error":"4","message":"Invalid authentication..."}) instead of the
    /// payload — and AccountInfo's tolerant decoder would happily turn that
    /// into an all-empty account. Detect the envelope first. Error 4 means
    /// the token is no longer accepted: treat it as an expired session.
    private func throwIfErrorEnvelope(data: Data, body: String) throws {
        guard looksLikeJSON(body), body.contains("\"error\""),
              let env = try? decoder.decode(SimpleResult.self, from: data),
              let code = env.result else { return }
        if code == 4 { throw APIError.sessionExpired }
        if code != 0 {
            throw APIError.api(code: code, message: env.message ?? "The server reported an error (\(code)).")
        }
    }

    /// GET /api/4/checkservice/{token}
    @discardableResult
    func checkService() async throws -> SimpleResult {
        let token = try requireToken()
        guard let url = URL(string: apiBase + "checkservice/" + pathEscaped(token)) else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        try throwIfErrorEnvelope(data: data, body: bodyStr)
        return try decode(SimpleResult.self, from: data, body: bodyStr)
    }

    /// GET /api/4/accountinfo/{token}
    func accountInfo() async throws -> AccountInfo {
        let token = try requireToken()
        guard let url = URL(string: apiBase + "accountinfo/" + pathEscaped(token)) else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        try throwIfErrorEnvelope(data: data, body: bodyStr)
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
    /// Built by raw string concatenation, exactly like the Android app
    /// (OkHttp), so the token/tag reach the server byte-for-byte the same.
    func fetchChannels(tag: String) async throws -> [EPGChannel] {
        let token = try requireToken()
        let raw = rootBase + "epgjson.php?token=" + token + "&tag=" + tag
        guard let url = URL(string: raw) else { return try await fetchChannelsEncoded(tag: tag) }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode([EPGChannel].self, from: data, body: bodyStr)
    }

    /// GET https://api.viu.rs/epgjson.php?token={token}   (no tag filter)
    func fetchChannelsNoTag() async throws -> [EPGChannel] {
        let token = try requireToken()
        let raw = rootBase + "epgjson.php?token=" + token
        guard let url = URL(string: raw) else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        return try decode([EPGChannel].self, from: data, body: bodyStr)
    }

    /// URLComponents-encoded variant of the per-tag fetch (diagnostics A/B).
    func fetchChannelsEncoded(tag: String) async throws -> [EPGChannel] {
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
    /// Raw concatenation like Android. An empty 200 body means "no tags",
    /// not an error.
    func fetchTags() async throws -> [EPGTag] {
        let token = try requireToken()
        let raw = rootBase + "epg_tags.php?token=" + token
        guard let url = URL(string: raw) else { return try await fetchTagsEncoded() }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        if bodyStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return try decode([EPGTag].self, from: data, body: bodyStr)
    }

    /// URLComponents-encoded variant of the tags fetch (diagnostics A/B).
    func fetchTagsEncoded() async throws -> [EPGTag] {
        let token = try requireToken()
        var comps = URLComponents(string: rootBase + "epg_tags.php")
        comps?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps?.url else { throw APIError.badURL }
        let req = makeRequest(url: url, method: "GET")
        let (data, bodyStr, _) = try await perform(req)
        if bodyStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
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

    // MARK: - Diagnostics

    /// Non-throwing raw GET used by the diagnostics screen: reports the HTTP
    /// status, byte count and body exactly as the server answered.
    func rawGET(_ urlString: String) async -> (status: Int, body: String, bytes: Int) {
        guard let url = URL(string: urlString) else { return (0, "Invalid URL", 0) }
        let req = makeRequest(url: url, method: "GET")
        do {
            let (data, response) = try await session.data(for: req)
            let clean = stripBOM(data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: clean, encoding: .utf8) ?? "<non-UTF8 body>"
            return (status, body, clean.count)
        } catch {
            return (-1, error.localizedDescription, 0)
        }
    }

    private func preview(_ body: String) -> String {
        let oneLine = body.replacingOccurrences(of: "\n", with: " ")
                          .replacingOccurrences(of: "\r", with: " ")
                          .trimmingCharacters(in: .whitespaces)
        if oneLine.isEmpty { return "<empty body>" }
        return String(oneLine.prefix(140))
    }

    /// Runs every channel-loading request the way the app makes it and
    /// returns human-readable result lines. The token itself is never
    /// included in the output — only endpoint names and server responses.
    func runDiagnostics() async -> [String] {
        guard let token = currentToken(), !token.isEmpty else {
            return ["No sign-in token stored. Sign in first, then run this again."]
        }
        var lines: [String] = []
        let dec = JSONDecoder()

        func report(_ label: String, _ result: (status: Int, body: String, bytes: Int)) -> Data? {
            let data = Data(result.body.utf8)
            if let channels = try? dec.decode([EPGChannel].self, from: data) {
                lines.append("\(label) → HTTP \(result.status), \(result.bytes) bytes, \(channels.count) channels ✓")
            } else if let tags = try? dec.decode([EPGTag].self, from: data) {
                lines.append("\(label) → HTTP \(result.status), \(result.bytes) bytes, \(tags.count) tags ✓")
            } else {
                lines.append("\(label) → HTTP \(result.status), \(result.bytes) bytes — \(preview(result.body))")
            }
            return data
        }

        // 1. Account info (proves the token works on /api/4/)
        let info = await rawGET(apiBase + "accountinfo/" + pathEscaped(token))
        if let acct = try? dec.decode(AccountInfo.self, from: Data(info.body.utf8)), acct.username != nil {
            lines.append("Account info → HTTP \(info.status), signed in as \(acct.username ?? "?") ✓")
        } else {
            lines.append("Account info → HTTP \(info.status), \(info.bytes) bytes — \(preview(info.body))")
        }

        // 2. Tags, Android-style raw URL
        let tagsRaw = await rawGET(rootBase + "epg_tags.php?token=" + token)
        let tagsData = report("Tags (raw URL)", tagsRaw)
        var firstTag: String?
        if let tagsData, let tags = try? dec.decode([EPGTag].self, from: tagsData) {
            firstTag = tags.first(where: { !$0.parameterName.isEmpty })?.parameterName
        }

        // 3. Tags, percent-encoded URL
        var encComps = URLComponents(string: rootBase + "epg_tags.php")
        encComps?.queryItems = [URLQueryItem(name: "token", value: token)]
        if let u = encComps?.url {
            _ = report("Tags (encoded URL)", await rawGET(u.absoluteString))
        }

        // 4. Per-tag EPG for the first tag
        if let tag = firstTag {
            _ = report("Channels for tag '\(tag)'", await rawGET(rootBase + "epgjson.php?token=" + token + "&tag=" + tag))
        } else {
            lines.append("Channels per tag → skipped (no tag to test with)")
        }

        // 5. EPG with token, no tag
        _ = report("Channels (no tag)", await rawGET(rootBase + "epgjson.php?token=" + token))

        // 6. V2 feed with token
        _ = report("Channels V2 (token)", await rawGET(rootBase + "epgjsonV2.php?token=" + token))

        // 7. V2 feed, no token
        _ = report("Channels V2 (no token)", await rawGET(rootBase + "epgjsonV2.php"))

        return lines
    }

    // MARK: - Helpers

    /// Percent-escape a token for safe inclusion in a URL path segment.
    private func pathEscaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
