import 'dart:async';

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
  // Předvolený typ (např. ze skenu sběrnice — ghost chip zná typ device).
  final ModuleType? suggestedType;
  // Volitelné živé měření DIST senzoru. Když je předán (jen při editaci
  // existujícího senzoru na připojené jednotce), v modalu se u SENZORu ukáže
  // checkbox „Měření"; po zaškrtnutí se callback volá každých 500 ms a vrací
  // naměřenou vzdálenost [mm] (null = bez hodnoty / porucha / timeout).
  final Future<int?> Function()? onMeasure;

  const AddModuleDialog({
    super.key,
    this.existingAddresses = const {},
    this.hasPumAWithRoom = false,
    this.initial,
    this.suggestedAddress,
    this.suggestedType,
    this.onMeasure,
  });

  @override
  State<AddModuleDialog> createState() => _AddModuleDialogState();
}

class _AddModuleDialogState extends State<AddModuleDialog> {
  late ModuleType _type;
  late TextEditingController _addrCtrl;
  final Set<PumaButton> _buttons = <PumaButton>{};
  bool _hasLeds = false;
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
  // Segmenty jen ke čtení (z GET-DEVICES) — needitujeme je, jen zachováme.
  List<DistSegment> _segments = const [];

  // Živé měření DIST (GET-VALUE každých 500 ms).
  Timer? _measureTimer;
  bool _measuring = false;
  bool _measurePending = false; // brání překrytí, když odpověď trvá > 500 ms
  int? _measuredValue;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _type = init?.type ?? widget.suggestedType ?? ModuleType.pumA;
    // Předvyplněná adresa: explicitní z volajícího (sken), jinak první volná.
    final initialSuggested =
        init == null ? (widget.suggestedAddress ?? _suggestFor(_type)) : null;
    _lastSuggested = initialSuggested;
    _addrCtrl = TextEditingController(
      text: init?.baseAddress.toString() ?? initialSuggested?.toString() ?? '',
    );
    // Adresy tlačítek se odvozují od bázové adresy → překresli při změně pole.
    _addrCtrl.addListener(_onAddrChanged);
    if (init != null) {
      _buttons.addAll(init.buttons);
      _hasLeds = init.hasLeds;
    } else {
      // Default: jedno tlačítko (vnitřní levé = 1) jako dřív.
      if (_type == ModuleType.pumA) _buttons.add(PumaButton.leftInner);
      _hasLeds = false;
    }

