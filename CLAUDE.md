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

#### Device topic kódy (P2L32)
DEVICE_ID v topicu je **2-ciferný kód typu + 4-ciferná adresa** (např. `050246` = DISP @246).

| Kód | Typ |
|-----|-----|
| `00` | UNIT (jednotka samotná) |
| `01` | P2L (LED pásky / test příkazy) |
| `04` | DIST (senzor vzdálenosti) |
| `05` | DISP (PUM-A displej) |
| `06` | BTN (tlačítko rodiny PUMA) |
| `11` | LEDS (PUMA LED) |

**DISP a BTN jsou obě z rodiny PUMA, ale mají vlastní prefix:** DISP `05`, BTN `06` (potvrzeno firmwarem — BTN ALIVE topicy `D/<unit>/BTN/06<addr>/ALIVE`). Konkrétní typ rozlišuje i textový segment topicu (`/DISP/` vs `/BTN/`). Zdroj: [`DeviceTypeExt.addressPrefix`](lib/models/device.dart) — používá se pro adresné device příkazy (SET-DATA, SET-CONFIG, SET-LEDS atd.). **Pozn.:** výměna a přečíslování device už device-topic nepoužívají — nový FW je řeší UNIT-level příkazy (viz níže).

#### Subscribe topicy po connectu
- `D/+/UNIT/+/ALIVE` — discovery + battery/firmware
- `A/SERVER/+/CMD` — odpověď na `get_param` (IP, MAC, firmware, ID)
- `O/+/UNIT/+/GET-DEVICES` — seznam atomických devices (P2L32)
- `O/+/UNIT/+/{ADD,RECREATE,DELETE}-DEVICES` — potvrzení device-management operací
- `O/+/UNIT/+/DEVICE-REPLACE` — potvrzení výměny vadného device (nový FW)
- `O/+/UNIT/+/DEVICE-SET-ID` — potvrzení přečíslování device (nový FW)

---

## Hardware topologie a PUMA moduly

**RS485 daisy-chain.** P2L jednotka komunikuje s devices přes jednu sběrnici v sérii. Adresace je podle **chip number** (vypálené v čipu), ne podle fyzické pozice. Pozice v řetězci **z `GET-DEVICES` zjistitelná není** — protokol pracuje jen s čipy. Kapacita: **max 100 čipů na jednotku**.

**1 modul = 1 fyzický čip.** Čip může v `GET-DEVICES` reportovat víc atomických entries (BTN/DISP/LEDS) podle své role. Pojem "modul" je rekonstruovaný čistě v aplikaci — protokol zná jen atomické typy.

### Moduly

| Modul | Popis | Samostatně? | Čipů | MQTT entries | Factory default |
|-------|-------|-------------|------|--------------|-----------------|
| **PUM-A** @N | displej + 0/1/2 tlačítka + volit. LEDS | ano | 1 | DISP `N` + volit. LEDS `N`; tlačítka viz níže | **246** (DISP) |
| **PUM-B** @N | samostatné tlačítko + volit. LEDS | ano | 1 | BTN `N` (bez prefixu) + volit. LEDS `N` | **247** (BTN) |
| **PUM-C** @M | vždy 2 tlačítka (+/−), jen jako doplněk PUM-A bez 2 tlačítek | NE | 1 | BTN `1000+M` (+), BTN `M` (−) | **247** (BTN) |
| **DIST** @N | senzor vzdálenosti | ano | 1 | DIST `N` s konfigurací | **127** |

**Factory default** = adresa, kterou má čip z výroby před přečipováním. Po fyzické výměně vadného kusu aplikace pošle `DEVICE-REPLACE` s touto default adresou v poli `From` a adresou vadného kusu v poli `To` → jednotka přečipuje nový kus na ID původního. Autoritativní zdroj: [`CommandService.defaultReplacementAddress`](lib/services/command_service.dart).

### PUM-A tlačítka

