/// Konfigurace LED zařízení jednotky (P2L, kód device `01`).
///
/// Na rozdíl od PUM-A/PUM-B LED kroužků jde o LED pásky připojené přímo na
/// porty jednotky (0–7). Konfigurace se čte z P2L `GET-CONFIG`
/// (`{"brightness":50,"leds port0":60,"color0":"ff0000","color2_0":"00ff00",…}`),
/// který umí jen FW ≥ `P2L_26071501NT`. Starší firmware neodpoví → pracuje se
/// s výchozími hodnotami ([P2lLedConfig.empty]).
library;

/// Počet LED portů na jednotce.
const int kP2lPortCount = 8;

/// Počet barevných slotů (`color_id` 0–5).
const int kP2lColorCount = 6;

/// Jedna barva `color_id`. [rgb] je primární, [rgb2] sekundární („color2") —
/// tu využívají styly se střídáním barev (`style_id` 5 a 6).
class P2lColorSlot {
  final int rgb;
  final int rgb2;

  const P2lColorSlot(this.rgb, this.rgb2);

  int get red => (rgb >> 16) & 0xFF;
  int get green => (rgb >> 8) & 0xFF;
  int get blue => rgb & 0xFF;

  int get red2 => (rgb2 >> 16) & 0xFF;
  int get green2 => (rgb2 >> 8) & 0xFF;
  int get blue2 => rgb2 & 0xFF;

  P2lColorSlot copyWith({int? rgb, int? rgb2}) =>
      P2lColorSlot(rgb ?? this.rgb, rgb2 ?? this.rgb2);

  @override
  bool operator ==(Object other) =>
      other is P2lColorSlot && other.rgb == rgb && other.rgb2 == rgb2;

  @override
  int get hashCode => Object.hash(rgb, rgb2);
}

/// Tovární barvy slotů podle [README-P2L.md]. Slouží jako popisek i jako
/// fallback, dokud jednotka neodpoví na `GET-CONFIG` — skutečné RGB se dá
/// přepsat (`SET-CONFIG` → `colors`), takže tahle tabulka **není** pravda
/// o tom, co v jednotce opravdu je.
const List<P2lColorSlot> kP2lDefaultColors = [
  P2lColorSlot(0xFF0000, 0x00FF00), // 0 RED    / GREEN
  P2lColorSlot(0x00FF00, 0xFF0000), // 1 GREEN  / RED
  P2lColorSlot(0x0000FF, 0xFFFF00), // 2 BLUE   / YELLOW
  P2lColorSlot(0xFFFF00, 0x0000FF), // 3 YELLOW / BLUE
  P2lColorSlot(0xFF00FF, 0xFFFFFF), // 4 PURPLE / WHITE
  P2lColorSlot(0xFFFFFF, 0xFF00FF), // 5 WHITE  / PURPLE
];

/// Tovární názvy barev (jen orientační popisek k číslu slotu).
const List<String> kP2lDefaultColorNames = [
  'RED',
  'GREEN',
  'BLUE',
  'YELLOW',
  'PURPLE',
  'WHITE',
];

/// Styly svícení (`style_id`).
///
/// Pozor: README-P2L.md má v tabulce překlep — `3` chybí úplně a `5` je
/// uvedené dvakrát (jednou jako „bliká s 1/2 intenzitou inverzně", podruhé
/// jako „svícení střídání barev"). Bereme druhý význam, protože navazuje na
/// `color2`; `3` do nabídky nedáváme, dokud ho neověříme na jednotce.
const Map<int, String> kP2lStyles = {
  0: 'svítí',
  1: 'bliká',
  2: 'bliká inverzně',
  4: 'bliká s 1/2 intenzitou',
  5: 'střídání barev',
  6: 'blikání střídáním barev',
  7: 'split svícení',
  8: 'split blikání',
};

/// Konfigurace P2L LED načtená z jednotky.
class P2lLedConfig {
  /// Jas 1–100; `null` = jednotka zatím neodpověděla.
  final int? brightness;

  /// Počet LED na portu (port → počet). Chybějící port = neznámý.
  final Map<int, int> ledCounts;

  /// Barevné sloty (`color_id` → barvy). Chybějící slot = neznámý.
  final Map<int, P2lColorSlot> colors;

  /// Kdy odpověď dorazila (`null` = nikdy).
  final DateTime? fetchedAt;

