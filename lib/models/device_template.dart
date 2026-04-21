import 'dart:convert';

import 'module.dart';

class DeviceTemplate {
  final String name;
  final List<PumaModule> modules;
  final DateTime created;

  const DeviceTemplate({
    required this.name,
    required this.modules,
    required this.created,
  });

  int get chipCount => modules.length;

  DeviceTemplate copyWith({String? name, List<PumaModule>? modules}) =>
      DeviceTemplate(
        name: name ?? this.name,
        modules: modules ?? this.modules,
        created: created,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'modules': modules.map((m) => m.toJson()).toList(),
        'created': created.toIso8601String(),
      };

  factory DeviceTemplate.fromJson(Map<String, dynamic> json) => DeviceTemplate(
        name: json['name'] as String,
        modules: (json['modules'] as List)
            .map((m) => PumaModule.fromJson(m as Map<String, dynamic>))
            .toList(),
        created: DateTime.parse(json['created'] as String),
      );

  static String listToJson(List<DeviceTemplate> templates) =>
      jsonEncode(templates.map((t) => t.toJson()).toList());

  static List<DeviceTemplate> listFromJson(String json) =>
      (jsonDecode(json) as List)
          .map((t) => DeviceTemplate.fromJson(t as Map<String, dynamic>))
          .toList();
}
