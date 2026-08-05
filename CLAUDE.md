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
| **PUM-A** @N | displej + 0–4 tlačítka + volit. LEDS | ano | 1 | DISP `N` + volit. LEDS `N`; tlačítka viz níže | **246** (DISP) |
| **PUM-B** @N | samostatné tlačítko + volit. LEDS | ano | 1 | BTN `N` (bez prefixu) + volit. LEDS `N` | **247** (BTN) |
| **PUM-C** @M | vždy 2 tlačítka (+/−), jen jako doplněk PUM-A bez 2 tlačítek | NE | 1 | BTN `1000+M` (+), BTN `M` (−) | **247** (BTN) |
| **DIST** @N | senzor vzdálenosti | ano | 1 | DIST `N` s konfigurací | **127** |

**Factory default** = adresa, kterou má čip z výroby před přečipováním. Po fyzické výměně vadného kusu aplikace pošle `DEVICE-REPLACE` s touto default adresou v poli `From` a adresou vadného kusu v poli `To` → jednotka přečipuje nový kus na ID původního. Autoritativní zdroj: [`CommandService.defaultReplacementAddress`](lib/services/command_service.dart).

### PUM-A tlačítka (0–4)

PUM-A má uprostřed displej a okolo něj **0 až 4 tlačítka** (až 2 vlevo, až 2 vpravo). Každé tlačítko je samostatná BTN entry s adresou `offset + N` (N = adresa DISP). **Číslo tlačítka (0–3) = tisícová číslice adresy** (`offset / 1000`).

| Fyzická pozice (zleva doprava) | Offset | Adresa | **Číslo** | Strana |
|-------------------------------|--------|--------|-----------|--------|
| levé-vlevo (vnější L) | `3000` | `3000+N` | **3** | levá |
| levé-vpravo (vnitřní L) | `1000` | `1000+N` | **1** | levá |
| DISPLEJ | — | `N` | — | — |
| pravé-vlevo (vnitřní P) | `0` | `N` | **0** | pravá |
| pravé-vpravo (vnější P) | `2000` | `2000+N` | **2** | pravá |

Tlačítka jsou **nezávislá** (libovolná kombinace 0–4). Na každé straně je nižší číslo vnitřní (u displeje). Strana pro zvýraznění stisku: čísla **1 a 3 = levá hrana**, **0 a 2 = pravá**. Reprezentace v kódu: `Set<PumaButton>` (`PumaButton` + `PumaButtonExt` v [`module.dart`](lib/models/module.dart)). Autoritativní zdroj: [`module_reconstruction.dart`](lib/services/module_reconstruction.dart) a `PumaModule.toDevices()`.

**Disambiguace vs. PUM-C:** offsety `0`/`1000` sdílí PUM-A i PUM-C, ale PUM-A má vždy DISP na `N`, PUM-C nikdy → BTN patří PUM-A právě tehdy, když na jeho bázové adrese (`addr % 1000`) existuje DISP. Offsety `2000`/`3000` jsou výhradně PUM-A.

**Migrace starého formátu:** dřívější model (`buttonCount` 0/1/2 + `buttonSide`) je v `PumaModule.fromJson` mapován na sadu tlačítek (`left`/1000+N → tl. 1, `right`/N → tl. 0, 2 tl. → {0,1}) kvůli starým uloženým šablonám.

### Klíčová pravidla rekonstrukce

- **PUM-B** a **PUM-C mínus** jsou oba holá `N` — rozlišit se dají jen tak, že PUM-C mínus má vždy párového brata `1000+N`.
- **LEDS** jsou fyzicky součástí PUM-A nebo PUM-B (volitelný LED kroužek na tlačítku). V `GET-DEVICES` se objeví jen pokud je jednotka "potřebuje znát" — registrace je volitelná. PUM-B s LEDS = BTN @N + LEDS @N (rekonstrukce: BTN bez DISP páru, LEDS na stejné adrese → PUM-B s LEDS).
- **DISP** vždy znamená PUM-A.
- **PUM-C** lze zapojit JEN k PUM-A, které má 0 nebo 1 tlačítko (PUM-C dodá chybějící). Kombinace PUM-A se 2 tlačítky + PUM-C vedle je neplatná.
- Adresy modulů jsou **nezávislé** — PUM-A na 128, PUM-C na 130 je validní.

### Algoritmus rekonstrukce z `GET-DEVICES`

1. Pro každý DISP `N`: vytvoř PUM-A @N. Nárokuj BTN z `{N, 1000+N, 2000+N, 3000+N}` (čísla 0/1/2/3) jako jeho tlačítka. LEDS `N` → `hasLeds=true`.
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

#### Portable distribuce s vlastním serverem (v2.81+)

`tools\pack-portable.ps1` sestaví Windows distribuci, která **nosí Node server s sebou** — appka si ho spustí při startu a ukončí při zavření, takže databáze jednotek funguje bez instalace Node a bez ručního `npm start`.

```bash
flutter build windows --release
flutter build apk --release --split-per-abi         # volitelné (APK do zipu)
powershell -ExecutionPolicy Bypass -File tools\pack-portable.ps1
```

