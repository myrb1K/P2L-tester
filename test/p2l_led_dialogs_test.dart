import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:p2l_tester/providers/app_state.dart';
import 'package:p2l_tester/widgets/p2l_led_dialogs.dart';

/// Barva rozsvěcovací (levé) půlky vypínače portu.
Color? _portColor(WidgetTester tester, int port) {
  final box = tester.widget<ColoredBox>(
    find
        .descendant(
          of: find.byKey(ValueKey('p2l-port-$port-on')),
          matching: find.byType(ColoredBox),
        )
        .first,
  );
  return box.color;
}

/// Klepne na rozsvěcovací půlku portu.
Future<void> _lightPort(WidgetTester tester, int port) async {
  await tester.tap(find.byKey(ValueKey('p2l-port-$port-on')));
  await tester.pumpAndSettle();
}

/// Klepne na zhasínací půlku portu.
Future<void> _clearPort(WidgetTester tester, int port) async {
  await tester.tap(find.byKey(ValueKey('p2l-port-$port-off')));
  await tester.pumpAndSettle();
}

Widget _wrap(Widget child) => ChangeNotifierProvider(
  create: (_) => AppState(),
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  testWidgets('Ovládání: pole, porty a primární tlačítko', (tester) async {
    await tester.pumpWidget(_wrap(const P2lControlDialog(unitId: '001209')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // Titulek je na jednom řádku: název akce a vedle ID bez vodicích nul.
    expect(find.text('Ovládání P2L LED'), findsOneWidget);
    expect(find.text('1209'), findsOneWidget);

    // Čtyři vstupy podle zadání.
    expect(find.text('LED od'), findsOneWidget);
    expect(find.text('LED do'), findsOneWidget);
    // Výchozí rozsah je krátký, ať test nezatěžuje celý pásek.
    expect(find.text('59'), findsOneWidget);
    expect(find.text('Barva'), findsOneWidget);
    expect(find.text('Styl svícení'), findsOneWidget);

    // Porty 0–7.
    for (int p = 0; p < 8; p++) {
      expect(find.text('$p'), findsWidgets);
    }
    expect(find.text('Rozsvítit vše'), findsOneWidget);
  });

  testWidgets('Vypínač: tlačítko portu rozsvítí, pruh pod ním zhasne', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const P2lControlDialog(unitId: '001209')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Klepnutím na port rozsvítíš zadaný rozsah, pruhem pod ním zhasneš.',
      ),
      findsOneWidget,
    );

    // Port se rozsvítí hned, bez potvrzovacího tlačítka.
    await _lightPort(tester, 3);
    expect(find.textContaining('Svítí 1 z 8 portů.'), findsOneWidget);
    // Jakmile něco svítí, primární tlačítko nabízí zhasnutí.
    expect(find.text('Zhasnout vše'), findsOneWidget);

    // Opakované klepnutí vlevo port NEzhasne — přidává další rozsah.
    await _lightPort(tester, 3);
    expect(find.textContaining('Svítí 1 z 8 portů.'), findsOneWidget);
    expect(find.text('Zhasnout vše'), findsOneWidget);

    // Zhasne až pravá půlka.
    await _clearPort(tester, 3);
    expect(
      find.text(
        'Klepnutím na port rozsvítíš zadaný rozsah, pruhem pod ním zhasneš.',
      ),
      findsOneWidget,
    );
    expect(find.text('Rozsvítit vše'), findsOneWidget);
  });

  testWidgets('„Rozsvítit vše" rozsvítí všechny porty a přepne se', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const P2lControlDialog(unitId: '001209')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rozsvítit vše'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Svítí 8 z 8 portů.'), findsOneWidget);
    expect(find.text('Zhasnout vše'), findsOneWidget);
    expect(find.text('Rozsvítit vše'), findsNothing);

    // Druhý stisk zhasne všechno a vrátí tlačítko zpět.
    await tester.tap(find.text('Zhasnout vše'));
    await tester.pumpAndSettle();
    expect(find.text('Rozsvítit vše'), findsOneWidget);
  });

  testWidgets('Port si drží barvu, kterou byl rozsvícen', (tester) async {
    await tester.pumpWidget(_wrap(const P2lControlDialog(unitId: '001209')));
    await tester.pumpAndSettle();

    // Port 0 rozsvítíme výchozí barvou 0 (tovární RED).
    await _lightPort(tester, 0);
    expect(_portColor(tester, 0), const Color(0xFFFF0000));

    // Přepneme barvu na 2 (tovární BLUE) a rozsvítíme port 1.
    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('BLUE').last);
    await tester.pumpAndSettle();
    await _lightPort(tester, 1);

    // Port 1 má novou barvu, port 0 zůstává v té, kterou fyzicky svítí.
    expect(_portColor(tester, 1), const Color(0xFF0000FF));
    expect(_portColor(tester, 0), const Color(0xFFFF0000));
  });

  testWidgets('Jas: výchozí hodnota a poznámka u staršího firmwaru', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const P2lBrightnessDialog(unitId: '001209')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Jas P2L LED'), findsOneWidget);
    expect(find.text('50 %'), findsOneWidget);
    expect(find.textContaining('Jednotka jas nehlásí'), findsOneWidget);
  });

  testWidgets('Počet LED: řádek na každý port', (tester) async {
    await tester.pumpWidget(_wrap(const P2lLedCountDialog(unitId: '001209')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (int p = 0; p < 8; p++) {
      expect(find.text('Port $p'), findsOneWidget);
    }
  });

  testWidgets('Barvy: deset slotů s tovární hodnotou', (tester) async {
    await tester.pumpWidget(_wrap(const P2lColorsDialog(unitId: '001209')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('RED'), findsOneWidget);
    expect(find.text('WHITE'), findsOneWidget);
    // Tovární RED = ff0000, jeho color2 = 00ff00.
    expect(find.text('ff0000'), findsWidgets);
    expect(find.text('00ff00'), findsWidgets);
    // Jednotka hlásí color0–color9; sloty 6–9 jsou černé a bez tovární barvy.
    expect(find.text('volná'), findsNWidgets(3));
    expect(find.text('černá — testovací vzor'), findsOneWidget);
  });

  testWidgets(
    'Sekce P2L: jeden chip s ID jednotky a menu se čtyřmi položkami',
    (tester) async {
      await tester.pumpWidget(_wrap(const P2lLedSection(unitId: '001209')));
      await tester.pumpAndSettle();

      expect(find.text('P2L  1x'), findsOneWidget);
      expect(find.text('1209'), findsOneWidget);

      await tester.tap(find.text('1209'));
      await tester.pumpAndSettle();

      expect(find.text('Ovládání'), findsOneWidget);
      expect(find.text('Jas P2L LED'), findsOneWidget);
      expect(find.text('Počet P2L LED'), findsOneWidget);
      expect(find.text('Barvy P2L LED'), findsOneWidget);
    },
  );
}
