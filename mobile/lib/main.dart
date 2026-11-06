// Viu Live TV for Android (phone & tablet).
//
// Touch-first sibling of the iOS app: the same Viu backend (api.viu.rs),
// the same account features — sign-in with the Non-VIP gate, parallel
// EPG over all category tags, favorites two-way sync with the website,
// parental controls with a PIN pad, Kids and Sports modes, category
// visibility — plus the iOS v1.3.1 readability pass: big Dynamic-Type
// rows, a per-language badge on every channel, and a Settings language
// filter. Material 3 with native System / Light / Dark appearance and
// the same seven accent colors. Chromecast is hand-rolled CASTV2
// (see cast.dart), mirroring the iOS player.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart' as painting;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'cast.dart';
import 'language.dart';
import 'reminders.dart';

// ---------------------------------------------------------------------------
// Accents (same curated set as the iOS app)
// ---------------------------------------------------------------------------

class Accent {
  final String name;
  final Color seed;
  const Accent(this.name, this.seed);
}

const List<Accent> kAccents = [
  Accent('Red', Color(0xFFE5323B)),
  Accent('Blue', Color(0xFF4C8DFF)),
  Accent('Purple', Color(0xFF9D6BFF)),
  Accent('Pink', Color(0xFFFF5C8A)),
  Accent('Orange', Color(0xFFFF8A3D)),
  Accent('Green', Color(0xFF35C26B)),
  Accent('Teal', Color(0xFF2BB3A3)),
];

const Set<String> kSportsParams = {
  'HOCKEY', 'ESPN_PLUS', 'TSN_PLUS', 'SPORTSNET', 'BEIN_SPORTS', 'NFL',
  'NBA', 'MLB', 'NHL', 'SOCCER', 'FOOTBALL', 'GOLF', 'TENNIS', 'UFC',
  'BOXING', 'WWE', 'F1', 'RACING',
};

bool isSportsTag(String param) =>
    param.contains('SPORT') || kSportsParams.contains(param);

/// One viewer profile (2.0.0). Favorites, recents and custom groups are
/// stored per profile; the server-side favorites sync only runs for the
/// 'main' profile — every other profile's favorites are local-only.
class ViuProfile {
  final String id;
  String name;
  ViuProfile({required this.id, required this.name});

  factory ViuProfile.fromJson(Map<String, dynamic> json) => ViuProfile(
        id: (json['id'] as String?) ?? 'main',
        name: (json['name'] as String?) ?? 'Main',
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// A user-built channel group (2.0.0), channels kept in display order.
class ViuGroup {
  final String id;
  String name;
  List<int> channelIds;
  ViuGroup({required this.id, required this.name, List<int>? channelIds})
      : channelIds = channelIds ?? [];

  factory ViuGroup.fromJson(Map<String, dynamic> json) => ViuGroup(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? 'Group',
        channelIds: ((json['channelIds'] as List?) ?? [])
            .map((e) => e is num ? e.toInt() : int.tryParse('$e') ?? 0)
            .where((e) => e > 0)
            .toList(),
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'channelIds': channelIds};
}

// ---------------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  final ViuApi api = ViuApi();
  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  SharedPreferences? _prefs;

  bool booted = false;
  String? token;
  String? username;
  AccountInfo? account;
  bool vipKnown = false;
  bool nonVip = false;

  List<EPGTag> tags = [];
  Map<String, List<EPGChannel>> byTag = {};
  List<EPGChannel> all = [];
  bool epgLoading = false;
  String? epgError;

  Set<int> favorites = {};
  Set<int> locked = {};

  /// Recently watched channel ids, newest first (capped at 12) —
  /// the counterpart of the iOS app's Recently Watched rail.
  List<int> recentIds = [];

  /// "streamId|startEpochMs" keys for scheduled programme reminders.
  Set<String> reminderKeys = {};

  int accentIndex = 0;
  int appearanceMode = 0; // 0 System, 1 Light, 2 Dark
  String languageFilter = ''; // '' = all languages
  Set<String> hiddenTags = {};
  List<String> tagOrder = [];
  bool sportsMode = false;
  bool kidsMode = false;
  bool parentalEnabled = false;
  String? customPin;

  // 2.0.0: profiles, custom groups, favorites order/pins, extra-large
  // text, kids bedtime.
  List<ViuProfile> profiles = [ViuProfile(id: 'main', name: 'Main')];
  String activeProfileId = 'main';
  List<ViuGroup> groups = [];

  /// Display order for favorites (ids) and the pinned subset, both for
  /// the active profile. See [orderedFavoriteIds].
  List<int> favOrder = [];
  List<int> favPins = [];

  bool extraLarge = false;
  bool kidsBedtimeEnabled = false;

  /// Bedtime as minutes after midnight (default 1200 = 20:00).
  int kidsBedtimeMinutes = 1200;
  Timer? _bedtimeTimer;

  ViuProfile get activeProfile {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return profiles.first;
  }

  bool get isMainProfile => activeProfileId == 'main';

  // Per-profile preference keys. The main profile keeps the historic
  // un-suffixed favorites/recents keys so existing installs upgrade
  // seamlessly; everything else is keyed by profile id.
  String _favKeyFor(String pid) =>
      pid == 'main' ? 'viu_favorites' : 'viu_favorites_$pid';
  String _recentsKeyFor(String pid) =>
      pid == 'main' ? 'viu_recents' : 'viu_recents_$pid';
  String _groupsKeyFor(String pid) => 'viu_groups_$pid';
  String _favOrderKeyFor(String pid) => 'viu_fav_order_$pid';
  String _favPinsKeyFor(String pid) => 'viu_fav_pins_$pid';

  /// True while Kids Mode's bedtime lock should cover the app: bedtime
  /// has passed this evening, or it is the small hours before 06:00.
  bool get kidsBedtimeActive {
    if (!kidsMode || !kidsBedtimeEnabled) return false;
    final now = DateTime.now();
    final mins = now.hour * 60 + now.minute;
    return mins >= kidsBedtimeMinutes || mins < 360;
  }

  Accent get accent => kAccents[accentIndex.clamp(0, kAccents.length - 1)];
  String get effectivePin => customPin ?? '0000';
  bool get hasCustomPin => customPin != null;

  ThemeMode get themeMode => switch (appearanceMode) {
        1 => ThemeMode.light,
        2 => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  EPGChannel? channelById(int id) {
    for (final c in all) {
      if (c.streamId == id) return c;
    }
    return null;
  }

  // MARK: Recently watched + reminders

  Future<void> recordRecent(int streamId) async {
    recentIds.remove(streamId);
    recentIds.insert(0, streamId);
    if (recentIds.length > 12) {
      recentIds = recentIds.sublist(0, 12);
    }
    await _prefs?.setStringList(_recentsKeyFor(activeProfileId),
        recentIds.map((e) => e.toString()).toList());
    // Timestamps powering the Jump Back In banner.
    final now = DateTime.now().millisecondsSinceEpoch;
    await _prefs?.setInt('viu_recent_at_$streamId', now);
    await _prefs?.setInt('viu_last_watched_at', now);
    notifyListeners();
  }

  /// When a channel was last watched (epoch ms), or null if unknown.
  int? recentAtMs(int streamId) => _prefs?.getInt('viu_recent_at_$streamId');

  /// The Recently Watched rail contents, with the same Kids / language
  /// visibility rules as the channel list.
  List<EPGChannel> recentChannels() {
    final out = <EPGChannel>[];
    for (final id in recentIds) {
      final c = channelById(id);
      if (c == null) continue;
      if (kidsMode && !c.tags.contains('KIDS')) continue;
      if (languageFilter.isNotEmpty && c.language.code != languageFilter) {
        continue;
      }
      out.add(c);
    }
    return out;
  }

  static String reminderKey(EPGChannel c, EPGProgramme p) =>
      '${c.streamId}|${p.timeStart?.millisecondsSinceEpoch ?? 0}';

  bool hasReminder(EPGChannel c, EPGProgramme p) =>
      reminderKeys.contains(reminderKey(c, p));

  /// Set or cancel a Remind Me notification. Returns false when the
  /// reminder could not be scheduled (unsupported platform, or the
  /// programme has already started).
  Future<bool> setReminder(
      EPGChannel channel, EPGProgramme programme, bool enabled) async {
    final start = programme.timeStart;
    if (start == null) return false;
    if (enabled) {
      final ok = await ReminderService.schedule(
        streamId: channel.streamId,
        channelName: channel.name,
        programmeName: programme.name,
        start: start,
      );
      if (!ok) return false;
      reminderKeys.add(reminderKey(channel, programme));
    } else {
      await ReminderService.cancel(streamId: channel.streamId, start: start);
      reminderKeys.remove(reminderKey(channel, programme));
    }
    await _prefs?.setStringList('viu_reminders', reminderKeys.toList());
    notifyListeners();
    return true;
  }

  /// Drop reminder keys whose programme ended over an hour ago.
  void _pruneReminders() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 3600000;
    reminderKeys.removeWhere((key) {
      final ms = int.tryParse(key.split('|').last) ?? 0;
      return ms < cutoff;
    });
  }

  bool isLocked(EPGChannel c) => parentalEnabled && locked.contains(c.streamId);

  List<EPGChannel> _applyLanguage(List<EPGChannel> list) {
    if (languageFilter.isEmpty) return list;
    return list.where((c) => c.language.code == languageFilter).toList();
  }

  List<EPGTag> visibleTags() {
    if (kidsMode) {
      return tags.where((t) => t.parameterName == 'KIDS').toList();
    }
    var list = tags.where((t) => t.parameterName != 'FAVORITES').toList();
    if (tagOrder.isNotEmpty) {
      int rank(String p) {
        final i = tagOrder.indexOf(p);
        return i < 0 ? 9999 : i;
      }

      list.sort((a, b) => rank(a.parameterName).compareTo(rank(b.parameterName)));
    }
    list = list.where((t) => !hiddenTags.contains(t.parameterName)).toList();
    if (sportsMode) {
      list = list.where((t) => isSportsTag(t.parameterName)).toList();
    }
    return list;
  }

  List<EPGChannel> channelsFor(EPGTag tag) {
    List<EPGChannel> base;
    if (tag.parameterName == 'ALL' && sportsMode && !kidsMode) {
      base = all.where((c) => c.tags.any(isSportsTag)).toList();
    } else {
      base = byTag[tag.parameterName] ??
          all.where((c) => c.tags.contains(tag.parameterName)).toList();
    }
    return _applyLanguage(base);
  }

  /// All favorite ids in display order: pinned first (in pin order),
  /// then the user's saved order, then any remaining favorites in
  /// guide order. Mode/language filters are NOT applied here so the
  /// stored order stays stable while filters change.
  List<int> orderedFavoriteIds() {
    final out = <int>[];
    final used = <int>{};
    for (final id in favPins) {
      if (favorites.contains(id) && used.add(id)) out.add(id);
    }
    for (final id in favOrder) {
      if (favorites.contains(id) && used.add(id)) out.add(id);
    }
    for (final c in all) {
      if (favorites.contains(c.streamId) && used.add(c.streamId)) {
        out.add(c.streamId);
      }
    }
    // Favorites whose channel is not in the current guide still keep
    // their relative order at the end.
    for (final id in favorites) {
      if (used.add(id)) out.add(id);
    }
    return out;
  }

  List<EPGChannel> favoriteChannels() {
    var favs = all.where((c) => favorites.contains(c.streamId)).toList();
    if (kidsMode) {
      favs = favs.where((c) => c.tags.contains('KIDS')).toList();
    } else if (sportsMode) {
      favs = favs.where((c) => c.tags.any(isSportsTag)).toList();
    }
    favs = _applyLanguage(favs);
    final rank = <int, int>{};
    final order = orderedFavoriteIds();
    for (var i = 0; i < order.length; i++) {
      rank[order[i]] = i;
    }
    favs.sort((a, b) =>
        (rank[a.streamId] ?? 1 << 30).compareTo(rank[b.streamId] ?? 1 << 30));
    return favs;
  }

  Future<void> _saveFavOrderAndPins() async {
    await _prefs?.setStringList(_favOrderKeyFor(activeProfileId),
        favOrder.map((e) => e.toString()).toList());
    await _prefs?.setStringList(_favPinsKeyFor(activeProfileId),
        favPins.map((e) => e.toString()).toList());
  }

  /// Rewrite the stored order/pins from a full display-order id list,
  /// keeping the pin set unchanged (pin order follows display order).
  Future<void> _storeFavoriteDisplayOrder(List<int> displayIds) async {
    final pinSet = favPins.toSet();
    favPins = displayIds.where(pinSet.contains).toList();
    favOrder = displayIds.where((id) => !pinSet.contains(id)).toList();
    await _saveFavOrderAndPins();
  }

  bool isPinned(EPGChannel c) => favPins.contains(c.streamId);

  Future<void> togglePin(EPGChannel c) async {
    if (favPins.contains(c.streamId)) {
      favPins.remove(c.streamId);
      // Stay near the top of the unpinned section after unpinning.
      favOrder.remove(c.streamId);
      favOrder.insert(0, c.streamId);
    } else {
      favPins.add(c.streamId);
      favOrder.remove(c.streamId);
    }
    await _saveFavOrderAndPins();
    notifyListeners();
  }

  /// Move a favorite one step in display order. Crossing the boundary
  /// between the pinned and unpinned sections unpins (moving down) or
  /// pins (moving up) the channel, which is what the user sees happen.
  Future<void> moveFavorite(EPGChannel c, int delta) async {
    final ids = orderedFavoriteIds();
    final i = ids.indexOf(c.streamId);
    if (i < 0) return;
    final j = i + delta;
    if (j < 0 || j >= ids.length) return;
    final pinCount = ids.where(favPins.contains).length;
    ids.removeAt(i);
    ids.insert(j, c.streamId);
    if (delta > 0 && i < pinCount && j >= pinCount) {
      favPins.remove(c.streamId);
    } else if (delta < 0 && i >= pinCount && j < pinCount) {
      favPins.add(c.streamId);
    }
    await _storeFavoriteDisplayOrder(ids);
    notifyListeners();
  }

  /// Reorder from the Favorites page drag-and-drop. [visibleIds] is the
  /// (possibly mode-filtered) list the user was looking at; invisible
  /// favorites keep their places around the visible ones.
  Future<void> reorderFavorites(
      List<int> visibleIds, int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= visibleIds.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= visibleIds.length) return;
    final moved = visibleIds.removeAt(oldIndex);
    visibleIds.insert(newIndex, moved);
    final visibleSet = visibleIds.toSet();
    var vi = 0;
    final merged = orderedFavoriteIds()
        .map((id) => visibleSet.contains(id) ? visibleIds[vi++] : id)
        .toList();
    await _storeFavoriteDisplayOrder(merged);
    notifyListeners();
  }

