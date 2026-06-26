import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/models/bus_scan.dart';
import 'package:p2l_tester/models/module.dart';

void main() {
  final at = DateTime(2026, 1, 1);

  group('BusScanResult.fromJson', () {
    test('parsuje typy, řadí adresy, vynechá prázdné', () {
      final json = jsonDecode(
              '{"DIST":[67,1,2],"PUM-A":[128],"PUM-X":[131,130],"PUM-B":[]}')
          as Map<String, dynamic>;
      final scan = BusScanResult.fromJson(json, at);

      expect(scan.byType['DIST'], [1, 2, 67]);
      expect(scan.byType['PUM-A'], [128]);
      expect(scan.byType['PUM-X'], [130, 131]);
      expect(scan.byType.containsKey('PUM-B'), isFalse); // prázdné se nepřidá
      expect(scan.total, 6);
    });
  });

  group('BusScanResult.withUpdatedAddress', () {
    final base = BusScanResult.fromJson(
        jsonDecode('{"PUM-A":[133],"PUM-C":[134]}') as Map<String, dynamic>,
        at,
        scope: BusScanScope.pum);

    test('ověření nalezené adresy zachová ostatní devices a vynuluje scanId', () {
      final merged = base.withUpdatedAddress(
          133, jsonDecode('{"PUM-A":[133]}') as Map<String, dynamic>, at);
      expect(merged.byType['PUM-A'], [133]);
      expect(merged.byType['PUM-C'], [134]); // druhý device zůstane
      expect(merged.scanId, isNull); // porovnání pokrývá celou množinu
      expect(merged.scope, BusScanScope.pum);
    });

    test('adresa nenalezená skenem se odebere (= fyzicky chybí)', () {
      final merged = base.withUpdatedAddress(
          133, jsonDecode('{}') as Map<String, dynamic>, at);
      expect(merged.addressTypes.containsKey(133), isFalse);
      expect(merged.byType['PUM-C'], [134]);
    });

    test('aktualizuje typ adresy (PUM-X → PUM-A)', () {
      final start = BusScanResult.fromJson(
          jsonDecode('{"PUM-X":[133]}') as Map<String, dynamic>, at);
      final merged = start.withUpdatedAddress(
          133, jsonDecode('{"PUM-A":[133]}') as Map<String, dynamic>, at);
      expect(merged.byType.containsKey('PUM-X'), isFalse);
      expect(merged.byType['PUM-A'], [133]);
    });
  });

  group('BusScanScope.containsAddress', () {
    test('all pokrývá vše', () {
      expect(BusScanScope.all.containsAddress(1), isTrue);
      expect(BusScanScope.all.containsAddress(247), isTrue);
    });
    test('dist jen 1–127', () {
      expect(BusScanScope.dist.containsAddress(1), isTrue);
      expect(BusScanScope.dist.containsAddress(127), isTrue);
      expect(BusScanScope.dist.containsAddress(128), isFalse);
    });
    test('pum jen 128–247', () {
      expect(BusScanScope.pum.containsAddress(127), isFalse);
      expect(BusScanScope.pum.containsAddress(128), isTrue);
      expect(BusScanScope.pum.containsAddress(247), isTrue);
    });
  });

  group('diagnoseBus', () {
    test('OK / chybí na sběrnici / nezaregistrované', () {
      final modules = [
        const PumaModule.pumA(address: 128),
        const PumaModule.pumA(address: 130), // na sběrnici chybí
        PumaModule.dist(address: 67),
      ];
      final scan = BusScanResult.fromJson(
        jsonDecode('{"PUM-A":[128],"PUM-X":[131],"DIST":[67]}')
            as Map<String, dynamic>,
        at,
      );

      final rows = {for (final r in diagnoseBus(modules, scan)) r.address: r};

      expect(rows[128]!.status, BusScanStatus.ok);
      expect(rows[130]!.status, BusScanStatus.missing);
      expect(rows[131]!.status, BusScanStatus.unregistered);
      expect(rows[67]!.status, BusScanStatus.ok);
      // Řazení podle adresy
      expect(diagnoseBus(modules, scan).map((r) => r.address),
          [67, 128, 130, 131]);
    });

    test('PUM-X proti konfiguraci PUM-A není nesoulad typu', () {
      final modules = [const PumaModule.pumA(address: 128)];
      final scan = BusScanResult.fromJson(
          jsonDecode('{"PUM-X":[128]}') as Map<String, dynamic>, at);
      final row = diagnoseBus(modules, scan).single;
      expect(row.status, BusScanStatus.ok);
      expect(row.typeMismatch, isFalse);
    });

    test('sken jen DIST nehlásí PUM moduly jako chybějící', () {
      // Jednotka má PUM moduly, ale skenoval se jen DIST rozsah (vrátil {}).
      final modules = [
        const PumaModule.pumA(address: 128),
        const PumaModule.pumA(address: 129),
      ];
      final scan = BusScanResult.fromJson(
          jsonDecode('{}') as Map<String, dynamic>, at,
          scope: BusScanScope.dist);
      // PUM moduly jsou mimo rozsah skenu → žádné řádky, žádné falešné „chybí".
      expect(diagnoseBus(modules, scan), isEmpty);
    });

    test('sken jen PUM nehlásí DIST jako chybějící', () {
      final modules = [PumaModule.dist(address: 67)];
      final scan = BusScanResult.fromJson(
          jsonDecode('{"PUM-X":[128]}') as Map<String, dynamic>, at,
          scope: BusScanScope.pum);
      final rows = diagnoseBus(modules, scan);
      // DIST @67 mimo rozsah; jen nezaregistrovaný PUM-X @128.
      expect(rows.map((r) => r.address), [128]);
      expect(rows.single.status, BusScanStatus.unregistered);
    });

    test('sken jedné adresy (scanId) porovnává jen tu adresu', () {
      // Config má víc modulů, ale skenovala se jen adresa 130 (nalezena).
      final modules = [
        const PumaModule.pumA(address: 128),
        const PumaModule.pumA(address: 130),
        PumaModule.dist(address: 67),
      ];
      final scan = BusScanResult.fromJson(
          jsonDecode('{"PUM-A":[130]}') as Map<String, dynamic>, at,
          scanId: 130);
      final rows = diagnoseBus(modules, scan);
      // Jen řádek pro 130 — ostatní moduly se nehlásí jako „chybí".
      expect(rows.map((r) => r.address), [130]);
      expect(rows.single.status, BusScanStatus.ok);
    });

    test('sken jedné adresy: nakonfigurovaná, ale fyzicky chybí', () {
      final modules = [
        const PumaModule.pumA(address: 128),
        const PumaModule.pumA(address: 130),
      ];
      // Sken 130 nic nenašel (prázdná odpověď) → 130 chybí, 128 se neřeší.
      final scan = BusScanResult.fromJson(
          jsonDecode('{}') as Map<String, dynamic>, at,
          scanId: 130);
      final rows = diagnoseBus(modules, scan);
      expect(rows.map((r) => r.address), [130]);
      expect(rows.single.status, BusScanStatus.missing);
    });

    test('po přidání jednoho ghostu zůstane druhý ghost viditelný', () {
      // Rozsahový PUM sken našel dva neuložené devices: 133 a 134.
      final scan = BusScanResult.fromJson(
          jsonDecode('{"PUM-A":[133],"PUM-C":[134]}') as Map<String, dynamic>,
          at,
          scope: BusScanScope.pum);
      // Uživatel přidal 133 do configu (sken se NEzahazuje, jen se přepočítá).
      final modulesAfterAdd = [const PumaModule.pumA(address: 133)];
      final rows = {
        for (final r in diagnoseBus(modulesAfterAdd, scan)) r.address: r
      };
      expect(rows[133]!.status, BusScanStatus.ok); // přidaný → zezelená
      expect(rows[134]!.status,
          BusScanStatus.unregistered); // druhý ghost zůstane
    });

    test('PUM-A v konfiguraci vs PUM-C na sběrnici = nesoulad typu', () {
      final modules = [const PumaModule.pumA(address: 128)];
      final scan = BusScanResult.fromJson(
          jsonDecode('{"PUM-C":[128]}') as Map<String, dynamic>, at);
      final row = diagnoseBus(modules, scan).single;
      expect(row.status, BusScanStatus.ok);
      expect(row.typeMismatch, isTrue);
    });
  });
}
