// Synchronizace lokální DB se serverem (DB11, PRD-DB/03-PRD-sync.md §7).
//
// Orchestrátor: sám nic nezapisuje, jen řídí pořadí a stav. Vlastní práci dělá
// UnitDbService (probe / push / pull) nad LocalUnitDb.
//
// Pořadí je PUSH → PULL, ne naopak: server tak rozhoduje o konfliktu se
// znalostí obou verzí a klient si hned stáhne výsledek (včetně vlastní
// přehlasované karty).
//
// Web se nesynchronizuje — nemá lokální DB (R5), čte a píše přímo API.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_session.dart';
import 'local_unit_db.dart';
import 'unit_db_service.dart';

enum SyncStatus {
  /// Nikdy neproběhla / vypnuto (web, nepřihlášený, bez lokální DB).
  idle,

  /// Právě běží.
  running,

  /// Poslední pokus uspěl.
  ok,

  /// Server nedostupný — normální stav u zákazníka, ne chyba.
  offline,
}

class SyncEngine extends ChangeNotifier {
  SyncEngine({UnitDbService? service, LocalUnitDb? local})
    : _service = service ?? UnitDbService.instance,
      _local = local ?? LocalUnitDb.instance;

  static final SyncEngine instance = SyncEngine();

  final UnitDbService _service;
  final LocalUnitDb _local;

  /// Po lokálním zápisu se čeká, jestli nepřijdou další — hromadná akce nad
  /// 20 jednotkami tak vyvolá jeden sync, ne dvacet.
  static const _debounce = Duration(seconds: 2);

  /// Kvůli změnám od ostatních uživatelů (push je řešen debouncem).
  static const _period = Duration(minutes: 10);

  /// Když je server nedostupný a něco čeká ve frontě, zkouší se častěji než
  /// [_period] — technik po návratu do signálu nemá čekat 10 minut.
  static const _retryWhenOffline = Duration(minutes: 1);

  SyncStatus _status = SyncStatus.idle;
  DateTime? _lastSyncAt;
  int _pending = 0;
  int _conflicts = 0;
  bool _running = false;
  Timer? _debounceTimer;
  Timer? _periodicTimer;
  Timer? _retryTimer;

  SyncStatus get status => _status;
  DateTime? get lastSyncAt => _lastSyncAt;

  /// Kolik lokálních změn čeká na odeslání (indikátor v UI).
  int get pendingCount => _pending;

  /// Kolik přehlasovaných změn uživatel ještě neviděl.
  int get conflictCount => _conflicts;

  bool get isEnabled => _local.isAvailable;

  /// Spustí periodickou synchronizaci a hned zkusí první kolo. Volá se po
  /// naběhnutí appky.
  ///
  /// Zároveň se přihlásí na [AuthSession]: nativní login je opt-in, takže se
  /// uživatel může přihlásit až za běhu — bez toho by engine do restartu
  /// appky nejel.
  Future<void> start() async {
    if (!isEnabled) return;
    if (!_watchingSession) {
      _watchingSession = true;
      AuthSession.instance.addListener(_onSessionChanged);
    }
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_period, (_) => syncNow());
    await refreshCounts();
    await syncNow();
  }

  bool _watchingSession = false;
  AuthSessionStatus? _lastSessionStatus;

  void _onSessionChanged() {
    final now = AuthSession.instance.status;
    final was = _lastSessionStatus;
    _lastSessionStatus = now;
    // Přihlášení za běhu → hned zkusit slaďení (fronta může být neprázdná
    // z doby, kdy uživatel přihlášený nebyl).
    if (now == AuthSessionStatus.loggedIn && was != AuthSessionStatus.loggedIn) {
      syncNow();
    }
  }

  void stop() {
    _debounceTimer?.cancel();
    _periodicTimer?.cancel();
    _retryTimer?.cancel();
    _debounceTimer = null;
    _periodicTimer = null;
    _retryTimer = null;
    if (_watchingSession) {
      AuthSession.instance.removeListener(_onSessionChanged);
      _watchingSession = false;
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// Ohlášení lokální změny — sync se spustí po [_debounce]. V online provozu
  /// je to fakticky okamžité, offline to jen posune čítač „čeká".
  void notifyLocalChange() {
    if (!isEnabled) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, syncNow);
    // Čítač osvěžíme hned, ať UI ukáže „1 čeká" bez prodlevy.
    refreshCounts();
  }

  /// Jedno kolo synchronizace. Nikdy nevyhodí — offline je normální stav.
  ///
  /// Vrací true, když se povedlo (server odpověděl a kolo doběhlo).
  Future<bool> syncNow() async {
    if (!isEnabled || _running) return false;
    _running = true;
    _setStatus(SyncStatus.running);
    try {
      // 1) Dostupnost serveru — s validací obsahu odpovědi, aby captive portál
      //    zákazníkovy WiFi nevypadal jako běžící server (PRD §7 bod 1).
      if (!await _service.probeServer()) {
        _setStatus(SyncStatus.offline);
        _scheduleRetryIfPending();
        return false;
      }
      _retryTimer?.cancel();
      // 2) Push fronty, 3) pull změn (v tomhle pořadí — viz hlavička).
      await _service.pushOutbox();
      await _service.pullFromServer();

      final st = await _local.syncState();
      _lastSyncAt = st.lastSyncAt ?? DateTime.now();
      _setStatus(SyncStatus.ok);
      return true;
    } catch (_) {
      _setStatus(SyncStatus.offline);
      return false;
    } finally {
      _running = false;
      await refreshCounts();
    }
  }

  /// Když je offline a něco čeká, zkoušet po minutě znovu — po návratu do
  /// signálu se změny odešlou samy, bez čekání na desetiminutový cyklus nebo
  /// na to, že uživatel otevře obrazovku Databáze.
  void _scheduleRetryIfPending() {
    _retryTimer?.cancel();
    if (_pending == 0) return;
    _retryTimer = Timer(_retryWhenOffline, syncNow);
  }

  /// Přepočítá čítače pro UI (fronta + nevyřešené konflikty).
  Future<void> refreshCounts() async {
    if (!isEnabled) return;
    try {
      _pending = await _local.outboxCount();
      _conflicts = await _local.conflictCount();
      notifyListeners();
    } catch (_) {
      // lokální DB může být zavřená (test teardown) — nemá cenu řešit
    }
  }

  void _setStatus(SyncStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  /// Text pro indikátor v AppBaru.
  String get label => switch (_status) {
    SyncStatus.running => 'Synchronizuji…',
    SyncStatus.offline => _pending > 0
        ? 'Offline · $_pending ${_changesWord(_pending)} čeká'
        : 'Offline',
    SyncStatus.ok => _pending > 0
        ? '$_pending ${_changesWord(_pending)} čeká'
        : 'Sladěno ${_hhmm(_lastSyncAt)}',
    SyncStatus.idle => _pending > 0
        ? '$_pending ${_changesWord(_pending)} čeká'
        : 'Nesynchronizováno',
  };

  static String _changesWord(int n) => n == 1 ? 'změna' : (n < 5 ? 'změny' : 'změn');

  static String _hhmm(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}