| Počet | MQTT BTN entries |
|-------|------------------|
| 0 | žádné |
| 1 | BTN `N` (pravé) **nebo** BTN `1000+N` (levé) — strana se ukládá v `buttonSide` |
| 2 | BTN `1000+N` (levé) + BTN `N` (pravé) |

Pravé tlačítko je vždy bez prefixu (holé `N`), levé je s `1000+`. Žádný `2000+N` se nepoužívá. Autoritativní zdroj: [`module_reconstruction.dart`](lib/services/module_reconstruction.dart) a `PumaModule.toDevices()` v [`module.dart`](lib/models/module.dart).

### Klíčová pravidla rekonstrukce

- **PUM-B** a **PUM-C mínus** jsou oba holá `N` — rozlišit se dají jen tak, že PUM-C mínus má vždy párového brata `1000+N`.
- **LEDS** jsou fyzicky součástí PUM-A nebo PUM-B (volitelný LED kroužek na tlačítku). V `GET-DEVICES` se objeví jen pokud je jednotka "potřebuje znát" — registrace je volitelná. PUM-B s LEDS = BTN @N + LEDS @N (rekonstrukce: BTN bez DISP páru, LEDS na stejné adrese → PUM-B s LEDS).
- **DISP** vždy znamená PUM-A.
- **PUM-C** lze zapojit JEN k PUM-A, které má 0 nebo 1 tlačítko (PUM-C dodá chybějící). Kombinace PUM-A se 2 tlačítky + PUM-C vedle je neplatná.
- Adresy modulů jsou **nezávislé** — PUM-A na 128, PUM-C na 130 je validní.

### Algoritmus rekonstrukce z `GET-DEVICES`

1. Pro každý DISP `N`: vytvoř PUM-A @N. Podle přítomnosti BTN `1000+N` / BTN `N` urči 0/1/2 tlačítek a stranu. LEDS `N` → `hasLeds=true`.
2. Pro nezabrané dvojice (BTN `1000+M`, BTN `M`) bez DISP `M` → PUM-C @M.
3. Zbylé osamocené BTN `N` → PUM-B @N.
4. Každý DIST → samostatný DIST modul s konfigurací.

---

## Workflow výměny a přečíslování device (nový FW)

Nový FW (kolegův přepis, od v2.67) řeší obě operace **UNIT-level příkazy** na topicu `I/<unit>/UNIT/<unit>/<CMD>` s payloadem `{"From": <z>, "To": <na>}`. Typ device ani per-device topic se už neřeší — firmware přemapuje podle adres.

### DEVICE-REPLACE — výměna vadného kusu
- Vadný device se fyzicky vymění za nový s **factory default adresou** (= horní mez rozsahu daného modulu).
- Platné rozsahy adres podle **typu modulu** (default = horní mez), autoritativní zdroj [`ModuleTypeExt.addressRange`](lib/models/module.dart):
  - **PUM-A: 128–246** (default 246)
  - **PUM-B: 128–247** (default 247)
  - **PUM-C: 128–247** (default 247)
  - **DIST: 1–127** (default 127)
- Aplikace pošle `DEVICE-REPLACE` s `{"From": <default_nového>, "To": <adresa_vadného>}` → jednotka přečipuje nový na ID původního.
- LEDS se v UI samostatně nenabízí — vyměňují se s PUM-A / PUM-B jako celek.

### DEVICE-SET-ID — přečíslování existujícího device
- Změna adresy funkčního device na jinou: `{"From": <stará>, "To": <nová>}`.
- V UI: položka „Přečíslovat" v menu modulu (ikona `tag`), dostupná pro všechny typy modulů.
- Validace nové adresy podle rozsahu typu modulu (viz výše, `ModuleTypeExt.addressRange`) + kontrola kolize s obsazenou adresou.

