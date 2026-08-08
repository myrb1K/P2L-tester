// Zápisy do centrální databáze jednotek (PRD-DB/01-PRD.md, milestone DB3).
//
// DB se plní jako VEDLEJŠÍ EFEKT normální práce s appkou — AppState po
// akcích volá push* metody (fire-and-forget přes `unawaited`):
//   - ALIVE               → pushObserved (throttle 30 s/jednotku — ALIVE
//                           chodí à 5 min, ale GET-ALIVE umí dávky)
//   - get_param odpověď   → pushObserved (plná pole, bez throttle)
//   - GET-DEVICES         → pushObserved s devices (bez throttle)
//   - set_Mqtt/set_WiFi/… → pushDesired (fragment, server merguje po klíčích)
//   - change_ID           → pushChangeId (karta se přenese vč. historie)
//
// Klíčové zásady (akceptační kritéria PRD §11):
// - Zapisuje se JEN když je uživatel přihlášený (web = vždy za AuthGate,
//   nativ = opt-in AuthSession). Nepřihlášený stav → metody tiše nic nedělají.
// - Selhání zápisu NIKDY neshodí ani nezdrží MQTT akci — všechny chyby se
//   polykají (timeout 5 s), bez retry (MVP).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../models/module.dart';
import '../models/unit.dart';
import '../models/unit_db.dart';
import 'auth_api.dart' show authApiBase;
import 'auth_http_client.dart';
import 'auth_session.dart';
import 'local_unit_db.dart';

/// Chyba čtecích/editačních operací DB — obrazovka Databáze jednotek z ní
/// zobrazuje hlášku + „Zkusit znovu" (na rozdíl od push*, které se polykají).
class UnitDbException implements Exception {
  final String message;
  const UnitDbException(this.message);
  @override
  String toString() => message;
}

/// Proč se kolo synchronizace nepovedlo (`null` = povedlo).
///
/// Rozlišovat je nutné, protože každý případ chce jinou reakci — a hlavně
/// proto, že uživatel musí poznat rozdíl mezi „ještě se to neodeslalo" a
/// „tenhle server to nikdy nepřijme". Do teď se každá ne-200 odpověď mlčky
/// spolkla a fronta jen rostla.
enum SyncFailure {
  /// Endpoint neexistuje (404) — server je starší než DB9 a synchronizaci
  /// neumí. Opakování nepomůže, musí se aktualizovat server.
  unsupported,

  /// 401/403 — přihlášení vypršelo nebo účet nemá práva. Opakování nepomůže,
  /// dokud se uživatel nepřihlásí znovu.
  unauthorized,

  /// Síť, timeout, 5xx — přechodné. Fronta počká a zkusí se znovu; tohle je
  /// u zákazníka bez internetu normální stav, ne chyba.
  transient,
}

/// Mapuje HTTP status na [SyncFailure]. 2xx → `null`.
SyncFailure? _failureOf(int status) {
  if (status >= 200 && status < 300) return null;
  if (status == 404) return SyncFailure.unsupported;
  if (status == 401 || status == 403) return SyncFailure.unauthorized;
  return SyncFailure.transient;
}

class UnitDbService {
  static const _timeout = Duration(seconds: 5);

  /// Min. rozestup throttlovaných (ALIVE) pushů na jednotku.
  static const _throttleWindow = Duration(seconds: 30);

  final AuthSession _session;
  final http.Client _client;
  final LocalUnitDb _local;
  final Map<String, DateTime> _lastThrottledPush = {};

  UnitDbService({AuthSession? session, http.Client? client, LocalUnitDb? local})
    : _session = session ?? AuthSession.instance,
      _client = client ?? createAuthClient(),
      _local = local ?? LocalUnitDb.instance;

  /// Globální instance pro AppState.
  static final UnitDbService instance = UnitDbService();

  /// Web je za AuthGate vždy přihlášený (session cookie), nativ podle
  /// opt-in loginu.
  bool get _enabled => kIsWeb || _session.isLoggedIn;

