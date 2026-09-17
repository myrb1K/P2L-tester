import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/p2l_led_config.dart';
import '../providers/app_state.dart';

/// Dialogy pro práci s P2L LED — LED pásky připojené přímo na porty jednotky
/// (device kód `01`). Nejde o LED kroužky na PUM-A/PUM-B, ty se ovládají
/// z menu příslušného modulu.
///
/// Hodnoty se plní z P2L `GET-CONFIG` (viz [AppState.p2lConfigFor]); u starší
/// generace firmwaru, která `GET-CONFIG` nezná, se pracuje s továrními
/// hodnotami a příkazy jdou starým `CMD` formátem.

/// Barva slotu jako [Color] (RGB z jednotky, plná průhlednost).
Color p2lSlotColor(int rgb) => Color(0xFF000000 | rgb);

/// Kontrastní barva textu na daném pozadí — číslo barvy musí být čitelné
/// i na bílém i na tmavě modrém slotu.
Color _onColor(Color bg) =>
    bg.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

String _hex(int rgb) => rgb.toRadixString(16).padLeft(6, '0');

/// Obsah dialogu: roztáhne se na dostupnou šířku, nejvýš však [maxWidth].
/// Pevný `SizedBox(width: …)` by na úzkém okně (nebo na telefonu) přetekl —
/// dialog má k dispozici jen šířku obrazovky mínus okraje.
class _DialogBody extends StatelessWidget {
  final double maxWidth;
  final Widget child;

  const _DialogBody({required this.maxWidth, required this.child});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SizedBox(width: double.maxFinite, child: child),
    );
  }
}

/// Titulek dialogu na **jeden řádek**: název akce a za ním ID jednotky menším
/// šedým písmem. Plné „Ovládání P2L LED — 1209" ve výchozí velikosti titulku
/// se v úzkém okně lámalo na dva řádky.
class _DialogTitle extends StatelessWidget {
  final String label;
  final String unitId;

  const _DialogTitle({required this.label, required this.unitId});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          unitId,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }
}

/// Čtvercové tlačítko portu (0–7). [color] je barva, kterou port **právě
/// svítí**; `null` znamená zhasnuto. Barva je per-port schválně: po změně
/// barvy v dialogu musí port, který svítí ještě tou původní, zůstat v ní.
class _PortToggle extends StatelessWidget {
  final int port;
  final Color? color;
  final VoidCallback onTap;

  const _PortToggle({
    super.key,
    required this.port,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lit = color != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color ?? Colors.grey.shade300,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color ?? Colors.grey.shade400, width: 1),
        ),
        child: Text(
          '$port',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: lit ? _onColor(color!) : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }
}

/// Řádky s tlačítky portů 0–7 a přepínačem Vše / Zrušit.
/// [litColors] mapuje port na barvu, kterou svítí; co v mapě není, je zhasnuté.
class _PortPicker extends StatelessWidget {
  final Map<int, Color> litColors;
  final void Function(int port) onToggle;
  final VoidCallback onAll;
  final VoidCallback onNone;

  const _PortPicker({
    required this.litColors,
    required this.onToggle,
    required this.onAll,
    required this.onNone,
  });

