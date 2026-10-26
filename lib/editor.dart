import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'recorder.dart';
import 'transcript.dart';
import 'wav_edit.dart';

/// Editor avanzato: forma d'onda con zoom, selezione,
/// taglio con unione automatica, annulla/ripeti, anteprima e salvataggio.
class EditorPage extends StatefulWidget {
  final String path;
  final String name;
  final AudioQuality quality; // per ricomprimere i file M4A
  const EditorPage(
      {super.key,
      required this.path,
      required this.name,
      this.quality = AudioQuality.voice});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

enum _Drag { none, newSel, edgeA, edgeB, zoom }

class _EditorPageState extends State<EditorPage> {
  WavInfo _info = WavInfo(2, 48000, 44, 0);
  late final String _src; // WAV su cui si lavora (decodificato se M4A)
  double? _decodeProgress;
  Uint8List? _peaks; // forma d'onda originale
  List<Seg> _orig = const [];
  List<Seg> _segs = const [];
  Uint8List _ep = Uint8List(0); // forma d'onda modificata
  final _undo = <List<Seg>>[];
  final _redo = <List<Seg>>[];

  // vista (in blocchi da 10 ms)
  double _vStart = 0, _vSpan = 1;
  int _cursor = 0;
  int? _selA, _selB;

  // gesti
  _Drag _drag = _Drag.none;
  int _anchor = 0;
  double _zStartSpan = 1, _zFocalBlock = 0;
  double _width = 1;

  // riproduzione
  final _player = AudioPlayer();
  late final String _previewPath;
  List<Seg>? _previewFor;
  bool _playing = false;
  int? _playEnd;
  StreamSubscription? _posSub, _doneSub;

  String? _busy;
  bool _saved = false;

  int get _len => _ep.length;
  bool get _hasSel => _selA != null && _selB != null && _selB! > _selA!;
  bool get _dirty =>
      !(_segs.length == _orig.length && listEquals(_segs, _orig));

  @override
  void initState() {
    super.initState();
    final dir = File(widget.path).parent.path;
    _src = isCompressed(widget.path) ? '$dir/.edit_src.wav' : widget.path;
    _previewPath = '$dir/.preview.wav';
    _posSub = _player.onPositionChanged.listen(_onPos);
    _doneSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
    _load();
  }

