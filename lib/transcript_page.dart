import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'flags.dart';
import 'transcript.dart';
import 'whisper_service.dart';

/// Lingue: codice -> (bandiera, nome)
const tLangs = <String, (String, String)>{
  'it': ('IT', 'Italiano'),
  'en': ('GB', 'Inglese'),
  'fr': ('FR', 'Francese'),
  'de': ('DE', 'Tedesco'),
  'es': ('ES', 'Spagnolo'),
  'ar': ('SA', 'Arabo'),
  'pt': ('PT', 'Portoghese'),
  'ru': ('RU', 'Russo'),
  'tr': ('TR', 'Turco'),
  'nl': ('NL', 'Olandese'),
  'zh': ('CN', 'Cinese'),
  'ja': ('JP', 'Giapponese'),
};

String langFlag(String code) =>
    tLangs[code] == null ? '🌐' : flagFromCode(tLangs[code]!.$1);
String langName(String code) => tLangs[code]?.$2 ?? code.toUpperCase();
bool isRtl(String code) => code == 'ar';

TranslateLanguage? _ml(String code) {
  for (final l in TranslateLanguage.values) {
    if (l.bcpCode == code) return l;
  }
  return null;
}

/// Pagina "Testo": trascrizione con evidenziazione che segue l'audio.
class TranscriptPage extends StatefulWidget {
  final String path;
  final String name;
  const TranscriptPage({super.key, required this.path, required this.name});

  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  final _whisper = WhisperService();
  Transcript? _t;

  // creazione
  Quality _quality = Quality.balanced;
  String _lang = 'auto';
  bool _working = false;
  String _stage = '';
  double? _progress;
  DateTime? _startedAt;
  Timer? _clock;

  // traduzione
  String? _trLang; // lingua della traduzione mostrata
  bool _translating = false;

  // riproduzione
  final _player = AudioPlayer();
  final _items = ItemScrollController();
  StreamSubscription? _posSub, _stateSub;
  int _pos = 0;
  int _line = -1;
  bool _playing = false;
  bool _loop = false;
  double _speed = 1.0;
  int? _loopLine;