  /// Jde evidence přes lokální DB (offline-first, DB10)? Na webu nikdy
  /// (stub → `isAvailable == false`, PRD-DB/03 R5), na nativu když se lokální
  /// DB podařilo otevřít. Když ne, chová se appka jako do DB9 — přímé HTTP.
  bool get _useLocal => _local.isAvailable;

  /// Je přihlášený uživatel admin? Rozhoduje o zobrazení akce „Smazat"
  /// (server ji stejně vynucuje — tohle je jen UX gating). Na webu neznáme
  /// claim bez `/me`, proto povolíme a spolehneme se na server (403).
  bool get isAdmin => kIsWeb || (_session.user?.isAdmin ?? false);

  String get _base => kIsWeb ? authApiBase : _session.apiBase;

  /// Observed vrstva z aktuálního stavu [unit]. [includeParams] přidá pole
  /// dostupná jen z get_param (SSID, broker, jas) — při ALIVE by default
  /// jasu (100) přemazal reálnou hodnotu z dřívějšího get_param.
  /// [includeConfig] přidá snapshot z UNIT GET-CONFIG (`unit.unitConfig`) —
  /// bohatší observed (nakonfigurováno vs. reálně běží, TLS, cert, dns/gw).
  /// [modules] přidá devices (po GET-DEVICES). [throttled] zapne per-unit
  /// throttle (pro ALIVE). [seenOnBroker] = host brokeru, přes který appka
  /// jednotku právě vidí — na rozdíl od mqtt_server (get_param) se plní
  /// každým kontaktem, takže „jednotka žije na jiném brokeru" je v DB vidět
  /// hned po discovery.
  Future<void> pushObserved(
    P2LUnit unit, {
    bool includeParams = false,
    bool includeConfig = false,
    List<PumaModule>? modules,
    bool throttled = false,
    String? seenOnBroker,
  }) async {
    if (!_enabled) return;
    // Throttle je kvůli síti (ALIVE chodí často). Do lokální DB se zapisuje
    // vždy — je to levné a offline evidence má ukazovat aktuální stav; ve
    // frontě k odeslání se observed operace stejně slévají do jedné.
    if (throttled && !_useLocal) {
      final last = _lastThrottledPush[unit.id];
      if (last != null && DateTime.now().difference(last) < _throttleWindow) {
        return;
      }
      _lastThrottledPush[unit.id] = DateTime.now();
    }
    final body = <String, dynamic>{
      'generation': unit.isNewGen ? 'new' : 'old',
      if (unit.mac != null) 'mac': unit.mac,
      if (unit.hwModel != null) 'hwModel': unit.hwModel,
      if (unit.firmware != null) 'firmware': unit.firmware,
      if (unit.ip != null) 'ip': unit.ip,
      if (unit.battery != null) 'battery': unit.battery,
      if (seenOnBroker != null && seenOnBroker.isNotEmpty)
        'seenOnBroker': seenOnBroker,
      if (includeParams) ...{
        if (unit.ssid != null) 'ssid': unit.ssid,
        if (unit.mqttServer != null) 'mqttServer': unit.mqttServer,
        if (unit.mqttPort != null) 'mqttPort': unit.mqttPort,
        'brightness': unit.brightness,
      },
      if (includeConfig && unit.unitConfig != null)
        'unitConfig': unit.unitConfig,
      if (modules != null) 'devices': modules.map((m) => m.toJson()).toList(),
    };
    if (_useLocal) {
      await _localWrite(() => _local.writeObserved(unit.id, body));
      return;
    }
    await _put('/units/${unit.id}/observed', body);
  }

  /// Desired fragment po konfigurační akci — server merguje po top-level
  /// klíčích ({broker}, {wifi}, {brightness}, {dispBrightness}, {fwUrl}).
  Future<void> pushDesired(String unitId, Map<String, dynamic> fragment) async {
    if (!_enabled) return;
    if (_useLocal) {
      await _localWrite(
        () => _local.writeDesired(unitId, fragment, username: _username),
      );
      return;
    }
    await _put('/units/$unitId/desired', fragment);
  }

