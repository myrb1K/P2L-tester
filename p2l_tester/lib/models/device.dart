enum DeviceType { btn, disp, leds, dist }

extension DeviceTypeExt on DeviceType {
  String get code => switch (this) {
        DeviceType.btn => 'BTN',
        DeviceType.disp => 'DISP',
        DeviceType.leds => 'LEDS',
        DeviceType.dist => 'DIST',
      };

  /// 2-ciferný prefix pro zařízení v topicu (00 UNIT, 01 P2L, 04 DIST, 05 DISP, 11 LEDS)
  String? get addressPrefix => switch (this) {
        DeviceType.btn => null,
        DeviceType.disp => '05',
        DeviceType.leds => '11',
        DeviceType.dist => '04',
      };
}

DeviceType? deviceTypeFromCode(String code) => switch (code.toUpperCase()) {
      'BTN' => DeviceType.btn,
      'DISP' => DeviceType.disp,
      'LEDS' => DeviceType.leds,
      'DIST' => DeviceType.dist,
      _ => null,
    };

class Device {
  final DeviceType type;
  final int id;

  const Device({required this.type, required this.id});

  @override
  bool operator ==(Object other) =>
      other is Device && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);

  @override
  String toString() => '${type.code}/$id';
}
