// Obrazovka „Databáze jednotek" (PRD-DB/01-PRD.md §6.1, milestone DB4).
//
// Vstup: položka v hamburger menu HomeScreen (jen pro přihlášené).
// Seznam: jedno vyhledávací pole (filtruje přes ID + název + umístění),
// chipy stavu, řádky s ID / názvem / stavem / relativním last_seen /
// firmware. Detail: tři vrstvy karty (observed / desired / meta) + historie,
// editace meta polí, drift indikace („Nesouhlasí s evidencí").
// Server nedostupný → hláška + „Zkusit znovu" (UnitDbException).

import 'package:flutter/material.dart';

import '../models/unit_db.dart';
import '../services/unit_db_service.dart';

// ─── Seznam ────────────────────────────────────────────────────────────

class UnitDbListScreen extends StatefulWidget {
  /// Injektovatelné kvůli testům; default globální instance.
  final UnitDbService? service;
  const UnitDbListScreen({super.key, this.service});

  @override
  State<UnitDbListScreen> createState() => _UnitDbListScreenState();
}

class _UnitDbListScreenState extends State<UnitDbListScreen> {
  late final UnitDbService _service = widget.service ?? UnitDbService.instance;
  final _searchController = TextEditingController();

  List<UnitDbSummary>? _units;
  String? _error;
  String? _statusFilter; // null = vše

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _units = null;
      _error = null;
    });
    try {
      final units = await _service.fetchUnits();
      if (!mounted) return;
      setState(() => _units = units);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  List<UnitDbSummary> get _filtered {
    final q = _searchController.text;
    return (_units ?? const [])
        .where((u) => u.matches(q))
        .where((u) => _statusFilter == null || u.status == _statusFilter)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Databáze jednotek'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Obnovit',
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null
          ? _ErrorRetry(message: _error!, onRetry: _load)
          : _units == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Hledat ID / název / umístění…',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {});
                                  },
                                ),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: FilterChip(
                              label: const Text('Vše'),
                              selected: _statusFilter == null,
                              onSelected: (_) =>
                                  setState(() => _statusFilter = null),
                            ),
                          ),
                          for (final s in unitDbStatuses)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: FilterChip(
                                label: Text(unitDbStatusLabel(s)),
                                selected: _statusFilter == s,
                                onSelected: (_) => setState(() =>
                                    _statusFilter = _statusFilter == s ? null : s),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _filtered.isEmpty
                          ? Center(
                              child: Text(
                                _units!.isEmpty
                                    ? 'Databáze je prázdná — karty vznikají '
                                        'automaticky prací s jednotkami.'
                                    : 'Nic neodpovídá filtru.',
                                style: TextStyle(color: Colors.grey[600]),
                                textAlign: TextAlign.center,
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView.builder(
                                itemCount: _filtered.length,
                                itemBuilder: (context, i) => _UnitRow(
                                  unit: _filtered[i],
                                  service: _service,
                                  // Po návratu z karty seznam obnovit —
                                  // editace meta polí se má propsat hned.
                                  onReturn: _load,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  final UnitDbSummary unit;
  final UnitDbService service;

  /// Volá se po návratu z detailu — seznam se obnoví, aby změny meta polí
  /// (název, umístění, stav) byly vidět hned.
  final VoidCallback onReturn;

  const _UnitRow({
    required this.unit,
    required this.service,
    required this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: _statusColor(unit.status).withAlpha(30),
          child: Icon(Icons.memory, size: 20, color: _statusColor(unit.status)),
        ),
        title: Row(
          children: [
            Text(unit.id, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            if (unit.name != null && unit.name!.isNotEmpty)
              Expanded(
                child: Text(unit.name!, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
        subtitle: Text(
          [
            unitDbStatusLabel(unit.status),
            relativeTime(unit.lastSeen),
            if (unit.location != null && unit.location!.isNotEmpty) unit.location!,
            if (unit.firmware != null) unit.firmware!,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (unit.drift)
              const Tooltip(
                message: 'Nesouhlasí s evidencí',
                child: Icon(Icons.warning_amber, color: Colors.orange),
              ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                UnitDbDetailScreen(unitId: unit.id, service: service),
          ));
          onReturn();
        },
      ),
    );
  }
}

Color _statusColor(String status) => switch (status) {
      'active' => Colors.green,
      'faulty' => Colors.red,
      'stock' => Colors.blue,
      'retired' => Colors.grey,
      _ => Colors.grey,
    };

// ─── Detail karty ──────────────────────────────────────────────────────

class UnitDbDetailScreen extends StatefulWidget {
  final String unitId;
  final UnitDbService? service;
  const UnitDbDetailScreen({super.key, required this.unitId, this.service});

  @override
  State<UnitDbDetailScreen> createState() => _UnitDbDetailScreenState();
}

class _UnitDbDetailScreenState extends State<UnitDbDetailScreen> {
  late final UnitDbService _service = widget.service ?? UnitDbService.instance;

  UnitDbCard? _card;
  List<UnitDbEvent> _history = const [];
  String? _error;
  bool _showSecrets = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _card = null;
      _error = null;
    });
    try {
      final card = await _service.fetchUnit(widget.unitId);
      final history = await _service.fetchHistory(widget.unitId);
      if (!mounted) return;
      setState(() {
        _card = card;
        _history = history;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// „Převzít skutečnost do evidence" — záměrná změna mimo appku (broker /
  /// WiFi / jas): desired se přepíše podle observed. Credentials z původní
  /// evidence zůstávají (jednotka je nehlásí).
  Future<void> _acceptObserved() async {
    final card = _card!;
    final fragment = card.acceptObservedFragment();
    if (fragment == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Převzít skutečnost do evidence?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Evidence (desired) se přepíše podle toho, co '
                'jednotka reálně hlásí:'),
            const SizedBox(height: 8),
            for (final w in card.driftWarnings)
              Text('• $w', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            Text(
              'Hesla (broker, WiFi) v evidenci zůstávají původní — pokud se '
              'změnila taky, pošli konfiguraci přes appku.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Převzít'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await _service.saveDesired(card.id, fragment);
      messenger.showSnackBar(
          const SnackBar(content: Text('Evidence srovnána podle skutečnosti')));
      _load();
    } on UnitDbException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editMeta() async {
    final card = _card!;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _MetaDialog(card: card, service: _service),
    );
    if (saved == true) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Karta uložena')));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    return Scaffold(
      appBar: AppBar(
        title: Text('Jednotka ${widget.unitId}'),
        actions: [
          if (card != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Upravit údaje',
              onPressed: _editMeta,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Obnovit',
            onPressed: _load,
          ),
        ],
      ),
      body: _error != null
          ? _ErrorRetry(message: _error!, onRetry: _load)
          : card == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (card.driftWarnings.isNotEmpty)
                      Card(
                        color: Colors.orange.withAlpha(25),
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(children: [
                                Icon(Icons.warning_amber,
                                    color: Colors.orange, size: 20),
                                SizedBox(width: 8),
                                Text('Nesouhlasí s evidencí',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold)),
                              ]),
                              const SizedBox(height: 6),
                              for (final w in card.driftWarnings)
                                Text('• $w',
                                    style: const TextStyle(fontSize: 13)),
                              // Záměrná změna mimo appku → srovnat evidenci
                              // podle skutečnosti. (Opačný směr — nahrát
                              // evidenci do jednotky — přijde s DB5.)
                              if (card.acceptObservedFragment() != null)
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton.icon(
                                    onPressed: _acceptObserved,
                                    icon: const Icon(Icons.sync_alt, size: 18),
                                    label: const Text(
                                        'Převzít skutečnost do evidence'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    _Section(title: 'Údaje (meta)', children: [
                      _row('Název', card.name),
                      _row('Umístění', card.location),
                      _row('Stav', unitDbStatusLabel(card.status)),
                      _row('Poznámka', card.note),
                    ]),
                    _Section(title: 'Jednotka hlásí (observed)', children: [
                      _row('Naposledy viděna', relativeTime(card.lastSeen)),
                      _row('HW model', card.hwModel),
                      _row('Firmware', card.firmware),
                      _row('Generace',
                          card.generation == 'new' ? 'nová (P2L32)' : 'stará'),
                      _row('MAC', card.mac),
                      _row('IP', card.ip),
                      _row('Baterie',
                          card.battery != null ? '${card.battery} %' : null),
                      _row('WiFi (SSID)', card.ssid),
                      _row(
                          'Broker',
                          card.mqttServer != null
                              ? '${card.mqttServer}:${card.mqttPort ?? ''}'
                              : null),
                      _row('Hlásí se přes', card.seenOnBroker),
                      _row('Jas', card.brightness?.toString()),
                      // displayLabel nese i detail modulu — počet a čísla
                      // tlačítek PUM-A, volitelné LEDS („PUM-A @128 · 1 tl.
                      // (0) · LEDS"). Jeden modul na řádek.
                      if (card.devices.isNotEmpty)
                        _row(
                            'Devices',
                            card.devices
                                .map((m) => m.displayLabel)
                                .join('\n')),
                    ]),
                    _Section(
                      title: 'Odesláno appkou (desired)',
                      trailing: card.desired != null
                          ? IconButton(
                              icon: Icon(_showSecrets
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                              tooltip:
                                  _showSecrets ? 'Skrýt hesla' : 'Zobrazit hesla',
                              onPressed: () =>
                                  setState(() => _showSecrets = !_showSecrets),
                            )
                          : null,
                      children: card.desired == null
                          ? [
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  'Zatím žádná konfigurace přes appku — '
                                  'vyplní se první změnou brokeru/WiFi/jasu.',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ),
                            ]
                          : _desiredRows(card),
                    ),
                    _Section(
                      title: 'Historie',
                      children: _history.isEmpty
                          ? [
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text('Žádné záznamy.',
                                    style: TextStyle(color: Colors.grey[600])),
                              ),
                            ]
                          : [
                              for (final e in _history)
                                ListTile(
                                  dense: true,
                                  leading: Icon(_actionIcon(e.action), size: 20),
                                  title: Text(
                                      '${_actionLabel(e.action)} — ${e.username}'),
                                  subtitle: Text(
                                    '${e.at} UTC'
                                    '${e.detail != null ? '\n${_detailSummary(e.detail!)}' : ''}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                    ),
                  ],
                ),
    );
  }

  List<Widget> _desiredRows(UnitDbCard card) {
    final d = card.desired!;
    String secret(dynamic v) =>
        v == null ? '—' : (_showSecrets ? v.toString() : '••••••');
    final rows = <Widget>[];
    final broker = d['broker'];
    if (broker is Map) {
      rows.add(_row('Broker',
          '${broker['address']}:${broker['port'] ?? ''} (user: ${broker['user'] ?? '—'})'));
      rows.add(_row('Broker heslo', secret(broker['password'])));
    }
    final wifi = d['wifi'];
    if (wifi is Map) {
      rows.add(_row('WiFi (SSID)', wifi['ssid']?.toString()));
      rows.add(_row('WiFi heslo', secret(wifi['password'])));
    }
    if (d['brightness'] != null) {
      rows.add(_row('Jas P2L LED', d['brightness'].toString()));
    }
    if (d['dispBrightness'] != null) {
      rows.add(_row('Jas PUM-A displejů', d['dispBrightness'].toString()));
    }
    if (d['fwUrl'] != null) rows.add(_row('Poslední OTA', d['fwUrl'].toString()));
    rows.add(_row(
        'Zapsáno',
        card.desiredUpdatedBy != null
            ? '${card.desiredUpdatedBy} (${card.desiredUpdatedAt ?? ''} UTC)'
            : null));
    return rows;
  }

  Widget _row(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: TextStyle(color: Colors.grey[600])),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

String _actionLabel(String action) => switch (action) {
      'desired' => 'Konfigurace',
      'meta' => 'Údaje karty',
      'change_id' => 'Změna ID',
      _ => action,
    };

IconData _actionIcon(String action) => switch (action) {
      'desired' => Icons.settings_remote,
      'meta' => Icons.edit_note,
      'change_id' => Icons.tag,
      _ => Icons.history,
    };

/// Kompaktní shrnutí detailu historie: klíče + primitivní hodnoty.
String _detailSummary(Map<String, dynamic> detail) {
  final parts = <String>[];
  detail.forEach((k, v) {
    if (v is Map) {
      parts.add('$k: ${v.keys.join('/')}');
    } else {
      parts.add('$k: $v');
    }
  });
  return parts.join(' · ');
}

// ─── Dialog editace meta polí ──────────────────────────────────────────

class _MetaDialog extends StatefulWidget {
  final UnitDbCard card;
  final UnitDbService service;
  const _MetaDialog({required this.card, required this.service});

  @override
  State<_MetaDialog> createState() => _MetaDialogState();
}

class _MetaDialogState extends State<_MetaDialog> {
  late final _name = TextEditingController(text: widget.card.name ?? '');
  late final _location = TextEditingController(text: widget.card.location ?? '');
  late final _note = TextEditingController(text: widget.card.note ?? '');
  late String _status = widget.card.status;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.saveMeta(
        widget.card.id,
        name: _name.text.trim(),
        location: _location.text.trim(),
        note: _note.text.trim(),
        status: _status,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Jednotka ${widget.card.id} — údaje'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Název'),
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _location,
              enabled: !_busy,
              decoration:
                  const InputDecoration(labelText: 'Umístění (sklad, regál…)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Poznámka'),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Stav'),
              items: [
                for (final s in unitDbStatuses)
                  DropdownMenuItem(value: s, child: Text(unitDbStatusLabel(s))),
              ],
              onChanged: _busy ? null : (v) => setState(() => _status = v!),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Uložit'),
        ),
      ],
    );
  }
}

// ─── Sdílené widgety ───────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;
  const _Section({required this.title, this.trailing, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(title,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Zkusit znovu'),
            ),
          ],
        ),
      ),
    );
  }
}
