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

  /// Drift (PRD §4.1): desired vs. observed u polí, která jednotka umí
  /// ohlásit zpět. Vrací lidské popisy nesouladů (prázdné = OK / nelze
  /// porovnat, protože jedna strana chybí).
  List<String> get driftWarnings {
    final out = <String>[];
    final broker = desired?['broker'];
    if (broker is Map) {
      final wantHost = broker['address'];
      if (wantHost is String && wantHost.isNotEmpty) {
        if (mqttServer != null && wantHost != mqttServer) {
          out.add('Broker: evidence „$wantHost", jednotka hlásí „$mqttServer"');
        }
        if (seenOnBroker != null &&
            wantHost != seenOnBroker &&
            seenOnBroker != mqttServer) {
          // Druhá podmínka: když get_param i seen-on říkají totéž, stačí
          // jedno varování výše.
          out.add(
              'Broker: evidence „$wantHost", jednotka se hlásí přes „$seenOnBroker"');
        }
      }
    }
    final wifi = desired?['wifi'];
    if (wifi is Map && ssid != null) {
      final wantSsid = wifi['ssid'];
      if (wantSsid is String && wantSsid.isNotEmpty && wantSsid != ssid) {
        out.add('WiFi: evidence „$wantSsid", jednotka hlásí „$ssid"');
      }
    }
    final wantBrightness = desired?['brightness'];
    if (wantBrightness is int && brightness != null && wantBrightness != brightness) {
      out.add('Jas: evidence $wantBrightness, jednotka hlásí $brightness');
    }
    return out;
  }

  /// „Převzít skutečnost do evidence" — fragment desired, který srovná
  /// evidenci podle observed hodnot (pro záměrné změny mimo appku).
  /// Vrací jen driftující klíče; credentials (broker user/password, WiFi
  /// heslo) z původní evidence ZŮSTÁVAJÍ — jednotka je nehlásí. `null` =
  /// není co přebírat.
  Map<String, dynamic>? acceptObservedFragment() {
    final out = <String, dynamic>{};
    final broker = desired?['broker'];
    // Preferuj mqtt_server (hlásí jednotka sama v get_param); fallback
    // seen-on (přes který broker ji appka vidí).
    final observedHost = mqttServer ?? seenOnBroker;
    if (broker is Map && observedHost != null && observedHost.isNotEmpty) {
      final want = broker['address'];
      if (want is String && want.isNotEmpty && want != observedHost) {
        out['broker'] = {
          ...Map<String, dynamic>.from(broker),
          'address': observedHost,
          if (mqttPort != null) 'port': mqttPort,
        };
      }
    }
    final wifi = desired?['wifi'];
    if (wifi is Map && ssid != null && ssid!.isNotEmpty) {
      final want = wifi['ssid'];
      if (want is String && want.isNotEmpty && want != ssid) {
        out['wifi'] = {...Map<String, dynamic>.from(wifi), 'ssid': ssid};
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

/// Relativní čas pro seznam („před 3 min", „před 2 h", „před 14 dny").
String relativeTime(DateTime? t) {
  if (t == null) return 'nikdy';
  final diff = DateTime.now().toUtc().difference(t);
  if (diff.inSeconds < 60) return 'před chvílí';
  if (diff.inMinutes < 60) return 'před ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'před ${diff.inHours} h';
  return 'před ${diff.inDays} dny';
}