  // MARK: Profiles + custom groups

  Future<void> _saveProfiles() async {
    await _prefs?.setString(
        'viu_profiles', jsonEncode(profiles.map((p) => p.toJson()).toList()));
    await _prefs?.setString('viu_active_profile', activeProfileId);
  }

  /// Load favorites / recents / groups / order for the active profile.
  void _loadProfileData() {
    final p = _prefs;
    if (p == null) return;
    favorites = (p.getStringList(_favKeyFor(activeProfileId)) ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    recentIds = (p.getStringList(_recentsKeyFor(activeProfileId)) ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    favOrder = (p.getStringList(_favOrderKeyFor(activeProfileId)) ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    favPins = (p.getStringList(_favPinsKeyFor(activeProfileId)) ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    groups = [];
    final rawGroups = p.getString(_groupsKeyFor(activeProfileId));
    if (rawGroups != null && rawGroups.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawGroups);
        if (decoded is List) {
          groups = decoded
              .whereType<Map>()
              .map((e) => ViuGroup.fromJson(e.cast<String, dynamic>()))
              .where((g) => g.id.isNotEmpty)
              .toList();
        }
      } catch (_) {
        groups = [];
      }
    }
  }

  Future<void> switchProfile(String id) async {
    if (id == activeProfileId) return;
    if (!profiles.any((p) => p.id == id)) return;
    activeProfileId = id;
    _loadProfileData();
    await _saveProfiles();
    notifyListeners();
    // Back on the main profile, re-merge the website favorites.
    if (id == 'main' && token != null) {
      unawaited(loadEpg());
    }
  }

  Future<void> addProfile(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final id = 'p${DateTime.now().millisecondsSinceEpoch}';
    profiles.add(ViuProfile(id: id, name: trimmed));
    await _saveProfiles();
    await switchProfile(id);
  }

  Future<void> renameProfile(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    for (final p in profiles) {
      if (p.id == id) p.name = trimmed;
    }
    await _saveProfiles();
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    if (profiles.length <= 1) return;
    profiles.removeWhere((p) => p.id == id);
    final p = _prefs;
    await p?.remove(_favKeyFor(id));
    await p?.remove(_recentsKeyFor(id));
    await p?.remove(_groupsKeyFor(id));
    await p?.remove(_favOrderKeyFor(id));
    await p?.remove(_favPinsKeyFor(id));
    if (activeProfileId == id) {
      activeProfileId = profiles.first.id;
      _loadProfileData();
    }
    await _saveProfiles();
    notifyListeners();
  }

  Future<void> _saveGroups() async {
    await _prefs?.setString(_groupsKeyFor(activeProfileId),
        jsonEncode(groups.map((g) => g.toJson()).toList()));
  }

  Future<ViuGroup> createGroup(String name) async {
    final group = ViuGroup(
      id: 'g${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Group' : name.trim(),
    );
    groups.add(group);
    await _saveGroups();
    notifyListeners();
    return group;
  }

  Future<void> renameGroup(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    for (final g in groups) {
      if (g.id == id) g.name = trimmed;
    }
    await _saveGroups();
    notifyListeners();
  }

  Future<void> deleteGroup(String id) async {
    groups.removeWhere((g) => g.id == id);
    await _saveGroups();
    notifyListeners();
  }

  ViuGroup? groupById(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  bool groupContains(String groupId, int streamId) =>
      groupById(groupId)?.channelIds.contains(streamId) ?? false;

  Future<void> addToGroup(String groupId, EPGChannel channel) async {
    final g = groupById(groupId);
    if (g == null) return;
    if (!g.channelIds.contains(channel.streamId)) {
      g.channelIds.add(channel.streamId);
      await _saveGroups();
      notifyListeners();
    }
  }

  Future<void> removeFromGroup(String groupId, EPGChannel channel) async {
    final g = groupById(groupId);
    if (g == null) return;
    if (g.channelIds.remove(channel.streamId)) {
      await _saveGroups();
      notifyListeners();
    }
  }

  /// A group's channels in group order, with the same Kids / language
  /// visibility rules as the rest of the home list.
  List<EPGChannel> groupChannels(ViuGroup group) {
    final out = <EPGChannel>[];
    for (final id in group.channelIds) {
      final c = channelById(id);
      if (c == null) continue;
      if (kidsMode && !c.tags.contains('KIDS')) continue;
      if (languageFilter.isNotEmpty && c.language.code != languageFilter) {
        continue;
      }
      out.add(c);
    }
    return out;
  }

  // MARK: Persistence + boot

  Future<void> boot() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    token = await _secure.read(key: 'viu_token');
    username = prefs.getString('viu_username');
    // Profiles (2.0.0): default to the single Main profile.
    final rawProfiles = prefs.getString('viu_profiles');
    if (rawProfiles != null && rawProfiles.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawProfiles);
        if (decoded is List && decoded.isNotEmpty) {
          profiles = decoded
              .whereType<Map>()
              .map((e) => ViuProfile.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
      } catch (_) {
        // Keep the default Main profile.
      }
    }
    if (profiles.isEmpty) {
      profiles = [ViuProfile(id: 'main', name: 'Main')];
    }
    activeProfileId = prefs.getString('viu_active_profile') ?? 'main';
    if (!profiles.any((p) => p.id == activeProfileId)) {
      activeProfileId = profiles.first.id;
    }
    _loadProfileData();
    locked = (prefs.getStringList('viu_locked') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    reminderKeys = (prefs.getStringList('viu_reminders') ?? []).toSet();
    _pruneReminders();
    hiddenTags = (prefs.getStringList('viu_hidden_tags') ?? []).toSet();
    tagOrder = prefs.getStringList('viu_tag_order') ?? [];
    accentIndex = prefs.getInt('viu_accent') ?? 0;
    appearanceMode = prefs.getInt('viu_appearance') ?? 0;
    languageFilter = prefs.getString('viu_language_filter') ?? '';
    sportsMode = prefs.getBool('viu_sports_mode') ?? false;
    kidsMode = prefs.getBool('viu_kids_mode') ?? false;
    parentalEnabled = prefs.getBool('viu_parental_enabled') ?? false;
    extraLarge = prefs.getBool('viu_extra_large') ?? false;
    kidsBedtimeEnabled = prefs.getBool('viu_kids_bedtime') ?? false;
    kidsBedtimeMinutes = prefs.getInt('viu_kids_bedtime_minutes') ?? 1200;
    customPin = await _secure.read(key: 'viu_parental_pin');
    // Bedtime lock engages while the app is running, not just at
    // launch: re-check every 30 s (cheap; only notifies when relevant).
    _bedtimeTimer?.cancel();
    _bedtimeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (kidsMode && kidsBedtimeEnabled) notifyListeners();
    });
    if (token != null) {
      api.token = token;
      await refreshAccountAndEpg();
    }
    booted = true;
    notifyListeners();
  }

  Future<void> _saveFavorites() async => _prefs?.setStringList(
      _favKeyFor(activeProfileId),
      favorites.map((e) => e.toString()).toList());
  Future<void> _saveLocked() async => _prefs?.setStringList(
      'viu_locked', locked.map((e) => e.toString()).toList());
  Future<void> _saveSettings() async {
    final p = _prefs;
    if (p == null) return;
    await p.setStringList('viu_hidden_tags', hiddenTags.toList());
    await p.setStringList('viu_tag_order', tagOrder);
    await p.setInt('viu_accent', accentIndex);
    await p.setInt('viu_appearance', appearanceMode);
    await p.setString('viu_language_filter', languageFilter);
    await p.setBool('viu_sports_mode', sportsMode);
    await p.setBool('viu_kids_mode', kidsMode);
    await p.setBool('viu_parental_enabled', parentalEnabled);
    await p.setBool('viu_extra_large', extraLarge);
    await p.setBool('viu_kids_bedtime', kidsBedtimeEnabled);
    await p.setInt('viu_kids_bedtime_minutes', kidsBedtimeMinutes);
  }

  Future<void> setExtraLarge(bool v) async {
    extraLarge = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setKidsBedtimeEnabled(bool v) async {
    kidsBedtimeEnabled = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setKidsBedtimeMinutes(int minutes) async {
    kidsBedtimeMinutes = minutes.clamp(0, 1439);
    await _saveSettings();
    notifyListeners();
  }

  Future<void> login(String user, String password) async {
    final tok = await api.authenticate(user, password);
    token = tok;
    username = user;
    await _secure.write(key: 'viu_token', value: tok);
    await _prefs?.setString('viu_username', user);
    notifyListeners();
    await refreshAccountAndEpg();
  }

  Future<void> refreshAccountAndEpg() async {
    try {
      account = await api.accountInfo();
      vipKnown = true;
      nonVip = !(account?.hasActiveSubscription ?? false);
      final u = account?.username;
      if (u != null && u.isNotEmpty) username = u;
      notifyListeners();
    } on SessionExpired {
      await signOut();
      return;
    } catch (_) {
      // A network failure must never trigger the VIP gate.
      vipKnown = false;
    }
    await loadEpg();
  }

  Future<void> loadEpg() async {
    epgLoading = true;
    epgError = null;
    notifyListeners();
    try {
      tags = await api.fetchTags();
      final results = await Future.wait(tags.map((t) async {
        try {
          return MapEntry(
              t.parameterName, await api.fetchChannels(t.parameterName));
        } catch (_) {
          return MapEntry(t.parameterName, <EPGChannel>[]);
        }
      }));
      byTag = Map.fromEntries(results);
      final allFeed = byTag['ALL'];
      if (allFeed != null && allFeed.isNotEmpty) {
        all = allFeed;
      } else {
        final seen = <int>{};
        all = [
          for (final list in byTag.values)
            for (final c in list)
              if (seen.add(c.streamId)) c
        ];
      }
      // Favorites: add-only two-way sync with the website list. Only
      // the main profile syncs with the server (2.0.0 profiles);
      // other profiles' favorites are local-only.
      if (isMainProfile) {
        final serverFavs =
            (byTag['FAVORITES'] ?? []).map((c) => c.streamId).toSet();
        final localOnly = favorites.difference(serverFavs);
        favorites = {...favorites, ...serverFavs};
        await _saveFavorites();
        for (final id in localOnly) {
          unawaited(api.saveFavorite(id));
        }
      }
    } on SessionExpired {
      await signOut();
      return;
    } catch (_) {
      epgError =
          'Could not load channels. Check your connection and try again.';
    }
    epgLoading = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    token = null;
    account = null;
    vipKnown = false;
    nonVip = false;
    tags = [];
    byTag = {};
    all = [];
    // Parental controls reset on sign-out (PIN back to default 0000),
    // as does the language filter.
    parentalEnabled = false;
    kidsMode = false;
    sportsMode = false;
    locked = {};
    customPin = null;
    languageFilter = '';
    await _secure.delete(key: 'viu_token');
    await _secure.delete(key: 'viu_parental_pin');
    await _saveLocked();
    await _saveSettings();
    notifyListeners();
  }

  // MARK: Favorites

  bool isFavorite(EPGChannel c) => favorites.contains(c.streamId);

  /// The live-links response reports the server-side favorite flag;
  /// merge it locally without pushing anything back. Main profile
  /// only — other profiles never sync with the server.
  Future<void> mergeFavoriteFromServer(int streamId) async {
    if (!isMainProfile) return;
    if (favorites.add(streamId)) {
      if (!favOrder.contains(streamId) && !favPins.contains(streamId)) {
        favOrder.add(streamId);
        await _saveFavOrderAndPins();
      }
      await _saveFavorites();
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(EPGChannel c) async {
    if (favorites.contains(c.streamId)) {
      favorites.remove(c.streamId);
      favOrder.remove(c.streamId);
      favPins.remove(c.streamId);
      if (isMainProfile) unawaited(api.removeFavorite(c.streamId));
    } else {
      favorites.add(c.streamId);
      if (!favOrder.contains(c.streamId)) favOrder.add(c.streamId);
      if (isMainProfile) unawaited(api.saveFavorite(c.streamId));
    }
    await _saveFavorites();
    await _saveFavOrderAndPins();
    notifyListeners();
  }

  Future<void> clearFavorites() async {
    if (isMainProfile) {
      for (final id in favorites.toList()) {
        unawaited(api.removeFavorite(id));
      }
    }
    favorites = {};
    favOrder = [];
    favPins = [];
    await _saveFavorites();
    await _saveFavOrderAndPins();
    notifyListeners();
  }

  // MARK: Parental controls

  bool verifyPin(String pin) => pin == effectivePin;

  Future<void> setPin(String pin) async {
    customPin = pin;
    await _secure.write(key: 'viu_parental_pin', value: pin);
    notifyListeners();
  }

  Future<void> resetPinToDefault() async {
    customPin = null;
    await _secure.delete(key: 'viu_parental_pin');
    notifyListeners();
  }

  String newResetCode() {
    final code = (100000 + Random().nextInt(900000)).toString();
    _prefs?.setString('viu_pin_reset_code', code);
    _prefs?.setInt('viu_pin_reset_at', DateTime.now().millisecondsSinceEpoch);
    return code;
  }

  bool verifyResetCode(String code) {
    final stored = _prefs?.getString('viu_pin_reset_code');
    final at = _prefs?.getInt('viu_pin_reset_at') ?? 0;
    if (stored == null || stored != code) return false;
    return DateTime.now().millisecondsSinceEpoch - at < 600000;
  }

  Future<void> setParentalEnabled(bool v) async {
    parentalEnabled = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setKidsMode(bool v) async {
    kidsMode = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setSportsMode(bool v) async {
    sportsMode = v;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> toggleLocked(EPGChannel c) async {
    if (locked.contains(c.streamId)) {
      locked.remove(c.streamId);
    } else {
      locked.add(c.streamId);
    }
    await _saveLocked();
    notifyListeners();
  }

  Future<void> restoreCategoryDefaults() async {
    hiddenTags = {};
    tagOrder = [];
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setAccent(int i) async {
    accentIndex = i;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setAppearance(int mode) async {
    appearanceMode = mode;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setLanguageFilter(String code) async {
    languageFilter = code;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setTagHidden(String param, bool hidden) async {
    if (hidden) {
      hiddenTags.add(param);
    } else {
      hiddenTags.remove(param);
    }
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setTagOrder(List<String> order) async {
    tagOrder = order;
    await _saveSettings();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

final AppState appState = AppState();
final CastManager castManager = CastManager();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const ViuMobileApp());
  unawaited(appState.boot());
}

TextTheme _textTheme(Brightness brightness) {
  // Deliberately larger than the Material defaults — the same
  // readability pass as iOS v1.3.1. Styles stay relative so Android's
  // font-size accessibility setting scales them further.
  return const TextTheme(
    headlineMedium: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
    headlineSmall: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
    titleMedium: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 18),
    bodyMedium: TextStyle(fontSize: 17),
    bodySmall: TextStyle(fontSize: 15),
    labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
  );
}

class ViuMobileApp extends StatelessWidget {
  const ViuMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        // Material 3 Expressive: the expressive scheme variant gives
        // bolder, higher-energy color mappings from the same accent
        // seed, paired with large rounded shapes below.
        final light = ColorScheme.fromSeed(
          seedColor: appState.accent.seed,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        );
        final dark = ColorScheme.fromSeed(
          seedColor: appState.accent.seed,
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.expressive,
        );
        ThemeData themeFor(ColorScheme scheme, {bool isDark = false}) {
          return ThemeData(
            useMaterial3: true,
            colorScheme: scheme,
            scaffoldBackgroundColor: isDark ? const Color(0xFF0A0A0E) : null,
            textTheme: _textTheme(isDark ? Brightness.dark : Brightness.light),
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              color: scheme.surfaceContainerLow,
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                textStyle:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28)),
              ),
            ),
            navigationBarTheme: NavigationBarThemeData(
              height: 74,
              indicatorColor: scheme.primaryContainer,
            ),
            navigationRailTheme: NavigationRailThemeData(
              indicatorColor: scheme.primaryContainer,
              selectedIconTheme:
                  IconThemeData(color: scheme.onPrimaryContainer, size: 28),
              unselectedIconTheme: const IconThemeData(size: 26),
              selectedLabelTextStyle: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
              unselectedLabelTextStyle: const TextStyle(fontSize: 14),
            ),
          );
        }

        return MaterialApp(
          title: 'Viu Live TV',
          debugShowCheckedModeBanner: false,
          themeMode: appState.themeMode,
          theme: themeFor(light),
          darkTheme: themeFor(dark, isDark: true),
          // Extra-Large Mode (2.0.0): scale all text by 1.35 on top
          // of the system setting.
          builder: (context, child) {
            if (!appState.extraLarge) return child ?? const SizedBox();
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(textScaler: const TextScaler.linear(1.35)),
              child: child ?? const SizedBox(),
            );
          },
          home: const RootGate(),
        );
      },
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (!appState.booted) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (appState.token == null) return const LoginScreen();
        if (!appState.vipKnown) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text('Checking your subscription…',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          );
        }
        if (appState.nonVip) return const VipGateScreen();
        if (appState.kidsBedtimeActive) return const BedtimeLockScreen();
        return const HomeShell();
      },
    );
  }
}

/// Kids bedtime lock (2.0.0): replaces the whole home UI while Kids
/// Mode's bedtime is in effect. The only way out is the regular PIN
/// flow that turns Kids Mode off.
class BedtimeLockScreen extends StatelessWidget {
  const BedtimeLockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bedtime,
                    size: 84, color: theme.colorScheme.primary),
                const SizedBox(height: 22),
                Text('Bedtime',
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text('Kids Mode resumes in the morning.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center),
                const SizedBox(height: 32),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 26, vertical: 14)),
                  onPressed: () async {
                    if (await _verifyPin(
                        context, 'Enter PIN to turn off Kids Mode')) {
                      await appState.setKidsMode(false);
                    }
                  },
                  child: const Text('Exit Kids Mode',
                      style: TextStyle(fontSize: 17)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Login + subscription gate
// ---------------------------------------------------------------------------

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await appState.login(_user.text.trim(), _pass.text);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('VIU',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 44,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 6,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  Text('Live TV — sign in with your Viu account',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 36),
                  TextField(
                    controller: _user,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                        labelText: 'Email / username',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pass,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                        labelText: 'Password', border: OutlineInputBorder()),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 28),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Sign In',
                            style: TextStyle(fontSize: 18)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VipGateScreen extends StatelessWidget {
  const VipGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = appState.account;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.workspace_premium_outlined,
                      size: 72, color: theme.colorScheme.primary),
                  const SizedBox(height: 20),
                  Text('Non-VIP Found',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 12),
                  Text(
                    'This app needs an active Viu subscription.\n'
                    'Account: ${info?.displayName ?? appState.username ?? ''}'
                    '${info?.premiumStatus != null ? '\nStatus: ${info!.premiumStatus}' : ''}'
                    '${info?.premiumExpiresOn != null ? '\nExpires: ${info!.premiumExpiresOn}' : ''}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: () => launchUrl(Uri.parse('https://viu.to'),
                        mode: LaunchMode.externalApplication),
                    child: const Text('Renew on viu.to',
                        style: TextStyle(fontSize: 18)),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: () => appState.refreshAccountAndEpg(),
                    child: const Text("I've Renewed — Check Again"),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => appState.signOut(),
                    child: const Text('Sign Out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PIN pad (iOS-passcode style, black) — verify / setup / 6-digit code
// ---------------------------------------------------------------------------

class PinPadScreen extends StatefulWidget {
  final String title;
  final int length;
  const PinPadScreen({super.key, required this.title, this.length = 4});

  @override
  State<PinPadScreen> createState() => _PinPadScreenState();
}

class _PinPadScreenState extends State<PinPadScreen> {
  String _entry = '';

  void _press(String key) {
    if (key == 'del') {
      if (_entry.isNotEmpty) {
        setState(() => _entry = _entry.substring(0, _entry.length - 1));
      }
      return;
    }
    if (_entry.length >= widget.length) return;
    setState(() => _entry += key);
    if (_entry.length == widget.length) {
      final value = _entry;
      Future.delayed(const Duration(milliseconds: 180), () {
        if (mounted) Navigator.of(context).pop(value);
      });
    }
  }

  Widget _key(String label) {
    final isDel = label == 'del';
    return Padding(
      padding: const EdgeInsets.all(7),
      child: Material(
        color: Colors.white.withValues(alpha: 0.08),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _press(label),
          child: SizedBox(
            width: 78,
            height: 78,
            child: Center(
              child: isDel
                  ? const Icon(Icons.backspace_outlined,
                      color: Colors.white, size: 27)
                  : Text(label,
                      style: const TextStyle(
                          fontSize: 30,
                          color: Colors.white,
                          fontWeight: FontWeight.w500)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, color: Colors.white, size: 40),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(widget.title,
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 21)),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(widget.length, (i) {
                    final filled = i < _entry.length;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: filled ? Colors.white : Colors.transparent,
                        border: Border.all(color: Colors.white, width: 1.6),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 28),
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [for (final k in row) _key(k)],
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 92),
                    _key('0'),
                    _key('del'),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.white70, fontSize: 17)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> _askPin(BuildContext context, String title,
    {int length = 4}) {
  return Navigator.of(context).push<String>(MaterialPageRoute(
    builder: (_) => PinPadScreen(title: title, length: length),
    fullscreenDialog: true,
  ));
}

Future<bool> _verifyPin(BuildContext context, String title) async {
  final entered = await _askPin(context, title);
  if (entered == null) return false;
  if (appState.verifyPin(entered)) return true;
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Incorrect PIN')));
  }
  return false;
}

/// Gate playback of a locked channel behind the PIN. Returns true when
/// playback may proceed.
Future<bool> ensureUnlocked(BuildContext context, EPGChannel channel) async {
  if (!appState.isLocked(channel)) return true;
  return _verifyPin(context, 'Enter PIN to watch ${channel.name}');
}

/// Forgot-PIN flow: email a 6-digit code to the account address (via the
/// mail app — a standalone app has no mail server), verify it, and
/// reset the PIN to the 0000 default.
Future<void> forgotPinFlow(BuildContext context) async {
  final email = appState.account?.username ?? appState.username ?? '';
  final code = appState.newResetCode();
  final uri = Uri(
    scheme: 'mailto',
    path: email,
    queryParameters: {
      'subject': 'Viu Live TV — PIN reset code',
      'body': 'Your Viu Live TV parental PIN reset code is $code. '
          'It is valid for 10 minutes. Enter it in the app to reset your PIN to 0000.',
    },
  );
  var mailed = false;
  try {
    mailed = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    mailed = false;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(mailed
          ? 'A reset code email is ready in your mail app — send it, then enter the code.'
          : 'No mail app handled the reset email. Enter the code from your email if you received it, or sign out and back in to reset the PIN.')));
  final entered =
      await _askPin(context, 'Enter the 6-digit reset code', length: 6);
  if (entered == null) return;
  if (appState.verifyResetCode(entered)) {
    await appState.resetPinToDefault();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('PIN reset — your PIN is now 0000.')));
    }
  } else if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('That code is incorrect or expired.')));
  }
}

