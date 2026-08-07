// Lokální databáze jednotek (SQLite) — offline evidence pro EXE i APK (DB10).
//
// Role podle PRD-DB/03-PRD-sync.md §3: **UI čte a píše VŽDY sem**, sync engine
// (DB11) tuhle DB na pozadí slaďuje se serverem. Serverová DB je zdroj pravdy
// pro řešení konfliktů, ne pro čtení — appka tak funguje stejně u zákazníka bez
// internetu jako ve firmě.
//
// Proč SQLite a ne JSON soubor: potřebujeme transakce (zápis do karty + do
// outboxu musí být atomický) a přírůstkové čtení. Schéma je záměrně blízké
// serverovému (server/db/units-schema.sql), ať se obě strany čtou stejně.
//
// Karta se drží jako JSON blob (`card_json`) + vytažené sloupce pro seznam a
// rozhodování o konfliktech. Rozepisovat všech 25 serverových sloupců by nutilo
// migrovat lokální schéma při každé změně serverového — blob to odstíní.
//
// POZOR na verze balíčků: `sqlite3` 3.x staví native knihovnu přes Dart build
// hooks, které na Windows profilu s mezerou v cestě (`C:\Users\Radek Brym`)
// spadnou. Proto jsou v pubspec.yaml `dependency_overrides` na řadu 2.x
// (sqlite3 2.9.x + sqlite3_flutter_libs 0.5.x + sqflite_common_ffi 2.3.x).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// sqflite_ffi reexportuje i sqflite API (Database, ConflictAlgorithm, …),
// takže stačí jeden import pro desktop i mobil.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/unit_db.dart';
import 'local_unit_db_types.dart';

export 'local_unit_db_types.dart';

class LocalUnitDb {
  LocalUnitDb._();
  static final LocalUnitDb instance = LocalUnitDb._();

  static const _schemaVersion = 1;

  Database? _db;
  bool _unavailable = false;
  int _clockOffsetMs = 0;

  /// Je lokální DB k dispozici? Do úspěšného [init] false, takže volající
  /// (UnitDbService) může spadnout zpět na přímé HTTP.
  bool get isAvailable => _db != null;

