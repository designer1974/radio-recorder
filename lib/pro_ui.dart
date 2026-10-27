import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'pro.dart';

/// Controlla una funzione prima di usarla.
/// Pro o gratis → true. Prova gratuita → la conta e dà true. Bloccata → apre la pagina Pro.
Future<bool> requireFeature(BuildContext context, Feature f) async {
  final a = Pro.i.check(f);
  switch (a) {
    case Allowed():
      return true;
    case Disabled():
      _snack(context, '${f.title}: non disponibile in questo momento');
      return false;
    case Trial(:final remaining):
      await Pro.i.useTrial(f);
      if (context.mounted) {
        _snack(
            context,
            remaining > 1
                ? 'Prova gratuita di ${f.title} (ne restano ${remaining - 1})'
                : 'Ultima prova gratuita di ${f.title}. Poi serve Pro.');
      }
      return true;
    case Locked():
      await openPaywall(context, highlight: f);
      return Pro.i.isPro;
  }
}

Future<void> openPaywall(BuildContext context, {Feature? highlight}) =>
    Navigator.push(context,
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => PaywallPage(highlight: highlight)));

void _snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));

/// Piccolo bollino "PRO" con lucchetto.
class ProBadge extends StatelessWidget {
  const ProBadge({super.key, this.trial = 0});
  final int trial;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    if (trial > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            border: Border.all(color: s.primary), borderRadius: BorderRadius.circular(99)),
        child: Text('Prova gratis', style: TextStyle(fontSize: 11, color: s.primary, fontWeight: FontWeight.w600)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: s.primaryContainer, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock, size: 12, color: s.onPrimaryContainer),
        const SizedBox(width: 3),
        Text('PRO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: s.onPrimaryContainer)),
      ]),
    );
  }
}

/// Bollino giusto per una funzione: niente se è libera.
Widget? featureBadge(Feature f) => switch (Pro.i.check(f)) {
      Locked() => const ProBadge(),
      Trial(:final remaining) => ProBadge(trial: remaining),
      _ => null,
    };

/// Banner Pro nostro: l'unica "pubblicità" dell'app. Solo per utenti gratis.
class ProBanner extends StatefulWidget {
  const ProBanner({super.key});
  @override
  State<ProBanner> createState() => _ProBannerState();
}