Future<bool> setupPinFlow(BuildContext context) async {
  final first = await _askPin(context, 'Create a new PIN');
  if (first == null) return false;
  final second = await _askPin(context, 'Re-enter the new PIN');
  if (second == null) return false;
  if (first != second) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PINs did not match.')));
    }
    return false;
  }
  await appState.setPin(first);
  return true;
}

Future<void> playChannel(BuildContext context, EPGChannel channel,
    List<EPGChannel> contextList) async {
  if (!await ensureUnlocked(context, channel)) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PlayerScreen(channel: channel, contextList: contextList),
  ));
}

String fmtTime(DateTime t) {
  var h = t.hour % 12;
  if (h == 0) h = 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "20:00" style text for the kids bedtime setting.
String fmtMinutesOfDay(int minutes) {
  final t = DateTime(2000, 1, 1, minutes ~/ 60, minutes % 60);
  return fmtTime(t);
}

/// Simple one-field text prompt used for profile/group names.
Future<String?> _askText(BuildContext context, String title,
    {String initial = '', String hint = 'Name'}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save')),
      ],
    ),
  );
}

/// Profile switcher sheet (2.0.0): used by the home app-bar chip and
/// Settings. Switching reloads favorites / recents / groups.
void showProfileSwitcher(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text('Profiles',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                for (final p in appState.profiles)
                  ListTile(
                    leading: Icon(
                        p.id == appState.activeProfileId
                            ? Icons.person
                            : Icons.person_outline,
                        size: 27),
                    title: Text(p.name, style: const TextStyle(fontSize: 18)),
                    subtitle: p.id == 'main'
                        ? const Text('Favorites sync with the website')
                        : const Text('Favorites are local to this profile'),
                    trailing: p.id == appState.activeProfileId
                        ? Icon(Icons.check,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () async {
                      await appState.switchProfile(p.id);
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.person_add_outlined, size: 27),
                  title: const Text('Add profile',
                      style: TextStyle(fontSize: 18)),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    final name = await _askText(context, 'New profile');
                    if (name != null && name.trim().isNotEmpty) {
                      await appState.addProfile(name);
                    }
                  },
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      );
    },
  );
}

/// "Add to group…" sheet (2.0.0): tapping a group toggles the channel
/// in/out of it; "New group" creates one with the channel inside.
void showAddToGroupSheet(BuildContext context, EPGChannel channel) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text('Add to group',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                if (appState.groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Text('No groups yet — create one below.'),
                  ),
                for (final g in appState.groups)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined, size: 27),
                    title:
                        Text(g.name, style: const TextStyle(fontSize: 18)),
                    trailing: g.channelIds.contains(channel.streamId)
                        ? Icon(Icons.check,
                            color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () async {
                      if (g.channelIds.contains(channel.streamId)) {
                        await appState.removeFromGroup(g.id, channel);
                      } else {
                        await appState.addToGroup(g.id, channel);
                      }
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.create_new_folder_outlined,
                      size: 27),
                  title: const Text('New group',
                      style: TextStyle(fontSize: 18)),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    final name = await _askText(context, 'New group');
                    if (name != null && name.trim().isNotEmpty) {
                      final g = await appState.createGroup(name);
                      await appState.addToGroup(g.id, channel);
                    }
                  },
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      );
    },
  );
}

