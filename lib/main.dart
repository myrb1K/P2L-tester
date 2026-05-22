import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/splash_screen.dart';

const String appVersion = '2.66';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const P2LTesterApp());
}

class P2LTesterApp extends StatelessWidget {
  const P2LTesterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadSettings(),
      child: MaterialApp(
        title: 'P2L Tester',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        themeMode: ThemeMode.light,
        home: const SplashScreen(next: _InitialRoute()),
      ),
    );
  }
}

class _InitialRoute extends StatelessWidget {
  const _InitialRoute();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        if (state.broker.isEmpty) {
          return const SettingsScreen();
        }
        return const HomeScreen();
      },
    );
  }
}