class _ProBannerState extends State<ProBanner> {
  bool _closed = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Pro.i,
      builder: (context, _) {
        final p = Pro.i;
        if (_closed || !p.showBanner) return const SizedBox.shrink();
        final c = p.config;
        final s = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Material(
            color: s.primaryContainer,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
              child: Row(children: [
                Icon(Icons.workspace_premium, size: 32, color: s.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.bannerTitle, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    Text(c.bannerText, style: TextStyle(fontSize: 13, color: s.onPrimaryContainer)),
                    if (c.offerEnabled && c.offerLabel.isNotEmpty)
                      Text(c.offerLabel, style: TextStyle(color: s.primary, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    FilledButton(onPressed: () => openPaywall(context), child: Text(c.bannerCta)),
                  ]),
                ),
                IconButton(
                    tooltip: 'Chiudi',
                    onPressed: () => setState(() => _closed = true),
                    icon: const Icon(Icons.close)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

/// Pagina Pro: chiara e onesta.
class PaywallPage extends StatefulWidget {
  const PaywallPage({super.key, this.highlight});
  final Feature? highlight;
  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  List<ProPlan>? _plans;
  String? _msg;
  bool _wasPro = Pro.i.isPro;
  StreamSubscription<ProEvent>? _sub;

  @override
  void initState() {
    super.initState();
    Pro.i.loadPlans().then((p) => mounted ? setState(() => _plans = p) : null).catchError((_) {
      if (mounted) setState(() => _plans = []);
    });
    _sub = Pro.i.events.listen((e) {
      if (!mounted) return;
      setState(() => _msg = switch (e) {
            ProEvent.purchased => 'Benvenuto in Devoo Recorder Pro!',
            ProEvent.restored => 'Abbonamento ripristinato.',
            ProEvent.nothingToRestore => 'Nessun abbonamento attivo su questo account Google.',
            ProEvent.canceled => null,
            ProEvent.unavailable => 'Google Play non è disponibile: l\'app non è stata installata dal Play Store.',
            ProEvent.error => 'Pagamento non riuscito. Riprova.',
          });
    });
    Pro.i.addListener(_onPro);
  }

  void _onPro() {
    if (!mounted) return;
    if (!_wasPro && Pro.i.isPro) {
      _wasPro = true;
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.maybePop(context);
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    Pro.i.removeListener(_onPro);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final p = Pro.i;
    final benefits = <(Feature, IconData, String)>[
      (Feature.editFull, Icons.content_cut, 'Editor completo: taglia la selezione e unisci, tieni solo una parte'),
      (Feature.noiseReduction, Icons.graphic_eq, 'Riduzione rumore su ogni registrazione'),
      (Feature.hqAudio, Icons.high_quality, 'Qualità Alta 128 kbps e WAV senza compressione'),
      (Feature.transcribe, Icons.subtitles_outlined, 'Trascrizione offline: tutto il parlato in testo'),
      (Feature.translate, Icons.translate, 'Traduzione del testo in 6 lingue'),
      (Feature.record, Icons.block, 'Nessuna pubblicità, mai'),
    ];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        actions: [TextButton(onPressed: p.restore, child: const Text('Ripristina'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Icon(Icons.workspace_premium, size: 56, color: s.primary),
          const SizedBox(height: 8),
          const Text('Devoo Recorder Pro',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Registrare resta gratis per sempre. Pro aggiunge gli strumenti da studio.',
              textAlign: TextAlign.center, style: TextStyle(color: s.onSurfaceVariant)),
          const SizedBox(height: 20),
          for (final (f, icon, text) in benefits)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: f == widget.highlight ? s.primaryContainer : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                Icon(icon, color: s.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
              ]),
            ),
          const SizedBox(height: 20),
          if (p.isPro) _active(s) else _buyArea(s),
          if (_msg != null) ...[
            const SizedBox(height: 14),
            Text(_msg!, textAlign: TextAlign.center, style: TextStyle(color: s.primary, fontWeight: FontWeight.w600)),
          ],
          if (kTestMode && !p.isPro) ...[
            const SizedBox(height: 24),
            _AdminCard(),
          ],
        ],
      ),
    );
  }

  Widget _buyArea(ColorScheme s) {
    final plans = _plans;
    if (plans == null) {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    if (plans.isEmpty) {
      return Card(
        elevation: 0,
        color: s.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            Pro.i.storeAvailable
                ? 'Abbonamento non ancora disponibile. Riprova più tardi.'
                : 'I pagamenti funzionano solo con l\'app scaricata dal Play Store.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final plan = plans.first;
    final c = Pro.i.config;
    final offerOn = c.offerEnabled && plan.offerId != null && plan.offerId == c.offerId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (offerOn && c.offerLabel.isNotEmpty)
        Text(c.offerLabel,
            textAlign: TextAlign.center, style: TextStyle(color: s.primary, fontWeight: FontWeight.w800)),
      Text(
        [
          if (plan.trialDays > 0) '${plan.trialDays} giorni gratis, poi',
          if (plan.introPrice != null) '${plan.introPrice} il primo anno, poi',
          '${plan.price} all\'anno',
        ].join(' '),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 54,
        child: FilledButton(
          onPressed: () => Pro.i.buy(plan),
          child: Text(plan.trialDays > 0 ? 'Inizia ${plan.trialDays} giorni gratis' : 'Abbonati',
              style: const TextStyle(fontSize: 17)),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        'Si rinnova ogni anno finché non annulli. Puoi annullare quando vuoi da Google Play → '
        'Pagamenti e abbonamenti.'
        '${plan.trialDays > 0 ? ' Se annulli durante la prova non paghi nulla.' : ''}',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: s.onSurfaceVariant),
      ),
    ]);
  }

  Widget _active(ColorScheme s) {
    final p = Pro.i;
    final exp = p.expiry;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(side: BorderSide(color: s.primary), borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(p.isSimulated ? 'Pro attivo (admin)' : 'Pro è attivo',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if (!p.isSimulated && exp != null)
            Text('Fino al ${exp.day}/${exp.month}/${exp.year}', style: TextStyle(color: s.onSurfaceVariant)),
          if (!p.isSimulated)
            TextButton(onPressed: openManageSubscription, child: const Text('Gestisci abbonamento')),
          if (p.isSimulated) _AdminCard(),
        ]),
      ),
    );
  }
}

Future<void> openManageSubscription() => launchUrl(
    Uri.parse('https://play.google.com/store/account/subscriptions?sku=$kSubscriptionId&package=com.designer1974.radio_recorder'),
    mode: LaunchMode.externalApplication);

/// Solo nella versione di prova (da GitHub): Pro attivo senza pagare, per l'admin.
class _AdminCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Pro.i,
      builder: (context, _) => Card(
        elevation: 0,
        color: s.tertiaryContainer,
        child: Column(children: [
          SwitchListTile(
            secondary: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Admin: Pro attivo'),
            subtitle: const Text('Solo versione di prova. Spegni per vedere l\'app come un utente gratis.'),
            value: Pro.i.isSimulated,
            onChanged: Pro.i.setSimulated,
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Ridai le prove gratuite'),
            onTap: () {
              Pro.i.resetTrials();
              _snack(context, 'Prove gratuite ripristinate');
            },
          ),
        ]),
      ),
    );
  }
}

/// Riquadro per le Impostazioni: stato Pro + accesso admin nella versione di prova.
class ProSettingsCard extends StatelessWidget {
  const ProSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Pro.i,
      builder: (context, _) {
        final p = Pro.i;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            elevation: 0,
            color: s.primaryContainer,
            child: ListTile(
              leading: Icon(Icons.workspace_premium, color: s.primary),
              title: Text(p.isPro ? (p.isSimulated ? 'Pro attivo (admin)' : 'Pro attivo') : 'Devoo Recorder Pro'),
              subtitle: Text(p.isPro ? 'Tutte le funzioni sbloccate' : 'Editor completo, riduzione rumore, testo e traduzione'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPaywall(context),
            ),
          ),
          if (kTestMode) _AdminCard(),
        ]);
      },
    );
  }
}
