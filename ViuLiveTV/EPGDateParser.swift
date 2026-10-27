//
//  EPGDateParser.swift
//  Viu Live TV
//
//  Parses EPG timestamp strings ("yyyy-MM-dd HH:mm:ss") into Date,
//  honouring a per-programme timezone string when present and caching
//  formatters (DateFormatter creation is expensive).
//

import Foundation

final class EPGDateParser {
    static let shared = EPGDateParser()

    private var cache: [String: DateFormatter] = [:]
    private let lock = NSLock()

    private func formatter(for timezone: String?) -> DateFormatter {
        let tzKey = timezone ?? "__local__"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[tzKey] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let tz = timezone, !tz.isEmpty {
            // tz may be an IANA name ("Europe/Belgrade") or an offset.
            if let resolved = TimeZone(identifier: tz) {
                f.timeZone = resolved
            } else if let secs = Self.offsetSeconds(from: tz) {
                f.timeZone = TimeZone(secondsFromGMT: secs)
            } else {
                f.timeZone = TimeZone.current
            }
        } else {
            f.timeZone = TimeZone.current
        }
        cache[tzKey] = f
        return f
    }

    /// Parse "+02:00" / "-0500" / "GMT+2" style offsets to seconds.
    private static func offsetSeconds(from raw: String) -> Int? {
        var s = raw.uppercased().replacingOccurrences(of: "GMT", with: "")
                                .replacingOccurrences(of: "UTC", with: "")
                                .trimmingCharacters(in: .whitespaces)
        guard let signChar = s.first, signChar == "+" || signChar == "-" else { return nil }
        let sign = signChar == "-" ? -1 : 1
        s.removeFirst()
        s = s.replacingOccurrences(of: ":", with: "")
        guard !s.isEmpty else { return nil }
        let hours: Int, minutes: Int
        if s.count <= 2 {
            hours = Int(s) ?? 0; minutes = 0
        } else {
            let h = String(s.prefix(2)); let m = String(s.suffix(2))
            hours = Int(h) ?? 0; minutes = Int(m) ?? 0
        }
        return sign * (hours * 3600 + minutes * 60)
    }

    func date(from string: String?, timezone: String?) -> Date? {
        guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Primary expected format.
        if let d = formatter(for: timezone).date(from: trimmed) { return d }

        // Unix epoch fallback (seconds).
        if let secs = TimeInterval(trimmed) {
            // Heuristic: treat 10-digit values as seconds, 13-digit as ms.
            if trimmed.count >= 12 { return Date(timeIntervalSince1970: secs / 1000.0) }
            return Date(timeIntervalSince1970: secs)
        }

        // ISO-8601 fallback.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }

        return nil
    }
}
