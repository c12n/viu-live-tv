// Viu Live TV for Android TV — backend layer.
//
// Mirrors the iOS app's networking exactly (same endpoints, same
// User-Agent, same response quirks): the php EPG endpoints answer the
// literal string "expired" for a rejected token, /api/4/ answers JSON
// error 4, response bodies may carry a UTF-8 BOM, and the EPG category
// feeds must be fetched IN PARALLEL (the ALL feed alone is ~1,145
// channels; sequential fetching looks broken).

import 'dart:convert';

import 'package:http/http.dart' as http;

const String kUserAgent = 'viutvapp/1.12 LH';
const String kApiBase = 'https://api.viu.rs';

class SessionExpired implements Exception {
  const SessionExpired();
  @override
  String toString() => 'Session expired';
}

class ApiFailure implements Exception {
  final String message;
  const ApiFailure(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

String decodeHtmlEntities(String s) {
  var out = s;
  out = out.replaceAll('&amp;', '&');
  out = out.replaceAll('&lt;', '<');
  out = out.replaceAll('&gt;', '>');
  out = out.replaceAll('&quot;', '"');
  out = out.replaceAll('&#39;', "'");
  out = out.replaceAll('&apos;', "'");
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  return out;
}

String? flexString(Map<String, dynamic> json, List<String> keys) {
  for (final k in keys) {
    final v = json[k];
    if (v is String && v.isNotEmpty) return v;
    if (v is num) return v.toString();
  }
  return null;
}

int? flexInt(Map<String, dynamic> json, List<String> keys) {
  for (final k in keys) {
    final v = json[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final p = int.tryParse(v);
      if (p != null) return p;
    }
  }
  return null;
}

/// Glue a programme's wall-time string to its own UTC offset, carried in
/// the schedule entry's sibling `timezone` field (e.g. "-0400") — this is
/// exactly what the official Android app does (it parses
/// timestart+timezone with "yyyy-MM-dd HH:mm:ssZ"). Without the offset
/// the times land hours away from the real instant and now/next matching
/// fails for every channel ("No programme info" on all cards).
String? withTzOffset(dynamic raw, String? tz) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty) return s;
  if (RegExp(r'^\d+$').hasMatch(s)) return s; // epoch — already absolute
  if (tz == null || tz.trim().isEmpty) return s;
  if (RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(s)) return s; // has offset
  var t = tz.trim();
  if (RegExp(r'^[+-]\d$').hasMatch(t)) {
    t = '${t[0]}0${t[1]}00';
  } else if (RegExp(r'^[+-]\d{2}$').hasMatch(t)) {
    t = '${t}00';
  } else if (RegExp(r'^[+-]\d{3}$').hasMatch(t)) {
    t = '${t[0]}0${t.substring(1)}';
  }
  if (!RegExp(r'^[+-]\d{2}:?\d{2}$').hasMatch(t)) return s; // unknown shape
  return '$s$t';
}

DateTime? parseEpgDate(dynamic raw) {
  if (raw == null) return null;
  if (raw is num) {
    final v = raw.toInt();
    if (v > 100000000000) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v > 100000000) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
    return null;
  }
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^\d{10,13}$').hasMatch(s)) {
    final v = int.parse(s);
    return s.length >= 13
        ? DateTime.fromMillisecondsSinceEpoch(v)
        : DateTime.fromMillisecondsSinceEpoch(v * 1000);
  }
  return DateTime.tryParse(s.replaceAll('/', '-'));
}

class EPGProgramme {
  final String name;
  final String description;
  final DateTime? timeStart;
  final DateTime? timeEnd;

  const EPGProgramme({
    required this.name,
    this.description = '',
    this.timeStart,
    this.timeEnd,
  });

  factory EPGProgramme.fromJson(Map<String, dynamic> json) {
    final tz = flexString(json, ['timezone', 'tz', 'utc_offset']);
    return EPGProgramme(
      name: decodeHtmlEntities(
          flexString(json, ['name', 'title']) ?? '—'),
      description:
          decodeHtmlEntities(flexString(json, ['description', 'desc']) ?? ''),
      timeStart: parseEpgDate(withTzOffset(
          json['timestart'] ?? json['start'] ?? json['start_time'], tz)),
      timeEnd: parseEpgDate(withTzOffset(
          json['timeend'] ?? json['end'] ?? json['end_time'] ?? json['stop'],
          tz)),
    );
  }

  bool isLiveAt(DateTime date) =>
      timeStart != null &&
      timeEnd != null &&
      !date.isBefore(timeStart!) &&
      date.isBefore(timeEnd!);
}

class EPGChannel {
  final int streamId;
  final String name;
  final String? streamIcon;
  final List<String> tags; // normalised: UPPERCASE_WITH_UNDERSCORES
  final String? categoryId;
  final String? currentShow;
  final List<EPGProgramme> schedule;

