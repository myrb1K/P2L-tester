import 'device.dart';

enum ModuleType { pumA, pumB, pumC, dist }

extension ModuleTypeExt on ModuleType {
  String get label => switch (this) {
        ModuleType.pumA => 'PUM-A',
        ModuleType.pumB => 'PUM-B',
        ModuleType.pumC => 'PUM-C',
        ModuleType.dist => 'DIST',
      };
}

/// Strana tlačítka PUM-A s 1 tlačítkem.
/// Levé = BTN 1000+N, Pravé = BTN N.
enum ButtonSide { left, right }

class DistConfig {
  final int measurePeriod;
  final int timeout;
  final int countMeasures;
  final int maxDeviation;
  final int offset;
  final int measureType; // 1=Short(do 1m), 2=Middle(do 2m), 3=Long(do 3m)

  const DistConfig({
    this.measurePeriod = 50,
    this.timeout = 10,
    this.countMeasures = 4,
    this.maxDeviation = 20,
    this.offset = 0,
    this.measureType = 2,
  });

  DistConfig copyWith({
    int? measurePeriod,
    int? timeout,
    int? countMeasures,
    int? maxDeviation,
    int? offset,
    int? measureType,
  }) =>
      DistConfig(
        measurePeriod: measurePeriod ?? this.measurePeriod,
        timeout: timeout ?? this.timeout,
        countMeasures: countMeasures ?? this.countMeasures,
        maxDeviation: maxDeviation ?? this.maxDeviation,
        offset: offset ?? this.offset,
        measureType: measureType ?? this.measureType,
      );

  Map<String, dynamic> toJson() => {
        'MeasurePeriod': measurePeriod,
        'Timeout': timeout,
        'CountMeasures': countMeasures,
        'MaxDeviation': maxDeviation,
        'Offset': offset,
        'MeasureType': measureType,
      };

  factory DistConfig.fromJson(Map<String, dynamic> json) => DistConfig(
        measurePeriod: json['MeasurePeriod'] as int? ?? json['measurePeriod'] as int? ?? 50,
        timeout: json['Timeout'] as int? ?? json['timeout'] as int? ?? 10,
        countMeasures: json['CountMeasures'] as int? ?? json['countMeasures'] as int? ?? 4,
        maxDeviation: json['MaxDeviation'] as int? ?? json['maxDeviation'] as int? ?? 20,
        offset: json['Offset'] as int? ?? json['offset'] as int? ?? 0,
        measureType: json['MeasureType'] as int? ?? json['measureType'] as int? ?? 2,
      );
}

/// Fyzický modul (1 čip). Viz POSTUP.MD sekce "PUMA moduly".
class PumaModule {
  final ModuleType type;
  final int baseAddress;
  final int buttonCount; // jen pro PUM-A: 0/1/2; pevně 1 pro PUM-B, 2 pro PUM-C
  final bool hasLeds; // pro PUM-A i PUM-B (LED kroužek na adrese baseAddress)
  final ButtonSide? buttonSide; // jen pro PUM-A s 1 tlačítkem
  final DistConfig? distConfig; // jen pro DIST

  const PumaModule({
    required this.type,
    required this.baseAddress,
    this.buttonCount = 0,
    this.hasLeds = false,
    this.buttonSide,
    this.distConfig,
  });

  const PumaModule.pumA({
    required int address,
    int buttonCount = 0,
    bool hasLeds = false,
    ButtonSide? buttonSide,
  }) : this(
          type: ModuleType.pumA,
          baseAddress: address,
          buttonCount: buttonCount,
          hasLeds: hasLeds,
          buttonSide: buttonSide,
        );

  const PumaModule.pumB({required int address, bool hasLeds = false})
      : this(
          type: ModuleType.pumB,
          baseAddress: address,
          buttonCount: 1,
          hasLeds: hasLeds,
        );

  const PumaModule.pumC({required int address})
      : this(type: ModuleType.pumC, baseAddress: address, buttonCount: 2);

  PumaModule.dist({required int address, DistConfig? config})
      : this(
          type: ModuleType.dist,
          baseAddress: address,
          distConfig: config ?? const DistConfig(),
        );

  /// Všechny MQTT Device záznamy, které tento modul (1 čip) generuje do GET-DEVICES.
  /// PUM-A/PUM-C konvence: BTN levé = 1000+N, BTN pravé = N.
  List<Device> toDevices() {
    switch (type) {
      case ModuleType.pumA:
        return [
          Device(type: DeviceType.disp, id: baseAddress),
          if (hasLeds) Device(type: DeviceType.leds, id: baseAddress),
          if (buttonCount == 1)
            Device(
              type: DeviceType.btn,
              id: buttonSide == ButtonSide.right ? baseAddress : 1000 + baseAddress,
            ),
          if (buttonCount == 2) ...[
            Device(type: DeviceType.btn, id: 1000 + baseAddress),
            Device(type: DeviceType.btn, id: baseAddress),
          ],
        ];
      case ModuleType.pumB:
        return [
          Device(type: DeviceType.btn, id: baseAddress),
          if (hasLeds) Device(type: DeviceType.leds, id: baseAddress),
        ];
      case ModuleType.pumC:
        return [
          Device(type: DeviceType.btn, id: 1000 + baseAddress),
          Device(type: DeviceType.btn, id: baseAddress),
        ];
      case ModuleType.dist:
        return [Device(type: DeviceType.dist, id: baseAddress)];
    }
  }

  String get displayLabel {
    switch (type) {
      case ModuleType.pumA:
        final parts = <String>['PUM-A @$baseAddress'];
        if (buttonCount == 0) {
          parts.add('bez tl.');
        } else if (buttonCount == 1) {
          parts.add(buttonSide == ButtonSide.right ? '1 tl. (P)' : '1 tl. (L)');
        } else {
          parts.add('2 tl.');
        }
        if (hasLeds) parts.add('LEDS');
        return parts.join(' · ');
      case ModuleType.pumB:
        return hasLeds ? 'PUM-B @$baseAddress · LEDS' : 'PUM-B @$baseAddress';
      case ModuleType.pumC:
        return 'PUM-C @$baseAddress';
      case ModuleType.dist:
        return 'DIST @$baseAddress';
    }
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'baseAddress': baseAddress,
        'buttonCount': buttonCount,
        'hasLeds': hasLeds,
        if (buttonSide != null) 'buttonSide': buttonSide!.name,
        if (distConfig != null) 'distConfig': distConfig!.toJson(),
      };

  factory PumaModule.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String;
    final type = ModuleType.values.firstWhere((t) => t.name == typeName);
    final sideName = json['buttonSide'] as String?;
    return PumaModule(
      type: type,
      baseAddress: json['baseAddress'] as int,
      buttonCount: json['buttonCount'] as int? ?? 0,
      hasLeds: json['hasLeds'] as bool? ?? false,
      buttonSide: sideName == null
          ? null
          : ButtonSide.values.firstWhere((s) => s.name == sideName),
      distConfig: json['distConfig'] != null
          ? DistConfig.fromJson(json['distConfig'] as Map<String, dynamic>)
          : (type == ModuleType.dist ? const DistConfig() : null),
    );
  }
}
