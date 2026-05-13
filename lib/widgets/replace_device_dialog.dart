import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../models/module.dart';
import '../services/command_service.dart';

class ReplaceResult {
  final DeviceType type;
  final int oldAddress;
  final int newDefaultAddress;
  final bool restartAfter;

  const ReplaceResult({
    required this.type,
    required this.oldAddress,
    required this.newDefaultAddress,
    this.restartAfter = false,
  });
}

/// Dialog pro výměnu vadného device v modulu. Podporováno pro PUM-A (DISP) a DIST.
class ReplaceDeviceDialog extends StatefulWidget {
  final PumaModule module;
  const ReplaceDeviceDialog({super.key, required this.module});

  @override
  State<ReplaceDeviceDialog> createState() => _ReplaceDeviceDialogState();
}

class _ReplaceDeviceDialogState extends State<ReplaceDeviceDialog> {
  late DeviceType _type;
  late TextEditingController _newCtrl;
  bool _restartAfter = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _type = _resolveType(widget.module);
    _newCtrl = TextEditingController(
        text: CommandService.defaultReplacementAddress(_type).toString());
  }

  static DeviceType _resolveType(PumaModule m) {
    switch (m.type) {
      case ModuleType.pumA:
        return DeviceType.disp; // primární device PUM-A; LEDS se přemapují s ním
      case ModuleType.pumB:
        return DeviceType.btn; // 1 BTN čip
      case ModuleType.pumC:
        return DeviceType.btn; // primární BTN @M; firmware přemapuje i 1000+M
      case ModuleType.dist:
        return DeviceType.dist;
    }
  }

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final newAddr = int.tryParse(_newCtrl.text);
    if (newAddr == null || newAddr <= 0) {
      setState(() => _error = 'Zadej platnou default adresu nového kusu.');
      return;
    }
    Navigator.pop(
      context,
      ReplaceResult(
        type: _type,
        oldAddress: widget.module.baseAddress,
        newDefaultAddress: newAddr,
        restartAfter: _restartAfter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supported = CommandService.supportsReplace(_type);
    final defaultAddr = CommandService.defaultReplacementAddress(_type);

    return AlertDialog(
      title: Text('Vyměnit ${widget.module.displayLabel}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!supported)
            const Text(
              'Výměna přes REPLACE-FROM není pro tento typ dokumentována v protokolu.',
              style: TextStyle(color: Colors.orange),
            )
          else ...[
            const Text(
              'Osazený nový kus má výchozí adresu (default). Po potvrzení se P2L modul pokusí změnit ID nového device na ID vadného.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Default adresa nového device (obvykle $defaultAddr)',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _restartAfter,
              onChanged: (v) => setState(() => _restartAfter = v ?? false),
              title: const Text('Po úpravě restartovat P2L modul'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        if (supported)
          FilledButton(onPressed: _submit, child: const Text('Vyměnit')),
      ],
    );
  }
}