  Future<void> _load() async {
    if (_src != widget.path) {
      try {
        await Recorder.toWav(widget.path, _src,
            progress: (v) => mounted ? setState(() => _decodeProgress = v) : null);
      } catch (e) {
        if (mounted) {
          _snack('Impossibile aprire il file: $e');
          Navigator.pop(context, false);
        }
        return;
      }
    }
    final path = _src;
    final info = readWavInfo(path);
    final p = await peaksInBackground(path);
    if (!mounted) return;
    setState(() {
      _info = info;
      _orig = info.blocks > 0 ? [Seg(0, info.blocks)] : [];
      _segs = _orig;
      _peaks = p;
      _rebuild();
      _fit();
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _doneSub?.cancel();
    _player.dispose();
    for (final f in [_previewPath, if (_src != widget.path) _src]) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  // ---------- utilità ----------

  void _rebuild() => _ep = editedPeaks(_peaks!, _segs);

  void _fit() {
    _vStart = 0;
    _vSpan = max(1, _len).toDouble();
  }

  double get _minSpan => min(max(1, _len).toDouble(), 50); // 0,5 s

  void _clampView() {
    _vSpan = _vSpan.clamp(_minSpan, max(1, _len).toDouble());
    _vStart = _vStart.clamp(0, max(0, _len - _vSpan)).toDouble();
  }

  int _xToBlock(double x) =>
      (_vStart + x / _width * _vSpan).round().clamp(0, _len);
  double _blockToX(num b) => (b - _vStart) / _vSpan * _width;

  String _fmt(int blocks) {
    final ms = (blocks * _info.blockMs).round();
    final h = ms ~/ 3600000;
    final m = (ms ~/ 60000) % 60;
    final s = (ms ~/ 1000) % 60;
    final d = (ms ~/ 100) % 10;
    final ss = s.toString().padLeft(2, '0');
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:$ss.$d'
        : '$m:$ss.$d';
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ---------- modifiche ----------

  Future<void> _apply(List<Seg> next, {int? cursor}) async {
    if (_playing) await _pause();
    if (totalLen(next) == 0) {
      _snack('Non puoi togliere tutto l\'audio');
      return;
    }
    setState(() {
      _undo.add(_segs);
      if (_undo.length > 50) _undo.removeAt(0);
      _redo.clear();
      _segs = next;
      _rebuild();
      _selA = _selB = null;
      _cursor = (cursor ?? _cursor).clamp(0, _len);
      _clampView();
    });
  }

  void _cutSel() {
    if (!_hasSel) return;
    final a = _selA!, b = _selB!;
    _apply(cut(_segs, a, b), cursor: a);
    _snack('Tagliato ${_fmt(b - a)} e unito');
  }

  void _keepSel() {
    if (!_hasSel) return;
    _apply(keep(_segs, _selA!, _selB!), cursor: 0).then((_) {
      if (mounted) setState(_fit);
    });
  }

  void _cutBefore() {
    if (_cursor <= 0) return;
    _apply(cut(_segs, 0, _cursor), cursor: 0);
  }

  void _cutAfter() {
    if (_cursor >= _len) return;
    _apply(cut(_segs, _cursor, _len), cursor: _cursor);
  }

  void _selectAll() => setState(() {
        _selA = 0;
        _selB = _len;
      });

  void _doUndo() {
    if (_undo.isEmpty) return;
    _pause();
    setState(() {
      _redo.add(_segs);
      _segs = _undo.removeLast();
      _rebuild();
      _selA = _selB = null;
      _cursor = _cursor.clamp(0, _len);
      _clampView();
    });
  }

  void _doRedo() {
    if (_redo.isEmpty) return;
    _pause();
    setState(() {
      _undo.add(_segs);
      _segs = _redo.removeLast();
      _rebuild();
      _selA = _selB = null;
      _cursor = _cursor.clamp(0, _len);
      _clampView();
    });
  }

  /// Sposta un bordo della selezione di [d] blocchi (precisione 0,1 s).
  void _nudge(bool start, int d) {
    if (!_hasSel) return;
    setState(() {
      if (start) {
        _selA = (_selA! + d).clamp(0, _selB! - 1);
      } else {
        _selB = (_selB! + d).clamp(_selA! + 1, _len);
      }
    });
  }

  void _zoom(double f) => setState(() {
        final c = _hasSel
            ? (_selA! + _selB!) / 2
            : (_cursor >= _vStart && _cursor <= _vStart + _vSpan
                ? _cursor.toDouble()
                : _vStart + _vSpan / 2);
        _vSpan = _vSpan / f;
        _vStart = c - _vSpan / 2;
        _clampView();
      });

  void _zoomToSel() {
    if (!_hasSel) return;
    setState(() {
      final pad = (_selB! - _selA!) * 0.1;
      _vStart = _selA! - pad;
      _vSpan = (_selB! - _selA!) + 2 * pad;
      _clampView();
    });
  }

  // ---------- riproduzione ----------

  Future<void> _ensurePreview() async {
    if (identical(_previewFor, _segs)) return;
    setState(() => _busy = 'Preparo l\'anteprima…');
    final segs = _segs, src = _src, dst = _previewPath;
    await _player.release();
    await renderInBackground(src, segs, dst);
    await _player.setSource(DeviceFileSource(dst));
    _previewFor = segs;
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _play({bool selection = false}) async {
    if (_playing) {
      await _pause();
      if (!selection) return;
    }
    if (_len == 0) return;
    await _ensurePreview();
    var from = selection && _hasSel ? _selA! : _cursor;
    if (from >= _len - 1) from = 0;
    _playEnd = selection && _hasSel ? _selB : null;
    await _player.resume();
    await _player.seek(Duration(milliseconds: (from * _info.blockMs).round()));
    if (mounted) {
      setState(() {
        _playing = true;
        _cursor = from;
      });
    }
  }

  Future<void> _pause() async {
    await _player.pause();
    if (mounted) setState(() => _playing = false);
  }

  void _onPos(Duration p) {
    if (!_playing || !mounted) return;
    final b = (p.inMilliseconds / _info.blockMs).round().clamp(0, _len);
    setState(() {
      _cursor = b;
      // la vista segue il cursore
      if (b < _vStart || b > _vStart + _vSpan) {
        _vStart = b - _vSpan * 0.1;
        _clampView();
      }
    });
    if (_playEnd != null && b >= _playEnd!) {
      _pause();
      setState(() => _cursor = _playEnd!);
    }
  }

  void _seekTo(int b) {
    setState(() => _cursor = b);
    if (_playing) {
      _playEnd = null;
      _player.seek(Duration(milliseconds: (b * _info.blockMs).round()));
    }
  }

  // ---------- salvataggio ----------

  Future<void> _save() async {
    if (!_dirty) {
      _snack('Nessuna modifica da salvare');
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Salva modifiche'),
        content: Text('Nuova durata: ${_fmt(_len)}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'copy'),
              child: const Text('Salva come copia')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'replace'),
              child: const Text('Sostituisci')),
        ],
      ),
    );
    if (choice == null) return;
    await _pause();
    await _player.release();
    _previewFor = null;
    setState(() => _busy = 'Salvataggio…');
    final segs = _segs, src = _src, orig = widget.path;
    final dir = File(orig).parent.path;
    final comp = isCompressed(orig);
    final ext = comp ? 'm4a' : 'wav';
    // scrive il risultato in [dst]: WAV diretto, oppure WAV temporaneo -> M4A
    Future<void> write(String dst) async {
      if (!comp) {
        await renderInBackground(src, segs, dst);
        return;
      }
      final wav = '$dir/.save_tmp.wav';
      await renderInBackground(src, segs, wav);
      setState(() => _busy = 'Comprimo…');
      try {
        await Recorder.toM4a(wav, dst, widget.quality);
      } finally {
        try {
          File(wav).deleteSync();
        } catch (_) {}
      }
    }

    try {
      if (choice == 'replace') {
        final tmp = '$dir/.save_tmp2.$ext';
        await write(tmp);
        await File(orig).delete();
        await File(tmp).rename(orig);
        deleteTranscript(orig); // l'audio è cambiato: il testo va rifatto
      } else {
        var dst = '$dir/${widget.name} (tagliata).$ext';
        var i = 2;
        while (File(dst).existsSync()) {
          dst = '$dir/${widget.name} (tagliata $i).$ext';
          i++;
        }
        await write(dst);
      }
      _saved = true;
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = null);
        _snack('Errore nel salvataggio: $e');
      }
    }
  }

