// Viu Live TV for Android TV.
//
// Leanback, YouTube-for-Android-TV-style interface: a collapsible left
// rail, horizontal rows of channel cards per category, and a
// focus-driven 10-foot UI built for the remote — D-pad navigation,
// media keys (play/pause, channel up/down), Menu/F for favorites, and
// a guide overlay in the player. Material 3 Expressive styling, DARK
// MODE ONLY (it's a TV app). Google Assistant support comes from the
// Android TV media-search intent + App Actions deep links (see
// MainActivity.kt and res/xml/shortcuts.xml): "Play <channel> on Viu
// Live TV" resolves to the channel and starts playback.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'language.dart';

// ---------------------------------------------------------------------------
// Accents (same curated set as the iOS app; each reads well on dark)
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

/// "9:30 PM" style wall-clock formatting (no intl dependency).
String fmtTime(DateTime t) {
  var h = t.hour % 12;
  if (h == 0) h = 12;
  final m = t.minute.toString().padLeft(2, '0');
  final ap = t.hour >= 12 ? 'PM' : 'AM';
  return '$h:$m $ap';
}

String fmtMinutesOfDay(int mins) =>
    fmtTime(DateTime(2024, 1, 1, mins ~/ 60, mins % 60));

// ---------------------------------------------------------------------------
// Profiles + custom groups (2.0.0) — device-local, per profile
// ---------------------------------------------------------------------------

class Profile {
  final String id;
  String name;
  Profile(this.id, this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        (json['id'] ?? 'main').toString(),
        (json['name'] ?? 'Main').toString(),
      );
}

