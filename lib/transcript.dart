// Trascrizione: dati (parole e frasi con tempi), salvataggio accanto al WAV,
// conversione audio per Whisper (16 kHz mono) e raggruppamento parole → frasi.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'wav_edit.dart';

class TWord {
  final int s, e; // millisecondi
  final String t;
  const TWord(this.s, this.e, this.t);
  Map<String, dynamic> toJson() => {'s': s, 'e': e, 't': t};
  factory TWord.fromJson(Map<String, dynamic> j) =>
      TWord(j['s'] as int, j['e'] as int, j['t'] as String);
}

class TLine {
  final List<TWord> words;
  const TLine(this.words);
  int get s => words.first.s;
  int get e => words.last.e;
  String get text => words.map((w) => w.t).join(' ');
  Map<String, dynamic> toJson() => {'w': words.map((w) => w.toJson()).toList()};
  factory TLine.fromJson(Map<String, dynamic> j) => TLine((j['w'] as List)
      .map((x) => TWord.fromJson(x as Map<String, dynamic>))
      .toList());
}

class Transcript {
  String lang; // codice lingua (es. "en"), "" se sconosciuta
  final String model;
  final List<TLine> lines;
  final Map<String, List<String>> translations; // lingua -> una per riga
  Transcript(this.lang, this.model, this.lines,
      [Map<String, List<String>>? tr])
      : translations = tr ?? {};

  String get text => lines.map((l) => l.text).join('\n');

  Map<String, dynamic> toJson() => {
        'v': 1,
        'lang': lang,
        'model': model,
        'lines': lines.map((l) => l.toJson()).toList(),
        'tr': translations,
      };

  factory Transcript.fromJson(Map<String, dynamic> j) => Transcript(
        j['lang'] as String? ?? '',
        j['model'] as String? ?? '',
        (j['lines'] as List)
            .map((x) => TLine.fromJson(x as Map<String, dynamic>))
            .toList(),
        ((j['tr'] as Map?) ?? {}).map((k, v) =>
            MapEntry(k as String, (v as List).map((e) => '$e').toList())),
      );

  /// Testo con i tempi, per condividere.
  String toPlainText() {
    final b = StringBuffer();
    for (final l in lines) {
      b.writeln('[${fmtMs(l.s)}] ${l.text}');
    }
    return b.toString();
  }
}

