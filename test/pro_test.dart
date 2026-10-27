import 'package:flutter_test/flutter_test.dart';
import 'package:radio_recorder/pro.dart';
import 'package:radio_recorder/recorder.dart';

void main() {
  test('config remota letta dal pannello', () {
    final c = RemoteConfig.fromJson({
      'minVersionCode': 3,
      'banner': {'enabled': false, 'title': 'Ciao', 'showEvery': 0},
      'offer': {'enabled': true, 'offerId': 'blackfriday', 'label': '-30%'},
      'trials': {'transcribe': 2},
      'disabled': ['translate'],
    });
    expect(c.minVersionCode, 3);
    expect(c.bannerEnabled, false);
    expect(c.bannerTitle, 'Ciao');
    expect(c.bannerEvery, 1); // mai zero
    expect(c.bannerText, isNotEmpty); // valore di default se manca
    expect(c.offerId, 'blackfriday');
    expect(c.trials['transcribe'], 2);
    expect(c.disabled, contains('translate'));
  });

  test('config vuota usa i valori di default', () {
    final c = RemoteConfig.fromJson({});
    expect(c.bannerEnabled, true);
    expect(c.trials['transcribe'], 1);
  });

  test('funzioni gratis e Pro', () {
    expect(Feature.record.pro, false);
    expect(Feature.trimBasic.pro, false);
    expect(Feature.editFull.pro, true);
    expect(Feature.transcribe.trial, 'transcribe');
    expect(AudioQuality.wav.isPro, true);
    expect(AudioQuality.voice.isPro, false);
  });
}
