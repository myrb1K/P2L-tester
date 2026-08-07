// Webová varianta lokální DB — žádná není (PRD-DB/03 R5).
//
// Web běží na serveru: když nemá server, nemá ani sám sebe, takže offline
// evidence tam nemá smysl. `isAvailable == false` a UnitDbService jde starou
// HTTP cestou přesně jako dřív.

import '../models/unit_db.dart';
import 'local_unit_db_types.dart';

export 'local_unit_db_types.dart';

class LocalUnitDb {
  LocalUnitDb._();
  static final LocalUnitDb instance = LocalUnitDb._();

  bool get isAvailable => false;

  Future<void> init({String? path}) async {}
  Future<void> close() async {}

  Future<List<UnitDbSummary>> listUnits() async => const [];
  Future<UnitDbCard?> getCard(String id) async => null;
  Future<List<UnitDbEvent>> history(String id) async => const [];
  Future<List<UnitDbEvent>> recentHistory({int limit = 200}) async => const [];

  Future<void> applyServerChanges({
    required List<Map<String, dynamic>> units,
    required List<Map<String, dynamic>> deleted,
    required int maxRev,
    DateTime? serverTs,
  }) async {}

  Future<void> writeObserved(
    String unitId,
    Map<String, dynamic> fragment, {
    bool queue = true,
  }) async {}

  Future<void> writeDesired(
    String unitId,
    Map<String, dynamic> fragment, {
    String? username,
  }) async {}

  Future<void> writeMeta(
    String unitId,
    Map<String, dynamic> meta, {
    String? username,
  }) async {}

  Future<void> writeDelete(String unitId, {String? username}) async {}

  Future<List<OutboxOp>> pendingOps({int limit = 200}) async => const [];
  Future<int> outboxCount() async => 0;
  Future<void> dropOp(String opId) async {}
  Future<void> markOpFailed(String opId, String error) async {}

  Future<void> recordConflict({
    required String unitId,
    required UnitLayer layer,
    required Map<String, dynamic> payload,
    required DateTime at,
    int? serverRev,
  }) async {}
  Future<List<SyncConflict>> conflicts({String? unitId}) async => const [];
  Future<int> conflictCount() async => 0;
  Future<void> dismissConflict(int id) async {}

  Future<LocalSyncState> syncState() async => const LocalSyncState();
  Future<void> saveSyncState({
    int? lastRev,
    DateTime? lastSyncAt,
    int? clockOffsetMs,
  }) async {}

  DateTime now() => DateTime.now().toUtc();

  /// Popis klienta pro audit na serveru — na webu prostě `web`.
  String get deviceLabel => 'web';
}
