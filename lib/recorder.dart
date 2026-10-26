import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Qualità / formato di registrazione.
enum AudioQuality { voice, medium, minimum, high, wav }

extension AudioQualityX on AudioQuality {
  int get bitrate => switch (this) {
        AudioQuality.voice => 32000,
        AudioQuality.medium => 64000,
        AudioQuality.minimum => 24000,
        AudioQuality.high => 128000,
        AudioQuality.wav => 0,
      };
  int get outCh => this == AudioQuality.minimum ? 1 : 2;
  bool get he => this != AudioQuality.high;
  String get ext => this == AudioQuality.wav ? 'wav' : 'm4a';
  String get label => switch (this) {
        AudioQuality.voice => 'Voce',
        AudioQuality.medium => 'Media',
        AudioQuality.minimum => 'Minima',
        AudioQuality.high => 'Alta',
        AudioQuality.wav => 'WAV senza compressione',
      };
  String get info => switch (this) {
        AudioQuality.voice => '32 kbps · ~14 MB all\'ora · radio parlata, notizie',
        AudioQuality.medium => '64 kbps · ~28 MB all\'ora · voce e musica',
        AudioQuality.minimum => '24 kbps mono · ~10 MB all\'ora · solo parlato',
        AudioQuality.high => '128 kbps · ~56 MB all\'ora · musica',
        AudioQuality.wav => '~690 MB all\'ora · solo per uso professionale',
      };
}

/// Ponte verso il codice nativo Android (Kotlin) che registra l'audio.
class Recorder {
  static const _ch = MethodChannel('rr/recorder');
  static void Function()? _onStopped;
  static void Function(double)? onProgress;

  /// Chiamato quando la registrazione si ferma dal sistema
  /// (es. l'utente revoca il permesso dalla notifica).
  static void setOnStopped(void Function() cb) {
    _onStopped = cb;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'stopped') _onStopped?.call();
      if (call.method == 'progress') {
        onProgress?.call((call.arguments as num).toDouble());
      }
    });
  }

  static Future<void> start({
    required String path,
    required bool internal,
    required bool noise,
    required AudioQuality quality,
  }) =>
      _ch.invokeMethod('start', {
        'path': path,
        'internal': internal,
        'noise': noise,
        'bitrate': quality.bitrate,
        'outCh': quality.outCh,
        'he': quality.he,
      });

  static Future<void> stop() => _ch.invokeMethod('stop');

  /// Livello del suono in questo momento (0..1).
  static Future<double> level() async =>
      (await _ch.invokeMethod<double>('level')) ?? 0;

  static Future<bool> isRecording() async =>
      (await _ch.invokeMethod<bool>('isRecording')) ?? false;

  /// Durata di un file audio in millisecondi.
  static Future<int> durationMs(String path) async =>
      (await _ch.invokeMethod<int>('duration', {'path': path})) ?? 0;

  /// Comprime un WAV in M4A.
  static Future<void> toM4a(String src, String dst, AudioQuality q,
      {void Function(double)? progress}) async {
    onProgress = progress;
    try {
      await _ch.invokeMethod('toM4a', {
        'src': src,
        'dst': dst,
        'bitrate': q.bitrate == 0 ? AudioQuality.voice.bitrate : q.bitrate,
        'outCh': q.outCh,
        'he': q.he,
      });
    } finally {
      onProgress = null;
    }
  }

  /// Decodifica un M4A in WAV (per modificare o trascrivere).
  static Future<void> toWav(String src, String dst,
      {void Function(double)? progress}) async {
    onProgress = progress;
    try {
      await _ch.invokeMethod('toWav', {'src': src, 'dst': dst});
    } finally {
      onProgress = null;
    }
  }
}

bool isCompressed(String path) => !path.toLowerCase().endsWith('.wav');

/// Impostazioni salvate sul telefono.
class AppSettings {
  bool internal = true; // true = audio interno, false = microfono
  bool noise = false; // riduzione rumore
  bool autoFlag = true; // aggiunge la bandiera in automatico
  AudioQuality quality = AudioQuality.voice;

  /// Qualità usata per comprimere (se il formato scelto è WAV, usa Voce).
  AudioQuality get compressQuality =>
      quality == AudioQuality.wav ? AudioQuality.voice : quality;

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final q = p.getString('quality');
    return AppSettings()
      ..internal = p.getBool('internal') ?? true
      ..noise = p.getBool('noise') ?? false
      ..autoFlag = p.getBool('autoFlag') ?? true
      ..quality = AudioQuality.values
          .firstWhere((x) => x.name == q, orElse: () => AudioQuality.voice);
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('internal', internal);
    await p.setBool('noise', noise);
    await p.setBool('autoFlag', autoFlag);
    await p.setString('quality', quality.name);
  }
}
