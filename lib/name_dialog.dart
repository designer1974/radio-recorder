import 'package:flutter/material.dart';
import 'flags.dart';

class NameResult {
  final String? flag;
  final String title;
  NameResult(this.flag, this.title);
  String get fileName => flag == null ? title : '$flag $title';
}

/// Finestra per dare (o cambiare) il nome a una registrazione,
/// con la bandiera suggerita mentre scrivi.
Future<NameResult?> showNameDialog(
  BuildContext context, {
  required String title,
  String? flag,
  bool autoFlag = true,
  String heading = 'Salva registrazione',
}) {
  return showDialog<NameResult>(
    context: context,
    builder: (_) => _NameDialog(
      title: title,
      flag: flag,
      autoFlag: autoFlag,
      heading: heading,
    ),
  );
}

class _NameDialog extends StatefulWidget {
  final String title;
  final String? flag;
  final bool autoFlag;
  final String heading;
  const _NameDialog({
    required this.title,
    required this.flag,
    required this.autoFlag,
    required this.heading,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctrl;
  String? _flag;
  bool _manual = false; // l'utente ha scelto la bandiera a mano
  List<String> _suggested = [];

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.title);
    _flag = widget.flag;
    _manual = widget.flag != null;
    _update(widget.title);
  }

  void _update(String text) {
    _suggested = detectFlags(text);
    if (widget.autoFlag && !_manual) {
      _flag = _suggested.isEmpty ? null : _suggested.first;
    }
  }

  Future<void> _pickOther() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in allFlags())
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(ctx, f),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(f, style: const TextStyle(fontSize: 30)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _flag = picked;
        _manual = true;
      });
    }
  }

  void _save() {
    final t = _ctrl.text.trim();
    Navigator.pop(context, NameResult(_flag, t.isEmpty ? widget.title : t));
  }

  @override
  Widget build(BuildContext context) {
    final chips = <String>{..._suggested, if (_flag != null) _flag!}.toList();
    return AlertDialog(
      title: Text(widget.heading),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Titolo',
              prefixText: _flag == null ? null : '$_flag  ',
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _update(v)),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          Text('Bandiera', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in chips)
                ChoiceChip(
                  label: Text(f, style: const TextStyle(fontSize: 20)),
                  selected: _flag == f,
                  onSelected: (_) => setState(() {
                    _flag = f;
                    _manual = true;
                  }),
                ),
              ChoiceChip(
                label: const Text('Nessuna'),
                selected: _flag == null,
                onSelected: (_) => setState(() {
                  _flag = null;
                  _manual = true;
                }),
              ),
              ActionChip(
                avatar: const Icon(Icons.flag_outlined, size: 18),
                label: const Text('Altre'),
                onPressed: _pickOther,
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(onPressed: _save, child: const Text('Salva')),
      ],
    );
  }
}
