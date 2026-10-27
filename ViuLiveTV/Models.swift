//
//  Models.swift
//  Viu Live TV
//
//  All API response models + app-domain models.
//  Decoding is written defensively: multiple possible key names,
//  string-or-int ids, and tolerant date parsing, because the live
//  API sometimes returns plain-text error bodies ("Error 2") or
//  values typed differently than documented.
//

import Foundation

// MARK: - Flexible decoding helpers

/// Decodes a value that may arrive as Int, String, Double, or Bool and
/// normalizes it to an Int. Returns nil when absent or unparseable.
func decodeFlexibleInt(_ container: KeyedDecodingContainer<DynamicKey>, _ keys: [String]) -> Int? {
    for key in keys {
        guard let ck = DynamicKey(stringValue: key) else { continue }
        if let v = (try? container.decodeIfPresent(Int.self, forKey: ck)) ?? nil { return v }
        if let v = (try? container.decodeIfPresent(Double.self, forKey: ck)) ?? nil { return Int(v) }
        if let v = (try? container.decodeIfPresent(Bool.self, forKey: ck)) ?? nil { return v ? 1 : 0 }
        if let v = (try? container.decodeIfPresent(String.self, forKey: ck)) ?? nil {
            let trimmed = v.trimmingCharacters(in: .whitespaces)
            if let i = Int(trimmed) { return i }
            if let d = Double(trimmed) { return Int(d) }
        }
    }
    return nil
}

/// Decodes a value that may arrive as String, Int, Double, or Bool and
/// normalizes it to a String.
func decodeFlexibleString(_ container: KeyedDecodingContainer<DynamicKey>, _ keys: [String]) -> String? {
    for key in keys {
        guard let ck = DynamicKey(stringValue: key) else { continue }
        if let v = (try? container.decodeIfPresent(String.self, forKey: ck)) ?? nil {
            return v
        }
        if let v = (try? container.decodeIfPresent(Int.self, forKey: ck)) ?? nil { return String(v) }
        if let v = (try? container.decodeIfPresent(Double.self, forKey: ck)) ?? nil {
            // Avoid trailing ".0" for integral doubles
            if v.rounded() == v { return String(Int(v)) }
            return String(v)
        }
        if let v = (try? container.decodeIfPresent(Bool.self, forKey: ck)) ?? nil { return v ? "1" : "0" }
    }
    return nil
}

/// Decodes a value that may arrive as Bool, Int (0/1), or String ("true"/"1").
func decodeFlexibleBool(_ container: KeyedDecodingContainer<DynamicKey>, _ keys: [String]) -> Bool? {
    for key in keys {
        guard let ck = DynamicKey(stringValue: key) else { continue }
        if let v = (try? container.decodeIfPresent(Bool.self, forKey: ck)) ?? nil { return v }
        if let v = (try? container.decodeIfPresent(Int.self, forKey: ck)) ?? nil { return v != 0 }
        if let v = (try? container.decodeIfPresent(String.self, forKey: ck)) ?? nil {
            switch v.lowercased().trimmingCharacters(in: .whitespaces) {
            case "1", "true", "yes", "y": return true
            case "0", "false", "no", "n", "": return false
            default: return nil
            }
        }
    }
    return nil
}

/// A CodingKey that can be built from any string — lets us probe multiple
/// candidate key names from a single keyed container.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

// MARK: - Auth

/// Response from POST /api/4/authenticate
/// {"token": String, "error": Int, "message": String}
/// error 0 = success, 4 = auth failed, 3 = token failed.
struct LoginApiCallResult: Decodable {
    let token: String?
    let error: Int
    let message: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.token = decodeFlexibleString(c, ["token", "session_token", "access_token"])
        self.error = decodeFlexibleInt(c, ["error", "code", "status"]) ?? -1
        self.message = decodeFlexibleString(c, ["message", "msg", "detail"])
    }

    var isSuccess: Bool { error == 0 && (token?.isEmpty == false) }

    var humanError: String {
        switch error {
        case 0:  return message ?? "Success"
        case 3:  return "Token failed. Please sign in again."
        case 4:  return message ?? "Incorrect username or password."
        default: return message ?? "Login failed (error \(error))."
        }
    }
}

// MARK: - Account info

