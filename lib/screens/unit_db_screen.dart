// Obrazovka „Databáze jednotek" (PRD-DB/01-PRD.md §6.1, milestone DB4).
//
// Vstup: položka v hamburger menu HomeScreen (jen pro přihlášené).
// Seznam: jedno vyhledávací pole (filtruje přes ID + název + umístění),
// chipy stavu, řádky s ID / názvem / stavem / relativním last_seen /
// firmware. Detail: Údaje (meta) + Konfigurace (jeden řádek na parametr se
// třemi sloučenými pohledy evidence/uloženo/běží, PRD-DB v2 §2.4) + Jednotka
// (observed metadata) + historie; editace meta polí, drift indikace
// („Nesouhlasí s evidencí").
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
  String? _customerFilter; // null = vše
  String? _brokerFilter; // null = vše
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
      setState(() {
        _units = units;
        // Po obnově zahoď filtry, které už v datech neexistují (zákazník
        // přejmenován/smazán), ať dropdown neukazuje mrtvou volbu.
        if (_customerFilter != null && !_customers.contains(_customerFilter)) {
          _customerFilter = null;
        }
        if (_brokerFilter != null && !_brokers.contains(_brokerFilter)) {
          _brokerFilter = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// Unikátní neprázdní zákazníci napříč načtenými jednotkami (pro dropdown).
  List<String> get _customers {
    final set = <String>{};
    for (final u in _units ?? const <UnitDbSummary>[]) {
      if (u.name != null && u.name!.isNotEmpty) set.add(u.name!);
    }
    return set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Unikátní neprázdné brokery napříč načtenými jednotkami (pro dropdown).
  List<String> get _brokers {
    final set = <String>{};
    for (final u in _units ?? const <UnitDbSummary>[]) {
      if (u.broker != null && u.broker!.isNotEmpty) set.add(u.broker!);
    }
    return set.toList()..sort();
  }

  List<UnitDbSummary> get _filtered {
    final q = _searchController.text;
    return (_units ?? const [])
        .where((u) => u.matches(q))
        .where((u) => _customerFilter == null || u.name == _customerFilter)
        .where((u) => _brokerFilter == null || u.broker == _brokerFilter)
        .where((u) => _statusFilter == null || u.status == _statusFilter)
        .toList();
  }

  bool get _hasActiveFilter =>
      _customerFilter != null || _brokerFilter != null || _statusFilter != null;

  void _resetFilters() => setState(() {
        _customerFilter = null;
        _brokerFilter = null;
        _statusFilter = null;
      });

  /// Sjednocené rozevírací pole filtru (Zákazník / Broker / Stav).
  /// `value == null` → vybráno „Vše".
  Widget _filterDropdown({
    required String label,
    required String? value,
    required List<DropdownMenuItem<String?>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String?>(
      // Klíč závislý na hodnotě → po externím resetu (_resetFilters) se pole
      // překreslí na „Vše"; FormField jinak drží vnitřní stav a initialValue
      // po prvním sestavení ignoruje.
      key: ValueKey('$label:$value'),
      initialValue: value,
      isExpanded: true,
      style: Theme.of(context)
          .textTheme
          .bodyMedium
          ?.copyWith(fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12),
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      items: items,
      onChanged: onChanged,
    );
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
                          hintText: 'Hledat ID / zákazník / umístění…',
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: _filterDropdown(
                              label: 'Zákazník',
                              value: _customerFilter,
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null, child: Text('Vše')),
                                for (final c in _customers)
                                  DropdownMenuItem<String?>(
                                    value: c,
                                    child: Text(c,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _customerFilter = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _filterDropdown(
                              label: 'Broker',
                              value: _brokerFilter,
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null, child: Text('Vše')),
                                for (final b in _brokers)
                                  DropdownMenuItem<String?>(
                                    value: b,
                                    child: Text(b,
                                        overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _brokerFilter = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _filterDropdown(
                              label: 'Stav',
                              value: _statusFilter,
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null, child: Text('Vše')),
                                for (final s in unitDbStatuses)
                                  DropdownMenuItem<String?>(
                                    value: s,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 10,
                                          height: 10,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: _statusColor(s),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(unitDbStatusLabel(s)),
                                      ],
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _statusFilter = v),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.filter_alt_off_outlined),
                            iconSize: 20,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Zrušit filtry',
                            onPressed: _hasActiveFilter ? _resetFilters : null,
                          ),
                        ],
                      ),
                    ),
                    // Vizuální oddělení filtrů od seznamu jednotek.
                    const Divider(height: 1, thickness: 1),
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
    // Plochý dvouřádkový řádek ve stylu seznamu jednotek na HomeScreen
    // (Container se spodním okrajem, kompaktní padding, barevná tečka stavu).
    final statusColor = _statusColor(unit.status);
    final hasName = unit.name != null && unit.name!.isNotEmpty;
    final hasBroker = unit.broker != null && unit.broker!.isNotEmpty;
    // Stav (aktivní/vadná/…) nese barevná tečka na začátku druhého řádku;
    // význam barev vysvětluje filtr „Stav" nahoře (barevné tečky u položek).
    final subtitleRest = [
      relativeTime(unit.lastSeen),
      if (unit.location != null && unit.location!.isNotEmpty) unit.location!,
      if (unit.firmware != null) unit.firmware!,
    ].join(' · ');

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.withAlpha(50))),
      ),
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                UnitDbDetailScreen(unitId: unit.id, service: service),
          ));
          onReturn();
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          unit.id,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        if (hasName) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              unit.name!,
                              style: const TextStyle(fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        if (hasBroker) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.dns_outlined,
                              size: 13, color: Colors.grey[500]),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              unit.broker!,
                              style:
                                  TextStyle(fontSize: 12, color: Colors.grey[600]),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            subtitleRest,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[600]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (unit.drift) ...[
                const SizedBox(width: 6),
                const Tooltip(
                  message: 'Nesouhlasí s evidencí',
                  child: Icon(Icons.warning_amber,
                      color: Colors.orange, size: 20),
                ),
              ],
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 20, color: Colors.grey[500]),
            ],
          ),
        ),
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
                      _row('Zákazník', card.name),
                      _row('Umístění', card.location),
                      _row('Stav', unitDbStatusLabel(card.status)),
                      _row('Poznámka', card.note),
                    ]),
                    _configCard(card),
                    _unitCard(card),
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
                                    formatTimestamp(e.at) +
                                        (e.detail != null
                                            ? '\n${_detailSummary(e.detail!)}'
                                            : ''),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                            ],
                    ),
                  ],
                ),
    );
  }

  /// Sekce „Konfigurace" — jeden řádek na parametr se třemi pohledy
  /// (evidence = desired / uloženo = GET-CONFIG NVS / běží = actualIp/actualSSID
  /// + get_param). Shoda více zdrojů → jedna hodnota + ✓, rozdíl → rozepsané
  /// pohledy pod sebou (PRD-DB v2 §2.4). Starý FW bez GET-CONFIG → míň pohledů,
  /// degraduje na dnešní jednu hodnotu. Hesla maskovaná, oko je odkryje.
  Widget _configCard(UnitDbCard card) {
    final cfg = card.unitConfig; // uloženo v NVS (může být null)
    final d = card.desired; // evidence

    // ── evidence (desired) ──
    Map? dBroker = d?['broker'] is Map ? d!['broker'] as Map : null;
    Map? dWifi = d?['wifi'] is Map ? d!['wifi'] as Map : null;
    String? str(dynamic v) => (v is String && v.isNotEmpty) ? v : null;
    String? cfgStr(String k) => str(cfg?[k]);
    String? hostPort(String? host, dynamic port) =>
        host == null ? null : '$host:${port ?? ''}';
    String? boolText(dynamic v, String yes, String no) =>
        v == true ? yes : (v == false ? no : null);

    final evBrokerUser = dBroker != null ? str(dBroker['address']) : null;
    final evBroker = evBrokerUser != null
        ? hostPort(evBrokerUser, dBroker!['port'])
        : null;
    final evWifi = dWifi != null ? str(dWifi['ssid']) : null;

    // ── uloženo (GET-CONFIG NVS) ──
    final stBroker = hostPort(cfgStr('mqttAddress'), cfg?['mqttPort']);
    final stWifi = cfgStr('SSID');

    // ── běží (actual / get_param) ──
    final rnBroker = hostPort(card.mqttServer, card.mqttPort);
    final rnWifi = cfgStr('actualSSID') ?? card.ssid;

    // „Hlásí se přes" (kde appka jednotku vidí) ukázat jen když přináší novou
    // informaci — tj. liší se od hostů už zobrazených v řádku Broker. Při
    // shodě je to jen šum (§2.4: rozepisuje se jen rozdíl).
    final brokerHosts = {evBrokerUser, cfgStr('mqttAddress'), card.mqttServer}
      ..removeWhere((h) => h == null || h.isEmpty);
    final seenOn = (card.seenOnBroker != null &&
            card.seenOnBroker!.isNotEmpty &&
            !brokerHosts.contains(card.seenOnBroker))
        ? card.seenOnBroker
        : null;

    // Oko jen když je co odkrýt (skutečná hesla jako string kdekoli).
    final hasSecrets = (dBroker?['password'] is String) ||
        (dWifi?['password'] is String) ||
        cfg?['PSWD'] is String ||
        cfg?['mqttPassword'] is String;

    final children = <Widget>[
      _triRow('Broker', evidence: evBroker, stored: stBroker, running: rnBroker),
      _row('Hlásí se přes', seenOn),
      _triRow('MQTT uživatel',
          evidence: dBroker != null ? str(dBroker['user']) : null,
          stored: cfgStr('mqttUser')),
      _secretRow('Broker heslo',
          evidence: dBroker?['password'], stored: cfg?['mqttPassword']),
      _row('TLS validace certifikátu',
          boolText(cfg?['mqttInsec'], 'vypnutá (insecure)', 'zapnutá')),
      _row('Vlastní CA certifikát', boolText(cfg?['mqttCert'], 'uložen', 'ne')),
      _triRow('WiFi (SSID)', evidence: evWifi, stored: stWifi, running: rnWifi),
      _secretRow('WiFi heslo',
          evidence: dWifi?['password'], stored: cfg?['PSWD']),
      // IP: evidence nemá; uloženo=ip (statická), běží=actualIp/get_param.
      // DHCP anotace jen když známe NVS (jinak nevíme statická vs. DHCP).
      _triRow('IP',
          stored: cfgStr('ip'),
          running: cfgStr('actualIp') ?? card.ip,
          dhcp: cfg != null),
      _row('DNS', cfgStr('dns')),
      _row('Brána', cfgStr('gateway')),
      _row('Maska', cfgStr('subnet')),
      _triRow('Jas P2L LED',
          evidence: (d?['brightness'])?.toString(),
          running: card.brightness?.toString()),
      _row('Jas PUM-A displejů', (d?['dispBrightness'])?.toString()),
      _row('Poslední OTA', str(d?['fwUrl'])),
      // Původ dat (zdroj/čas) — malým písmem dole.
      _row(
          'Evidence zapsána',
          card.desiredUpdatedBy != null
              ? '${card.desiredUpdatedBy} (${formatTimestamp(card.desiredUpdatedAt)})'
              : null),
      _row('Konfigurace načtena',
          cfg != null ? formatTimestamp(card.unitConfigFetchedAt) : null),
    ];

    // Všechny řádky prázdné (žádná evidence ani GET-CONFIG) → přátelská hláška.
    final anyContent = children.any((w) => w is! SizedBox);
    return _Section(
      title: 'Konfigurace',
      trailing: hasSecrets
          ? IconButton(
              icon: Icon(
                  _showSecrets ? Icons.visibility_off : Icons.visibility),
              tooltip: _showSecrets ? 'Skrýt hesla' : 'Zobrazit hesla',
              onPressed: () => setState(() => _showSecrets = !_showSecrets),
            )
          : null,
      children: anyContent
          ? children
          : [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Zatím žádná konfigurace — evidence se vyplní první změnou '
                  'brokeru/WiFi/jasu, uložený stav načtením GET-CONFIG.',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            ],
    );
  }

  /// Sekce „Jednotka" — observed metadata bez rozlišení pohledů (HW model,
  /// firmware, generace, MAC, baterie, last_seen, devices).
  Widget _unitCard(UnitDbCard card) {
    return _Section(title: 'Jednotka', children: [
      _row('Naposledy viděna', relativeTime(card.lastSeen)),
      _row('HW model', card.hwModel),
      _row('Firmware', card.firmware),
      _row('Generace', card.generation == 'new' ? 'nová (P2L32)' : 'stará'),
      _row('MAC', card.mac),
      _row('Baterie', card.battery != null ? '${card.battery} %' : null),
      // displayLabel nese i detail modulu — počet a čísla tlačítek PUM-A,
      // volitelné LEDS („PUM-A @128 · 1 tl. (0) · LEDS"). Jeden modul na řádek.
      if (card.devices.isNotEmpty)
        _row('Devices', card.devices.map((m) => m.displayLabel).join('\n')),
    ]);
  }

  /// Řádek se třemi pohledy. Shoda ≥2 zdrojů → „hodnota ✓"; jediný zdroj →
  /// holá hodnota; rozdíl → label + odsazené popsané pohledy. `dhcp` → prázdná
  /// / „0.0.0.0" uložená IP znamená statickou vypnutou (běží DHCP).
  Widget _triRow(String label,
      {String? evidence, String? stored, String? running, bool dhcp = false}) {
    String? norm(String? v) => (v != null && v.isNotEmpty) ? v : null;
    final ev = norm(evidence), st = norm(stored), rn = norm(running);

    if (dhcp && (st == null || st == '0.0.0.0')) {
      if (rn == null && ev == null) return const SizedBox.shrink();
      return _row(label, rn != null ? '$rn (DHCP)' : ev!);
    }

    final views = <MapEntry<String, String>>[
      if (ev != null) MapEntry('evidence', ev),
      if (st != null) MapEntry('uloženo', st),
      if (rn != null) MapEntry('běží', rn),
    ];
    if (views.isEmpty) return const SizedBox.shrink();

    if (views.map((e) => e.value).toSet().length == 1) {
      final v = views.first.value;
      return _row(label, views.length >= 2 ? '$v  ✓' : v);
    }
    // Pohledy se liší → rozepsat pod sebou.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 2),
          for (final e in views)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 66,
                    child: Text(e.key,
                        style:
                            TextStyle(color: Colors.grey[500], fontSize: 12)),
                  ),
                  Expanded(child: SelectableText(e.value)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Řádek s heslem (tri-state §4). Skutečnou hodnotu preferuj z jednotky
  /// (GET-CONFIG string), pak z evidence (desired); maskovaná, oko odkryje.
  /// Jen `true` = „nastaveno" (hodnota neznámá). Nikdy nehlásí „změněno".
  Widget _secretRow(String label, {dynamic evidence, dynamic stored}) {
    String? real;
    if (stored is String && stored.isNotEmpty) {
      real = stored;
    } else if (evidence is String && evidence.isNotEmpty) {
      real = evidence;
    }
    if (real != null) {
      return _row(label, _showSecrets ? real : '••••••');
    }
    if (stored == true || evidence == true) return _row(label, 'nastaveno');
    return const SizedBox.shrink();
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
              decoration: const InputDecoration(labelText: 'Zákazník'),
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
