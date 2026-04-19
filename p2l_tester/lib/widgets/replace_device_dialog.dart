import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../models/module.dart';
import '../services/command_service.dart';

class ReplaceResult {
  final DeviceType type;
  final int oldAddress;
  final int newDefaultAddress;

  const ReplaceResult({
    required this.type,
    required this.oldAddress,
    required this.newDefaultAddress,
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
        return DeviceType.disp; // vyměňuje se samotný displej, tělo modulu
      case ModuleType.dist:
        return DeviceType.dist;
      default:
        return DeviceType.btn; // nepodporováno
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
          Text('Typ: ${_type.code} @${widget.module.baseAddress}'),
          const SizedBox(height: 8),
          if (!supported)
            const Text(
              'Výměna přes REPLACE-FROM není pro tento typ dokumentována v protokolu.',
              style: TextStyle(color: Colors.orange),
            )
          else ...[
            const Text(
              'Osazený nový kus má výchozí adresu (default). Po potvrzení se jednotka pokusí nový přečipovat na ID vadného.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Default adresa nového (obvykle $defaultAddr)',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
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