### Společné
- **Firmware atomicky přemapuje všechny entries v rámci 1 fyzického čipu.** Pro PUM-A se přemapuje i LEDS @M (pokud osazené) a případná BTN tlačítka; pro PUM-B s LEDS i LEDS @M; pro PUM-C i sekundární BTN @1000+M. Aplikace tedy posílá **1 příkaz na modul**, ne víc. Ověřeno tracem: jeden `DEVICE-SET-ID` z 128 na 168 vyvolal ALIVE na `DISP/050168`, `LEDS/110168` i `BTN/06x168`.
- Odpověď chodí na zrcadlový topic `O/<unit>/UNIT/<unit>/<CMD>` s `{"Code":0,"Message":"OK"}`; po OK aplikace automaticky pošle `GET-DEVICES`.

V kódu: `AppState.replaceDevice(...)` → `CommandService.buildDeviceReplaceCommand(...)`, `AppState.setDeviceId(...)` → `CommandService.buildDeviceSetIdCommand(...)`. UI dialogy: [widgets/replace_device_dialog.dart](lib/widgets/replace_device_dialog.dart), [widgets/set_device_id_dialog.dart](lib/widgets/set_device_id_dialog.dart). Defaulty: [`CommandService.defaultReplacementAddress`](lib/services/command_service.dart).

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

**Pozn.:** Od commitu `e8fdc84` je `dist/` v `.gitignore` (build outputy nepatří do gitu). Adresář se používá lokálně pro packaging release artefaktů; pokud je potřeba je sdílet, jdou přes GitHub Releases, ne přes commit.

#### Distribuční zip (APK + EXE pohromadě)

Po buildu APK + EXE vždy sestavit **jeden** archiv `P2L-Tester-v<VER>.zip` (`<VER>` = `appVersion` z `main.dart`, např. `2.67`) s touto strukturou:

```
P2L-Tester-v<VER>.zip
├── P2L-Tester-v<VER>.apk          ← Android (arm64-v8a)
└── P2L-Tester-v<VER>/             ← Windows složka
    ├── p2l_tester v<VER>.exe       ← přejmenovaný z p2l_tester.exe (POZOR: mezera před v<VER>)
    ├── *.dll
    └── data/
```

