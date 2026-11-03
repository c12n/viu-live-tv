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
    var favs = all.where((c) => favorites.contains(c.streamId)).toList();
    if (kidsMode) {
      favs = favs.where((c) => c.tags.contains('KIDS')).toList();
    }
    if (sportsMode) {
      favs = favs.where((c) => c.tags.any(isSportsTag)).toList();
    }
    return _applyLanguage(favs);
  }

  // MARK: Recently watched

  Future<void> recordRecent(int streamId) async {
    recentIds.remove(streamId);
    recentIds.insert(0, streamId);
    if (recentIds.length > 12) {
      recentIds = recentIds.sublist(0, 12);
    }
    await _prefs?.setStringList(
        'viu_recents', recentIds.map((e) => e.toString()).toList());
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
    favorites = (prefs.getStringList('viu_favorites') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    locked = (prefs.getStringList('viu_locked') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    recentIds = (prefs.getStringList('viu_recents') ?? [])
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    hiddenTags = (prefs.getStringList('viu_hidden_tags') ?? []).toSet();
    tagOrder = prefs.getStringList('viu_tag_order') ?? [];
    accentIndex = prefs.getInt('viu_accent') ?? 0;
    languageFilter = prefs.getString('viu_language_filter') ?? '';
    sportsMode = prefs.getBool('viu_sports_mode') ?? false;
    kidsMode = prefs.getBool('viu_kids_mode') ?? false;
    parentalEnabled = prefs.getBool('viu_parental_enabled') ?? false;
    customPin = await _secure.read(key: 'viu_parental_pin');
    if (token != null) {
      api.token = token;
      await refreshAccountAndEpg();
    }
    booted = true;
    notifyListeners();
  }

  Future<void> _saveFavorites() async => _prefs?.setStringList(
      'viu_favorites', favorites.map((e) => e.toString()).toList());
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
      // Favorites: add-only two-way sync with the website list.
      final serverFavs =
          (byTag['FAVORITES'] ?? []).map((c) => c.streamId).toSet();
      final localOnly = favorites.difference(serverFavs);
      favorites = {...favorites, ...serverFavs};
      await _saveFavorites();
      for (final id in localOnly) {
        unawaited(api.saveFavorite(id));
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
    if (favorites.add(streamId)) {
      await _saveFavorites();
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(EPGChannel c) async {
    if (favorites.contains(c.streamId)) {
      favorites.remove(c.streamId);
      unawaited(api.removeFavorite(c.streamId));
    } else {
      favorites.add(c.streamId);
      unawaited(api.saveFavorite(c.streamId));
    }
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> clearFavorites() async {
    for (final id in favorites.toList()) {
      unawaited(api.removeFavorite(id));
    }
    favorites = {};
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
    (Icons.search_rounded, 'Search'),
    (Icons.settings_rounded, 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    appState.intentRequest.addListener(_maybeHandleIntent);
  }

  @override
  void dispose() {
    appState.intentRequest.removeListener(_maybeHandleIntent);
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
  const TvChannelCard({
    super.key,
    required this.channel,
    required this.contextList,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  State<TvChannelCard> createState() => _TvChannelCardState();
}

class _TvChannelCardState extends State<TvChannelCard> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.contextMenu ||
            event.logicalKey == LogicalKeyboardKey.keyF)) {
      appState.toggleFavorite(widget.channel);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    final sections = <(String, List<EPGChannel>)>[
      if (recents.isNotEmpty) ('Recently Watched', recents),
      if (favs.isNotEmpty) ('Favorites', favs),
      for (final t in visible)
        if (appState.channelsFor(t).isNotEmpty)
          (t.displayName, appState.channelsFor(t)),
    ];
    if (sections.isEmpty) {
      return Center(
        child: Text(
          'No channels to show.\nCheck Modes and category visibility in Settings.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(color: Colors.white60),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(36, 28, 12, 28),
      itemCount: sections.length,
      itemBuilder: (context, s) {
        final (title, channels) = sections[s];
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              SizedBox(
                height: 218,
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
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
            'No favorites yet.\nFocus a channel and press the Menu key (or F) to favorite it.',
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
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text('Viu Live TV for Android TV · version 1.5.0 · Dark mode only',
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
// Player — fullscreen, remote-first
//
// Remote map: D-pad centre / media Play-Pause = play/pause · Up/Down =
// previous/next channel · Menu or F = favorite · Guide button or G =
// channel guide overlay · Back = close overlay/guide, then exit.
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

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _player = Player();
    _controller = VideoController(_player);
    _subs.add(_player.stream.playing.listen((v) {
      if (!mounted) return;
      if (v) _watchdog?.cancel();
      setState(() {
        _playing = v;
        if (v && _error != null) _error = null;
      });
    }));
    _subs.add(_player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    }));
    _subs.add(_player.stream.error.listen((e) {
      // mpv reports transient problems on live streams (famously
      // "Cannot seek in this stream") and then often plays fine, so
      // never fail the channel on an error event alone — the watchdog
      // in _load surfaces the last error only if playback never starts.
      _lastError = e;
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
    super.dispose();
  }

  Future<void> _load(EPGChannel channel) async {
    if (channel.streamId != _channel.streamId) {
      _previous = _channel;
    }
    unawaited(appState.recordRecent(channel.streamId));
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
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_guideOpen) {
        setState(() => _overlay = false);
        _rootFocus.requestFocus();
      }
    });
  }

  void _togglePlay() {
    if (_playing) {
      _player.pause();
    } else {
      _player.play();
    }
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
              _multiButtonFocus.hasFocus)) {
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
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (_guideOpen) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        setState(() => _guideOpen = false);
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // guide items take the rest
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
        _multiButtonFocus.hasFocus;
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
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (_multiButtonFocus.hasFocus) {
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
        _multiButtonFocus.requestFocus();
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
        if (_guideOpen) {
          setState(() => _guideOpen = false);
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
              if (_loading || _buffering)
                const Center(
                    child: CircularProgressIndicator(color: Colors.white)),
              if (_error != null) _errorPanel(theme),
              if (_overlay && _error == null) _controlsOverlay(theme),
              if (_guideOpen) _guideOverlay(theme),
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
            onPressed: () => _load(_channel),
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