  String? get _username => _session.user?.username;

  /// Zavolá se po každém lokálním zápisu — SyncEngine si to zapojí a spustí
  /// odeslání (s debouncem). Callback místo přímého importu, aby nevznikl
  /// import cyklus UnitDbService ↔ SyncEngine.
  void Function()? onLocalChange;

  /// Lokální zápis nesmí shodit MQTT akci ani UI — stejná zásada jako u
  /// fire-and-forget HTTP pushů. Selže-li (plný disk, zamčená DB), evidence
  /// o té změně neví, ale appka jede dál.
  Future<void> _localWrite(Future<void> Function() op) async {
    try {
      await op();
      onLocalChange?.call();
    } catch (e) {
      // ignore: avoid_print
      print('UnitDbService: lokální zápis selhal: $e');
    }
  }

  /// Interaktivní lokální zápis (uživatel čeká na potvrzení). Na rozdíl od
  /// [_localWrite] chybu **propaguje** — kdyby se do lokální DB nezapsalo,
  /// uživatel by si jinak myslel, že je změna uložená.
  Future<T> _localInteractive<T>(Future<T> Function() op) async {
    final T result;
    try {
      result = await op();
    } catch (e) {
      throw UnitDbException('Uložení do lokální databáze selhalo: $e');
    }
    onLocalChange?.call();
    return result;
  }

