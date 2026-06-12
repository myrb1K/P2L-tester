import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device.dart';
import '../models/module.dart';

class SetDeviceIdResult {
  final DeviceType type;
  final int oldAddress;
  final int newAddress;
  final bool restartAfter;

  const SetDeviceIdResult({
    required this.type,
    required this.oldAddress,
    required this.newAddress,
    this.restartAfter = false,
  });
}

/// Dialog pro přečíslování existujícího device (DEVICE-SET-ID). Změní adresu
/// modulu z aktuální na zadanou; firmware atomicky přemapuje celý čip.
class SetDeviceIdDialog extends StatefulWidget {
  final PumaModule module;
  final Set<int> existingAddresses;
  const SetDeviceIdDialog({
    super.key,
    required this.module,
    this.existingAddresses = const {},
  });

  @override
  State<SetDeviceIdDialog> createState() => _SetDeviceIdDialogState();
}

class _SetDeviceIdDialogState extends State<SetDeviceIdDialog> {
  late DeviceType _type;
  late TextEditingController _newCtrl;
  bool _restartAfter = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _type = _resolveType(widget.module);
    _newCtrl = TextEditingController(text: widget.module.baseAddress.toString());
  }

  static DeviceType _resolveType(PumaModule m) {
    switch (m.type) {
      case ModuleType.pumA:
        return DeviceType.disp;
      case ModuleType.pumB:
      case ModuleType.pumC:
        return DeviceType.btn;
      case ModuleType.dist:
        return DeviceType.dist;
    }
  }

  // Platný rozsah adres podle typu modulu (PUM-A 128–246, PUM-B/C 128–247,
  // DIST 1–127). Zdroj pravdy: ModuleTypeExt.addressRange.
  ({int min, int max}) get _range => widget.module.type.addressRange;

  void _submit() {
    final newAddr = int.tryParse(_newCtrl.text);
    final range = _range;
    if (newAddr == null) {
      setState(() => _error = 'Zadej platné číslo adresy.');
      return;
    }
    if (newAddr == widget.module.baseAddress) {
      setState(() => _error = 'Nová adresa je shodná s aktuální.');
      return;
    }
    if (newAddr < range.min || newAddr > range.max) {
      setState(() => _error =
          'Adresa mimo rozsah ${range.min}–${range.max} pro ${widget.module.type.label}.');
      return;
    }
    if (widget.existingAddresses.contains(newAddr)) {
      setState(() => _error = 'Adresa $newAddr už je v jednotce obsazená.');
      return;
    }
    Navigator.pop(
      context,
      SetDeviceIdResult(
        type: _type,
        oldAddress: widget.module.baseAddress,
        newAddress: newAddr,
        restartAfter: _restartAfter,
      ),
    );
  }

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    return AlertDialog(
      title: Text('Přečíslovat ${widget.module.displayLabel}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Aktuální adresa: ${widget.module.baseAddress}. Po potvrzení P2L modul '
            'přemapuje device na novou adresu (DEVICE-SET-ID).',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Nová adresa (${range.min}–${range.max})',
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Přečíslovat')),
      ],
    );
  }
}
