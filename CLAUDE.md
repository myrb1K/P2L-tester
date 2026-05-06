# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Uživatel a styl komunikace

**Radek** (`r.brym@smartbox4you.com`) — autor a údržbář P2L Testeru, používá appku interně ve firmě Smart Product Solution / Smartbox4you. Pracuje na Windows 11 v Cursoru s rozšířením Claude Code (doma stroj uživatel `Brno`, v práci jiný — projekt cestuje přes git).

**Komunikace:** **česky**. UI texty, commit messages, doc komentáře — vše česky. Terminologie: "P2L modul" = jednotka, "modul" = PUM-A/B/C/DIST na sběrnici.

**Styl práce:** krátké, prakticky zaměřené úkoly. Nechce extra polishing nad rámec zadání. Itruje postupně po malých commitech. Zná hardware (ESP32 firmware P2L_*NT) a MQTT protokol; Flutter zřejmě není hlavní expertíza, takže Flutter-specific patterns dobře vysvětlit.

## Project Overview

**P2L Tester** is a Flutter application for testing P2L hardware modules via MQTT communication. The app connects to a broker to control LED modules and perform diagnostics on physical units. Version is tracked in `main.dart` as `appVersion = '2.X'`.

## Architecture

### State Management
- **Provider pattern** with `ChangeNotifier` for reactive state
- Main state holder: `AppState` (`providers/app_state.dart`)
- Profiles stored in `SharedPreferences` (broker settings, LED patterns, device templates)

### Core Services
- **MqttService** (`services/mqtt_service.dart`): Wraps mqtt_client, manages connection state, publishes/subscribes to topics
- **CommandService** (`services/command_service.dart`): Builds command payloads for old/new units (JSON and BIN formats)
- **ModuleReconstruction** (`services/module_reconstruction.dart`): Reconstructs PUMA module config from hardware responses

### Data Models
- **P2LUnit** (`models/unit.dart`): Represents a P2L hardware unit
- **PumaModule** (`models/module.dart`): Physical module types (PUM-A, PUM-B, PUM-C, DIST) with config
- **DeviceTemplate** (`models/device_template.dart`): Named hardware configs for quick reuse
- **BrokerProfile** (`models/broker_profile.dart`): Named broker connection presets

### UI Structure
- **HomeScreen**: Main list of units with test controls and live status. AppBar contains `BulkConfigMenu` (ikona `Icons.settings_remote`) pro hromadnou změnu brokera/WiFi na vybraných jednotkách.
- **SettingsScreen**: Broker profiles (s přetahováním pořadí přes `ReorderableListView`), LED pattern config, device templates
- **UnitDetailScreen**: In-depth unit info (IP, MAC, firmware, module details)
- **TemplateEditorScreen**: Create/edit device template configurations
- **BulkConfigMenu** (`widgets/bulk_config_menu.dart`): PopupMenu v AppBar → dialogy pro hromadný `set_Mqtt` / `set_WiFi` na vybrané jednotky s 100ms pauzou mezi publishi. Dialog brokera umí buď vybrat uložený profil (bez aktuálního) nebo zadat nový, který se zároveň uloží.

### MQTT Protocol
Topics and message formats documented in `MQTT-TOPICS.md` and `README-P2L.md`. Key points:
- Subscribe to `D/+/UNIT/+/ALIVE` for automatic unit discovery
- Subscribe to `A/SERVER/+/CMD` for unit detail responses
- Publish test commands to `I/<unit_id>/P2L/<device_id>/CMD` (new units) or `I/u<4digit>/SERVER/CMD` (old units)
- Unit responses on topics with prefixes: D (discovery), A (async replies), L (logs)

---

## Common Development Tasks

### Build and Run
```bash
flutter pub get           # Install dependencies
flutter run -d windows    # Run on Windows
flutter run -d <device>   # Run on connected device or emulator
```

### Analyze and Format
```bash
flutter analyze                    # Lint check (configured in analysis_options.yaml)
dart format lib/                   # Auto-format Dart files
dart fix --apply                   # Apply suggested fixes
```

### Testing
```bash
flutter test                       # Run all tests
flutter test test/widget_test.dart # Run specific test file
flutter test --coverage            # Generate coverage report
```

### Build Distributions
```bash
flutter build windows --release                    # Windows exe
flutter build apk --release --split-per-abi        # Android APK (3× smaller per ABI)
flutter build ipa --release                        # iOS app
```

