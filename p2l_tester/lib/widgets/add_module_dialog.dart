import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/module.dart';

class AddModuleResult {
  final PumaModule module;
  final bool restartAfter;
  const AddModuleResult({required this.module, required this.restartAfter});
}

/// Dialog pro přidání/editaci modulu. Vrací null při zrušení, jinak AddModuleResult.
class AddModuleDialog extends StatefulWidget {
  final Set<int> existingAddresses;
  final bool hasPumAWithRoom;
  final PumaModule? initial;
  final int? suggestedAddress;

  const AddModuleDialog({
    super.key,
    this.existingAddresses = const {},
    this.hasPumAWithRoom = false,
    this.initial,
    this.suggestedAddress,
  });

  @override
  State<AddModuleDialog> createState() => _AddModuleDialogState();
}

class _AddModuleDialogState extends State<AddModuleDialog> {
  late ModuleType _type;
  late TextEditingController _addrCtrl;
  int _buttonCount = 0;
  bool _hasLeds = false;
  ButtonSide _buttonSide = ButtonSide.left;
  bool _restartAfter = false;
  String? _error;
  int? _lastSuggested;

  // DIST config
  late TextEditingController _distPeriodCtrl;
  late TextEditingController _distTimeoutCtrl;
  late TextEditingController _distCountCtrl;
  late TextEditingController _distMaxDevCtrl;
  late TextEditingController _distOffsetCtrl;
  int _distMeasureType = 2;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _type = init?.type ?? ModuleType.pumA;
    final initialSuggested = init == null ? _suggestFor(_type) : null;
    _lastSuggested = initialSuggested;
    _addrCtrl = TextEditingController(
      text: init?.baseAddress.toString() ?? initialSuggested?.toString() ?? '',
    );
    _buttonCount = init?.buttonCount ?? 1;
    _hasLeds = init?.hasLeds ?? false;
    _buttonSide = init?.buttonSide ?? ButtonSide.left;

