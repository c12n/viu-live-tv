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

  int accentIndex = 0;
  int appearanceMode = 0; // 0 System, 1 Light, 2 Dark
  String languageFilter = ''; // '' = all languages
  Set<String> hiddenTags = {};
  List<String> tagOrder = [];
  bool sportsMode = false;
  bool kidsMode = false;
  bool parentalEnabled = false;
  String? customPin;

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

  List<EPGChannel> favoriteChannels() {
    var favs = all.where((c) => favorites.contains(c.streamId)).toList();
    if (kidsMode) {
      favs = favs.where((c) => c.tags.contains('KIDS')).toList();
    } else if (sportsMode) {
      favs = favs.where((c) => c.tags.any(isSportsTag)).toList();
    }
    return _applyLanguage(favs);
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
    hiddenTags = (prefs.getStringList('viu_hidden_tags') ?? []).toSet();
    tagOrder = prefs.getStringList('viu_tag_order') ?? [];
    accentIndex = prefs.getInt('viu_accent') ?? 0;
    appearanceMode = prefs.getInt('viu_appearance') ?? 0;
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
    await p.setInt('viu_appearance', appearanceMode);
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
        final light = ColorScheme.fromSeed(
          seedColor: appState.accent.seed,
          brightness: Brightness.light,
        );
        final dark = ColorScheme.fromSeed(
          seedColor: appState.accent.seed,
          brightness: Brightness.dark,
        );
        return MaterialApp(
          title: 'Viu Live TV',
          debugShowCheckedModeBanner: false,
          themeMode: appState.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: light,
            textTheme: _textTheme(Brightness.light),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: dark,
            scaffoldBackgroundColor: const Color(0xFF0A0A0E),
            textTheme: _textTheme(Brightness.dark),
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

/// One channel row — the mobile counterpart of the iOS v1.3.1 row:
/// 54 pt logo, big semibold name, language badge right after the name,
/// current programme, progress bar, then the next programme.
class ChannelRow extends StatelessWidget {
  final EPGChannel channel;
  final List<EPGChannel> contextList;
  const ChannelRow(
      {super.key, required this.channel, required this.contextList});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final fav = appState.isFavorite(channel);
        final locked = appState.isLocked(channel);
        final progress = channel.nowProgress();
        return InkWell(
          onTap: () => playChannel(context, channel, contextList),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                      if (progress != null) ...[
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ],
                      const SizedBox(height: 3),
                      Text('Next: ${channel.nextProgramme()?.name ?? '—'}',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [ChannelsPage(), FavoritesPage(), SettingsPage()],
      ),
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
        return Scaffold(
          appBar: AppBar(
            title: const Text('Viu Live TV'),
            actions: [
              IconButton(
                icon: const Icon(Icons.search, size: 27),
                tooltip: 'Search',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SearchPage())),
              ),
              _castAppBarButton(context),
            ],
          ),
          body: Column(
            children: [
              if (appState.epgError != null && appState.all.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(appState.epgError!,
                              textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () => appState.loadEpg(),
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else ...[
                SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
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
                  child: appState.epgLoading && appState.all.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : channels.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  appState.languageFilter.isEmpty
                                      ? 'No channels in this category.'
                                      : 'No channels in this language here. Change it in Settings → Channel Language.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: () => appState.loadEpg(),
                              child: ListView.separated(
                                itemCount: channels.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1, indent: 84),
                                itemBuilder: (context, i) => ChannelRow(
                                  channel: channels[i],
                                  contextList: channels,
                                ),
                              ),
                            ),
                ),
              ],
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
              : ListView.separated(
                  itemCount: favs.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 84),
                  itemBuilder: (context, i) =>
                      ChannelRow(channel: favs[i], contextList: favs),
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
            .where((c) => c.name.toLowerCase().contains(q))
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
                hintText: 'Search channels',
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

  bool get _casting => castManager.connectedDeviceName != null;

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
      if (mounted && !_playing && !_casting && _error == null) {
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
      _player.pause();
    } else {
      _player.play();
    }
    _showOverlay();
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

  @override
  Widget build(BuildContext context) {
    final casting = _casting;
    final remotePlaying = castManager.remotePlayerState == 'PLAYING';
    return Scaffold(
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
                    _circleButton(Icons.list, _openGuide),
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
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
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
                  if (await _confirm(context, 'Clear Favorites?',
                      'This removes all favorites here and on the website.')) {
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
                  'Viu Live TV for Android 1.0.0\n'
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
