import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ponte verso il codice nativo Android (Kotlin) che registra l'audio.
class Recorder {
  static const _ch = MethodChannel('rr/recorder');

  /// Chiamato quando la registrazione si ferma dal sistema
  /// (es. l'utente revoca il permesso dalla notifica).
  static void setOnStopped(void Function() cb) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'stopped') cb();
    });
  }

  static Future<void> start({
    required String path,
    required bool internal,
    required bool noise,
  }) =>
      _ch.invokeMethod('start', {
        'path': path,
        'internal': internal,
        'noise': noise,
      });

  static Future<void> stop() => _ch.invokeMethod('stop');

  /// Livello del suono in questo momento (0..1).
  static Future<double> level() async =>
      (await _ch.invokeMethod<double>('level')) ?? 0;

  static Future<bool> isRecording() async =>
      (await _ch.invokeMethod<bool>('isRecording')) ?? false;
}

/// Impostazioni salvate sul telefono.
class AppSettings {
  bool internal = true; // true = audio interno, false = microfono
  bool noise = false; // riduzione rumore
  bool autoFlag = true; // aggiunge la bandiera in automatico

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings()
      ..internal = p.getBool('internal') ?? true
      ..noise = p.getBool('noise') ?? false
      ..autoFlag = p.getBool('autoFlag') ?? true;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('internal', internal);
    await p.setBool('noise', noise);
    await p.setBool('autoFlag', autoFlag);
  }
}