  /// Přenese kartu na nové ID po change_ID. Jednotka bez karty v DB → 404,
  /// tiše ignorováno (karta vznikne s novým ID při příštím ALIVE).
  Future<void> pushChangeId(String oldId, int newId) async {
    if (!_enabled) return;
    try {
      await _client
          .post(
            Uri.parse('$_base/units/$oldId/change-id'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'newId': '$newId'}),
          )
          .timeout(_timeout);
    } catch (_) {
      // fire-and-forget — DB nesmí ovlivnit MQTT akci
    }
  }

  Future<void> _put(String path, Map<String, dynamic> body) async {
    try {
      await _client
          .put(
            Uri.parse('$_base$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (_) {
      // fire-and-forget — DB nesmí ovlivnit MQTT akci
    }
  }

  // ─── Čtení a editace pro obrazovku Databáze jednotek (DB4) ──────────
  //
  // Na rozdíl od push* metody HÁZÍ [UnitDbException] — uživatel na
  // obrazovce potřebuje vědět, že server nejede / session vypršela.

  Future<List<UnitDbSummary>> fetchUnits() async {
    if (_useLocal) {
      // Nejdřív se pokus dorovnat ze serveru, pak čti lokál. Offline pull
      // tiše selže a zobrazí se poslední známý stav — o tom je celý DB10.
      await pullFromServer();
      return _local.listUnits();
    }
    final json = await _getJson('/units');
    return (json['units'] as List)
        .cast<Map<String, dynamic>>()
        .map(UnitDbSummary.fromJson)
        .toList();
  }

  Future<UnitDbCard> fetchUnit(String id) async {
    if (_useLocal) {
      final card = await _local.getCard(id);
      if (card != null) return card;
      throw const UnitDbException('Jednotka v databázi není.');
    }
    final json = await _getJson('/units/$id');
    return UnitDbCard.fromJson(json['unit'] as Map<String, dynamic>);
  }

  /// Audit karty. Serverová historie se nestahuje (pull vrací karty, ne
  /// historii), takže online se bere z API a offline se ukáže aspoň to, co
  /// vzniklo na tomhle zařízení.
  Future<List<UnitDbEvent>> fetchHistory(String id) async {
    try {
      final json = await _getJson('/units/$id/history');
      return (json['history'] as List)
          .cast<Map<String, dynamic>>()
          .map(UnitDbEvent.fromJson)
          .toList();
    } on UnitDbException {
      if (!_useLocal) rethrow;
      return _local.history(id);
    }
  }

  // ─── Audit napříč jednotkami (DB12) ───────────────────────────────────
  //
  // Audit je serverová veličina — lokální DB drží jen změny vzniklé na tomhle
  // zařízení. Offline se proto ukáže aspoň to (viz [fetchLocalAudit]).

  /// Stránka změn napříč jednotkami. Hází [UnitDbException] (obrazovka Změny
  /// z ní zobrazí hlášku + „Zkusit znovu").
  Future<UnitDbAuditPage> fetchAudit({
    String? unitId,
    String? username,
    String? layer,
    String? origin,
    int limit = 50,
    int offset = 0,
  }) async {
    final q = <String, String>{
      if (unitId != null && unitId.isNotEmpty) 'unitId': unitId,
      'username': ?username,
      'layer': ?layer,
      'origin': ?origin,
      'limit': '$limit',
      'offset': '$offset',
    };
    final query = q.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return UnitDbAuditPage.fromJson(await _getJson('/units/history?$query'));
  }

  Future<UnitDbAuditFilters> fetchAuditFilters() async =>
      UnitDbAuditFilters.fromJson(await _getJson('/units/history/filters'));

  /// Změny vzniklé na tomhle zařízení — záloha pro offline režim, kde na
  /// serverový audit nedosáhneme.
  Future<List<UnitDbEvent>> fetchLocalAudit() async {
    if (!_useLocal) return const [];
    return _local.recentHistory();
  }

  // ─── Pull ze serveru (DB10) ───────────────────────────────────────────
  //
  // Rozdílové stahování podle revizí: `GET /units/changes?since=<rev>`.
  // Plný sync (odesílání outboxu, konflikty, triggery) přijde v DB11 —
  // tady jde jen o to, aby lokální DB měla serverová data.

  static const _pullTimeout = Duration(seconds: 6);
  static const _maxPullPages = 50; // strop proti nekonečné smyčce

  /// Dorovná lokální DB ze serveru. Nikdy nevyhodí — vrací důvod selhání
  /// (`null` = v pořádku), aby volající poznal, že server `/units/changes`
  /// vůbec neumí, a neopakoval to donekonečna.
  Future<SyncFailure?> pullFromServer() async {
    if (!_useLocal || !_enabled) return null;
    try {
      var since = (await _local.syncState()).lastRev;
      for (var page = 0; page < _maxPullPages; page++) {
        final res = await _client
            .get(Uri.parse('$_base/units/changes?since=$since&limit=500'))
            .timeout(_pullTimeout);
        final failure = _failureOf(res.statusCode);
        if (failure != null) return failure;
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final units = (json['units'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final deleted = (json['deleted'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final maxRev = (json['maxRev'] as num?)?.toInt() ?? since;
        final serverTs = DateTime.tryParse(json['serverTs'] as String? ?? '');
        await _local.applyServerChanges(
          units: units,
          deleted: deleted,
          maxRev: maxRev,
          serverTs: serverTs,
        );
        // Kalibrace hodin: podle serverového času, ne podle místních (telefon
        // po vybití nebo notebook bez NTP se rozchází i o dny) — PRD §4.4.
        if (serverTs != null) {
          final offset = serverTs.difference(DateTime.now().toUtc()).inMilliseconds;
          await _local.saveSyncState(clockOffsetMs: offset);
        }
        if (json['more'] != true) break;
        since = maxRev;
      }
    } catch (_) {
      // offline / timeout → zůstane poslední známý stav, zkusí se příště
      return SyncFailure.transient;
    }
    return null;
  }

  /// Kolik lokálních změn čeká na odeslání (indikátor v UI).
  Future<int> pendingChanges() => _useLocal ? _local.outboxCount() : Future.value(0);

  // ─── Push outboxu + dostupnost serveru (DB11) ─────────────────────────

  static const _probeTimeout = Duration(seconds: 3);

  /// Je server dostupný? Kontroluje **obsah** odpovědi, ne jen HTTP status:
  /// captive portály zákazníkových WiFi vrací `200 OK` s přihlašovací
  /// stránkou na cokoli, takže by se appka považovala za online a sync by
  /// dokola padal (PRD-DB/03 §7 bod 1). Krátký timeout, ať UI nečeká.
  Future<bool> probeServer() async {
    if (!_enabled) return false;
    try {
      final res = await _client
          .get(Uri.parse('$_base/health'))
          .timeout(_probeTimeout);
      if (res.statusCode != 200) return false;
      final json = jsonDecode(res.body);
      return json is Map && json['ok'] == true && json['db'] != null;
    } catch (_) {
      return false;
    }
  }

  /// Odešle frontu lokálních změn na `POST /units/sync`.
  ///
  /// Server je idempotentní přes `opId`, takže když se odpověď ztratí, další
  /// pokus nic nezdvojí. Výsledky se vyhodnocují per operace:
  ///   applied / superseded → z fronty zmizí (superseded = server má novější
  ///     pozorování, není co řešit)
  ///   conflict             → z fronty zmizí a uloží se jako [SyncConflict],
  ///     aby uživatel viděl, že jeho verze prohrála
  ///   rejected             → z fronty zmizí (vadná operace by se jinak
  ///     přeposílala donekonečna), zapíše se chyba
  /// Operace, ke které odpověď nepřišla, zůstává ve frontě.
  ///
  /// Vrací důvod selhání (`null` = v pořádku). Rozlišení je podstatné: proti
  /// serveru bez DB9 vrací `/units/sync` 404 a fronta by jinak tiše rostla do
  /// nekonečna, aniž by měl uživatel jak poznat, že se nic neděje.
  Future<SyncFailure?> pushOutbox({int batch = 100}) async {
    if (!_useLocal || !_enabled) return null;
    final ops = await _local.pendingOps(limit: batch);
    if (ops.isEmpty) return null;

    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_base/units/sync'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'ops': ops.map((o) => o.toWire()).toList(),
              'sourceDevice': _sourceDevice,
            }),
          )
          .timeout(_bulkTimeout);
    } catch (_) {
      return SyncFailure.transient; // offline → fronta zůstává
    }
    final failure = _failureOf(res.statusCode);
    if (failure != null) return failure;

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final results = (json['results'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final byId = {for (final r in results) r['opId'] as String: r};

    for (final op in ops) {
      final r = byId[op.opId];
      if (r == null) continue; // bez odpovědi → nechat ve frontě
      final status = r['status'] as String?;
      if (status == 'conflict') {
        await _local.recordConflict(
          unitId: op.unitId,
          layer: op.layer,
          payload: op.payload,
          at: op.at,
          serverRev: (r['rev'] as num?)?.toInt(),
        );
      } else if (status == 'rejected') {
        await _local.markOpFailed(
          op.opId,
          (r['message'] ?? r['error'] ?? 'odmítnuto serverem').toString(),
        );
      }
      await _local.dropOp(op.opId);
    }
    return null;
  }

  /// Popis klienta pro audit na serveru (`source_device`) — z něj je v historii
  /// vidět, odkud změna přišla (`exe@NB-RADEK`, `apk@Pixel7`, `web`).
  /// Bere se z LocalUnitDb, protože ta je platform-specific; `dart:io` tady
  /// importovat nelze (soubor se kompiluje i pro web).
  String get _sourceDevice => _local.deviceLabel;

  /// Uloží desired fragment s potvrzením výsledku (na rozdíl od
  /// fire-and-forget [pushDesired]). Používá akce „Převzít skutečnost do
  /// evidence" na kartě — uživatel potřebuje vědět, jestli se to povedlo.
  Future<void> saveDesired(String id, Map<String, dynamic> fragment) async {
    if (_useLocal) {
      // Offline-first: zapíše se do lokální DB a odešle se, až bude server
      // k dispozici. Uživateli to potvrdíme hned — o čekajících změnách
      // informuje indikátor synchronizace, ne chybová hláška.
      await _localInteractive(
        () => _local.writeDesired(id, fragment, username: _username),
      );
      return;
    }
    final http.Response res;
    try {
      res = await _client
          .put(
            Uri.parse('$_base/units/$id/desired'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(fragment),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const UnitDbException('Server neodpověděl (timeout).');
    } catch (e) {
      throw UnitDbException('Server nedostupný: $e');
    }
    _throwForStatus(res);
  }

  /// Uloží meta pole karty (jen dodaná). Hází [UnitDbException] — editace
  /// potřebuje zpětnou vazbu (SnackBar), ne tiché selhání.
  Future<void> saveMeta(
    String id, {
    String? name,
    String? location,
    String? note,
    String? status,
  }) async {
    final body = <String, dynamic>{
      'name': ?name,
      'location': ?location,
      'note': ?note,
      'status': ?status,
    };
    if (_useLocal) {
      await _localInteractive(
        () => _local.writeMeta(id, body, username: _username),
      );
      return;
    }
    final http.Response res;
    try {
      res = await _client
          .put(
            Uri.parse('$_base/units/$id/meta'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const UnitDbException('Server neodpověděl (timeout).');
    } catch (e) {
      throw UnitDbException('Server nedostupný: $e');
    }
    _throwForStatus(res);
  }

  /// Hromadná editace evidence (desired) vybraných jednotek — jeden POST,
  /// server řeší v transakci. Vrací počet zpracovaných jednotek.
  ///
  /// Lokální režim: zapíše se po jednotkách do lokální DB (každá dostane svou
  /// operaci do fronty, takže případný konflikt se řeší per jednotka).
  Future<int> bulkSaveDesired(
    List<String> ids,
    Map<String, dynamic> fragment,
  ) async {
    if (_useLocal) {
      return _localInteractive(() async {
        for (final id in ids) {
          await _local.writeDesired(id, fragment, username: _username);
        }
        return ids.length;
      });
    }
    return _bulkPost('/units/bulk/desired', {'ids': ids, 'fragment': fragment});
  }

  /// Hromadná editace meta polí (stav / zákazník / umístění).
  Future<int> bulkSaveMeta(List<String> ids, Map<String, dynamic> meta) async {
    if (_useLocal) {
      return _localInteractive(() async {
        for (final id in ids) {
          await _local.writeMeta(id, meta, username: _username);
        }
        return ids.length;
      });
    }
    return _bulkPost('/units/bulk/meta', {'ids': ids, 'meta': meta});
  }

  /// Hromadné smazání jednotek (jen admin — server vynucuje, 403 → výjimka).
  ///
  /// Lokálně smaže hned; server operaci při syncu odmítne (`rejected`), pokud
  /// uživatel adminem není. Proto UI mazání nabízí jen adminovi (isAdmin).
  Future<int> bulkDelete(List<String> ids) async {
    if (_useLocal) {
      return _localInteractive(() async {
        for (final id in ids) {
          await _local.writeDelete(id, username: _username);
        }
        return ids.length;
      });
    }
    return _bulkPost('/units/bulk/delete', {'ids': ids});
  }

  /// Společné hodnoty evidence vybraných jednotek (pro předvyplnění dialogu
  /// hromadné editace). Vrací fragment jen s poli, která mají všechny shodná.
  Future<Map<String, dynamic>> bulkCommonDesired(List<String> ids) async {
    if (_useLocal) return _commonDesiredLocal(ids);
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_base/units/bulk/common-desired'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'ids': ids}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const UnitDbException('Server neodpověděl (timeout).');
    } catch (e) {
      throw UnitDbException('Server nedostupný: $e');
    }
    _throwForStatus(res);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return (json['common'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Lokální varianta `commonDesired` — hodnota se vrátí jen když ji mají
  /// VŠECHNY vybrané jednotky shodnou (jinak zůstane v dialogu prázdná).
  /// Zrcadlí serverovou logiku v db/units.js.
  Future<Map<String, dynamic>> _commonDesiredLocal(List<String> ids) async {
    final desireds = <Map<String, dynamic>>[];
    for (final id in ids) {
      final card = await _local.getCard(id);
      desireds.add(card?.desired ?? const {});
    }
    bool allEqual(List<Object?> vals) =>
        vals.every((v) => v != null) &&
        vals.every((v) => v == vals.first);

    final common = <String, dynamic>{};
    for (final key in ['brightness', 'dispBrightness']) {
      final vals = desireds.map((d) => d[key]).toList();
      if (allEqual(vals)) common[key] = vals.first;
    }
    const groups = {
      'broker': ['address', 'port', 'user', 'password'],
      'wifi': ['ssid', 'password'],
    };
    for (final entry in groups.entries) {
      final sub = <String, dynamic>{};
      for (final field in entry.value) {
        final vals = desireds
            .map((d) => (d[entry.key] as Map?)?[field])
            .toList();
        if (allEqual(vals)) sub[field] = vals.first;
      }
      if (sub.isNotEmpty) common[entry.key] = sub;
    }
    return common;
  }

  Future<int> _bulkPost(String path, Map<String, dynamic> body) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_base$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const UnitDbException('Server neodpověděl (timeout).');
    } catch (e) {
      throw UnitDbException('Server nedostupný: $e');
    }
    _throwForStatus(res);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return json['count'] as int? ?? (body['ids'] as List).length;
  }

  // ─── Export / import celé DB (kompletní záloha / obnova, hamburger na
  // obrazovce Databáze) ────────────────────────────────────────────────
  //
  // Delší timeout než běžné čtení — záloha může nést historii všech jednotek.

  static const _bulkTimeout = Duration(seconds: 30);

  /// Kompletní záloha (všechna pole vč. hesel + historie). Vrací dekódovaný
  /// JSON připravený k zápisu do souboru. [ids] == null → celá DB (GET);
  /// neprázdný seznam → jen vybrané jednotky (POST). Hází [UnitDbException].
  Future<Map<String, dynamic>> exportDatabase({List<String>? ids}) async {
    final http.Response res;
    try {
      if (ids == null) {
        res = await _client
            .get(Uri.parse('$_base/units/export'))
            .timeout(_bulkTimeout);
      } else {
        res = await _client
            .post(
              Uri.parse('$_base/units/export'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'ids': ids}),
            )
            .timeout(_bulkTimeout);
      }
    } on TimeoutException {
      throw const UnitDbException('Server neodpověděl (timeout).');
    } catch (e) {
      throw UnitDbException('Server nedostupný: $e');
    }
    _throwForStatus(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Naimportuje zálohu ([backup] = obsah exportovaného souboru) — sloučení po
  /// ID (existující aktualizovat, nové přidat, nic se nemaže). Vrací počty
  /// `{created, updated, total}`. Hází [UnitDbException].
  Future<Map<String, dynamic>> importDatabase(
    Map<String, dynamic> backup,
  ) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_base/units/import'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(backup),
          )
          .timeout(_bulkTimeout);
    } on TimeoutException {
      throw const UnitDbException('Server neodpověděl (timeout).');
    } catch (e) {
      throw UnitDbException('Server nedostupný: $e');
    }
    _throwForStatus(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final http.Response res;
    try {
      res = await _client.get(Uri.parse('$_base$path')).timeout(_timeout);
    } on TimeoutException {
      throw const UnitDbException('Server neodpověděl (timeout).');
    } catch (e) {
      throw UnitDbException('Server nedostupný: $e');
    }
    _throwForStatus(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  void _throwForStatus(http.Response res) {
    if (res.statusCode == 200) return;
    if (res.statusCode == 401) {
      throw const UnitDbException(
        'Nepřihlášený — obnov přihlášení v Nastavení → Účet.',
      );
    }
    if (res.statusCode == 403) {
      throw const UnitDbException('Nemáš oprávnění pro tuto akci.');
    }
    if (res.statusCode == 404) {
      throw const UnitDbException('Jednotka v databázi není.');
    }
    String detail = 'HTTP ${res.statusCode}';
    try {
      final err = jsonDecode(res.body) as Map<String, dynamic>;
      detail = (err['message'] ?? err['error'] ?? detail).toString();
    } catch (_) {}
    throw UnitDbException('Chyba serveru: $detail');
  }
}
