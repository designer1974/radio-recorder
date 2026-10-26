// Motore di modifica WAV: legge le informazioni, calcola la forma d'onda,
// gestisce i tagli come elenco di "pezzi" del file originale e
// scrive il risultato unendo i pezzi con una micro-dissolvenza (niente "click").
//
// Unità di base: il "blocco" = 10 ms di audio (rate/100 frame).

import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

class WavInfo {
  final int channels;
  final int rate;
  final int dataOffset;
  final int dataLen;
  WavInfo(this.channels, this.rate, this.dataOffset, this.dataLen);

  int get frameBytes => channels * 2;
  int get blockFrames => max(1, rate ~/ 100);
  int get blockBytes => blockFrames * frameBytes;
  int get blocks => (dataLen + blockBytes - 1) ~/ blockBytes;
  double get blockMs => blockFrames * 1000 / rate;
}

WavInfo readWavInfo(String path) {
  final raf = File(path).openSync();
  final len = raf.lengthSync();
  final head = raf.readSync(min(len, 1 << 16));
  raf.closeSync();
  final bd = ByteData.sublistView(head);
  String id(int o) => String.fromCharCodes(head.sublist(o, o + 4));
  var ch = 2, rate = 48000, off = 44, dlen = max(0, len - 44);
  if (head.length >= 12 && id(0) == 'RIFF' && id(8) == 'WAVE') {
    var p = 12;
    while (p + 8 <= head.length) {
      final cid = id(p);
      final size = bd.getUint32(p + 4, Endian.little);
      if (cid == 'fmt ' && p + 16 <= head.length) {
        ch = bd.getUint16(p + 10, Endian.little);
        rate = bd.getUint32(p + 12, Endian.little);
      } else if (cid == 'data') {
        off = p + 8;
        dlen = min(size, len - off);
        if (dlen <= 0) dlen = len - off; // intestazione non aggiornata
        break;
      }
      p += 8 + size + (size & 1);
    }
  }
  if (ch < 1) ch = 1;
  if (rate < 1000) rate = 48000;
  dlen -= dlen % (ch * 2);
  return WavInfo(ch, rate, off, max(0, dlen));
}

/// Picco (0..255) di ogni blocco da 10 ms. Da eseguire in un isolate.
Uint8List computePeaks(String path) {
  final info = readWavInfo(path);
  final n = info.blocks;
  final out = Uint8List(n);
  if (n == 0) return out;
  final raf = File(path).openSync();
  raf.setPositionSync(info.dataOffset);
  final bb = info.blockBytes;
  final buf = Uint8List(bb * 2000);
  var remaining = info.dataLen;
  var b = 0;
  final spb = bb ~/ 2;
  while (remaining > 0 && b < n) {
    final got = raf.readIntoSync(buf, 0, min(buf.length, remaining));
    if (got <= 0) break;
    remaining -= got;
    final samples = buf.buffer.asInt16List(0, got ~/ 2);
    for (var i = 0; i < samples.length && b < n; i += spb) {
      var m = 0;
      final e = min(i + spb, samples.length);
      for (var j = i; j < e; j++) {
        final v = samples[j];
        final a = v < 0 ? -v : v;
        if (a > m) m = a;
      }
      out[b++] = min(255, m >> 7);
    }
  }
  raf.closeSync();
  return out;
}

/// Un pezzo del file originale: blocchi [a, b).
class Seg {
  final int a, b;
  const Seg(this.a, this.b);
  int get len => b - a;
  @override
  bool operator ==(Object o) => o is Seg && o.a == a && o.b == b;
  @override
  int get hashCode => Object.hash(a, b);
  @override
  String toString() => '[$a,$b)';
}

int totalLen(List<Seg> segs) => segs.fold(0, (s, g) => s + g.len);

/// Parte della timeline modificata [from, to) come pezzi dell'originale.
List<Seg> slice(List<Seg> segs, int from, int to) {
  final out = <Seg>[];
  var pos = 0;
  for (final g in segs) {
    final s = pos, e = pos + g.len;
    final a = max(s, from), b = min(e, to);
    if (a < b) out.add(Seg(g.a + a - s, g.a + b - s));
    pos = e;
    if (pos >= to) break;
  }
  return out;
}

/// Unisce pezzi contigui.
List<Seg> normalize(List<Seg> segs) {
  final out = <Seg>[];
  for (final g in segs) {
    if (g.len <= 0) continue;
    if (out.isNotEmpty && out.last.b == g.a) {
      out[out.length - 1] = Seg(out.last.a, g.b);
    } else {
      out.add(g);
    }
  }
  return out;
}

