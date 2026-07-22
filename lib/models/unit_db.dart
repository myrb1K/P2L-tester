// Modely karet centrální databáze jednotek (PRD-DB, milestone DB4).
// Mapují JSON z `/api/units` endpointů (server/routes/units.js).

import 'module.dart';

/// Řádek seznamu `GET /api/units` — bez desired (hesla) a bez devices.
class UnitDbSummary {
  final String id;
  final String generation; // 'old' | 'new'
  final String? mac;
  final String? name;
  final String? location;
  final String status; // active | faulty | stock | retired
  final DateTime? lastSeen;
  final String? firmware;
  final String? ip;
  final double? battery;

  /// Adresa brokeru pro řádek seznamu (server ji odvodí: GET-CONFIG
  /// mqttAddress → get_param mqtt_server → seen_on_broker). Není tajná.
  final String? broker;

  /// Nesoulad desired vs. observed (broker/SSID/jas) — počítá server, aby
  /// seznam nemusel nést desired (hesla). Detail viz UnitDbCard.driftWarnings.
  final bool drift;

  const UnitDbSummary({
    required this.id,
    required this.generation,
    this.mac,
    this.name,
    this.location,
    required this.status,
    this.lastSeen,
    this.firmware,
    this.ip,
    this.battery,
    this.broker,
    this.drift = false,
  });

  factory UnitDbSummary.fromJson(Map<String, dynamic> json) => UnitDbSummary(
        id: json['id'] as String,
        generation: json['generation'] as String? ?? 'new',
        mac: json['mac'] as String?,
        name: json['name'] as String?,
        location: json['location'] as String?,
        status: json['status'] as String? ?? 'active',
        lastSeen: _parseTime(json['last_seen']),
        firmware: json['firmware'] as String?,
        ip: json['ip'] as String?,
        battery: (json['battery'] as num?)?.toDouble(),
        broker: json['broker'] as String?,
        drift: json['drift'] as bool? ?? false,
      );

  /// Case-insensitive filtr přes ID + název + umístění (vyhledávací pole).
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return id.toLowerCase().contains(q) ||
        (name?.toLowerCase().contains(q) ?? false) ||
        (location?.toLowerCase().contains(q) ?? false);
  }
}

/// Kompletní karta `GET /api/units/:id` — všechny tři vrstvy.
class UnitDbCard {
  final String id;
  final String generation;
  final String? mac;
  // observed
  final String? hwModel;
  final String? firmware;
  final String? ip;
  final double? battery;
  final String? ssid;
  final String? mqttServer;
  final int? mqttPort;
  final int? brightness;

  /// Host brokeru, přes který appka jednotku naposledy viděla (každý ALIVE) —
  /// na rozdíl od [mqttServer], který jednotka hlásí jen v get_param.
  final String? seenOnBroker;

  /// Snapshot z UNIT GET-CONFIG (FW ≥ P2L_26071501NT) 1:1 — uložená konfigurace
  /// (`mqttAddress`/`SSID`/`ip`/`dns`/…, hesla jako bool) i reálný stav
  /// (`actualIp`/`actualSSID`). `null` u staré generace / staršího FW → drift
  /// degraduje na porovnání proti get_param hodnotám. (PRD-DB v2 §2.1.)
  final Map<String, dynamic>? unitConfig;
  final String? unitConfigFetchedAt;
  final DateTime? lastSeen;
  final List<PumaModule> devices;
  // desired
  final Map<String, dynamic>? desired;
  final String? desiredUpdatedAt;
  final String? desiredUpdatedBy;
  // meta
  final String? name;
  final String? location;
  final String? note;
  final String status;

  const UnitDbCard({
    required this.id,
    required this.generation,
    this.mac,
    this.hwModel,
    this.firmware,
    this.ip,
    this.battery,
    this.ssid,
    this.mqttServer,
    this.mqttPort,
    this.brightness,
    this.seenOnBroker,
    this.unitConfig,
    this.unitConfigFetchedAt,
    this.lastSeen,
    this.devices = const [],
    this.desired,
    this.desiredUpdatedAt,
    this.desiredUpdatedBy,
    this.name,
    this.location,
    this.note,
    required this.status,
  });

