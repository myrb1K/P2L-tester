// Typy lokální DB — sdílené nativní implementací i webovým stubem
// (samostatný soubor kvůli conditional exportu, stejně jako file_export_types).

/// Vrstva karty, které se zápis týká. Zrcadlí `layer` v serverovém sync API
/// (server/db/units.js → SYNC_LAYERS).
enum UnitLayer { observed, desired, meta, delete }

extension UnitLayerExt on UnitLayer {
  String get wire => switch (this) {
    UnitLayer.observed => 'observed',
    UnitLayer.desired => 'desired',
    UnitLayer.meta => 'meta',
    UnitLayer.delete => 'delete',
  };

  static UnitLayer fromWire(String s) => switch (s) {
    'observed' => UnitLayer.observed,
    'desired' => UnitLayer.desired,
    'meta' => UnitLayer.meta,
    'delete' => UnitLayer.delete,
    _ => throw ArgumentError('Neznámá vrstva: $s'),
  };
}

/// Čekající zápis ve frontě k odeslání na server (outbox).
///
/// `at` je čas, kdy změna vznikla — už **normalizovaný na serverový čas**
/// (viz PRD-DB/03 §4.4), protože podle něj server rozhoduje, kdo vyhrál.
/// `opId` je UUID: server podle něj pozná opakované doručení a nezapíše dvakrát.
class OutboxOp {
  final String opId;
  final String unitId;
  final UnitLayer layer;
  final Map<String, dynamic> payload;
  final DateTime at;
  final int tries;
  final String? lastError;

  const OutboxOp({
    required this.opId,
    required this.unitId,
    required this.layer,
    required this.payload,
    required this.at,
    this.tries = 0,
    this.lastError,
  });

  /// Tvar pro `POST /api/units/sync`.
  Map<String, dynamic> toWire() => {
    'opId': opId,
    'unitId': unitId,
    'layer': layer.wire,
    'at': at.toUtc().toIso8601String(),
    'payload': payload,
  };
}

/// Stav synchronizace uložený v lokální DB.
class LocalSyncState {
  /// Nejvyšší revize, kterou už klient má stáhnutou (`since` pro pull).
  final int lastRev;

  /// Kdy se naposledy povedla synchronizace.
  final DateTime? lastSyncAt;

  /// Rozdíl serverového a místního času v ms (serverTs − localTs). Časy zápisů
  /// se ukládají už opravené — hodiny klientů se rozcházejí i o dny.
  final int clockOffsetMs;

  const LocalSyncState({
    this.lastRev = 0,
    this.lastSyncAt,
    this.clockOffsetMs = 0,
  });
}