/// Toglie [from, to) e unisce le due parti.
List<Seg> cut(List<Seg> segs, int from, int to) =>
    normalize([...slice(segs, 0, from), ...slice(segs, to, totalLen(segs))]);

/// Tiene solo [from, to).
List<Seg> keep(List<Seg> segs, int from, int to) =>
    normalize(slice(segs, from, to));

/// Posizioni (nella timeline modificata) dove due pezzi sono stati uniti.
List<int> joins(List<Seg> segs) {
  final out = <int>[];
  var pos = 0;
  for (var i = 0; i < segs.length - 1; i++) {
    pos += segs[i].len;
    out.add(pos);
  }
  return out;
}

/// Forma d'onda della timeline modificata.
Uint8List editedPeaks(Uint8List peaks, List<Seg> segs) {
  final out = Uint8List(totalLen(segs));
  var p = 0;
  for (final g in segs) {
    out.setRange(p, p + g.len, peaks, g.a);
    p += g.len;
  }
  return out;
}

Uint8List wavHeader(int dataLen, int channels, int rate) {
  final h = ByteData(44);
  void str(int o, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  h.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, channels, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * channels * 2, Endian.little);
  h.setUint16(32, channels * 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  str(36, 'data');
  h.setUint32(40, dataLen, Endian.little);
  return h.buffer.asUint8List();
}

/// Scrive in [dst] i pezzi [segs] di [src], uniti con dissolvenza di 5 ms.
/// Da eseguire in un isolate. Restituisce i byte audio scritti.
int renderSegments(String src, List<Seg> segs, String dst) {
  final info = readWavInfo(src);
  final bb = info.blockBytes;
  final input = File(src).openSync();
  final out = File(dst).openSync(mode: FileMode.write);
  out.writeFromSync(Uint8List(44));
  final buf = Uint8List(1 << 20);
  var total = 0;
  final joinPos = <int>[];
  for (var i = 0; i < segs.length; i++) {
    final g = segs[i];
    final start = g.a * bb;
    final end = min(g.b * bb, info.dataLen);
    if (i > 0) joinPos.add(total);
    var pos = start;
    input.setPositionSync(info.dataOffset + pos);
    while (pos < end) {
      final r = input.readIntoSync(buf, 0, min(buf.length, end - pos));
      if (r <= 0) break;
      out.writeFromSync(buf, 0, r);
      pos += r;
      total += r;
    }
  }
  input.closeSync();

  // Micro-dissolvenza sui punti di unione per evitare il "click".
  final fadeFrames = max(1, info.rate ~/ 200);
  final fb = fadeFrames * info.frameBytes;
  for (final j in joinPos) {
    final a = max(0, j - fb), b = min(total, j + fb);
    if (b - a < info.frameBytes * 2) continue;
    out.setPositionSync(44 + a);
    final chunk = out.readSync(b - a);
    final s = chunk.buffer.asInt16List(0, chunk.length ~/ 2);
    final ch = info.channels;
    final framesBefore = (j - a) ~/ info.frameBytes;
    final framesAfter = (b - j) ~/ info.frameBytes;
    for (var f = 0; f < framesBefore; f++) {
      final gain = (framesBefore - f) / framesBefore; // 1 -> 0
      for (var c = 0; c < ch; c++) {
        final k = f * ch + c;
        s[k] = (s[k] * gain).round();
      }
    }
    for (var f = 0; f < framesAfter; f++) {
      final gain = (f + 1) / framesAfter; // 0 -> 1
      for (var c = 0; c < ch; c++) {
        final k = (framesBefore + f) * ch + c;
        if (k < s.length) s[k] = (s[k] * gain).round();
      }
    }
    out.setPositionSync(44 + a);
    out.writeFromSync(chunk);
  }

  out.setPositionSync(0);
  out.writeFromSync(wavHeader(total, info.channels, info.rate));
  out.closeSync();
  return total;
}

// Funzioni di livello superiore per lavorare in un isolate separato
// (così la closure non trascina con sé lo stato della schermata).
Future<Uint8List> peaksInBackground(String path) =>
    Isolate.run(() => computePeaks(path));

Future<int> renderInBackground(String src, List<Seg> segs, String dst) {
  final copy = List<Seg>.of(segs);
  return Isolate.run(() => renderSegments(src, copy, dst));
}
