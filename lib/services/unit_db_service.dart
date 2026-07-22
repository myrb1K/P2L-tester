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

/// Chyba čtecích/editačních operací DB — obrazovka Databáze jednotek z ní
/// zobrazuje hlášku + „Zkusit znovu" (na rozdíl od push*, které se polykají).
class UnitDbException implements Exception {
  final String message;
  const UnitDbException(this.message);
  @override
  String toString() => message;
}

class UnitDbService {
  static const _timeout = Duration(seconds: 5);

  /// Min. rozestup throttlovaných (ALIVE) pushů na jednotku.
  static const _throttleWindow = Duration(seconds: 30);

  final AuthSession _session;
  final http.Client _client;
  final Map<String, DateTime> _lastThrottledPush = {};

  UnitDbService({AuthSession? session, http.Client? client})
    : _session = session ?? AuthSession.instance,
      _client = client ?? createAuthClient();

  /// Globální instance pro AppState.
  static final UnitDbService instance = UnitDbService();

  /// Web je za AuthGate vždy přihlášený (session cookie), nativ podle
  /// opt-in loginu.
  bool get _enabled => kIsWeb || _session.isLoggedIn;

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
    if (throttled) {
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
    await _put('/units/${unit.id}/observed', body);
  }

  /// Desired fragment po konfigurační akci — server merguje po top-level
  /// klíčích ({broker}, {wifi}, {brightness}, {dispBrightness}, {fwUrl}).
  Future<void> pushDesired(String unitId, Map<String, dynamic> fragment) async {
    if (!_enabled) return;
    await _put('/units/$unitId/desired', fragment);
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
    final json = await _getJson('/units');
    return (json['units'] as List)
        .cast<Map<String, dynamic>>()
        .map(UnitDbSummary.fromJson)
        .toList();
  }

  Future<UnitDbCard> fetchUnit(String id) async {
    final json = await _getJson('/units/$id');
    return UnitDbCard.fromJson(json['unit'] as Map<String, dynamic>);
  }

  Future<List<UnitDbEvent>> fetchHistory(String id) async {
    final json = await _getJson('/units/$id/history');
    return (json['history'] as List)
        .cast<Map<String, dynamic>>()
        .map(UnitDbEvent.fromJson)
        .toList();
  }

  /// Uloží desired fragment s potvrzením výsledku (na rozdíl od
  /// fire-and-forget [pushDesired]). Používá akce „Převzít skutečnost do
  /// evidence" na kartě — uživatel potřebuje vědět, jestli se to povedlo.
  Future<void> saveDesired(String id, Map<String, dynamic> fragment) async {
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
  Future<int> bulkSaveDesired(List<String> ids, Map<String, dynamic> fragment) {
    return _bulkPost('/units/bulk/desired', {'ids': ids, 'fragment': fragment});
  }

  /// Hromadná editace meta polí (stav / zákazník / umístění).
  Future<int> bulkSaveMeta(List<String> ids, Map<String, dynamic> meta) {
    return _bulkPost('/units/bulk/meta', {'ids': ids, 'meta': meta});
  }

  /// Hromadné smazání jednotek (jen admin — server vynucuje, 403 → výjimka).
  Future<int> bulkDelete(List<String> ids) {
    return _bulkPost('/units/bulk/delete', {'ids': ids});
  }

  /// Společné hodnoty evidence vybraných jednotek (pro předvyplnění dialogu
  /// hromadné editace). Vrací fragment jen s poli, která mají všechny shodná.
  Future<Map<String, dynamic>> bulkCommonDesired(List<String> ids) async {
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
