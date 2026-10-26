import 'dart:math';

import 'package:flutter/material.dart';

String fmtHms(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// Pannello mostrato durante la registrazione:
/// timer grande ore:minuti:secondi, onde del suono in tempo reale,
/// misuratore di volume e pulsante Ferma.
class RecPanel extends StatefulWidget {
  final Duration elapsed;
  final List<double> levels; // storico livelli 0..1 (il più recente in fondo)
  final bool internal;
  final VoidCallback onStop;

  const RecPanel({
    super.key,
    required this.elapsed,
    required this.levels,
    required this.internal,
    required this.onStop,
  });

  @override
  State<RecPanel> createState() => _RecPanelState();
}

class _RecPanelState extends State<RecPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lv = widget.levels;
    final cur = lv.isEmpty ? 0.0 : lv.last;
    final db = cur <= 0.00003 ? -90.0 : 20 * log(cur) / ln10;
    // silenzio negli ultimi ~3 secondi?
    final recent = lv.length >= 40 ? lv.sublist(lv.length - 40) : <double>[];
    final silent = recent.isNotEmpty && recent.every((v) => v < 0.004);

    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  FadeTransition(
                    opacity: _blink,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('REC',
                      style: TextStyle(
                          color: Colors.red.shade400,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2)),
                  const SizedBox(width: 8),
                  Icon(widget.internal ? Icons.speaker_phone : Icons.mic,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(widget.internal ? 'Audio interno' : 'Microfono',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  Text(
                    db <= -60 ? '−∞ dB' : '${db.toStringAsFixed(0)} dB',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                fmtHms(widget.elapsed),
                style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 2,
                  color: scheme.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final l in const ['ore', 'min', 'sec'])
                    SizedBox(
                      width: 78,
                      child: Text(l,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 70,
                width: double.infinity,
                child: CustomPaint(
                  painter: _WavePainter(lv, scheme.primary),
                ),
              ),
              const SizedBox(height: 10),
              _Meter(level: cur),
              if (silent) ...[
                const SizedBox(height: 8),
                Text(
                  'Nessun suono: la radio sta suonando? (alcune app bloccano la registrazione)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  onPressed: widget.onStop,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Ferma e salva',
                      style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Onde che scorrono: ogni barra è un livello recente.
class _WavePainter extends CustomPainter {
  final List<double> levels;
  final Color color;
  _WavePainter(this.levels, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 3.0, gap = 2.0;
    final n = (size.width / (barW + gap)).floor();
    final mid = size.height / 2;
    final p = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barW;
    for (var i = 0; i < n; i++) {
      final idx = levels.length - n + i;
      final v = idx >= 0 ? levels[idx] : 0.0;
      final h = max(1.5, sqrt(v.clamp(0.0, 1.0)) * mid);
      final x = i * (barW + gap) + barW / 2;
      p.color = color.withValues(alpha: idx >= 0 ? 1 : 0.25);
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), p);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}

/// Barra del volume verde / giallo / rosso.
class _Meter extends StatelessWidget {
  final double level;
  const _Meter({required this.level});

  @override
  Widget build(BuildContext context) {
    final v = sqrt(level.clamp(0.0, 1.0));
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 10,
        child: Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [
                  Color(0xFF2ECC71),
                  Color(0xFF2ECC71),
                  Color(0xFFF1C40F),
                  Color(0xFFE74C3C),
                ], stops: [0, 0.6, 0.85, 1]),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 1 - v,
                heightFactor: 1,
                child: Container(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
