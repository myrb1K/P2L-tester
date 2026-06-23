import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:p2l_tester/main.dart';
import 'package:p2l_tester/screens/splash_screen.dart';

void main() {
  testWidgets('Splash se zobrazí a přejde na další obrazovku', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SplashScreen(next: Scaffold(body: Text('HOTOVO'))),
      ),
    );

    // Splash je vidět hned na prvním snímku (vč. verze aplikace).
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.text('P2L Tester v$appVersion'), findsOneWidget);

    // Po doběhnutí splash timeru (1800 ms) + fade (300 ms) přejde dál.
    await tester.pumpAndSettle(const Duration(milliseconds: 2200));
    expect(find.text('HOTOVO'), findsOneWidget);
  });
}