/// GET /api/4/accountinfo/{token}
/// Note the capitalised keys.
struct AccountInfo: Decodable, Equatable {
    let username: String?
    let firstName: String?
    let lastName: String?
    let createdOn: String?
    let premiumExpiresOn: String?
    let premiumStatus: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.username         = decodeFlexibleString(c, ["Username", "username"])
        self.firstName        = decodeFlexibleString(c, ["First_Name", "first_name", "firstName"])
        self.lastName         = decodeFlexibleString(c, ["Last_Name", "last_name", "lastName"])
        self.createdOn        = decodeFlexibleString(c, ["Account_Created_on", "account_created_on", "created_on"])
        self.premiumExpiresOn = decodeFlexibleString(c, ["Premium_Expires_on", "premium_expires_on", "expires_on"])
        self.premiumStatus    = decodeFlexibleString(c, ["Your_Premium_Status", "premium_status", "status"])
    }

    var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        return username ?? "Account"
    }
}

// MARK: - Live links

/// GET /api/4/live-tv/links/{stream_id}/{token}
struct LiveLinks: Decodable {
    let liveLink: String?
    let streamDisplayName: String?
    let isFavorite: Bool
    let code: Int?
    let error: Int?
    let message: String?
    let bufferTime: Int?
    let rebufferTime: Int?
    let maxBufferTime: Int?
    let reconnectBufferTime: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.liveLink            = decodeFlexibleString(c, ["live_link", "link", "url", "stream", "stream_url"])
        self.streamDisplayName   = decodeFlexibleString(c, ["stream_display_name", "display_name", "name"])
        self.isFavorite          = decodeFlexibleBool(c,   ["is_favorite", "favorite", "fav"]) ?? false
        self.code                = decodeFlexibleInt(c,    ["code"])
        self.error               = decodeFlexibleInt(c,    ["error"])
        self.message             = decodeFlexibleString(c, ["message", "msg"])
        self.bufferTime          = decodeFlexibleInt(c,    ["bufferTime", "buffer_time"])
        self.rebufferTime        = decodeFlexibleInt(c,    ["rebufferTime", "rebuffer_time"])
        self.maxBufferTime       = decodeFlexibleInt(c,    ["maxbufferTime", "max_buffer_time"])
        self.reconnectBufferTime = decodeFlexibleInt(c,    ["reconnectbufferTime", "reconnect_buffer_time"])
    }

    /// True when the body is an API error rather than a usable link.
    var hasError: Bool {
        if let error, error != 0 { return true }
        return (liveLink?.isEmpty ?? true)
    }
}

// MARK: - EPG (channel list)

/// One programme in a channel's schedule.
struct EPGProgramme: Decodable, Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String
    let timeStart: Date?
    let timeEnd: Date?
    let timezone: String?

    // Keep the raw strings for debugging / fallbacks.
    let rawStart: String?
    let rawEnd: String?

    enum CodingKeys: String, CodingKey { case name, description, timestart, timeend, timezone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.name        = decodeFlexibleString(c, ["name", "title"]) ?? "—"
        self.description = decodeFlexibleString(c, ["description", "desc"]) ?? ""
        self.timezone    = decodeFlexibleString(c, ["timezone", "tz"])
        self.rawStart    = decodeFlexibleString(c, ["timestart", "start", "start_time"])
        self.rawEnd      = decodeFlexibleString(c, ["timeend", "end", "end_time", "stop"])
        self.timeStart   = EPGDateParser.shared.date(from: rawStart, timezone: timezone)
        self.timeEnd     = EPGDateParser.shared.date(from: rawEnd, timezone: timezone)
    }

    // Manual Hashable/Equatable since Date? parsing is deterministic per-decode
    static func == (lhs: EPGProgramme, rhs: EPGProgramme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 0...1 progress of this programme at `now`, or nil if times unknown.
    func progress(at now: Date = Date()) -> Double? {
        guard let start = timeStart, let end = timeEnd, end > start else { return nil }
        let total = end.timeIntervalSince(start)
        let elapsed = now.timeIntervalSince(start)
        return min(max(elapsed / total, 0), 1)
    }

    func isLive(at now: Date = Date()) -> Bool {
        guard let start = timeStart, let end = timeEnd else { return false }
        return now >= start && now < end
    }
}

/// One channel from epgjsonV2.php. This is the primary channel list.
struct EPGChannel: Decodable, Identifiable, Hashable {
    /// Stable identity used throughout the app.
    var id: Int { streamId }

