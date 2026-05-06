import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:p2l_tester/models/device_template.dart';
import 'package:p2l_tester/models/module.dart';
import 'package:p2l_tester/services/template_io.dart';

void main() {
  group('TemplateBundle v2', () {
    test('encode sloučí moduly se shodnou konfigurací do CSV baseAddresses', () {
      final modules = [
        PumaModule(
          type: ModuleType.pumA,
          baseAddress: 128,
          buttonCount: 1,
          hasLeds: true,
          buttonSide: ButtonSide.left,
        ),
        PumaModule(
          type: ModuleType.pumC,
          baseAddress: 129,
          buttonCount: 2,
          hasLeds: false,
        ),
        PumaModule(
          type: ModuleType.pumA,
          baseAddress: 130,
          buttonCount: 1,
          hasLeds: true,
          buttonSide: ButtonSide.left,
        ),
        PumaModule(
          type: ModuleType.pumC,
          baseAddress: 131,
          buttonCount: 2,
          hasLeds: false,
        ),
        PumaModule(
          type: ModuleType.pumB,
          baseAddress: 132,
          buttonCount: 1,
          hasLeds: true,
        ),
      ];
      final template = DeviceTemplate(
        name: 'Test template',
        modules: modules,
        created: DateTime(2026, 5, 6, 12, 0, 0),
      );
      final json = TemplateBundle.encode([template], appVersion: '2.56');
      expect(json.contains('"version": 2'), true);

      final decoded = jsonDecode(json);
      expect(decoded['version'], 2);
      expect(decoded['templates'], isNotEmpty);
      final templateJson = decoded['templates'][0];
      expect(templateJson['modules'], isA<List>());
      expect(templateJson['modules'].length, 3);

      final pumAEntry = templateJson['modules']
          .firstWhere((m) => m['type'] == 'pumA') as Map<String, dynamic>;
      expect(pumAEntry['baseAddresses'], '128,130');

      final pumCEntry = templateJson['modules']
          .firstWhere((m) => m['type'] == 'pumC') as Map<String, dynamic>;
      expect(pumCEntry['baseAddresses'], '129,131');
    });

    test('decode expanduje CSV baseAddresses a seřadí moduly podle adresy', () {
      const jsonString = '''
{
  "format": "p2l-tester.templates",
  "version": 2,
  "exportedAt": "2026-05-06T12:00:00.000Z",
  "appVersion": "2.56",
  "templates": [
    {
      "name": "Test",
      "modules": [
        {
          "type": "pumA",
          "baseAddresses": "128,130",
          "buttonCount": 1,
          "hasLeds": true,
          "buttonSide": "left"
        },
        {
          "type": "pumC",
          "baseAddresses": "129,131",
          "buttonCount": 2,
          "hasLeds": false
        }
      ],
      "created": "2026-05-06T12:00:00.000Z"
    }
  ]
}
''';
      final result = TemplateBundle.decode(jsonString);
      expect(result.isOk, true);
      expect(result.templates, isNotNull);
      expect(result.templates!.length, 1);

      final template = result.templates![0];
      expect(template.name, 'Test');
      expect(template.modules.length, 4);

      expect(template.modules[0].baseAddress, 128);
      expect(template.modules[0].type, ModuleType.pumA);

      expect(template.modules[1].baseAddress, 129);
      expect(template.modules[1].type, ModuleType.pumC);

      expect(template.modules[2].baseAddress, 130);
      expect(template.modules[2].type, ModuleType.pumA);

      expect(template.modules[3].baseAddress, 131);
      expect(template.modules[3].type, ModuleType.pumC);
    });

    test('decode odmítne formát v1 s přátelskou chybou', () {
      const jsonString = '''
{
  "format": "p2l-tester.templates",
  "version": 1,
  "exportedAt": "2026-05-06T12:00:00.000Z",
  "appVersion": "2.55",
  "templates": [
    {
      "name": "Old format",
      "modules": [
        {
          "type": "pumA",
          "baseAddress": 128,
          "buttonCount": 1,
          "hasLeds": true,
          "buttonSide": "left"
        }
      ],
      "created": "2026-05-06T12:00:00.000Z"
    }
  ]
}
''';
      final result = TemplateBundle.decode(jsonString);
      expect(result.isOk, false);
      expect(result.error, contains('formát v1'));
      expect(result.error, contains('Exportujte'));
    });

    test('decode seřadí moduly podle baseAddress', () {
      const jsonString = '''
{
  "format": "p2l-tester.templates",
  "version": 2,
  "exportedAt": "2026-05-06T12:00:00.000Z",
  "appVersion": "2.56",
  "templates": [
    {
      "name": "Unsorted",
      "modules": [
        {
          "type": "pumB",
          "baseAddresses": "132",
          "buttonCount": 1,
          "hasLeds": true
        },
        {
          "type": "pumA",
          "baseAddresses": "128,130",
          "buttonCount": 1,
          "hasLeds": true,
          "buttonSide": "left"
        },
        {
          "type": "pumC",
          "baseAddresses": "129,131",
          "buttonCount": 2,
          "hasLeds": false
        }
      ],
      "created": "2026-05-06T12:00:00.000Z"
    }
  ]
}
''';
      final result = TemplateBundle.decode(jsonString);
      expect(result.isOk, true);
      final template = result.templates![0];
      final addresses = template.modules.map((m) => m.baseAddress).toList();
      expect(addresses, [128, 129, 130, 131, 132]);
    });

    test('encode+decode round-trip zachová všechny údaje', () {
      final modules = [
        PumaModule(
          type: ModuleType.pumA,
          baseAddress: 128,
          buttonCount: 1,
          hasLeds: true,
          buttonSide: ButtonSide.left,
        ),
        PumaModule(
          type: ModuleType.pumA,
          baseAddress: 130,
          buttonCount: 1,
          hasLeds: true,
          buttonSide: ButtonSide.left,
        ),
      ];
      final original = DeviceTemplate(
        name: 'Round-trip test',
        modules: modules,
        created: DateTime(2026, 5, 6, 12, 0, 0),
      );

      final encoded = TemplateBundle.encode([original], appVersion: '2.56');
      final result = TemplateBundle.decode(encoded);
      expect(result.isOk, true);

      final decoded = result.templates![0];
      expect(decoded.name, original.name);
      expect(decoded.modules.length, 2);
      expect(decoded.modules[0].type, ModuleType.pumA);
      expect(decoded.modules[0].baseAddress, 128);
      expect(decoded.modules[0].buttonCount, 1);
      expect(decoded.modules[0].hasLeds, true);
      expect(decoded.modules[0].buttonSide, ButtonSide.left);
    });

    test('decode odmítne neplatné baseAddresses s chybou', () {
      const jsonString = '''
{
  "format": "p2l-tester.templates",
  "version": 2,
  "exportedAt": "2026-05-06T12:00:00.000Z",
  "appVersion": "2.56",
  "templates": [
    {
      "name": "Bad addresses",
      "modules": [
        {
          "type": "pumA",
          "baseAddresses": "not-a-number",
          "buttonCount": 1,
          "hasLeds": true
        }
      ],
      "created": "2026-05-06T12:00:00.000Z"
    }
  ]
}
''';
      final result = TemplateBundle.decode(jsonString);
      expect(result.isOk, false);
      expect(result.error, contains('neplatné'));
    });

    test('decode akceptuje single address i CSV', () {
      const jsonString = '''
{
  "format": "p2l-tester.templates",
  "version": 2,
  "exportedAt": "2026-05-06T12:00:00.000Z",
  "appVersion": "2.56",
  "templates": [
    {
      "name": "Single",
      "modules": [
        {
          "type": "pumA",
          "baseAddresses": "128",
          "buttonCount": 1,
          "hasLeds": true
        }
      ],
      "created": "2026-05-06T12:00:00.000Z"
    }
  ]
}
''';
      final result = TemplateBundle.decode(jsonString);
      expect(result.isOk, true);
      expect(result.templates![0].modules.length, 1);
      expect(result.templates![0].modules[0].baseAddress, 128);
    });

    test('decode odmítne duplikátní baseAddress s chybou', () {
      const jsonString = '''
{
  "format": "p2l-tester.templates",
  "version": 2,
  "exportedAt": "2026-05-06T12:00:00.000Z",
  "appVersion": "2.56",
  "templates": [
    {
      "name": "Duplicates",
      "modules": [
        {
          "type": "pumA",
          "baseAddresses": "128,130",
          "buttonCount": 1,
          "hasLeds": true,
          "buttonSide": "left"
        },
        {
          "type": "pumC",
          "baseAddresses": "128,131",
          "buttonCount": 2,
          "hasLeds": false
        }
      ],
      "created": "2026-05-06T12:00:00.000Z"
    }
  ]
}
''';
      final result = TemplateBundle.decode(jsonString);
      expect(result.isOk, false);
      expect(result.error, contains('Duplikátní'));
      expect(result.error, contains('128'));
    });
  });
}
