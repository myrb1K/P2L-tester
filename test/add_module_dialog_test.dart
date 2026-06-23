import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:p2l_tester/widgets/add_module_dialog.dart';

void main() {
  testWidgets('Výběr tlačítek PUM-A se vykreslí bez layout chyby', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AddModuleDialog()),
      ),
    );
    await tester.pumpAndSettle();

    // Žádná layout výjimka (dřív "BoxConstraints forces an infinite height").
    expect(tester.takeException(), isNull);

    // Displej uprostřed + všechny 4 pozice tlačítek.
    expect(find.text('DISPLEJ'), findsOneWidget);
    expect(find.text('levé-vlevo'), findsOneWidget);
    expect(find.text('levé-vpravo'), findsOneWidget);
    expect(find.text('pravé-vlevo'), findsOneWidget);
    expect(find.text('pravé-vpravo'), findsOneWidget);

    // Default adresa 128 → 4-ciferné adresy tlačítek 3128/1128/0128/2128.
    expect(find.text('3128'), findsOneWidget);
    expect(find.text('1128'), findsOneWidget);
    expect(find.text('0128'), findsOneWidget);
    expect(find.text('2128'), findsOneWidget);
  });

  testWidgets('Toggle tlačítka přidá/odebere bez chyby', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AddModuleDialog()),
      ),
    );
    await tester.pumpAndSettle();

    // Klepnutí na dlaždici „pravé-vpravo" (tl. 2) ji přepne.
    await tester.tap(find.text('pravé-vpravo'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
