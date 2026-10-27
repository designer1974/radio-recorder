import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Versione di prova scaricata da GitHub: permette di "simulare" Pro,
/// perché fuori da Google Play i pagamenti veri non funzionano.
/// La compilazione per Play Store NON passa PRO_TEST, quindi lì è spento.
const kTestMode = bool.fromEnvironment('PRO_TEST');

/// Backend su devoo.it (vedi cartella backend del progetto Pro).
const kApiBase = String.fromEnvironment('DEVOO_API', defaultValue: 'https://record.devoo.it');
const kApiKey = String.fromEnvironment('DEVOO_KEY', defaultValue: 'devoo-record-app');

/// ID abbonamento in Play Console → Monetizza → Abbonamenti.
const kSubscriptionId = 'devoo_record_pro';

/// Tutte le funzioni, divise in Gratis e Pro.
enum Feature {
  // Gratis
  record('record', pro: false),
  share('share', pro: false),
  compress('compress', pro: false),
  trimBasic('trim_basic', pro: false), // taglia prima/dopo il cursore

  // Pro
  editFull('edit_full', pro: true, title: 'Editor completo'),
  noiseReduction('noise_reduction', pro: true, trial: 'noise_reduction', title: 'Riduzione rumore'),
  hqAudio('hq_audio', pro: true, title: 'Qualità Alta e WAV'),
  transcribe('transcribe', pro: true, trial: 'transcribe', title: 'Trascrizione'),
  translate('translate', pro: true, title: 'Traduzione del testo');

  const Feature(this.key, {required this.pro, this.trial, this.title = ''});
  final String key;
  final bool pro;
  final String? trial;
  final String title;
}

sealed class Access {
  const Access();
}

class Allowed extends Access {
  const Allowed();
}

class Trial extends Access {
  const Trial(this.remaining);
  final int remaining;
}

class Locked extends Access {
  const Locked();
}

class Disabled extends Access {
  const Disabled();
}

/// Config remota (si cambia dal pannello admin su devoo.it, senza aggiornare l'app).
class RemoteConfig {
  RemoteConfig({
    this.minVersionCode = 1,
    this.latestVersionCode = 1,
    this.bannerEnabled = true,
    this.bannerTitle = 'Passa a Devoo Recorder Pro',
    this.bannerText = 'Editor completo, riduzione rumore, trascrizione e traduzione. Senza pubblicità.',
    this.bannerCta = 'Scopri Pro',
    this.bannerEvery = 3,
    this.bannerMinLaunches = 2,
    this.offerEnabled = false,
    this.offerId = '',
    this.offerLabel = '',
    Map<String, int>? trials,
    Set<String>? disabled,
  })  : trials = trials ?? const {'noise_reduction': 1, 'transcribe': 1},
        disabled = disabled ?? const {};

  final int minVersionCode, latestVersionCode;
  final bool bannerEnabled;
  final String bannerTitle, bannerText, bannerCta;
  final int bannerEvery, bannerMinLaunches;
  final bool offerEnabled;
  final String offerId, offerLabel;
  final Map<String, int> trials;
  final Set<String> disabled;

  factory RemoteConfig.fromJson(Map<String, dynamic> j) {
    final d = RemoteConfig();
    final b = (j['banner'] as Map?) ?? {};
    final o = (j['offer'] as Map?) ?? {};
    final t = j['trials'] as Map?;
    final dis = j['disabled'] as List?;
    int i(Object? v, int def) => v is num ? v.toInt() : def;
    return RemoteConfig(
      minVersionCode: i(j['minVersionCode'], d.minVersionCode),
      latestVersionCode: i(j['latestVersionCode'], d.latestVersionCode),
      bannerEnabled: b['enabled'] as bool? ?? d.bannerEnabled,
      bannerTitle: b['title'] as String? ?? d.bannerTitle,
      bannerText: b['text'] as String? ?? d.bannerText,
      bannerCta: b['cta'] as String? ?? d.bannerCta,
      bannerEvery: i(b['showEvery'], d.bannerEvery).clamp(1, 1000),
      bannerMinLaunches: i(b['minLaunches'], d.bannerMinLaunches),
      offerEnabled: o['enabled'] as bool? ?? false,
      offerId: o['offerId'] as String? ?? '',
      offerLabel: o['label'] as String? ?? '',
      trials: t == null ? d.trials : t.map((k, v) => MapEntry('$k', i(v, 0))),
      disabled: dis == null ? d.disabled : dis.map((e) => '$e').toSet(),
    );
  }
}

/// Un piano acquistabile da mostrare nel paywall.
class ProPlan {
  ProPlan(this.details, {required this.price, this.trialDays = 0, this.introPrice, this.offerId});
  final ProductDetails details;
  final String price;
  final int trialDays;
  final String? introPrice;
  final String? offerId;
}

enum ProEvent { purchased, restored, nothingToRestore, canceled, error, unavailable }

