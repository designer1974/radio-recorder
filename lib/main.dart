import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'flags.dart';
import 'editor.dart';
import 'name_dialog.dart';
import 'rec_panel.dart';
import 'recorder.dart';
import 'settings_page.dart';
import 'transcript.dart';
import 'transcript_page.dart';

void main() => runApp(const RadioRecorderApp());

const _seed = Color(0xFF5B4BDB);

class RadioRecorderApp extends StatelessWidget {
  const RadioRecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radio Recorder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

/// Una registrazione salvata.
class Rec {
  final File file;
  final String name; // nome completo (con bandiera)
  final String? flag;
  final String title;
  final DateTime date;
  final Duration duration;
  final int size;

  Rec(this.file, this.name, this.flag, this.title, this.date, this.duration,
      this.size);

  static Rec fromFile(File f) {
    final stat = f.statSync();
    final base = f.path.split('/').last;
    final name = base.substring(0, base.length - 4);
    var ch = 2, rate = 48000;
    try {
      final raf = f.openSync();
      final h = raf.readSync(44);
      raf.closeSync();
      if (h.length == 44) {
        ch = h[22] | (h[23] << 8);
        rate = h[24] | (h[25] << 8) | (h[26] << 16) | (h[27] << 24);
      }
    } catch (_) {}
    final bytes = max(0, stat.size - 44);
    final ms = (ch > 0 && rate > 0) ? bytes * 1000 ~/ (rate * ch * 2) : 0;
    return Rec(f, name, leadingFlag(name), stripFlag(name), stat.modified,
        Duration(milliseconds: ms), stat.size);
  }
}

String _two(int n) => n.toString().padLeft(2, '0');
String _fmtDur(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '$m:${_two(s)}';
}

String _fmtDate(DateTime d) =>
    '${_two(d.day)}/${_two(d.month)}/${d.year} ${_two(d.hour)}:${_two(d.minute)}';
String _fmtSize(int b) => b > 1024 * 1024
    ? '${(b / 1024 / 1024).toStringAsFixed(1)} MB'
    : '${(b / 1024).toStringAsFixed(0)} KB';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppSettings _settings = AppSettings();
  Directory? _dir;
  List<Rec> _recs = [];
  String? _filter; // bandiera selezionata nel filtro

  final _player = AudioPlayer();
  String? _playing;

  bool _recording = false;
  DateTime? _startedAt;
  String? _tmpPath;
  Timer? _ticker;
  final List<double> _levels = [];

  @override
  void initState() {
    super.initState();
    _init();
    _player.onPlayerComplete.listen((_) => setState(() => _playing = null));
    Recorder.setOnStopped(_onStopped);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _settings = await AppSettings.load();
    final docs = await getApplicationDocumentsDirectory();
    _dir = Directory('${docs.path}/recordings');
    await _dir!.create(recursive: true);
    await _load();
  }