  @override
  void initState() {
    super.initState();
    _t = loadTranscript(widget.path);
    _player.setSource(DeviceFileSource(widget.path));
    _posSub = _player.onPositionChanged.listen(_onPos);
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    });
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final q = p.getString('tq');
    setState(() {
      _quality = Quality.values.firstWhere((x) => x.name == q,
          orElse: () => Quality.balanced);
      _trLang = p.getString('trLang');
      if (_t != null && _trLang != null && !_t!.translations.containsKey(_trLang)) {
        _trLang = null;
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  // ---------------- creazione ----------------

  Future<void> _create() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('tq', _quality.name);
    await _player.pause();
    setState(() {
      _working = true;
      _stage = 'Avvio…';
      _progress = null;
      _startedAt = DateTime.now();
    });
    _clock = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    try {
      final t = await _whisper.transcribe(
        widget.path,
        quality: _quality,
        lang: _lang,
        onStage: (s, prog) {
          if (mounted) {
            setState(() {
              _stage = s;
              _progress = prog;
            });
          }
        },
      );
      if (t.lines.isEmpty) {
        _snack('Nessuna voce trovata nella registrazione');
      } else {
        // rilevatore della lingua sul testo (oltre a Whisper sull'audio)
        if (t.lang.isEmpty) t.lang = await _detect(t.text) ?? '';
        saveTranscript(widget.path, t);
        setState(() {
          _t = t;
          _trLang = null;
        });
      }
    } catch (e) {
      _snack('Errore: $e');
    } finally {
      _clock?.cancel();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _detect(String text) async {
    final id = LanguageIdentifier(confidenceThreshold: 0.3);
    try {
      final c = await id.identifyLanguage(text);
      return c == 'und' ? null : c.split('-').first;
    } catch (_) {
      return null;
    } finally {
      id.close();
    }
  }

  // ---------------- traduzione ----------------

  Future<void> _translate(String? to) async {
    final t = _t;
    if (t == null) return;
    final p = await SharedPreferences.getInstance();
    if (to == null) {
      await p.remove('trLang');
      setState(() => _trLang = null);
      return;
    }
    await p.setString('trLang', to);
    if (t.translations.containsKey(to)) {
      setState(() => _trLang = to);
      return;
    }
    final src = _ml(t.lang), dst = _ml(to);
    if (src == null || dst == null || t.lang == to) {
      _snack(t.lang.isEmpty
          ? 'Lingua del testo sconosciuta'
          : 'Traduzione non disponibile per questa lingua');
      return;
    }
    setState(() => _translating = true);
    final mgr = OnDeviceTranslatorModelManager();
    try {
      for (final m in {src.bcpCode, dst.bcpCode, 'en'}) {
        if (!await mgr.isModelDownloaded(m)) {
          _snack('Scarico il dizionario ${langName(m)} (circa 30 MB)…');
          await mgr.downloadModel(m, isWifiRequired: false);
        }
      }
      final tr = OnDeviceTranslator(sourceLanguage: src, targetLanguage: dst);
      final out = <String>[];
      for (final l in t.lines) {
        out.add(await tr.translateText(l.text));
      }
      await tr.close();
      t.translations[to] = out;
      saveTranscript(widget.path, t);
      if (mounted) setState(() => _trLang = to);
    } catch (e) {
      _snack('Traduzione non riuscita: $e');
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  // ---------------- riproduzione ----------------

  void _onPos(Duration d) {
    final ms = d.inMilliseconds;
    final t = _t;
    if (t == null || !mounted) return;
    // ripeti frase: torna all'inizio quando finisce
    if (_loop && _loopLine != null && _loopLine! < t.lines.length) {
      final l = t.lines[_loopLine!];
      if (ms > l.e + 250) {
        _player.seek(Duration(milliseconds: l.s));
        return;
      }
    }
    final i = lineAt(t.lines, ms);
    setState(() {
      _pos = ms;
      if (i != _line) {
        _line = i;
        if (!_loop) _loopLine = i;
        if (i >= 0 && _items.isAttached) {
          _items.scrollTo(
              index: i,
              alignment: 0.3,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut);
        }
      }
    });
  }

  Future<void> _seek(int ms, {int? line}) async {
    await _player.seek(Duration(milliseconds: ms));
    if (line != null) _loopLine = line;
    if (!_playing) await _player.resume();
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.resume();
    }
  }

  void _cycleSpeed() {
    const speeds = [1.0, 0.75, 0.5, 1.25];
    final i = speeds.indexOf(_speed);
    setState(() => _speed = speeds[(i + 1) % speeds.length]);
    _player.setPlaybackRate(_speed);
  }

  // ---------------- condivisione ----------------

  Future<void> _share() async {
    final t = _t!;
    final b = StringBuffer('${widget.name}\n\n');
    for (var i = 0; i < t.lines.length; i++) {
      b.writeln('[${fmtMs(t.lines[i].s)}] ${t.lines[i].text}');
      final tr = _trLang == null ? null : t.translations[_trLang];
      if (tr != null && i < tr.length) b.writeln('    ${tr[i]}');
    }
    final dir = await getTemporaryDirectory();
    final safe = widget.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    final f = File('${dir.path}/${safe.isEmpty ? 'testo' : safe}.txt');
    await f.writeAsString(b.toString());
    await Share.shareXFiles([XFile(f.path, mimeType: 'text/plain')],
        text: widget.name);
  }

  Future<void> _deleteText() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminare il testo?'),
        content: const Text('L\'audio resta. Potrai rifare la trascrizione.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Elimina')),
        ],
      ),
    );
    if (ok != true) return;
    deleteTranscript(widget.path);
    setState(() {
      _t = null;
      _line = -1;
    });
  }

  // ---------------- interfaccia ----------------

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return PopScope(
      canPop: !_working,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _snack('Attendi la fine della trascrizione');
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (t != null && !_working) ...[
              IconButton(
                tooltip: 'Copia',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: t.toPlainText()));
                  _snack('Testo copiato');
                },
              ),
              IconButton(
                tooltip: 'Condividi testo',
                icon: const Icon(Icons.share_outlined),
                onPressed: _share,
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'redo') setState(() => _t = null);
                  if (v == 'delete') _deleteText();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'redo', child: Text('Rifai trascrizione')),
                  PopupMenuItem(value: 'delete', child: Text('Elimina testo')),
                ],
              ),
            ],
          ],
        ),
        body: _working
            ? _workingView()
            : t == null
                ? _setupView()
                : _textView(t),
        bottomNavigationBar: t != null && !_working ? _playerBar(t) : null,
      ),
    );
  }

  Widget _setupView() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.subtitles_outlined, size: 56, color: scheme.primary),
        const SizedBox(height: 12),
        const Text('Trasforma la voce in testo',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
          'Gratis e senza internet (dopo il primo download). '
          'Mentre ascolti, la parola detta si illumina.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Text('Qualità', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<Quality>(
          segments: [
            for (final q in Quality.values)
              ButtonSegment(value: q, label: Text(q.label)),
          ],
          selected: {_quality},
          onSelectionChanged: (s) => setState(() => _quality = s.first),
        ),
        const SizedBox(height: 6),
        FutureBuilder<bool>(
          future: _whisper.hasModel(_quality),
          builder: (_, snap) => Text(
            switch (_quality) {
              Quality.fast => 'Più rapido, qualche errore in più.',
              Quality.balanced => 'Consigliato: buon equilibrio.',
              Quality.precise => 'Il più preciso, ma lento su questo telefono.',
            } +
                (snap.data == true
                    ? '  ✓ già scaricato'
                    : '  Download: ${_quality.size}'),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ),
        const SizedBox(height: 20),
        Text('Lingua dell\'audio', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              avatar: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Rileva da sola'),
              selected: _lang == 'auto',
              onSelected: (_) => setState(() => _lang = 'auto'),
            ),
            for (final c in tLangs.keys)
              ChoiceChip(
                label: Text('${langFlag(c)} ${langName(c)}'),
                selected: _lang == c,
                onSelected: (_) => setState(() => _lang = c),
              ),
          ],
        ),
        const SizedBox(height: 28),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Crea il testo', style: TextStyle(fontSize: 16)),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Tempo: circa quanto la durata dell\'audio (o un po\' di più). '
          'Tieni l\'app aperta.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      ],
    );
  }

  Widget _workingView() {
    final scheme = Theme.of(context).colorScheme;
    final el = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: _progress,
                    strokeWidth: 8,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                  Center(
                    child: Text(
                      _progress == null
                          ? '…'
                          : '${(_progress! * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(_stage,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text('Tempo trascorso ${fmtMs(el.inMilliseconds)}',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Text('Tieni l\'app aperta e lo schermo acceso.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _textView(Transcript t) {
    final scheme = Theme.of(context).colorScheme;
    final tr = _trLang == null ? null : t.translations[_trLang];
    return Column(
      children: [
        // intestazione: lingua rilevata + traduzione
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Chip(
                avatar: Text(t.lang.isEmpty ? '🌐' : langFlag(t.lang)),
                label: Text(t.lang.isEmpty ? 'Lingua ?' : langName(t.lang)),
              ),
              const SizedBox(width: 8),
              Text('${t.lines.length} frasi',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const Spacer(),
              if (_translating)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              PopupMenuButton<String>(
                tooltip: 'Traduzione',
                onSelected: (v) => _translate(v == 'none' ? null : v),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'none', child: Text('Senza traduzione')),
                  for (final c in ['it', 'en', 'fr', 'de', 'es', 'ar'])
                    if (c != t.lang)
                      PopupMenuItem(
                          value: c,
                          child: Text('${langFlag(c)}  ${langName(c)}')),
                ],
                child: Chip(
                  avatar: const Icon(Icons.translate, size: 18),
                  label: Text(_trLang == null
                      ? 'Traduci'
                      : '${langFlag(_trLang!)} ${langName(_trLang!)}'),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ScrollablePositionedList.builder(
            itemScrollController: _items,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: t.lines.length,
            itemBuilder: (_, i) => _lineTile(t, i, tr, scheme),
          ),
        ),
      ],
    );
  }

  Widget _lineTile(
      Transcript t, int i, List<String>? tr, ColorScheme scheme) {
    final l = t.lines[i];
    final current = i == _line;
    final past = _line >= 0 && i < _line;
    final w = current ? wordAt(l, _pos) : -1;
    final rtl = isRtl(t.lang);
    final base = TextStyle(
      fontSize: current ? 21 : 18,
      height: 1.45,
      color: current
          ? scheme.onSurface
          : past
              ? scheme.onSurface.withValues(alpha: 0.75)
              : scheme.onSurface.withValues(alpha: 0.6),
      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: current ? scheme.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        border: current
            ? Border.all(color: scheme.primary.withValues(alpha: 0.35))
            : null,
        boxShadow: current
            ? [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.18),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _seek(l.s, line: i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            crossAxisAlignment:
                rtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(fmtMs(l.s),
                      style: TextStyle(
                          fontSize: 12,
                          color: current
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  if (current && _loop) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.repeat_one, size: 14, color: scheme.primary),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text.rich(
                TextSpan(children: [
                  for (var k = 0; k < l.words.length; k++) ...[
                    if (k > 0) TextSpan(text: ' ', style: base),
                    TextSpan(
                      text: l.words[k].t,
                      style: k == w
                          ? base.copyWith(
                              color: scheme.onPrimary,
                              background: Paint()
                                ..color = scheme.primary
                                ..style = PaintingStyle.fill
                                ..strokeWidth = 6
                                ..strokeJoin = StrokeJoin.round,
                            )
                          : current && k > w
                              ? base.copyWith(
                                  color: scheme.onSurface
                                      .withValues(alpha: 0.5))
                              : base,
                    ),
                  ],
                ]),
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              ),
              if (tr != null && i < tr.length) ...[
                const SizedBox(height: 6),
                Text(
                  tr[i],
                  textDirection:
                      isRtl(_trLang!) ? TextDirection.rtl : TextDirection.ltr,
                  style: TextStyle(
                      fontSize: 15,
                      fontStyle: FontStyle.italic,
                      color: scheme.tertiary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _playerBar(Transcript t) {
    final scheme = Theme.of(context).colorScheme;
    final total = t.lines.isEmpty ? 1 : t.lines.last.e;
    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: _pos.clamp(0, total).toDouble(),
                max: total.toDouble(),
                onChanged: (v) => setState(() => _pos = v.round()),
                onChangeEnd: (v) => _seek(v.round()),
              ),
              Row(
                children: [
                  const SizedBox(width: 8),
                  Text(fmtMs(_pos),
                      style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()])),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Frase precedente',
                    icon: const Icon(Icons.skip_previous_rounded),
                    onPressed: () {
                      final i = (_line - 1).clamp(0, t.lines.length - 1);
                      _seek(t.lines[i].s, line: i);
                    },
                  ),
                  IconButton.filled(
                    iconSize: 34,
                    onPressed: _togglePlay,
                    icon: Icon(_playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                  ),
                  IconButton(
                    tooltip: 'Frase successiva',
                    icon: const Icon(Icons.skip_next_rounded),
                    onPressed: () {
                      final i = (_line + 1).clamp(0, t.lines.length - 1);
                      _seek(t.lines[i].s, line: i);
                    },
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Ripeti frase',
                    isSelected: _loop,
                    selectedIcon: Icon(Icons.repeat_one_on_rounded,
                        color: scheme.primary),
                    icon: const Icon(Icons.repeat_one_rounded),
                    onPressed: () => setState(() {
                      _loop = !_loop;
                      _loopLine = _line < 0 ? 0 : _line;
                    }),
                  ),
                  TextButton(
                    onPressed: _cycleSpeed,
                    child: Text('${_speed}x'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
