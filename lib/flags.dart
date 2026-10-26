// Riconoscimento del paese dal titolo e creazione dell'emoji bandiera.

/// Trasforma un codice paese (es. "IT") nell'emoji bandiera (🇮🇹).
String flagFromCode(String code) {
  final c = code.toUpperCase();
  return String.fromCharCodes([
    0x1F1E6 + c.codeUnitAt(0) - 65,
    0x1F1E6 + c.codeUnitAt(1) - 65,
  ]);
}

/// Parole chiave (minuscole) -> codice paese.
const Map<String, String> _keywords = {
  // Stati Uniti
  'usa': 'US', 'us': 'US', 'america': 'US', 'american': 'US',
  'americano': 'US', 'americana': 'US', 'stati uniti': 'US',
  'united states': 'US', 'fox': 'US', 'cnn': 'US', 'npr': 'US',
  'nbc': 'US', 'abc news': 'US', 'bloomberg': 'US', 'new york': 'US',
  // Regno Unito
  'uk': 'GB', 'england': 'GB', 'inghilterra': 'GB', 'inglese': 'GB',
  'english': 'GB', 'british': 'GB', 'britain': 'GB', 'bbc': 'GB',
  'london': 'GB', 'londra': 'GB', 'lbc': 'GB',
  // Italia
  'italia': 'IT', 'italy': 'IT', 'italiano': 'IT', 'italiana': 'IT',
  'rai': 'IT', 'radio24': 'IT', 'rtl': 'IT', 'roma': 'IT', 'milano': 'IT',
  // Marocco
  'marocco': 'MA', 'morocco': 'MA', 'maroc': 'MA', 'marocchino': 'MA',
  'medi1': 'MA', 'medi 1': 'MA', '2m': 'MA', 'hit radio': 'MA',
  'rabat': 'MA', 'casablanca': 'MA', 'المغرب': 'MA', 'مغربي': 'MA',
  // Francia
  'francia': 'FR', 'france': 'FR', 'français': 'FR', 'francais': 'FR',
  'francese': 'FR', 'rfi': 'FR', 'paris': 'FR', 'parigi': 'FR',
  // Spagna
  'spagna': 'ES', 'spain': 'ES', 'españa': 'ES', 'espana': 'ES',
  'spagnolo': 'ES', 'español': 'ES', 'cadena ser': 'ES', 'madrid': 'ES',
  // Germania
  'germania': 'DE', 'germany': 'DE', 'deutschland': 'DE', 'tedesco': 'DE',
  'deutsch': 'DE', 'berlin': 'DE', 'berlino': 'DE',
  // Mondo arabo
  'egitto': 'EG', 'egypt': 'EG', 'مصر': 'EG',
  'arabia': 'SA', 'saudi': 'SA', 'السعودية': 'SA',
  'qatar': 'QA', 'al jazeera': 'QA', 'aljazeera': 'QA', 'jazeera': 'QA',
  'الجزيرة': 'QA',
  'algeria': 'DZ', 'algérie': 'DZ', 'الجزائر': 'DZ',
  'tunisia': 'TN', 'tunisie': 'TN', 'تونس': 'TN',
  'emirati': 'AE', 'uae': 'AE', 'dubai': 'AE',
  // Altri
  'turchia': 'TR', 'turkey': 'TR', 'türkiye': 'TR', 'turco': 'TR',
  'cina': 'CN', 'china': 'CN', 'cinese': 'CN',
  'giappone': 'JP', 'japan': 'JP', 'giapponese': 'JP',
  'india': 'IN', 'brasile': 'BR', 'brazil': 'BR', 'brasil': 'BR',
  'canada': 'CA', 'australia': 'AU', 'russia': 'RU',
  'portogallo': 'PT', 'portugal': 'PT', 'olanda': 'NL',
  'netherlands': 'NL', 'svizzera': 'CH', 'switzerland': 'CH',
};

/// Bandiere suggerite per un titolo, nell'ordine in cui compaiono.
List<String> detectFlags(String text) {
  final t = ' ${text.toLowerCase()} ';
  final tokens = t
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((s) => s.isNotEmpty)
      .toSet();
  final found = <String, int>{}; // codice -> posizione
  _keywords.forEach((key, code) {
    final match = key.contains(' ') ? t.contains(key) : tokens.contains(key);
    if (match) {
      final pos = t.indexOf(key);
      if (!found.containsKey(code) || pos < found[code]!) found[code] = pos;
    }
  });
  final codes = found.keys.toList()
    ..sort((a, b) => found[a]!.compareTo(found[b]!));
  return codes.map(flagFromCode).toList();
}

/// Tutte le bandiere conosciute (per la scelta manuale).
List<String> allFlags() {
  final codes = _keywords.values.toSet().toList()..sort();
  return codes.map(flagFromCode).toList();
}

bool _isRegional(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;

/// Se il nome inizia con una bandiera, la restituisce.
String? leadingFlag(String s) {
  final r = s.runes.toList();
  if (r.length >= 2 && _isRegional(r[0]) && _isRegional(r[1])) {
    return String.fromCharCodes(r.sublist(0, 2));
  }
  return null;
}

/// Il nome senza la bandiera iniziale.
String stripFlag(String s) {
  final f = leadingFlag(s);
  return f == null ? s.trim() : s.substring(f.length).trim();
}