**Pro dist v `dist/P2L-Tester-vX.YY/` shippovat pouze `arm64-v8a` APK** (~17 MB pokrývá ~95 % moderních Android zařízení):
```bash
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk dist/P2L-Tester-vX.YY/P2L-Tester-vX.YY.apk
```
Default `flutter build apk --release` (bez `--split-per-abi`) vytvoří fat APK ~51 MB se třemi ABI v jednom — to je nad GitHub doporučenou hranicí 50 MB (push warning, navrhuje LFS). App Bundle (`flutter build appbundle`) je jen pro Play Store, sideload nepodporuje.

---

## Build Gotchas

### Flutter Windows: chybějící `cpp_client_wrapper/*.cc`

**Symptom:** Po `flutter build windows --release` (zvlášť po několika v řadě, např. dist pro v2.53 + v2.54) selže následný `flutter run -d windows` s:
```
error C1083: Nejde otevřít soubor zdroj: ...\windows\flutter\ephemeral\cpp_client_wrapper\core_implementations.cc
```
Adresář `windows/flutter/ephemeral/cpp_client_wrapper/` zůstane jen s `include/`, `.cc` soubory chybí.

**Why:** Flutter tool kopíruje `cpp_client_wrapper/*.cc` z SDK template **lazy** — jen když je adresář prázdný nebo při full `flutter build`. Po release buildu zůstane `generated_config.cmake` (marker), takže Flutter považuje ephemeral za "OK" a kopírování přeskočí. Mix release → debug rozladí CMake cache v `build/`. `flutter pub get` ephemeral neobnovuje (kopírování dělá jen build).

**Fix:**
```bash
flutter clean
flutter pub get
flutter build windows --debug    # regeneruje ephemeral
flutter run -d windows           # teprve teď
```

Není to bug v naší codebase a nesouvisí to s `dependency_overrides` (path_provider_foundation 2.5.1 / win32 5.5.4 jsou správně).

### Android release APK potřebuje INTERNET permission v `main/AndroidManifest.xml`

**Symptom:** `flutter build apk --release` projde, ale po instalaci APK na fyzické Android zařízení selžou všechna síťová volání. `mqtt_client` typicky vyhodí null exception, kterou aplikace zobrazí jako "null" chybu. `flutter run` nebo debug APK funguje normálně.

**Why:** Defaultní Flutter projekt má `<uses-permission android:name="android.permission.INTERNET"/>` jen v `android/app/src/debug/AndroidManifest.xml` (kvůli hot reload), nikoli v `main/`. Release build pak permission nemá. Vyřešeno v rámci v2.38 hotfix (commit `57b2f84`).

**How to apply:** Při Android release buildu vždy ověřit, že `android/app/src/main/AndroidManifest.xml` obsahuje:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
Uvnitř `<manifest>` ale mimo `<application>`.

### Cursor: `.cursorignore` rozbije Claude Code rozšíření

**Symptom:** Po restartu Cursoru se v projektu P2L-TESTER nenačte Claude Code rozšíření ani terminál.

**Why:** Když `.cursorignore` obsahuje `.git`, `*.lock` (nebo jiné runtime metadata), Cursor / rozšíření ztratí přístup k souborům potřebným pro inicializaci extension hostu.

**How to apply:** Pokud uživatel hlásí, že rozšíření po restartu Cursoru nenaběhne, první kontrola je `.cursorignore` — nesmí obsahovat `.git` ani `*.lock`. Bezpečné vzorce jsou jen build artefakty (`build/`, `.dart_tool/`, `*/ephemeral/`, `android/.gradle/`, `android/app/build/`, `coverage/`).

---

## Key Implementation Details

### LED Test Pattern
- Controlled via `ledsOn` (duration on), `ledsOff` (duration off), `ledColor` (0-5 for different colors)
- Pattern applies to all selected ports: `selectedPorts` (Set<int>)
- Saved to SharedPreferences for persistence

### Unit Discovery
- Units are discovered automatically when they broadcast ALIVE messages to `D/+/UNIT/+/ALIVE`
- Payload contains HWModel, firmware version, battery level
- Unit ID normalized: leading 'u' prefix is optional in code, always stored without it

### Device Templates
- Pre-configured module layouts (PUMA layout) for different hardware variants
- Stored as JSON in SharedPreferences under `device_templates` key
- Used to populate unit configuration dialogs without manual setup