  @override
  Widget build(BuildContext context) {
    final all = litColors.length == kP2lPortCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Porty', style: Theme.of(context).textTheme.labelMedium),
            const Spacer(),
            FilledButton.tonal(
              onPressed: all ? onNone : onAll,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              child: Text(all ? 'Zrušit' : 'Vše'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Dva pevné řádky po čtyřech (0–3 / 4–7) — Wrap by porty zalomil podle
        // šířky dialogu a rozdělení by se měnilo s velikostí okna.
        for (int row = 0; row < 2; row++)
          Padding(
            padding: EdgeInsets.only(top: row == 0 ? 0 : 6),
            child: Row(
              children: [
                for (int i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _PortToggle(
                      key: ValueKey('p2l-port-${row * 4 + i}'),
                      port: row * 4 + i,
                      color: litColors[row * 4 + i],
                      onTap: () => onToggle(row * 4 + i),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Rozevírací seznam barev — barevný obdélník s číslem slotu uvnitř.
/// Barvy jsou skutečné hodnoty z jednotky, ne tovární tabulka.
class _ColorDropdown extends StatelessWidget {
  final P2lLedConfig config;
  final int value;
  final ValueChanged<int> onChanged;

  const _ColorDropdown({
    required this.config,
    required this.value,
    required this.onChanged,
  });

  Widget _swatch(int id) {
    final color = p2lSlotColor(config.colorOf(id).rgb);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 44,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade400),
          ),
          child: Text(
            '$id',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: _onColor(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            id < kP2lDefaultColorNames.length ? kP2lDefaultColorNames[id] : '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      isDense: true,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Barva',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      items: [
        for (int id = 0; id < kP2lColorCount; id++)
          DropdownMenuItem(value: id, child: _swatch(id)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

// ============================================================
// Ovládání
// ============================================================

/// Ovládání P2L LED — rozsah LED, barva, styl svícení a výběr portů.
class P2lControlDialog extends StatefulWidget {
  final String unitId;

  const P2lControlDialog({super.key, required this.unitId});

  @override
  State<P2lControlDialog> createState() => _P2lControlDialogState();
}

class _P2lControlDialogState extends State<P2lControlDialog> {
  late final TextEditingController _fromCtrl;
  late final TextEditingController _toCtrl;
  // Porty, které právě svítí, a `color_id`, kterým byly rozsvíceny. Klepnutí
  // na port povel rovnou odešle, takže zvýrazněné tlačítko není „vybráno
  // k odeslání", ale „tenhle port svítí". Barvu držíme per-port, aby změna
  // barvy v dialogu nepřebarvila porty, které fyzicky svítí ještě tou starou.
  final Map<int, int> _lit = {};
  int _colorId = 0;
  int _styleId = 0;

  @override
  void initState() {
    super.initState();
    final config = context.read<AppState>().p2lConfigFor(widget.unitId);
    // Horní mez bereme z počtu LED hlášeného jednotkou; když ho neznáme,
    // použijeme stejných 600 LED jako testovací pattern na hlavní obrazovce.
    final max = config.maxLedCount > 0 ? config.maxLedCount : 600;
    _fromCtrl = TextEditingController(text: '0');
    _toCtrl = TextEditingController(text: '${max - 1}');
  }

  @override
  void dispose() {
    _fromCtrl.dispose();
    _toCtrl.dispose();
    super.dispose();
  }

  int get _x1 => int.tryParse(_fromCtrl.text.trim()) ?? 0;
  int get _x2 => int.tryParse(_toCtrl.text.trim()) ?? 0;

  /// Klepnutí na port — povel se pošle hned. Zhasnutý port rozsvítí podle
  /// aktuálně nastaveného rozsahu, barvy a stylu, svítící zhasne.
  Future<void> _togglePort(AppState state, int port) async {
    final wasLit = _lit.containsKey(port);
    setState(() => wasLit ? _lit.remove(port) : _lit[port] = _colorId);
    if (wasLit) {
      await state.sendP2lClearStrips(unitId: widget.unitId, ports: [port]);
    } else {
      await _lightPorts(state, [port]);
    }
  }

  /// Rozsvítí / zhasne všechny porty najednou.
  Future<void> _toggleAll(AppState state) async {
    if (_lit.isNotEmpty) {
      setState(_lit.clear);
      // Bez seznamu portů zhasne firmware všechny — kratší než vyjmenovat je.
      await state.sendP2lClearStrips(unitId: widget.unitId);
      return;
    }
    final all = List.generate(kP2lPortCount, (i) => i);
    setState(() {
      for (final port in all) {
        _lit[port] = _colorId;
      }
    });
    await _lightPorts(state, all);
  }

  Future<void> _lightPorts(AppState state, List<int> ports) async {
    await state.sendP2lLeds(
      unitId: widget.unitId,
      ports: ports,
      x1: _x1,
      x2: _x2,
      styleId: _styleId,
      colorId: _colorId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.p2lConfigFor(widget.unitId);
    final display = int.tryParse(widget.unitId)?.toString() ?? widget.unitId;
    final anyLit = _lit.isNotEmpty;
    // Barvu bereme z aktuální konfigurace, takže přenastavení RGB v „Barvy
    // P2L LED" se propíše i do už svítících portů (tam se opravdu změní).
    final litColors = {
      for (final entry in _lit.entries)
        entry.key: p2lSlotColor(config.colorOf(entry.value).rgb),
    };

    return AlertDialog(
      title: _DialogTitle(label: 'Ovládání P2L LED', unitId: display),
      content: _DialogBody(
        maxWidth: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _fromCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'LED od',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _toCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'LED do',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _ColorDropdown(
                config: config,
                value: _colorId,
                onChanged: (v) => setState(() => _colorId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _styleId,
                isDense: true,
                // Bez isExpanded si dropdown drží přirozenou šířku položky
                // a na úzkém okně přeteče.
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Styl svícení',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: [
                  for (final entry in kP2lStyles.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(
                        '${entry.key} — ${entry.value}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _styleId = v);
                },
              ),
              const SizedBox(height: 16),
              _PortPicker(
                litColors: litColors,
                onToggle: (p) => _togglePort(state, p),
                onAll: () => _toggleAll(state),
                onNone: () => _toggleAll(state),
              ),
              const SizedBox(height: 8),
              Text(
                _lit.isEmpty
                    ? 'Klepnutím na port ho rozsvítíš, dalším klepnutím zhasneš.'
                    : 'Svítí ${_lit.length} z $kP2lPortCount portů.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        FilledButton.icon(
          onPressed: () => _toggleAll(state),
          style: FilledButton.styleFrom(
            backgroundColor: anyLit
                ? Colors.red.shade700
                : Colors.green.shade700,
          ),
          icon: Icon(
            anyLit ? Icons.lightbulb_outline : Icons.lightbulb,
            size: 18,
          ),
          label: Text(anyLit ? 'Zhasnout vše' : 'Rozsvítit vše'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zavřít'),
        ),
      ],
    );
  }
}

// ============================================================
// Jas
// ============================================================

/// Jas P2L LED (1–100 %).
class P2lBrightnessDialog extends StatefulWidget {
  final String unitId;

  const P2lBrightnessDialog({super.key, required this.unitId});

  @override
  State<P2lBrightnessDialog> createState() => _P2lBrightnessDialogState();
}

class _P2lBrightnessDialogState extends State<P2lBrightnessDialog> {
  late int _value;

  @override
  void initState() {
    super.initState();
    _value =
        context.read<AppState>().p2lConfigFor(widget.unitId).brightness ?? 50;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.p2lConfigFor(widget.unitId);
    final display = int.tryParse(widget.unitId)?.toString() ?? widget.unitId;

    return AlertDialog(
      title: _DialogTitle(label: 'Jas P2L LED', unitId: display),
      content: _DialogBody(
        maxWidth: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              config.isLoaded
                  ? 'V jednotce je nastaveno ${config.brightness ?? '—'} %.'
                  : 'Jednotka jas nehlásí (starší firmware) — pošle se zadaná hodnota.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _value.toDouble(),
                    min: 1,
                    max: 100,
                    divisions: 99,
                    label: '$_value %',
                    onChanged: (v) => setState(() => _value = v.round()),
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '$_value %',
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () {
            state.setP2lBrightness(unitId: widget.unitId, brightness: _value);
            Navigator.pop(context);
          },
          child: const Text('Nastavit'),
        ),
      ],
    );
  }
}

// ============================================================
// Počet LED
// ============================================================

/// Počet LED na jednotlivých portech.
class P2lLedCountDialog extends StatefulWidget {
  final String unitId;

  const P2lLedCountDialog({super.key, required this.unitId});

  @override
  State<P2lLedCountDialog> createState() => _P2lLedCountDialogState();
}

class _P2lLedCountDialogState extends State<P2lLedCountDialog> {
  late final List<TextEditingController> _ctrls;
  late final P2lLedConfig _config;

  @override
  void initState() {
    super.initState();
    _config = context.read<AppState>().p2lConfigFor(widget.unitId);
    _ctrls = [
      for (int p = 0; p < kP2lPortCount; p++)
        TextEditingController(text: _config.ledCountOf(p)?.toString() ?? ''),
    ];
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  /// Prázdné pole = port se nemění (příkaz ho vůbec nezmíní).
  Map<int, int> _collect() {
    final out = <int, int>{};
    for (int p = 0; p < kP2lPortCount; p++) {
      final text = _ctrls[p].text.trim();
      if (text.isEmpty) continue;
      final value = int.tryParse(text);
      if (value != null && value >= 0) out[p] = value;
    }
    return out;
  }

  void _fillAll() {
    final first = _ctrls.first.text.trim();
    if (first.isEmpty) return;
    setState(() {
      for (final c in _ctrls) {
        c.text = first;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final display = int.tryParse(widget.unitId)?.toString() ?? widget.unitId;

    return AlertDialog(
      title: _DialogTitle(label: 'Počet P2L LED', unitId: display),
      content: _DialogBody(
        maxWidth: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _config.isLoaded
                    ? 'Hodnoty načtené z jednotky. Prázdné pole port nezmění.'
                    : 'Jednotka počty nehlásí (starší firmware) — vyplň, co se má nastavit.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              for (int p = 0; p < kP2lPortCount; p++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 60,
                        child: Text(
                          'Port $p',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _ctrls[p],
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                            hintText: 'neznámo',
                            suffixText: 'LED',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _fillAll,
                  icon: const Icon(Icons.content_copy, size: 16),
                  label: const Text('Port 0 na všechny'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () {
            final counts = _collect();
            if (counts.isNotEmpty) {
              state.setP2lLedCounts(unitId: widget.unitId, counts: counts);
            }
            Navigator.pop(context);
          },
          child: const Text('Nastavit'),
        ),
      ],
    );
  }
}

// ============================================================
// Barvy
// ============================================================

/// Definice barev (`color_id` 0–5). Každý slot má primární barvu a sekundární
/// („color2"), kterou používají styly se střídáním barev.
class P2lColorsDialog extends StatefulWidget {
  final String unitId;

  const P2lColorsDialog({super.key, required this.unitId});

  @override
  State<P2lColorsDialog> createState() => _P2lColorsDialogState();
}

class _P2lColorsDialogState extends State<P2lColorsDialog> {
  late final P2lLedConfig _config;
  late final Map<int, P2lColorSlot> _slots;

  @override
  void initState() {
    super.initState();
    _config = context.read<AppState>().p2lConfigFor(widget.unitId);
    _slots = {
      for (int id = 0; id < kP2lColorCount; id++) id: _config.colorOf(id),
    };
  }

  /// Změněné sloty proti tomu, co hlásí jednotka — posílat všech šest by
  /// zbytečně přepsalo i to, na co uživatel nesáhl.
  Map<int, P2lColorSlot> _changed() => {
    for (final entry in _slots.entries)
      if (entry.value != _config.colorOf(entry.key)) entry.key: entry.value,
  };

  Future<void> _edit(int id, {required bool secondary}) async {
    final slot = _slots[id]!;
    final current = secondary ? slot.rgb2 : slot.rgb;
    final rgb = await showDialog<int>(
      context: context,
      builder: (_) => _HexColorDialog(
        title: secondary ? 'Barva $id — color2' : 'Barva $id',
        initial: current,
      ),
    );
    if (rgb == null) return;
    setState(() {
      _slots[id] = secondary
          ? slot.copyWith(rgb2: rgb)
          : slot.copyWith(rgb: rgb);
    });
  }

  Widget _swatchButton(int rgb, VoidCallback onTap) {
    final color = p2lSlotColor(rgb);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 74,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade400),
        ),
        child: Text(
          _hex(rgb),
          style: TextStyle(
            fontSize: 11,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: _onColor(color),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final display = int.tryParse(widget.unitId)?.toString() ?? widget.unitId;

    return AlertDialog(
      title: _DialogTitle(label: 'Barvy P2L LED', unitId: display),
      content: _DialogBody(
        maxWidth: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _config.isLoaded
                    ? 'Barvy načtené z jednotky. Klepnutím na vzorek se mění.'
                    : 'Jednotka barvy nehlásí (starší firmware) — zobrazené jsou tovární.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 4),
              Text(
                'color2 využívají styly se střídáním barev (5 a 6).',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 12),
              for (int id = 0; id < kP2lColorCount; id++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        child: Text(
                          '$id',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _swatchButton(
                        _slots[id]!.rgb,
                        () => _edit(id, secondary: false),
                      ),
                      const SizedBox(width: 8),
                      _swatchButton(
                        _slots[id]!.rgb2,
                        () => _edit(id, secondary: true),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          id < kP2lDefaultColorNames.length
                              ? kP2lDefaultColorNames[id]
                              : '',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () {
            final changed = _changed();
            if (changed.isNotEmpty) {
              state.setP2lColors(unitId: widget.unitId, colors: changed);
            }
            Navigator.pop(context);
          },
          child: const Text('Nastavit'),
        ),
      ],
    );
  }
}

/// Zadání barvy hexem (`ff8800`) s náhledem a rychlou volbou ze základních
/// barev. Vlastní dialog místo balíčkového pickeru — kvůli jedné obrazovce
/// nemá smysl tahat do projektu novou závislost.
class _HexColorDialog extends StatefulWidget {
  final String title;
  final int initial;

  const _HexColorDialog({required this.title, required this.initial});

  @override
  State<_HexColorDialog> createState() => _HexColorDialogState();
}

class _HexColorDialogState extends State<_HexColorDialog> {
  late final TextEditingController _ctrl;
  late int _rgb;

  static const _presets = [
    0xFF0000,
    0x00FF00,
    0x0000FF,
    0xFFFF00,
    0xFF00FF,
    0x00FFFF,
    0xFFFFFF,
    0xFF8000,
    0x808080,
    0x000000,
  ];

  @override
  void initState() {
    super.initState();
    _rgb = widget.initial;
    _ctrl = TextEditingController(text: _hex(_rgb));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _apply(String text) {
    final parsed = int.tryParse(text.trim().replaceFirst('#', ''), radix: 16);
    if (parsed == null) return;
    setState(() => _rgb = parsed & 0xFFFFFF);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _DialogBody(
        maxWidth: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 54,
                  height: 40,
                  decoration: BoxDecoration(
                    color: p2lSlotColor(_rgb),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    maxLength: 6,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'RGB hex',
                      prefixText: '#',
                      border: OutlineInputBorder(),
                      isDense: true,
                      counterText: '',
                    ),
                    onChanged: _apply,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in _presets)
                  InkWell(
                    onTap: () {
                      _ctrl.text = _hex(preset);
                      setState(() => _rgb = preset);
                    },
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: p2lSlotColor(preset),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade400),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _rgb),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

// ============================================================
// Sekce v seznamu devices
// ============================================================

/// Sekce **P2L** v seznamu devices — LED pásky jednotky. Má vždy právě jeden
/// chip s číslem jednotky a **nepočítá se mezi devices** (není to čip na
/// RS485 sběrnici, ale LED výstupy jednotky samotné).
class P2lLedSection extends StatelessWidget {
  final String unitId;

  const P2lLedSection({super.key, required this.unitId});

  static const _color = Colors.deepOrange;

  void _open(BuildContext context, String choice) {
    final builder = switch (choice) {
      'control' => (BuildContext _) => P2lControlDialog(unitId: unitId),
      'brightness' => (BuildContext _) => P2lBrightnessDialog(unitId: unitId),
      'count' => (BuildContext _) => P2lLedCountDialog(unitId: unitId),
      'colors' => (BuildContext _) => P2lColorsDialog(unitId: unitId),
      _ => null,
    };
    if (builder == null) return;
    showDialog(context: context, builder: builder);
  }

  @override
  Widget build(BuildContext context) {
    final display = int.tryParse(unitId)?.toString() ?? unitId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'P2L  1x',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: _color,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          PopupMenuButton<String>(
            tooltip: 'LED pásky jednotky $display',
            offset: const Offset(0, 32),
            onSelected: (v) => _open(context, v),
            itemBuilder: (_) => const [
              PopupMenuItem(
                enabled: false,
                child: Text(
                  'P2L LED',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'control',
                child: Row(
                  children: [
                    Icon(Icons.tune, size: 18),
                    SizedBox(width: 8),
                    Text('Ovládání'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'brightness',
                child: Row(
                  children: [
                    Icon(Icons.brightness_6, size: 18),
                    SizedBox(width: 8),
                    Text('Jas P2L LED'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'count',
                child: Row(
                  children: [
                    Icon(Icons.format_list_numbered, size: 18),
                    SizedBox(width: 8),
                    Text('Počet P2L LED'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'colors',
                child: Row(
                  children: [
                    Icon(Icons.palette, size: 18),
                    SizedBox(width: 8),
                    Text('Barvy P2L LED'),
                  ],
                ),
              ),
            ],
            child: Chip(
              label: Text(
                display,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _color,
                ),
              ),
              avatar: Icon(Icons.lightbulb_circle, size: 16, color: _color),
              backgroundColor: _color.withAlpha(30),
              side: BorderSide(color: _color.withAlpha(110)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}