  factory UnitDbCard.fromJson(Map<String, dynamic> json) {
    final rawDevices = json['devices'];
    final devices = <PumaModule>[];
    if (rawDevices is List) {
      for (final d in rawDevices) {
        try {
          devices.add(PumaModule.fromJson(d as Map<String, dynamic>));
        } catch (_) {
          // neznámý formát device záznamu — přeskočit, karta se zobrazí i tak
        }
      }
    }
    return UnitDbCard(
      id: json['id'] as String,
      generation: json['generation'] as String? ?? 'new',
      mac: json['mac'] as String?,
      hwModel: json['hw_model'] as String?,
      firmware: json['firmware'] as String?,
      ip: json['ip'] as String?,
      battery: (json['battery'] as num?)?.toDouble(),
      ssid: json['ssid'] as String?,
      mqttServer: json['mqtt_server'] as String?,
      mqttPort: json['mqtt_port'] as int?,
      brightness: json['brightness'] as int?,
      seenOnBroker: json['seen_on_broker'] as String?,
      unitConfig: json['unit_config'] as Map<String, dynamic>?,
      unitConfigFetchedAt: json['unit_config_fetched_at'] as String?,
      lastSeen: _parseTime(json['last_seen']),
      devices: devices,
      desired: json['desired'] as Map<String, dynamic>?,
      desiredUpdatedAt: json['desired_updated_at'] as String?,
      desiredUpdatedBy: json['desired_updated_by'] as String?,
      name: json['name'] as String?,
      location: json['location'] as String?,
      note: json['note'] as String?,
      status: json['status'] as String? ?? 'active',
    );
  }

  /// Nenulový a neprázdný String z GET-CONFIG snapshotu (jinak null).
  String? _cfgStr(String key) {
    final v = unitConfig?[key];
    return (v is String && v.isNotEmpty) ? v : null;
  }

  /// Drift v2 (PRD-DB v2 §6) — tři kategorie nesouladu. Vrací lidské popisy;
  /// prázdné = OK / nelze porovnat (jedna strana chybí). Bez GET-CONFIG
  /// (starý FW) degraduje na dnešní porovnání proti get_param hodnotám.
  ///   1) evidence ↔ uloženo v NVS (dorazila naše konfigurace?)
  ///   2) uloženo ↔ reálně běží (statická IP, ale jede DHCP / jiné SSID)
  ///   3) evidence ↔ kde ji vidíme (hlásí se přes jiný broker)
  /// „Nesoulad" má smysl jen když jsme jednotku viděli AŽ PO poslední změně
  /// evidence. Čerstvá, ještě nepozorovaná změna (jednotka přešla na jiný
  /// broker / je offline) je „čekající" — potvrzená ackem, ale realita ještě
  /// nepřečtena → nic nehlásíme. Neznámý čas změny → neblokuj.
  bool get _observedSinceChange {
    final changed = _parseTime(desiredUpdatedAt);
    if (changed == null) return true;
    if (lastSeen == null) return false;
    return !lastSeen!.isBefore(changed);
  }

  List<String> get driftWarnings {
    if (!_observedSinceChange) return const [];
    final out = <String>[];
    final broker = desired?['broker'];
    final wifi = desired?['wifi'];
    final cfgBroker = _cfgStr('mqttAddress');
    final cfgSsid = _cfgStr('SSID');
    final actualIp = _cfgStr('actualIp');
    final cfgIp = _cfgStr('ip');
    final actualSsid = _cfgStr('actualSSID');

    // 1) evidence ↔ uloženo v jednotce (GET-CONFIG)
    if (broker is Map) {
      final want = broker['address'];
      if (want is String && want.isNotEmpty && cfgBroker != null && want != cfgBroker) {
        out.add('Broker: evidence „$want", uloženo v jednotce „$cfgBroker"');
      }
    }
    if (wifi is Map) {
      final want = wifi['ssid'];
      if (want is String && want.isNotEmpty) {
        if (cfgSsid != null) {
          if (want != cfgSsid) {
            out.add('WiFi: evidence „$want", uloženo v jednotce „$cfgSsid"');
          }
        } else if (ssid != null && want != ssid) {
          // Bez GET-CONFIG degraduj na get_param SSID (starý FW).
          out.add('WiFi: evidence „$want", jednotka hlásí „$ssid"');
        }
      }
    }

    // 2) uloženo ↔ reálně běží (jen z GET-CONFIG). Prázdná / "0.0.0.0"
    // konfigurovaná IP = statická vypnutá (DHCP) → _cfgStr vrátí null, tady
    // se nastavené vs. běžící neporovnává.
    if (cfgIp != null && cfgIp != '0.0.0.0' && actualIp != null && cfgIp != actualIp) {
      out.add('IP: nastaveno „$cfgIp", ale běží „$actualIp" (statická IP se neuplatnila?)');
    }
    if (cfgSsid != null && actualSsid != null && cfgSsid != actualSsid) {
      out.add('WiFi: nastaveno „$cfgSsid", ale připojeno k „$actualSsid"');
    }

    // 3) evidence ↔ kde jednotku vidíme (broker connectivity). mqtt_server =
    // co jednotka hlásí v get_param, seenOnBroker = přes co ji appka vidí.
    if (broker is Map) {
      final want = broker['address'];
      if (want is String && want.isNotEmpty) {
        // „jednotka hlásí" (running) ukaž jen když přidává novou informaci —
        // tj. liší se od toho, co je uložené v NVS (kat. 1). Když se běžící
        // broker shoduje s uloženým, kat. 1 už to řekla → nedupluj.
        if (mqttServer != null && want != mqttServer && mqttServer != cfgBroker) {
          out.add('Broker: evidence „$want", jednotka hlásí „$mqttServer"');
        }
        if (seenOnBroker != null && want != seenOnBroker && seenOnBroker != mqttServer) {
          out.add('Broker: evidence „$want", jednotka se hlásí přes „$seenOnBroker"');
        }
      }
    }

    // Jas — UNIT GET-CONFIG jej nenese; drift dál z get_param brightness.
    final wantBrightness = desired?['brightness'];
    if (wantBrightness is int && brightness != null && wantBrightness != brightness) {
      out.add('Jas: evidence $wantBrightness, jednotka hlásí $brightness');
    }
    return out;
  }