### Command Formats
- **Old units** (ID < 1000): JSON only, topic `I/u{4digit}/SERVER/CMD`
- **New units** (ID ≥ 1000): Both JSON and BIN formats supported, topic `I/{6digit}/P2L/{device_id}/CMD`
- Binary format handled by CommandService for firmware >= P2L_25092501NT
- See `command_service.dart` for full encoding logic
- **Config builders**: `buildSetMqttCommand` a `buildSetWifiCommand` generují JSON payloady pro hromadnou změnu brokera/WiFi (používané z `AppState.sendBulkBroker/sendBulkWifi`)

### Broker Profiles
- Uloženy v `SharedPreferences` pod klíčem `broker_profiles`, aktivní index pod `active_profile`.
- Duplicitní názvy nejsou povoleny — kontrolováno přes `AppState.isProfileNameTaken(name, {excludeIndex})` (case-insensitive, trim).
- `addProfile`, `addProfileWithoutActivating` a `updateProfile` vrací `Future<String?>` (`null` = OK, jinak chybová zpráva).
- `addProfileWithoutActivating` uloží profil, ale nepřepne aktivní připojení — používá se při hromadné změně brokera, kdy uživatel zadá nový broker pro vybrané moduly, ale aplikace má zůstat na aktuálním.
- `reorderProfiles(oldIndex, newIndex)` přesouvá profily a přepočítává `_activeProfileIndex` tak, aby dál ukazoval na stejný profil.

### Error Handling
- MQTT errors stored in `_lastError` and exposed via AppState
- Connection state tracked via `AppMqttState` enum (disconnected, connecting, connected, error)
- Status messages updated in `_statusMessage` for UI feedback

---

## Testing Notes

- **Unit tests** check command serialization (`command_service_devices_test.dart`, `module_reconstruction_test.dart`)
- **Widget tests** verify UI interactions
- Run tests after changes to command format or module parsing logic

---

## Version and Recent Changes