  Future<void> _load() async {
    final list = <Rec>[];
    for (final e in _dir!.listSync()) {
      final base = e.path.split('/').last;
      if (e is File && base.endsWith('.wav') && !base.startsWith('.')) {
        list.add(Rec.fromFile(e));
      }
    }
    list.sort((a, b) => b.date.compareTo(a.date));
    if (mounted) setState(() => _recs = list);
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  String _clean(String name) =>
      name.replaceAll(RegExp(r'[/\\:*?"<>|\n]'), '-').trim();

  String _uniquePath(String name, {String? except}) {
    var p = '${_dir!.path}/$name.wav';
    var i = 2;
    while (File(p).existsSync() && p != except) {
      p = '${_dir!.path}/$name ($i).wav';
      i++;
    }
    return p;
  }

  // ---------- Registrazione ----------

  Future<void> _toggleRecord() async {
    if (_recording) {
      try {
        await Recorder.stop();
      } catch (_) {}
      await _onStopped();
      return;
    }
    await _player.stop();
    setState(() => _playing = null);
    final tmp =
        '${_dir!.path}/.tmp_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      await Recorder.start(
        path: tmp,
        internal: _settings.internal,
        noise: _settings.noise,
      );
      setState(() {
        _recording = true;
        _startedAt = DateTime.now();
        _tmpPath = tmp;
      });
      _levels.clear();
      _ticker = Timer.periodic(const Duration(milliseconds: 80), (_) async {
        double v = 0;
        try {
          v = await Recorder.level();
        } catch (_) {}
        if (!mounted || !_recording) return;
        setState(() {
          _levels.add(v);
          if (_levels.length > 400) _levels.removeRange(0, 100);
        });
      });
    } on PlatformException catch (e) {
      _snack(e.message ?? 'Errore durante l\'avvio');
    }
  }

  Future<void> _onStopped() async {
    if (!_recording) return;
    _ticker?.cancel();
    setState(() => _recording = false);
    final tmp = File(_tmpPath!);
    if (!tmp.existsSync() || tmp.lengthSync() <= 44) {
      if (tmp.existsSync()) tmp.deleteSync();
      _snack('Registrazione vuota');
      return;
    }
    final d = DateTime.now();
    final def = 'Registrazione ${_two(d.day)}-${_two(d.month)} ${_two(d.hour)}.${_two(d.minute)}';
    if (!mounted) return;
    final res = await showNameDialog(context,
        title: def, autoFlag: _settings.autoFlag);
    final name = _clean(res?.fileName ?? def);
    await tmp.rename(_uniquePath(name.isEmpty ? def : name));
    await _load();
  }

  // ---------- Azioni sui file ----------

  Future<void> _play(Rec r) async {
    if (_recording) return;
    if (_playing == r.file.path) {
      await _player.stop();
      setState(() => _playing = null);
    } else {
      await _player.play(DeviceFileSource(r.file.path));
      setState(() => _playing = r.file.path);
    }
  }

  Future<void> _rename(Rec r) async {
    final res = await showNameDialog(context,
        title: r.title,
        flag: r.flag,
        autoFlag: _settings.autoFlag,
        heading: 'Rinomina');
    if (res == null) return;
    final name = _clean(res.fileName);
    if (name.isEmpty || name == r.name) return;
    if (_playing == r.file.path) {
      await _player.stop();
      _playing = null;
    }
    final dst = _uniquePath(name, except: r.file.path);
    await r.file.rename(dst);
    moveTranscript(r.file.path, dst);
    await _load();
  }

  Future<void> _edit(Rec r) async {
    if (_recording) return;
    await _player.stop();
    setState(() => _playing = null);
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => EditorPage(path: r.file.path, name: r.name)),
    );
    if (changed == true) await _load();
  }

  Future<void> _text(Rec r) async {
    if (_recording) return;
    await _player.stop();
    setState(() => _playing = null);
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => TranscriptPage(path: r.file.path, name: r.name)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _delete(Rec r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminare?'),
        content: Text('"${r.name}" verrà eliminata definitivamente.'),
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
    if (_playing == r.file.path) {
      await _player.stop();
      _playing = null;
    }
    await r.file.delete();
    deleteTranscript(r.file.path);
    await _load();
  }

  Future<void> _share(Rec r) async {
    await Share.shareXFiles([XFile(r.file.path, mimeType: 'audio/wav')],
        text: r.name);
  }

  // ---------- Interfaccia ----------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final flags = _recs.map((r) => r.flag).whereType<String>().toSet().toList();
    final shown =
        _filter == null ? _recs : _recs.where((r) => r.flag == _filter).toList();
    final elapsed = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio Recorder'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Impostazioni',
            onPressed: _recording
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => SettingsPage(settings: _settings)),
                    ).then((_) => setState(() {})),
          ),
        ],
      ),
      body: Column(
        children: [
          if (flags.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: const Text('Tutte'),
                      selected: _filter == null,
                      onSelected: (_) => setState(() => _filter = null),
                    ),
                  ),
                  for (final f in flags)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f, style: const TextStyle(fontSize: 18)),
                        selected: _filter == f,
                        onSelected: (_) => setState(
                            () => _filter = _filter == f ? null : f),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.graphic_eq,
                              size: 64, color: scheme.primary),
                          const SizedBox(height: 12),
                          Text(
                            _recording
                                ? 'Registrazione in corso…\nDopo, nel menu ⋮ scegli «Testo» per vedere tutto quello che dice la radio.'
                                : 'Nessuna registrazione.\nApri la tua radio e premi Registra.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 120),
                    itemCount: shown.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 72),
                    itemBuilder: (_, i) => _tile(shown[i], scheme),
                  ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _recording
          ? null
          : FloatingActionButton.extended(
              onPressed: _dir == null ? null : _toggleRecord,
              icon: const Icon(Icons.fiber_manual_record, color: Colors.red),
              label: Text(
                  'Registra · ${_settings.internal ? 'interno' : 'microfono'}'),
            ),
      bottomNavigationBar: _recording
          ? RecPanel(
              elapsed: elapsed,
              levels: _levels,
              internal: _settings.internal,
              onStop: _toggleRecord,
            )
          : null,
    );
  }

  Widget _tile(Rec r, ColorScheme scheme) {
    final playing = _playing == r.file.path;
    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: scheme.primaryContainer,
        child: r.flag != null
            ? Text(r.flag!, style: const TextStyle(fontSize: 24))
            : Icon(Icons.audiotrack, color: scheme.onPrimaryContainer),
      ),
      title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(
            text:
                '${_fmtDate(r.date)} · ${_fmtDur(r.duration)} · ${_fmtSize(r.size)}'),
        if (hasTranscript(r.file.path))
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.subtitles, size: 16, color: scheme.primary),
            ),
          ),
      ])),
      onTap: () => _play(r),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(playing
                ? Icons.stop_circle_outlined
                : Icons.play_circle_outline),
            iconSize: 32,
            color: scheme.primary,
            onPressed: () => _play(r),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'text') _text(r);
              if (v == 'edit') _edit(r);
              if (v == 'rename') _rename(r);
              if (v == 'share') _share(r);
              if (v == 'delete') _delete(r);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'text',
                  child: ListTile(
                      leading: Icon(Icons.subtitles_outlined),
                      title: Text('Testo (trascrizione)'))),
              PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                      leading: Icon(Icons.content_cut),
                      title: Text('Modifica / Taglia'))),
              PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Rinomina'))),
              PopupMenuItem(
                  value: 'share',
                  child: ListTile(
                      leading: Icon(Icons.share_outlined),
                      title: Text('Condividi (WhatsApp, email…)'))),
              PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Elimina'))),
            ],
          ),
        ],
      ),
    );
  }
}