Skript čte verzi z `appVersion` v `main.dart`, do `dist\P2L-Tester-v<VER>\` nakopíruje celý Release, přejmenuje exe a přiloží `server\` + `node.exe` z PATH. Parametry: `-OutRoot <cesta>` (jiná cílová složka, pro testy), `-SkipZip`.

**Co se do `server\` NEKOPÍRUJE a proč:**
- `.env` — obsahuje JWT secret a admin heslo; portable režim si secret generuje sám (`SharedPreferences` klíč `local_server_jwt_secret`) a předává procesu jako env proměnnou. Skript navíc dělá pojistný sweep na `.env` / `*.db*`.
- `data\` — DB se drží v `%APPDATA%\P2L-Tester\server-data`, aby rozbalení novější verze nepřepsalo `units.db`.
- `test\`, `scripts\` — k běhu nejsou potřeba.

**Přiložený `node.exe` musí být té major verze, pro kterou jsou zkompilované native moduly** v `node_modules` (`better-sqlite3`, `bcrypt`). Skript proto přikládá ten samý runtime, kterým se dělal `npm install` (bere `(Get-Command node).Source`). Po `npm install` s jinou major verzí Node je potřeba distribuci sestavit znovu.

Velikost: `server\` ≈ 100 MB rozbaleno (node.exe ~80 MB + node_modules ~19 MB), celá složka ≈ 128 MB.

**PowerShell skripty ukládat jako UTF-8 s BOM** — Windows PowerShell 5.1 čte UTF-8 bez BOM jako ANSI a české texty rozhodí parser (em-dash uvnitř stringu → syntaktická chyba).

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

## Databázová vrstva serveru — SQLite nebo MariaDB (v2.82+)

Server umí dva drivery, přepínač je env `DB_DRIVER` (`sqlite` default | `mariadb`).
**Datová vrstva je jedna** — rozdíly izoluje [server/db/adapter.js](server/db/adapter.js).

- **sqlite** — `data/users.db` + `data/units.db`, nic se neinstaluje (portable dist).
- **mariadb** — jedna databáze (`P2Lunits`) se všemi tabulkami → sdílená evidence.
  `openDatabases()` proto u MariaDB vrací **jeden pool** pro users i units.

**Vše je asynchronní.** better-sqlite3 byl synchronní, MySQL klient být nemůže — takže
`db/units.js`, `db/users.js`, `db/init.js`, všechny routes i CLI skripty jsou async.
Express 4 rejected promise nezachytí, proto má každý router `wrap()` helper.

**Adapter API:** `get/all/run/exec/columns/transaction/close` + `sql` (dialektové fragmenty).
Parametry pojmenovaně `:name` (rozumí jim better-sqlite3 i mysql2 s `namedPlaceholders`).

**Pravidla, na která se naráží:**
- **Uvnitř `db.transaction(fn)` se dotazuj přes předaný `tx`**, ne přes vnější handle.
  U MariaDB drží transakce jedno spojení z poolu; u SQLite je vnější handle serializovaný
  mutexem (async `await` mezi `BEGIN`/`COMMIT` by jinak pustil cizí zápis do transakce)
  a rekurzivní vstup by se zablokoval sám.
- **Časové značky generuje JS** (`adapter.nowIso()`, ISO 8601), ne SQL. `datetime('now')`
  vs `UTC_TIMESTAMP()` se liší formátem a `computeDrift` na tom staví.
- **`LIMIT`/`OFFSET` se vkládají do SQL jako konstanty**, ne jako parametry — MariaDB je
  v prepared statements přijímá nespolehlivě (hodnoty jsou z kódu, nikdy z requestu).
- **`DELETE ... WHERE id IN (SELECT ... FROM stejná_tabulka)` MariaDB nedovolí** → prune
  historie je dvoufázový (SELECT id → DELETE ... IN).
- Dialektové rozdíly ve fragmentech: `ON CONFLICT DO NOTHING/UPDATE ... excluded.x` vs
  `ON DUPLICATE KEY UPDATE ... VALUES(x)`, `CAST(x AS INTEGER)` vs `AS UNSIGNED`,
  `COLLATE NOCASE` vs ci collation ve schématu.
- Schémata jsou po dialektech: `schema.sql`/`schema.mariadb.sql`,
  `units-schema.sql`/`units-schema.mariadb.sql`. MariaDB nezná `CREATE INDEX IF NOT EXISTS`
  → indexy inline v `CREATE TABLE`.
- `GET /api/health` vrací `{ok, ts, db}` — `db` je typ driveru (bez údajů o spojení).
  Appka podle něj pozná, že adoptovala server nad jinou databází (`LocalServer.dbMismatch`).
- **Past při přechodu na MariaDB:** nad prázdnou DB si první start serveru (i `db-check`)
  naseeduje admina z `INITIAL_ADMIN_*`. `migrate-users` pak to jméno **přeskočí** a účet má
  heslo z `.env`, ne původní → login starým heslem selže. Poznat to jde po `created_at`
  (dnešní datum místo původního). Řešení: `--overwrite`. Narazili jsme na to 2026-08-05.
- **Přenos dat mezi drivery:** uživatelé skriptem `npm run migrate-users`
  ([scripts/migrate-users.js](server/scripts/migrate-users.js)) — bcrypt hashe 1:1, takže
  hesla dál platí; zdroj read-only, existující jména se přeskočí (`--overwrite` je přepíše),
  účty jen v cíli se nemažou. **Jednotky** přes `GET /api/units/export` → `POST /api/units/import`
  (kompletní snímek vč. hesel a historie, import je idempotentní upsert).
- Testy: `npm test` = SQLite `:memory:`, `npm run test:mariadb` = tatáž sada proti reálné
  MariaDB (`TEST_DB_NAME`, default `P2Lunits_test` — **testy DB před každým testem mažou**,
  skript odmítne `P2Lunits`). `npm run db-check` ověří spojení mimo server.
- `mysql2` je čistě JS (žádný native build), na rozdíl od `better-sqlite3`/`bcrypt`.

**Kdo se na kterou DB dostane:** vlastní server si spustí jen desktop (Windows). Android
ani web Node runtime nemají (a prohlížeč se na MySQL port nepřipojí) → ty se hlásí
k serveru na síti (`Nastavení → Účet`). Pro web servírovaný jinde než API je potřeba
`CORS_ORIGIN` (platí i v produkci, na rozdíl od dev-only `DEV_CORS_ORIGIN`).

## Lokální server pro databázi (portable Windows, v2.81+)

Databáze jednotek žije v SQLite (nebo MariaDB, viz výše) obsluhované Node backendem v `server/`. Aby Windows EXE nepotřebovalo ruční `npm start`, appka si server spouští sama.

**Kód:** [lib/services/local_server.dart](lib/services/local_server.dart) (conditional export jako `mqtt_client_factory`) → [local_server_io.dart](lib/services/local_server_io.dart) (nativ) / [local_server_stub.dart](lib/services/local_server_stub.dart) (web, no-op). UI: [lib/widgets/local_server_section.dart](lib/widgets/local_server_section.dart) v Nastavení pod sekcí Účet. Start/stop zapojený v [main.dart](lib/main.dart) (`_bootstrapNative`, `AppLifecycleListener.onExitRequested`).

**Detekce:** `server/server.js` se hledá vedle EXE (portable dist), pak v `cwd/server` (dev z repa). Node: přiložený `server/node.exe`, jinak `node` z PATH. Když nic → `LocalServerStatus.unavailable` a **sekce v UI se vůbec nezobrazí** (appka pro terén vypadá jako dřív).

**Volba databáze v UI:** sekce *Lokální server* → řádek **Databáze** → dialog `_DatabaseDialog`
([local_server_section.dart](lib/widgets/local_server_section.dart)) přepne SQLite/MariaDB a
uloží `LocalServerDbConfig` do `SharedPreferences` (`local_server_db_*`). Server čte konfiguraci
jen při startu → dialog po uložení **restartuje** instanci, kterou spustila appka (cizí
adoptovanou ne, jen upozorní). Heslo k MariaDB leží v prefs otevřeně jako hesla brokerů → DB
účet ať má práva jen na tu jednu databázi.

**Konfigurace se předává jako env proměnné procesu, ne přes `.env`:**
- `P2L_DATA_DIR` = `%APPDATA%\P2L-Tester\server-data` — DB **mimo aplikační složku**, jinak by ji přepsalo rozbalení nové verze. Server: [server/db/paths.js](server/db/paths.js), používají `db/index.js` (users.db) a `db/units.js` (units.db) — cesty se čtou **lazy**, ne do konstanty při `require`.
- `JWT_SECRET` — generovaný jednou (`Random.secure()`, 32 B hex), držený v `SharedPreferences` (`local_server_jwt_secret`). Musí být stabilní, jinak by restart appky zneplatnil vydané tokeny.
- `PORT` (`local_server_port`, default 3001), `NODE_ENV=production`.
- `DB_DRIVER` + při MariaDB `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD`/`DB_NAME`
  (z `LocalServerDbConfig`). `P2L_DATA_DIR` platí i při MariaDB — server si tam pořád
  píše PID file.
- `INITIAL_ADMIN_USER`/`_PASSWORD` jen při bootstrapu správce — **nikdy se neukládají**, žijí jen v dialogu.

**Pozor na `.env` v devu:** při spuštění serveru z repa dotenv `.env` načte (naše env proměnné mají prioritu, protože dotenv existující `process.env` nepřepisuje). Proto se v devu naseeduje admin z `.env` a `needsAdminBootstrap` je false — v portable distu `.env` chybí, takže nabídka „Založit správce" naskočí.

**Klíčová pravidla:**
- **Cizí server se nikdy nezabíjí.** Když `/api/health` odpoví před startem, proces se jen adoptuje (`ownsProcess = false`) a při zavření appky zůstane běžet. Chrání `npm run dev` v terminálu.
- **Sirotci přes PID file.** PID si píše **sám server** ([server.js](server/server.js) → `<dataDir>/server.pid`), protože jen on zná svůj skutečný PID. Hard kill appky (Správce úloh) graceful hook nespustí → při dalším startu appka PID přečte, ověří přes `tasklist`, že je to `node.exe` (PID se recyklují), a zabije. Úklid běží **jen když health neodpovídá**, takže nemůže sestřelit funkční instanci. Na Windows je `Process.kill()` TerminateProcess → SIGTERM handler v serveru neproběhne, PID file maže appka.
- **`needsAdminBootstrap` se ptá serveru**, ne filesystému — `GET /api/bootstrap-status` (bez auth, vrací jen `{hasUsers: bool}`). Existence `users.db` nestačí: soubor vznikne i při startu nad prázdnou DB, takže by nabídka zmizela dřív, než by uživatel účet vytvořil.
- **`AuthSession.preferLocalBase`** nasměruje session na lokální port před `restore()`. Uložený **vzdálený** base (firemní server) má přednost a zůstane; uložený **loopback s jiným portem** se přepíše.
- **Pořadí startu:** `LocalServer.init()` → `maybeAutostart()` → `AuthSession.restore()`. Kdyby restore běželo hned, narazilo by na ještě nenaběhnutý server a skončilo ve stavu `offline` (uživatel by musel klikat „Zkusit znovu").

**Testy:** [test/local_server_test.dart](test/local_server_test.dart) reálně spouští Node na portu 3097 (start/health/stop, adopce cizího procesu, úklid sirotka). Vyžadují `HttpOverrides.global = null` — `TestWidgetsFlutterBinding` jinak na každý HTTP request vrací 400 a health probe nikdy neprojde. Skipují se, když chybí Node nebo `server/node_modules`. Server: [server/test/paths.test.js](server/test/paths.test.js), [server/test/bootstrap.test.js](server/test/bootstrap.test.js).

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

Current version: **2.82** (see `main.dart`)  
Recent themes:
- v2.82: **Server umí MariaDB (sdílená evidence) + Docker image.** (1) **Dva drivery, jedna datová vrstva** — přepínač `DB_DRIVER` (`sqlite` default | `mariadb`), rozdíly izoluje nový [server/db/adapter.js](server/db/adapter.js); celá vrstva (`db/units.js`, `db/users.js`, `db/init.js`, routes, CLI skripty) je **async**, protože MySQL klient synchronní být nemůže. Detail pravidel (transakce přes `tx`, časové značky z JS, `LIMIT` jako konstanta, dialektové fragmenty) v sekci *Databázová vrstva serveru* výše. Schémata po dialektech: `schema.mariadb.sql`, `units-schema.mariadb.sql`. (2) **Volba databáze z UI** — sekce *Lokální server* → *Databáze* přepne SQLite/MariaDB, uloží `LocalServerDbConfig` do `SharedPreferences` a restartuje server, který appka spustila. `GET /api/health` vrací typ driveru → appka pozná adopci serveru nad jinou DB (`LocalServer.dbMismatch`). (3) **Přenos dat** — `npm run migrate-users` (bcrypt hashe 1:1, zdroj read-only, idempotentní), jednotky přes `GET /api/units/export` → `POST /api/units/import`. `npm run db-check` ověří spojení mimo server. (4) **Docker** — [server/Dockerfile](server/Dockerfile) (dvoustage `node:22-bookworm-slim`, native moduly se kompilují jen v build stage, běh jako `node`, `HEALTHCHECK` na `/api/health`, data ve volume `/data` přes `P2L_DATA_DIR`) + [server/docker-compose.yml](server/docker-compose.yml) (backend + `mariadb:11.4`, port DB se na host nemapuje, API default na loopback) a `.env.docker.example`; `.env` se do image nekopíruje, konfigurace jde env proměnnými. Testy: `npm test` (SQLite `:memory:`, 68) i `npm run test:mariadb` (tatáž sada proti reálné MariaDB, `TEST_DB_NAME`). Návod k nasazení v [server/README.md](server/README.md) §Docker.
- v2.81: **Portable Windows distribuce — appka si spouští vlastní server pro databázi.** Windows EXE nosí Node server v podadresáři `server\` (viz `tools\pack-portable.ps1`) a **spustí ho při startu, ukončí při zavření** → databáze jednotek funguje bez instalace Node a bez ručního `npm start`. (1) **Launcher** [local_server_io.dart](lib/services/local_server_io.dart) + web stub, conditional export; detekce serveru vedle EXE / v repu, přiložený `node.exe` s fallbackem na PATH; health probe na `/api/health`. (2) **Data mimo aplikační složku** — nový [server/db/paths.js](server/db/paths.js) s override `P2L_DATA_DIR`, appka míří na `%APPDATA%\P2L-Tester\server-data`, takže rozbalení novější verze nepřepíše `units.db`. `.env` se nepoužívá (obsahuje secret) — konfigurace jde jako env proměnné, `JWT_SECRET` se generuje jednou do `SharedPreferences`. (3) **Cizí server se adoptuje, ne zabíjí** (`ownsProcess`) — chrání `npm run dev`. (4) **Sirotci přes PID file**, který píše sám server; úklid ověřuje přes `tasklist`, že PID patří `node.exe`, a běží jen když health neodpovídá. (5) **Bootstrap správce** — nový endpoint `GET /api/bootstrap-status` (bez auth, jen `{hasUsers}`); při prázdné DB nabídne UI založení účtu, restartuje server s `INITIAL_ADMIN_*` a hned přihlásí (heslo se nikam neukládá). (6) **`AuthSession.preferLocalBase`** — session jde na lokální port, ale uložený vzdálený server má přednost; `restore()` se volá až po naběhnutí serveru, takže se přeskočí stav „offline" a klikání na „Zkusit znovu". (7) **UI** sekce „Lokální server (databáze)" v Nastavení pod Účtem (stav / autostart / Spustit-Zastavit / Log), zobrazí se jen když je server k dispozici. Testy: nový [test/local_server_test.dart](test/local_server_test.dart) (reálný start Node na 3097, adopce, sirotek), [server/test/paths.test.js](server/test/paths.test.js), [server/test/bootstrap.test.js](server/test/bootstrap.test.js) + rozšířený `auth_session_test.dart` — celkem 196 Flutter + 46 server testů. Návod §9.1.
- v2.80: **Databáze jednotek — ruční evidence, hromadné akce, zpřesnění driftu, UX změny brokera.** (1) **Ruční editace evidence** (broker/WiFi/jas) na kartě jednotky v DB — ikona ✎ v hlavičce sekce Konfigurace, zápis přes existující `saveDesired` (`PUT /units/:id/desired`); pro jednotky nedosažitelné přes MQTT (nasazené u zákazníka). `_ConfigEvidenceDialog` vrací fragment (uložení řeší volající), hesla předvyplněná skutečnou hodnotou (jinak by top-level merge přemazal). (2) **Hromadné akce v seznamu DB** ve stylu HomeScreen (zatržítka u řádků + „Vybrat vše"/„Zrušit" nad seznamem + tlačítko „Hromadné úpravy" `settings_remote` v AppBaru): **Změnit parametry** (evidence; předvyplní hodnoty, které mají všechny vybrané shodné, přes `POST /units/bulk/common-desired`), **Změnit stav/zákazníka/umístění** (meta), **Smazat** (jen admin, potvrzení opsáním počtu). Bulk endpointy `POST /units/bulk/{desired,meta,delete,common-desired}` (transakce, delete tolerantní k chybějícím ID, admin gating), **hloubkový merge desired** (`updateDesired` slévá broker/wifi po podklíčích — částečný fragment nepřemaže ostatní podpole), `UnitDbService.isAdmin` z `AuthSession.user.isAdmin`. (3) **Drift v2.1 — „Nesoulad" jen když je co ověřit:** klient `UnitDbCard.driftWarnings` i server `computeDrift` hlásí drift jen když jsme jednotku viděli **až po** poslední změně evidence (`last_seen ≥ desired_updated_at`) — čerstvá, ještě nepozorovaná změna (jednotka odešla na jiný broker / offline) = čekající → žádný banner. ⚠ na HomeScreen jen u **online** jednotek. V seznamu DB se u čekající změny ukáže **zamýšlený** broker (z evidence), ne stará observed adresa. Dedup: „jednotka hlásí" se nezobrazí, když se shoduje s „uloženo v NVS". (4) **UX změny brokera:** po potvrzení (ack) jednotka **zmizí ze seznamu** (`_forgetUnit` místo jen offline) — opustila tenhle broker; když se někde znovu ozve, přijde jako nová a auto-fetch (get_param+GET-DEVICES+GET-CONFIG) se spustí přes cestu prvního ALIVE. Status **„U jednotky X / U N jednotek potvrzen příjem požadavku na změnu brokera 'DEV'"** (1 kus → ID; správná pluralizace „jednotky/jednotek"; píše do `_statusMessage` = hlavní bar, ne `_setStatus`). WiFi zůstává offline-until-alive (nemění broker). (5) **Prostorově úspornější detail karty** (menší chrome sekcí/řádků, menší písmo popisků, kratší nejdelší labely). Testy: rozšířené `unit_db_screen_test.dart` + server `units.test.js`. Návod §10.
- v2.79: **Sloučené pohledy v detailu karty jednotek v DB + čitelný čas.** Detail karty slučuje pohledy evidence/uloženo/běží do jednoho řádku na parametr (shoda → ✓, rozdíl → rozepsané), časové značky čitelně.
- v2.78: **DB5 (PRD-DB v2) — UNIT GET-CONFIG do observed vrstvy + drift v2 + ⚠ na HomeScreen.** Nový FW `P2L_26071501NT` přidal UNIT `GET-CONFIG` → appka teď z jednotky čte kompletní konfiguraci (uloženo v NVS: broker/SSID/statická IP/dns/gw/maska/mqttUser/mqttInsec/cert + reálný stav `actualIp`/`actualSSID`). (1) **CommandService:** `firmwareSupportsGetConfig` (práh datum ≥ 260715, vzor `firmwareSupportsBin`), `buildGetConfigCommand(unitId, {user, password})` — s přihlašovacími údaji FW vrací i **skutečná hesla** (`PSWD`/`mqttPassword` jako string), bez nich bool „je nastaveno". (2) **P2LUnit:** pole `unitConfig` + `updateFromGetConfig` (osvěží i FW/MAC). (3) **AppState:** subscribe `O/+/UNIT/+/GET-CONFIG`, `_handleGetConfigResponse` → push do DB, `fetchConfig` (gating na nová gen přes **ID ≥ 1000 || isNewGen** — samotný `isNewGen` je vratký: FW hlásí ID s prefixem `u` → jinak false; FW config creds `admin`/`smartbox` default, přepsatelné přes SharedPreferences `get_config_user`/`get_config_password`), volané z `fetchDevices`. (4) **Rozhodnutí (interní tool):** do evidence se ukládají i skutečná hesla — **žádná redakce**; ochrana = HTTPS + auth + přístup k serveru (šifrování = budoucí DB8). Server tri-state pojistka: pozdější bool `true` (odpověď na `{}` od jiného klienta na sběrnici) **nepřepíše** dřív zachycené skutečné heslo (`mergeConfigSecrets`). (5) **Server:** sloupce `unit_config_json`/`unit_config_fetched_at` (přes `ensureObservedColumns`), `computeDrift` **v2** (3 kategorie: evidence↔uloženo / uloženo↔běží / evidence↔kde-žije; DHCP = prázdný string), `getUnit` vrací `unit_config`, `listUnits` unit config neúniká. (6) **UnitDbCard:** `driftWarnings` v2 (fallback na get_param u starého FW), `acceptObservedFragment` preferuje GET-CONFIG. (7) **UI:** karta má sekci **„Uloženo v jednotce (GET-CONFIG)"** (nastaveno vs. běží, hesla maskovaná s okem); na **HomeScreen** v řádku jednotky **⚠ ikona** (jen přihlášený + jednotka má v DB drift) → klik otevře kartu; `AppState._dbDriftIds` z `GET /units` (debounce, jen přihlášený). Ověřeno **naživo na jednotce 1209** (FW 26071501NT): `{}` → bool hesla, creds → skutečná hesla; DHCP=`""`, `actualIp` reálná. Testy: `unit_get_config_test.dart` (nový), rozšířené `command_service_devices_test`/`unit_db_service_test`/`unit_db_screen_test` + server `units.test.js`. Detail v [PRD-DB/02-PRD-konfigurace.md](PRD-DB/02-PRD-konfigurace.md). Návod §2 (⚠ ikona) + §10 (sekce GET-CONFIG, drift v2). **Potvrzení příjmu (request_id ACK):** hromadná změna WiFi/brokera/firmwaru už neběží naslepo — `set_WiFi`/`set_Mqtt`/`update` se posílají s rostoucím `request_id` (`CommandService.nextRequestId`, rozsah **1–65535** = FW limit 16bit/5 míst, wraparound; seed ze sekund epochy mod 65535 → přes restart nekoliduje; jednotka nesmí opakovat posledních 10 → čítač to garantuje), appka subscribuje `O/+/P2L/+/CMD` a čeká na `{"status":"received"}` (`_handleCmdAck`, timeout 5 s). **Desired se do DB zapíše až po potvrzení** (`_sendTrackedConfigCmd`) — offline jednotka příkaz nedostane, uživatel vidí „NEPOTVRDILA (offline?)" a evidence nelže; u firmwaru se i offline-until-alive nastaví až po acku. Stará gen (ack neumí) → pošle s `-1` a potvrdí optimisticky jako dřív. LED test / get_param zůstávají na `-1` (bez acku). Návod §4. **Config CMD topic:** `_sendTrackedConfigCmd` posílá config příkazy na topic podle spolehlivého „`isNewGen || ID ≥ 1000`" (ne jen vratký `isNewGen` — FW hlásí ID s „u" prefixem → false), takže nová jednotka (1209) jde na `I/001209/P2L/011209/CMD` (ne starou `I/u1209/SERVER/CMD`) a ackne na jeho zrcadle `O/001209/P2L/011209/CMD`. **Auto-refresh observed po config změně:** změna brokera/WiFi jednotku restartuje → `onConfirmed` ji přes `_expectRestartReread` zaregistruje a po návratu (`_handleAlive`) appka zavolá `_autoRefreshObserved` = get_param + GET-DEVICES + GET-CONFIG. get_param je nutné, aby se obnovil i `mqtt_server` (jinak `computeDrift` kat. 3 hlásí falešný drift ze zastaralého snapshotu). Stejný refresh běží i při prvním ALIVE (i po reconnectu na jiný broker).
- v2.77: **Segmentový režim DIST — čtení segmentů + zachování při editaci.** Senzor v segmentovém režimu hlásí místo surové vzdálenosti pásmo, do kterého objekt padl. (1) **Model:** nová třída `DistSegment` (`id`/`from`/`to`/`positionId`) + `List<DistSegment> segments` v `DistConfig` ([module.dart](lib/models/module.dart)) — `toJson`/`fromJson` (objektový tvar `{SegmentId,From,To,PositionId}` pro SET-CONFIG a perzistenci), `toPositional`/`fromPositional` (poziční tvar pro RECREATE/ADD). **Reálný FW posílá segment jako 3-prvkový** `["R01.A01",0,200]` (bez `PositionId`, README uvádí 4) — parser to zvládá, zpět posíláme stejný 3-prvkový tvar (4 prvky jen když `positionId != 0`). (2) **Oprava mrtvého kódu:** `parseDistConfigs` se dosud **nikde nevolal** a `reconstructModules` vytvářel DIST moduly bez configu → edit modal ukazoval jen defaulty. Nově `reconstructModules(devices, {distConfigs})` a `AppState` (`_handleGetDevices`) předává `parseDistConfigs(devicesField)` — edit modal teď ukazuje **skutečnou** konfiguraci senzoru vč. segmentů. `parseDistConfigs` navíc parsuje 8. prvek (segmenty). (3) **Zachování segmentů při editaci (past):** `buildSetDistConfigCommand` (SET-CONFIG) přikládá pole `Segments` jen když existují — bez něj by FW přepnul senzor zpět do režimu vzdálenosti a segmenty smazal. `_buildDevicesPayload` (RECREATE/ADD) plní 8. prvek segmenty místo prázdného `[]`. Edit dialog ([add_module_dialog.dart](lib/widgets/add_module_dialog.dart)) segmenty **jen zobrazuje** (read-only výpis „název · od–do mm", ohraničený, celý modal se scrolluje) a při OK je beze změny přenáší zpět. (4) **Tlačítko „Obnovit"** vlevo dole v edit modalu (jen SENZOR, ikona `settings_backup_restore`) — vrátí skalární config na tovární default (50/10/0/20/4/Middle); **adresu ani segmenty nemění**, odešle se až po OK. (5) **Živý segment v chipu** ([unit_detail_screen.dart](lib/screens/unit_detail_screen.dart)): DIST chip v seznamu devices pod vzdáleností ukáže název aktuálního segmentu — **zeleně** uvnitř pásma / **šedě** mimo, z `D/.../DIST/.../UPDATE` polí `segmentID`+`state`. Pozor: FW posílá `state` jako **string** `"true"`/`"false"`. `AppState._handleDistUpdate` rozšířen o `_distSegments` + getter `distSegmentFor`. Testy: segmenty v `module_reconstruction_test.dart` (parse reálného payloadu 1209, round-trip 3-prvkový tvar) a `command_service_devices_test.dart` (SET-CONFIG přiloží/nepřiloží `Segments`, ADD-DEVICES 8. prvek). Návod §Akce na čipu (Upravit, živý chip). Segmenty se **nevytváří/needitují** — jen čtou.
- v2.76: **DB1 — opt-in login na nativu (PRD-DB).** První milestone centrální databáze jednotek ([PRD-DB/01-PRD.md](PRD-DB/01-PRD.md)). Backend: `POST /api/login` vrací JWT i v response body; nový helper `tokenFromReq` v [server/routes/auth.js](server/routes/auth.js) (cookie NEBO `Authorization: Bearer`) sdílený s `admin.js` a `firmware.js` — web flow (cookie) beze změny. Flutter: `AuthSession` ([lib/services/auth_session.dart](lib/services/auth_session.dart)) — ChangeNotifier singleton, stavy `loggedOut/loggedIn/offline`, token v `SharedPreferences` (`auth_session_token`/`auth_api_base`/`auth_session_user`), tichá obnova při startu (`main.dart`, fire-and-forget, timeout 5 s, NIKDY neblokuje start); `BearerClient` v [auth_http_client_io.dart](lib/services/auth_http_client_io.dart) přidává Bearer header (jen nativ; token drží [auth_token_store.dart](lib/services/auth_token_store.dart) — samostatný soubor kvůli importním cyklům); `AuthApi.lastLoginToken` zachytává token z loginu. UI: sekce **„Účet"** na konci Nastavení na **všech platformách** ([lib/widgets/account_section.dart](lib/widgets/account_section.dart)) — **jediné místo pro účet v celé appce**: nativ = login dialog (server/jméno/heslo; `normalizeApiBase` doplní `http://` a `/api`, takže stačí `192.168.1.10:3001`), stav přihlášen/offline s „Zkusit znovu", odhlášení; web = přihlášený uživatel + odhlášení přes `AuthScope`. **Ikona účtu (`_UserMenu`, `account_circle`) z AppBaru HomeScreen odstraněna** (rozhodnutí: žádná ikona účtu v AppBaru na žádné platformě; budoucí „Databáze jednotek" bude položka v hamburger menu, viz PRD-DB §6.1). Login je **opt-in** — nepřihlášená nativní appka se chová přesně jako dřív a o server se nepokouší. `rememberMe=true` vždy (JWT 7 dní → re-login ~1× týdně). 13 testů [test/auth_session_test.dart](test/auth_session_test.dart); backend E2E ověřen curl (Bearer /me + firmware-list + admin 403, cookie flow OK). Pozn.: firmware listing na nativu jde přímým `http.get` (bez auth klienta), takže Bearer token na cizí firmware server neuniká. **Součástí stejné vlny je DB2 (čistě backend):** centrální DB jednotek v `server/data/units.db` — [server/db/units.js](server/db/units.js) + [server/routes/units.js](server/routes/units.js) (`/api/units` CRUD za auth, seznam nikdy nevrací hesla, historie se scrubem, change-id přenáší kartu), 21 testů `npm test` (node --test). **A DB3 (zápisy z appky):** [lib/services/unit_db_service.dart](lib/services/unit_db_service.dart) — fire-and-forget push do DB jako vedlejší efekt akcí (gating: web vždy, nativ jen přihlášený; chyba zápisu nikdy neshodí MQTT akci). Hooky v `app_state.dart`: ALIVE → observed s throttle 30 s, get_param → observed s `includeParams` (SSID/aktuální broker/jas), GET-DEVICES → observed s devices, bulk broker/WiFi/jasy/OTA → desired fragmenty, setUnitId → change-id. Server desired = merge po top-level klíčích; observed sloupce `ssid`/`mqtt_server`/`mqtt_port`/`brightness` + mini-migrace `ensureObservedColumns`. **A DB4 (obrazovka „Databáze jednotek"):** položka v hamburger menu HomeScreen (jen přihlášení), [lib/screens/unit_db_screen.dart](lib/screens/unit_db_screen.dart) — seznam s vyhledáváním (ID+název+umístění) a chipy stavů, karta se 3 vrstvami (meta editovatelná dialogem, observed, desired s maskovanými hesly + oko), historie, **drift banner „Nesouhlasí s evidencí"** (`UnitDbCard.driftWarnings` v [lib/models/unit_db.dart](lib/models/unit_db.dart)); čtecí metody `UnitDbService` házejí `UnitDbException` → „Zkusit znovu". Návod §10. Detail v [PRD-DB/01-PRD.md](PRD-DB/01-PRD.md) §10.
- v2.75: **GET-ALIVE, diagnostika vadné části modulu, „????" na displejích.** (1) **Akce „Alive" v menu device** ([unit_detail_screen.dart](lib/screens/unit_detail_screen.dart), ikona `monitor_heart`) — vynutí okamžité ALIVE (`GET-ALIVE`, FW `P2L_26070201NT`+) na **všech atomických částech** modulu bez čekání na periodický 5min interval: PUM-A = DISP + LEDS + tlačítka, PUM-B = BTN (+ LEDS), PUM-C = obě tlačítka, DIST = senzor. `CommandService.buildGetAliveCommand({unitId, type, address})` → `I/<unit>/<TYPE>/<DEVICE_ID>/GET-ALIVE` payload `{}`; `AppState.sendModuleAlive({unitId, module})` iteruje přes `module.toDevices()` se 100ms pauzou; `onAlive` callback protažen celým řetězcem (`_ModulesGroupedList → _GroupSection → _AddressChip`), dostupné pro všechny typy. Odpovědi (ALIVE na `D/` topicy) se promítnou do zdraví devices stávajícím `_handleDeviceAlive`. (2) **U vadného modulu vidět, která část nekomunikuje.** Data už existovala v `_unitDeviceFaults` (Set `deviceId` jako `050246`/`061128`/`110130`), jen se v `deviceFaultAddresses` agregovala na base adresu. Nově `AppState.faultyPartsForModule(unitId, module)` porovná `toDevices()` s faults setem přes `deviceId` (prefix+addr4) → vrátí vadné `Device` části; `PumaModule.partLabel(Device)` → lidský popisek (displej / LED / tlačítko N / +/− u PUM-C / senzor). Chip modulu kromě červeného rámečku ukáže **červený odznak ⚠ + počet** vadných částí, konkrétní seznam v **tooltipu** („⚠ Nekomunikuje: displej, tlačítko 1"). Reaktivitu řídí stávající `Consumer<AppState>`. (3) **Ikona „????" v hlavičce PUM-A** (`Icons.question_mark`, před „Smazat text") — jeden broadcast `SET-DATA {"Data":"????"}` na `050000`; displeje vykreslí své **skutečné ID uložené v čipu** (Pum-A FW v3.01+). **Diagnostika fyzické výměny:** na rozdíl od `pin` („Adresa na každý displej", kde appka pošle adresu z konfigurace) `?` ukáže reálné ID z čipu — když někdo vymění kus za jiný (128 → 222), nesoulad je hned vidět. `sendDispData(dispAddress:0, data:'????')` (bez změny service/state, jen zpřesněná hláška + docstring). (4) **README-P2L-32.md** aktualizován kolegou (GET-ALIVE pro UNIT/DIST/DISP/LEDS/BTN, broadcast RS485 adresa 0, DISP `"????"`). Testy: GET-ALIVE topicy v `command_service_devices_test.dart` (vč. PUM-A tlačítka `061128`), `partLabel` v `module_reconstruction_test.dart`. Návod sjednocen (akce Alive, odznak vadné části, „????").
- v2.74: **Cílený sken jedné adresy (`SCAN-DEVICES {"Id":N}`) + ověřování devices.** (1) Nová volba **„ID…"** v menu skenu sběrnice (vedle Vše/PUM-X/SENZORY) — dialog na zadání adresy 1–247, firmware si typ (DIST/PUM) odvodí z rozsahu. Model: `BusScanResult.scanId` + `BusScanResult.withUpdatedAddress` (merge jedné adresy do existujícího skenu), `BusScanScope.containsAddress`; `diagnoseBus` při `scanId != null` omezí porovnání jen na tu adresu ([bus_scan.dart](lib/models/bus_scan.dart)). `CommandService.buildScanDevicesCommand({scanId})` → `{"Id":N}`. (2) **Auto-ověření po přidání device** — po `ADD-DEVICES`+`GET-DEVICES` se pošle `SCAN-DEVICES {"Id":N}` (jen 1 device); výsledek se **vmerguje** do existujícího skenu → ostatní ghosty zůstanou (`_pendingAddVerify`). (3) **Auto-ověření po smazání** — když čip fyzicky zůstane na sběrnici, ukáže se jako šedý ghost. (4) **Ověření před výměnou** — `probeBusAddress` (completer pattern, neukládá do zobrazeného skenu) ověří nový kus na jeho default adrese PŘED `DEVICE-REPLACE`; při nenalezení dialog „Přesto vyměnit?". Sken se invaliduje jen po re-adresování (REPLACE/SET-ID), ne po ADD/DELETE (config-only). (5) **Rescan** v popup menu čipu → cílený sken té adresy (OK/chybí). (6) Po **přečíslování PUM-A** (`DEVICE-SET-ID`) se nová adresa zobrazí na displeji (SET-DATA). Fixy: PopupMenuButton bral `null` jako „zrušeno" (→ nenulové String hodnoty); dialog adresy přepsán na vlastní `StatefulWidget` (controller dispose až v `dispose()`). Testy v [test/bus_scan_test.dart](test/bus_scan_test.dart) (withUpdatedAddress, containsAddress, ghost-stays) + SCAN-DEVICES scanId v `command_service_devices_test.dart`. Návod sjednocen. (7) **Obnoven broadcast pro text displejů.** Nový FW nově `SET-DATA` na DISP `050000` (broadcast) přijímá → „AHOJ na všechny" / „Smazat text na všech" (`_bulkDisp`) zase posílají **jeden** příkaz na adresu 0 místo postupného rozesílání (revert části v2.71). **POZOR — asymetrie FW:** broadcast `050000` funguje jen pro `SET-DATA`, **NE pro `SET-CONFIG`** (jas → stále `Code:-2 "unknown ID"`), takže `sendBulkBrightness` (jas displejů) **zůstává per-display** se 100ms pauzou. `sendDispData(dispAddress:0)` = broadcast (hláška „všechny displeje"). „Adresa na každý displej" zůstává per-display (různá data).
- v2.73: **PUM-A 0–4 tlačítka (nové adresování přes offsety).** PUM-A nově umí až 4 tlačítka okolo displeje (2 vlevo, 2 vpravo) místo dřívějších 0/1/2. Adresa tlačítka = `offset + N` (N = adresa DISP), **číslo tlačítka 0–3 = tisícová číslice** (`offset/1000`): vnitřní pravé `0` (holé N), vnitřní levé `1` (1000+N), vnější pravé `2` (2000+N), vnější levé `3` (3000+N). Fyzicky zleva doprava `3·1·DISPLEJ·0·2`. Model: `enum PumaButton` + `PumaButtonExt` a `Set<PumaButton> buttons` místo `buttonCount`/`buttonSide` ([module.dart](lib/models/module.dart)); `fromJson` migruje starý formát (1tl. levé→1, pravé→0, 2tl.→{0,1}) kvůli uloženým šablonám. Rekonstrukce ([module_reconstruction.dart](lib/services/module_reconstruction.dart)) nárokuje za DISP `{N,1000+N,2000+N,3000+N}`; **disambiguace vs PUM-C přes přítomnost DISP** (PUM-A má vždy DISP na N, PUM-C nikdy; offsety 2000/3000 jsou výhradně PUM-A). PUM-B i **PUM-C beze změny**. Modal „Přidat device" ([add_module_dialog.dart](lib/widgets/add_module_dialog.dart)): vizuální řada 5 dlaždic `3·1·DISPLEJ·0·2`, 4 nezávislé toggly s číslem + popiskem strany + **4-cifernou živou adresou** (`0133`/`1133`/`2133`/`3133`), DISPLEJ statický uprostřed; `IntrinsicHeight` (stretch ve scroll view). Flash stisku ([app_state.dart](lib/providers/app_state.dart) `_handleBtnUpdate`, [unit_detail_screen.dart](lib/screens/unit_detail_screen.dart) `_PressFlash`): `číslo=addr~/1000`, `base=addr%1000`, levá hrana {1,3} / pravá {0,2}, v zazářené hraně se zobrazí **číslo tlačítka**. Testy přepsané + nové (4 tl., offsety 2000/3000, disambiguace, render modalu [test/add_module_dialog_test.dart](test/add_module_dialog_test.dart)). `widget_test.dart` přepsán ze stale šablonového testu na smoke test splash→přechod. Návod + CLAUDE.md sjednoceny.
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
