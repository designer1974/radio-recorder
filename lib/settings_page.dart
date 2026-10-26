import 'package:flutter/material.dart';
import 'recorder.dart';

class SettingsPage extends StatefulWidget {
  final AppSettings settings;
  const SettingsPage({super.key, required this.settings});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get s => widget.settings;

  void _set(VoidCallback f) {
    setState(f);
    s.save();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Sorgente audio', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: true,
                icon: Icon(Icons.speaker_phone),
                label: Text('Interno'),
              ),
              ButtonSegment(
                value: false,
                icon: Icon(Icons.mic),
                label: Text('Microfono'),
              ),
            ],
            selected: {s.internal},
            onSelectionChanged: (v) => _set(() => s.internal = v.first),
          ),
          const SizedBox(height: 6),
          Text(
            s.internal
                ? 'Registra il suono delle altre app (es. Radio Garden) in alta qualità, stereo 48 kHz.'
                : 'Registra dal microfono del telefono.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Riduzione rumore'),
            subtitle: Text(s.internal
                ? 'Toglie ronzii bassi e fruscio nei silenzi'
                : 'Usa il filtro anti-rumore del telefono'),
            value: s.noise,
            onChanged: (v) => _set(() => s.noise = v),
          ),
          const SizedBox(height: 8),
          Text('Qualità e spazio', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final q in AudioQuality.values)
            RadioListTile<AudioQuality>(
              contentPadding: EdgeInsets.zero,
              value: q,
              groupValue: s.quality,
              title: Text(q == AudioQuality.voice
                  ? '${q.label}  ★ consigliata'
                  : q.label),
              subtitle: Text(q.info),
              onChanged: (v) => _set(() => s.quality = v!),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Bandiera automatica'),
            subtitle: const Text(
                'Riconosce il paese nel titolo (es. "Fox News usa" → 🇺🇸)'),
            value: s.autoFlag,
            onChanged: (v) => _set(() => s.autoFlag = v),
          ),
          const SizedBox(height: 16),
          Card(
            color: scheme.surfaceContainerHighest,
            elevation: 0,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Nota: l\'audio interno funziona da Android 10 in poi. '
                'Le app con contenuti protetti (es. Netflix, Spotify) '
                'possono bloccare la registrazione: in quel caso il file resta muto.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