Current version: **2.58** (see `main.dart`)  
Recent themes:
- v2.58: Terminologie a UI sjednocení — "P2L modul" (hardware jednotka), "device"/"devices" (jednotlivé čipy na sběrnici), "entita"/"entit" (záznamy). Změny: všechny "modul/modulů/moduly" pro čipy přejmenováno na "device/devices"; UI texty "čipů" → "entit"; template editor ukazuje "Devices: N / M entit" (N = počet modulů, M = počet všech atomických entries); export/import šablon v UnitDetailScreen (ikony file_download/upload); ID normalizace v UI (001209 → 1209). Audit všech status messages v app_state.dart.
- v2.57: Nový formát export/import šablon (TemplateBundle v2) — moduly se shodnou konfigurací se sloučí do jednoho záznamu s CSV `baseAddresses` (`"128,130,134"`) místo jednotlivých `baseAddress` intů. Import expanduje CSV → vytvoří jednotlivé moduly → seřadí podle adresy. Staré v1 soubory jsou odmítnuty s přátelskou zprávou. Validace duplikátních adres během importu. Nové testy v [test/template_io_test.dart](test/template_io_test.dart).
- v2.56: UI sjednocení — ikona výběru brokeru v `HomeScreen` AppBaru přepsána z `Icons.swap_horiz` na `Icons.dns_outlined` (konzistence s `BulkConfigMenu` a settings, outlined varianta). Port toggle "Vše/Zrušit" v LED ovládací liště přepsán z outline `Container` na `FilledButton` se `StadiumBorder` a `minimumSize: Size(0, 28)`, aby barevně odpovídal `FilledButton`u "Ověřit" (M3 primary, ne `Colors.blue`) a výškově sedl s 28×28 port boxy. Window title nativního Win32 okna v [windows/runner/main.cpp:30](windows/runner/main.cpp#L30) změněn z `"p2l_tester"` na `"P2L Tester"` (Flutter title z `MaterialApp.title` se na Windows automaticky nesynchronizuje, je hardcoded v `window.Create`).
- v2.55: Fix klikací oblasti ikony "Seznam zařízení" v `_UnitCard` — `Badge` (kolečko s počtem modulů) pohlcoval tap eventy ve své části nad ikonou. Přepsáno na `Stack` s `IconButton` jako tap target a `Badge` v `IgnorePointer` přes `SizedBox(32×32)` jako čistě vizuální overlay. Hit area je teď u všech tří ikon v řádku (Seznam, Info, Obnovit) plnohodnotných 32×32.
- v2.54: Wave animace se spouští znovu i po offline → online cyklu, kdy uživatel mezi tím odscrolloval kartu pryč. `AppState._wavedUnitIds` se odebírá při přechodu online → offline (jak v `_markUnitOfflineUntilAlive`, tak v tick timeru po překročení lastSeen threshold), takže další ALIVE animaci zase pustí.
- v2.53: Modrá vlna animace v seznamu jednotek na `HomeScreen` při prvním objevení jednotky (ALIVE / manuální zadání ID) a při přechodu offline → online (včetně po restartu jednotky). Implementace v [`home_screen.dart`](lib/screens/home_screen.dart) — `_UnitCard` jako `StatefulWidget` s `SingleTickerProviderStateMixin`, `AnimationController` 1300 ms, `Curves.easeInOut`. Vlna je `Positioned.fill` overlay nad `InkWell` v `Stack`, gradient pruh širokým ~35 % šířky karty (`Colors.lightBlueAccent` alpha 220) s `BoxShadow` glow (alpha 110, blur 18, spread 2). `ListView.builder` ničí off-screen karty → tracking "už animováno" je v `AppState._wavedUnitIds` (`consumeFirstAppearAnimation` / `markUnitWaved`), aby se animace nezopakovala při scrolování. `P2LUnit.isOnline` je mutable pole — proto se v `_UnitCardState` drží `_lastOnline` lokálně místo srovnávání `oldWidget.unit.isOnline`. `_UnitListView` předává `key: ValueKey(unit.id)`.
- v2.52: Export / Import šablon — ikony `file_download_outlined` / `file_upload_outlined` v AppBar `TemplatesScreen` (export jen pokud existují šablony) + položka "Exportovat" v PopupMenu řádku. Formát: JSON wrapper `{"format":"p2l-tester.templates","version":1,"exportedAt","appVersion","templates":[...]}` v `lib/services/template_io.dart` (`TemplateBundle.encode/decode`). Při exportu jedné šablony rovnou dialog "Sdílet (`share_plus`) / Uložit (`file_picker.saveFile`)". Při exportu z AppBaru s více šablonami nejdřív checkbox dialog. Import řeší konflikty jmen dialogem `Přepsat / Přejmenovat (auto suffix `(2)`) / Přeskočit` s "Použít pro zbývajících N". Helpery v `AppState`: `hasTemplate(name)`, `suggestUniqueTemplateName(base)`. Závislosti: `share_plus ^10.1.2`, `path_provider ^2.1.4` (temp file pro share). **Pin `path_provider_foundation: 2.5.1` v `dependency_overrides`** — verze 2.6.0 zavedla Dart native build hooks přes `objective_c`, které Flutter tool spouští i na Windows a crashuje na mezerách v cestě k user profilu (`C:\Users\Radek Brym\…`).
- v2.51: Flutter `SplashScreen` widget s plným Smartbox logem (1.8–2.2 s, fade transition); kompaktnější ikony v seznamu profilů (`visualDensity.compact`, `minWidth: 36`); dialog Aplikovat šablonu zjednodušený (jen `displayName`, tučně, `ListView.separated` s `Divider`, `Icon(device_hub) + Badge` s počtem modulů).
- v2.50: `Listener` na úrovni `Scaffold` v `HomeScreen` → `FocusManager.primaryFocus.unfocus()` na `onPointerDown`, takže klepnutí na libovolné tlačítko/ikonu skryje klávesnici a zruší focus pole pro ID.
- v2.49: tap-mimo skryje klávesnici, fix klávesnice po Restart akci.
- v2.48: po restartu jednotky čítač zamrzne na "offline" do návratu ALIVE.

**Pozor — nezvedat `appVersion` automaticky.** Po code změnách na něj nesahat; verzi řeší až commit, a to **až poté, co se uživatele zeptám**, jestli má být nová verze (a jaká). Někdy je změna jen WIP / experiment / refactor, kdy se verze nemění. Toto pravidlo přepisuje starší pokyn "Always increment".

## Splash Screen
- `lib/screens/splash_screen.dart` — Flutter splash s `Image.asset('assets/icons/Smartboxlogo.png')` na bílém pozadí, dole verze aplikace.
- Asset registrovaný v `pubspec.yaml` (`flutter.assets`).
- Délka zobrazení: 2200 ms, pak `Navigator.pushReplacement` s `FadeTransition` 300 ms na `_InitialRoute`.
- Důvod: nativní Android 12+ splash zobrazuje jen kruhovou ikonu uprostřed (oříznuté logo), Flutter splash dává plnou kontrolu na všech platformách.