    final cfg = init?.distConfig ?? const DistConfig();
    _distPeriodCtrl = TextEditingController(text: cfg.measurePeriod.toString());
    _distTimeoutCtrl = TextEditingController(text: cfg.timeout.toString());
    _distCountCtrl = TextEditingController(text: cfg.countMeasures.toString());
    _distMaxDevCtrl = TextEditingController(text: cfg.maxDeviation.toString());
    _distOffsetCtrl = TextEditingController(text: cfg.offset.toString());
    _distMeasureType = cfg.measureType;
    _segments = cfg.segments;
  }

  @override
  void dispose() {
    _measureTimer?.cancel();
    _addrCtrl.dispose();
    _distPeriodCtrl.dispose();
    _distTimeoutCtrl.dispose();
    _distCountCtrl.dispose();
    _distMaxDevCtrl.dispose();
    _distOffsetCtrl.dispose();
    super.dispose();
  }

  /// Zapne/vypne živé měření senzoru (GET-VALUE každých 200 ms).
  void _toggleMeasure(bool on) {
    _measureTimer?.cancel();
    setState(() {
      _measuring = on;
      if (!on) _measuredValue = null;
    });
    if (on) {
      _tickMeasure(); // první měření hned, ať uživatel nečeká 500 ms
      _measureTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _tickMeasure(),
      );
    } else {
      _measureTimer = null;
    }
  }

  Future<void> _tickMeasure() async {
    final cb = widget.onMeasure;
    if (cb == null || _measurePending) return; // předchozí měření ještě běží
    _measurePending = true;
    try {
      final value = await cb();
      if (!mounted || !_measuring) return;
      setState(() => _measuredValue = value);
    } finally {
      _measurePending = false;
    }
  }

  /// Kompaktní ovládání živého měření: checkbox „Měření" + naměřená hodnota.
  Widget _measureControl(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: _measuring,
          onChanged: (v) => _toggleMeasure(v ?? false),
          visualDensity: VisualDensity.compact,
        ),
        const Text('Měření'),
        if (_measuring) ...[
          const SizedBox(width: 8),
          Text(
            _measuredValue != null ? '$_measuredValue mm' : '…',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }

  void _onAddrChanged() {
    if (_type == ModuleType.pumA && mounted) setState(() {});
  }

  int _suggestFor(ModuleType t) {
    final taken = widget.existingAddresses;
    final range = t.addressRange;
    for (var i = range.min; i <= range.max; i++) {
      if (!taken.contains(i)) return i;
    }
    return range.min;
  }

  String? _validate() {
    final addr = int.tryParse(_addrCtrl.text);
    if (addr == null) return 'Zadej adresu (číslo).';
    final range = _type.addressRange;
    if (addr < range.min || addr > range.max) {
      return '${_type.label} adresa musí být ${range.min}–${range.max}.';
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
          buttons: {..._buttons},
          hasLeds: _hasLeds,
        );
      case ModuleType.pumB:
        module = PumaModule.pumB(address: addr, hasLeds: _hasLeds);
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
            segments: _segments, // needitujeme, jen zachováme (jinak by se smazaly)
          ),
        );
    }
    Navigator.pop(
      context,
      AddModuleResult(module: module, restartAfter: _restartAfter),
    );
  }

  /// Vrátí konfiguraci senzoru na tovární výchozí (50, 10, 0, 20, 4, Middle).
  /// Adresu ani segmenty (jen ke čtení) nemění — přepíše jen pole configu.
  void _resetDistDefaults() {
    const d = DistConfig();
    setState(() {
      _distPeriodCtrl.text = d.measurePeriod.toString();
      _distTimeoutCtrl.text = d.timeout.toString();
      _distCountCtrl.text = d.countMeasures.toString();
      _distMaxDevCtrl.text = d.maxDeviation.toString();
      _distOffsetCtrl.text = d.offset.toString();
      _distMeasureType = d.measureType;
    });
  }

  /// Vizuální výběr 0–4 tlačítek PUM-A okolo displeje.
  /// Zleva doprava: 3 · 1 · DISPLEJ · 0 · 2 (nezávislé toggly).
  Widget _buildButtonSelector() {
    final base = int.tryParse(_addrCtrl.text);

    Widget toggle(PumaButton b) => Expanded(
          child: _ButtonToggle(
            number: b.number,
            positionLabel: b.positionLabel,
            // 4-ciferný tvar (tisícová číslice = číslo tlačítka), např. 0133.
            address: base == null
                ? '—'
                : b.addressFor(base).toString().padLeft(4, '0'),
            selected: _buttons.contains(b),
            onTap: () => setState(() {
              if (!_buttons.add(b)) _buttons.remove(b);
            }),
          ),
        );

    // IntrinsicHeight dá Row konečnou výšku (= nejvyšší dlaždice), aby
    // crossAxisAlignment.stretch fungoval i ve svislém scroll view.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toggle(PumaButton.leftOuter),
          const SizedBox(width: 4),
          toggle(PumaButton.leftInner),
          const SizedBox(width: 4),
          Expanded(child: _DisplaySlot(address: base?.toString() ?? '—')),
          const SizedBox(width: 4),
          toggle(PumaButton.rightInner),
          const SizedBox(width: 4),
          toggle(PumaButton.rightOuter),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Přidat device' : 'Upravit device'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<ModuleType>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Typ device',
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
                          if (_buttons.isEmpty) _buttons.add(PumaButton.leftInner);
                        } else if (_type != ModuleType.pumB) {
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
                    ? 'Adresa sensoru (${_type.addressRange.min}–${_type.addressRange.max})'
                    : 'Adresa / číslo čipu (${_type.addressRange.min}–${_type.addressRange.max})',
                hintText: _type == ModuleType.pumA
                    ? 'např. 128 (DISP + tlačítka 0/1/2/3)'
                    : _type == ModuleType.pumC
                        ? 'např. 130 (PUM-C + = 1130, − = 130)'
                        : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_type == ModuleType.pumA) ...[
              const SizedBox(height: 12),
              Text('Tlačítka (klepnutím vyber)',
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 6),
              _buildButtonSelector(),
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
            if (_type == ModuleType.pumB) ...[
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
              // Živé měření senzoru (GET-VALUE každých 500 ms) — jen při editaci
              // existujícího senzoru na připojené jednotce. Se segmenty je
              // checkbox integrovaný do řádku „Segmenty (N)"; bez segmentů
              // (řádek neexistuje) se ukáže samostatně.
              if (widget.onMeasure != null && _segments.isEmpty) ...[
                const SizedBox(height: 8),
                _measureControl(context),
              ],
              if (_segments.isNotEmpty) ...[
                const SizedBox(height: 16),
                // Wrap: na úzkém okně se měření zalomí pod „Segmenty (N)",
                // na širším zůstane hned za ním (bez horizontálního overflow).
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.view_week_outlined, size: 16),
                      const SizedBox(width: 6),
                      Text('Segmenty (${_segments.length})',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                    if (widget.onMeasure != null) _measureControl(context),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(vertical: 2, horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < _segments.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(_segments[i].id,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ),
                              Text('${_segments[i].from} – ${_segments[i].to} mm',
                                  style: const TextStyle(fontFeatures: [
                                    FontFeature.tabularFigures()
                                  ])),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Segmenty jsou jen ke čtení (režim „segments").',
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _restartAfter,
              onChanged: (v) => setState(() => _restartAfter = v ?? false),
              title: const Text('Po úpravě restartovat P2L modul'),
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
        Row(
          children: [
            // Obnovit tovární config senzoru (jen DIST) — vlevo dole.
            if (_type == ModuleType.dist)
              TextButton.icon(
                onPressed: _resetDistDefaults,
                icon: const Icon(Icons.settings_backup_restore, size: 18),
                label: const Text('Obnovit'),
              ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Zrušit'),
            ),
            FilledButton(onPressed: _submit, child: const Text('OK')),
          ],
        ),
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

/// Přepínatelná dlaždice jednoho tlačítka PUM-A (číslo + pozice + adresa).
class _ButtonToggle extends StatelessWidget {
  final int number;
  final String positionLabel;
  final String address;
  final bool selected;
  final VoidCallback onTap;

  const _ButtonToggle({
    required this.number,
    required this.positionLabel,
    required this.address,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = selected ? scheme.primary : scheme.outline;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withAlpha(28) : null,
          border: Border.all(color: accent, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$number',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: selected ? scheme.primary : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              positionLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 8.5, height: 1.05),
            ),
            const SizedBox(height: 2),
            Text(
              address,
              style: TextStyle(
                fontSize: 9,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Statický rámeček uprostřed výběru — displej PUM-A (vždy přítomen).
class _DisplaySlot extends StatelessWidget {
  final String address;
  const _DisplaySlot({required this.address});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.monitor, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(height: 2),
          Text(
            'DISPLEJ',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            address,
            style: TextStyle(
              fontSize: 9,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