class ChannelGroup {
  final String id;
  String name;
  List<int> channelIds;
  ChannelGroup(this.id, this.name, [List<int>? channelIds])
      : channelIds = channelIds ?? [];

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'channelIds': channelIds};

  factory ChannelGroup.fromJson(Map<String, dynamic> json) => ChannelGroup(
        (json['id'] ?? '').toString(),
        (json['name'] ?? 'Group').toString(),
        ((json['channelIds'] as List?) ?? [])
            .map((e) => (e as num).toInt())
            .toList(),
      );
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

  /// Recently watched channel ids, newest first (capped at 12).
  List<int> recentIds = [];

  int accentIndex = 0;
  String languageFilter = ''; // '' = all languages
  Set<String> hiddenTags = {};
  List<String> tagOrder = [];
  bool sportsMode = false;
  bool kidsMode = false;
  bool parentalEnabled = false;
  String? customPin;

  // 2.0.0: profiles (device-local). Favorites / recents / groups /
  // favorite order + pins are stored per profile; 'main' keeps the
  // legacy un-suffixed favorites/recents keys.
  List<Profile> profiles = [Profile('main', 'Main')];
  String activeProfileId = 'main';

  List<ChannelGroup> groups = [];

  /// Favorite display order (unpinned tail) and pinned favorites, both
  /// as stream-id lists in display order.
  List<int> favOrder = [];
  List<int> favPins = [];

  // 2.0.0: display + kids-bedtime settings (app-global).
  bool extraLarge = false;
  bool kidsBedtimeEnabled = false;
  int kidsBedtimeMinutes = 1200; // 20:00

  String get _favKey => activeProfileId == 'main'
      ? 'viu_favorites'
      : 'viu_favorites_$activeProfileId';
  String get _recentsKey => activeProfileId == 'main'
      ? 'viu_recents'
      : 'viu_recents_$activeProfileId';
  String get _groupsKey => 'viu_groups_$activeProfileId';
  String get _favOrderKey => 'viu_fav_order_$activeProfileId';
  String get _favPinsKey => 'viu_fav_pins_$activeProfileId';

  Profile get activeProfile => profiles.firstWhere(
        (p) => p.id == activeProfileId,
        orElse: () => profiles.first,
      );

  /// Voice/Assistant intents land here (see MainActivity.kt); the home
  /// shell observes and acts once the EPG is loaded.
  final ValueNotifier<Map<String, dynamic>?> intentRequest =
      ValueNotifier(null);

  Accent get accent => kAccents[accentIndex.clamp(0, kAccents.length - 1)];
  String get effectivePin => customPin ?? '0000';
  bool get hasCustomPin => customPin != null;

  EPGChannel? channelById(int id) {
    for (final c in all) {
      if (c.streamId == id) return c;
    }
    return null;
  }

  bool isLocked(EPGChannel c) => parentalEnabled && locked.contains(c.streamId);

  List<EPGTag> visibleTags() {
    if (kidsMode) {
      return tags.where((t) => t.parameterName == 'KIDS').toList();
    }
    var list =
        tags.where((t) => t.parameterName != 'FAVORITES').toList();
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

  List<EPGChannel> _applyLanguage(List<EPGChannel> list) {
    if (languageFilter.isEmpty) return list;
    return list.where((c) => c.language.code == languageFilter).toList();
  }

  List<EPGChannel> channelsFor(EPGTag tag) {
    if (tag.parameterName == 'ALL' && sportsMode && !kidsMode) {
      return _applyLanguage(
          all.where((c) => c.tags.any(isSportsTag)).toList());
    }
    return _applyLanguage(byTag[tag.parameterName] ??
        all.where((c) => c.tags.contains(tag.parameterName)).toList());
  }

  List<EPGChannel> favoriteChannels() {
    var favs = <EPGChannel>[
      for (final id in _orderedFavoriteIds())
        if (channelById(id) != null) channelById(id)!,
    ];
    if (kidsMode) {
      favs = favs.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (sportsMode) {
      favs = favs.where((c) => c.tags.any(isSportsTag)).toList();
    }
    return _applyLanguage(favs);
  }

  /// Display order for favorites: pinned first (pin order), then the
  /// stored order, then any remaining favorites in EPG order.
  List<int> _orderedFavoriteIds() {
    final out = <int>[];
    void push(int id) {
      if (favorites.contains(id) && !out.contains(id)) out.add(id);
    }

    favPins.forEach(push);
    favOrder.forEach(push);
    for (final c in all) {
      push(c.streamId);
    }
    favorites.forEach(push);
    return out;
  }

  /// Rewrite pins/order from a full display-order list (used by the
  /// pin + move actions so the two lists never disagree).
  void _commitFavoriteOrder(List<int> ordered) {
    final pinSet = favPins.toSet();
    favPins = ordered.where(pinSet.contains).toList();
    favOrder = ordered.where((id) => !pinSet.contains(id)).toList();
    unawaited(_saveFavOrderPins());
  }

  bool isPinned(int streamId) => favPins.contains(streamId);

  Future<void> setPinned(EPGChannel c, bool pinned) async {
    final ordered = _orderedFavoriteIds();
    ordered.remove(c.streamId);
    if (pinned) {
      if (!favPins.contains(c.streamId)) favPins.add(c.streamId);
      // Land at the end of the pinned block.
      final pinCount = ordered.where(favPins.contains).length;
      ordered.insert(pinCount, c.streamId);
    } else {
      favPins.remove(c.streamId);
      ordered.insert(favPins.length, c.streamId);
    }
    _commitFavoriteOrder(ordered);
    notifyListeners();
  }

  Future<void> moveFavorite(EPGChannel c, int delta) async {
    final ordered = _orderedFavoriteIds();
    final i = ordered.indexOf(c.streamId);
    if (i < 0) return;
    final j = i + delta;
    if (j < 0 || j >= ordered.length) return;
    ordered.removeAt(i);
    ordered.insert(j, c.streamId);
    _commitFavoriteOrder(ordered);
    notifyListeners();
  }

  // MARK: Custom groups (per profile)

  List<EPGChannel> groupChannels(ChannelGroup g) {
    var list = <EPGChannel>[
      for (final id in g.channelIds)
        if (channelById(id) != null) channelById(id)!,
    ];
    if (kidsMode) {
      list = list.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (sportsMode) {
      list = list.where((c) => c.tags.any(isSportsTag)).toList();
    }
    return _applyLanguage(list);
  }

  Future<void> createGroup(String name) async {
    final id = 'g${DateTime.now().millisecondsSinceEpoch}';
    groups = [...groups, ChannelGroup(id, name)];
    await _saveGroups();
    notifyListeners();
  }

  Future<void> renameGroup(String id, String name) async {
    for (final g in groups) {
      if (g.id == id) g.name = name;
    }
    await _saveGroups();
    notifyListeners();
  }

  Future<void> deleteGroup(String id) async {
    groups = groups.where((g) => g.id != id).toList();
    await _saveGroups();
    notifyListeners();
  }

  ChannelGroup? groupById(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  Future<void> toggleGroupMembership(String groupId, int streamId) async {
    final g = groupById(groupId);
    if (g == null) return;
    if (g.channelIds.contains(streamId)) {
      g.channelIds.remove(streamId);
    } else {
      g.channelIds.add(streamId);
    }
    await _saveGroups();
    notifyListeners();
  }

  Future<void> removeFromGroup(String groupId, int streamId) async {
    final g = groupById(groupId);
    if (g == null) return;
    g.channelIds.remove(streamId);
    await _saveGroups();
    notifyListeners();
  }

  // MARK: Home rails (2.0.0)

  /// Channels with a sports tag and a programme live right now.
  List<EPGChannel> liveSportsChannels() {
    if (kidsMode) return const [];
    var list = all
        .where((c) => c.tags.any(isSportsTag) && c.nowProgramme() != null)
        .toList();
    list = _applyLanguage(list);
    return list;
  }

  int? recentAtMs(int streamId) => _prefs?.getInt('viu_recent_at_$streamId');

  /// "Jump back in": the most recently watched channel, if it was
  /// watched within the last 3 hours.
  EPGChannel? jumpBackChannel() {
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 3))
        .millisecondsSinceEpoch;
    for (final c in recentChannels()) {
      final at = recentAtMs(c.streamId);
      if (at != null && at >= cutoff) return c;
    }
    return null;
  }

  // MARK: Recently watched

  Future<void> recordRecent(int streamId) async {
    recentIds.remove(streamId);
    recentIds.insert(0, streamId);
    if (recentIds.length > 12) {
      recentIds = recentIds.sublist(0, 12);
    }
    await _prefs?.setStringList(
        _recentsKey, recentIds.map((e) => e.toString()).toList());
    // Jump-back-in needs to know WHEN each channel was last watched.
    await _prefs?.setInt(
        'viu_recent_at_$streamId', DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
  }

  /// The Recently Watched row contents, with the same Kids / Sports /
  /// language visibility rules as the rest of Home.
  List<EPGChannel> recentChannels() {
    final out = <EPGChannel>[];
    for (final id in recentIds) {
      final c = channelById(id);
      if (c == null) continue;
      if (kidsMode && !c.tags.contains('KIDS')) continue;
      if (sportsMode && !c.tags.any(isSportsTag)) continue;
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
    // Profiles first — favorites/recents/groups hang off the active one.
    final rawProfiles = prefs.getString('viu_profiles');
    if (rawProfiles != null && rawProfiles.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawProfiles);
        if (decoded is List && decoded.isNotEmpty) {
          profiles = decoded
              .whereType<Map>()
              .map((e) => Profile.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
      } catch (_) {
        // Corrupt profile store — fall back to the Main profile.
      }
    }
    if (profiles.isEmpty) profiles = [Profile('main', 'Main')];
    activeProfileId = prefs.getString('viu_active_profile') ?? 'main';
    if (!profiles.any((p) => p.id == activeProfileId)) {
      activeProfileId = profiles.first.id;
    }
    _loadProfileData();
    locked = (prefs.getStringList('viu_locked') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    hiddenTags = (prefs.getStringList('viu_hidden_tags') ?? []).toSet();
    tagOrder = prefs.getStringList('viu_tag_order') ?? [];
    accentIndex = prefs.getInt('viu_accent') ?? 0;
    languageFilter = prefs.getString('viu_language_filter') ?? '';
    sportsMode = prefs.getBool('viu_sports_mode') ?? false;
    kidsMode = prefs.getBool('viu_kids_mode') ?? false;
    parentalEnabled = prefs.getBool('viu_parental_enabled') ?? false;
    extraLarge = prefs.getBool('viu_extra_large') ?? false;
    kidsBedtimeEnabled = prefs.getBool('viu_kids_bedtime') ?? false;
    kidsBedtimeMinutes = prefs.getInt('viu_kids_bedtime_minutes') ?? 1200;
    customPin = await _secure.read(key: 'viu_parental_pin');
    if (token != null) {
      api.token = token;
      await refreshAccountAndEpg();
    }
    booted = true;
    notifyListeners();
  }

  void _loadProfileData() {
    final p = _prefs;
    if (p == null) return;
    List<int> readIds(String key) => (p.getStringList(key) ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    favorites = readIds(_favKey).toSet();
    recentIds = readIds(_recentsKey);
    favOrder = readIds(_favOrderKey);
    favPins = readIds(_favPinsKey);
    groups = [];
    final rawGroups = p.getString(_groupsKey);
    if (rawGroups != null && rawGroups.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawGroups);
        if (decoded is List) {
          groups = decoded
              .whereType<Map>()
              .map((e) => ChannelGroup.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
      } catch (_) {
        groups = [];
      }
    }
  }

  Future<void> _saveProfiles() async => _prefs?.setString(
      'viu_profiles', jsonEncode(profiles.map((p) => p.toJson()).toList()));

  Future<void> switchProfile(String id) async {
    if (id == activeProfileId) return;
    if (!profiles.any((p) => p.id == id)) return;
    activeProfileId = id;
    await _prefs?.setString('viu_active_profile', id);
    _loadProfileData();
    notifyListeners();
  }

  Future<void> addProfile(String name) async {
    final id = 'p${DateTime.now().millisecondsSinceEpoch}';
    profiles = [...profiles, Profile(id, name)];
    await _saveProfiles();
    notifyListeners();
  }

  Future<void> renameProfile(String id, String name) async {
    for (final p in profiles) {
      if (p.id == id) p.name = name;
    }
    await _saveProfiles();
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    if (profiles.length <= 1) return; // never delete the last profile
    profiles = profiles.where((p) => p.id != id).toList();
    await _saveProfiles();
    final p = _prefs;
    if (p != null) {
      await p.remove(id == 'main' ? 'viu_favorites' : 'viu_favorites_$id');
      await p.remove(id == 'main' ? 'viu_recents' : 'viu_recents_$id');
      await p.remove('viu_groups_$id');
      await p.remove('viu_fav_order_$id');
      await p.remove('viu_fav_pins_$id');
    }
    if (activeProfileId == id) {
      activeProfileId = profiles.first.id;
      await _prefs?.setString('viu_active_profile', activeProfileId);
      _loadProfileData();
    }
    notifyListeners();
  }

  Future<void> _saveFavorites() async => _prefs?.setStringList(
      _favKey, favorites.map((e) => e.toString()).toList());
  Future<void> _saveFavOrderPins() async {
    final p = _prefs;
    if (p == null) return;
    await p.setStringList(
        _favOrderKey, favOrder.map((e) => e.toString()).toList());
    await p.setStringList(
        _favPinsKey, favPins.map((e) => e.toString()).toList());
  }

  Future<void> _saveGroups() async => _prefs?.setString(
      _groupsKey, jsonEncode(groups.map((g) => g.toJson()).toList()));
  Future<void> _saveLocked() async => _prefs?.setStringList(
      'viu_locked', locked.map((e) => e.toString()).toList());
  Future<void> _saveSettings() async {
    final p = _prefs;
    if (p == null) return;
    await p.setStringList('viu_hidden_tags', hiddenTags.toList());
    await p.setStringList('viu_tag_order', tagOrder);
    await p.setInt('viu_accent', accentIndex);
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

  Future<void> setKidsBedtimeMinutes(int v) async {
    kidsBedtimeMinutes = v;
    await _saveSettings();
    notifyListeners();
  }

  /// Kids bedtime lock: Kids Mode on + bedtime enabled + the clock is
  /// at/after bedtime or before 06:00.
  bool get bedtimeActive {
    if (!kidsMode || !kidsBedtimeEnabled) return false;
    final now = DateTime.now();
    final mins = now.hour * 60 + now.minute;
    return mins >= kidsBedtimeMinutes || mins < 360;
  }

  /// Called on a timer by the shells so the bedtime lock engages (and
  /// releases at 06:00) without any user input.
  void tickBedtime() => notifyListeners();

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
          return MapEntry(t.parameterName, await api.fetchChannels(t.parameterName));
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
      // the Main profile talks to the server list — other profiles are
      // purely local, so their favorites never leak into the account
      // list (or get the account list merged into them).
      if (activeProfileId == 'main') {
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
      epgError = 'Could not load channels. Check your connection and try again.';
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
    // Parental controls reset on sign-out (PIN back to default 0000).
    parentalEnabled = false;
    kidsMode = false;
    sportsMode = false;
    locked = {};
    customPin = null;
    await _secure.delete(key: 'viu_token');
    await _secure.delete(key: 'viu_parental_pin');
    await _saveLocked();
    await _saveSettings();
    notifyListeners();
  }

  // MARK: Favorites

  bool isFavorite(EPGChannel c) => favorites.contains(c.streamId);

  /// The live-links response reports the server-side favorite flag;
  /// merge it locally without pushing anything back.
  Future<void> mergeFavoriteFromServer(int streamId) async {
    if (activeProfileId != 'main') return; // server list = Main profile
    if (favorites.add(streamId)) {
      await _saveFavorites();
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(EPGChannel c) async {
    final syncServer = activeProfileId == 'main';
    if (favorites.contains(c.streamId)) {
      favorites.remove(c.streamId);
      favOrder.remove(c.streamId);
      favPins.remove(c.streamId);
      await _saveFavOrderPins();
      if (syncServer) unawaited(api.removeFavorite(c.streamId));
    } else {
      favorites.add(c.streamId);
      if (!favOrder.contains(c.streamId)) favOrder.add(c.streamId);
      await _saveFavOrderPins();
      if (syncServer) unawaited(api.saveFavorite(c.streamId));
    }
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> clearFavorites() async {
    if (activeProfileId == 'main') {
      for (final id in favorites.toList()) {
        unawaited(api.removeFavorite(id));
      }
    }
    favorites = {};
    favOrder = [];
    favPins = [];
    await _saveFavOrderPins();
    await _saveFavorites();
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

  // MARK: Voice / external intents

  void handleIntent(Map<dynamic, dynamic> raw) {
    intentRequest.value =
        raw.map((k, v) => MapEntry(k.toString(), v));
  }

  EPGChannel? findChannelByName(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final c in all) {
      if (c.name.toLowerCase() == needle) return c;
    }
    for (final c in all) {
      if (c.name.toLowerCase().contains(needle)) return c;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

final AppState appState = AppState();
const MethodChannel _intentChannel = MethodChannel('viu.tv/intents');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const ViuTvApp());
  unawaited(appState.boot());
  _intentChannel.setMethodCallHandler((call) async {
    if (call.method == 'onIntent' && call.arguments is Map) {
      appState.handleIntent(call.arguments as Map);
    }
    return null;
  });
  try {
    final initial =
        await _intentChannel.invokeMethod<Map<dynamic, dynamic>>('getInitialIntent');
    if (initial != null) appState.handleIntent(initial);
  } catch (_) {
    // No intent bridge (e.g. running on a phone) — nothing to do.
  }
}

class ViuTvApp extends StatelessWidget {
  const ViuTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final scheme = ColorScheme.fromSeed(
          seedColor: appState.accent.seed,
          brightness: Brightness.dark,
        );
        return MaterialApp(
          title: 'Viu Live TV',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark, // Dark mode only — it's a TV.
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: scheme,
            scaffoldBackgroundColor: const Color(0xFF0A0A0E),
            textTheme: const TextTheme(
              displaySmall: TextStyle(fontSize: 40, fontWeight: FontWeight.w700),
              headlineMedium: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
              headlineSmall: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
              titleLarge: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
              titleMedium: TextStyle(fontSize: 19, fontWeight: FontWeight.w500),
              bodyLarge: TextStyle(fontSize: 18),
              bodyMedium: TextStyle(fontSize: 16),
              bodySmall: TextStyle(fontSize: 14),
            ),
            cardTheme: CardThemeData(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                textStyle:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28)),
              ),
            ),
          ),
          builder: (context, child) {
            final content = child ?? const SizedBox.shrink();
            if (!appState.extraLarge) return content;
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(textScaler: TextScaler.linear(1.3)),
              child: content,
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
        if (appState.bedtimeActive) return const BedtimeLockScreen();
        return const HomeShell();
      },
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
  final _userFocus = FocusNode();
  final _passFocus = FocusNode();
  final _signInFocus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_loginKeys);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_loginKeys);
    _user.dispose();
    _pass.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    _signInFocus.dispose();
    super.dispose();
  }

  // TV remote handling for the login form. A focused TextField swallows
  // D-pad up/down itself (text-cursor actions), so normal focus traversal
  // can never move email -> password -> Sign In with a remote — that was
  // reported on a real Chromecast remote ("cannot switch from the email
  // box to the password box"). Handle the moves at the hardware-keyboard
  // level, before focus dispatch: Down walks down the form, Up walks
  // back. Select on a field also explicitly re-raises the on-screen
  // keyboard, which on Google TV sometimes never appears when a field
  // was only D-pad focused, never tapped.
  bool _loginKeys(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_userFocus.hasFocus) {
        _passFocus.requestFocus();
        return true;
      }
      if (_passFocus.hasFocus) {
        _signInFocus.requestFocus();
        return true;
      }
    } else if (key == LogicalKeyboardKey.arrowUp) {
      if (_signInFocus.hasFocus) {
        _passFocus.requestFocus();
        return true;
      }
      if (_passFocus.hasFocus) {
        _userFocus.requestFocus();
        return true;
      }
    } else if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_userFocus.hasFocus || _passFocus.hasFocus) {
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      }
    }
    return false;
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
      body: Center(
        child: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('VIU',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displaySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 6)),
              const SizedBox(height: 8),
              Text('Live TV — sign in with your Viu account',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: Colors.white70)),
              const SizedBox(height: 40),
              TextField(
                controller: _user,
                focusNode: _userFocus,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passFocus.requestFocus(),
                decoration: const InputDecoration(
                    labelText: 'Email / username',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pass,
                focusNode: _passFocus,
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
                focusNode: _signInFocus,
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Text('Sign In'),
              ),
            ],
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
      body: Center(
        child: SizedBox(
          width: 640,
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
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 32),
              FilledButton(
                autofocus: true,
                onPressed: () => launchUrl(Uri.parse('https://viu.to'),
                    mode: LaunchMode.externalApplication),
                child: const Text('Renew on viu.to'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
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
    );
  }
}

// ---------------------------------------------------------------------------
// Kids bedtime lock (2.0.0)
// ---------------------------------------------------------------------------

class BedtimeLockScreen extends StatefulWidget {
  const BedtimeLockScreen({super.key});
  @override
  State<BedtimeLockScreen> createState() => _BedtimeLockScreenState();
}

class _BedtimeLockScreenState extends State<BedtimeLockScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-check the clock so the lock releases itself at 06:00.
    _ticker = Timer.periodic(
        const Duration(seconds: 30), (_) => appState.tickBedtime());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _exitKids() async {
    if (await _verifyPin(context, 'Enter PIN to exit Kids Mode')) {
      await appState.setKidsMode(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bedtime_rounded,
                size: 84, color: theme.colorScheme.primary),
            const SizedBox(height: 24),
            Text('Bedtime',
                style: theme.textTheme.displaySmall
                    ?.copyWith(color: Colors.white)),
            const SizedBox(height: 12),
            Text(
              'Kids Mode is resting until 6:00 AM.\n'
              'Bedtime started at ${fmtMinutesOfDay(appState.kidsBedtimeMinutes)}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 36),
            FilledButton(
              autofocus: true,
              onPressed: _exitKids,
              child: const Text('Exit Kids Mode (PIN)'),
            ),
          ],
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

  Widget _key(String label, {bool autofocus = false}) {
    final isDel = label == 'del';
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.08),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          autofocus: autofocus,
          onTap: () => _press(label),
          child: SizedBox(
            width: 92,
            height: 92,
            child: Center(
              child: isDel
                  ? const Icon(Icons.backspace_outlined,
                      color: Colors.white, size: 30)
                  : Text(label,
                      style: const TextStyle(
                          fontSize: 34,
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
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, color: Colors.white, size: 40),
            const SizedBox(height: 16),
            Text(widget.title,
                style: const TextStyle(color: Colors.white, fontSize: 22)),
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
                children: [
                  for (final k in row) _key(k, autofocus: k == '1'),
                ],
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 108),
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
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Incorrect PIN')));
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
  final entered = await _askPin(context, 'Enter the 6-digit reset code',
      length: 6);
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

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

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

Future<void> playChannel(
    BuildContext context, EPGChannel channel, List<EPGChannel> contextList) async {
  if (!await ensureUnlocked(context, channel)) return;
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => PlayerScreen(channel: channel, contextList: contextList),
  ));
}

// ---------------------------------------------------------------------------
// Text entry page (profile / group names) — same D-pad handling as the
// login form: the field swallows Up/Down, so the moves are done at the
// hardware-keyboard level.
// ---------------------------------------------------------------------------

class TextEntryPage extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  final String saveLabel;
  const TextEntryPage({
    super.key,
    required this.title,
    this.hint = '',
    this.initial = '',
    this.saveLabel = 'Save',
  });

  @override
  State<TextEntryPage> createState() => _TextEntryPageState();
}

class _TextEntryPageState extends State<TextEntryPage> {
  late final TextEditingController _controller;
  final _fieldFocus = FocusNode();
  final _saveFocus = FocusNode();
  final _cancelFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    HardwareKeyboard.instance.addHandler(_keys);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keys);
    _controller.dispose();
    _fieldFocus.dispose();
    _saveFocus.dispose();
    _cancelFocus.dispose();
    super.dispose();
  }

  bool _keys(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown && _fieldFocus.hasFocus) {
      _saveFocus.requestFocus();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp && _saveFocus.hasFocus) {
      _fieldFocus.requestFocus();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight && _saveFocus.hasFocus) {
      _cancelFocus.requestFocus();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft && _cancelFocus.hasFocus) {
      _saveFocus.requestFocus();
      return true;
    }
    if ((key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        _fieldFocus.hasFocus) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
    return false;
  }

  void _save() {
    final v = _controller.text.trim();
    Navigator.of(context).pop(v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                focusNode: _fieldFocus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      focusNode: _saveFocus,
                      onPressed: _save,
                      child: Text(widget.saveLabel),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: OutlinedButton(
                      focusNode: _cancelFocus,
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> askText(BuildContext context, String title,
    {String hint = '', String initial = '', String saveLabel = 'Save'}) {
  return Navigator.of(context).push<String>(MaterialPageRoute(
    builder: (_) => TextEntryPage(
        title: title, hint: hint, initial: initial, saveLabel: saveLabel),
    fullscreenDialog: true,
  ));
}

// ---------------------------------------------------------------------------
// Channel menu (2.0.0) — Menu key or long-press on any channel card.
// Pops with 'play' when the user picks Play; every other action is
// applied in place before popping.
// ---------------------------------------------------------------------------

class ChannelMenuPage extends StatelessWidget {
  final EPGChannel channel;
  final String? groupId;
  const ChannelMenuPage({super.key, required this.channel, this.groupId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final fav = appState.isFavorite(channel);
          final pinned = appState.isPinned(channel.streamId);
          final group =
              groupId != null ? appState.groupById(groupId!) : null;
          return ListView(
            padding: const EdgeInsets.fromLTRB(36, 36, 36, 32),
            children: [
              Row(
                children: [
                  if (channel.streamIcon != null)
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: Image.network(
                        channel.streamIcon!,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(channel.name,
                            style: theme.textTheme.headlineMedium),
                        Text(channel.nowText(),
                            style: theme.textTheme.titleMedium
                                ?.copyWith(color: Colors.white60)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _SettingRow(
                title: 'Play',
                autofocus: true,
                trailing: const Icon(Icons.play_arrow_rounded),
                onTap: () => Navigator.of(context).pop('play'),
              ),
              _SettingRow(
                title: fav ? 'Remove from Favorites' : 'Add to Favorites',
                trailing: Icon(fav ? Icons.favorite : Icons.favorite_border,
                    color: fav ? theme.colorScheme.primary : null),
                onTap: () async {
                  await appState.toggleFavorite(channel);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              if (fav) ...[
                _SettingRow(
                  title: pinned ? 'Unpin Favorite' : 'Pin Favorite',
                  subtitle: 'Pinned favorites stay at the front',
                  trailing:
                      Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  onTap: () async {
                    await appState.setPinned(channel, !pinned);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                _SettingRow(
                  title: 'Move Up',
                  subtitle: 'Earlier in the Favorites order',
                  trailing: const Icon(Icons.arrow_upward_rounded),
                  onTap: () async {
                    await appState.moveFavorite(channel, -1);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                _SettingRow(
                  title: 'Move Down',
                  subtitle: 'Later in the Favorites order',
                  trailing: const Icon(Icons.arrow_downward_rounded),
                  onTap: () async {
                    await appState.moveFavorite(channel, 1);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              ],
              _SettingRow(
                title: 'Add to Group…',
                subtitle: 'Custom channel groups',
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => GroupPickerPage(channel: channel))),
              ),
              if (group != null)
                _SettingRow(
                  title: 'Remove from ${group.name}',
                  trailing: const Icon(Icons.remove_circle_outline),
                  onTap: () async {
                    await appState.removeFromGroup(group.id, channel.streamId);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              _SettingRow(
                title: 'Back',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Toggle-list of the profile's groups for one channel, plus
/// "New group…" (creates the group and adds the channel).
class GroupPickerPage extends StatelessWidget {
  final EPGChannel channel;
  const GroupPickerPage({super.key, required this.channel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(36, 36, 36, 32),
            children: [
              Text('Groups for ${channel.name}',
                  style: theme.textTheme.headlineMedium),
              const SizedBox(height: 16),
              if (appState.groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  child: Text('No groups yet — create one below.',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: Colors.white60)),
                ),
              for (final g in appState.groups)
                _SettingRow(
                  title: g.name,
                  subtitle: '${g.channelIds.length} channels',
                  trailing: g.channelIds.contains(channel.streamId)
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: () =>
                      appState.toggleGroupMembership(g.id, channel.streamId),
                ),
              _SettingRow(
                title: 'New Group…',
                trailing: const Icon(Icons.add),
                onTap: () async {
                  final name = await askText(context, 'New group name',
                      hint: 'e.g. Match Days', saveLabel: 'Create');
                  if (name == null) return;
                  await appState.createGroup(name);
                  final created = appState.groups.lastWhere(
                      (g) => g.name == name,
                      orElse: () => appState.groups.last);
                  await appState.toggleGroupMembership(
                      created.id, channel.streamId);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Opens the channel menu; plays the channel if the user picked Play.
Future<void> openChannelMenu(BuildContext context, EPGChannel channel,
    List<EPGChannel> contextList,
    {String? groupId}) async {
  final action = await Navigator.of(context).push<String>(MaterialPageRoute(
    builder: (_) => ChannelMenuPage(channel: channel, groupId: groupId),
    fullscreenDialog: true,
  ));
  if (action == 'play' && context.mounted) {
    await playChannel(context, channel, contextList);
  }
}

// ---------------------------------------------------------------------------
// Home shell: collapsible rail + pages
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _page = 0;
  Map<String, dynamic>? _lastHandledIntent;

  static const _railItems = [
    (Icons.home_rounded, 'Home'),
    (Icons.favorite_rounded, 'Favorites'),
    (Icons.list_alt_rounded, 'Guide'),
    (Icons.search_rounded, 'Search'),
    (Icons.settings_rounded, 'Settings'),
  ];

  Timer? _bedtimeTicker;

  @override
  void initState() {
    super.initState();
    appState.intentRequest.addListener(_maybeHandleIntent);
    // Watch the clock so the Kids bedtime lock engages on time.
    _bedtimeTicker = Timer.periodic(
        const Duration(seconds: 30), (_) => appState.tickBedtime());
  }

  @override
  void dispose() {
    appState.intentRequest.removeListener(_maybeHandleIntent);
    _bedtimeTicker?.cancel();
    super.dispose();
  }

  void _maybeHandleIntent() {
    final intent = appState.intentRequest.value;
    if (intent == null || identical(intent, _lastHandledIntent)) return;
    if (appState.all.isEmpty) return; // wait for the EPG, listener refires via rebuild check
    _lastHandledIntent = intent;
    final name = (intent['name'] ?? intent['query'] ?? '').toString();
    final streamId = int.tryParse((intent['stream'] ?? '').toString());
    EPGChannel? channel =
        streamId != null ? appState.channelById(streamId) : null;
    channel ??= appState.findChannelByName(name);
    if (channel != null && mounted) {
      final target = channel;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) playChannel(context, target, appState.all);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        // An intent may have arrived before the EPG finished loading.
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _maybeHandleIntent());
        return Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 92,
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    const SizedBox(height: 36),
                    Text('VIU',
                        style: theme.textTheme.headlineSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2)),
                    const SizedBox(height: 44),
                    for (var i = 0; i < _railItems.length; i++)
                      _RailItem(
                        icon: _railItems[i].$1,
                        label: _railItems[i].$2,
                        selected: _page == i,
                        autofocus: i == 0,
                        onFocused: () => setState(() => _page = i),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _page,
                  children: const [
                    ChannelsHomePage(),
                    FavoritesPage(),
                    GuidePage(),
                    SearchPage(),
                    SettingsPage(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RailItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool autofocus;
  final VoidCallback onFocused;
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onFocused,
    this.autofocus = false,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _focused || widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (f) {
          setState(() => _focused = f);
          if (f) widget.onFocused();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(widget.icon,
              size: 30,
              color: active
                  ? theme.colorScheme.onPrimaryContainer
                  : Colors.white70),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Channel card (focusable, scales up with a border when focused)
// ---------------------------------------------------------------------------

class TvChannelCard extends StatefulWidget {
  final EPGChannel channel;
  final List<EPGChannel> contextList;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Set when the card sits in a custom-group row — the channel menu
  /// then offers "Remove from <group>".
  final String? groupId;
  const TvChannelCard({
    super.key,
    required this.channel,
    required this.contextList,
    this.autofocus = false,
    this.focusNode,
    this.groupId,
  });

  @override
  State<TvChannelCard> createState() => _TvChannelCardState();
}

class _TvChannelCardState extends State<TvChannelCard> {
  bool _focused = false;
  Timer? _pressTimer;
  bool _longPressFired = false;

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isSelect = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space;
    // Long-press OK opens the channel menu: arm a timer on key-down,
    // and if it fired, swallow the key-up so the card's tap (playback)
    // doesn't also trigger.
    if (event is KeyDownEvent && isSelect) {
      _longPressFired = false;
      _pressTimer?.cancel();
      _pressTimer = Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        _longPressFired = true;
        unawaited(openChannelMenu(context, widget.channel, widget.contextList,
            groupId: widget.groupId));
      });
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      _pressTimer?.cancel();
      if (isSelect && _longPressFired) {
        _longPressFired = false;
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.contextMenu) {
      unawaited(openChannelMenu(context, widget.channel, widget.contextList,
          groupId: widget.groupId));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      appState.toggleFavorite(widget.channel);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _nowLine(EPGChannel c) {
    final p = c.nowProgramme();
    if (p != null && p.name != '—') {
      if (p.timeEnd != null) return '${p.name} · ends ${fmtTime(p.timeEnd!)}';
      return p.name;
    }
    return c.nowText();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.channel;
    final fav = appState.isFavorite(c);
    final locked = appState.isLocked(c);
    final progress = c.nowProgress();
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: _onKey,
      child: AnimatedScale(
        scale: _focused ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 140),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => playChannel(context, c, widget.contextList),
            onLongPress: () => openChannelMenu(
                context, c, widget.contextList,
                groupId: widget.groupId),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _focused
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 3,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: Colors.black54,
                          child: c.streamIcon != null
                              ? Image.network(
                                  c.streamIcon!,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) =>
                                      _logoFallback(c.name, theme),
                                )
                              : _logoFallback(c.name, theme),
                        ),
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('LIVE',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white)),
                          ),
                        ),
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Row(
                            children: [
                              if (locked)
                                const Icon(Icons.lock,
                                    size: 19, color: Colors.white),
                              if (fav)
                                Icon(Icons.favorite,
                                    size: 20,
                                    color: theme.colorScheme.primary),
                            ],
                          ),
                        ),
                        if (progress != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 4,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(c.language.code.toUpperCase(),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  color: theme.colorScheme.primary)),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Text(_nowLine(c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white60)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _logoFallback(String name, ThemeData theme) {
    final letters = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Center(
      child: Text(letters,
          style: theme.textTheme.headlineMedium
              ?.copyWith(color: Colors.white38, fontWeight: FontWeight.w800)),
    );
  }
}

// ---------------------------------------------------------------------------
// Home page: one horizontal row per category (YouTube TV style)
// ---------------------------------------------------------------------------

class ChannelsHomePage extends StatelessWidget {
  const ChannelsHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (appState.epgLoading && appState.all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (appState.epgError != null && appState.all.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(appState.epgError!, style: theme.textTheme.titleMedium),
            const SizedBox(height: 20),
            FilledButton(
              autofocus: true,
              onPressed: () => appState.loadEpg(),
              child: const Text('Try Again'),
            ),
          ],
        ),
      );
    }
    final visible = appState.visibleTags();
    final favs = appState.favoriteChannels();
    final recents = appState.recentChannels();
    final sportsLive = appState.liveSportsChannels();
    final jumpBack = appState.jumpBackChannel();
    final groupSections = <(String, List<EPGChannel>, String?)>[
      for (final g in appState.groups)
        (g.name, appState.groupChannels(g), g.id),
    ];
    final sections = <(String, List<EPGChannel>, String?)>[
      if (sportsLive.isNotEmpty) ('Live Sports Now', sportsLive, null),
      if (recents.isNotEmpty) ('Recently Watched', recents, null),
      if (favs.isNotEmpty) ('Favorites', favs, null),
      for (final s in groupSections)
        if (s.$2.isNotEmpty) s,
      for (final t in visible)
        if (appState.channelsFor(t).isNotEmpty)
          (t.displayName, appState.channelsFor(t), null),
    ];
    if (sections.isEmpty && jumpBack == null) {
      return Center(
        child: Text(
          'No channels to show.\nCheck Modes and category visibility in Settings.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(color: Colors.white60),
        ),
      );
    }
    final rowHeight = appState.extraLarge ? 256.0 : 218.0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(36, 28, 12, 28),
      children: [
        if (jumpBack != null) _JumpBackCard(channel: jumpBack),
        for (final (title, channels, groupId) in sections)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 12),
                SizedBox(
                  height: rowHeight,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: channels.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(right: 18),
                      child: SizedBox(
                        width: 264,
                        child: TvChannelCard(
                          channel: channels[i],
                          contextList: channels,
                          groupId: groupId,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Jump back in" banner (2.0.0): the channel you were watching
/// earlier, with what's on now and how much of it is left.
class _JumpBackCard extends StatefulWidget {
  final EPGChannel channel;
  const _JumpBackCard({required this.channel});

  @override
  State<_JumpBackCard> createState() => _JumpBackCardState();
}

class _JumpBackCardState extends State<_JumpBackCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.channel;
    final now = c.nowProgramme();
    final minsLeft = now?.timeEnd != null
        ? now!.timeEnd!.difference(DateTime.now()).inMinutes
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Focus(
        onFocusChange: (f) => setState(() => _focused = f),
        child: AnimatedScale(
          scale: _focused ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 140),
          child: Material(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () =>
                  playChannel(context, c, appState.recentChannels()),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _focused
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: theme.colorScheme.primary,
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 34),
                    ),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('JUMP BACK IN',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.4,
                                  color: theme.colorScheme.primary)),
                          const SizedBox(height: 4),
                          Text(c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                  color:
                                      theme.colorScheme.onPrimaryContainer)),
                          if (now != null)
                            Text(
                              '${now.name}'
                              '${minsLeft != null && minsLeft >= 0 ? ' · $minsLeft min left' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer
                                      .withValues(alpha: 0.75)),
                            ),
                        ],
                      ),
                    ),
                    if (c.streamIcon != null)
                      SizedBox(
                        width: 96,
                        height: 64,
                        child: Image.network(
                          c.streamIcon!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final favs = appState.favoriteChannels();
    if (favs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Text(
            'No favorites yet.\nFocus a channel and press F — or open the channel menu with the Menu key — to favorite it.',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white60),
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(36, 28, 36, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        childAspectRatio: 1.32,
      ),
      itemCount: favs.length,
      itemBuilder: (context, i) => TvChannelCard(
        channel: favs[i],
        contextList: favs,
      ),
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
  final _fieldFocus = FocusNode();
  final _firstCardFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_searchKeys);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_searchKeys);
    _fieldFocus.dispose();
    _firstCardFocus.dispose();
    super.dispose();
  }

  // Same TV text-field trap as the login form: the search field swallows
  // D-pad down, so the results grid was unreachable by remote. Down from
  // the field jumps to the first result; Select re-raises the keyboard.
  // Guarded by hasFocus — this page stays mounted inside the shell's
  // IndexedStack, and the guard keeps the handler inert elsewhere.
  bool _searchKeys(KeyEvent event) {
    if (event is! KeyDownEvent || !_fieldFocus.hasFocus) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _firstCardFocus.requestFocus();
      return true;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    if (appState.kidsMode) {
      results = results.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (appState.sportsMode) {
      results = results.where((c) => c.tags.any(isSportsTag)).toList();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 8),
          child: TextField(
            focusNode: _fieldFocus,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: (v) => setState(() => _query = v),
            style: theme.textTheme.titleLarge,
            decoration: InputDecoration(
              hintText: 'Search channels & programmes — or ask the Assistant: “Play … on Viu Live TV”',
              prefixIcon: const Icon(Icons.search, size: 28),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
        Expanded(
          child: results.isEmpty
              ? Center(
                  child: Text(
                      q.isEmpty
                          ? 'Start typing to search ${appState.all.length} channels.'
                          : 'No channels match “$_query”.',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: Colors.white60)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(36, 16, 36, 28),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 20,
                    crossAxisSpacing: 20,
                    childAspectRatio: 1.32,
                  ),
                  itemCount: results.length,
                  itemBuilder: (context, i) => TvChannelCard(
                    channel: results[i],
                    contextList: results,
                    focusNode: i == 0 ? _firstCardFocus : null,
                  ),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Guide (2.0.0): per-channel programme strips for the next ~6 hours.
// The TV form of the timeline grid — D-pad right walks a channel's
// programmes, up/down moves between channels.
// ---------------------------------------------------------------------------

class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  List<EPGChannel> _channels() {
    var list = appState.all;
    if (appState.kidsMode) {
      list = list.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (appState.sportsMode) {
      list = list.where((c) => c.tags.any(isSportsTag)).toList();
    }
    if (appState.languageFilter.isNotEmpty) {
      list =
          list.where((c) => c.language.code == appState.languageFilter).toList();
    }
    return list.take(100).toList();
  }

  List<EPGProgramme> _window(EPGChannel c) {
    final now = DateTime.now();
    final end = now.add(const Duration(hours: 6));
    final list = c.schedule
        .where((p) =>
            p.timeStart != null &&
            p.timeEnd != null &&
            p.timeEnd!.isAfter(now) &&
            p.timeStart!.isBefore(end))
        .toList();
    list.sort((a, b) => a.timeStart!.compareTo(b.timeStart!));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (appState.epgLoading && appState.all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final channels = _channels();
    if (channels.isEmpty) {
      return Center(
        child: Text('No channels to show in the guide.',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: Colors.white60)),
      );
    }
    final now = DateTime.now();
    final windowEnd = now.add(const Duration(hours: 6));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 4),
          child: Text('Guide', style: theme.textTheme.headlineMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(36, 0, 36, 12),
          child: Text(
            'Now → ${fmtTime(windowEnd)} · OK on a programme for details',
            style:
                theme.textTheme.titleMedium?.copyWith(color: Colors.white60),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(36, 0, 12, 28),
            itemCount: channels.length,
            itemBuilder: (context, ci) {
              final c = channels[ci];
              final programmes = _window(c);
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 208,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium),
                          Text(c.nowText(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: Colors.white54)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: SizedBox(
                        height: 86,
                        child: programmes.isEmpty
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: Text('No programme info',
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(color: Colors.white38)),
                              )
                            : ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: programmes.length,
                                itemBuilder: (context, pi) {
                                  final p = programmes[pi];
                                  final visStart =
                                      p.timeStart!.isBefore(now)
                                          ? now
                                          : p.timeStart!;
                                  final visEnd =
                                      p.timeEnd!.isAfter(windowEnd)
                                          ? windowEnd
                                          : p.timeEnd!;
                                  final minutes =
                                      visEnd.difference(visStart).inMinutes;
                                  final width =
                                      (minutes * 2.0).clamp(120.0, 460.0);
                                  final live = p.isLiveAt(now);
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 10),
                                    child: SizedBox(
                                      width: width,
                                      child: _GuideChip(
                                        channel: c,
                                        programme: p,
                                        live: live,
                                        autofocus: ci == 0 && pi == 0,
                                        contextList: channels,
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GuideChip extends StatefulWidget {
  final EPGChannel channel;
  final EPGProgramme programme;
  final bool live;
  final bool autofocus;
  final List<EPGChannel> contextList;
  const _GuideChip({
    required this.channel,
    required this.programme,
    required this.live,
    required this.autofocus,
    required this.contextList,
  });

  @override
  State<_GuideChip> createState() => _GuideChipState();
}

class _GuideChipState extends State<_GuideChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.programme;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      child: Material(
        color: widget.live
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            final play = await Navigator.of(context).push<EPGChannel>(
                MaterialPageRoute(
              builder: (_) => ProgrammeDetailPage(
                  channel: widget.channel,
                  programme: p,
                  contextList: widget.contextList),
            ));
            if (play != null && context.mounted) {
              await playChannel(context, play, widget.contextList);
            }
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focused
                    ? theme.colorScheme.primary
                    : (widget.live
                        ? theme.colorScheme.primary.withValues(alpha: 0.6)
                        : Colors.transparent),
                width: _focused ? 3 : 1.5,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(fmtTime(p.timeStart!),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary)),
                    if (widget.live) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Text('LIVE',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Text(p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontSize: 16)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProgrammeDetailPage extends StatelessWidget {
  final EPGChannel channel;
  final EPGProgramme programme;
  final List<EPGChannel> contextList;
  const ProgrammeDetailPage({
    super.key,
    required this.channel,
    required this.programme,
    required this.contextList,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = programme;
    final live = p.isLiveAt(DateTime.now());
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 760,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(channel.name,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 8),
              Text(p.name, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 10),
              Text(
                '${p.timeStart != null ? fmtTime(p.timeStart!) : ''}'
                '${p.timeEnd != null ? ' – ${fmtTime(p.timeEnd!)}' : ''}'
                '${live ? ' · LIVE NOW' : ''}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 18),
              Text(
                p.description.isNotEmpty
                    ? p.description
                    : 'No description available for this programme.',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 32),
              FilledButton(
                autofocus: true,
                // Pop with the channel — the guide chip (still mounted)
                // starts playback with a live context.
                onPressed: () => Navigator.of(context).pop(channel),
                child: Text('Play ${channel.name}'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to Guide'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class _SettingRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool autofocus;
  const _SettingRow({
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        autofocus: autofocus,
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleLarge),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: Colors.white60)),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 6),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _toggleParental(BuildContext context) async {
    if (appState.parentalEnabled) {
      if (!await _verifyPin(context, 'Enter PIN to turn off Parental Controls')) {
        return;
      }
      await appState.setParentalEnabled(false);
    } else {
      if (!appState.hasCustomPin) {
        if (!await setupPinFlow(context)) return;
      }
      await appState.setParentalEnabled(true);
    }
  }

  Future<void> _toggleKids(BuildContext context) async {
    if (appState.kidsMode) {
      if (!await _verifyPin(context, 'Enter PIN to turn off Kids Mode')) return;
      await appState.setKidsMode(false);
    } else {
      if (!appState.hasCustomPin) {
        if (!await setupPinFlow(context)) return;
      }
      await appState.setKidsMode(true);
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = appState.account;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 36, 32),
      children: [
        Text('Settings', style: theme.textTheme.headlineMedium),
        const _SectionTitle('Account'),
        _SettingRow(
          title: info?.displayName ?? appState.username ?? 'Account',
          subtitle:
              'Status: ${info?.premiumStatus ?? '—'}${info?.premiumExpiresOn != null ? ' · Expires ${info!.premiumExpiresOn}' : ''}',
        ),
        _SettingRow(
          title: 'Sign Out',
          subtitle: 'Also resets parental controls and the PIN to 0000',
          onTap: () async {
            if (await _confirm(context, 'Sign out?',
                'Parental controls, locks and modes will be reset.')) {
              await appState.signOut();
            }
          },
        ),
        const _SectionTitle('Profiles'),
        _SettingRow(
          title: 'Profiles',
          subtitle:
              'Active: ${appState.activeProfile.name} · ${appState.profiles.length} profile${appState.profiles.length == 1 ? '' : 's'} — favorites, recents and groups are per profile',
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ProfilesPage())),
        ),
        const _SectionTitle('Display'),
        _SettingRow(
          title: 'Extra-Large Text',
          subtitle: appState.extraLarge
              ? 'On — text is scaled up across the app'
              : 'Bigger text and taller channel rows',
          trailing: IgnorePointer(
              child: Switch(value: appState.extraLarge, onChanged: (_) {})),
          onTap: () => appState.setExtraLarge(!appState.extraLarge),
        ),
        const _SectionTitle('Appearance — accent colour'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              for (var i = 0; i < kAccents.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Material(
                    color: kAccents[i].seed,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => appState.setAccent(i),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: appState.accentIndex == i
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const _SectionTitle('Parental Controls'),
        _SettingRow(
          title: 'Parental Controls',
          subtitle: appState.parentalEnabled
              ? 'On — locked channels ask for the PIN'
              : 'Off',
          trailing: IgnorePointer(
              child: Switch(value: appState.parentalEnabled, onChanged: (_) {})),
          onTap: () => _toggleParental(context),
        ),
        if (appState.parentalEnabled) ...[
          _SettingRow(
            title: 'Locked Channels',
            subtitle: '${appState.locked.length} locked',
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const LockedChannelsPage())),
          ),
          _SettingRow(
            title: 'Change PIN',
            onTap: () async {
              if (await _verifyPin(context, 'Enter your current PIN')) {
                await setupPinFlow(context);
              }
            },
          ),
        ],
        _SettingRow(
          title: 'Forgot PIN?',
          subtitle: 'Email a reset code to ${appState.account?.username ?? appState.username ?? 'your account email'}',
          onTap: () => forgotPinFlow(context),
        ),
        const _SectionTitle('Modes'),
        _SettingRow(
          title: 'Kids Mode',
          subtitle: appState.kidsMode
              ? 'On — only the Kids category (PIN needed to turn off)'
              : 'Only the Kids category, app-wide',
          trailing: IgnorePointer(
              child: Switch(value: appState.kidsMode, onChanged: (_) {})),
          onTap: () => _toggleKids(context),
        ),
        _SettingRow(
          title: 'Sports Mode',
          subtitle: appState.sportsMode
              ? 'On — sports categories only'
              : 'Sports categories only (no PIN)',
          trailing: IgnorePointer(
              child: Switch(value: appState.sportsMode, onChanged: (_) {})),
          onTap: () => appState.setSportsMode(!appState.sportsMode),
        ),
        _SettingRow(
          title: 'Kids Bedtime',
          subtitle: appState.kidsBedtimeEnabled
              ? 'On — Kids Mode locks at ${fmtMinutesOfDay(appState.kidsBedtimeMinutes)} until 6:00 AM'
              : 'Lock Kids Mode at night (PIN to exit)',
          trailing: IgnorePointer(
              child:
                  Switch(value: appState.kidsBedtimeEnabled, onChanged: (_) {})),
          onTap: () =>
              appState.setKidsBedtimeEnabled(!appState.kidsBedtimeEnabled),
        ),
        if (appState.kidsBedtimeEnabled)
          _SettingRow(
            title: 'Bedtime',
            subtitle: fmtMinutesOfDay(appState.kidsBedtimeMinutes),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const BedtimeTimePage())),
          ),
        const _SectionTitle('My Groups'),
        _SettingRow(
          title: 'Custom Groups',
          subtitle: appState.groups.isEmpty
              ? 'No groups yet — open a channel menu (Menu key) to create one'
              : '${appState.groups.length} group${appState.groups.length == 1 ? '' : 's'} on the ${appState.activeProfile.name} profile',
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const GroupsPage())),
        ),
        const _SectionTitle('Language'),
        _SettingRow(
          title: 'Channel Language',
          subtitle: appState.languageFilter.isEmpty
              ? 'All languages — every channel also shows a language badge'
              : 'Filtered — change to see other languages',
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const LanguageSettingsPage())),
        ),
        const _SectionTitle('Channel Categories'),
        _SettingRow(
          title: 'Show / Hide Categories',
          subtitle: 'Choose which category rows appear on Home',
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const CategoryVisibilityPage())),
        ),
        const _SectionTitle('Data'),
        _SettingRow(
          title: 'Clear Cache',
          subtitle: 'Clears cached channel logos',
          onTap: () {
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Cache cleared.')));
          },
        ),
        _SettingRow(
          title: 'Clear Favorites',
          subtitle: 'Removes favorites here and on the website',
          onTap: () async {
            if (await _confirm(context, 'Clear favorites?',
                'This removes all favorites from the app and your account.')) {
              await appState.clearFavorites();
            }
          },
        ),
        _SettingRow(
          title: 'Restore Defaults',
          subtitle: 'Category visibility back to defaults',
          onTap: () => appState.restoreCategoryDefaults(),
        ),
        const _SectionTitle('Help'),
        _SettingRow(
          title: 'Remote Shortcuts',
          subtitle: 'Every remote key the app listens to',
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ShortcutsHelpPage())),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text('Viu Live TV for Android TV · version 2.0.0 · Dark mode only',
              style:
                  theme.textTheme.bodySmall?.copyWith(color: Colors.white38)),
        ),
      ],
    );
  }
}

class LanguageSettingsPage extends StatelessWidget {
  const LanguageSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final options = availableLanguages(appState.all);
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 36, 32),
            children: [
              Text('Channel Language', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              _SettingRow(
                title: 'All Languages',
                subtitle: '${appState.all.length} channels',
                autofocus: appState.languageFilter.isEmpty,
                trailing: appState.languageFilter.isEmpty
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                onTap: () => appState.setLanguageFilter(''),
              ),
              for (final o in options)
                _SettingRow(
                  title: o.label,
                  subtitle: '${o.count} channels',
                  autofocus: appState.languageFilter == o.code,
                  trailing: appState.languageFilter == o.code
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: () => appState.setLanguageFilter(o.code),
                ),
            ],
          );
        },
      ),
    );
  }
}

class LockedChannelsPage extends StatefulWidget {
  const LockedChannelsPage({super.key});
  @override
  State<LockedChannelsPage> createState() => _LockedChannelsPageState();
}

class _LockedChannelsPageState extends State<LockedChannelsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.trim().toLowerCase();
    final channels = q.isEmpty
        ? appState.all
        : appState.all
            .where((c) => c.name.toLowerCase().contains(q))
            .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Locked Channels')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 16, 36, 8),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Filter channels',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              itemCount: channels.length,
              itemBuilder: (context, i) {
                final c = channels[i];
                final isLocked = appState.locked.contains(c.streamId);
                return _SettingRow(
                  title: c.name,
                  subtitle: c.tags.take(3).join(' · '),
                  trailing: Icon(
                    isLocked ? Icons.lock : Icons.lock_open_outlined,
                    color: isLocked ? theme.colorScheme.primary : Colors.white38,
                  ),
                  onTap: () => appState.toggleLocked(c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class CategoryVisibilityPage extends StatelessWidget {
  const CategoryVisibilityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Show / Hide Categories')),
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final tags = appState.tags
              .where((t) => t.parameterName != 'FAVORITES')
              .toList();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            itemCount: tags.length,
            itemBuilder: (context, i) {
              final t = tags[i];
              final hidden = appState.hiddenTags.contains(t.parameterName);
              return _SettingRow(
                title: t.displayName,
                subtitle: hidden ? 'Hidden' : 'Shown',
                trailing: IgnorePointer(
                    child: Switch(value: !hidden, onChanged: (_) {})),
                onTap: () =>
                    appState.setTagHidden(t.parameterName, !hidden),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profiles / groups / bedtime / shortcuts pages (2.0.0)
// ---------------------------------------------------------------------------

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final active = appState.activeProfile;
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 36, 32),
            children: [
              Text('Profiles', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Each profile keeps its own favorites, recents and groups on this TV. Only the Main profile syncs favorites with your Viu account.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.white60),
                ),
              ),
              const SizedBox(height: 12),
              for (final p in appState.profiles)
                _SettingRow(
                  title: p.name,
                  subtitle: p.id == appState.activeProfileId
                      ? 'Active profile'
                      : 'Tap to switch to this profile',
                  autofocus: p.id == appState.activeProfileId,
                  trailing: p.id == appState.activeProfileId
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: () => appState.switchProfile(p.id),
                ),
              const _SectionTitle('Manage'),
              _SettingRow(
                title: 'Add Profile',
                trailing: const Icon(Icons.add),
                onTap: () async {
                  final name = await askText(context, 'New profile name',
                      hint: 'e.g. Kids, Guest', saveLabel: 'Add');
                  if (name == null) return;
                  await appState.addProfile(name);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content:
                            Text('Profile “$name” added — tap it to switch.')));
                  }
                },
              ),
              _SettingRow(
                title: 'Rename Active Profile',
                subtitle: active.name,
                onTap: () async {
                  final name = await askText(context, 'Rename profile',
                      initial: active.name, saveLabel: 'Rename');
                  if (name == null) return;
                  await appState.renameProfile(active.id, name);
                },
              ),
              _SettingRow(
                title: 'Delete Active Profile',
                subtitle: appState.profiles.length <= 1
                    ? 'The last profile cannot be deleted'
                    : 'Deletes ${active.name}’s favorites, recents and groups on this TV',
                onTap: () async {
                  if (appState.profiles.length <= 1) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Keep at least one profile.')));
                    return;
                  }
                  if (await _confirm(context, 'Delete ${active.name}?',
                      'Its favorites, recents and groups on this TV will be removed.')) {
                    await appState.deleteProfile(active.id);
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class GroupsPage extends StatelessWidget {
  const GroupsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 36, 32),
            children: [
              Text('Custom Groups', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Groups belong to the ${appState.activeProfile.name} profile and appear as rows on Home. Add channels from any channel menu (Menu key on a channel).',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.white60),
                ),
              ),
              const SizedBox(height: 12),
              for (final g in appState.groups)
                _SettingRow(
                  title: g.name,
                  subtitle: '${g.channelIds.length} channels',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => GroupDetailPage(groupId: g.id))),
                ),
              _SettingRow(
                title: 'New Group',
                trailing: const Icon(Icons.add),
                autofocus: appState.groups.isEmpty,
                onTap: () async {
                  final name = await askText(context, 'New group name',
                      hint: 'e.g. Match Days', saveLabel: 'Create');
                  if (name == null) return;
                  await appState.createGroup(name);
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class GroupDetailPage extends StatelessWidget {
  final String groupId;
  const GroupDetailPage({super.key, required this.groupId});

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final g = appState.groupById(groupId);
          if (g == null) {
            return const Center(child: Text('This group no longer exists.'));
          }
          final channels = <EPGChannel>[
            for (final id in g.channelIds)
              if (appState.channelById(id) != null) appState.channelById(id)!,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 36, 32),
            children: [
              Text(g.name, style: theme.textTheme.headlineMedium),
              const _SectionTitle('Group'),
              _SettingRow(
                title: 'Rename Group',
                subtitle: g.name,
                autofocus: true,
                onTap: () async {
                  final name = await askText(context, 'Rename group',
                      initial: g.name, saveLabel: 'Rename');
                  if (name == null) return;
                  await appState.renameGroup(g.id, name);
                },
              ),
              _SettingRow(
                title: 'Delete Group',
                subtitle: 'The channels themselves are not affected',
                onTap: () async {
                  if (await _confirm(context, 'Delete ${g.name}?',
                      'The group row will disappear from Home.')) {
                    await appState.deleteGroup(g.id);
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
              ),
              const _SectionTitle('Channels'),
              if (channels.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  child: Text(
                    'No channels yet. Focus a channel anywhere and press the Menu key, then “Add to Group…”.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: Colors.white60),
                  ),
                ),
              for (final c in channels)
                _SettingRow(
                  title: c.name,
                  subtitle: 'Tap to remove from ${g.name}',
                  trailing: const Icon(Icons.remove_circle_outline),
                  onTap: () => appState.removeFromGroup(g.id, c.streamId),
                ),
            ],
          );
        },
      ),
    );
  }
}

class BedtimeTimePage extends StatelessWidget {
  const BedtimeTimePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListenableBuilder(
        listenable: appState,
        builder: (context, _) {
          final options = <int>[
            for (var m = 17 * 60; m <= 23 * 60 + 30; m += 30) m,
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 36, 32),
            children: [
              Text('Bedtime', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Kids Mode locks at this time and unlocks at 6:00 AM. Exiting early needs the parental PIN.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.white60),
                ),
              ),
              const SizedBox(height: 12),
              for (final m in options)
                _SettingRow(
                  title: fmtMinutesOfDay(m),
                  autofocus: appState.kidsBedtimeMinutes == m,
                  trailing: appState.kidsBedtimeMinutes == m
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: () => appState.setKidsBedtimeMinutes(m),
                ),
            ],
          );
        },
      ),
    );
  }
}

class ShortcutsHelpPage extends StatelessWidget {
  const ShortcutsHelpPage({super.key});

  static const _rows = <(String, String, String)>[
    // (section, keys, action)
    ('Player', 'OK / Play-Pause', 'Play or pause'),
    ('Player', 'Up / Down', 'Previous / next channel'),
    ('Player', 'Left / Right', 'Move between video and the player buttons'),
    ('Player', 'Menu or F', 'Favorite / unfavorite this channel'),
    ('Player', 'G', 'Channel guide overlay'),
    ('Player', 'L', 'Jump to the last channel'),
    ('Player', 'M', 'Open Multiview'),
    ('Player', 'S', 'Sleep timer menu'),
    ('Player', 'A', 'Audio-only on/off (black screen, sound keeps playing)'),
    ('Player', 'T', 'Audio & subtitles menu'),
    ('Player', 'Back', 'Close overlay or menu, then exit the player'),
    ('Home & lists', 'Menu', 'Open the channel menu (play, favorite, pin/move favorites, groups)'),
    ('Home & lists', 'F', 'Favorite / unfavorite the focused channel'),
    ('Home & lists', 'Long-press OK', 'Open the channel menu (touch / mouse long-press works too)'),
    ('Multiview', 'D-pad', 'The focused pane is the one you hear'),
    ('Multiview', 'OK', 'Expand the focused pane to the full player'),
    ('Multiview', 'Menu or F', 'Remove the focused pane'),
    ('Multiview', 'Back', 'Exit Multiview'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      Text('Remote Shortcuts', style: theme.textTheme.headlineMedium),
    ];
    String? lastSection;
    for (final (section, keys, action) in _rows) {
      if (section != lastSection) {
        children.add(_SectionTitle(section));
        lastSection = section;
      }
      children.add(_SettingRow(title: action, subtitle: keys));
    }
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 36, 32),
        children: children,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Player — fullscreen, remote-first
//
// Remote map: D-pad centre / media Play-Pause = play/pause · Up/Down =
// previous/next channel · Menu or F = favorite · Guide button or G =
// channel guide overlay · S = sleep timer · A = audio-only ·
// T = audio & subtitles · Back = close overlay/menu, then exit.
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
  final FocusNode _rootFocus = FocusNode();
  final FocusNode _playButtonFocus = FocusNode();
  final FocusNode _favButtonFocus = FocusNode();
  final FocusNode _lastButtonFocus = FocusNode();
  final FocusNode _guideButtonFocus = FocusNode();
  final FocusNode _multiButtonFocus = FocusNode();
  final FocusNode _sleepButtonFocus = FocusNode();
  final FocusNode _tracksButtonFocus = FocusNode();

  late EPGChannel _channel;
  EPGChannel? _previous;
  bool _loading = true;
  bool _buffering = false;
  bool _playing = false;
  String? _error;
  String? _lastError;
  bool _overlay = true;
  bool _guideOpen = false;
  Timer? _hideTimer;
  Timer? _watchdog;
  final List<String> _logTail = [];
  final List<StreamSubscription> _subs = [];

  // 2.0.0 player features.
  bool _wantPlaying = true; // false after an intentional pause
  bool _audioOnly = false;
  // Sleep timer.
  int _sleepChoice = 0; // minutes; 0 = off
  DateTime? _sleepDeadline;
  Timer? _sleepFireTimer;
  Timer? _sleepTicker;
  bool _sleepEnded = false;
  bool _sleepMenuOpen = false;
  // Audio/subtitle track menu (snapshotted when the menu opens).
  bool _tracksMenuOpen = false;
  List<AudioTrack> _audioTracks = [];
  List<SubtitleTrack> _subtitleTracks = [];
  String? _selAudioId;
  String? _selSubtitleId;
  // Auto-reconnect + stream health.
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  bool _wasBuffering = false;
  final List<DateTime> _healthEvents = [];

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
        // Playback (re)started — the reconnect loop has done its job.
        _reconnectTimer?.cancel();
        _reconnectAttempt = 0;
      }
      setState(() {
        _playing = v;
        if (v && _error != null) _error = null;
      });
    }));
    _subs.add(_player.stream.buffering.listen((v) {
      if (!mounted) return;
      if (v && !_wasBuffering) _noteHealthEvent();
      _wasBuffering = v;
      setState(() => _buffering = v);
    }));
    _subs.add(_player.stream.error.listen((e) {
      // mpv reports transient problems on live streams (famously
      // "Cannot seek in this stream") and then often plays fine, so
      // never fail the channel on an error event alone — the watchdog
      // in _load surfaces the last error only if playback never starts.
      _lastError = e;
      _noteHealthEvent();
      _maybeReconnect();
    }));
    _subs.add(_player.stream.log.listen((log) {
      _logTail.add('${log.level}/${log.prefix}: ${log.text}'.trim());
      if (_logTail.length > 10) _logTail.removeAt(0);
    }));
    _showOverlay();
    _initPlayer();
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
      if (mounted && !_playing && _error == null) {
        setState(() {
          _error = _lastError ?? 'The stream did not start.';
          _loading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _watchdog?.cancel();
    _sleepFireTimer?.cancel();
    _sleepTicker?.cancel();
    _reconnectTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _rootFocus.dispose();
    _playButtonFocus.dispose();
    _favButtonFocus.dispose();
    _lastButtonFocus.dispose();
    _guideButtonFocus.dispose();
    _multiButtonFocus.dispose();
    _sleepButtonFocus.dispose();
    _tracksButtonFocus.dispose();
    super.dispose();
  }

  Future<void> _load(EPGChannel channel) async {
    if (channel.streamId != _channel.streamId) {
      _previous = _channel;
      // A new channel gets a fresh reconnect budget. (The reconnect
      // loop itself calls _load with the SAME channel, so its counter
      // is not reset here.)
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
    }
    unawaited(appState.recordRecent(channel.streamId));
    _wantPlaying = true;
    setState(() {
      _channel = channel;
      _loading = true;
      _error = null;
      _lastError = null;
    });
    _armWatchdog();
    try {
      final links = await appState.api.liveLinks(channel.streamId);
      if (links.isFavorite) {
        unawaited(appState.mergeFavoriteFromServer(channel.streamId));
      }
      final url = links.liveLink;
      if (url == null || url.isEmpty) {
        throw const ApiFailure('This channel returned no playable link.');
      }
      await _player.open(
        Media(url, httpHeaders: const {'User-Agent': kUserAgent}),
        play: true,
      );
      if (_audioOnly) {
        // open() resets track selection — re-apply audio-only.
        try {
          await _player.setVideoTrack(VideoTrack.no());
        } catch (_) {}
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

  bool get _anyMenuOpen => _guideOpen || _sleepMenuOpen || _tracksMenuOpen;

  void _showOverlay() {
    if (!_overlay && mounted) setState(() => _overlay = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_anyMenuOpen && !_sleepEnded) {
        setState(() => _overlay = false);
        _rootFocus.requestFocus();
      }
    });
  }

  void _togglePlay() {
    if (_playing) {
      _wantPlaying = false;
      _player.pause();
    } else {
      _wantPlaying = true;
      _player.play();
    }
  }

  // MARK: Sleep timer (2.0.0)

  void _setSleepTimer(int minutes) {
    _sleepFireTimer?.cancel();
    _sleepTicker?.cancel();
    setState(() {
      _sleepChoice = minutes;
      _sleepMenuOpen = false;
      _sleepDeadline = minutes <= 0
          ? null
          : DateTime.now().add(Duration(minutes: minutes));
    });
    _rootFocus.requestFocus();
    if (minutes <= 0) return;
    _sleepFireTimer = Timer(Duration(minutes: minutes), _onSleepTimerFired);
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // Refreshes the countdown shown in the banner.
      if (mounted && _sleepDeadline != null) setState(() {});
    });
  }

  void _onSleepTimerFired() {
    if (!mounted) return;
    _sleepTicker?.cancel();
    _wantPlaying = false;
    _player.pause();
    setState(() {
      _sleepDeadline = null;
      _sleepChoice = 0;
      _sleepEnded = true;
      _overlay = true;
    });
  }

  void _dismissSleepEnded({required bool resume}) {
    setState(() => _sleepEnded = false);
    _rootFocus.requestFocus();
    if (resume) {
      _wantPlaying = true;
      _player.play();
    }
  }

  String get _sleepCountdownText {
    final d = _sleepDeadline;
    if (d == null) return '';
    var secs = d.difference(DateTime.now()).inSeconds;
    if (secs < 0) secs = 0;
    final m = (secs ~/ 60).toString();
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // MARK: Audio & subtitle tracks (2.0.0)

  void _openTracksMenu() {
    try {
      final tracks = _player.state.tracks;
      _audioTracks = tracks.audio;
      _subtitleTracks = tracks.subtitle;
      _selAudioId = _player.state.track.audio.id;
      _selSubtitleId = _player.state.track.subtitle.id;
    } catch (_) {
      _audioTracks = [];
      _subtitleTracks = [];
      _selAudioId = null;
      _selSubtitleId = null;
    }
    setState(() => _tracksMenuOpen = true);
  }

  String _trackLabel(String? title, String? language, String fallback) {
    if (title != null && title.isNotEmpty) return title;
    if (language != null && language.isNotEmpty) return language;
    return fallback;
  }

  // MARK: Audio-only (2.0.0)

  Future<void> _toggleAudioOnly() async {
    final next = !_audioOnly;
    setState(() => _audioOnly = next);
    try {
      await _player.setVideoTrack(next ? VideoTrack.no() : VideoTrack.auto());
    } catch (_) {
      // Stream without a selectable video track — the black overlay
      // still gives the audio-only look.
    }
  }

  // MARK: Auto-reconnect + stream health (2.0.0)

  void _noteHealthEvent() {
    final now = DateTime.now();
    _healthEvents.add(now);
    _healthEvents
        .removeWhere((t) => now.difference(t) > const Duration(minutes: 5));
  }

  Color get _healthColor {
    final now = DateTime.now();
    final recent = _healthEvents
        .where((t) => now.difference(t) <= const Duration(minutes: 5))
        .length;
    if (recent == 0) return const Color(0xFF35C26B);
    if (recent <= 2) return const Color(0xFFFFB020);
    return const Color(0xFFE5323B);
  }

  /// When the stream errors while it should be playing, reopen it up
  /// to 3 times (2s / 5s / 10s apart) before letting the existing
  /// watchdog + error panel take over. Transient mpv errors that
  /// recover on their own never trigger a reopen: a check timer only
  /// reopens if playback still hasn't (re)started when it fires.
  void _maybeReconnect() {
    if (!mounted || !_wantPlaying || _playing || _error != null) return;
    if (_reconnectAttempt >= 3) return;
    if (_reconnectTimer?.isActive ?? false) return;
    const delays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ];
    _reconnectTimer = Timer(delays[_reconnectAttempt], () {
      if (!mounted || !_wantPlaying || _playing || _error != null) return;
      if (_reconnectAttempt >= 3) return;
      setState(() => _reconnectAttempt++);
      _load(_channel);
    });
  }

  void _openGuide() {
    setState(() => _guideOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // If focus is still on the player root or an overlay button,
      // nudge it into the guide.
      if (mounted &&
          _guideOpen &&
          (_rootFocus.hasFocus ||
              _playButtonFocus.hasFocus ||
              _favButtonFocus.hasFocus ||
              _lastButtonFocus.hasFocus ||
              _guideButtonFocus.hasFocus ||
              _multiButtonFocus.hasFocus ||
              _sleepButtonFocus.hasFocus ||
              _tracksButtonFocus.hasFocus)) {
        FocusScope.of(context).nextFocus();
      }
    });
  }

  /// Last Channel swap: jump back to the previous channel (which
  /// then becomes current, so it swaps back and forth).
  Future<void> _swapToPrevious() async {
    final target = _previous;
    if (target == null) return;
    if (!await ensureUnlocked(context, target)) return;
    if (mounted) _load(target);
  }

  Future<void> _openMultiview() async {
    final wasPlaying = _playing;
    await _player.pause();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<EPGChannel>(
      MaterialPageRoute(builder: (_) => MultiviewScreen(initial: _channel)),
    );
    if (!mounted) return;
    _rootFocus.requestFocus();
    if (picked != null && picked.streamId != _channel.streamId) {
      if (await ensureUnlocked(context, picked)) {
        if (mounted) _load(picked);
      }
    } else if (wasPlaying) {
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _showOverlay();
    final key = event.logicalKey;
    if (_sleepEnded) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        _dismissSleepEnded(resume: false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // the panel button takes the rest
    }
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (_anyMenuOpen) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        setState(() {
          _guideOpen = false;
          _sleepMenuOpen = false;
          _tracksMenuOpen = false;
        });
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // menu items take the rest
    }
    // Overlay-button focus routing (deterministic remote control — the
    // Chromecast remote has no Menu key, so Favorite and Guide must be
    // reachable with the D-pad alone): Left/Right from the video enters
    // the button row, Left/Right moves along it, Up returns to the
    // video. Select is deliberately left through: the button under
    // focus activates itself, and the root branch below ignores it.
    final onButton = _playButtonFocus.hasFocus ||
        _favButtonFocus.hasFocus ||
        _lastButtonFocus.hasFocus ||
        _guideButtonFocus.hasFocus ||
        _multiButtonFocus.hasFocus ||
        _sleepButtonFocus.hasFocus ||
        _tracksButtonFocus.hasFocus;
    if (onButton) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        if (_playButtonFocus.hasFocus) {
          _favButtonFocus.requestFocus();
        } else if (_favButtonFocus.hasFocus) {
          (_previous != null ? _lastButtonFocus : _guideButtonFocus)
              .requestFocus();
        } else if (_lastButtonFocus.hasFocus) {
          _guideButtonFocus.requestFocus();
        } else if (_guideButtonFocus.hasFocus) {
          _multiButtonFocus.requestFocus();
        } else if (_multiButtonFocus.hasFocus) {
          _sleepButtonFocus.requestFocus();
        } else if (_sleepButtonFocus.hasFocus) {
          _tracksButtonFocus.requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (_tracksButtonFocus.hasFocus) {
          _sleepButtonFocus.requestFocus();
        } else if (_sleepButtonFocus.hasFocus) {
          _multiButtonFocus.requestFocus();
        } else if (_multiButtonFocus.hasFocus) {
          _guideButtonFocus.requestFocus();
        } else if (_guideButtonFocus.hasFocus) {
          (_previous != null ? _lastButtonFocus : _favButtonFocus)
              .requestFocus();
        } else if (_lastButtonFocus.hasFocus) {
          _favButtonFocus.requestFocus();
        } else if (_favButtonFocus.hasFocus) {
          _playButtonFocus.requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        return KeyEventResult.handled; // nothing below the row
      }
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _hop(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _hop(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.keyF) {
      appState.toggleFavorite(_channel);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyG) {
      _openGuide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _openMultiview();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL) {
      _swapToPrevious();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      setState(() => _sleepMenuOpen = true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyA) {
      _toggleAudioOnly();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyT) {
      _openTracksMenu();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      // Only when the root has focus (overlay buttons handle themselves).
      if (_rootFocus.hasFocus) {
        _togglePlay();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      if (_overlay) {
        setState(() => _overlay = false);
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    // From the video, Left/Right enters the overlay button row (the
    // overlay was just (re)shown at the top of this handler).
    if (_overlay && _rootFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowRight) {
        _playButtonFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        _tracksButtonFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_sleepEnded) {
          _dismissSleepEnded(resume: false);
        } else if (_anyMenuOpen) {
          setState(() {
            _guideOpen = false;
            _sleepMenuOpen = false;
            _tracksMenuOpen = false;
          });
          _rootFocus.requestFocus();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(
                controller: _controller,
                controls: (state) => const SizedBox.shrink(),
                fit: BoxFit.contain,
              ),
              if (_audioOnly) _audioOnlyOverlay(theme),
              if (_loading || _buffering)
                const Center(
                    child: CircularProgressIndicator(color: Colors.white)),
              if (_reconnectAttempt > 0 && !_playing && _error == null)
                Positioned(
                  top: 36,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        'Reconnecting… attempt $_reconnectAttempt of 3',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ),
                ),
              if (_error != null) _errorPanel(theme),
              if (_overlay && _error == null) _controlsOverlay(theme),
              if (_guideOpen) _guideOverlay(theme),
              if (_sleepMenuOpen) _sleepMenuOverlay(theme),
              if (_tracksMenuOpen) _tracksMenuOverlay(theme),
              if (_sleepEnded) _sleepEndedPanel(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorPanel(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.amber, size: 56),
          const SizedBox(height: 16),
          Text('Playback problem',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(color: Colors.white)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 80),
            child: Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
          ),
          if (_logTail.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              constraints:
                  const BoxConstraints(maxHeight: 130, maxWidth: 760),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: Text(_logTail.join('\n'),
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontFamily: 'monospace')),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            autofocus: true,
            onPressed: () {
              _reconnectAttempt = 0;
              _load(_channel);
            },
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _controlsOverlay(ThemeData theme) {
    final fav = appState.isFavorite(_channel);
    final now = _channel.nowProgramme();
    final next = _channel.nextProgramme();
    final progress = _channel.nowProgress();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(48, 40, 48, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('LIVE',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
                const SizedBox(width: 10),
                // Stream health: green = clean, amber/red = stalls or
                // errors in the last 5 minutes.
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                      color: _healthColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(_channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(color: Colors.white)),
                ),
              ],
            ),
            if (now != null) ...[
              const SizedBox(height: 6),
              Text(
                'Now: ${now.name}${next != null ? '   ·   Next: ${next.name}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
            if (progress != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: Colors.white24,
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                _OverlayButton(
                  focusNode: _playButtonFocus,
                  icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  label: _playing ? 'Pause' : 'Play',
                  primary: true,
                  onTap: _togglePlay,
                ),
                const SizedBox(width: 14),
                _OverlayButton(
                  focusNode: _favButtonFocus,
                  icon: fav ? Icons.favorite : Icons.favorite_border,
                  label: fav ? 'Favorited' : 'Favorite',
                  onTap: () => appState.toggleFavorite(_channel),
                ),
                if (_previous != null) ...[
                  const SizedBox(width: 14),
                  _OverlayButton(
                    focusNode: _lastButtonFocus,
                    icon: Icons.swap_horiz_rounded,
                    label: 'Last',
                    onTap: _swapToPrevious,
                  ),
                ],
                const SizedBox(width: 14),
                _OverlayButton(
                  focusNode: _guideButtonFocus,
                  icon: Icons.list_rounded,
                  label: 'Guide',
                  onTap: _openGuide,
                ),
                const SizedBox(width: 14),
                _OverlayButton(
                  focusNode: _multiButtonFocus,
                  icon: Icons.grid_view_rounded,
                  label: 'Multiview',
                  onTap: _openMultiview,
                ),
                const SizedBox(width: 14),
                _OverlayButton(
                  focusNode: _sleepButtonFocus,
                  icon: Icons.bedtime_outlined,
                  label: _sleepDeadline != null
                      ? 'Sleep $_sleepCountdownText'
                      : 'Sleep',
                  onTap: () => setState(() => _sleepMenuOpen = true),
                ),
                const SizedBox(width: 14),
                _OverlayButton(
                  focusNode: _tracksButtonFocus,
                  icon: Icons.subtitles_outlined,
                  label: 'Audio/Sub',
                  onTap: _openTracksMenu,
                ),
                const Spacer(),
                const Text('↑↓ channel · ←→ buttons · Back exit',
                    style: TextStyle(color: Colors.white54, fontSize: 14)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _guideOverlay(ThemeData theme) {
    final list = widget.contextList;
    final currentIdx =
        list.indexWhere((c) => c.streamId == _channel.streamId);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 480,
        color: Colors.black.withValues(alpha: 0.88),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 12),
              child: Text('Guide',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(color: Colors.white)),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final c = list[i];
                  final isCurrent = i == currentIdx;
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      autofocus: isCurrent || (currentIdx < 0 && i == 0),
                      onTap: () async {
                        setState(() => _guideOpen = false);
                        _rootFocus.requestFocus();
                        if (c.streamId != _channel.streamId) {
                          if (await ensureUnlocked(context, c)) {
                            _load(c);
                          }
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: isCurrent
                                  ? theme.colorScheme.primary
                                  : Colors.transparent,
                              width: 4,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(c.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                          fontWeight: isCurrent
                                              ? FontWeight.w700
                                              : FontWeight.w400)),
                                ),
                                if (appState.isLocked(c))
                                  const Icon(Icons.lock,
                                      size: 17, color: Colors.white60),
                                if (appState.isFavorite(c))
                                  Icon(Icons.favorite,
                                      size: 17,
                                      color: theme.colorScheme.primary),
                              ],
                            ),
                            Text(c.nowText(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 14)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // MARK: 2.0.0 player overlays

  Widget _audioOnlyOverlay(ThemeData theme) {
    final now = _channel.nowProgramme();
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_channel.streamIcon != null)
              SizedBox(
                width: 200,
                height: 120,
                child: Image.network(
                  _channel.streamIcon!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            const SizedBox(height: 16),
            Icon(Icons.headphones_rounded,
                color: theme.colorScheme.primary, size: 40),
            const SizedBox(height: 12),
            Text(_channel.name,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(color: Colors.white)),
            if (now != null) ...[
              const SizedBox(height: 6),
              Text(now.name,
                  style: const TextStyle(color: Colors.white70, fontSize: 17)),
            ],
            const SizedBox(height: 10),
            const Text('Audio only — press A to bring the picture back',
                style: TextStyle(color: Colors.white38, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _sidePanelShell(ThemeData theme, String title, List<Widget> rows) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 480,
        color: Colors.black.withValues(alpha: 0.88),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 36, 24, 12),
              child: Text(title,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(color: Colors.white)),
            ),
            Expanded(child: ListView(children: rows)),
          ],
        ),
      ),
    );
  }

  Widget _menuRow({
    required String title,
    String? subtitle,
    bool selected = false,
    bool autofocus = false,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        autofocus: autofocus,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w400)),
                    if (subtitle != null)
                      Text(subtitle,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 14)),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check,
                    size: 20, color: Theme.of(context).colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sleepMenuOverlay(ThemeData theme) {
    const options = <(int, String)>[
      (0, 'Off'),
      (15, '15 minutes'),
      (30, '30 minutes'),
      (60, '60 minutes'),
      (90, '90 minutes'),
    ];
    return _sidePanelShell(theme, 'Sleep Timer', [
      for (final (mins, label) in options)
        _menuRow(
          title: label,
          subtitle: mins == _sleepChoice && _sleepDeadline != null
              ? '$_sleepCountdownText left'
              : null,
          selected: _sleepChoice == mins,
          autofocus: _sleepChoice == mins,
          onTap: () => _setSleepTimer(mins),
        ),
    ]);
  }

  Widget _tracksMenuOverlay(ThemeData theme) {
    final rows = <Widget>[];
    if (_audioTracks.isEmpty && _subtitleTracks.isEmpty) {
      rows.add(_menuRow(
        title: 'No alternate tracks on this stream',
        autofocus: true,
        onTap: () => setState(() => _tracksMenuOpen = false),
      ));
    }
    if (_audioTracks.isNotEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.fromLTRB(24, 8, 24, 4),
        child: Text('AUDIO',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      ));
      for (var i = 0; i < _audioTracks.length; i++) {
        final t = _audioTracks[i];
        rows.add(_menuRow(
          title: _trackLabel(t.title, t.language, 'Audio ${i + 1}'),
          selected: t.id == _selAudioId,
          autofocus: rows.length == 1,
          onTap: () async {
            try {
              await _player.setAudioTrack(t);
            } catch (_) {}
            if (mounted) {
              setState(() {
                _selAudioId = t.id;
                _tracksMenuOpen = false;
              });
              _rootFocus.requestFocus();
            }
          },
        ));
      }
    }
    if (_subtitleTracks.isNotEmpty) {
      rows.add(const Padding(
        padding: EdgeInsets.fromLTRB(24, 16, 24, 4),
        child: Text('SUBTITLES',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      ));
      rows.add(_menuRow(
        title: 'Off',
        selected: _selSubtitleId == null || _selSubtitleId == 'no',
        autofocus: _audioTracks.isEmpty,
        onTap: () async {
          try {
            await _player.setSubtitleTrack(SubtitleTrack.no());
          } catch (_) {}
          if (mounted) {
            setState(() {
              _selSubtitleId = 'no';
              _tracksMenuOpen = false;
            });
            _rootFocus.requestFocus();
          }
        },
      ));
      for (var i = 0; i < _subtitleTracks.length; i++) {
        final t = _subtitleTracks[i];
        rows.add(_menuRow(
          title: _trackLabel(t.title, t.language, 'Subtitle ${i + 1}'),
          selected: t.id == _selSubtitleId,
          onTap: () async {
            try {
              await _player.setSubtitleTrack(t);
            } catch (_) {}
            if (mounted) {
              setState(() {
                _selSubtitleId = t.id;
                _tracksMenuOpen = false;
              });
              _rootFocus.requestFocus();
            }
          },
        ));
      }
    }
    return _sidePanelShell(theme, 'Audio & Subtitles', rows);
  }

  Widget _sleepEndedPanel(ThemeData theme) {
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bedtime_rounded,
                color: theme.colorScheme.primary, size: 64),
            const SizedBox(height: 18),
            Text('Sleep timer ended',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(color: Colors.white)),
            const SizedBox(height: 8),
            Text('${_channel.name} is paused.',
                style: const TextStyle(color: Colors.white70, fontSize: 17)),
            const SizedBox(height: 28),
            FilledButton(
              autofocus: true,
              onPressed: () => _dismissSleepEnded(resume: true),
              child: const Text('Keep Watching'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Multiview (Android TV): up to four channels at once, D-pad driven
// ---------------------------------------------------------------------------

class MultiviewScreen extends StatefulWidget {
  final EPGChannel initial;
  const MultiviewScreen({super.key, required this.initial});

  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

class _MultiviewScreenState extends State<MultiviewScreen> {
  late final List<EPGChannel?> _slots = [widget.initial, null, null, null];
  int _audioSlot = 0;

  Future<void> _pickForSlot(int slot) async {
    final picked = await Navigator.of(context).push<EPGChannel>(
      MaterialPageRoute(builder: (_) => const MultiviewPickerPage()),
    );
    if (picked == null) return;
    if (!await ensureUnlocked(context, picked)) return;
    if (mounted) {
      setState(() {
        _slots[slot] = picked;
        _audioSlot = slot;
      });
    }
  }

  // Menu / F clears the pane that currently holds focus (and audio).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.contextMenu ||
            event.logicalKey == LogicalKeyboardKey.keyF)) {
      if (_slots[_audioSlot] != null) {
        setState(() => _slots[_audioSlot] = null);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Multiview',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(color: Colors.white)),
                  const Spacer(),
                  const Text(
                      'OK = full screen · Menu = remove focused pane · Back = exit',
                      style: TextStyle(color: Colors.white54, fontSize: 15)),
                ],
              ),
              const SizedBox(height: 18),
              Expanded(
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 16 / 9,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: 4,
                  itemBuilder: (context, i) {
                    final channel = _slots[i];
                    if (channel == null) {
                      return _EmptyPane(
                        autofocus: i == 1,
                        onTap: () => _pickForSlot(i),
                        onFocus: () => setState(() => _audioSlot = i),
                      );
                    }
                    return _TvMultiviewCell(
                      key: ValueKey('${channel.streamId}-$i'),
                      channel: channel,
                      audio: _audioSlot == i,
                      autofocus: i == 0,
                      onFocus: () => setState(() => _audioSlot = i),
                      onTap: () => Navigator.of(context).pop(channel),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyPane extends StatefulWidget {
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback onFocus;
  const _EmptyPane({
    required this.autofocus,
    required this.onTap,
    required this.onFocus,
  });

  @override
  State<_EmptyPane> createState() => _EmptyPaneState();
}

class _EmptyPaneState extends State<_EmptyPane> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocus();
      },
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _focused ? theme.colorScheme.primary : Colors.white24,
                width: _focused ? 3 : 1,
              ),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, color: Colors.white70, size: 40),
                SizedBox(height: 8),
                Text('Add Channel',
                    style: TextStyle(color: Colors.white70, fontSize: 18)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One Multiview pane: its own media_kit player, audible only while
/// it holds D-pad focus.
class _TvMultiviewCell extends StatefulWidget {
  final EPGChannel channel;
  final bool audio;
  final bool autofocus;
  final VoidCallback onFocus;
  final VoidCallback onTap;
  const _TvMultiviewCell({
    super.key,
    required this.channel,
    required this.audio,
    required this.autofocus,
    required this.onFocus,
    required this.onTap,
  });

  @override
  State<_TvMultiviewCell> createState() => _TvMultiviewCellState();
}

class _TvMultiviewCellState extends State<_TvMultiviewCell> {
  late final Player _player;
  late final VideoController _controller;
  bool _focused = false;
  bool _failed = false;

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
    await _player.setVolume(widget.audio ? 100 : 0);
    if (mounted) _load();
  }

  @override
  void didUpdateWidget(_TvMultiviewCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audio != widget.audio) {
      _player.setVolume(widget.audio ? 100 : 0);
    }
    if (oldWidget.channel.streamId != widget.channel.streamId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _failed = false);
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
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocus();
      },
      child: Material(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color:
                    _focused ? theme.colorScheme.primary : Colors.white24,
                width: _focused ? 3 : 1,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(
                  controller: _controller,
                  controls: (state) => const SizedBox.shrink(),
                  fit: BoxFit.contain,
                ),
                if (_failed)
                  const Center(
                    child: Text('Couldn\'t load this channel',
                        style: TextStyle(color: Colors.white70, fontSize: 16)),
                  ),
                Positioned(
                  left: 12,
                  bottom: 10,
                  right: 12,
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                            color: Colors.red, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(widget.channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 4)
                                ])),
                      ),
                      if (widget.audio)
                        const Icon(Icons.volume_up,
                            color: Colors.white70, size: 19),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Channel picker for an empty Multiview pane: a focusable grid that
/// pops with the chosen channel.
class MultiviewPickerPage extends StatelessWidget {
  const MultiviewPickerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var channels = appState.all;
    if (appState.kidsMode) {
      channels = channels.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (appState.languageFilter.isNotEmpty) {
      channels = channels
          .where((c) => c.language.code == appState.languageFilter)
          .toList();
    }
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 28, 36, 8),
            child: Text('Add Channel',
                style: theme.textTheme.headlineMedium),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(36, 16, 36, 28),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 20,
                crossAxisSpacing: 20,
                childAspectRatio: 1.32,
              ),
              itemCount: channels.length,
              itemBuilder: (context, i) {
                final c = channels[i];
                return _PickerTile(
                  channel: c,
                  autofocus: i == 0,
                  onTap: () => Navigator.of(context).pop(c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A focusable channel tile for the Multiview picker — same look as
/// TvChannelCard, but tapping pops with the channel instead of
/// starting playback.
class _PickerTile extends StatefulWidget {
  final EPGChannel channel;
  final bool autofocus;
  final VoidCallback onTap;
  const _PickerTile({
    required this.channel,
    required this.autofocus,
    required this.onTap,
  });

  @override
  State<_PickerTile> createState() => _PickerTileState();
}

class _PickerTileState extends State<_PickerTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.channel;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedScale(
        scale: _focused ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 140),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _focused
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 3,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      color: Colors.black54,
                      alignment: Alignment.center,
                      child: c.streamIcon != null
                          ? Image.network(
                              c.streamIcon!,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Text(
                                  c.name.isEmpty ? '?' : c.name[0],
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(color: Colors.white38)),
                            )
                          : Text(c.name.isEmpty ? '?' : c.name[0],
                              style: theme.textTheme.headlineMedium
                                  ?.copyWith(color: Colors.white38)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
                    child: Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Text(c.nowText(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white60)),
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

class _OverlayButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final FocusNode? focusNode;
  const _OverlayButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: primary
          ? theme.colorScheme.primary
          : Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        focusNode: focusNode,
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 24),
              const SizedBox(width: 9),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