    final cfg = init?.distConfig ?? const DistConfig();
    _distPeriodCtrl = TextEditingController(text: cfg.measurePeriod.toString());
    _distTimeoutCtrl = TextEditingController(text: cfg.timeout.toString());
    _distCountCtrl = TextEditingController(text: cfg.countMeasures.toString());
    _distMaxDevCtrl = TextEditingController(text: cfg.maxDeviation.toString());
    _distOffsetCtrl = TextEditingController(text: cfg.offset.toString());
    _distMeasureType = cfg.measureType;
  }

  @override
  void dispose() {
    _addrCtrl.dispose();
    _distPeriodCtrl.dispose();
    _distTimeoutCtrl.dispose();
    _distCountCtrl.dispose();
    _distMaxDevCtrl.dispose();
    _distOffsetCtrl.dispose();
    super.dispose();
  }

  int _suggestFor(ModuleType t) {
    final taken = widget.existingAddresses;
    if (t == ModuleType.dist) {
      for (var i = 1; i <= 126; i++) {
        if (!taken.contains(i)) return i;
      }
      return 1;
    }
    var i = 128;
    while (taken.contains(i)) {
      i++;
    }
    return i;
  }

  String? _validate() {
    final addr = int.tryParse(_addrCtrl.text);
    if (addr == null) return 'Zadej adresu (číslo).';
    if (addr <= 0) return 'Adresa musí být > 0.';
    if (_type == ModuleType.dist && (addr < 1 || addr > 126)) {
      return 'DIST adresa musí být 1–126.';
    }
    if (_type != ModuleType.dist && (addr < 127 || addr > 246)) {
      return '${_type.label} adresa musí být 127–246.';
    }
    if (_type == ModuleType.pumC && !widget.hasPumAWithRoom && widget.initial == null) {
      return 'PUM-C lze přidat jen k PUM-A, které má 0 nebo 1 tlačítko.';
    }
    if (widget.existingAddresses.contains(addr) &&
        widget.initial?.baseAddress != addr) {
      return 'Adresa $addr je už použitá.';
    }
    return null;
  }

  void _submit() {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final addr = int.parse(_addrCtrl.text);
    final PumaModule module;
    switch (_type) {
      case ModuleType.pumA:
        module = PumaModule.pumA(
          address: addr,
          buttonCount: _buttonCount,
          hasLeds: _hasLeds,
          buttonSide: _buttonCount == 1 ? _buttonSide : null,
        );
      case ModuleType.pumB:
        module = PumaModule.pumB(address: addr);
      case ModuleType.pumC:
        module = PumaModule.pumC(address: addr);
      case ModuleType.dist:
        module = PumaModule.dist(
          address: addr,
          config: DistConfig(
            measurePeriod: int.tryParse(_distPeriodCtrl.text) ?? 50,
            timeout: int.tryParse(_distTimeoutCtrl.text) ?? 10,
            countMeasures: int.tryParse(_distCountCtrl.text) ?? 4,
            maxDeviation: int.tryParse(_distMaxDevCtrl.text) ?? 20,
            offset: int.tryParse(_distOffsetCtrl.text) ?? 0,
            measureType: _distMeasureType,
          ),
        );
    }
    Navigator.pop(
      context,
      AddModuleResult(module: module, restartAfter: _restartAfter),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Přidat modul' : 'Upravit modul'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<ModuleType>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Typ modulu',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: ModuleType.values.map((t) {
                final disabled = t == ModuleType.pumC &&
                    !widget.hasPumAWithRoom &&
                    widget.initial == null;
                return DropdownMenuItem(
                  value: t,
                  enabled: !disabled,
                  child: Text(
                    disabled ? '${t.label} (nejdřív přidej PUM-A)' : t.label,
                    style: disabled ? const TextStyle(color: Colors.grey) : null,
                  ),
                );
              }).toList(),
              onChanged: widget.initial != null
                  ? null
                  : (v) => setState(() {
                        _type = v!;
                        _error = null;
                        if (_type == ModuleType.pumA) {
                          _buttonCount = 1;
                        } else {
                          _buttonCount = 0;
                          _hasLeds = false;
                        }
                        final current = int.tryParse(_addrCtrl.text);
                        if (_addrCtrl.text.isEmpty ||
                            current == _lastSuggested) {
                          final s = _suggestFor(_type);
                          _lastSuggested = s;
                          _addrCtrl.text = s.toString();
                        }
                      }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addrCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: _type == ModuleType.dist
                    ? 'Adresa sensoru (1–126)'
                    : 'Adresa / číslo čipu (127–246)',
                hintText: _type == ModuleType.pumA
                    ? 'např. 128 (DISP N, tlačítka 1N/2N)'
                    : _type == ModuleType.pumC
                        ? 'např. 130 (PUM-C + = 1130, − = 130)'
                        : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_type == ModuleType.pumA) ...[
              const SizedBox(height: 12),
              Text('Počet tlačítek', style: Theme.of(context).textTheme.bodyMedium),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Žádné')),
                  ButtonSegment(value: 1, label: Text('1 tl.')),
                  ButtonSegment(value: 2, label: Text('2 tl. (L+P)')),
                ],
                selected: {_buttonCount},
                onSelectionChanged: (s) => setState(() => _buttonCount = s.first),
              ),
              if (_buttonCount == 1) ...[
                const SizedBox(height: 8),
                Text('Strana tlačítka', style: Theme.of(context).textTheme.bodyMedium),
                SegmentedButton<ButtonSide>(
                  segments: const [
                    ButtonSegment(value: ButtonSide.left, label: Text('Levé (1000+N)')),
                    ButtonSegment(value: ButtonSide.right, label: Text('Pravé (N)')),
                  ],
                  selected: {_buttonSide},
                  onSelectionChanged: (s) => setState(() => _buttonSide = s.first),
                ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _hasLeds,
                onChanged: (v) => setState(() => _hasLeds = v ?? false),
                title: const Text('LEDS osazeny (LED kroužek aktivní)'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
            if (_type == ModuleType.pumC)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'PUM-C musí být přidáno k PUM-A, které má 0 nebo 1 tlačítko.',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ),
            if (_type == ModuleType.dist) ...[
              const SizedBox(height: 12),
              const Text('Konfigurace sensoru',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _distPeriodCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Period (ms)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _distTimeoutCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Timeout',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _distCountCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'CountMeasures',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _distMaxDevCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'MaxDeviation (mm)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _distOffsetCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Offset (mm)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _distMeasureType,
                    decoration: const InputDecoration(
                      labelText: 'Range',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('Short (1m)')),
                      DropdownMenuItem(value: 2, child: Text('Middle (2m)')),
                      DropdownMenuItem(value: 3, child: Text('Long (3m)')),
                    ],
                    onChanged: (v) => setState(() => _distMeasureType = v ?? 2),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _restartAfter,
              onChanged: (v) => setState(() => _restartAfter = v ?? false),
              title: const Text('Restartovat jednotku po úpravě'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}

/// Zjistí, zda seznam modulů obsahuje alespoň jeden PUM-A s 0 nebo 1 tlačítkem
/// (tj. je kam přidat PUM-C).
bool hasPumAWithButtonRoom(List<PumaModule> modules) {
  return modules.any(
      (m) => m.type == ModuleType.pumA && m.buttonCount < 2);
}
