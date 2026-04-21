import 'package:flutter_test/flutter_test.dart';

import 'package:p2l_tester/main.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const P2LTesterApp());
    expect(find.text('Nastaveni MQTT'), findsOneWidget);
  });
}