- Windows složka `P2L-Tester-v<VER>/` obsahuje **celý obsah** `build\windows\x64\runner\Release\` (DLLs + `data\`) — jen `p2l_tester.exe` se přejmenuje na `p2l_tester v<VER>.exe` (s mezerou). Samotný exe se bez okolních DLL a `data\` nespustí, proto celá Release složka.
- APK uvnitř zipu: arm64-v8a, pojmenovaný `P2L-Tester-v<VER>.apk`.
- Zip se tvoří typicky do `dist/` (které je v `.gitignore`).

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

### DIST konfigurace
`DistConfig` ([models/module.dart](lib/models/module.dart)):

| Pole | Význam | Default |
|------|--------|---------|
| `measurePeriod` | perioda měření [ms] | 50 |
| `timeout` | timeout odpovědi [ms]; po vypršení ALIV hlásí poruchu | 10 |
| `countMeasures` | počet měření v `maxDeviation` pro stabilní hodnotu | 4 |
| `maxDeviation` | rozsah stabilního měření [mm] | 20 |
| `offset` | přičte se k naměřené hodnotě [mm] | 0 |
| `measureType` | 1=Short(<1m), 2=Middle(<2m), 3=Long(<3m) | 2 |

Volitelně `Segments` (segmentový režim) — zatím první iterace posílá prázdný seznam.

### AppState stavová logika
- **Auto-fetch:** první ALIVE jednotky v rámci připojení → automatický `GET-DEVICES` (`_initialFetchDone`).
- **Restart-after-config:** po `ADD-DEVICES`/`RECREATE-DEVICES` s `restartAfter=true` se pošle `RESTART`, pak se čeká na první ALIVE mimo grace window 2 s a teprve potom se znovu volá `GET-DEVICES` (`_pendingRestart`, `_awaitingAliveAfterRestart`, `_restartSentAt`, `_restartGrace`).
- **Fallback pro firmware bez `O/.../*-DEVICES` odpovědi:** po 200 ms od publish se vynutí `GET-DEVICES` (nebo restart, pokud je požadován).

### Command Formats
- **Old units** (ID < 1000): JSON only, topic `I/u{4digit}/SERVER/CMD`
- **New units** (ID ≥ 1000): Both JSON and BIN formats supported, topic `I/{6digit}/P2L/{device_id}/CMD`
- Binary format handled by CommandService for firmware >= P2L_25092501NT
- See `command_service.dart` for full encoding logic
- **Config builders**: `buildSetMqttCommand` a `buildSetWifiCommand` generují JSON payloady pro hromadnou změnu brokera/WiFi (používané z `AppState.sendBulkBroker/sendBulkWifi`)
- **Firmware OTA (`update` cmd)**: `buildUpdateCommand({fileName})` → payload `{"request_id":-1,"cmds":[{"cmd":"update","args":{"file_name":"<url>"}}]}`. Posílá se přes stejný topic jako ostatní config cmd: u staré gen `I/u<4>/SERVER/CMD`, u nové gen `I/<6>/P2L/01<4>/CMD` (přes `_topicFor()`). **Ověřeno**, že firmware nové generace `update` přijme na P2L topicu (ne UNIT), i když README-P2L-32.md ho nedokumentuje. Použito z `AppState.sendBulkFirmwareUpdate` (BulkConfigMenu → "Nahrát firmware").

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

## Deployment topology

Aplikace má 3 nasazovací scénáře:

1. **Cloud server + mobil na mobilních datech** — Nginx servíruje Flutter web build, `/ws` proxyuje na Mosquitto (TCP 1883 / WS 9001). Zákazník otevře `https://app.domena.cz`.
2. **On-premise server + mobil na Wi-Fi** — identické řešení lokálně, HTTPS volitelné (self-signed).
3. **Notebook jako dev server** — `flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0`, mobil i notebook na stejné Wi-Fi, firewall musí povolit port 8080.

**Pro web verzi:** broker musí mít povolený **WebSocket listener** (typicky port 9001 nebo 8083). Aplikace detekuje platformu a volí WS klienta místo TCP.

Detail v [README.md §Typy nasazení](README.md).

---

## Testing Notes

- **Unit tests** check command serialization (`command_service_devices_test.dart`, `module_reconstruction_test.dart`)
- **Widget tests** verify UI interactions
- Run tests after changes to command format or module parsing logic

---

## Version and Recent Changes

Current version: **2.72** (see `main.dart`)  
Recent themes:
- v2.72: **Diagnostika sběrnice (SCAN-DEVICES) + sledování zdraví devices.** (1) Read-only sken RS485 `SCAN-DEVICES` (FW ≥ `P2L_26061801NT`) v UnitDetailScreen — tlačítko `Icons.radar` → menu **Vše / PUM-X / SENZORY** (`BusScanScope`). Zjistí fyzicky připojené čipy bez zápisu do configu; odpověď je přímý JSON objekt `{"PUM-A":[…],"DIST":[…]}` (úspěch) nebo Code/Message (chyba). Model [bus_scan.dart](lib/models/bus_scan.dart) (`BusScanResult`, `diagnoseBus`), porovnání respektuje rozsah skenu (DIST sken nehlásí PUM jako chybějící). Timeout 45 s (sken trvá i přes 20 s). (2) **Výsledek inline v seznamu devices:** 🟢 normální = OK, 🔴 červený rámeček = v configu, ale na sběrnici chybí, ⬜ šedý ghost chip = na sběrnici, neuložený → klepnutím přidá (předvyplní typ+adresu; `AddModuleDialog` nově respektuje `suggestedAddress`+`suggestedType`). `PUM-X` (starší PUMA bez registru typu) jako samostatná šedá sekce. Souhrnný proužek nahoře. (3) **Sledování zdraví devices z ALIVE:** subscribe `D/+/{DIST,DISP,BTN,LEDS}/+/ALIVE` (dřív se odebíral jen UNIT!); `_handleDeviceAlive` — `Code:0` = OK, jinak porucha (`_unitDeviceFaults`). Porucha → **červená ikona „Seznam devices" na hlavní obrazovce + červený rámeček chipu v detailu** (sjednoceno s missing do `alertAddresses`/`alert`); zotavení (`Code:0`) barvu vrátí. (4) **Barevné chybové hlášky:** jednotný příznak `deviceActionIsError` přes `_setStatus`, červeně v detailu i v hlavním status baru (error override); pokrývá O/ odpovědi, chyby/timeout skenu i device ALIVE. (5) **Sken se zneplatní jen po potvrzeném úspěchu** device operace (`Code:0`) — při chybě/bez odpovědi se zachová, ať uživatel neskenuje znovu. (6) **Živá vzdálenost DIST:** subscribe `D/+/DIST/+/UPDATE`, `distanceFor` — DIST chip ukazuje pod adresou naměřené mm (menším písmem, pevná šířka 34 + tabulkové číslice, ať se buňky nepřekreslují). Ikona „Seznam devices" má počítadlo i barvu. Testy: nový [test/bus_scan_test.dart](test/bus_scan_test.dart) + SCAN-DEVICES v `command_service_devices_test.dart`.
- v2.71: **Fix hromadného jasu/textu displejů na novém FW (konec broadcastu DISP 0).** Nový FW odmítá broadcast na DISP adresu 0 (`050000` → `Code:-2 "unknown ID"`). `AppState.sendBulkBrightness` a `_bulkDisp` (AHOJ / smazat text na všech displejích v detailu) nově posílají SET-CONFIG/SET-DATA na **každou skutečnou DISP adresu zvlášť** (z posledního GET-DEVICES přes nový helper `_dispAddressesFor`) se 100ms pauzou; jednotky bez načtených devices se u jasu přeskočí (hláška). Docstringy/UI texty zbavené nepravdivého „broadcast (050000)". Drobnost: ikona „Vyčistit seznam" v HomeScreen AppBaru z `Icons.delete_sweep` na `Icons.cleaning_services`. Tlačítko „Nápověda" (`Icons.help_outline`) přesunuto z AppBaru HomeScreen do AppBaru Nastavení (vedle Export/Import). (Pozn.: jednotlivé per-display akce — Test displeje, Adresa na displej — fungovaly i dřív, rozbité byly jen „na všechny" přes adresu 0.)
- v2.70: **In-app nápověda (uživatelský návod).** Nový [docs/navod.md](docs/navod.md) — kompletní český návod ovládání (připojení, seznam jednotek, LED test, hromadná konfigurace, správa devices, šablony, výměna/přečíslování, export/import ID, nastavení, web). Registrován jako asset v `pubspec.yaml` (`docs/navod.md`). Zobrazuje se přímo v appce přes novou [lib/screens/help_screen.dart](lib/screens/help_screen.dart) (tlačítko `Icons.help_outline` „Nápověda" v AppBaru HomeScreen za Nastavením) — **jeden zdroj, dvě cesty** (GitHub + in-app). HelpScreen načítá markdown přes `rootBundle.loadString` a renderuje vlastním lehkým rendererem `_MarkdownView` (nadpisy `#`/`##`/`###`, odstavce, odrážky `- `, číslované `1.`, citace `> `, vodorovná čára `---`, GFM tabulky, inline `**tučné**` / `` `kód` ``) — **bez nové závislosti** (`flutter_markdown` je deprecovaný; obsah návodu řídíme sami, takže stačí podmnožina). Návod aktualizovat při změnách UI.
- v2.69: **UI úpravy hromadné konfigurace a HomeScreen.** Tlačítko mazání seznamu jednotek přejmenováno na „Vyčistit seznam" + ikona změněna na `Icons.delete_sweep`. V `BulkConfigMenu` přerovnáno pořadí položek (Změnit broker → Změnit WiFi → Jas P2L LED → Aktualizovat firmware → Restartovat P2L modul → dělící čára → Jas PUM-A → Aplikovat šablonu) a sjednoceny popisky: „Jas jednotky" → „Jas P2L LED", „Jas displejů" → „Jas PUM-A", „Nahrát firmware" → „Aktualizovat firmware", „Restart jednotek" → „Restartovat P2L modul". Jen UI texty/ikony/pořadí, žádná změna logiky.
- v2.68: **Fix WSS (secure WebSocket) na native + export do souboru na webu.** (1) `mqtt_client_factory_io.dart` nastavoval `secure = useSsl` i pro WebSocket — kombinace `secure=true` + `useWebSocket=true` rozbila připojení k `wss://` brokeru na Windows i Androidu (projevilo se jako „Chyba: null"). V mqtt_client je `secure` jen pro TCP (MQTTS); u WS řeší TLS schéma `wss://` v URL. Fix: `secure = useWebsocket ? false : useSsl`. Web nebyl dotčen (jiná factory). (2) Maskování chyby: `AppState.connect` bral `lastError` jen async přes `stateStream` (broadcast → microtask), takže UI čtená hned po `await` viděla starou hodnotu (null) — teď se chyba bere synchronně; `MqttService` navíc nikdy nevrátí prázdnou hlášku. (3) Export do souboru (nastavení/šablony/devices/ID) na webu předtím nedělal nic (web nemá nativní „Uložit jako", `File` z `dart:io` na webu neexistuje) — nový sdílený helper `saveTextFile` ([services/file_export.dart](lib/services/file_export.dart), conditional import jako mqtt factory): nativně dialog/SAF, na webu stažení přes blob. „Sdílet" na webu spadá na stažení.
- v2.67: **Nový FW protokol pro výměnu a přečíslování device — `DEVICE-REPLACE` + `DEVICE-SET-ID`.** Kolegův přepis FW nahradil per-device `REPLACE-FROM` UNIT-level příkazy na `I/<unit>/UNIT/<unit>/<CMD>` s payloadem `{"From": <z>, "To": <na>}`. `CommandService.buildReplaceFromCommand` → přejmenováno na `buildDeviceReplaceCommand` (From = factory default nového, To = adresa vadného); nový `buildDeviceSetIdCommand` pro přečíslování funkčního device. `AppState`: subscribe zrušeny tři `O/+/{DIST,DISP,BTN}/+/REPLACE-FROM`, nahrazeny `O/+/UNIT/+/DEVICE-REPLACE` a `O/+/UNIT/+/DEVICE-SET-ID`; `replaceDevice` mapuje From/To; nová metoda `setDeviceId(...)`. UI: nová akce „Přečíslovat" (ikona `tag`) v menu modulu + dialog [widgets/set_device_id_dialog.dart](lib/widgets/set_device_id_dialog.dart) (rozsah validace podle typu modulu — viz `ModuleTypeExt.addressRange` — + kontrola kolize). Ověřeno reálným tracem na unit 1209: `DEVICE-SET-ID {"From":128,"To":168}` atomicky přemapoval celý PUM-A čip (DISP+LEDS+BTN), odpověď `O/.../UNIT/.../DEVICE-SET-ID {"Code":0}`, poté auto `GET-DEVICES`. **Pouze nový formát** — staré FW s per-device REPLACE-FROM už appka neobsluhuje. Testy v `command_service_devices_test.dart` přepsány na nový formát. Zároveň opraven `DeviceTypeExt.addressPrefix` pro BTN z `05` na `06` (potvrzeno kolegou + reálným tracem — BTN má vlastní prefix, ne sdílený s DISP). Validace v obou dialozích: `SetDeviceIdDialog` i `ReplaceDeviceDialog` dostávají seznam obsazených adres a odmítnou cílovou/default adresu, která koliduje s jiným existujícím modulem nebo je shodná se zdrojovou (`ReplaceDeviceDialog` dříve nevalidoval nic). Rozsahy adres sjednoceny do `ModuleTypeExt.addressRange` (jeden zdroj pravdy pro `AddModuleDialog`, `SetDeviceIdDialog` i `ReplaceDeviceDialog`): **PUM-A 128–246, PUM-B/C 128–247, DIST 1–127** (default = horní mez). Oproti dřívějšku: dolní mez PUM* nově 128 (bylo 127), DIST nově 1–127 vč. defaultu 127 (bylo 1–126 s defaultem mimo rozsah). (Pozn.: README-P2L-32.md zatím popisuje starý protokol — čeká se na aktualizaci od kolegy.)
- v2.66: **MQTT přes WebSocket — volitelný flag v `BrokerProfile`.** Nová pole `useWebsocket: bool` a `wsPath: String` (default `/mqtt`) v [models/broker_profile.dart](lib/models/broker_profile.dart) + UI switch a path field v `SettingsScreen` profile editoru. `MqttService` používá conditional-import factory ([services/mqtt_client_factory.dart](lib/services/mqtt_client_factory.dart) → `_io.dart` / `_web.dart` / `_stub.dart`): native (`MqttServerClient` s `useWebSocket=true` + `websocketProtocols=['mqtt']`) i web (`MqttBrowserClient`) sdílí stejnou cestu. Klíčový fix: Mosquitto vyžaduje `Sec-WebSocket-Protocol: mqtt` v handshake, bez něj spojení padne s "Connection closed before handshake response" — `MqttClientConstants.protocolsSingleDefault` to nastaví. APK/EXE existující profily s `useWebsocket=false` (default) jedou TCP přesně jako dřív (backwards compatible). Užitečné pro zákazníky za firewallem co blokuje 1883, nebo když broker poslouchá jen na 443/WSS. Lokální dev s Mosquitto WS listenerem viz [.dev/README.md](.dev/README.md). Branding `web/index.html` + `web/manifest.json` srovnán pod "P2L Tester" (M1 polish).
- v2.65: Předvyplněná default URL `http://185.149.129.164/download` v `firmware_base_url` při prvním spuštění (fallback v `loadSettings` pokud klíč v `SharedPreferences` chybí). Existující instalace s uloženou vlastní URL zůstanou nedotčené — jen čisté instalace dostanou default.
- v2.64: **Hromadné nahrání firmware** — nová položka "Nahrát firmware" v `BulkConfigMenu` (ikona `system_update_alt`, mezi "Aplikovat šablonu" a "Restart"). Dialog `_BulkFirmwareDialog`: pole "Cesta" + tlačítko "Ověřit", dropdown s detekovanými `*.bin` soubory (zebra-stripe podbarvení lichých řádků, sort sestupně podle `YYMMDDVV`, label `<file> · <type> · <date> · <size>`), live preview "Bude odesláno" v monospace, červené FLASH tlačítko. Pokud cesta končí `.bin` → posílá se přímo, dropdown skryt. Auto-discovery z Apache/nginx autoindex HTML přes nový `lib/services/firmware_listing_service.dart` (regex `href="P2L_(\d+)([A-Za-z]+)\.bin"`, žádný hardcoded filter typů). Persistence base URL v `SharedPreferences` (`firmware_base_url`). `CommandService.buildUpdateCommand({fileName})` produkuje `{"request_id":-1,"cmds":[{"cmd":"update","args":{"file_name":"<url>"}}]}`. `AppState.sendBulkFirmwareUpdate` posílá s 100ms pauzou + označí jednotky offline-until-alive (flash způsobí restart). Dependencies: `http: ^1.2.2`. Android: `android:usesCleartextTraffic="true"` v `AndroidManifest.xml` (firmware server běží na HTTP). Ověřeno na novém FW na unit 1209 (`I/001209/P2L/011209/CMD`).
- v2.63: Duplikování šablon (PopupMenu item "Duplikovat" v `TemplatesScreen` → JSON deep-clone modulů, unikátní název `X (2)`, otevře editor) + zobrazení adresy na displeji PUM-A: nová položka "Adresa na displej (0130)" v menu chipu (pošle 4-místné padované číslo) a tlačítko pin v PUM-A group headeru, které postupně rozesílá adresy všem displejům s 100ms pauzou. Užitečné pro fyzickou identifikaci modulů na sběrnici.
- v2.62: **REPLACE-FROM rozšířen na BTN čipy** — `supportsReplace` nyní podporuje `DeviceType.btn` (default 247), `ReplaceDeviceDialog` mapuje PUM-B i PUM-C na `DeviceType.btn`, `_canReplace` v `unit_detail_screen` povoluje "Vyměnit" pro PUM-B/C. `AppState` subscribuje `O/+/BTN/+/REPLACE-FROM`. Test `I/<unit>/BTN/<addr>/REPLACE-FROM` v `command_service_devices_test.dart`.
- v2.61: Factory default adresy upraveny dle aktuálního HW: PUM-A (DISP) = 246, PUM-B/PUM-C (BTN) = 247, DIST = 127. `CommandService.defaultReplacementAddress` doplněn o BTN=247. `AddModuleDialog` rozsah validace pro PUM* rozšířen z 127–246 na 127–247 (kvůli PUM-C/B s factory default 247 v šablonách). Pozn.: `README-P2L-32.md` upstream říká DISP default = 247, ale autoritativní pro appku je HW hodnota 246.
- v2.60: **Export/import seznamu ID P2L modulů** — `lib/services/unit_ids_io.dart` (JSON wrapper `p2l-tester.unit-ids` v1, canonical normalizace ID podle generace, filename `{broker}_ID-Nx_{datum}.json`). Volitelný `brokerProfile` v JSON (kompletní `BrokerProfile.toJson`; při importu se tiše přidá do profilů bez aktivace, pokud název ještě neexistuje). `P2LUnit.isPlaceholder` + placeholder ctor pro importovaná ID, která ještě neodpověděla (tick-timer placeholder přeskakuje, ALIVE/get_param překlopí na full unit). `AppState.scanAll` přepsán na async s 100ms pauzou + progress status. UI: 2 nové IconButton (Načíst / Export) v `_ManualIdInput`, placeholder indikátor `help_outline` v `_UnitCard`, `SelectionArea` v Info dialogu (Ctrl+C na Windows), auto-clear pole "ID P2L modulu" po úspěšném ověření (`_pendingVerifyId`), SnackBar při neplatném vstupu. 22 testů v `test/unit_ids_io_test.dart`.
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

## In-app nápověda — udržovat v souladu
- Uživatelský návod ovládání je `docs/navod.md` (registrovaný jako asset v `pubspec.yaml`), zobrazený v appce přes `lib/screens/help_screen.dart` (tlačítko „Nápověda" `Icons.help_outline` v AppBaru obrazovky **Nastavení**, vedle Export/Import). **Jeden zdroj, dvě cesty** — čitelný i na GitHubu.
- Renderuje vlastní lehký renderer `_MarkdownView` (nadpisy `#`/`##`/`###`, odstavce, odrážky `- `, číslované `1.`, citace `> `, `---`, GFM tabulky, inline `**tučné**` / `` `kód` ``) — **bez závislosti `flutter_markdown`** (deprecovaný). Obsah návodu řídíme sami, proto stačí tahle podmnožina; pokud do návodu přibude jiná syntaxe, rozšířit renderer.
- **Pravidlo:** při každé user-facing změně ovládání (přejmenování/přesun tlačítka, nová akce v menu, nový dialog, změna toku) zkontrolovat `docs/navod.md` a sjednotit příslušnou sekci — ideálně ve stejném commitu. Čistě interní změny/refactory bez dopadu na ovládání návod měnit nemusí. Drobné úpravy návodu nezvedají `appVersion`.

## Splash Screen
- `lib/screens/splash_screen.dart` — Flutter splash s `Image.asset('assets/icons/Smartboxlogo.png')` na bílém pozadí, dole verze aplikace.
- Asset registrovaný v `pubspec.yaml` (`flutter.assets`).
- Délka zobrazení: 2200 ms, pak `Navigator.pushReplacement` s `FadeTransition` 300 ms na `_InitialRoute`.
- Důvod: nativní Android 12+ splash zobrazuje jen kruhovou ikonu uprostřed (oříznuté logo), Flutter splash dává plnou kontrolu na všech platformách.
