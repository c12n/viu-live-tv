// Channel language detection — a direct port of the iOS app's
// ChannelLanguage (v1.3.1), so both apps badge and filter identically.
//
// Layered heuristics, most specific first:
//   1. Script of the channel name (Arabic / Cyrillic / Hangul / …).
//   2. Well-known networks whose language the name alone implies.
//   3. Explicit language words in the name or tags.
//   4. Country — the "| XXX" name suffix first, then any country token.
//   5. Residual default: English (the bulk of the plain-Latin lineup).

import 'api.dart';

class LangInfo {
  final String code;
  final String label;
  const LangInfo(this.code, this.label);
}

class LanguageOption {
  final String code;
  final String label;
  final int count;
  const LanguageOption(this.code, this.label, this.count);
}

LangInfo detectChannelLanguage(String name, List<String> tags) {
  // 1. Script of the name.
  var hasKana = false;
  var hasHan = false;
  for (final v in name.runes) {
    if ((v >= 0x0600 && v <= 0x06FF) ||
        (v >= 0x0750 && v <= 0x077F) ||
        (v >= 0x08A0 && v <= 0x08FF) ||
        (v >= 0xFB50 && v <= 0xFDFF) ||
        (v >= 0xFE70 && v <= 0xFEFF)) {
      return const LangInfo('ar', 'Arabic');
    }
    if (v >= 0x0590 && v <= 0x05FF) return const LangInfo('he', 'Hebrew');
    if (v >= 0x0400 && v <= 0x04FF) return const LangInfo('ru', 'Russian');
    if (v >= 0x0370 && v <= 0x03FF) return const LangInfo('el', 'Greek');
    if ((v >= 0xAC00 && v <= 0xD7AF) ||
        (v >= 0x1100 && v <= 0x11FF) ||
        (v >= 0x3130 && v <= 0x318F)) {
      return const LangInfo('ko', 'Korean');
    }
    if (v >= 0x3040 && v <= 0x30FF) hasKana = true;
    if (v >= 0x4E00 && v <= 0x9FFF) hasHan = true;
    if (v >= 0x0E00 && v <= 0x0E7F) return const LangInfo('th', 'Thai');
    if (v >= 0x0900 && v <= 0x097F) return const LangInfo('hi', 'Hindi');
    if (v >= 0x0530 && v <= 0x058F) return const LangInfo('hy', 'Armenian');
    if (v >= 0x10A0 && v <= 0x10FF) return const LangInfo('ka', 'Georgian');
  }
  if (hasKana) return const LangInfo('ja', 'Japanese');
  if (hasHan) return const LangInfo('zh', 'Chinese');

  final upperName = name.toUpperCase();
  final haystack = '$upperName ${tags.join(' ').toUpperCase()}'
      .replaceAll(',', ' ')
      .replaceAll('_', ' ');

  // 2. Well-known networks whose language the name alone implies.
  const knownNetworks = <String, LangInfo>{
    'RDS': LangInfo('fr', 'French'),
    'TVA': LangInfo('fr', 'French'),
    'UNIVISION': LangInfo('es', 'Spanish'),
    'TELEMUNDO': LangInfo('es', 'Spanish'),
    'AZTECA': LangInfo('es', 'Spanish'),
    'GLOBO': LangInfo('pt', 'Portuguese'),
    'RAI': LangInfo('it', 'Italian'),
    'ZDF': LangInfo('de', 'German'),
    'TRT': LangInfo('tr', 'Turkish'),
    'CCTV': LangInfo('zh', 'Chinese'),
    'NHK': LangInfo('ja', 'Japanese'),
  };
  for (final e in knownNetworks.entries) {
    final token = e.key;
    if (upperName == token ||
        upperName.startsWith('$token ') ||
        upperName.startsWith('$token|') ||
        upperName.contains('| $token')) {
      return e.value;
    }
  }

  // 3. Explicit language words.
  const languageWords = <String, LangInfo>{
    'SPANISH': LangInfo('es', 'Spanish'),
    'ESPANOL': LangInfo('es', 'Spanish'),
    'ESPAÑOL': LangInfo('es', 'Spanish'),
    'FRENCH': LangInfo('fr', 'French'),
    'FRANCAIS': LangInfo('fr', 'French'),
    'FRANÇAIS': LangInfo('fr', 'French'),
    'ARABIC': LangInfo('ar', 'Arabic'),
    'GERMAN': LangInfo('de', 'German'),
    'DEUTSCH': LangInfo('de', 'German'),
    'PORTUGUESE': LangInfo('pt', 'Portuguese'),
    'PORTUGUES': LangInfo('pt', 'Portuguese'),
    'ITALIAN': LangInfo('it', 'Italian'),
    'ITALIANO': LangInfo('it', 'Italian'),
    'RUSSIAN': LangInfo('ru', 'Russian'),
    'TURKISH': LangInfo('tr', 'Turkish'),
    'POLISH': LangInfo('pl', 'Polish'),
    'POLSKI': LangInfo('pl', 'Polish'),
    'DUTCH': LangInfo('nl', 'Dutch'),
    'NEDERLANDS': LangInfo('nl', 'Dutch'),
    'HINDI': LangInfo('hi', 'Hindi'),
    'URDU': LangInfo('ur', 'Urdu'),
    'FARSI': LangInfo('fa', 'Persian'),
    'PERSIAN': LangInfo('fa', 'Persian'),
    'KOREAN': LangInfo('ko', 'Korean'),
    'CHINESE': LangInfo('zh', 'Chinese'),
    'MANDARIN': LangInfo('zh', 'Chinese'),
    'CANTONESE': LangInfo('zh', 'Chinese'),
    'JAPANESE': LangInfo('ja', 'Japanese'),
    'VIETNAMESE': LangInfo('vi', 'Vietnamese'),
    'INDONESIAN': LangInfo('id', 'Indonesian'),
    'FILIPINO': LangInfo('ph', 'Filipino'),
    'TAGALOG': LangInfo('ph', 'Filipino'),
    'SWEDISH': LangInfo('sv', 'Swedish'),
    'NORWEGIAN': LangInfo('no', 'Norwegian'),
    'DANISH': LangInfo('da', 'Danish'),
    'FINNISH': LangInfo('fi', 'Finnish'),
    'GREEK': LangInfo('el', 'Greek'),
    'HEBREW': LangInfo('he', 'Hebrew'),
    'ROMANIAN': LangInfo('ro', 'Romanian'),
    'BULGARIAN': LangInfo('bg', 'Bulgarian'),
    'SERBIAN': LangInfo('sr', 'Serbian'),
    'CROATIAN': LangInfo('hr', 'Croatian'),
    'CZECH': LangInfo('cs', 'Czech'),
    'SLOVAK': LangInfo('sk', 'Slovak'),
    'HUNGARIAN': LangInfo('hu', 'Hungarian'),
    'UKRAINIAN': LangInfo('uk', 'Ukrainian'),
    'ALBANIAN': LangInfo('sq', 'Albanian'),
    'THAI': LangInfo('th', 'Thai'),
    'ENGLISH': LangInfo('en', 'English'),
  };
  for (final e in languageWords.entries) {
    if (haystack.contains(e.key)) return e.value;
  }

  // 4. Country: "| XXX" suffix first, then any country token.
  const countries = <String, LangInfo>{
    'USA': LangInfo('en', 'English'),
    'UNITED STATES': LangInfo('en', 'English'),
    'UK': LangInfo('en', 'English'),
    'UNITED KINGDOM': LangInfo('en', 'English'),
    'CANADA': LangInfo('en', 'English'),
    'AUSTRALIA': LangInfo('en', 'English'),
    'IRELAND': LangInfo('en', 'English'),
    'NEW ZEALAND': LangInfo('en', 'English'),
    'FRANCE': LangInfo('fr', 'French'),
    'SPAIN': LangInfo('es', 'Spanish'),
    'MEXICO': LangInfo('es', 'Spanish'),
    'ARGENTINA': LangInfo('es', 'Spanish'),
    'COLOMBIA': LangInfo('es', 'Spanish'),
    'CHILE': LangInfo('es', 'Spanish'),
    'PERU': LangInfo('es', 'Spanish'),
    'VENEZUELA': LangInfo('es', 'Spanish'),
    'GERMANY': LangInfo('de', 'German'),
    'AUSTRIA': LangInfo('de', 'German'),
    'SWITZERLAND': LangInfo('de', 'German'),
    'BRAZIL': LangInfo('pt', 'Portuguese'),
    'BRASIL': LangInfo('pt', 'Portuguese'),
    'PORTUGAL': LangInfo('pt', 'Portuguese'),
    'ITALY': LangInfo('it', 'Italian'),
    'ITALIA': LangInfo('it', 'Italian'),
    'TURKEY': LangInfo('tr', 'Turkish'),
    'TÜRKIYE': LangInfo('tr', 'Turkish'),
    'POLAND': LangInfo('pl', 'Polish'),
    'POLSKA': LangInfo('pl', 'Polish'),
    'NETHERLANDS': LangInfo('nl', 'Dutch'),
    'HOLLAND': LangInfo('nl', 'Dutch'),
    'BELGIUM': LangInfo('nl', 'Dutch'),
    'INDIA': LangInfo('hi', 'Hindi'),
    'PAKISTAN': LangInfo('ur', 'Urdu'),
    'KOREA': LangInfo('ko', 'Korean'),
    'JAPAN': LangInfo('ja', 'Japanese'),
    'CHINA': LangInfo('zh', 'Chinese'),
    'TAIWAN': LangInfo('zh', 'Chinese'),
    'HONG KONG': LangInfo('zh', 'Chinese'),
    'EGYPT': LangInfo('ar', 'Arabic'),
    'SAUDI': LangInfo('ar', 'Arabic'),
    'UAE': LangInfo('ar', 'Arabic'),
    'EMIRATES': LangInfo('ar', 'Arabic'),
    'MOROCCO': LangInfo('ar', 'Arabic'),
    'ALGERIA': LangInfo('ar', 'Arabic'),
    'LEBANON': LangInfo('ar', 'Arabic'),
    'IRAQ': LangInfo('ar', 'Arabic'),
    'JORDAN': LangInfo('ar', 'Arabic'),
    'KUWAIT': LangInfo('ar', 'Arabic'),
    'QATAR': LangInfo('ar', 'Arabic'),
    'SYRIA': LangInfo('ar', 'Arabic'),
    'TUNISIA': LangInfo('ar', 'Arabic'),
    'LIBYA': LangInfo('ar', 'Arabic'),
    'YEMEN': LangInfo('ar', 'Arabic'),
    'OMAN': LangInfo('ar', 'Arabic'),
    'BAHRAIN': LangInfo('ar', 'Arabic'),
    'PALESTINE': LangInfo('ar', 'Arabic'),
    'RUSSIA': LangInfo('ru', 'Russian'),
    'UKRAINE': LangInfo('uk', 'Ukrainian'),
    'GREECE': LangInfo('el', 'Greek'),
    'ISRAEL': LangInfo('he', 'Hebrew'),
    'SWEDEN': LangInfo('sv', 'Swedish'),
    'NORWAY': LangInfo('no', 'Norwegian'),
    'DENMARK': LangInfo('da', 'Danish'),
    'FINLAND': LangInfo('fi', 'Finnish'),
    'PHILIPPINES': LangInfo('ph', 'Filipino'),
    'VIETNAM': LangInfo('vi', 'Vietnamese'),
    'INDONESIA': LangInfo('id', 'Indonesian'),
    'THAILAND': LangInfo('th', 'Thai'),
    'ROMANIA': LangInfo('ro', 'Romanian'),
    'BULGARIA': LangInfo('bg', 'Bulgarian'),
    'SERBIA': LangInfo('sr', 'Serbian'),
    'CROATIA': LangInfo('hr', 'Croatian'),
    'CZECH': LangInfo('cs', 'Czech'),
    'HUNGARY': LangInfo('hu', 'Hungarian'),
    'ALBANIA': LangInfo('sq', 'Albanian'),
    'IRAN': LangInfo('fa', 'Persian'),
  };
  final pipe = upperName.lastIndexOf('|');
  if (pipe >= 0) {
    final suffix = upperName.substring(pipe + 1).trim();
    for (final e in countries.entries) {
      if (suffix == e.key || suffix.startsWith('${e.key} ')) return e.value;
    }
  }
  for (final e in countries.entries) {
    if (haystack.contains(e.key)) return e.value;
  }

  // 5. Residual default.
  return const LangInfo('en', 'English');
}

extension EPGChannelLanguage on EPGChannel {
  LangInfo get language => detectChannelLanguage(name, tags);
}

/// Languages present in the lineup, with counts — most channels first,
/// then alphabetical. Powers Settings → Channel Language.
List<LanguageOption> availableLanguages(List<EPGChannel> channels) {
  final counts = <String, int>{};
  final labels = <String, String>{};
  for (final c in channels) {
    final lang = c.language;
    counts[lang.code] = (counts[lang.code] ?? 0) + 1;
    labels[lang.code] = lang.label;
  }
  final options = [
    for (final e in counts.entries)
      LanguageOption(e.key, labels[e.key]!, e.value),
  ];
  options.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.label.compareTo(b.label);
  });
  return options;
}
