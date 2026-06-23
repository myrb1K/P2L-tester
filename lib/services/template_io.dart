import 'dart:convert';

import '../models/device_template.dart';
import '../models/module.dart';

/// Wrapper formát pro export/import šablon.
///
/// ```json
/// {
///   "format": "p2l-tester.templates",
///   "version": 1,
///   "exportedAt": "2026-05-04T10:30:00Z",
///   "appVersion": "2.52",
///   "templates": [ { ...DeviceTemplate.toJson... } ]
/// }
/// ```
class TemplateBundle {
  static const String formatId = 'p2l-tester.templates';
  static const int currentVersion = 2;

  static String encode(
    List<DeviceTemplate> templates, {
    required String appVersion,
  }) {
    final payload = {
      'format': formatId,
      'version': currentVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
      'templates': templates.map((t) => {
        'name': t.name,
        'modules': _compactModules(t.modules),
        'created': t.created.toIso8601String(),
      }).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static String _moduleFingerprint(PumaModule m) {
    final distPart = m.distConfig == null
        ? 'null'
        : jsonEncode(Map.fromEntries(
            (m.distConfig!.toJson().entries.toList()
                ..sort((a, b) => a.key.compareTo(b.key)))));
    return '${m.type.name}|${m.buttonNumbers.join(',')}|${m.hasLeds}|$distPart';
  }

  static List<Map<String, dynamic>> _compactModules(List<PumaModule> modules) {
    final groups = <String, Map<String, dynamic>>{};
    for (final m in modules) {
      final fp = _moduleFingerprint(m);
      if (groups.containsKey(fp)) {
        groups[fp]!['baseAddresses'] += ',${m.baseAddress}';
      } else {
        final j = m.toJson();
        j.remove('baseAddress');
        j['baseAddresses'] = '${m.baseAddress}';
        groups[fp] = j;
      }
    }
    return groups.values.toList();
  }

  /// Vrací buď seznam šablon nebo chybovou zprávu — nikdy obojí.
  static TemplateBundleParseResult decode(String jsonString) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      return TemplateBundleParseResult.error('Soubor není platný JSON: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      return TemplateBundleParseResult.error(
          'Neplatný formát: očekáván objekt s "templates".');
    }
    if (decoded['format'] != formatId) {
      return TemplateBundleParseResult.error(
          'Neznámý formát souboru (chybí "$formatId").');
    }
    final version = decoded['version'];
    if (version is! int) {
      return TemplateBundleParseResult.error(
          'Neplatná verze formátu: $version.');
    }
    if (version == 1) {
      return TemplateBundleParseResult.error(
          'Soubor byl exportován starší verzí aplikace (formát v1). Exportujte šablony znovu v aktuální verzi.');
    }
    if (version > currentVersion) {
      return TemplateBundleParseResult.error(
          'Nepodporovaná verze formátu: $version. Aktualizuj aplikaci.');
    }
    final templatesRaw = decoded['templates'];
    if (templatesRaw is! List) {
      return TemplateBundleParseResult.error(
          'Neplatný formát: "templates" musí být pole.');
    }
    final templates = <DeviceTemplate>[];
    for (var i = 0; i < templatesRaw.length; i++) {
      final item = templatesRaw[i];
      if (item is! Map<String, dynamic>) {
        return TemplateBundleParseResult.error(
            'Šablona #${i + 1} není objekt.');
      }
      try {
        final templateName = item['name'] as String?;
        if (templateName == null || templateName.isEmpty) {
          return TemplateBundleParseResult.error(
              'Šablona #${i + 1} nemá název.');
        }
        final modulesRaw = item['modules'];
        if (modulesRaw is! List) {
          return TemplateBundleParseResult.error(
              'Šablona "$templateName" nemá pole modulů.');
        }
        final modules = <PumaModule>[];
        final seenAddresses = <int>{};
        for (var j = 0; j < modulesRaw.length; j++) {
          final moduleItem = modulesRaw[j];
          if (moduleItem is! Map<String, dynamic>) {
            return TemplateBundleParseResult.error(
                'Modul #${j + 1} v šabloně "$templateName" není objekt.');
          }
          final baseAddressesRaw = moduleItem['baseAddresses'];
          if (baseAddressesRaw is! String) {
            return TemplateBundleParseResult.error(
                'Modul #${j + 1} v šabloně "$templateName" nemá baseAddresses.');
          }
          final addresses = baseAddressesRaw
              .split(',')
              .map((s) => int.tryParse(s.trim()))
              .whereType<int>()
              .toList();
          if (addresses.isEmpty) {
            return TemplateBundleParseResult.error(
                'Modul #${j + 1} v šabloně "$templateName" má neplatné baseAddresses: "$baseAddressesRaw".');
          }
          for (final addr in addresses) {
            if (seenAddresses.contains(addr)) {
              return TemplateBundleParseResult.error(
                  'Duplikátní baseAddress $addr v šabloně "$templateName".');
            }
            seenAddresses.add(addr);
            final mData = Map<String, dynamic>.from(moduleItem);
            mData.remove('baseAddresses');
            mData['baseAddress'] = addr;
            modules.add(PumaModule.fromJson(mData));
          }
        }
        modules.sort((a, b) => a.baseAddress.compareTo(b.baseAddress));
        final created = item['created'];
        templates.add(DeviceTemplate(
          name: templateName,
          modules: modules,
          created: created is String
              ? DateTime.parse(created)
              : DateTime.now(),
        ));
      } catch (e) {
        return TemplateBundleParseResult.error(
            'Šablona #${i + 1} se nepodařila načíst: $e');
      }
    }
    if (templates.isEmpty) {
      return TemplateBundleParseResult.error('Soubor neobsahuje žádné šablony.');
    }
    return TemplateBundleParseResult.ok(templates);
  }
}

class TemplateBundleParseResult {
  final List<DeviceTemplate>? templates;
  final String? error;

  const TemplateBundleParseResult._(this.templates, this.error);

  factory TemplateBundleParseResult.ok(List<DeviceTemplate> templates) =>
      TemplateBundleParseResult._(templates, null);

  factory TemplateBundleParseResult.error(String error) =>
      TemplateBundleParseResult._(null, error);

  bool get isOk => error == null;
}
