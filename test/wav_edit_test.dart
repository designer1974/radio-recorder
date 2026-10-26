import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_recorder/flags.dart';
import 'package:radio_recorder/wav_edit.dart';

/// Crea un WAV stereo 48 kHz dove ogni blocco da 10 ms ha valore = indice blocco.
String makeWav(Directory dir, int blocks) {
  const ch = 2, rate = 48000, bf = 480;
  final data = Int16List(blocks * bf * ch);
  for (var b = 0; b < blocks; b++) {
    for (var i = 0; i < bf * ch; i++) {
      data[b * bf * ch + i] = 1000 + b;
    }
  }
  final bytes = data.buffer.asUint8List();
  final f = File('${dir.path}/t.wav');
  f.writeAsBytesSync([...wavHeader(bytes.length, ch, rate), ...bytes]);
  return f.path;
}

void main() {
  test('cut / keep / joins', () {
    final s = [const Seg(0, 100)];
    final c = cut(s, 10, 30);
    expect(c, [const Seg(0, 10), const Seg(30, 100)]);
    expect(totalLen(c), 80);
    expect(joins(c), [10]);
    final c2 = cut(c, 5, 15); // attraversa l'unione
    expect(c2, [const Seg(0, 5), const Seg(35, 100)]);
    expect(keep(c2, 3, 8), [const Seg(3, 5), const Seg(35, 38)]);
    expect(cut(s, 0, 100), isEmpty);
    expect(normalize([const Seg(0, 5), const Seg(5, 9)]), [const Seg(0, 9)]);
  });

  test('render, header e peaks', () {
    final dir = Directory.systemTemp.createTempSync('rr');
    final src = makeWav(dir, 100);
    final info = readWavInfo(src);
    expect(info.channels, 2);
    expect(info.rate, 48000);
    expect(info.blocks, 100);
    expect(computePeaks(src).length, 100);

    final dst = '${dir.path}/out.wav';
    final segs = cut([const Seg(0, 100)], 10, 30);
    final n = renderSegments(src, segs, dst);
    expect(n, 80 * info.blockBytes);
    final out = readWavInfo(dst);
    expect(out.blocks, 80);
    final bytes = File(dst).readAsBytesSync();
    final s = bytes.buffer.asInt16List(44, (bytes.length - 44) ~/ 2);
    // primo campione del blocco 50 di uscita = blocco 70 originale
    expect(s[50 * 480 * 2], 1070);
    // dissolvenza sul punto di unione
    expect(s[10 * 480 * 2].abs() < 1030, true);
    dir.deleteSync(recursive: true);
  });

  test('bandiere', () {
    expect(detectFlags('Fox News usa'), contains(flagFromCode('US')));
    expect(leadingFlag('${flagFromCode('IT')} Rai'), flagFromCode('IT'));
    expect(stripFlag('${flagFromCode('IT')} Rai'), 'Rai');
  });
}
