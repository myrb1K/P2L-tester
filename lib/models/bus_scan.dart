import 'module.dart';

/// Rozsah pro `SCAN-DEVICES`. Mapuje se na pole `Type`:
/// - [all] → `Type` se neposílá (scan obou rozsahů)
/// - [dist] → `"DIST"` (adresy 1–127, WIT senzory / SENZORY v UI)
/// - [pum] → `"PUM"` (adresy 128–247, PUMA moduly)
///
/// Pozn.: `Type` u SCAN-DEVICES je jiná doména než `DeviceType.code`
/// (DIST/DISP/BTN…), proto vlastní enum.
enum BusScanScope { all, dist, pum }

/// Výsledek read-only scanu RS485 sběrnice (`SCAN-DEVICES`, od FW
/// `P2L_26061801NT`). Na rozdíl od `GET-DEVICES` reportuje **fyzicky připojené**
/// čipy, nikoli uloženou konfiguraci jednotky, a nic do jednotky nezapisuje.
///
/// Odpověď je přímo JSON objekt (ne Code/Message), klíče = typ čipu z HW
/// registru, hodnota = seznam adres. Prázdné klíče firmware neposílá. Typy:
/// `PUM-A`/`PUM-B`/`PUM-C` (z registru), `PUM-X` (starší PUMA bez registru
/// typu), `DIST`.
class BusScanResult {
  /// Typ čipu → seřazený seznam adres na sběrnici.
  final Map<String, List<int>> byType;
  final DateTime scannedAt;

  /// Rozsah, kterým se skenovalo — určuje, které konfigurované moduly se smí
  /// porovnávat (sken jen DIST nesmí hlásit PUM moduly jako „chybí").
  final BusScanScope scope;

  const BusScanResult(this.byType, this.scannedAt,
      {this.scope = BusScanScope.all});

  factory BusScanResult.fromJson(Map<String, dynamic> json, DateTime at,
      {BusScanScope scope = BusScanScope.all}) {
    final map = <String, List<int>>{};
    json.forEach((key, value) {
      if (value is List) {
        final addrs = value.whereType<num>().map((e) => e.toInt()).toList()
          ..sort();
        if (addrs.isNotEmpty) map[key] = addrs;
      }
    });
    return BusScanResult(map, at, scope: scope);
  }

  /// Počet nalezených čipů celkem.
  int get total => byType.values.fold(0, (sum, list) => sum + list.length);

  /// Adresa → typ čipu (zploštěná mapa pro porovnání s konfigurací).
  Map<int, String> get addressTypes {
    final out = <int, String>{};
    byType.forEach((type, addrs) {
      for (final a in addrs) {
        out[a] = type;
      }
    });
    return out;
  }
}

/// Stav jedné adresy při porovnání konfigurace (GET-DEVICES) se scanem sběrnice.
enum BusScanStatus {
  /// V konfiguraci i na sběrnici.
  ok,

  /// V konfiguraci, ale na sběrnici chybí (nekomunikuje / odpojeno / vadné).
  missing,

  /// Na sběrnici, ale není v konfiguraci (nezaregistrovaný device).
  unregistered,
}

/// Jeden řádek diagnostického porovnání pro danou adresu.
class BusScanRow {
  final int address;

  /// Typ podle uložené konfigurace (`PUM-A`…), nebo `null` když není v konfiguraci.
  final String? configType;

  /// Typ podle scanu sběrnice, nebo `null` když na sběrnici nebyl nalezen.
  final String? busType;

  const BusScanRow({
    required this.address,
    this.configType,
    this.busType,
  });

  BusScanStatus get status {
    if (configType != null && busType != null) return BusScanStatus.ok;
    if (configType != null) return BusScanStatus.missing;
    return BusScanStatus.unregistered;
  }

  /// Adresa je v obou, ale typy se liší (jiné než PUM-X, které je jen "starší
  /// PUMA bez registru" — tu za skutečný nesoulad nepovažujeme).
  bool get typeMismatch {
    if (configType == null || busType == null) return false;
    if (configType == busType) return false;
    // PUM-X = stejný čip, jen FW neumí ohlásit konkrétní podtyp PUMA.
    if (busType == 'PUM-X' && configType!.startsWith('PUM-')) return false;
    return true;
  }
}

/// Porovná uloženou konfiguraci (`modules` z GET-DEVICES) se scanem sběrnice.
/// Výsledek je seřazený podle adresy, sjednocuje obě strany podle adresy čipu
/// (= `PumaModule.baseAddress`, fyzická RS485 adresa).
List<BusScanRow> diagnoseBus(List<PumaModule> modules, BusScanResult scan) {
  // Porovnává se jen v rámci naskenovaného rozsahu — jinak by sken jen DIST
  // hlásil PUM moduly (a naopak) jako „chybí na sběrnici".
  bool inScope(ModuleType t) => switch (scan.scope) {
        BusScanScope.all => true,
        BusScanScope.dist => t == ModuleType.dist,
        BusScanScope.pum => t != ModuleType.dist,
      };

  final configByAddr = <int, String>{
    for (final m in modules)
      if (inScope(m.type)) m.baseAddress: m.type.label,
  };
  final busByAddr = scan.addressTypes;

  final addresses = <int>{...configByAddr.keys, ...busByAddr.keys}.toList()
    ..sort();

  return [
    for (final addr in addresses)
      BusScanRow(
        address: addr,
        configType: configByAddr[addr],
        busType: busByAddr[addr],
      ),
  ];
}
