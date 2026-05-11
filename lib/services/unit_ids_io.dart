import 'dart:convert';

/// Wrapper formát pro export/import seznamu ID P2L modulů.
///
/// ```json
/// {
///   "format": "p2l-tester.unit-ids",
///   "version": 1,
///   "exportedAt": "2026-05-11T12:34:56Z",
///   "appVersion": "2.58",
///   "broker": "Smartbox-Cloud",
///   "brokerProfile": {
///     "name": "Smartbox-Cloud",
///     "broker": "broker.example.com",
///     "port": 1883,
///     "username": "user",
///     "password": "pass",
///     "useSsl": false
///   },
///   "unitIds": ["001017", "001023", "0472"]
/// }
/// ```
class UnitIdsBundle {
  static const String formatId = 'p2l-tester.unit-ids';
  static const int currentVersion = 1;

  static String encode(
    List<String> unitIds, {
    required String brokerName,
    required String appVersion,
    Map<String, dynamic>? brokerProfile,
  }) {
    final payload = <String, dynamic>{
      'format': formatId,
      'version': currentVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
      'broker': brokerName,
      'brokerProfile': ?brokerProfile,
      'unitIds': unitIds,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static UnitIdsParseResult decode(String jsonString) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      return UnitIdsParseResult.error('Soubor není platný JSON: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      return UnitIdsParseResult.error(
          'Neplatný formát: očekáván objekt s "unitIds".');
    }
    if (decoded['format'] != formatId) {
      return UnitIdsParseResult.error(
          'Neznámý formát souboru (chybí "$formatId").');
    }
    final version = decoded['version'];
    if (version is! int) {
      return UnitIdsParseResult.error('Neplatná verze formátu: $version.');
    }
    if (version > currentVersion) {
      return UnitIdsParseResult.error(
          'Nepodporovaná verze formátu: $version. Aktualizuj aplikaci.');
    }
    final idsRaw = decoded['unitIds'];
    if (idsRaw is! List) {
      return UnitIdsParseResult.error(
          'Neplatný formát: "unitIds" musí být pole.');
    }

    final seen = <String>{};
    final canonical = <String>[];
    final skipped = <String>[];
    for (final item in idsRaw) {
      if (item is! String) {
        skipped.add(item?.toString() ?? '<null>');
        continue;
      }
      final c = canonicalUnitId(item);
      if (c == null) {
        skipped.add(item);
        continue;
      }
      if (seen.add(c)) {
        canonical.add(c);
      }
    }

    final broker = decoded['broker'];
    final profileRaw = decoded['brokerProfile'];
    return UnitIdsParseResult.ok(
      ids: canonical,
      skipped: skipped,
      broker: broker is String ? broker : null,
      brokerProfile:
          profileRaw is Map<String, dynamic> ? profileRaw : null,
    );
  }
}

/// Normalizuje vstupní ID na kanonický tvar používaný v `AppState._units`.
/// Pravidla:
/// - Akceptuje 1–6 cifer, volitelně s prefixem `u`.
/// - Numerická hodnota < 1000 → stará jednotka, padding na 4 cifry (`0472`).
/// - Numerická hodnota ≥ 1000 → nová P2L32, padding na 6 cifer (`001017`).
/// Vrací `null`, pokud vstup neodpovídá formátu.
String? canonicalUnitId(String raw) {
  final trimmed = raw.trim();
  final match = RegExp(r'^u?(\d{1,6})$').firstMatch(trimmed);
  if (match == null) return null;
  final n = int.tryParse(match.group(1)!);
  if (n == null) return null;
  if (n < 1000) return n.toString().padLeft(4, '0');
  return n.toString().padLeft(6, '0');
}

/// Filename pro export seznamu ID. Sanitizuje název brokeru — povoluje
/// alfanumeriku, diakritiku, mezery a `_.()-`; ostatní znaky nahradí `_`.
/// Výstup: `{broker}_{N}ids_{YYYY-MM-DDTHH-MM}.json`.
String unitIdsFileName(String brokerName, int count, DateTime now) {
  final safe = brokerName
      .trim()
      .replaceAll(
          RegExp(r'[^A-Za-z0-9ÁČĎÉĚÍŇÓŘŠŤÚŮÝŽáčďéěíňóřšťúůýž _.()-]'), '_');
  final broker = safe.isEmpty ? 'P2L' : safe;
  final y = now.year.toString();
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  return '${broker}_ID-${count}x_$y-$m-${d}T$hh-$mm.json';
}

class UnitIdsParseResult {
  final List<String>? ids;
  final List<String> skipped;
  final String? broker;
  final Map<String, dynamic>? brokerProfile;
  final String? error;

  const UnitIdsParseResult._({
    this.ids,
    this.skipped = const [],
    this.broker,
    this.brokerProfile,
    this.error,
  });

  factory UnitIdsParseResult.ok({
    required List<String> ids,
    required List<String> skipped,
    String? broker,
    Map<String, dynamic>? brokerProfile,
  }) =>
      UnitIdsParseResult._(
        ids: ids,
        skipped: skipped,
        broker: broker,
        brokerProfile: brokerProfile,
      );

  factory UnitIdsParseResult.error(String error) =>
      UnitIdsParseResult._(error: error);

  bool get isOk => error == null;
}