/// Cuore della versione Pro. Uso: `Pro.i.isPro`, `Pro.i.check(Feature.x)`.
class Pro extends ChangeNotifier {
  Pro._();
  static final Pro i = Pro._();

  final _iap = InAppPurchase.instance;
  SharedPreferences? _prefs;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final _events = StreamController<ProEvent>.broadcast();

  bool _pro = false;
  bool _simulated = false;
  DateTime? _expiry;
  RemoteConfig config = RemoteConfig();
  int launches = 0;
  String installId = '';
  bool storeAvailable = false;
  bool _restoring = false;

  bool get isPro => _pro || _simulated;
  bool get isSimulated => _simulated;
  DateTime? get expiry => _expiry;
  Stream<ProEvent> get events => _events.stream;

  Future<void> init() async {
    final p = _prefs = await SharedPreferences.getInstance();
    installId = p.getString('pro_install_id') ?? _newId();
    await p.setString('pro_install_id', installId);
    launches = (p.getInt('pro_launches') ?? 0) + 1;
    await p.setInt('pro_launches', launches);

    final exp = p.getInt('pro_expiry');
    _expiry = exp == null || exp == 0 ? null : DateTime.fromMillisecondsSinceEpoch(exp);
    // Senza internet l'utente Pro resta Pro fino alla scadenza salvata
    _pro = (p.getBool('pro') ?? false) && (_expiry == null || _expiry!.isAfter(DateTime.now()));
    _simulated = kTestMode && (p.getBool('pro_simulated') ?? false);

    final cached = p.getString('pro_config');
    if (cached != null) {
      try {
        config = RemoteConfig.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      } catch (_) {}
    }
    notifyListeners();

    unawaited(_fetchConfig());
    try {
      storeAvailable = await _iap.isAvailable();
    } catch (_) {
      storeAvailable = false;
    }
    if (storeAvailable) {
      _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) => _events.add(ProEvent.error));
      unawaited(_sync(userAction: false));
    }
  }

  String _newId() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'dr-$r-${Object().hashCode.toRadixString(16)}';
  }

  // ------------------------------------------------------------ funzioni

  Access check(Feature f) {
    if (config.disabled.contains(f.key)) return const Disabled();
    if (!f.pro || isPro) return const Allowed();
    final left = trialsLeft(f);
    return left > 0 ? Trial(left) : const Locked();
  }

  bool locked(Feature f) => check(f) is Locked;

  int trialsLeft(Feature f) {
    final k = f.trial;
    if (k == null) return 0;
    final allowed = config.trials[k] ?? 0;
    final used = _prefs?.getInt('trial_$k') ?? 0;
    return (allowed - used).clamp(0, 1000);
  }

  Future<void> useTrial(Feature f) async {
    final k = f.trial;
    if (k == null || isPro) return;
    await _prefs?.setInt('trial_$k', (_prefs?.getInt('trial_$k') ?? 0) + 1);
    notifyListeners();
  }

  bool get showBanner =>
      !isPro &&
      config.bannerEnabled &&
      launches >= config.bannerMinLaunches &&
      launches % config.bannerEvery == 0;

  // ------------------------------------------------------------ acquisti

  Future<List<ProPlan>> loadPlans() async {
    if (!storeAvailable) return [];
    final res = await _iap.queryProductDetails({kSubscriptionId});
    final plans = <ProPlan>[];
    for (final d in res.productDetails) {
      var trialDays = 0;
      String? intro;
      String? offerId;
      var price = d.price;
      if (d is GooglePlayProductDetails && d.subscriptionIndex != null) {
        final offer = d.productDetails.subscriptionOfferDetails?[d.subscriptionIndex!];
        if (offer != null) {
          offerId = offer.offerId;
          final phases = offer.pricingPhases;
          if (phases.isNotEmpty) {
            price = phases.last.formattedPrice;
            for (final ph in phases.take(phases.length - 1)) {
              if (ph.priceAmountMicros == 0) {
                trialDays = _days(ph.billingPeriod);
              } else {
                intro = ph.formattedPrice;
              }
            }
          }
        }
      }
      plans.add(ProPlan(d, price: price, trialDays: trialDays, introPrice: intro, offerId: offerId));
    }
    // Offerta attiva dal pannello per prima, poi il piano con prova gratuita
    int score(ProPlan p) =>
        (config.offerEnabled && config.offerId.isNotEmpty && p.offerId == config.offerId ? 100 : 0) +
        (p.trialDays > 0 ? 10 : 0);
    plans.sort((a, b) => score(b).compareTo(score(a)));
    return plans;
  }

  Future<void> buy(ProPlan plan) async {
    if (!storeAvailable) {
      _events.add(ProEvent.unavailable);
      return;
    }
    final param = plan.details is GooglePlayProductDetails
        ? GooglePlayPurchaseParam(productDetails: plan.details, applicationUserName: installId)
        : PurchaseParam(productDetails: plan.details, applicationUserName: installId);
    try {
      await _iap.buyNonConsumable(purchaseParam: param);
    } catch (_) {
      _events.add(ProEvent.error);
    }
  }

  /// Pulsante "Ripristina".
  Future<void> restore() => _sync(userAction: true);

  Future<void> _sync({required bool userAction}) async {
    if (!storeAvailable || _restoring) {
      if (userAction && !storeAvailable) _events.add(ProEvent.unavailable);
      return;
    }
    _restoring = true;
    try {
      final add = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final res = await add.queryPastPurchases();
      if (res.error != null) return; // Play non raggiungibile: resta lo stato salvato
      final active = res.pastPurchases
          .where((p) => p.productID == kSubscriptionId && p.status != PurchaseStatus.pending)
          .toList();
      if (active.isEmpty) {
        await _setStatus(false, null);
        if (userAction) _events.add(ProEvent.nothingToRestore);
      } else {
        await _handle(active, fromUser: false);
        if (userAction && _pro) _events.add(ProEvent.restored);
      }
    } catch (_) {
      if (userAction) _events.add(ProEvent.error);
    } finally {
      _restoring = false;
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    final ok = <PurchaseDetails>[];
    for (final p in list) {
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          ok.add(p);
        case PurchaseStatus.canceled:
          _events.add(ProEvent.canceled);
        case PurchaseStatus.error:
          _events.add(ProEvent.error);
        case PurchaseStatus.pending:
          break; // pagamento in attesa: si sblocca quando arriva
      }
    }
    if (ok.isNotEmpty) await _handle(ok, fromUser: true);
  }

  Future<void> _handle(List<PurchaseDetails> list, {required bool fromUser}) async {
    var pro = false;
    DateTime? exp;
    for (final p in list) {
      final res = await _verify(p.verificationData.serverVerificationData);
      if (res != null) {
        // Il server ha risposto: decide lui (e ha già confermato l'acquisto a Google)
        if (res.$1) {
          pro = true;
          if (res.$2 != null && (exp == null || res.$2!.isAfter(exp))) exp = res.$2;
        }
      } else {
        // Server irraggiungibile: ci fidiamo di Google Play sul telefono
        pro = true;
        final grace = DateTime.now().add(const Duration(days: 3));
        if (exp == null || grace.isAfter(exp)) exp = grace;
      }
      // Conferma l'acquisto (Google rimborsa dopo 3 giorni senza conferma)
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (_) {}
      }
    }
    await _setStatus(pro, exp);
    if (fromUser && pro) _events.add(ProEvent.purchased);
  }

  Future<void> _setStatus(bool pro, DateTime? exp) async {
    _pro = pro;
    _expiry = exp;
    await _prefs?.setBool('pro', pro);
    await _prefs?.setInt('pro_expiry', exp?.millisecondsSinceEpoch ?? 0);
    notifyListeners();
  }

  /// Solo versione di prova: accende/spegne Pro senza pagare.
  Future<void> setSimulated(bool on) async {
    if (!kTestMode) return;
    _simulated = on;
    await _prefs?.setBool('pro_simulated', on);
    notifyListeners();
  }

  /// Solo versione di prova: ridà le prove gratuite.
  Future<void> resetTrials() async {
    if (!kTestMode) return;
    for (final f in Feature.values) {
      if (f.trial != null) await _prefs?.remove('trial_${f.trial}');
    }
    notifyListeners();
  }

  // ------------------------------------------------------------ server

  Future<(bool, DateTime?)?> _verify(String token) async {
    try {
      final r = await _http('POST', '/api/verify.php',
          jsonEncode({'purchaseToken': token, 'installId': installId}));
      if (r == null) return null;
      final j = jsonDecode(r) as Map<String, dynamic>;
      final e = j['expiry'] as String?;
      return (j['pro'] == true, e == null ? null : DateTime.tryParse(e));
    } catch (_) {
      return null;
    }
  }

  Future<void> _fetchConfig() async {
    try {
      final r = await _http('GET', '/api/config.php', null);
      if (r == null) return;
      config = RemoteConfig.fromJson(jsonDecode(r) as Map<String, dynamic>);
      await _prefs?.setString('pro_config', r);
      notifyListeners();
    } catch (_) {}
  }

  /// Ritorna il corpo della risposta se HTTP 200, altrimenti null.
  Future<String?> _http(String method, String path, String? body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.openUrl(method, Uri.parse('$kApiBase$path'));
      req.headers.set('X-Devoo-Key', kApiKey);
      req.headers.set('Accept', 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(body);
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join();
      return res.statusCode == 200 ? text : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static int _days(String iso) {
    // P3D, P1W, P1M, P1Y
    final m = RegExp(r'^P(\d+)([DWMY])$').firstMatch(iso);
    if (m == null) return 0;
    final n = int.parse(m.group(1)!);
    return switch (m.group(2)) { 'D' => n, 'W' => n * 7, 'M' => n * 30, _ => n * 365 };
  }

  @override
  void dispose() {
    _sub?.cancel();
    _events.close();
    super.dispose();
  }
}