  /// „Převzít skutečnost do evidence" — fragment desired, který srovná
  /// evidenci podle skutečné konfigurace jednotky (pro záměrné změny mimo
  /// appku). Preferuje autoritativní GET-CONFIG (`mqttAddress`/`SSID`),
  /// fallback get_param (`mqttServer`) / seen-on. Credentials (broker
  /// user/password, WiFi heslo) z původní evidence ZŮSTÁVAJÍ — jednotka je
  /// nehlásí. `null` = není co přebírat.
  Map<String, dynamic>? acceptObservedFragment() {
    final out = <String, dynamic>{};
    final broker = desired?['broker'];
    final observedHost = _cfgStr('mqttAddress') ?? mqttServer ?? seenOnBroker;
    final observedPort = unitConfig?['mqttPort'] as int? ?? mqttPort;
    if (broker is Map && observedHost != null && observedHost.isNotEmpty) {
      final want = broker['address'];
      if (want is String && want.isNotEmpty && want != observedHost) {
        out['broker'] = {
          ...Map<String, dynamic>.from(broker),
          'address': observedHost,
          'port': ?observedPort,
        };
      }
    }
    final wifi = desired?['wifi'];
    final observedSsid = _cfgStr('SSID') ?? ssid;
    if (wifi is Map && observedSsid != null && observedSsid.isNotEmpty) {
      final want = wifi['ssid'];
      if (want is String && want.isNotEmpty && want != observedSsid) {
        out['wifi'] = {...Map<String, dynamic>.from(wifi), 'ssid': observedSsid};
      }
    }
    final wantB = desired?['brightness'];
    if (wantB is int && brightness != null && wantB != brightness) {
      out['brightness'] = brightness;
    }
    return out.isEmpty ? null : out;
  }
}

/// Záznam historie `GET /api/units/:id/history`.
class UnitDbEvent {
  final String at;
  final String username;
  final String action; // desired | meta | change_id | ...
  final Map<String, dynamic>? detail;

  const UnitDbEvent({
    required this.at,
    required this.username,
    required this.action,
    this.detail,
  });

  factory UnitDbEvent.fromJson(Map<String, dynamic> json) => UnitDbEvent(
        at: json['at'] as String? ?? '',
        username: json['username'] as String? ?? '',
        action: json['action'] as String? ?? '',
        detail: json['detail'] as Map<String, dynamic>?,
      );
}

/// Stavy karty — pořadí = pořadí chipů filtru.
const unitDbStatuses = ['active', 'faulty', 'stock', 'retired'];

String unitDbStatusLabel(String status) => switch (status) {
      'active' => 'Aktivní',
      'faulty' => 'Vadná',
      'stock' => 'Sklad',
      'retired' => 'Vyřazená',
      _ => status,
    };

DateTime? _parseTime(dynamic v) {
  if (v is! String || v.isEmpty) return null;
  // SQLite datetime('now') vrací 'YYYY-MM-DD HH:MM:SS' (UTC bez timezone),
  // ISO stringy z appky mají 'T' a offset/Z. Obojí normalizovat na UTC.
  var s = v.contains('T') ? v : '${v.replaceFirst(' ', 'T')}Z';
  if (!s.endsWith('Z') && !s.contains('+')) s = '${s}Z';
  return DateTime.tryParse(s)?.toUtc();
}

/// Absolutní čas čitelně v lokální zóně („21. 7. 2026 16:10") — pro historii
/// a časové značky na kartě. Přijme SQLite `YYYY-MM-DD HH:MM:SS` i ISO string
/// (obojí UTC, viz [_parseTime]); prázdné → ''.
String formatTimestamp(dynamic v) {
  final t = _parseTime(v)?.toLocal();
  if (t == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.day}. ${t.month}. ${t.year} ${two(t.hour)}:${two(t.minute)}';
}

/// Relativní čas pro seznam („3 min", „2 h", „14 dny") — bez slova „před".
String relativeTime(DateTime? t) {
  if (t == null) return 'nikdy';
  final diff = DateTime.now().toUtc().difference(t);
  if (diff.inSeconds < 60) return 'teď';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min';
  if (diff.inHours < 24) return '${diff.inHours} h';
  return '${diff.inDays} dny';
}