/// Long-press actions for a channel: favorite toggle and, on Android,
/// a Remind Me for the next programme (mirrors the iOS context menu).
Future<void> showChannelActions(
    BuildContext context, EPGChannel channel,
    {String? groupId}) async {
  final next = channel.nextProgramme();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final fav = appState.isFavorite(channel);
            final hasNext = next != null &&
                next.timeStart != null &&
                next.timeStart!.isAfter(DateTime.now());
            final reminded = hasNext && appState.hasReminder(channel, next);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  leading: LogoTile(channel: channel, size: 42),
                  title: Text(channel.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(channel.nowText(),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                ListTile(
                  leading: Icon(
                      fav ? Icons.favorite : Icons.favorite_border),
                  title: Text(fav
                      ? 'Remove from Favorites'
                      : 'Add to Favorites'),
                  onTap: () {
                    appState.toggleFavorite(channel);
                    Navigator.of(sheetContext).pop();
                  },
                ),
                if (fav) ...[
                  ListTile(
                    leading: Icon(appState.isPinned(channel)
                        ? Icons.push_pin
                        : Icons.push_pin_outlined),
                    title: Text(appState.isPinned(channel)
                        ? 'Unpin Favorite'
                        : 'Pin Favorite'),
                    onTap: () {
                      appState.togglePin(channel);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.arrow_upward),
                    title: const Text('Move Favorite Up'),
                    onTap: () {
                      appState.moveFavorite(channel, -1);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.arrow_downward),
                    title: const Text('Move Favorite Down'),
                    onTap: () {
                      appState.moveFavorite(channel, 1);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                ],
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Add to Group…'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    showAddToGroupSheet(context, channel);
                  },
                ),
                if (groupId != null &&
                    appState.groupById(groupId) != null &&
                    appState.groupContains(groupId, channel.streamId))
                  ListTile(
                    leading: const Icon(Icons.folder_off_outlined),
                    title: Text(
                        'Remove from ${appState.groupById(groupId)!.name}'),
                    onTap: () {
                      appState.removeFromGroup(groupId, channel);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                if (ReminderService.supported && hasNext)
                  ListTile(
                    leading: Icon(reminded
                        ? Icons.notifications_active
                        : Icons.notifications_none),
                    title: Text(reminded
                        ? 'Cancel Reminder: ${next.name}'
                        : 'Remind Me: ${next.name}'),
                    subtitle: Text('Starts ${fmtTime(next.timeStart!)}'),
                    onTap: () async {
                      final ok = await appState.setReminder(
                          channel, next, !reminded);
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(ok
                                ? (reminded
                                    ? 'Reminder cancelled.'
                                    : 'Reminder set for ${next.name}.')
                                : 'Could not set that reminder.'),
                          ),
                        );
                      }
                    },
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Shared channel widgets
// ---------------------------------------------------------------------------

class LanguageBadge extends StatelessWidget {
  final String code;
  const LanguageBadge({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(code.toUpperCase(),
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: scheme.primary)),
    );
  }
}

class LogoTile extends StatelessWidget {
  final EPGChannel channel;
  final double size;
  const LogoTile({super.key, required this.channel, this.size = 54});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.live_tv,
          size: size * 0.5, color: scheme.onSurfaceVariant),
    );
    final url = channel.streamIcon;
    if (url == null || url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

/// Thin progress bar for a live programme with an "ends 9:30 PM"
/// label (2.0.0), used under the now/next text on rows and cards.
class NowProgressBar extends StatelessWidget {
  final EPGProgramme programme;
  final bool showEnds;
  const NowProgressBar(
      {super.key, required this.programme, this.showEnds = true});

  @override
  Widget build(BuildContext context) {
    final start = programme.timeStart;
    final end = programme.timeEnd;
    if (start == null || end == null) return const SizedBox.shrink();
    final total = end.difference(start).inSeconds;
    if (total <= 0) return const SizedBox.shrink();
    final done = DateTime.now().difference(start).inSeconds;
    final fraction = (done / total).clamp(0.0, 1.0).toDouble();
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            color: scheme.primary,
          ),
        ),
        if (showEnds) ...[
          const SizedBox(width: 10),
          Text('ends ${fmtTime(end)}',
              style:
                  TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}

/// "starts in 23m" / "starts in 2h 5m" / "starting now" for an
/// upcoming programme; '' when it has no start time.
String startsInText(EPGProgramme? p) {
  final s = p?.timeStart;
  if (s == null) return '';
  final d = s.difference(DateTime.now());
  if (d.isNegative || d.inMinutes < 1) return 'starting now';
  if (d.inHours >= 1) {
    final m = d.inMinutes % 60;
    return m > 0
        ? 'starts in ${d.inHours}h ${m}m'
        : 'starts in ${d.inHours}h';
  }
  return 'starts in ${d.inMinutes}m';
}

/// One channel row — the mobile counterpart of the iOS v1.3.1 row:
/// 54 pt logo, big semibold name, language badge right after the name,
/// current programme, progress bar, then the next programme.
class ChannelRow extends StatelessWidget {
  final EPGChannel channel;
  final List<EPGChannel> contextList;

  /// Set when the row is rendered inside a custom group section, so
  /// the long-press menu can offer "Remove from <group>".
  final String? groupId;
  const ChannelRow(
      {super.key,
      required this.channel,
      required this.contextList,
      this.groupId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final fav = appState.isFavorite(channel);
        final locked = appState.isLocked(channel);
        final nowProg = channel.nowProgramme();
        final liveNow =
            nowProg != null && nowProg.isLiveAt(DateTime.now());
        final next = channel.nextProgramme();
        final startsIn = startsInText(next);
        return InkWell(
          onTap: () => playChannel(context, channel, contextList),
          onLongPress: () =>
              showChannelActions(context, channel, groupId: groupId),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: 16, vertical: appState.extraLarge ? 16 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LogoTile(channel: channel),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(channel.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium),
                          ),
                          const SizedBox(width: 8),
                          LanguageBadge(code: channel.language.code),
                          if (locked) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.lock,
                                size: 17, color: scheme.onSurfaceVariant),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(channel.nowText(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                      if (liveNow) ...[
                        const SizedBox(height: 6),
                        NowProgressBar(programme: nowProg),
                      ],
                      const SizedBox(height: 3),
                      Text(
                          'Next: ${next?.name ?? '—'}'
                          '${startsIn.isEmpty ? '' : ' • $startsIn'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    fav ? Icons.favorite : Icons.favorite_border,
                    color: fav ? const Color(0xFFFFD60A) : scheme.outline,
                    size: 27,
                  ),
                  onPressed: () => appState.toggleFavorite(channel),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Home shell: bottom navigation (Channels / Favorites / Settings)
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _pages = [ChannelsPage(), FavoritesPage(), SettingsPage()];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Phones: bottom navigation bar. Tablets (>= 600 dp wide): a
        // Material 3 Expressive navigation rail, extended with labels
        // beside the icons on wide screens.
        if (constraints.maxWidth < 600) {
          return Scaffold(
            body: IndexedStack(index: _tab, children: _pages),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.live_tv_outlined),
                    selectedIcon: Icon(Icons.live_tv),
                    label: 'Channels'),
                NavigationDestination(
                    icon: Icon(Icons.favorite_border),
                    selectedIcon: Icon(Icons.favorite),
                    label: 'Favorites'),
                NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: 'Settings'),
              ],
            ),
          );
        }
        final extended = constraints.maxWidth >= 1000;
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                extended: extended,
                labelType:
                    extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                      icon: Icon(Icons.live_tv_outlined),
                      selectedIcon: Icon(Icons.live_tv),
                      label: Text('Channels')),
                  NavigationRailDestination(
                      icon: Icon(Icons.favorite_border),
                      selectedIcon: Icon(Icons.favorite),
                      label: Text('Favorites')),
                  NavigationRailDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: Text('Settings')),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: IndexedStack(index: _tab, children: _pages)),
            ],
          ),
        );
      },
    );
  }
}

/// A grid of channel cards for wide screens (tablets), shared by the
/// Channels, Favorites and Search pages.
Widget channelGrid(List<EPGChannel> channels) {
  return GridView.builder(
    padding: const EdgeInsets.all(16),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 360,
      mainAxisExtent: 208,
      crossAxisSpacing: 14,
      mainAxisSpacing: 14,
    ),
    itemCount: channels.length,
    itemBuilder: (context, i) =>
        ChannelCard(channel: channels[i], contextList: channels),
  );
}