  /// Otevře DB (idempotentně). [path] je pro testy (`inMemoryDatabasePath`).
  ///
  /// Selhání se **nepropaguje** — appka musí fungovat i když lokální DB
  /// nejde otevřít (plný disk, práva); jen se nepoužije.
  Future<void> init({String? path}) async {
    if (_db != null || _unavailable) return;
    try {
      // Desktop potřebuje FFI backend; na Androidu/iOSu jde sqflite přes
      // platform kanál a databaseFactory se nepřepisuje.
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      final file = path ?? await _defaultPath();
      _db = await databaseFactory.openDatabase(
        file,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, _) => _createSchema(db),
        ),
      );
      final st = await syncState();
      _clockOffsetMs = st.clockOffsetMs;
    } catch (e) {
      _unavailable = true;
      _db = null;
      // ignore: avoid_print
      print('LocalUnitDb: nedostupná ($e) — evidence pojede jen online');
    }
  }

  Future<String> _defaultPath() async {
    // Vedle ostatních dat appky; na Windows %APPDATA%\P2L-Tester, na Androidu
    // v app support adresáři (mimo cache, aby to systém nesmazal).
    final dir = await getApplicationSupportDirectory();
    await Directory(dir.path).create(recursive: true);
    return p.join(dir.path, 'units-local.db');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Database get _require {
    final db = _db;
    if (db == null) throw StateError('LocalUnitDb není otevřená');
    return db;
  }

  static Future<void> _createSchema(Database db) async {
    // `card_json` = celá karta (tvar UnitDbCard.fromJson, tedy shodný se
    // serverovým GET /units/:id). Ostatní sloupce jsou z ní vytažené kvůli
    // seznamu a rozhodování o konfliktech.
    await db.execute('''
      CREATE TABLE units_cache (
        id                  TEXT PRIMARY KEY,
        rev                 INTEGER NOT NULL DEFAULT 0,
        generation          TEXT    NOT NULL DEFAULT 'new',
        name                TEXT,
        location            TEXT,
        status              TEXT    NOT NULL DEFAULT 'active',
        firmware            TEXT,
        ip                  TEXT,
        battery             REAL,
        broker              TEXT,
        last_seen           TEXT,
        observed_updated_at TEXT,
        desired_updated_at  TEXT,
        meta_updated_at     TEXT,
        deleted_at          TEXT,
        card_json           TEXT    NOT NULL,
        updated_at          TEXT    NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_units_cache_rev ON units_cache(rev)');

    // Fronta zápisů k odeslání. `synced_at` se nepoužívá — hotová operace se
    // maže, aby fronta zůstala malá; historii drží local_history.
    await db.execute('''
      CREATE TABLE outbox (
        op_id       TEXT PRIMARY KEY,
        unit_id     TEXT NOT NULL,
        layer       TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        at          TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        tries       INTEGER NOT NULL DEFAULT 0,
        last_error  TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_outbox_created ON outbox(created_at)');

    // Lokálně vzniklé audit záznamy. `uuid` je globálně unikátní, aby se
    // záznamy dvou klientů na serveru nesrazily (PRD §4.2).
    await db.execute('''
      CREATE TABLE local_history (
        uuid        TEXT PRIMARY KEY,
        unit_id     TEXT NOT NULL,
        at          TEXT NOT NULL,
        username    TEXT,
        action      TEXT NOT NULL,
        layer       TEXT,
        origin      TEXT,
        detail_json TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_local_history_unit ON local_history(unit_id, at)',
    );

    await db.execute('CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT)');
  }

  // ─── Čas ──────────────────────────────────────────────────────────────
  //
  // Všechny časy zapisované do karet i outboxu jdou přes `now()`, tedy už
  // opravené o rozdíl proti serveru. Bez toho by telefon s rozjetými hodinami
  // svými zápisy přebíjel novější serverové změny (nebo naopak prohrával).

  DateTime now() =>
      DateTime.now().toUtc().add(Duration(milliseconds: _clockOffsetMs));

  String _nowIso() => now().toIso8601String();

  // ─── Čtení ────────────────────────────────────────────────────────────

  /// Seznam karet pro obrazduku Databáze (bez smazaných). Drift se počítá
  /// z karty klientem ([UnitDbCard.driftWarnings]), ne serverem — offline
  /// není koho se zeptat.
  Future<List<UnitDbSummary>> listUnits() async {
    final rows = await _require.query(
      'units_cache',
      where: 'deleted_at IS NULL',
      orderBy: 'CAST(id AS INTEGER)',
    );
    return rows.map((row) {
      final card = _cardOf(row);
      return UnitDbSummary(
        id: row['id'] as String,
        generation: row['generation'] as String? ?? 'new',
        mac: card.mac,
        name: row['name'] as String?,
        location: row['location'] as String?,
        status: row['status'] as String? ?? 'active',
        lastSeen: _parse(row['last_seen'] as String?),
        firmware: row['firmware'] as String?,
        ip: row['ip'] as String?,
        battery: (row['battery'] as num?)?.toDouble(),
        broker: row['broker'] as String?,
        drift: card.driftWarnings.isNotEmpty,
      );
    }).toList();
  }

  Future<UnitDbCard?> getCard(String id) async {
    final rows = await _require.query(
      'units_cache',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _cardOf(rows.first);
  }

  /// Audit karty — zatím jen lokálně vzniklé záznamy. Serverovou historii
  /// stahuje sync engine (DB11); do té doby se pro online kartu bere přímo
  /// z API (UnitDbService).
  Future<List<UnitDbEvent>> history(String id) async {
    final rows = await _require.query(
      'local_history',
      where: 'unit_id = ?',
      whereArgs: [id],
      orderBy: 'at DESC',
      limit: 200,
    );
    return rows
        .map(
          (r) => UnitDbEvent(
            at: r['at'] as String? ?? '',
            username: r['username'] as String? ?? '—',
            action: r['action'] as String? ?? '',
            detail: _decodeMap(r['detail_json'] as String?),
          ),
        )
        .toList();
  }

  Future<int> outboxCount() async {
    final r = await _require.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    return (r.first['c'] as num).toInt();
  }

  UnitDbCard _cardOf(Map<String, Object?> row) => UnitDbCard.fromJson(
    (jsonDecode(row['card_json'] as String) as Map).cast<String, dynamic>(),
  );

  static DateTime? _parse(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s)?.toLocal();

  static Map<String, dynamic>? _decodeMap(String? s) {
    if (s == null || s.isEmpty) return null;
    final v = jsonDecode(s);
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  // ─── Zápis ze serveru (pull) ──────────────────────────────────────────

  /// Zapíše dávku z `GET /api/units/changes`. Serverová verze **přepisuje**
  /// lokální kartu — server je zdroj pravdy; případná neodeslaná lokální změna
  /// zůstává v outboxu a pošle se zvlášť (a prohraje/vyhraje podle času).
  Future<void> applyServerChanges({
    required List<Map<String, dynamic>> units,
    required List<Map<String, dynamic>> deleted,
    required int maxRev,
    DateTime? serverTs,
  }) async {
    await _require.transaction((tx) async {
      for (final u in units) {
        await _putServerCard(tx, u);
      }
      for (final d in deleted) {
        final id = d['id']?.toString();
        if (id == null) continue;
        // Tombstone: kartu odstraníme úplně (na rozdíl od serveru ji nemusíme
        // držet — o mazání se dozvěděl každý klient sám z `deleted`).
        await tx.delete('units_cache', where: 'id = ?', whereArgs: [id]);
      }
      await _setState(tx, 'last_rev', maxRev.toString());
      if (serverTs != null) {
        await _setState(tx, 'last_sync_at', serverTs.toIso8601String());
      }
    });
  }

  Future<void> _putServerCard(DatabaseExecutor tx, Map<String, dynamic> u) async {
    final id = u['id']?.toString();
    if (id == null) return;
    final desired = (u['desired'] as Map?)?.cast<String, dynamic>();
    final cfg = (u['unit_config'] as Map?)?.cast<String, dynamic>();
    // Broker pro řádek seznamu stejnou logikou jako server (listUnits):
    // uloženo v NVS → hlášeno jednotkou → kde ji appka viděla → zamýšlený.
    final broker = (cfg?['mqttAddress'] as String?) ??
        (u['mqtt_server'] as String?) ??
        (u['seen_on_broker'] as String?) ??
        ((desired?['broker'] as Map?)?['address'] as String?);
    await tx.insert('units_cache', {
      'id': id,
      'rev': (u['rev'] as num?)?.toInt() ?? 0,
      'generation': u['generation'] as String? ?? 'new',
      'name': u['name'],
      'location': u['location'],
      'status': u['status'] as String? ?? 'active',
      'firmware': u['firmware'],
      'ip': u['ip'],
      'battery': u['battery'],
      'broker': broker,
      'last_seen': u['last_seen'],
      'observed_updated_at': u['observed_updated_at'] ?? u['last_seen'],
      'desired_updated_at': u['desired_updated_at'],
      'meta_updated_at': u['meta_updated_at'],
      'deleted_at': null,
      'card_json': jsonEncode(u),
      'updated_at': _nowIso(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ─── Lokální zápisy (UI a MQTT akce) ──────────────────────────────────

  /// Observed vrstva z MQTT (ALIVE / get_param / GET-DEVICES / GET-CONFIG).
  ///
  /// [queue] = false pro čistě informativní zápisy, které nemá cenu posílat na
  /// server (dnes se nepoužívá; ALIVE se posílá throttlovaně z UnitDbService).
  Future<void> writeObserved(
    String unitId,
    Map<String, dynamic> fragment, {
    bool queue = true,
  }) async {
    await _write(
      unitId: unitId,
      layer: UnitLayer.observed,
      fragment: fragment,
      queue: queue,
      history: false, // observed historii negeneruje (ALIVE by byl šum)
    );
  }

  /// Desired fragment (co se poslalo na jednotku / ruční editace evidence).
  Future<void> writeDesired(
    String unitId,
    Map<String, dynamic> fragment, {
    String? username,
  }) async {
    await _write(
      unitId: unitId,
      layer: UnitLayer.desired,
      fragment: fragment,
      username: username,
    );
  }

  /// Meta pole karty (název / umístění / poznámka / stav).
  Future<void> writeMeta(
    String unitId,
    Map<String, dynamic> meta, {
    String? username,
  }) async {
    await _write(
      unitId: unitId,
      layer: UnitLayer.meta,
      fragment: meta,
      username: username,
    );
  }

  /// Smazání karty. Lokálně řádek zmizí hned, do outboxu jde `delete` op
  /// (server ho promění na tombstone a rozešle ostatním klientům).
  Future<void> writeDelete(String unitId, {String? username}) async {
    final at = _nowIso();
    await _require.transaction((tx) async {
      await tx.delete('units_cache', where: 'id = ?', whereArgs: [unitId]);
      await _enqueue(tx, unitId, UnitLayer.delete, const {}, at);
      await _addHistory(tx, unitId, 'delete', null, username, 'delete', at);
    });
  }

  Future<void> _write({
    required String unitId,
    required UnitLayer layer,
    required Map<String, dynamic> fragment,
    String? username,
    bool queue = true,
    bool history = true,
  }) async {
    final at = _nowIso();
    await _require.transaction((tx) async {
      final rows = await tx.query(
        'units_cache',
        where: 'id = ?',
        whereArgs: [unitId],
        limit: 1,
      );
      final card = rows.isEmpty
          ? <String, dynamic>{
              'id': unitId,
              // Stejná heuristika jako server i appka: ID ≥ 1000 = nová gen.
              'generation': (int.tryParse(unitId) ?? 0) >= 1000 ? 'new' : 'old',
              'status': 'active',
            }
          : (jsonDecode(rows.first['card_json'] as String) as Map)
              .cast<String, dynamic>();

      _mergeIntoCard(card, layer, fragment);
      final touched = switch (layer) {
        UnitLayer.observed => 'observed_updated_at',
        UnitLayer.desired => 'desired_updated_at',
        UnitLayer.meta => 'meta_updated_at',
        UnitLayer.delete => 'deleted_at',
      };
      card[touched] = at;

      await tx.insert('units_cache', {
        'id': unitId,
        // Lokální změna revizi nemá — tu přiděluje server. Zůstává původní,
        // aby pull nepřeskočil serverovou verzi téže karty.
        'rev': rows.isEmpty ? 0 : (rows.first['rev'] as num).toInt(),
        'generation': card['generation'] ?? 'new',
        'name': card['name'],
        'location': card['location'],
        'status': card['status'] ?? 'active',
        'firmware': card['firmware'],
        'ip': card['ip'],
        'battery': card['battery'],
        'broker': _brokerOf(card),
        'last_seen': card['last_seen'],
        'observed_updated_at': card['observed_updated_at'],
        'desired_updated_at': card['desired_updated_at'],
        'meta_updated_at': card['meta_updated_at'],
        'deleted_at': null,
        'card_json': jsonEncode(card),
        'updated_at': at,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      if (queue) await _enqueue(tx, unitId, layer, fragment, at);
      if (history) {
        await _addHistory(
          tx, unitId, layer.wire, fragment, username, layer.wire, at,
        );
      }
    });
  }

  /// Sloučení fragmentu do karty — musí odpovídat serverové logice
  /// (server/db/units.js), jinak by lokál a server po syncu ukazovaly jinak.
  static void _mergeIntoCard(
    Map<String, dynamic> card,
    UnitLayer layer,
    Map<String, dynamic> fragment,
  ) {
    switch (layer) {
      case UnitLayer.observed:
        // Partial update: přepíšou se jen dodaná pole (ALIVE nese firmware
        // a baterii, get_param zbytek). Klíče v camelCase z appky mapujeme
        // na tvar karty (snake_case ze serveru).
        const map = {
          'mac': 'mac',
          'hwModel': 'hw_model',
          'firmware': 'firmware',
          'ip': 'ip',
          'battery': 'battery',
          'ssid': 'ssid',
          'mqttServer': 'mqtt_server',
          'mqttPort': 'mqtt_port',
          'brightness': 'brightness',
          'seenOnBroker': 'seen_on_broker',
          'generation': 'generation',
          'devices': 'devices',
          'unitConfig': 'unit_config',
        };
        for (final e in fragment.entries) {
          final col = map[e.key];
          if (col != null) card[col] = e.value;
        }
        card['last_seen'] = fragment['lastSeen'] ?? DateTime.now().toUtc().toIso8601String();
        if (fragment.containsKey('unitConfig')) {
          card['unit_config_fetched_at'] = card['last_seen'];
        }
      case UnitLayer.desired:
        // Hloubkový merge o jednu úroveň (broker/wifi po podklíčích) — jinak by
        // fragment {broker:{address}} smazal port a heslo.
        final current =
            (card['desired'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        final merged = <String, dynamic>{...current};
        for (final e in fragment.entries) {
          final v = e.value;
          final old = merged[e.key];
          merged[e.key] = (v is Map && old is Map)
              ? {...old.cast<String, dynamic>(), ...v.cast<String, dynamic>()}
              : v;
        }
        card['desired'] = merged;
      case UnitLayer.meta:
        for (final key in ['name', 'location', 'note', 'status']) {
          if (fragment.containsKey(key)) card[key] = fragment[key];
        }
      case UnitLayer.delete:
        break;
    }
  }

  static String? _brokerOf(Map<String, dynamic> card) {
    final cfg = (card['unit_config'] as Map?)?.cast<String, dynamic>();
    final desired = (card['desired'] as Map?)?.cast<String, dynamic>();
    return (cfg?['mqttAddress'] as String?) ??
        (card['mqtt_server'] as String?) ??
        (card['seen_on_broker'] as String?) ??
        ((desired?['broker'] as Map?)?['address'] as String?);
  }

  // ─── Outbox ───────────────────────────────────────────────────────────

  Future<void> _enqueue(
    DatabaseExecutor tx,
    String unitId,
    UnitLayer layer,
    Map<String, dynamic> payload,
    String at,
  ) async {
    // Observed operace se ve frontě SLUČUJÍ: ALIVE chodí často a serveru stačí
    // poslední stav, jinak by fronta po dni offline měla tisíce položek.
    if (layer == UnitLayer.observed) {
      final existing = await tx.query(
        'outbox',
        where: 'unit_id = ? AND layer = ?',
        whereArgs: [unitId, layer.wire],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final old = (jsonDecode(existing.first['payload_json'] as String) as Map)
            .cast<String, dynamic>();
        await tx.update(
          'outbox',
          {'payload_json': jsonEncode({...old, ...payload}), 'at': at},
          where: 'op_id = ?',
          whereArgs: [existing.first['op_id']],
        );
        return;
      }
    }
    await tx.insert('outbox', {
      'op_id': _uuid(),
      'unit_id': unitId,
      'layer': layer.wire,
      'payload_json': jsonEncode(payload),
      'at': at,
      'created_at': at,
      'tries': 0,
    });
  }

  Future<List<OutboxOp>> pendingOps({int limit = 200}) async {
    final rows = await _require.query(
      'outbox',
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows
        .map(
          (r) => OutboxOp(
            opId: r['op_id'] as String,
            unitId: r['unit_id'] as String,
            layer: UnitLayerExt.fromWire(r['layer'] as String),
            payload:
                (jsonDecode(r['payload_json'] as String) as Map).cast<String, dynamic>(),
            at: DateTime.parse(r['at'] as String),
            tries: (r['tries'] as num?)?.toInt() ?? 0,
            lastError: r['last_error'] as String?,
          ),
        )
        .toList();
  }

  /// Operace doručena (applied / superseded / conflict / rejected) → z fronty
  /// zmizí. Server je idempotentní přes `opId`, takže i kdyby se smazání
  /// nestihlo a op se poslala znovu, nic se nezdvojí.
  Future<void> dropOp(String opId) async {
    await _require.delete('outbox', where: 'op_id = ?', whereArgs: [opId]);
  }

  Future<void> markOpFailed(String opId, String error) async {
    await _require.rawUpdate(
      'UPDATE outbox SET tries = tries + 1, last_error = ? WHERE op_id = ?',
      [error, opId],
    );
  }

  Future<void> _addHistory(
    DatabaseExecutor tx,
    String unitId,
    String action,
    Map<String, dynamic>? detail,
    String? username,
    String layer,
    String at,
  ) async {
    await tx.insert('local_history', {
      'uuid': _uuid(),
      'unit_id': unitId,
      'at': at,
      'username': username,
      'action': action,
      'layer': layer,
      'origin': 'local',
      'detail_json': detail == null ? null : jsonEncode(_scrub(detail)),
    });
  }

  /// Hesla se do auditu nezapisují — stejné pravidlo jako na serveru
  /// (scrubSecrets v db/units.js).
  static Object? _scrub(Object? value) {
    if (value is List) return value.map(_scrub).toList();
    if (value is Map) {
      return {
        for (final e in value.entries)
          e.key.toString(): RegExp('pass|pswd|secret', caseSensitive: false)
                  .hasMatch(e.key.toString())
              ? '•••'
              : _scrub(e.value),
      };
    }
    return value;
  }

  // ─── Stav synchronizace ───────────────────────────────────────────────

  Future<LocalSyncState> syncState() async {
    final rows = await _require.query('sync_state');
    final map = {
      for (final r in rows) r['key'] as String: r['value'] as String?,
    };
    return LocalSyncState(
      lastRev: int.tryParse(map['last_rev'] ?? '') ?? 0,
      lastSyncAt: _parse(map['last_sync_at']),
      clockOffsetMs: int.tryParse(map['clock_offset_ms'] ?? '') ?? 0,
    );
  }

  Future<void> saveSyncState({
    int? lastRev,
    DateTime? lastSyncAt,
    int? clockOffsetMs,
  }) async {
    await _require.transaction((tx) async {
      if (lastRev != null) await _setState(tx, 'last_rev', lastRev.toString());
      if (lastSyncAt != null) {
        await _setState(tx, 'last_sync_at', lastSyncAt.toUtc().toIso8601String());
      }
      if (clockOffsetMs != null) {
        await _setState(tx, 'clock_offset_ms', clockOffsetMs.toString());
        _clockOffsetMs = clockOffsetMs;
      }
    });
  }

  static Future<void> _setState(
    DatabaseExecutor tx,
    String key,
    String value,
  ) async {
    await tx.insert(
      'sync_state',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // UUID v4 z Random.secure — vlastní generátor, ať kvůli jednomu volání
  // nepřidáváme závislost. Kolize napříč klienty jsou vylouceny stejně jako
  // u standardní v4 (122 bitů entropie).
  static final _rnd = Random.secure();

  static String _uuid() {
    final b = List<int>.generate(16, (_) => _rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // verze 4
    b[8] = (b[8] & 0x3f) | 0x80; // varianta
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