  const P2lLedConfig({
    this.brightness,
    this.ledCounts = const {},
    this.colors = const {},
    this.fetchedAt,
  });

  static const P2lLedConfig empty = P2lLedConfig();

  /// Jednotka odpověděla na `GET-CONFIG` (byť jen částečně).
  bool get isLoaded => fetchedAt != null;

  /// Barva slotu z jednotky, jinak tovární fallback.
  P2lColorSlot colorOf(int id) =>
      colors[id] ??
      (id >= 0 && id < kP2lDefaultColors.length
          ? kP2lDefaultColors[id]
          : const P2lColorSlot(0xFFFFFF, 0x000000));

  /// Počet LED na portu; `null` když ho jednotka nehlásila.
  int? ledCountOf(int port) => ledCounts[port];

  /// Největší počet LED přes všechny porty — použije se jako horní mez pro
  /// „LED do", aby dialog nenabízel víc, než kolik pásek reálně má.
  int get maxLedCount => ledCounts.values.fold(0, (a, b) => b > a ? b : a);

  P2lLedConfig copyWith({
    int? brightness,
    Map<int, int>? ledCounts,
    Map<int, P2lColorSlot>? colors,
    DateTime? fetchedAt,
  }) => P2lLedConfig(
    brightness: brightness ?? this.brightness,
    ledCounts: ledCounts ?? this.ledCounts,
    colors: colors ?? this.colors,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );

  /// Parsuje odpověď na P2L `GET-CONFIG`. Klíče jsou ploché a s mezerou
  /// v názvu: `brightness`, `leds port0`…`leds port7`, `color0`…`color5`
  /// a `color2_0`…`color2_5` (hex bez `#`).
  ///
  /// Neznámé klíče se ignorují a chybějící se prostě nenaplní — firmware
  /// nemusí poslat všechno a přísnost by tu jen zahodila to, co dorazilo.
  factory P2lLedConfig.fromGetConfig(
    Map<String, dynamic> json, {
    DateTime? now,
  }) {
    final counts = <int, int>{};
    final primary = <int, int>{};
    final secondary = <int, int>{};

    for (final entry in json.entries) {
      final key = entry.key.trim();
      final value = entry.value;

      final ledsMatch = RegExp(
        r'^leds\s*port\s*(\d+)$',
        caseSensitive: false,
      ).firstMatch(key);
      if (ledsMatch != null) {
        final port = int.tryParse(ledsMatch.group(1)!);
        final count = _asInt(value);
        if (port != null && count != null) counts[port] = count;
        continue;
      }

      final color2Match = RegExp(
        r'^color2_(\d+)$',
        caseSensitive: false,
      ).firstMatch(key);
      if (color2Match != null) {
        final id = int.tryParse(color2Match.group(1)!);
        final rgb = _asRgb(value);
        if (id != null && rgb != null) secondary[id] = rgb;
        continue;
      }

      final colorMatch = RegExp(
        r'^color(\d+)$',
        caseSensitive: false,
      ).firstMatch(key);
      if (colorMatch != null) {
        final id = int.tryParse(colorMatch.group(1)!);
        final rgb = _asRgb(value);
        if (id != null && rgb != null) primary[id] = rgb;
        continue;
      }
    }

    final colors = <int, P2lColorSlot>{};
    for (final id in {...primary.keys, ...secondary.keys}) {
      final fallback = id >= 0 && id < kP2lDefaultColors.length
          ? kP2lDefaultColors[id]
          : const P2lColorSlot(0xFFFFFF, 0x000000);
      colors[id] = P2lColorSlot(
        primary[id] ?? fallback.rgb,
        secondary[id] ?? fallback.rgb2,
      );
    }

    return P2lLedConfig(
      brightness: _asInt(json['brightness']),
      ledCounts: counts,
      colors: colors,
      fetchedAt: now ?? DateTime.now(),
    );
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// Barva může přijít jako hex string (`"ff0000"`, `"#ff0000"`) i jako číslo.
  static int? _asRgb(dynamic v) {
    if (v is num) return v.toInt() & 0xFFFFFF;
    if (v is String) {
      final clean = v.trim().replaceFirst('#', '');
      if (clean.isEmpty) return null;
      final parsed = int.tryParse(clean, radix: 16);
      return parsed == null ? null : parsed & 0xFFFFFF;
    }
    return null;
  }
}
