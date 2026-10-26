import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:radio_recorder/transcript.dart';
import 'package:radio_recorder/wav_edit.dart';

void main() {
  test('parole → frasi', () {
    final segs = [
      const RawSeg(0, 300, ' Hello'),
      const RawSeg(300, 600, ' world.'),
      const RawSeg(700, 900, ' [BLANK_AUDIO]'),
      const RawSeg(5000, 5400, ' How'),
      const RawSeg(5400, 5800, ' are'),
      const RawSeg(5800, 6200, ' you?'),
    ];
    final lines = buildLines(segs);
    expect(lines.length, 2);
    expect(lines[0].text, 'Hello world.');
    expect(lines[1].text, 'How are you?');
    expect(lines[1].s, 5000);
    expect(lineAt(lines, 100), 0);
    expect(lineAt(lines, 5500), 1);
    expect(wordAt(lines[1], 5500), 1);
  });

  test('pezzo con più parole: tempi proporzionali', () {
    final lines = buildLines([const RawSeg(0, 1000, 'uno due tre')]);
    expect(lines.single.words.length, 3);
    expect(lines.single.words.first.s, 0);
    expect(lines.single.words.last.e, 1000);
  });

  test('json', () {
    final t = Transcript('en', 'base', buildLines([const RawSeg(0, 500, 'Hi.')]),
        {'it': ['Ciao.']});
    final back = Transcript.fromJson(t.toJson());
    expect(back.lines.single.text, 'Hi.');
    expect(back.translations['it'], ['Ciao.']);
  });

  test('conversione 48k stereo → 16k mono', () {
    final dir = Directory.systemTemp.createTempSync('tr');
    const frames = 48000; // 1 secondo
    final data = Int16List(frames * 2);
    for (var i = 0; i < data.length; i++) {
      data[i] = 1000;
    }
    final bytes = data.buffer.asUint8List();
    final src = '${dir.path}/a.wav';
    File(src).writeAsBytesSync([...wavHeader(bytes.length, 2, 48000), ...bytes]);
    final ms = convertTo16kMono(src, '${dir.path}/b.wav');
    expect(ms, 1000);
    final info = readWavInfo('${dir.path}/b.wav');
    expect(info.channels, 1);
    expect(info.rate, 16000);
    final out = File('${dir.path}/b.wav').readAsBytesSync();
    expect(out.buffer.asInt16List(44, 10)[5], 1000);
    dir.deleteSync(recursive: true);
  });
}
