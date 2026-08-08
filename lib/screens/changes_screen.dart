// Obrazovka „Změny" — audit napříč jednotkami (DB12, PRD-DB/03-PRD-sync.md §8).
//
// Historie jedné karty je na kartě samotné; tady jde o otázku „kdo kdy co
// změnil" napříč celou evidencí, s filtry a stránkováním.
//
// Audit je serverová veličina (lokální DB drží jen změny z tohohle zařízení),
// takže offline se ukáže aspoň ta lokální část a řekne se to.

import 'package:flutter/material.dart';

import '../models/unit_db.dart';
import '../services/unit_db_service.dart';
import '../services/unit_ids_io.dart';

class ChangesScreen extends StatefulWidget {
  const ChangesScreen({super.key, this.unitId});

  /// Předvyplněný filtr jednotky (otevřeno z karty).
  final String? unitId;

  @override
  State<ChangesScreen> createState() => _ChangesScreenState();
}

class _ChangesScreenState extends State<ChangesScreen> {
  static const _pageSize = 50;

  final _service = UnitDbService.instance;
  final _unitController = TextEditingController();

  final List<UnitDbEvent> _events = [];
  UnitDbAuditFilters _filters = const UnitDbAuditFilters();
  String? _username;
  String? _layer;
  String? _origin;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _localOnly = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _unitController.text = widget.unitId ?? '';
    _load();
  }

  @override
  void dispose() {
    _unitController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _localOnly = false;
    });
    try {
      final page = await _service.fetchAudit(
        unitId: _unitController.text.trim(),
        username: _username,
        layer: _layer,
        origin: _origin,
        limit: _pageSize,
      );
      // Nabídky filtrů se plní z dat; když selžou, není to důvod nic nezobrazit.
      UnitDbAuditFilters filters = _filters;
      try {
        filters = await _service.fetchAuditFilters();
      } catch (_) {
        // ponech předchozí
      }
      if (!mounted) return;
      setState(() {
        _events
          ..clear()
          ..addAll(page.events);
        _hasMore = page.hasMore;
        _filters = filters;
        _loading = false;
      });
    } on UnitDbException catch (e) {
      // Offline: serverový audit není, ale lokální změny ukázat můžeme.
      final local = await _service.fetchLocalAudit();
      if (!mounted) return;
      setState(() {
        _events
          ..clear()
          ..addAll(local);
        _hasMore = false;
        _loading = false;
        _localOnly = local.isNotEmpty;
        _error = local.isEmpty ? e.message : null;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _service.fetchAudit(
        unitId: _unitController.text.trim(),
        username: _username,
        layer: _layer,
        origin: _origin,
        limit: _pageSize,
        offset: _events.length,
      );
      if (!mounted) return;
      setState(() {
        _events.addAll(page.events);
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } on UnitDbException catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _clearFilters() {
    _unitController.clear();
    setState(() {
      _username = null;
      _layer = null;
      _origin = null;
    });
    _load();
  }

  bool get _hasFilter =>
      _unitController.text.trim().isNotEmpty ||
      _username != null ||
      _layer != null ||
      _origin != null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Změny v databázi'),
        actions: [
          if (_hasFilter)
            IconButton(
              icon: const Icon(Icons.filter_alt_off_outlined),
              tooltip: 'Zrušit filtry',
              onPressed: _clearFilters,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Obnovit',
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          _filterBar(),
          if (_localOnly)
            Container(
              width: double.infinity,
              color: Colors.orange.withAlpha(30),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: const Text(
                'Server není dostupný — ukazují se jen změny z tohoto zařízení.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          TextField(
            controller: _unitController,
            onSubmitted: (_) => _load(),
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: 'ID P2L modulu (prázdné = všechny)',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                tooltip: 'Filtrovat',
                onPressed: _load,
              ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _dropdown(
                  label: 'Uživatel',
                  value: _username,
                  items: _filters.usernames,
                  onChanged: (v) {
                    setState(() => _username = v);
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _dropdown(
                  label: 'Co',
                  value: _layer,
                  items: _filters.layers,
                  labelFor: (v) => switch (v) {
                    'desired' => 'Evidence',
                    'meta' => 'Údaje',
                    'observed' => 'Stav',
                    'delete' => 'Smazání',
                    'change_id' => 'Přečíslování',
                    _ => v,
                  },
                  onChanged: (v) {
                    setState(() => _layer = v);
                    _load();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _dropdown(
                  label: 'Odkud',
                  value: _origin,
                  items: _filters.origins,
                  labelFor: (v) => switch (v) {
                    'online' => 'Online',
                    'sync' => 'Sync',
                    'mqtt' => 'MQTT',
                    _ => v,
                  },
                  onChanged: (v) {
                    setState(() => _origin = v);
                    _load();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dropdown({
    required String label,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    String Function(String)? labelFor,
  }) {
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Vše')),
        for (final item in items)
          DropdownMenuItem<String?>(
            value: item,
            child: Text(
              labelFor?.call(item) ?? item,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off, size: 40, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
    }
    if (_events.isEmpty) {
      return const Center(child: Text('Žádné změny neodpovídají filtru.'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _events.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == _events.length) {
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: _loadingMore
                    ? const CircularProgressIndicator()
                    : OutlinedButton(
                        onPressed: _loadMore,
                        child: const Text('Načíst další'),
                      ),
              ),
            );
          }
          return _EventTile(event: _events[i]);
        },
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final UnitDbEvent event;

  @override
  Widget build(BuildContext context) {
    final origin = event.originLabel;
    return ListTile(
      dense: true,
      leading: Icon(_icon, size: 20, color: _color),
      title: Text(
        '${event.unitId != null ? '${plainUnitId(event.unitId!)} · ' : ''}'
        '${event.actionLabel}',
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              _fmtTime(event.at),
              event.username,
              if (origin.isNotEmpty) origin,
              if (event.sourceDevice != null) event.sourceDevice!,
            ].join(' · '),
            style: const TextStyle(fontSize: 11),
          ),
          if (event.detail != null && event.detail!.isNotEmpty)
            Text(
              _describe(event.detail!),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
        ],
      ),
    );
  }

  IconData get _icon => switch (event.action) {
        'desired' => Icons.settings_ethernet,
        'meta' => Icons.label_outline,
        'delete' => Icons.delete_outline,
        'change_id' => Icons.tag,
        'superseded_local' => Icons.merge_type,
        'import' => Icons.file_upload_outlined,
        _ => Icons.circle_outlined,
      };

  Color? get _color => switch (event.action) {
        'delete' => Colors.red,
        'superseded_local' => Colors.orange,
        _ => null,
      };

  /// Hesla jsou zamaskovaná už od zápisu (scrubSecrets na serveru), takže se
  /// detail vypisuje, jak přišel.
  static String _describe(Map<String, dynamic> detail) {
    final parts = <String>[];
    detail.forEach((k, v) {
      if (v is Map) {
        parts.add('$k: ${v.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
      } else {
        parts.add('$k=$v');
      }
    });
    return parts.join(' · ');
  }

  static String _fmtTime(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    final d = '${t.day}.${t.month}.';
    final hm = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    return '$d $hm';
  }
}