    let num: Int?
    let name: String
    let streamType: String?
    let streamId: Int
    let streamIcon: String?
    let epgChannelId: String?
    let added: String?
    let categoryId: String?
    let customSid: String?
    let tvArchive: Int?
    let directSource: String?
    let tvArchiveDuration: Int?
    let schedule: [EPGProgramme]
    let currentShow: String?
    let tags: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.num               = decodeFlexibleInt(c,    ["num", "number"])
        self.name              = decodeFlexibleString(c, ["name", "title", "channel_name"]) ?? "Channel"
        self.streamType        = decodeFlexibleString(c, ["stream_type", "type"])
        // stream_id is required for identity; if missing, synthesize from name hash.
        self.streamId          = decodeFlexibleInt(c,    ["stream_id", "id", "channel_id"]) ?? abs((decodeFlexibleString(c, ["name"]) ?? UUID().uuidString).hashValue)
        self.streamIcon        = decodeFlexibleString(c, ["stream_icon", "icon", "logo", "logo_url"])
        self.epgChannelId      = decodeFlexibleString(c, ["epg_channel_id", "epg_id"])
        self.added             = decodeFlexibleString(c, ["added"])
        self.categoryId        = decodeFlexibleString(c, ["category_id", "category"])
        self.customSid         = decodeFlexibleString(c, ["custom_sid"])
        self.tvArchive         = decodeFlexibleInt(c,    ["tv_archive"])
        self.directSource      = decodeFlexibleString(c, ["direct_source"])
        self.tvArchiveDuration = decodeFlexibleInt(c,    ["tv_archive_duration"])
        self.currentShow       = decodeFlexibleString(c, ["current_show"])
        self.tags              = decodeFlexibleString(c, ["tags"])

        // schedule is an array; decode leniently (may be absent).
        if let ck = DynamicKey(stringValue: "schedule"),
           let progs = (try? c.decodeIfPresent([EPGProgramme].self, forKey: ck)) ?? nil {
            self.schedule = progs
        } else {
            self.schedule = []
        }
    }

    /// Designated memberwise init for building fallback channels in code.
    init(num: Int?, name: String, streamType: String?, streamId: Int,
         streamIcon: String?, epgChannelId: String?, categoryId: String?,
         schedule: [EPGProgramme] = [], currentShow: String? = nil, tags: String? = nil) {
        self.num = num; self.name = name; self.streamType = streamType
        self.streamId = streamId; self.streamIcon = streamIcon
        self.epgChannelId = epgChannelId; self.added = nil; self.categoryId = categoryId
        self.customSid = nil; self.tvArchive = nil; self.directSource = nil
        self.tvArchiveDuration = nil; self.schedule = schedule
        self.currentShow = currentShow; self.tags = tags
    }

    static func == (lhs: EPGChannel, rhs: EPGChannel) -> Bool { lhs.streamId == rhs.streamId }
    func hash(into hasher: inout Hasher) { hasher.combine(streamId) }

    var logoURL: URL? {
        guard let s = streamIcon, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    /// The programme airing right now (by schedule times, else current_show fallback).
    func nowProgramme(at date: Date = Date()) -> EPGProgramme? {
        if let live = schedule.first(where: { $0.isLive(at: date) }) { return live }
        // Fall back to the most recent programme that already started.
        return schedule
            .filter { ($0.timeStart ?? .distantFuture) <= date }
            .max(by: { ($0.timeStart ?? .distantPast) < ($1.timeStart ?? .distantPast) })
    }

    /// The next upcoming programme after `date`.
    func nextProgramme(at date: Date = Date()) -> EPGProgramme? {
        schedule
            .filter { ($0.timeStart ?? .distantPast) > date }
            .min(by: { ($0.timeStart ?? .distantFuture) < ($1.timeStart ?? .distantFuture) })
    }

    /// Display string for "now", favouring EPG, then current_show, then placeholder.
    func nowText(at date: Date = Date()) -> String {
        if let p = nowProgramme(at: date), p.name != "—" { return p.name }
        if let cs = currentShow, !cs.isEmpty { return cs }
        return "No programme info"
    }
}

// MARK: - EPG tags

/// GET /epg_tags.php?token={token}
struct EPGTag: Decodable, Identifiable, Hashable {
    var id: String { parameterName }
    let displayName: String
    let parameterName: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.displayName   = decodeFlexibleString(c, ["displayname", "display_name", "name"]) ?? "Tag"
        self.parameterName = decodeFlexibleString(c, ["parameter_name", "parameter", "param", "tag"]) ?? ""
    }
}

// MARK: - Favorites

/// POST /api/4/save|remove/stream/favorite/{token}
struct FavoriteRequest: Encodable {
    let stream_id: Int
    let title_id: Int
    let title_type: Int
}

/// Generic {"result": Int, "message": String} response.
struct SimpleResult: Decodable {
    let result: Int?
    let message: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.result  = decodeFlexibleInt(c,    ["result", "error", "code", "status"])
        self.message = decodeFlexibleString(c, ["message", "msg", "detail"])
    }

    var isSuccess: Bool { (result ?? -1) == 0 || (result ?? -1) == 1 }
}

/// POST /api/4/save/livetv/history/{token} and /save/livestream/error/{token}
struct LiveEventRequest: Encodable {
    let device: String
    let stream_id: Int
    let stream_name: String
}