  Future<bool> _confirmExit() async {
    if (!_dirty || _saved) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Uscire senza salvare?'),
        content: const Text('Le modifiche andranno perse.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Resta')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Esci')),
        ],
      ),
    );
    return r == true;
  }

  // ---------- gesti sulla forma d'onda ----------

  void _onScaleStart(ScaleStartDetails d) {
    if (d.pointerCount >= 2) {
      _startZoom(d.localFocalPoint.dx);
      return;
    }
    final x = d.localFocalPoint.dx;
    if (_hasSel && (x - _blockToX(_selA!)).abs() < 28) {
      _drag = _Drag.edgeA;
    } else if (_hasSel && (x - _blockToX(_selB!)).abs() < 28) {
      _drag = _Drag.edgeB;
    } else {
      _drag = _Drag.newSel;
      _anchor = _xToBlock(x);
      setState(() {
        _selA = _anchor;
        _selB = _anchor;
      });
    }
  }

  void _startZoom(double fx) {
    _drag = _Drag.zoom;
    _zStartSpan = _vSpan;
    _zFocalBlock = _vStart + fx / _width * _vSpan;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final x = d.localFocalPoint.dx;
    if (d.pointerCount >= 2) {
      if (_drag != _Drag.zoom) _startZoom(x);
      setState(() {
        _vSpan = (_zStartSpan / d.scale)
            .clamp(_minSpan, max(1, _len).toDouble());
        _vStart = _zFocalBlock - x / _width * _vSpan;
        _clampView();
      });
      return;
    }
    if (_drag == _Drag.zoom || _drag == _Drag.none) return;
    // scorrimento automatico vicino ai bordi
    if (x < 16) {
      _vStart -= _vSpan * 0.02;
    } else if (x > _width - 16) {
      _vStart += _vSpan * 0.02;
    }
    _clampView();
    final t = _xToBlock(x.clamp(0, _width));
    setState(() {
      switch (_drag) {
        case _Drag.edgeA:
          _selA = t;
        case _Drag.edgeB:
          _selB = t;
        case _Drag.newSel:
          _selA = min(_anchor, t);
          _selB = max(_anchor, t);
        default:
          break;
      }
      if (_selA! > _selB!) {
        final tmp = _selA;
        _selA = _selB;
        _selB = tmp;
        _drag = _drag == _Drag.edgeA ? _Drag.edgeB : _Drag.edgeA;
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_drag == _Drag.newSel || _drag == _Drag.edgeA || _drag == _Drag.edgeB) {
      if (_hasSel && _selB! - _selA! >= 2) {
        if (!_playing) setState(() => _cursor = _selA!);
      } else {
        setState(() => _selA = _selB = null);
      }
    }
    _drag = _Drag.none;
  }

  // ---------- interfaccia ----------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_dirty || _saved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _confirmExit()) {
          _saved = true;
          nav.pop(false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
                tooltip: 'Annulla',
                onPressed: _undo.isEmpty ? null : _doUndo,
                icon: const Icon(Icons.undo)),
            IconButton(
                tooltip: 'Ripeti',
                onPressed: _redo.isEmpty ? null : _doRedo,
                icon: const Icon(Icons.redo)),
            IconButton(
                tooltip: 'Salva',
                onPressed: _dirty && _busy == null ? _save : null,
                icon: const Icon(Icons.save_outlined)),
          ],
        ),
        body: _peaks == null
            ? Center(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_decodeProgress == null
                      ? 'Analizzo l\'audio…'
                      : 'Preparo l\'audio… ${(_decodeProgress! * 100).round()}%'),
                ],
              ))
            : Stack(
                children: [
                  _body(scheme),
                  if (_busy != null)
                    Container(
                      color: Colors.black38,
                      alignment: Alignment.center,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(width: 16),
                              Text(_busy!),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    final mono = const TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        physics: const ClampingScrollPhysics(),
        children: [
          // tempo
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_fmt(_cursor),
                  style: mono.copyWith(
                      fontSize: 34,
                      fontWeight: FontWeight.w300,
                      color: scheme.primary)),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('/ ${_fmt(_len)}',
                    style: mono.copyWith(color: scheme.onSurfaceVariant)),
              ),
              const Spacer(),
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      'originale ${_fmt(_info.blocks)}',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // forma d'onda
          LayoutBuilder(builder: (ctx, c) {
            _width = c.maxWidth;
            return GestureDetector(
              onTapUp: (d) {
                setState(() => _selA = _selB = null);
                _seekTo(_xToBlock(d.localPosition.dx));
              },
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: 230,
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  child: CustomPaint(
                    size: Size(c.maxWidth, 230),
                    painter: _WavePainter(
                      ep: _ep,
                      vStart: _vStart,
                      vSpan: _vSpan,
                      selA: _hasSel ? _selA : null,
                      selB: _hasSel ? _selB : null,
                      cursor: _cursor,
                      joins: joins(_segs),
                      blockMs: _info.blockMs,
                      wave: scheme.primary,
                      selWave: scheme.tertiary,
                      selFill: scheme.tertiary.withValues(alpha: 0.18),
                      text: scheme.onSurfaceVariant,
                      join: Colors.orange,
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          // panoramica
          LayoutBuilder(builder: (ctx, c) {
            void go(double x) => setState(() {
                  _vStart = x / c.maxWidth * _len - _vSpan / 2;
                  _clampView();
                });
            return GestureDetector(
              onPanDown: (d) => go(d.localPosition.dx),
              onPanUpdate: (d) => go(d.localPosition.dx),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 36,
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  child: CustomPaint(
                    size: Size(c.maxWidth, 36),
                    painter: _OverviewPainter(
                      ep: _ep,
                      vStart: _vStart,
                      vSpan: _vSpan,
                      cursor: _cursor,
                      wave: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                      view: scheme.primary,
                    ),
                  ),
                ),
              ),
            );
          }),
          // zoom
          Row(
            children: [
              IconButton(
                  tooltip: 'Riduci',
                  onPressed: () => _zoom(0.5),
                  icon: const Icon(Icons.zoom_out)),
              IconButton(
                  tooltip: 'Ingrandisci',
                  onPressed: () => _zoom(2),
                  icon: const Icon(Icons.zoom_in)),
              IconButton(
                  tooltip: 'Tutto',
                  onPressed: () => setState(_fit),
                  icon: const Icon(Icons.fit_screen_outlined)),
              if (_hasSel)
                IconButton(
                    tooltip: 'Zoom sulla selezione',
                    onPressed: _zoomToSel,
                    icon: const Icon(Icons.center_focus_strong_outlined)),
              const Spacer(),
              Text('visibili ${_fmt(_vSpan.round())}',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          // riproduzione
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                  tooltip: 'Inizio',
                  onPressed: () => _seekTo(0),
                  icon: const Icon(Icons.skip_previous_rounded)),
              IconButton(
                  tooltip: '-5 s',
                  onPressed: () =>
                      _seekTo(max(0, _cursor - (5000 / _info.blockMs).round())),
                  icon: const Icon(Icons.replay_5)),
              const SizedBox(width: 8),
              FloatingActionButton(
                heroTag: 'play',
                onPressed: () => _play(),
                child: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 34),
              ),
              const SizedBox(width: 8),
              IconButton(
                  tooltip: '+5 s',
                  onPressed: () => _seekTo(
                      min(_len, _cursor + (5000 / _info.blockMs).round())),
                  icon: const Icon(Icons.forward_5)),
              IconButton(
                  tooltip: 'Ascolta selezione',
                  onPressed: _hasSel ? () => _play(selection: true) : null,
                  icon: const Icon(Icons.play_circle_outline)),
            ],
          ),
          const SizedBox(height: 8),
          // selezione
          Card(
            elevation: 0,
            color: scheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: _hasSel
                  ? Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.select_all, size: 18, color: scheme.tertiary),
                            const SizedBox(width: 6),
                            Text('Selezione ${_fmt(_selB! - _selA!)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const Spacer(),
                            TextButton(
                                onPressed: () =>
                                    setState(() => _selA = _selB = null),
                                child: const Text('Deseleziona')),
                          ],
                        ),
                        _nudgeRow('Inizio', _selA!, true, mono),
                        _nudgeRow('Fine', _selB!, false, mono),
                      ],
                    )
                  : Row(
                      children: [
                        Icon(Icons.touch_app_outlined,
                            size: 18, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Trascina sulla forma d\'onda per selezionare. '
                            'Tocca per spostare il cursore. Due dita per lo zoom.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          // azioni
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _hasSel ? _cutSel : null,
                style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError),
                icon: const Icon(Icons.content_cut),
                label: const Text('Taglia selezione e unisci'),
              ),
              FilledButton.tonalIcon(
                onPressed: _hasSel ? _keepSel : null,
                icon: const Icon(Icons.crop),
                label: const Text('Tieni solo selezione'),
              ),
              OutlinedButton.icon(
                onPressed: _cursor > 0 ? _cutBefore : null,
                icon: const Icon(Icons.first_page),
                label: const Text('Taglia prima del cursore'),
              ),
              OutlinedButton.icon(
                onPressed: _cursor < _len ? _cutAfter : null,
                icon: const Icon(Icons.last_page),
                label: const Text('Taglia dopo il cursore'),
              ),
              OutlinedButton.icon(
                onPressed: _len > 0 ? _selectAll : null,
                icon: const Icon(Icons.select_all),
                label: const Text('Seleziona tutto'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (joins(_segs).isNotEmpty)
            Row(
              children: [
                Container(width: 3, height: 14, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${joins(_segs).length} punti uniti automaticamente (dissolvenza 5 ms, senza click)',
                    style:
                        TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _nudgeRow(String label, int value, bool start, TextStyle mono) {
    final step = (100 / _info.blockMs).round(); // 0,1 s
    return Row(
      children: [
        SizedBox(width: 52, child: Text(label)),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _nudge(start, -10 * step),
            icon: const Icon(Icons.keyboard_double_arrow_left)),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _nudge(start, -step),
            icon: const Icon(Icons.chevron_left)),
        Expanded(
            child: Text(_fmt(value),
                textAlign: TextAlign.center,
                style: mono.copyWith(fontSize: 16))),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _nudge(start, step),
            icon: const Icon(Icons.chevron_right)),
        IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _nudge(start, 10 * step),
            icon: const Icon(Icons.keyboard_double_arrow_right)),
      ],
    );
  }
}

// ---------- disegno ----------

int _maxIn(Uint8List ep, int a, int b) {
  var m = 0;
  final e = min(b, ep.length);
  for (var i = max(0, a); i < e; i++) {
    if (ep[i] > m) m = ep[i];
  }
  return m;
}

class _WavePainter extends CustomPainter {
  final Uint8List ep;
  final double vStart, vSpan, blockMs;
  final int? selA, selB;
  final int cursor;
  final List<int> joins;
  final Color wave, selWave, selFill, text, join;

  _WavePainter({
    required this.ep,
    required this.vStart,
    required this.vSpan,
    required this.selA,
    required this.selB,
    required this.cursor,
    required this.joins,
    required this.blockMs,
    required this.wave,
    required this.selWave,
    required this.selFill,
    required this.text,
    required this.join,
  });

  double _x(num b, Size s) => (b - vStart) / vSpan * s.width;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 22.0; // spazio per il righello
    final h = size.height - top;
    final mid = top + h / 2;

    // selezione
    if (selA != null && selB != null) {
      final x0 = _x(selA!, size), x1 = _x(selB!, size);
      canvas.drawRect(Rect.fromLTRB(x0, top, x1, size.height),
          Paint()..color = selFill);
    }

    // righello del tempo
    _ruler(canvas, size, top);

    // linea centrale
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid),
        Paint()..color = text.withValues(alpha: 0.25));

    // forma d'onda
    const step = 2.0;
    final p = Paint()..strokeWidth = 1.4;
    for (double x = 0; x < size.width; x += step) {
      final a = (vStart + x / size.width * vSpan).floor();
      final b = max(a + 1, (vStart + (x + step) / size.width * vSpan).floor());
      if (a >= ep.length) break;
      final v = _maxIn(ep, a, b) / 255.0;
      final y = max(0.8, sqrt(v) * (h / 2 - 4));
      final inSel = selA != null && a >= selA! && a < selB!;
      p.color = inSel ? selWave : wave;
      canvas.drawLine(Offset(x, mid - y), Offset(x, mid + y), p);
    }

    // punti di unione
    final jp = Paint()
      ..color = join
      ..strokeWidth = 2;
    for (final j in joins) {
      final x = _x(j, size);
      if (x < 0 || x > size.width) continue;
      for (double y = top; y < size.height; y += 8) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 4), jp);
      }
    }

    // maniglie della selezione
    if (selA != null && selB != null) {
      final hp = Paint()
        ..color = selWave
        ..strokeWidth = 2;
      for (final b in [selA!, selB!]) {
        final x = _x(b, size);
        canvas.drawLine(Offset(x, top), Offset(x, size.height), hp);
        canvas.drawCircle(Offset(x, top + 8), 7, hp);
        canvas.drawCircle(Offset(x, size.height - 8), 7, hp);
      }
    }

    // cursore
    final cx = _x(cursor, size);
    if (cx >= 0 && cx <= size.width) {
      final cp = Paint()
        ..color = Colors.red
        ..strokeWidth = 2;
      canvas.drawLine(Offset(cx, top - 4), Offset(cx, size.height), cp);
      final path = Path()
        ..moveTo(cx - 6, top - 10)
        ..lineTo(cx + 6, top - 10)
        ..lineTo(cx, top - 2)
        ..close();
      canvas.drawPath(path, Paint()..color = Colors.red);
    }
  }

  void _ruler(Canvas canvas, Size size, double top) {
    const steps = [
      0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600
    ];
    final secPerPx = vSpan * blockMs / 1000 / size.width;
    var stepS = 3600.0;
    for (final s in steps) {
      if (s / secPerPx >= 70) {
        stepS = s.toDouble();
        break;
      }
    }
    final startS = vStart * blockMs / 1000;
    final endS = (vStart + vSpan) * blockMs / 1000;
    var t = (startS / stepS).ceil() * stepS;
    final tp = Paint()..color = text.withValues(alpha: 0.5);
    while (t <= endS) {
      final x = (t - startS) / secPerPx;
      canvas.drawLine(Offset(x, top - 6), Offset(x, top), tp);
      final label = _label(t, stepS);
      final para = TextPainter(
        text: TextSpan(
            text: label, style: TextStyle(color: text, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      para.paint(canvas, Offset(x + 3, 2));
      t += stepS;
    }
  }

  String _label(double t, double step) {
    final h = t ~/ 3600;
    final m = (t ~/ 60) % 60;
    final s = t % 60;
    final ss = step < 1
        ? s.toStringAsFixed(1).padLeft(4, '0')
        : s.floor().toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _OverviewPainter extends CustomPainter {
  final Uint8List ep;
  final double vStart, vSpan;
  final int cursor;
  final Color wave, view;

  _OverviewPainter({
    required this.ep,
    required this.vStart,
    required this.vSpan,
    required this.cursor,
    required this.wave,
    required this.view,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (ep.isEmpty) return;
    final n = ep.length;
    final mid = size.height / 2;
    final p = Paint()
      ..color = wave
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 2) {
      final a = (x / size.width * n).floor();
      final b = max(a + 1, ((x + 2) / size.width * n).floor());
      final v = sqrt(_maxIn(ep, a, b) / 255.0) * (mid - 2);
      canvas.drawLine(Offset(x, mid - v), Offset(x, mid + v), p);
    }
    final x0 = vStart / n * size.width;
    final x1 = (vStart + vSpan) / n * size.width;
    final r = Rect.fromLTRB(x0, 1, max(x0 + 4, x1), size.height - 1);
    canvas.drawRect(r, Paint()..color = view.withValues(alpha: 0.15));
    canvas.drawRect(
        r,
        Paint()
          ..color = view
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final cx = cursor / n * size.width;
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height),
        Paint()
          ..color = Colors.red
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}
