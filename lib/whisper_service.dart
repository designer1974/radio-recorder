// Whisper sul telefono: scarica il modello (una volta) e trascrive.

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'transcript.dart';

enum Quality { fast, balanced, precise }

extension QualityX on Quality {
  WhisperModel get model => switch (this) {
        Quality.fast => WhisperModel.tiny,
        Quality.balanced => WhisperModel.base,
        Quality.precise => WhisperModel.small,
      };
  String get label => switch (this) {
        Quality.fast => 'Veloce',
        Quality.balanced => 'Bilanciato',
        Quality.precise => 'Preciso',
      };
  String get size => switch (this) {
        Quality.fast => '75 MB',
        Quality.balanced => '142 MB',
        Quality.precise => '466 MB',
      };
}

typedef Stage = void Function(String stage, double? progress);

class WhisperService {
  final _ctrl = WhisperController();

  Future<String> modelPath(Quality q) => _ctrl.getPath(q.model);

  Future<bool> hasModel(Quality q) async => File(await modelPath(q)).existsSync();

  Future<void> deleteModel(Quality q) async {
    final f = File(await modelPath(q));
    if (f.existsSync()) await f.delete();
  }

  /// Scarica in streaming (con avanzamento) e salva dove la libreria lo cerca.
  Future<void> _download(Uri url, String path, Stage onStage, String label) async {
    final tmp = File('$path.part');
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('download non riuscito (${res.statusCode})');
      }
      final total = res.contentLength;
      var got = 0;
      final sink = tmp.openWrite();
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onStage(label, got / total);
      }
      await sink.close();
      await tmp.rename(path);
    } catch (e) {
      if (tmp.existsSync()) await tmp.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> ensureModel(Quality q, Stage onStage) async {
    final path = await modelPath(q);
    if (File(path).existsSync()) return;
    await Directory(File(path).parent.path).create(recursive: true);
    await _download(q.model.modelUri, path, onStage,
        'Scarico il modello ${q.label} (${q.size}, solo la prima volta)…');
  }

  /// Rilevatore di voce (Silero, < 1 MB): toglie silenzi e musica,
  /// riduce gli errori. Se non si scarica, si continua senza.
  Future<String?> _vad(Stage onStage) async {
    try {
      final dir = await WhisperController.getModelDir();
      final path = '$dir/ggml-silero-v5.1.2.bin';
      if (File(path).existsSync()) return path;
      await _download(
          Uri.parse(
              'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin'),
          path,
          onStage,
          'Scarico il rilevatore di voce…');
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Trascrive [wavPath]. [lang] = "auto" o codice lingua.
  Future<Transcript> transcribe(
    String wavPath, {
    required Quality quality,
    required String lang,
    required Stage onStage,
  }) async {
    await ensureModel(quality, onStage);
    final vad = await _vad(onStage);

    onStage('Preparo l\'audio…', null);
    final cache = await getTemporaryDirectory();
    final tmp = '${cache.path}/whisper_input.wav';
    await convertInBackground(wavPath, tmp);

    onStage('Trascrivo… 0%', 0);
    TranscribeResult? res;
    Future<TranscribeResult?> run(String? vadPath) => _ctrl.transcribe(
          model: quality.model,
          audioPath: tmp,
          lang: lang,
          withSegments: true,
          splitOnWord: true,
          suppressNonSpeechTokens: true,
          vadModelPath: vadPath,
          vadSpeechPadMs: vadPath == null ? null : 200,
          onProgress: (p) => onStage('Trascrivo… $p%', p / 100),
        );
    res = await run(vad);
    if (res == null && vad != null) res = await run(null); // riprova senza VAD

    for (final f in [tmp, '$tmp.wav']) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
    if (res == null) {
      throw Exception('Trascrizione non riuscita');
    }
    final segs = (res.transcription.segments ?? [])
        .map((s) => RawSeg(
            s.fromTs.inMilliseconds, s.toTs.inMilliseconds, s.text))
        .toList();
    var lines = buildLines(segs);
    if (lines.isEmpty && res.transcription.text.trim().isNotEmpty) {
      lines = buildLines([RawSeg(0, 0, res.transcription.text)]);
    }
    return Transcript(lang == 'auto' ? '' : lang, quality.name, lines);
  }
}