  const EPGChannel({
    required this.streamId,
    required this.name,
    this.streamIcon,
    this.tags = const [],
    this.categoryId,
    this.currentShow,
    this.schedule = const [],
  });

  factory EPGChannel.fromJson(Map<String, dynamic> json) {
    final rawTags = flexString(json, ['tags', 'tag']) ?? '';
    final tags = rawTags
        .split(',')
        .map((t) => t.trim().toUpperCase().replaceAll(' ', '_'))
        .where((t) => t.isNotEmpty)
        .toList();
    var schedule = <EPGProgramme>[];
    final rawSchedule = json['schedule'];
    if (rawSchedule is List) {
      schedule = rawSchedule
          .whereType<Map>()
          .map((e) => EPGProgramme.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    return EPGChannel(
      streamId: flexInt(json, ['stream_id', 'streamid', 'id']) ?? 0,
      name: decodeHtmlEntities(
          flexString(json, ['name', 'title']) ?? 'Channel'),
      streamIcon: flexString(json, ['stream_icon', 'icon', 'logo', 'logo_url']),
      tags: tags,
      categoryId: flexString(json, ['category_id', 'categoryid']),
      currentShow: flexString(json, ['current_show', 'currentShow', 'now']),
      schedule: schedule,
    );
  }

  EPGProgramme? nowProgramme([DateTime? at]) {
    final date = at ?? DateTime.now();
    for (final p in schedule) {
      if (p.isLiveAt(date)) return p;
    }
    EPGProgramme? best;
    for (final p in schedule) {
      final s = p.timeStart;
      if (s != null && !s.isAfter(date)) {
        if (best == null || s.isAfter(best.timeStart ?? DateTime(1970))) {
          best = p;
        }
      }
    }
    return best;
  }

  EPGProgramme? nextProgramme([DateTime? at]) {
    final date = at ?? DateTime.now();
    EPGProgramme? best;
    for (final p in schedule) {
      final s = p.timeStart;
      if (s != null && s.isAfter(date)) {
        if (best == null || s.isBefore(best.timeStart ?? DateTime(2100))) {
          best = p;
        }
      }
    }
    return best;
  }

  String nowText([DateTime? at]) {
    final p = nowProgramme(at);
    if (p != null && p.name != '—') return p.name;
    if (currentShow != null && currentShow!.isNotEmpty) return currentShow!;
    return 'No programme info';
  }

  double? nowProgress([DateTime? at]) {
    final date = at ?? DateTime.now();
    final p = nowProgramme(date);
    if (p == null || p.timeStart == null || p.timeEnd == null) return null;
    final total = p.timeEnd!.difference(p.timeStart!).inSeconds;
    if (total <= 0) return null;
    final done = date.difference(p.timeStart!).inSeconds;
    return (done / total).clamp(0.0, 1.0);
  }
}

class EPGTag {
  final String displayName;
  final String parameterName;
  const EPGTag({required this.displayName, required this.parameterName});

  factory EPGTag.fromJson(Map<String, dynamic> json) {
    return EPGTag(
      displayName: decodeHtmlEntities(
          flexString(json, ['displayname', 'display_name', 'name']) ?? 'Tag'),
      parameterName:
          flexString(json, ['parameter_name', 'parametername', 'param']) ?? '',
    );
  }
}

class AccountInfo {
  final String? username;
  final String? firstName;
  final String? lastName;
  final String? premiumExpiresOn;
  final String? premiumStatus;

  const AccountInfo({
    this.username,
    this.firstName,
    this.lastName,
    this.premiumExpiresOn,
    this.premiumStatus,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) {
    return AccountInfo(
      username: flexString(json, ['Username', 'username']),
      firstName: flexString(json, ['First_Name', 'first_name', 'firstName']),
      lastName: flexString(json, ['Last_Name', 'last_name', 'lastName']),
      premiumExpiresOn: flexString(
          json, ['Premium_Expires_on', 'premium_expires_on', 'expires_on']),
      premiumStatus:
          flexString(json, ['Your_Premium_Status', 'premium_status', 'status']),
    );
  }

  String get displayName {
    final full = [firstName, lastName]
        .where((e) => e != null && e.isNotEmpty)
        .join(' ');
    if (full.isNotEmpty) return full;
    return username ?? 'Account';
  }

  /// Mirrors the iOS rule: a present status string must read ACTIVE;
  /// otherwise fall back to the expiry date when it parses.
  bool get hasActiveSubscription {
    final status = premiumStatus?.trim();
    if (status != null && status.isNotEmpty) {
      return status.toUpperCase() == 'ACTIVE';
    }
    final exp = premiumExpiresOn;
    if (exp != null) {
      final d = parseEpgDate(exp);
      if (d != null) return !d.isBefore(DateTime.now());
    }
    return false;
  }
}

class LiveLinks {
  final String? liveLink;
  final String? streamDisplayName;
  final bool isFavorite;
  const LiveLinks({this.liveLink, this.streamDisplayName, this.isFavorite = false});

  factory LiveLinks.fromJson(Map<String, dynamic> json) {
    final fav = json['is_favorite'] ?? json['isFavorite'] ?? json['favorite'];
    return LiveLinks(
      liveLink:
          flexString(json, ['live_link', 'link', 'url', 'stream', 'stream_url']),
      streamDisplayName: flexString(
          json, ['stream_display_name', 'display_name', 'name']),
      isFavorite: fav == true || fav == 1 || fav == '1' || fav == 'true',
    );
  }
}

// ---------------------------------------------------------------------------
// API client
// ---------------------------------------------------------------------------

class ViuApi {
  String? token;

  ViuApi({this.token});

  Map<String, String> get _headers => {'User-Agent': kUserAgent};

  String _clean(String body) =>
      body.startsWith('\uFEFF') ? body.substring(1) : body;

  bool _isError4(dynamic decoded) {
    if (decoded is Map) {
      final e = decoded['error'];
      return e == 4 || e == '4';
    }
    return false;
  }

  Future<String> authenticate(String user, String password) async {
    final res = await http.post(
      Uri.parse('$kApiBase/api/4/authenticate'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'user': user, 'password': password}),
    );
    final decoded = jsonDecode(_clean(res.body));
    if (decoded is Map<String, dynamic>) {
      final e = decoded['error'];
      final ok = e == 0 || e == '0' || e == null;
      final tok = decoded['token'];
      if (ok && tok is String && tok.isNotEmpty) {
        token = tok;
        return tok;
      }
      throw ApiFailure(
          (decoded['message'] as String?) ?? 'Sign-in failed. Check your details.');
    }
    throw const ApiFailure('Unexpected response from the server.');
  }

  Future<AccountInfo> accountInfo() async {
    final res = await http.get(
      Uri.parse('$kApiBase/api/4/accountinfo/$token'),
      headers: _headers,
    );
    final decoded = jsonDecode(_clean(res.body));
    if (decoded is Map<String, dynamic>) {
      if (_isError4(decoded)) throw const SessionExpired();
      return AccountInfo.fromJson(decoded);
    }
    throw const ApiFailure('Could not load account info.');
  }

  /// True when the stored token is still accepted. Network failures are
  /// NOT expiry — they return true so the gate never fires offline.
  Future<bool> validateSession() async {
    try {
      final res = await http.get(
        Uri.parse('$kApiBase/api/4/checkservice/$token'),
        headers: _headers,
      );
      final body = _clean(res.body).trim();
      if (body.toLowerCase() == 'expired') return false;
      try {
        final decoded = jsonDecode(body);
        if (_isError4(decoded)) return false;
      } catch (_) {
        // Non-JSON 200 response — treat as valid.
      }
      return res.statusCode == 200;
    } catch (_) {
      return true;
    }
  }

  Future<List<EPGTag>> fetchTags() async {
    final res = await http.get(
      Uri.parse('$kApiBase/epg_tags.php?token=$token'),
      headers: _headers,
    );
    final body = _clean(res.body).trim();
    if (body.toLowerCase() == 'expired') throw const SessionExpired();
    final decoded = jsonDecode(body);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => EPGTag.fromJson(e.cast<String, dynamic>()))
          .where((t) => t.parameterName.isNotEmpty)
          .toList();
    }
    return const [];
  }

