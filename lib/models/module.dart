import 'device.dart';

enum ModuleType { pumA, pumB, pumC, dist }

extension ModuleTypeExt on ModuleType {
  String get label => switch (this) {
        ModuleType.pumA => 'PUM-A',
        ModuleType.pumB => 'PUM-B',
        ModuleType.pumC => 'PUM-C',
        ModuleType.dist => 'DIST',
      };

  /// Platný rozsah adres podle typu modulu (včetně obou mezí). Horní mez je
  /// zároveň factory default ([defaultAddress]).
  ///
  /// - PUM-A: 128–246 (246 = default)
  /// - PUM-B: 128–247 (247 = default)
  /// - PUM-C: 128–247 (247 = default)
  /// - DIST:  1–127  (127 = default)
  ({int min, int max}) get addressRange => switch (this) {
        ModuleType.pumA => (min: 128, max: 246),
        ModuleType.pumB => (min: 128, max: 247),
        ModuleType.pumC => (min: 128, max: 247),
        ModuleType.dist => (min: 1, max: 127),
      };

  /// Factory default adresa (= horní mez [addressRange]).
  int get defaultAddress => addressRange.max;
}

/// Tlačítko PUM-A okolo displeje. PUM-A může mít 0–4 tlačítka (2 vlevo, 2 vpravo).
/// Číslo tlačítka (0–3) = tisícová číslice jeho MQTT adresy (offset/1000),
/// adresa tlačítka = offset + baseAddress (adresa DISP).
///
/// Fyzicky zleva doprava: leftOuter(3) · leftInner(1) · DISPLEJ · rightInner(0) · rightOuter(2).
/// Na každé straně je nižší číslo vnitřní (u displeje), vyšší vnější.
enum PumaButton { rightInner, leftInner, rightOuter, leftOuter }

extension PumaButtonExt on PumaButton {
  /// Číslo tlačítka (0–3) = tisícová číslice adresy.
  int get number => switch (this) {
        PumaButton.rightInner => 0,
        PumaButton.leftInner => 1,
        PumaButton.rightOuter => 2,
        PumaButton.leftOuter => 3,
      };

  /// Adresní offset (0 / 1000 / 2000 / 3000).
  int get offset => number * 1000;

  /// Levá strana displeje (čísla 1 a 3 → zvýraznění levé hrany buňky).
  bool get isLeft =>
      this == PumaButton.leftInner || this == PumaButton.leftOuter;

  /// MQTT adresa tlačítka pro PUM-A se zadanou bázovou adresou (DISP).
  int addressFor(int base) => offset + base;

  /// Lidský popisek fyzické pozice.
  String get positionLabel => switch (this) {
        PumaButton.leftOuter => 'levé-vlevo',
        PumaButton.leftInner => 'levé-vpravo',
        PumaButton.rightInner => 'pravé-vlevo',
        PumaButton.rightOuter => 'pravé-vpravo',
      };

  /// Tlačítko podle čísla (0–3), nebo null pro neznámé číslo.
  static PumaButton? fromNumber(int n) => switch (n) {
        0 => PumaButton.rightInner,
        1 => PumaButton.leftInner,
        2 => PumaButton.rightOuter,
        3 => PumaButton.leftOuter,
        _ => null,
      };
}

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
  final Set<PumaButton> buttons; // jen pro PUM-A: 0–4 tlačítka okolo displeje
  final bool hasLeds; // pro PUM-A i PUM-B (LED kroužek na adrese baseAddress)
  final DistConfig? distConfig; // jen pro DIST

  const PumaModule({
    required this.type,
    required this.baseAddress,
    this.buttons = const <PumaButton>{},
    this.hasLeds = false,
    this.distConfig,
  });

  /// Počet osazených tlačítek PUM-A (0–4).
  int get buttonCount => buttons.length;

  /// Čísla osazených tlačítek (0–3) vzestupně.
  List<int> get buttonNumbers =>
      buttons.map((b) => b.number).toList()..sort();

  const PumaModule.pumA({
    required int address,
    Set<PumaButton> buttons = const <PumaButton>{},
    bool hasLeds = false,
  }) : this(
          type: ModuleType.pumA,
          baseAddress: address,
          buttons: buttons,
          hasLeds: hasLeds,
        );

  const PumaModule.pumB({required int address, bool hasLeds = false})
      : this(
          type: ModuleType.pumB,
          baseAddress: address,
          hasLeds: hasLeds,
        );

  const PumaModule.pumC({required int address})
      : this(type: ModuleType.pumC, baseAddress: address);

  PumaModule.dist({required int address, DistConfig? config})
      : this(
          type: ModuleType.dist,
          baseAddress: address,
          distConfig: config ?? const DistConfig(),
        );

  /// Všechny MQTT Device záznamy, které tento modul (1 čip) generuje do GET-DEVICES.
  /// PUM-A tlačítka: adresa = offset(0/1000/2000/3000) + baseAddress (viz [PumaButton]).
  /// PUM-C konvence: BTN + = 1000+N, BTN − = N. PUM-B: BTN N.
  List<Device> toDevices() {
    switch (type) {
      case ModuleType.pumA:
        final sorted = buttons.toList()
          ..sort((a, b) => a.number.compareTo(b.number));
        return [
          Device(type: DeviceType.disp, id: baseAddress),
          if (hasLeds) Device(type: DeviceType.leds, id: baseAddress),
          for (final b in sorted)
            Device(type: DeviceType.btn, id: b.addressFor(baseAddress)),
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
        if (buttons.isEmpty) {
          parts.add('bez tl.');
        } else {
          parts.add('${buttons.length} tl. (${buttonNumbers.join(',')})');
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
        if (type == ModuleType.pumA) 'buttons': buttonNumbers,
        'hasLeds': hasLeds,
        if (distConfig != null) 'distConfig': distConfig!.toJson(),
      };

  factory PumaModule.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String;
    final type = ModuleType.values.firstWhere((t) => t.name == typeName);
    return PumaModule(
      type: type,
      baseAddress: json['baseAddress'] as int,
      buttons: type == ModuleType.pumA
          ? _buttonsFromJson(json)
          : const <PumaButton>{},
      hasLeds: json['hasLeds'] as bool? ?? false,
      distConfig: json['distConfig'] != null
          ? DistConfig.fromJson(json['distConfig'] as Map<String, dynamic>)
          : (type == ModuleType.dist ? const DistConfig() : null),
    );
  }

  /// Načte sadu tlačítek PUM-A z JSON.
  /// Nový formát: `"buttons": [0,1,2,3]`.
  /// Starý formát (migrace): `"buttonCount"` (0/1/2) + `"buttonSide"`
  /// ("left" = 1000+N → tl. 1, "right" = N → tl. 0); 2 tl. = {0,1}.
  static Set<PumaButton> _buttonsFromJson(Map<String, dynamic> json) {
    final raw = json['buttons'];
    if (raw is List) {
      final out = <PumaButton>{};
      for (final n in raw) {
        final b = n is int ? PumaButtonExt.fromNumber(n) : null;
        if (b != null) out.add(b);
      }
      return out;
    }
    final count = json['buttonCount'] as int? ?? 0;
    if (count <= 0) return const <PumaButton>{};
    if (count == 1) {
      return {
        json['buttonSide'] == 'right'
            ? PumaButton.rightInner
            : PumaButton.leftInner
      };
    }
    return {PumaButton.leftInner, PumaButton.rightInner};
  }
}