/// A channel card for the tablet grid: big logo, name + language badge,
/// current programme with progress, and the next programme.
class ChannelCard extends StatelessWidget {
  final EPGChannel channel;
  final List<EPGChannel> contextList;
  final String? groupId;
  const ChannelCard(
      {super.key,
      required this.channel,
      required this.contextList,
      this.groupId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final fav = appState.isFavorite(channel);
        final locked = appState.isLocked(channel);
        final nowProg = channel.nowProgramme();
        final liveNow =
            nowProg != null && nowProg.isLiveAt(DateTime.now());
        final next = channel.nextProgramme();
        final startsIn = startsInText(next);
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => playChannel(context, channel, contextList),
            onLongPress: () =>
                showChannelActions(context, channel, groupId: groupId),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LogoTile(channel: channel, size: 56),
                      const Spacer(),
                      if (locked)
                        Padding(
                          padding: const EdgeInsets.only(top: 10, right: 2),
                          child: Icon(Icons.lock,
                              size: 19, color: scheme.onSurfaceVariant),
                        ),
                      IconButton(
                        icon: Icon(
                          fav ? Icons.favorite : Icons.favorite_border,
                          color:
                              fav ? const Color(0xFFFFD60A) : scheme.outline,
                          size: 26,
                        ),
                        onPressed: () => appState.toggleFavorite(channel),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Flexible(
                        child: Text(channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium),
                      ),
                      const SizedBox(width: 8),
                      LanguageBadge(code: channel.language.code),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(channel.nowText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  if (liveNow) ...[
                    const SizedBox(height: 6),
                    NowProgressBar(programme: nowProg),
                  ],
                  const SizedBox(height: 3),
                  Text(
                      'Next: ${next?.name ?? '—'}'
                      '${startsIn.isEmpty ? '' : ' • $startsIn'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

Widget _castAppBarButton(BuildContext context) {
  return ListenableBuilder(
    listenable: castManager,
    builder: (context, _) {
      final casting = castManager.connectedDeviceName != null;
      return IconButton(
        icon: Icon(casting ? Icons.cast_connected : Icons.cast, size: 27),
        tooltip: 'Cast to TV',
        onPressed: () => showCastPicker(context),
      );
    },
  );
}

class ChannelsPage extends StatefulWidget {
  const ChannelsPage({super.key});
  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  String _selectedParam = 'ALL';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final tags = appState.visibleTags();
        if (tags.isNotEmpty &&
            !tags.any((t) => t.parameterName == _selectedParam)) {
          _selectedParam = tags.first.parameterName;
        }
        EPGTag? selected;
        for (final tag in tags) {
          if (tag.parameterName == _selectedParam) {
            selected = tag;
            break;
          }
        }
        final channels =
            selected == null ? <EPGChannel>[] : appState.channelsFor(selected);
        final width = MediaQuery.sizeOf(context).width;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Viu Live TV'),
            actions: [
              // Active profile chip (2.0.0) — tap to switch profiles.
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => showProfileSwitcher(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person, size: 18),
                      const SizedBox(width: 5),
                      Text(appState.activeProfile.name,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.view_timeline_outlined, size: 27),
                tooltip: 'Guide',
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GuidePage())),
              ),
              IconButton(
                icon: const Icon(Icons.search, size: 27),
                tooltip: 'Search',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SearchPage())),
              ),
              if (MultiviewScreen.available(context) &&
                  appState.all.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.grid_view, size: 26),
                  tooltip: 'Multiview',
                  onPressed: () {
                    final recents = appState.recentChannels();
                    final initial =
                        recents.isNotEmpty ? recents.first : appState.all.first;
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => MultiviewScreen(initial: initial)));
                  },
                ),
              _castAppBarButton(context),
            ],
          ),
          body: appState.epgError != null && appState.all.isEmpty
              ? _errorView()
              : (width >= 600
                  ? _wideBody(tags, channels, width)
                  : _phoneBody(tags, channels)),
        );
      },
    );
  }

  /// Recently Watched rail across the top of the All list.
  Widget _recentsRail() {
    final recents = appState.recentChannels();
    if (recents.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text('Recently Watched',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        SizedBox(
          height: 98,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: recents.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final c = recents[i];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => playChannel(context, c, appState.all),
                child: SizedBox(
                  width: 78,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LogoTile(channel: c, size: 50),
                      const SizedBox(height: 5),
                      Text(c.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(appState.epgError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => appState.loadEpg(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results(List<EPGChannel> channels, {required bool grid}) {
    if (appState.epgLoading && appState.all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (channels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            appState.languageFilter.isEmpty
                ? 'No channels in this category.'
                : 'No channels in this language here. Change it in Settings → Channel Language.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => appState.loadEpg(),
      child: grid
          ? channelGrid(channels)
          : ListView.separated(
              itemCount: channels.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 84),
              itemBuilder: (context, i) => ChannelRow(
                channel: channels[i],
                contextList: channels,
              ),
            ),
    );
  }

  /// Phone layout: category chips across the top, channel list below.
  Widget _phoneBody(List<EPGTag> tags, List<EPGChannel> channels) {
    return Column(
      children: [
        SizedBox(
          height: 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: tags.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final tag = tags[i];
              final isSel = tag.parameterName == _selectedParam;
              return ChoiceChip(
                label: Text(tag.displayName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                selected: isSel,
                onSelected: (_) =>
                    setState(() => _selectedParam = tag.parameterName),
              );
            },
          ),
        ),
        Expanded(
          child: _selectedParam == 'ALL'
              ? _allSectionsList(channels)
              : _results(channels, grid: false),
        ),
      ],
    );
  }

  /// Tablet layout: the categories become a proper list in a left pane
  /// (with channel counts), and the channels fill the rest — a list on
  /// smaller tablets, a card grid on large ones.
  Widget _wideBody(List<EPGTag> tags, List<EPGChannel> channels, double width) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            itemCount: tags.length,
            itemBuilder: (context, i) {
              final tag = tags[i];
              final isSel = tag.parameterName == _selectedParam;
              return ListTile(
                title: Text(tag.displayName,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w500)),
                trailing: Text('${appState.channelsFor(tag).length}',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                selected: isSel,
                selectedTileColor:
                    scheme.primaryContainer.withValues(alpha: 0.55),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                onTap: () =>
                    setState(() => _selectedParam = tag.parameterName),
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _selectedParam == 'ALL'
              ? _allSectionsList(channels)
              : _results(channels, grid: width >= 1024),
        ),
      ],
    );
  }

  /// The "All" home list (2.0.0): Jump Back In banner, Recently
  /// Watched, Live Sports Now, the profile's custom groups, then the
  /// full channel list — one scroll, like a streaming home screen.
  Widget _allSectionsList(List<EPGChannel> channels) {
    if (appState.epgLoading && appState.all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: () => appState.loadEpg(),
      child: ListView(
        children: [
          _jumpBackInBanner(),
          _recentsRail(),
          _sportsRail(),
          for (final g in appState.groups) _groupSection(g),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Text('All Channels',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (channels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No channels match the current filters.',
                  textAlign: TextAlign.center),
            )
          else
            for (final c in channels) ...[
              ChannelRow(channel: c, contextList: channels),
              const Divider(height: 1, indent: 84),
            ],
        ],
      ),
    );
  }

  /// Jump Back In (2.0.0): the most recent channel, watched within
  /// the last 3 hours, offered at the very top of home.
  Widget _jumpBackInBanner() {
    if (appState.recentIds.isEmpty) return const SizedBox.shrink();
    final id = appState.recentIds.first;
    final c = appState.channelById(id);
    if (c == null) return const SizedBox.shrink();
    if (appState.kidsMode && !c.tags.contains('KIDS')) {
      return const SizedBox.shrink();
    }
    if (appState.languageFilter.isNotEmpty &&
        c.language.code != appState.languageFilter) {
      return const SizedBox.shrink();
    }
    final at = appState.recentAtMs(id);
    if (at == null) return const SizedBox.shrink();
    final ageMs = DateTime.now().millisecondsSinceEpoch - at;
    if (ageMs < 0 || ageMs > 3 * 3600 * 1000) {
      return const SizedBox.shrink();
    }
    final prog = c.nowProgramme();
    String detail = c.nowText();
    if (prog != null && prog.timeEnd != null) {
      final left = prog.timeEnd!.difference(DateTime.now()).inMinutes;
      if (left > 0) detail = '${prog.name} • $left min left';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              LogoTile(channel: c, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Jump back in — ${c.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => playChannel(context, c, appState.all),
                child: const Text('Play'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Live Sports Now rail (2.0.0): sports-tagged channels with a
  /// programme on right now.
  Widget _sportsRail() {
    final now = DateTime.now();
    var live = appState.all.where((c) {
      if (!c.tags.any((t) => t.contains('SPORT'))) return false;
      final p = c.nowProgramme(now);
      return p != null && p.isLiveAt(now);
    }).toList();
    if (appState.kidsMode) {
      live = live.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (appState.languageFilter.isNotEmpty) {
      live = live
          .where((c) => c.language.code == appState.languageFilter)
          .toList();
    }
    if (live.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text('Live Sports Now',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        SizedBox(
          height: 132,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: live.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final c = live[i];
              final prog = c.nowProgramme();
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => playChannel(context, c, appState.all),
                  onLongPress: () => showChannelActions(context, c),
                  child: SizedBox(
                    width: 248,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              LogoTile(channel: c, size: 40),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontSize: 17)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(c.nowText(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 15.5,
                                  color: scheme.onSurfaceVariant)),
                          const Spacer(),
                          if (prog != null) NowProgressBar(programme: prog),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// One custom-group section (2.0.0): header + its channels in the
  /// group's own order. Hidden when the group is empty after the
  /// Kids / language visibility rules.
  Widget _groupSection(ViuGroup group) {
    final channels = appState.groupChannels(group);
    if (channels.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 21, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(group.name,
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        for (final c in channels) ...[
          ChannelRow(
              channel: c, contextList: channels, groupId: group.id),
          const Divider(height: 1, indent: 84),
        ],
      ],
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final favs = appState.favoriteChannels();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Favorites'),
            actions: [_castAppBarButton(context)],
          ),
          body: favs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      appState.favorites.isEmpty
                          ? 'No favorites yet.\nTap the heart on any channel to save it here.'
                          : 'No favorites match the current mode or language filter.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : MediaQuery.sizeOf(context).width >= 840
                  ? channelGrid(favs)
                  : ReorderableListView.builder(
                      // Drag via the handle so long-press stays free
                      // for the channel actions menu (2.0.0).
                      buildDefaultDragHandles: false,
                      itemCount: favs.length,
                      onReorder: (oldIndex, newIndex) =>
                          appState.reorderFavorites(
                        favs.map((c) => c.streamId).toList(),
                        oldIndex,
                        newIndex,
                      ),
                      itemBuilder: (context, i) {
                        final c = favs[i];
                        return Container(
                          key: ValueKey(c.streamId),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: ChannelRow(
                                  channel: c,
                                  contextList: favs,
                                ),
                              ),
                              if (appState.isPinned(c))
                                const Icon(Icons.push_pin,
                                    size: 18, color: Colors.amber),
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(Icons.drag_handle, size: 26),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        );
      },
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    var results = q.isEmpty
        ? <EPGChannel>[]
        : appState.all
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                c.schedule.any((p) => p.name.toLowerCase().contains(q)))
            .toList();
    if (appState.languageFilter.isNotEmpty) {
      results = results
          .where((c) => c.language.code == appState.languageFilter)
          .toList();
    }
    final shown = results.take(150).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search channels & programmes',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: q.isEmpty
                ? const Center(child: Text('Type to search all channels.'))
                : shown.isEmpty
                    ? const Center(child: Text('No channels match.'))
                    : MediaQuery.sizeOf(context).width >= 840
                        ? channelGrid(shown)
                        : ListView.separated(
                            itemCount: shown.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, indent: 84),
                            itemBuilder: (context, i) => ChannelRow(
                              channel: shown[i],
                              contextList: shown,
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Timeline guide grid (2.0.0): frozen channel column + a horizontally
// scrolling now → +6h timeline of programme blocks.
// ---------------------------------------------------------------------------

class GuidePage extends StatefulWidget {
  const GuidePage({super.key});
  @override
  State<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends State<GuidePage> {
  static const double _rowHeight = 56;
  static const double _headerHeight = 30;
  static const double _pxPerMinute = 2.5;
  static const int _windowMinutes = 360; // 6 hours

  final ScrollController _leftCtrl = ScrollController();
  final ScrollController _rightCtrl = ScrollController();
  bool _syncing = false;
  late final DateTime _start;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    // Keep the frozen channel column in step with the timeline rows.
    _rightCtrl.addListener(() {
      if (_syncing || !_leftCtrl.hasClients) return;
      _syncing = true;
      final maxOff = _leftCtrl.position.maxScrollExtent;
      _leftCtrl.jumpTo(_rightCtrl.offset.clamp(0.0, maxOff));
      _syncing = false;
    });
  }

  @override
  void dispose() {
    _leftCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  List<EPGChannel> _guideChannels() {
    var list = appState.all
        .where((c) => c.schedule
            .any((p) => p.timeStart != null && p.timeEnd != null))
        .toList();
    if (appState.kidsMode) {
      list = list.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (appState.languageFilter.isNotEmpty) {
      list = list
          .where((c) => c.language.code == appState.languageFilter)
          .toList();
    }
    return list;
  }

  void _showProgramme(EPGChannel channel, EPGProgramme p) {
    final pageContext = context;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListenableBuilder(
            listenable: appState,
            builder: (context, _) {
              final isLive = p.isLiveAt(DateTime.now());
              final future = p.timeStart != null &&
                  p.timeStart!.isAfter(DateTime.now());
              final reminded = appState.hasReminder(channel, p);
              final range = (p.timeStart != null && p.timeEnd != null)
                  ? '${fmtTime(p.timeStart!)} – ${fmtTime(p.timeEnd!)}'
                  : '';
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: LogoTile(channel: channel, size: 42),
                    title: Text(channel.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(isLive ? 'On now' : range),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(p.name,
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  if (p.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(p.description,
                          maxLines: 4, overflow: TextOverflow.ellipsis),
                    ),
                  if (range.isNotEmpty && !isLive)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Text(range),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play channel'),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        playChannel(pageContext, channel, appState.all);
                      },
                    ),
                  ),
                  if (ReminderService.supported && future)
                    ListTile(
                      leading: Icon(reminded
                          ? Icons.notifications_active
                          : Icons.notifications_none),
                      title: Text(reminded
                          ? 'Cancel Reminder'
                          : 'Remind Me'),
                      onTap: () async {
                        final ok = await appState.setReminder(
                            channel, p, !reminded);
                        if (sheetContext.mounted && !ok) {
                          ScaffoldMessenger.of(pageContext).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Could not set that reminder.')));
                        }
                      },
                    ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _guideRow(EPGChannel c) {
    final scheme = Theme.of(context).colorScheme;
    final endLimit = _start.add(const Duration(minutes: _windowMinutes));
    final blocks = <Widget>[];
    for (final p in c.schedule) {
      final s = p.timeStart;
      final e = p.timeEnd;
      if (s == null || e == null) continue;
      if (!e.isAfter(_start) || !s.isBefore(endLimit)) continue;
      final leftMin = max(0, s.difference(_start).inMinutes);
      final rightMin = min(_windowMinutes, e.difference(_start).inMinutes);
      final w = (rightMin - leftMin) * _pxPerMinute;
      if (w < 8) continue;
      final live = p.isLiveAt(DateTime.now());
      blocks.add(Positioned(
        left: leftMin * _pxPerMinute + 1,
        top: 5,
        bottom: 5,
        width: w - 2,
        child: Material(
          color: live
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: () => _showProgramme(c, p),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.15)),
            ),
          ),
        ),
      ));
    }
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Stack(children: blocks),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final channels = _guideChannels();
    final truncated = channels.length > 100;
    final shown = truncated ? channels.sublist(0, 100) : channels;
    final totalWidth = _windowMinutes * _pxPerMinute;
    final nowX =
        DateTime.now().difference(_start).inMinutes * _pxPerMinute;
    return Scaffold(
      appBar: AppBar(title: const Text('Guide')),
      body: shown.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No programme data to show yet.',
                    textAlign: TextAlign.center),
              ),
            )
          : Column(
              children: [
                if (truncated)
                  Container(
                    width: double.infinity,
                    color: scheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 6),
                    child: const Text(
                        'Showing the first 100 channels with programme data.'),
                  ),
                Expanded(
                  child: Row(
                    children: [
                      // Frozen channel column.
                      SizedBox(
                        width: 76,
                        child: Column(
                          children: [
                            const SizedBox(height: _headerHeight),
                            Expanded(
                              child: ListView.builder(
                                controller: _leftCtrl,
                                physics:
                                    const NeverScrollableScrollPhysics(),
                                itemExtent: _rowHeight,
                                itemCount: shown.length,
                                itemBuilder: (context, i) {
                                  final c = shown[i];
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 4),
                                    alignment: Alignment.center,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        LogoTile(channel: c, size: 29),
                                        const SizedBox(height: 2),
                                        Text(c.name,
                                            maxLines: 1,
                                            overflow:
                                                TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                                fontSize: 10.5)),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      // Scrollable timeline.
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: totalWidth,
                            child: Column(
                              children: [
                                SizedBox(
                                  height: _headerHeight,
                                  child: Stack(
                                    children: [
                                      for (var i = 0; i <= 12; i++)
                                        Positioned(
                                          left: i * 30 * _pxPerMinute + 4,
                                          top: 6,
                                          child: Text(
                                            fmtTime(_start.add(Duration(
                                                minutes: i * 30))),
                                            style: TextStyle(
                                                fontSize: 12.5,
                                                color:
                                                    scheme.onSurfaceVariant),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Stack(
                                    children: [
                                      ListView.builder(
                                        controller: _rightCtrl,
                                        itemExtent: _rowHeight,
                                        itemCount: shown.length,
                                        itemBuilder: (context, i) =>
                                            _guideRow(shown[i]),
                                      ),
                                      if (nowX >= 0 && nowX <= totalWidth)
                                        Positioned(
                                          left: nowX,
                                          top: 0,
                                          bottom: 0,
                                          child: IgnorePointer(
                                            child: Container(
                                                width: 2,
                                                color: Colors.red),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chromecast device picker
// ---------------------------------------------------------------------------

void showCastPicker(BuildContext context) {
  castManager.startDiscovery();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: castManager,
          builder: (context, _) {
            final connected = castManager.connectedDeviceName;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text('Cast to TV',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                if (castManager.lastError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 6),
                    child: Text(castManager.lastError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                if (connected != null) ...[
                  ListTile(
                    leading: const Icon(Icons.cast_connected),
                    title: Text(connected),
                    subtitle: Text(castManager.isCastingMedia
                        ? 'Casting now'
                        : 'Connected'),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    child: Wrap(
                      spacing: 10,
                      children: [
                        FilledButton.tonal(
                          onPressed: () {
                            castManager.stopCasting();
                            Navigator.of(sheetContext).pop();
                          },
                          child: const Text('Stop casting'),
                        ),
                        OutlinedButton(
                          onPressed: () {
                            castManager.disconnect();
                            Navigator.of(sheetContext).pop();
                          },
                          child: const Text('Disconnect'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                ],
                if (castManager.devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Row(
                      children: [
                        SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5)),
                        SizedBox(width: 14),
                        Expanded(
                            child: Text(
                                'Looking for Chromecast devices on this Wi-Fi…')),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: castManager.devices.length,
                      itemBuilder: (context, i) {
                        final device = castManager.devices[i];
                        return ListTile(
                          leading: const Icon(Icons.tv, size: 30),
                          title: Text(device.friendlyName,
                              style: const TextStyle(fontSize: 18)),
                          onTap: () {
                            castManager.connect(device);
                            Navigator.of(sheetContext).pop();
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 10),
              ],
            );
          },
        ),
      );
    },
  ).whenComplete(() => castManager.stopDiscovery());
}

// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------

class PlayerScreen extends StatefulWidget {
  final EPGChannel channel;
  final List<EPGChannel> contextList;
  const PlayerScreen(
      {super.key, required this.channel, required this.contextList});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;

  late EPGChannel _channel;
  EPGChannel? _previous;
  bool _loading = true;
  bool _buffering = false;
  bool _playing = false;
  String? _error;
  String? _lastError;
  bool _overlay = true;
  bool _fullscreen = false;
  Timer? _hideTimer;
  Timer? _watchdog;
  final List<String> _logTail = [];
  final List<StreamSubscription> _subs = [];

  // 2.0.0: sleep timer (in-memory only).
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  Duration _sleepRemaining = Duration.zero;

  // 2.0.0: auto-reconnect + stream health.
  static const List<Duration> _retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];
  bool _intentPlaying = false;
  String? _currentUrl;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  final List<DateTime> _stallTimes = [];
  final List<DateTime> _errorTimes = [];

  // 2.0.0: audio-only mode (per session).
  bool _audioOnly = false;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  bool get _casting => castManager.connectedDeviceName != null;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _player = Player();
    _controller = VideoController(_player);
    _subs.add(_player.stream.playing.listen((v) {
      if (!mounted) return;
      if (v) {
        _watchdog?.cancel();
        // Playback (re)started — the reconnect ladder resets.
        _retryTimer?.cancel();
        _retryAttempt = 0;
      }
      setState(() {
        _playing = v;
        if (v && _error != null) _error = null;
      });
    }));
    _subs.add(_player.stream.buffering.listen((v) {
      if (!mounted) return;
      // Count stalls (buffering starting after the initial load) for
      // the stream-health indicator.
      if (v && !_buffering && !_loading && _intentPlaying) {
        _stallTimes.add(DateTime.now());
      }
      setState(() => _buffering = v);
    }));
    _subs.add(_player.stream.error.listen((e) {
      // mpv reports transient problems on live streams (famously
      // "Cannot seek in this stream") and then often plays fine, so
      // never fail the channel on an error event alone — the watchdog
      // in _load surfaces the last error only if playback never starts.
      _lastError = e;
      _errorTimes.add(DateTime.now());
      _maybeScheduleRetry();
      if (mounted) setState(() {});
    }));
    _subs.add(_player.stream.log.listen((log) {
      _logTail.add('${log.level}/${log.prefix}: ${log.text}'.trim());
      if (_logTail.length > 10) _logTail.removeAt(0);
    }));
    castManager.addListener(_onCastChanged);
    _showOverlay();
    _initPlayer();
  }

  void _onCastChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initPlayer() async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      // Live IPTV streams are not seekable; left to itself, mpv
      // attempts an opening seek on some of them and errors out with
      // "Cannot seek in this stream". Declaring streams non-seekable
      // up front makes mpv play from the live edge instead.
      try {
        await platform.setProperty('force-seekable', 'no');
        await platform.setProperty('network-timeout', '30');
      } catch (_) {}
    }
    if (mounted) _load(_channel);
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 15), () {
      if (mounted &&
          !_playing &&
          !_casting &&
          _error == null &&
          _retryAttempt == 0 &&
          !(_retryTimer?.isActive ?? false)) {
        setState(() {
          _error = _lastError ?? 'The stream did not start.';
          _loading = false;
        });
      }
    });
  }

  // MARK: Auto-reconnect + stream health (2.0.0)

  /// On a stream error while the user intends to be watching, retry
  /// opening the same URL up to 3 times (2s / 5s / 10s apart).
  void _maybeScheduleRetry() {
    if (!_intentPlaying || _casting) return;
    if (_currentUrl == null) return;
    if (_retryAttempt >= _retryDelays.length) return;
    if (_retryTimer?.isActive ?? false) return;
    final delay = _retryDelays[_retryAttempt];
    _retryAttempt += 1;
    _retryTimer = Timer(delay, _doRetry);
    if (mounted) setState(() {});
  }

  Future<void> _doRetry() async {
    if (!mounted || !_intentPlaying || _casting) return;
    final url = _currentUrl;
    if (url == null) return;
    try {
      await _player.open(
        Media(url, httpHeaders: const {'User-Agent': kUserAgent}),
        play: true,
      );
    } catch (_) {
      // The error stream will schedule the next attempt if any remain.
      _maybeScheduleRetry();
    }
  }

  /// 0 = good, 1 = fair, 2 = poor, from errors/stalls in the last
  /// 5 minutes.
  int get _healthLevel {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    final errors = _errorTimes.where((t) => t.isAfter(cutoff)).length;
    final stalls = _stallTimes.where((t) => t.isAfter(cutoff)).length;
    if (errors > 0 || stalls > 3) return 2;
    if (stalls > 0) return 1;
    return 0;
  }

  String get _healthLabel => switch (_healthLevel) {
        2 => 'Stream health: Poor',
        1 => 'Stream health: Fair',
        _ => 'Stream health: Good',
      };

  Color get _healthColor => switch (_healthLevel) {
        2 => const Color(0xFFE5323B),
        1 => const Color(0xFFFFB340),
        _ => const Color(0xFF35C26B),
      };

  // MARK: Sleep timer (2.0.0)

  void _setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    if (duration == null) {
      setState(() => _sleepRemaining = Duration.zero);
      return;
    }
    _sleepDeadline = DateTime.now().add(duration);
    _sleepRemaining = duration;
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final left = _sleepDeadline!.difference(DateTime.now());
      if (left <= Duration.zero) {
        _sleepTimer?.cancel();
        _sleepTimer = null;
        _sleepDeadline = null;
        setState(() => _sleepRemaining = Duration.zero);
        _intentPlaying = false;
        if (_casting) {
          castManager.togglePlayPause();
        } else {
          _player.pause();
        }
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sleep timer ended')));
      } else {
        setState(() => _sleepRemaining = left);
      }
    });
    setState(() {});
  }

  String get _sleepLabel {
    final s = _sleepRemaining.inSeconds;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '⏱ $m:$ss';
  }

  void _showSleepSheet() {
    _showOverlay();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        Widget option(String label, Duration? value) {
          final active = value == null
              ? _sleepDeadline == null
              : _sleepDeadline != null &&
                  (value.inMinutes - _sleepRemaining.inMinutes).abs() <= 1 &&
                  value.inMinutes > 0;
          return ListTile(
            leading: Icon(active ? Icons.timer : Icons.timer_outlined),
            title: Text(label, style: const TextStyle(fontSize: 18)),
            trailing: active ? const Icon(Icons.check) : null,
            onTap: () {
              _setSleepTimer(value);
              Navigator.of(sheetContext).pop();
            },
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Text('Sleep timer',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              option('Off', null),
              option('15 minutes', const Duration(minutes: 15)),
              option('30 minutes', const Duration(minutes: 30)),
              option('60 minutes', const Duration(minutes: 60)),
              option('90 minutes', const Duration(minutes: 90)),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // MARK: Audio / subtitle tracks + audio-only (2.0.0)

  Future<void> _showTrackPicker() async {
    _showOverlay();
    Tracks? tracks;
    try {
      tracks = _player.state.tracks;
    } catch (_) {
      tracks = null;
    }
    final audio = (tracks?.audio ?? const <AudioTrack>[])
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final subs = (tracks?.subtitle ?? const <SubtitleTrack>[])
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final currentAudio = _player.state.track.audio;
    final currentSub = _player.state.track.subtitle;
    if (!mounted) return;
    String label(String? title, String? language, String fallback) {
      final parts = [
        if (title != null && title.isNotEmpty) title,
        if (language != null && language.isNotEmpty) language,
      ];
      return parts.isEmpty ? fallback : parts.join(' • ');
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text('Audio & subtitles',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                if (audio.isEmpty && subs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Text('No alternate tracks for this stream.'),
                  ),
                if (audio.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 10, 20, 2),
                    child: Text('Audio',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  for (final t in audio)
                    ListTile(
                      title: Text(label(t.title, t.language, 'Audio ${t.id}')),
                      trailing: currentAudio.id == t.id
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () async {
                        try {
                          await _player.setAudioTrack(t);
                        } catch (_) {}
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                    ),
                ],
                if (subs.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 10, 20, 2),
                    child: Text('Subtitles',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  ListTile(
                    title: const Text('Subtitles off'),
                    trailing: currentSub.id == 'no'
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () async {
                      try {
                        await _player.setSubtitleTrack(SubtitleTrack.no());
                      } catch (_) {}
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                  ),
                  for (final t in subs)
                    ListTile(
                      title: Text(
                          label(t.title, t.language, 'Subtitles ${t.id}')),
                      trailing: currentSub.id == t.id
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () async {
                        try {
                          await _player.setSubtitleTrack(t);
                        } catch (_) {}
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                    ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleAudioOnly() async {
    _showOverlay();
    final next = !_audioOnly;
    try {
      await _player.setVideoTrack(
          next ? VideoTrack.no() : VideoTrack.auto());
    } catch (_) {}
    if (mounted) setState(() => _audioOnly = next);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _watchdog?.cancel();
    _sleepTimer?.cancel();
    _retryTimer?.cancel();
    _intentPlaying = false;
    castManager.removeListener(_onCastChanged);
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // Leaving the player ends the cast (same rule as the iOS app).
    if (_casting) castManager.stopCasting();
    super.dispose();
  }

  Future<void> _load(EPGChannel channel) async {
    if (channel.streamId != _channel.streamId) {
      _previous = _channel;
    }
    unawaited(appState.recordRecent(channel.streamId));
    _retryTimer?.cancel();
    _retryAttempt = 0;
    _intentPlaying = true;
    _currentUrl = null;
    setState(() {
      _channel = channel;
      _loading = true;
      _error = null;
      _lastError = null;
    });
    if (!_casting) _armWatchdog();
    try {
      final links = await appState.api.liveLinks(channel.streamId);
      if (links.isFavorite) {
        unawaited(appState.mergeFavoriteFromServer(channel.streamId));
      }
      final url = links.liveLink;
      if (url == null || url.isEmpty) {
        throw const ApiFailure('This channel returned no playable link.');
      }
      _currentUrl = url;
      if (_casting) {
        await _player.pause();
        castManager.load(url, channel.name, channel.streamIcon);
      } else {
        await _player.open(
          Media(url, httpHeaders: const {'User-Agent': kUserAgent}),
          play: true,
        );
      }
      if (mounted) setState(() => _loading = false);
    } on SessionExpired {
      if (mounted) {
        setState(() {
          _error = 'Your session expired. Sign out and back in.';
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _showOverlay() {
    if (!_overlay && mounted) setState(() => _overlay = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  void _toggleOverlay() {
    if (_overlay) {
      _hideTimer?.cancel();
      setState(() => _overlay = false);
    } else {
      _showOverlay();
    }
  }

  void _togglePlay() {
    if (_casting) {
      castManager.togglePlayPause();
    } else if (_playing) {
      _intentPlaying = false;
      _retryTimer?.cancel();
      _player.pause();
    } else {
      _intentPlaying = true;
      _player.play();
    }
    _showOverlay();
  }

  /// Last Channel swap: jump back to the previous channel (which
  /// then becomes current, so the button swaps back and forth).
  Future<void> _swapToPrevious() async {
    final target = _previous;
    if (target == null) return;
    if (!await ensureUnlocked(context, target)) return;
    if (mounted) _load(target);
  }

  Future<void> _openMultiview() async {
    _showOverlay();
    final wasPlaying = _playing;
    await _player.pause();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<EPGChannel>(
      MaterialPageRoute(
          builder: (_) => MultiviewScreen(initial: _channel)),
    );
    if (!mounted) return;
    if (picked != null && picked.streamId != _channel.streamId) {
      if (await ensureUnlocked(context, picked)) {
        if (mounted) _load(picked);
      }
    } else if (wasPlaying && !_casting) {
      _player.play();
    }
  }

  Future<void> _hop(int delta) async {
    final list = widget.contextList;
    if (list.isEmpty) return;
    final idx = list.indexWhere((c) => c.streamId == _channel.streamId);
    if (idx < 0) return;
    final next = (idx + delta).clamp(0, list.length - 1);
    if (next == idx) return;
    final target = list[next];
    if (!await ensureUnlocked(context, target)) return;
    if (mounted) _load(target);
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _showOverlay();
  }

  void _openGuide() {
    _showOverlay();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.92,
          builder: (context, scrollController) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text('Guide',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    itemCount: widget.contextList.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 84),
                    itemBuilder: (context, i) {
                      final c = widget.contextList[i];
                      final isCurrent = c.streamId == _channel.streamId;
                      return ListTile(
                        leading: LogoTile(channel: c, size: 44),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(c.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: isCurrent
                                          ? FontWeight.w700
                                          : FontWeight.w500)),
                            ),
                            const SizedBox(width: 8),
                            LanguageBadge(code: c.language.code),
                          ],
                        ),
                        subtitle: Text(c.nowText(),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: isCurrent
                            ? Icon(Icons.play_circle_fill,
                                color: Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: () async {
                          Navigator.of(sheetContext).pop();
                          if (isCurrent) return;
                          if (!await ensureUnlocked(context, c)) return;
                          if (mounted) _load(c);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onTap, {double size = 30}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }

  /// Desktop keyboard shortcuts (2.0.0): F favorite, L last channel,
  /// M multiview, Esc back. No-ops on touch platforms.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!_isDesktop) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyF) {
      appState.toggleFavorite(_channel);
      _showOverlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL) {
      _swapToPrevious();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      if (MultiviewScreen.available(context)) _openMultiview();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final casting = _casting;
    final remotePlaying = castManager.remotePlayerState == 'PLAYING';
    return Focus(
      autofocus: _isDesktop,
      onKeyEvent: _handleKey,
      child: Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleOverlay,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (casting)
              Container(
                color: const Color(0xFF101014),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cast_connected,
                        size: 84, color: Colors.white70),
                    const SizedBox(height: 18),
                    Text('Casting to ${castManager.connectedDeviceName}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(_channel.name,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 18)),
                    ),
                    const SizedBox(height: 6),
                    Text(
                        castManager.remotePlayerState.isEmpty
                            ? 'Starting…'
                            : castManager.remotePlayerState,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 15)),
                  ],
                ),
              )
            else
              Video(controller: _controller, fit: BoxFit.contain),
            // Audio-only mode (2.0.0): black cover with the channel
            // identity while the video track is disabled.
            if (_audioOnly && !casting)
              Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LogoTile(channel: _channel, size: 110),
                    const SizedBox(height: 16),
                    Text(_channel.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Text(_channel.nowText(),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 16)),
                    ),
                    const SizedBox(height: 10),
                    const Text('Audio only',
                        style:
                            TextStyle(color: Colors.white38, fontSize: 14)),
                  ],
                ),
              ),
            if (_error != null && !casting)
              Container(
                color: Colors.black.withValues(alpha: 0.88),
                padding: const EdgeInsets.all(24),
                alignment: Alignment.center,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          color: Colors.white70, size: 52),
                      const SizedBox(height: 14),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18)),
                      if (_logTail.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        SelectableText(_logTail.join('\n'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12)),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => _load(_channel),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            if ((_loading || _buffering) && _error == null)
              const Center(child: CircularProgressIndicator()),
            // Reconnecting banner (2.0.0).
            if (_retryAttempt > 0 && _error == null && !casting)
              Positioned(
                top: MediaQuery.of(context).padding.top + 66,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('Reconnecting… attempt $_retryAttempt',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14.5)),
                  ),
                ),
              ),
            // Sleep timer countdown chip (2.0.0).
            if (_sleepDeadline != null)
              Positioned(
                right: 14,
                bottom: MediaQuery.of(context).padding.bottom + 100,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(_sleepLabel,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14.5)),
                ),
              ),
            // Top bar
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              top: _overlay ? 0 : -110,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 6,
                    left: 8,
                    right: 8,
                    bottom: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    _circleButton(Icons.arrow_back,
                        () => Navigator.of(context).pop(),
                        size: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w600)),
                          Text(_channel.nowText(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 15)),
                        ],
                      ),
                    ),
                    _circleButton(
                        casting ? Icons.cast_connected : Icons.cast,
                        () => showCastPicker(context),
                        size: 26),
                    const SizedBox(width: 4),
                    // Stream health dot (2.0.0).
                    Tooltip(
                      message: _healthLabel,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                            color: _healthColor, shape: BoxShape.circle),
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert,
                          color: Colors.white, size: 27),
                      tooltip: 'More',
                      onSelected: (v) {
                        switch (v) {
                          case 'sleep':
                            _showSleepSheet();
                          case 'tracks':
                            _showTrackPicker();
                          case 'audioonly':
                            _toggleAudioOnly();
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                            value: 'sleep', child: Text('Sleep timer')),
                        const PopupMenuItem(
                            value: 'tracks',
                            child: Text('Audio & subtitles')),
                        PopupMenuItem(
                          value: 'audioonly',
                          child: Text(
                              _audioOnly ? 'Audio only: On' : 'Audio only'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // Bottom controls
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              bottom: _overlay ? 0 : -120,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom + 12,
                    top: 26,
                    left: 12,
                    right: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _circleButton(Icons.skip_previous, () => _hop(-1)),
                    _circleButton(
                      (casting ? remotePlaying : _playing)
                          ? Icons.pause
                          : Icons.play_arrow,
                      _togglePlay,
                      size: 38,
                    ),
                    _circleButton(Icons.skip_next, () => _hop(1)),
                    ListenableBuilder(
                      listenable: appState,
                      builder: (context, _) => _circleButton(
                        appState.isFavorite(_channel)
                            ? Icons.favorite
                            : Icons.favorite_border,
                        () => appState.toggleFavorite(_channel),
                      ),
                    ),
                    if (_previous != null)
                      _circleButton(Icons.swap_horiz, _swapToPrevious),
                    _circleButton(Icons.list, _openGuide),
                    if (MultiviewScreen.available(context))
                      _circleButton(Icons.grid_view, _openMultiview),
                    if (!casting)
                      _circleButton(
                        _fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        _toggleFullscreen,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

// ---------------------------------------------------------------------------
// Multiview (tablets + Windows): up to four channels at once
// ---------------------------------------------------------------------------

class MultiviewScreen extends StatefulWidget {
  final EPGChannel initial;
  const MultiviewScreen({super.key, required this.initial});

  /// Multiview is a big-screen feature: always on Windows, and on
  /// Android only at tablet widths.
  static bool available(BuildContext context) =>
      Platform.isWindows || MediaQuery.sizeOf(context).width >= 600;

  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

class _MultiviewScreenState extends State<MultiviewScreen> {
  late final List<EPGChannel?> _slots = [widget.initial, null, null, null];
  int _focus = 0;

  Future<void> _pickForSlot(int slot) async {
    final picked = await showModalBottomSheet<EPGChannel>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          maxChildSize: 0.92,
          builder: (context, scrollController) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Text('Add Channel',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    itemCount: appState.all.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 84),
                    itemBuilder: (context, i) {
                      final c = appState.all[i];
                      return ListTile(
                        leading: LogoTile(channel: c, size: 44),
                        title: Text(c.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(c.nowText(),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.of(sheetContext).pop(c),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (picked == null) return;
    if (!await ensureUnlocked(context, picked)) return;
    if (mounted) {
      setState(() {
        _slots[slot] = picked;
        _focus = slot;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Multiview'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 16 / 9,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: 4,
              itemBuilder: (context, i) {
                final channel = _slots[i];
                if (channel == null) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _pickForSlot(i),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add, color: Colors.white70, size: 30),
                          SizedBox(height: 6),
                          Text('Add Channel',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 16)),
                        ],
                      ),
                    ),
                  );
                }
                return _MultiviewCell(
                  key: ValueKey('${channel.streamId}-$i'),
                  channel: channel,
                  focused: _focus == i,
                  accent: scheme.primary,
                  onFocus: () => setState(() => _focus = i),
                  onClose: () => setState(() => _slots[i] = null),
                  onExpand: () => Navigator.of(context).pop(channel),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// One Multiview pane: its own media_kit player, audible only when
/// focused (volume 100 vs 0).
class _MultiviewCell extends StatefulWidget {
  final EPGChannel channel;
  final bool focused;
  final Color accent;
  final VoidCallback onFocus;
  final VoidCallback onClose;
  final VoidCallback onExpand;
  const _MultiviewCell({
    super.key,
    required this.channel,
    required this.focused,
    required this.accent,
    required this.onFocus,
    required this.onClose,
    required this.onExpand,
  });

  @override
  State<_MultiviewCell> createState() => _MultiviewCellState();
}

class _MultiviewCellState extends State<_MultiviewCell> {
  late final Player _player;
  late final VideoController _controller;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _init();
  }

  Future<void> _init() async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('force-seekable', 'no');
        await platform.setProperty('network-timeout', '30');
      } catch (_) {}
    }
    await _player.setVolume(widget.focused ? 100 : 0);
    if (mounted) _load();
  }

  @override
  void didUpdateWidget(_MultiviewCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focused != widget.focused) {
      _player.setVolume(widget.focused ? 100 : 0);
    }
    if (oldWidget.channel.streamId != widget.channel.streamId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final links = await appState.api.liveLinks(widget.channel.streamId);
      final url = links.liveLink;
      if (url == null || url.isEmpty) {
        throw const ApiFailure('No playable link.');
      }
      await _player.open(
        Media(url, httpHeaders: const {'User-Agent': kUserAgent}),
        play: true,
      );
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Couldn\'t load';
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onFocus,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.focused ? widget.accent : Colors.white24,
            width: widget.focused ? 3 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(controller: _controller, controls: NoVideoControls),
            if (_loading && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              right: 8,
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(widget.channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 4)
                            ])),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.focused)
                    IconButton(
                      icon: const Icon(Icons.open_in_full,
                          color: Colors.white, size: 20),
                      tooltip: 'Open full screen',
                      onPressed: widget.onExpand,
                    ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white, size: 20),
                    tooltip: 'Remove channel',
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 6),
      child: Text(title,
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Theme.of(context).colorScheme.primary)),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _toggleParental(BuildContext context, bool v) async {
    if (v) {
      if (!appState.hasCustomPin) {
        if (!await setupPinFlow(context)) return;
      }
      await appState.setParentalEnabled(true);
    } else {
      if (await _verifyPin(
          context, 'Enter PIN to turn off Parental Controls')) {
        await appState.setParentalEnabled(false);
      }
    }
  }

  Future<void> _toggleKids(BuildContext context, bool v) async {
    if (v) {
      if (!appState.hasCustomPin) {
        if (!await setupPinFlow(context)) return;
      }
      await appState.setKidsMode(true);
    } else {
      if (await _verifyPin(context, 'Enter PIN to turn off Kids Mode')) {
        await appState.setKidsMode(false);
      }
    }
  }

  Future<void> _changePin(BuildContext context) async {
    if (!await _verifyPin(context, 'Enter your current PIN')) return;
    if (context.mounted) await setupPinFlow(context);
  }

  void _showShortcuts(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keyboard Shortcuts'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('In the player (Windows / macOS / Linux):',
                style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 10),
            Text('F — Favorite / unfavorite this channel'),
            SizedBox(height: 4),
            Text('L — Last channel (swap back)'),
            SizedBox(height: 4),
            Text('M — Multiview (where available)'),
            SizedBox(height: 4),
            Text('Esc — Back'),
          ],
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done')),
        ],
      ),
    );
  }

  Future<bool> _confirm(
      BuildContext context, String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final info = appState.account;
        var languageLabel = 'All Languages';
        if (appState.languageFilter.isNotEmpty) {
          for (final o in availableLanguages(appState.all)) {
            if (o.code == appState.languageFilter) {
              languageLabel = '${o.label} (${o.count})';
              break;
            }
          }
        }
        // On tablets, keep the settings column a comfortable reading
        // width instead of stretching edge to edge.
        final sidePad = (MediaQuery.sizeOf(context).width - 760) / 2;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding:
                EdgeInsets.symmetric(horizontal: sidePad > 0 ? sidePad : 0),
            children: [
              _SectionHeader('Account'),
              ListTile(
                leading: const Icon(Icons.person_outline, size: 28),
                title: Text(info?.displayName ?? appState.username ?? '',
                    style: theme.textTheme.titleMedium),
                subtitle: Text([
                  if (info?.premiumStatus != null)
                    'Status: ${info!.premiumStatus}',
                  if (info?.premiumExpiresOn != null)
                    'Expires: ${info!.premiumExpiresOn}',
                ].join('\n')),
              ),
              _SectionHeader('Profiles'),
              ListTile(
                leading: const Icon(Icons.switch_account_outlined, size: 28),
                title: Text(appState.activeProfile.name),
                subtitle: Text(appState.isMainProfile
                    ? 'Favorites sync with the website'
                    : 'Favorites are local to this profile'),
                trailing: const Icon(Icons.unfold_more, size: 24),
                onTap: () => showProfileSwitcher(context),
              ),
              ListTile(
                leading: const Icon(Icons.manage_accounts_outlined,
                    size: 28),
                title: const Text('Manage Profiles'),
                subtitle: Text(
                    '${appState.profiles.length} profile${appState.profiles.length == 1 ? '' : 's'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ProfilesPage())),
              ),
              _SectionHeader('Appearance'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.brightness_auto),
                        label: Text('System')),
                    ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.light_mode),
                        label: Text('Light')),
                    ButtonSegment(
                        value: 2,
                        icon: Icon(Icons.dark_mode),
                        label: Text('Dark')),
                  ],
                  selected: {appState.appearanceMode},
                  onSelectionChanged: (s) =>
                      appState.setAppearance(s.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                    'System follows your phone\'s Light / Dark setting; Light and Dark lock the app to that look.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 62,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: kAccents.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    final a = kAccents[i];
                    final selected = i == appState.accentIndex;
                    return GestureDetector(
                      onTap: () => appState.setAccent(i),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: a.seed,
                              shape: BoxShape.circle,
                              border: selected
                                  ? Border.all(
                                      color: theme.colorScheme.onSurface,
                                      width: 3)
                                  : null,
                            ),
                            child: selected
                                ? const Icon(Icons.check,
                                    color: Colors.white, size: 22)
                                : null,
                          ),
                          const SizedBox(height: 3),
                          Text(a.name, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    );
                  },
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.format_size, size: 28),
                title: const Text('Extra-Large Mode'),
                subtitle:
                    const Text('Bigger text and roomier channel rows'),
                value: appState.extraLarge,
                onChanged: (v) => appState.setExtraLarge(v),
              ),
              _SectionHeader('Language'),
              ListTile(
                leading: const Icon(Icons.language, size: 28),
                title: const Text('Channel Language'),
                subtitle: Text(languageLabel),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const LanguageSettingsPage())),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                    'Filter the guide to one language. Every channel also shows a small language badge next to its name.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              _SectionHeader('Modes'),
              SwitchListTile(
                secondary: const Icon(Icons.sports, size: 28),
                title: const Text('Sports Mode'),
                subtitle: const Text('Show sports categories only'),
                value: appState.sportsMode,
                onChanged: (v) => appState.setSportsMode(v),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.child_care, size: 28),
                title: const Text('Kids Mode'),
                subtitle:
                    const Text('Kids channels only — a PIN turns it off'),
                value: appState.kidsMode,
                onChanged: (v) => _toggleKids(context, v),
              ),
              _SectionHeader('Parental Controls'),
              SwitchListTile(
                secondary: const Icon(Icons.lock_outline, size: 28),
                title: const Text('Parental Controls'),
                subtitle: Text(appState.hasCustomPin
                    ? 'Lock individual channels behind your PIN'
                    : 'Lock channels behind a PIN (you\'ll create one)'),
                value: appState.parentalEnabled,
                onChanged: (v) => _toggleParental(context, v),
              ),
              ListTile(
                leading: const Icon(Icons.lock, size: 28),
                title: const Text('Locked Channels'),
                subtitle:
                    Text('${appState.locked.length} channels locked'),
                trailing: const Icon(Icons.chevron_right),
                enabled: appState.parentalEnabled,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const LockedChannelsPage())),
              ),
              ListTile(
                leading: const Icon(Icons.pin, size: 28),
                title: const Text('Change PIN'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _changePin(context),
              ),
              ListTile(
                leading: const Icon(Icons.help_outline, size: 28),
                title: const Text('Forgot PIN?'),
                subtitle: const Text(
                    'Email yourself a reset code (PIN resets to 0000)'),
                onTap: () => forgotPinFlow(context),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.bedtime_outlined, size: 28),
                title: const Text('Kids Bedtime'),
                subtitle: const Text(
                    'Lock the app at night while Kids Mode is on (until 6 AM)'),
                value: appState.kidsBedtimeEnabled,
                onChanged: (v) => appState.setKidsBedtimeEnabled(v),
              ),
              ListTile(
                leading: const Icon(Icons.schedule, size: 28),
                title: const Text('Bedtime Time'),
                subtitle: Text(
                    'Locks at ${fmtMinutesOfDay(appState.kidsBedtimeMinutes)}'),
                trailing: const Icon(Icons.chevron_right),
                enabled: appState.kidsBedtimeEnabled,
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                      hour: appState.kidsBedtimeMinutes ~/ 60,
                      minute: appState.kidsBedtimeMinutes % 60,
                    ),
                  );
                  if (picked != null) {
                    await appState.setKidsBedtimeMinutes(
                        picked.hour * 60 + picked.minute);
                  }
                },
              ),
              _SectionHeader('Groups'),
              ListTile(
                leading: const Icon(Icons.folder_outlined, size: 28),
                title: const Text('My Groups'),
                subtitle: Text(
                    '${appState.groups.length} group${appState.groups.length == 1 ? '' : 's'} for ${appState.activeProfile.name}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const GroupsPage())),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                    'Long-press any channel and choose "Add to Group…" to build your own channel lists.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              _SectionHeader('Categories'),
              ListTile(
                leading: const Icon(Icons.view_list, size: 28),
                title: const Text('Show / Hide & Reorder'),
                subtitle: Text(
                    '${appState.visibleTags().length} categories shown'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const CategoryVisibilityPage())),
              ),
              if (Platform.isWindows ||
                  Platform.isMacOS ||
                  Platform.isLinux) ...[
                _SectionHeader('Desktop'),
                ListTile(
                  leading: const Icon(Icons.keyboard_outlined, size: 28),
                  title: const Text('Keyboard Shortcuts'),
                  subtitle:
                      const Text('Keys that work in the player'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showShortcuts(context),
                ),
              ],
              _SectionHeader('Data'),
              ListTile(
                leading: const Icon(Icons.refresh, size: 28),
                title: const Text('Refresh Channels'),
                onTap: () async {
                  await appState.loadEpg();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Channels refreshed.')));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.cleaning_services_outlined,
                    size: 28),
                title: const Text('Clear Image Cache'),
                onTap: () {
                  painting.PaintingBinding.instance.imageCache.clear();
                  painting.PaintingBinding.instance.imageCache.clearLiveImages();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Image cache cleared.')));
                },
              ),
              ListTile(
                leading: const Icon(Icons.favorite_border, size: 28),
                title: const Text('Clear Favorites'),
                onTap: () async {
                  if (await _confirm(
                      context,
                      'Clear Favorites?',
                      appState.isMainProfile
                          ? 'This removes all favorites here and on the website.'
                          : 'This removes all favorites for this profile.')) {
                    await appState.clearFavorites();
                  }
                },
              ),
              const Divider(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () async {
                    if (await _confirm(context, 'Sign Out?',
                        'Parental controls and your PIN will reset.')) {
                      await appState.signOut();
                    }
                  },
                  child: const Text('Sign Out', style: TextStyle(fontSize: 17)),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Viu Live TV for Android 2.0.0\n'
                  'The project is unofficial & strictly a hobby project.\n'
                  'Copyright (c) 2026 c12n Apps',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 28),
            ],
          ),
        );
      },
    );
  }
}

class LanguageSettingsPage extends StatelessWidget {
  const LanguageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final options = availableLanguages(appState.all);
        return Scaffold(
          appBar: AppBar(title: const Text('Channel Language')),
          body: ListView(
            children: [
              ListTile(
                title: const Text('All Languages',
                    style: TextStyle(fontSize: 18)),
                subtitle: Text('${appState.all.length} channels'),
                trailing: appState.languageFilter.isEmpty
                    ? Icon(Icons.check,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => appState.setLanguageFilter(''),
              ),
              const Divider(height: 1),
              for (final o in options)
                ListTile(
                  title: Text(o.label, style: const TextStyle(fontSize: 18)),
                  subtitle: Text('${o.count} channels'),
                  trailing: appState.languageFilter == o.code
                      ? Icon(Icons.check,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => appState.setLanguageFilter(o.code),
                ),
            ],
          ),
        );
      },
    );
  }
}

class LockedChannelsPage extends StatelessWidget {
  const LockedChannelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final channels = [...appState.all]
          ..sort((a, b) => a.name.compareTo(b.name));
        return Scaffold(
          appBar: AppBar(title: const Text('Locked Channels')),
          body: !appState.parentalEnabled
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'Turn on Parental Controls in Settings first.',
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView.builder(
                  itemCount: channels.length,
                  itemBuilder: (context, i) {
                    final c = channels[i];
                    final isLocked = appState.locked.contains(c.streamId);
                    return SwitchListTile(
                      secondary: LogoTile(channel: c, size: 42),
                      title: Text(c.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      value: isLocked,
                      onChanged: (_) => appState.toggleLocked(c),
                    );
                  },
                ),
        );
      },
    );
  }
}

class CategoryVisibilityPage extends StatefulWidget {
  const CategoryVisibilityPage({super.key});
  @override
  State<CategoryVisibilityPage> createState() =>
      _CategoryVisibilityPageState();
}

class _CategoryVisibilityPageState extends State<CategoryVisibilityPage> {
  late List<EPGTag> _ordered;

  @override
  void initState() {
    super.initState();
    final visible = appState.visibleTags();
    final visibleParams = visible.map((t) => t.parameterName).toSet();
    final hidden = appState.tags
        .where((t) =>
            t.parameterName != 'FAVORITES' &&
            !visibleParams.contains(t.parameterName) &&
            appState.hiddenTags.contains(t.parameterName))
        .toList();
    _ordered = [...visible, ...hidden];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        if (appState.kidsMode) {
          return Scaffold(
            appBar: AppBar(title: const Text('Categories')),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Turn off Kids Mode to edit categories.',
                    textAlign: TextAlign.center),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Categories'),
            actions: [
              TextButton(
                onPressed: () async {
                  await appState.restoreCategoryDefaults();
                  if (mounted) Navigator.of(context).pop();
                },
                child: const Text('Reset'),
              ),
            ],
          ),
          body: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                    'Drag to reorder. Switch a category off to hide it from the guide.'),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: _ordered.length,
                  onReorder: (oldIndex, newIndex) async {
                    setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final item = _ordered.removeAt(oldIndex);
                      _ordered.insert(newIndex, item);
                    });
                    await appState.setTagOrder(
                        _ordered.map((t) => t.parameterName).toList());
                  },
                  itemBuilder: (context, i) {
                    final tag = _ordered[i];
                    final hidden =
                        appState.hiddenTags.contains(tag.parameterName);
                    return SwitchListTile(
                      key: ValueKey(tag.parameterName),
                      title: Text(tag.displayName,
                          style: const TextStyle(fontSize: 18)),
                      value: !hidden,
                      onChanged: (v) =>
                          appState.setTagHidden(tag.parameterName, !v),
                      secondary: ReorderableDragStartListener(
                        index: i,
                        child: const Icon(Icons.drag_handle, size: 28),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Profiles + Groups managers (2.0.0)
// ---------------------------------------------------------------------------

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  Future<bool> _confirmDelete(BuildContext context, ViuProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${p.name}?'),
        content: const Text(
            'Its favorites, recents and groups will be removed from this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Profiles')),
          body: ListView(
            children: [
              for (final p in appState.profiles)
                ListTile(
                  leading: Icon(
                      p.id == appState.activeProfileId
                          ? Icons.person
                          : Icons.person_outline,
                      size: 28),
                  title:
                      Text(p.name, style: const TextStyle(fontSize: 18)),
                  subtitle: Text(p.id == 'main'
                      ? 'Favorites sync with the website'
                      : 'Favorites are local to this profile'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (p.id == appState.activeProfileId)
                        Icon(Icons.check,
                            color:
                                Theme.of(context).colorScheme.primary),
                      PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'rename') {
                            final name = await _askText(
                                context, 'Rename profile',
                                initial: p.name);
                            if (name != null && name.trim().isNotEmpty) {
                              await appState.renameProfile(p.id, name);
                            }
                          } else if (v == 'delete') {
                            if (await _confirmDelete(context, p)) {
                              await appState.deleteProfile(p.id);
                            }
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                              value: 'rename', child: Text('Rename')),
                          if (appState.profiles.length > 1)
                            const PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ],
                  ),
                  onTap: () => appState.switchProfile(p.id),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.person_add_outlined, size: 28),
                title: const Text('Add profile',
                    style: TextStyle(fontSize: 18)),
                onTap: () async {
                  final name = await _askText(context, 'New profile');
                  if (name != null && name.trim().isNotEmpty) {
                    await appState.addProfile(name);
                  }
                },
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                    'Each profile keeps its own favorites, recently watched and groups on this device. Only the Main profile syncs favorites with the Viu website.'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class GroupsPage extends StatelessWidget {
  const GroupsPage({super.key});

  Future<bool> _confirmDelete(BuildContext context, ViuGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${g.name}?'),
        content:
            const Text('The group is removed; its channels stay in the guide.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('My Groups')),
          body: ListView(
            children: [
              if (appState.groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'No groups yet.\nLong-press any channel and choose "Add to Group…" to start one.',
                      textAlign: TextAlign.center),
                ),
              for (final g in appState.groups)
                ListTile(
                  leading: const Icon(Icons.folder_outlined, size: 28),
                  title:
                      Text(g.name, style: const TextStyle(fontSize: 18)),
                  subtitle: Text(
                      '${g.channelIds.length} channel${g.channelIds.length == 1 ? '' : 's'}'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'rename') {
                        final name = await _askText(context, 'Rename group',
                            initial: g.name);
                        if (name != null && name.trim().isNotEmpty) {
                          await appState.renameGroup(g.id, name);
                        }
                      } else if (v == 'delete') {
                        if (await _confirmDelete(context, g)) {
                          await appState.deleteGroup(g.id);
                        }
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
              const Divider(height: 1),
              ListTile(
                leading:
                    const Icon(Icons.create_new_folder_outlined, size: 28),
                title: const Text('New group',
                    style: TextStyle(fontSize: 18)),
                onTap: () async {
                  final name = await _askText(context, 'New group');
                  if (name != null && name.trim().isNotEmpty) {
                    await appState.createGroup(name);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