  Future<List<EPGChannel>> fetchChannels(String tag) async {
    final res = await http.get(
      Uri.parse('$kApiBase/epgjson.php?token=$token&tag=$tag'),
      headers: _headers,
    );
    final body = _clean(res.body).trim();
    if (body.toLowerCase() == 'expired') throw const SessionExpired();
    final decoded = jsonDecode(body);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => EPGChannel.fromJson(e.cast<String, dynamic>()))
          .where((c) => c.streamId > 0)
          .toList();
    }
    return const [];
  }

  Future<LiveLinks> liveLinks(int streamId) async {
    final res = await http.get(
      Uri.parse('$kApiBase/api/4/live-tv/links/$streamId/$token'),
      headers: _headers,
    );
    final decoded = jsonDecode(_clean(res.body));
    if (decoded is Map<String, dynamic>) {
      if (_isError4(decoded)) throw const SessionExpired();
      return LiveLinks.fromJson(decoded);
    }
    throw const ApiFailure('This channel returned no playable link.');
  }

  Future<void> saveFavorite(int streamId) => _postFavorite('save', streamId);
  Future<void> removeFavorite(int streamId) =>
      _postFavorite('remove', streamId);

  Future<void> _postFavorite(String action, int streamId) async {
    try {
      await http.post(
        Uri.parse('$kApiBase/api/4/$action/stream/favorite/$token'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(
            {'stream_id': streamId, 'title_id': 0, 'title_type': 0}),
      );
    } catch (_) {
      // Best-effort sync; local state is the UI's source of truth.
    }
  }
}
