import 'dart:async' show unawaited;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/auth_gate.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/splash_screen.dart';
import 'services/auth_session.dart';
import 'services/local_server.dart';
import 'services/local_unit_db.dart';
import 'services/sync_engine.dart';
import 'services/unit_db_service.dart';

const String appVersion = '2.83';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Na nativu: nastartovat přiložený lokální server (portable EXE) a teprve
  // pak obnovit session. Fire-and-forget — nesmí zdržet start appky.
  // Web session řeší AuthGate přes cookie a server je na hostu.
  if (!kIsWeb) unawaited(_bootstrapNative());
  runApp(const P2LTesterApp());
}

/// Start lokálního serveru + obnova auth session.
///
/// Pořadí je podstatné: kdyby se `restore()` pustilo hned, běželo by proti
/// serveru, který ještě nenaběhl → stav „offline" a uživatel by musel klikat
/// na „Zkusit znovu". Proto se čeká na health lokálního serveru (jen když je
/// portable rozložení k dispozici a autostart je zapnutý) a až pak se ověřuje
/// session. Bez portable serveru se chování nemění — restore jde hned.
Future<void> _bootstrapNative() async {
  // Lokální DB jednotek (DB10) — otevřít dřív než cokoli jiného, aby první
  // zápisy z MQTT (ALIVE hned po připojení) měly kam padnout. Selhání se
  // nepropaguje: bez lokální DB jede evidence jen online jako do DB9.
  await LocalUnitDb.instance.init();

  final server = LocalServer.instance;
  await server.init();
  if (server.isAvailable && server.autostart) {
    // Server na sebe váže auth API — přesměrujeme na jeho port.
    AuthSession.instance.preferLocalBase(server.baseUrl);
    await server.maybeAutostart();
  }
  await AuthSession.instance.restore();

  // Synchronizace lokální DB se serverem (DB11) — až po restore session, aby
  // první kolo mělo platný token. Engine si zapojí notifikaci o lokálních
  // zápisech (callback, ne import, kvůli cyklu) a rozjede periodické kolo.
  UnitDbService.instance.onLocalChange = SyncEngine.instance.notifyLocalChange;
  unawaited(SyncEngine.instance.start());
}

class P2LTesterApp extends StatefulWidget {
  const P2LTesterApp({super.key});

  @override
  State<P2LTesterApp> createState() => _P2LTesterAppState();
}

class _P2LTesterAppState extends State<P2LTesterApp> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // Zavření okna → ukončit server, který jsme spustili. Cizí (adoptovaný)
    // proces si LocalServer.stop() nechá běžet.
    if (!kIsWeb) {
      _lifecycle = AppLifecycleListener(
        onExitRequested: () async {
          await LocalServer.instance.stop();
          return AppExitResponse.exit;
        },
      );
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

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
        // Na webu obalíme celý Navigator AuthGate-em přes builder.
        // Důvod: _AuthScope musí být ABOVE MaterialApp.Navigator, aby ho
        // viděly i pushnuté routy (Settings → AdminUsersScreen). Kdyby byl
        // uvnitř jedné route (jako home child), inherited widget by byl
        // sourozeneckým routám neviditelný.
        // Na nativu (APK/EXE) builder = null → pass-through.
        builder: kIsWeb
            ? (context, child) =>
                AuthGate(child: child ?? const SizedBox.shrink())
            : null,
        // Na webu přeskakujeme splash (branding má LoginScreen), aby se po
        // každém přihlášení nezobrazovala 2s splash animace. Na nativu
        // (APK/EXE) splash zůstává — Android 12+ má jen kruhovou ikonku,
        // Flutter splash dává plné logo.
        home: kIsWeb
            ? const _InitialRoute()
            : const SplashScreen(next: _InitialRoute()),
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
