import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/services/unit_ids_io.dart';

void main() {
  group('canonicalUnitId', () {
    test('numerická hodnota < 1000 → 4 cifry', () {
      expect(canonicalUnitId('472'), '0472');
      expect(canonicalUnitId('0472'), '0472');
      expect(canonicalUnitId('1'), '0001');
    });

    test('numerická hodnota ≥ 1000 → 6 cifer', () {
      expect(canonicalUnitId('1017'), '001017');
      expect(canonicalUnitId('001017'), '001017');
      expect(canonicalUnitId('999999'), '999999');
    });

    test('akceptuje prefix "u"', () {
      expect(canonicalUnitId('u0472'), '0472');
      expect(canonicalUnitId('u1017'), '001017');
    });

    test('trim whitespace', () {
      expect(canonicalUnitId('  1017  '), '001017');
    });

    test('neplatný vstup → null', () {
      expect(canonicalUnitId(''), isNull);
      expect(canonicalUnitId('abc'), isNull);
      expect(canonicalUnitId('1017x'), isNull);
      expect(canonicalUnitId('1234567'), isNull); // 7 cifer mimo rozsah
      expect(canonicalUnitId('-1'), isNull);
    });
  });

  group('UnitIdsBundle', () {
    test('encode obsahuje povinná pole', () {
      final json = UnitIdsBundle.encode(
        ['001017', '001023', '0472'],
        brokerName: 'Test Broker',
        appVersion: '2.59',
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['format'], 'p2l-tester.unit-ids');
      expect(decoded['version'], 1);
      expect(decoded['appVersion'], '2.59');
      expect(decoded['broker'], 'Test Broker');
      expect(decoded['unitIds'], ['001017', '001023', '0472']);
      expect(decoded['exportedAt'], isA<String>());
    });

    test('round-trip encode → decode', () {
      final source = ['001017', '001023', '0472'];
      final json = UnitIdsBundle.encode(
        source,
        brokerName: 'Test',
        appVersion: '2.59',
      );
      final parsed = UnitIdsBundle.decode(json);
      expect(parsed.isOk, isTrue);
      expect(parsed.ids, source);
      expect(parsed.broker, 'Test');
      expect(parsed.skipped, isEmpty);
    });

    test('decode normalizuje a deduplikuje ID', () {
      final json = jsonEncode({
        'format': 'p2l-tester.unit-ids',
        'version': 1,
        'unitIds': ['1017', '001017', '472', 'u0472', '1023'],
      });
      final parsed = UnitIdsBundle.decode(json);
      expect(parsed.isOk, isTrue);
      expect(parsed.ids, ['001017', '0472', '001023']);
    });

    test('decode přeskočí neplatná ID a zapíše do skipped', () {
      final json = jsonEncode({
        'format': 'p2l-tester.unit-ids',
        'version': 1,
        'unitIds': ['1017', 'abc', '', '999999', 'xyz123'],
      });
      final parsed = UnitIdsBundle.decode(json);
      expect(parsed.isOk, isTrue);
      expect(parsed.ids, ['001017', '999999']);
      expect(parsed.skipped, ['abc', '', 'xyz123']);
    });

    test('decode odmítne neznámý formát', () {
      final json = jsonEncode({'format': 'foo', 'version': 1, 'unitIds': []});
      final parsed = UnitIdsBundle.decode(json);
      expect(parsed.isOk, isFalse);
      expect(parsed.error, contains('Neznámý formát'));
    });

    test('decode odmítne vyšší verzi formátu', () {
      final json = jsonEncode({
        'format': 'p2l-tester.unit-ids',
        'version': 99,
        'unitIds': [],
      });
      final parsed = UnitIdsBundle.decode(json);
      expect(parsed.isOk, isFalse);
      expect(parsed.error, contains('Nepodporovaná verze'));
    });

    test('decode odmítne nesprávný JSON', () {
      final parsed = UnitIdsBundle.decode('not a json');
      expect(parsed.isOk, isFalse);
      expect(parsed.error, contains('JSON'));
    });
  });

  group('unitIdsFileName', () {
    test('standardní broker → čistý filename s ID-Nx', () {
      final now = DateTime(2026, 5, 11, 14, 30);
      final name = unitIdsFileName('Smartbox-Cloud', 42, now);
      expect(name, 'Smartbox-Cloud_ID-42x_2026-05-11T14-30.json');
    });

    test('broker s mezerami zachová mezery', () {
      final now = DateTime(2026, 5, 11, 14, 30);
      final name = unitIdsFileName('Smart Box', 5, now);
      expect(name, 'Smart Box_ID-5x_2026-05-11T14-30.json');
    });

    test('broker s nepovolenými znaky → podtržítka', () {
      final now = DateTime(2026, 5, 11, 14, 30);
      final name = unitIdsFileName('Broker/With:Slash', 1, now);
      expect(name, 'Broker_With_Slash_ID-1x_2026-05-11T14-30.json');
    });

    test('broker s diakritikou zachová znaky', () {
      final now = DateTime(2026, 5, 11, 14, 30);
      final name = unitIdsFileName('Příklad', 3, now);
      expect(name, 'Příklad_ID-3x_2026-05-11T14-30.json');
    });

    test('prázdný název → fallback "P2L"', () {
      final now = DateTime(2026, 5, 11, 14, 30);
      final name = unitIdsFileName('', 7, now);
      expect(name, 'P2L_ID-7x_2026-05-11T14-30.json');
    });

    test('padding měsíce/dne/hodiny/minuty', () {
      final now = DateTime(2026, 1, 5, 7, 3);
      final name = unitIdsFileName('Test', 1, now);
      expect(name, 'Test_ID-1x_2026-01-05T07-03.json');
    });
  });

  group('brokerProfile v JSON', () {
    test('encode bez profilu → klíč chybí', () {
      final json = UnitIdsBundle.encode(
        ['001017'],
        brokerName: 'Test',
        appVersion: '2.58',
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded.containsKey('brokerProfile'), isFalse);
    });

    test('encode s profilem → klíč obsahuje data', () {
      final profile = {
        'name': 'SM-ALMECO',
        'broker': 'broker.example.com',
        'port': 1883,
        'username': 'user',
        'password': 'pass',
        'useSsl': false,
      };
      final json = UnitIdsBundle.encode(
        ['001167', '001180'],
        brokerName: 'SM-ALMECO',
        appVersion: '2.58',
        brokerProfile: profile,
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['brokerProfile'], profile);
    });

    test('round-trip s profilem', () {
      final profile = {
        'name': 'SM-ALMECO',
        'broker': 'broker.example.com',
        'port': 8883,
        'username': 'user',
        'password': 'pass',
        'useSsl': true,
      };
      final json = UnitIdsBundle.encode(
        ['001167'],
        brokerName: 'SM-ALMECO',
        appVersion: '2.58',
        brokerProfile: profile,
      );
      final parsed = UnitIdsBundle.decode(json);
      expect(parsed.isOk, isTrue);
      expect(parsed.brokerProfile, profile);
    });

    test('decode bez profilu → brokerProfile == null', () {
      final json = jsonEncode({
        'format': 'p2l-tester.unit-ids',
        'version': 1,
        'unitIds': ['001017'],
      });
      final parsed = UnitIdsBundle.decode(json);
      expect(parsed.isOk, isTrue);
      expect(parsed.brokerProfile, isNull);
    });
  });
}
