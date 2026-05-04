import 'dart:convert';

import '../models/device_template.dart';

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
  static const int currentVersion = 1;

  static String encode(
    List<DeviceTemplate> templates, {
    required String appVersion,
  }) {
    final payload = {
      'format': formatId,
      'version': currentVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
      'templates': templates.map((t) => t.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
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
    if (version is! int || version > currentVersion) {
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
        templates.add(DeviceTemplate.fromJson(item));
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