String fmtMs(int ms) {
  final h = ms ~/ 3600000, m = (ms ~/ 60000) % 60, s = (ms ~/ 1000) % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

// ---------------- file accanto alla registrazione ----------------

String transcriptPathFor(String wavPath) =>
    '${wavPath.substring(0, wavPath.length - 4)}.transcript.json';

Transcript? loadTranscript(String wavPath) {
  final f = File(transcriptPathFor(wavPath));
  if (!f.existsSync()) return null;
  try {
    return Transcript.fromJson(
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

void saveTranscript(String wavPath, Transcript t) =>
    File(transcriptPathFor(wavPath)).writeAsStringSync(jsonEncode(t.toJson()));

bool hasTranscript(String wavPath) =>
    File(transcriptPathFor(wavPath)).existsSync();

/// Sposta il testo insieme al file audio (rinomina).
void moveTranscript(String fromWav, String toWav) {
  final f = File(transcriptPathFor(fromWav));
  if (f.existsSync()) f.renameSync(transcriptPathFor(toWav));
}

void deleteTranscript(String wavPath) {
  final f = File(transcriptPathFor(wavPath));
  if (f.existsSync()) f.deleteSync();
}

// ---------------- parole → frasi ----------------

/// Un pezzo restituito da Whisper (una parola o una frase).
class RawSeg {
  final int s, e;
  final String text;
  const RawSeg(this.s, this.e, this.text);
}

final _noise = RegExp(r'^[\[\(♪*].*[\]\)♪*]$');
final _endSentence = RegExp(r'[.!?…。؟!]["»”)]*$');

/// Trasforma i pezzi di Whisper in frasi con parole e tempi.
List<TLine> buildLines(List<RawSeg> segs) {
  // 1) parole con tempi (se un pezzo contiene più parole, tempi proporzionali)
  final words = <TWord>[];
  for (final g in segs) {
    final t = g.text.trim();
    if (t.isEmpty || _noise.hasMatch(t)) continue;
    final parts = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (parts.length == 1) {
      words.add(TWord(g.s, max(g.s, g.e), parts.first));
      continue;
    }
    final total = parts.fold<int>(0, (a, w) => a + w.length + 1);
    var pos = 0;
    final dur = max(0, g.e - g.s);
    for (final w in parts) {
      final a = g.s + (dur * pos / total).round();
      pos += w.length + 1;
      final b = g.s + (dur * pos / total).round();
      words.add(TWord(a, b, w));
    }
  }
  // 2) raggruppa in frasi
  final lines = <TLine>[];
  var cur = <TWord>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (cur.isNotEmpty) {
      final gap = w.s - cur.last.e;
      final len = cur.last.e - cur.first.s;
      if (gap > 1500 || len > 12000) {
        lines.add(TLine(cur));
        cur = [];
      }
    }
    cur.add(w);
    final len = w.e - cur.first.s;
    if (_endSentence.hasMatch(w.t) ||
        (len > 7000 && w.t.endsWith(',')) ||
        cur.length >= 30) {
      lines.add(TLine(cur));
      cur = [];
    }
  }
  if (cur.isNotEmpty) lines.add(TLine(cur));
  return lines;
}

/// Indice della frase in corso al tempo [ms] (ricerca binaria).
int lineAt(List<TLine> lines, int ms) {
  if (lines.isEmpty) return -1;
  var lo = 0, hi = lines.length - 1, ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].s <= ms) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

/// Indice della parola in corso nella frase.
int wordAt(TLine l, int ms) {
  var ans = -1;
  for (var i = 0; i < l.words.length; i++) {
    if (l.words[i].s <= ms) ans = i;
  }
  return ans;
}

// ---------------- audio per Whisper ----------------

/// Converte il WAV (es. 48 kHz stereo) in 16 kHz mono 16 bit.
/// Da eseguire in un isolate. Restituisce i millisecondi di audio.
int convertTo16kMono(String src, String dst) {
  final info = readWavInfo(src);
  final input = File(src).openSync();
  input.setPositionSync(info.dataOffset);
  final out = File(dst).openSync(mode: FileMode.write);
  out.writeFromSync(Uint8List(44));
  final ch = info.channels;
  final ratio = info.rate / 16000;
  final intRatio = ratio.round();
  final integer = (ratio - intRatio).abs() < 1e-6 && intRatio >= 1;

  const framesPerChunk = 48000;
  final inBuf = Uint8List(framesPerChunk * ch * 2);
  var remaining = info.dataLen;
  var written = 0;
  // stato per il ricampionamento non intero
  double pos = 0; // posizione (in frame d'ingresso) del prossimo campione d'uscita
  int base = 0; // indice del primo frame del blocco corrente
  double? prev; // ultimo campione mono del blocco precedente
  final outList = <int>[];

  while (remaining > 0) {
    final got = input.readIntoSync(inBuf, 0, min(inBuf.length, remaining));
    if (got <= 0) break;
    remaining -= got;
    final s = inBuf.buffer.asInt16List(0, got ~/ 2);
    final frames = s.length ~/ ch;
    final mono = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      var sum = 0;
      for (var c = 0; c < ch; c++) {
        sum += s[f * ch + c];
      }
      mono[f] = sum / ch;
    }
    outList.clear();
    if (integer) {
      // media di [intRatio] campioni: filtro semplice anti-aliasing
      for (var f = 0; f + intRatio <= frames; f += intRatio) {
        var sum = 0.0;
        for (var k = 0; k < intRatio; k++) {
          sum += mono[f + k];
        }
        outList.add((sum / intRatio).round().clamp(-32768, 32767));
      }
    } else {
      while (pos < base + frames) {
        final idx = pos - base;
        final i0 = idx.floor();
        final frac = idx - i0;
        final a = i0 >= 0 ? mono[i0] : (prev ?? mono[0]);
        final b = i0 + 1 < frames ? mono[i0 + 1] : mono[frames - 1];
        outList.add((a + (b - a) * frac).round().clamp(-32768, 32767));
        pos += ratio;
      }
      prev = mono[frames - 1];
      base += frames;
    }
    final bytes = Int16List.fromList(outList).buffer.asUint8List();
    out.writeFromSync(bytes);
    written += bytes.length;
  }
  input.closeSync();
  out.setPositionSync(0);
  out.writeFromSync(wavHeader(written, 1, 16000));
  out.closeSync();
  return written ~/ 32; // 16000 campioni * 2 byte = 32 byte per ms
}

Future<int> convertInBackground(String src, String dst) =>
    Isolate.run(() => convertTo16kMono(src, dst));
