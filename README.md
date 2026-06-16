# P2L Tester

Flutter aplikace pro testování a konfiguraci **P2L hardware modulů** (Pick-to-Light) přes MQTT. Slouží jako diagnostický nástroj pro ~70 jednotek se 4–8 LED porty (až 600 LED/port), modulů PUM-A/B/C a senzorů DIST.

Aktuální verze: viz `appVersion` v [lib/main.dart](lib/main.dart). Verze se zvedá až při commitu user-facing změny (ne automaticky po každé editaci).

---

## Obsah

1. [Funkce](#funkce)
2. [Technologický stack](#technologický-stack)
3. [Spuštění a build](#spuštění-a-build)
4. [Architektura kódu](#architektura-kódu)
5. [MQTT komunikace](#mqtt-komunikace)
6. [Hardware topologie a PUMA moduly](#hardware-topologie-a-puma-moduly)
7. [Workflow výměny vadného device](#workflow-výměny-vadného-device)
8. [Typy nasazení](#typy-nasazení)
9. [Reference](#reference)

---

## Funkce

- **Automatické objevování jednotek** přes ALIVE topic (`D/+/UNIT/+/ALIVE`).
- **Testovací LED pattern** (volitelné porty, barva, doba on/off) — JSON i BIN formát.
- **Detail jednotky** s rekonstruovaným seznamem fyzických modulů PUM-A/B/C/DIST z `GET-DEVICES`.
- **Správa device topologie**: přidávat/mazat moduly, výměna vadného device (`DEVICE-REPLACE`), přečíslování device (`DEVICE-SET-ID`), aplikace šablon (`DeviceTemplate`).
- **Hromadná konfigurace** ([widgets/bulk_config_menu.dart](lib/widgets/bulk_config_menu.dart)) na vybraných jednotkách (s 100 ms pauzou mezi publish): změna brokera (`set_Mqtt`), WiFi (`set_WiFi`), jasu P2L LED (`set_brightness`) i jasu displejů PUM-A (DISP `SET-CONFIG`), aktualizace firmware (`update`), restart, aplikace šablony.
- **Hromadné nahrání firmware** — auto-discovery `*.bin` z autoindex HTML serveru ([firmware_listing_service.dart](lib/services/firmware_listing_service.dart)), base URL v `SharedPreferences`.
- **Broker profily** s drag-and-drop řazením, kontrolou duplicit a uložením v `SharedPreferences`. Volitelně MQTT přes **WebSocket** (`useWebsocket` + `wsPath`) pro brokery za firewallem / WSS.
- **Export / Import šablon** — JSON wrapper formát ([template_io.dart](lib/services/template_io.dart)), volba mezi nativním sdílením (`share_plus`) a uložením do souboru (`file_picker.saveFile`); při importu konflikty jmen řeší dialog Přepsat / Přejmenovat / Přeskočit. Export funguje i na webu (stažení přes blob, [file_export.dart](lib/services/file_export.dart)).
- **Export / Import seznamu ID** P2L modulů ([unit_ids_io.dart](lib/services/unit_ids_io.dart)) — JSON včetně volitelného broker profilu, placeholder jednotky pro ještě neodpovězená ID.
- **Filtr offline jednotek**, scanování (`get_param`), restart jednotky, vyčištění seznamu.
- **Vlastní splash screen** ([screens/splash_screen.dart](lib/screens/splash_screen.dart)) s plným Smartbox logem (1.8–2.2 s, fade transition) — nezávislé na nativním Android 12+ kruhovém splashi.
- **Cross-platform**: Windows, Android, iOS, web.

---

## Technologický stack

- **Flutter** (Dart, SDK ^3.11.4)
- **mqtt_client** ^10.6 — MQTT klient (TCP i WebSocket, native i web)
- **provider** ^6.1 — state management
- **shared_preferences** ^2.3 — lokální persistence (žádná databáze)
- **package_info_plus** ^9.0
- **http** ^1.2 — auto-discovery firmware `*.bin` z autoindex HTML
- **share_plus** ^10.1 + **file_picker** ^8.1 + **path_provider** ^2.1 — export/sdílení šablon a ID (nativní; na webu stažení přes blob)

---

## Spuštění a build

```bash
flutter pub get               # instalace závislostí
flutter run -d windows        # spuštění na Windows
flutter run -d <device>       # spuštění na připojeném zařízení / emulátoru

flutter analyze               # lint (analysis_options.yaml)
dart format lib/              # auto-format
dart fix --apply              # aplikace navržených oprav

flutter test                  # všechny testy
flutter test test/command_service_devices_test.dart   # konkrétní soubor
flutter test --coverage       # coverage report

flutter build windows --release   # Windows .exe
flutter build apk --release       # Android APK
flutter build ipa --release       # iOS app
```

Pro web s MQTT broker musí mít povolený **WebSocket listener** (typicky port 9001 nebo 8083) a aplikace volí WS klienta místo TCP.

---

## Architektura kódu

### State management
- **Provider** s jediným `ChangeNotifier` — [`AppState`](lib/providers/app_state.dart)
- Persistence: vše v `SharedPreferences` (broker profily, LED pattern, device templates, last WiFi)

### Klíčové soubory

| Vrstva | Soubor | Popis |
|--------|--------|-------|
| State | [lib/providers/app_state.dart](lib/providers/app_state.dart) | jednotky, profily, vybrané porty, device management flow, restart-after-config logika |
| MQTT | [lib/services/mqtt_service.dart](lib/services/mqtt_service.dart) | wrapper nad mqtt_client (autoReconnect, streamy, publish/subscribe) |
| Buildery | [lib/services/command_service.dart](lib/services/command_service.dart) | všechny payload buildery: `buildTestCommand`/`buildTestCommandBin`, `buildClearCommand`, `buildGetParamCommand`, `buildSetMqttCommand`, `buildSetWifiCommand`, `buildGetDevicesCommand`, `buildAddDevicesCommand`, `buildRecreateDevicesCommand`, `buildDeleteDevicesCommand`, `buildDeviceReplaceCommand`, `buildDeviceSetIdCommand`, `buildSetDispDataCommand`, `buildSetDistConfigCommand`, `buildRestartCommand` |
| Logika | [lib/services/module_reconstruction.dart](lib/services/module_reconstruction.dart) | z plochého `GET-DEVICES` (BTN/DISP/LEDS/DIST) skládá fyzické PUM-A/B/C |
| Modely | [lib/models/](lib/models/) | `unit.dart`, `module.dart` (PumaModule, ModuleType, DistConfig, ButtonSide), `device.dart` (Device, DeviceType), `device_template.dart`, `broker_profile.dart` |
| Obrazovky | [lib/screens/](lib/screens/) | `splash_screen`, `home_screen`, `settings_screen`, `unit_detail_screen`, `template_editor_screen`, `templates_screen` |
| Widgety | [lib/widgets/](lib/widgets/) | `bulk_config_menu` (hromadný set_Mqtt/set_WiFi z AppBar), `add_module_dialog`, `replace_device_dialog`, `apply_template_sheet`, `module_tile` |

### Datové modely

- **`P2LUnit`** ([models/unit.dart](lib/models/unit.dart)) — jedna fyzická jednotka. ID se ukládá bez prefixu `u`; prefix se případně doplní v MQTT topicu.
- **`PumaModule`** ([models/module.dart](lib/models/module.dart)) — fyzický modul (1 čip): PUM-A/B/C nebo DIST. Faktory: `PumaModule.pumA(...)`, `pumB`, `pumC`, `dist`. Metoda `toDevices()` rozbalí modul na atomické MQTT entries.
- **`DeviceTemplate`** — pojmenovaná konfigurace modulů pro rychlé použití (`applyTemplateToUnits` → `RECREATE-DEVICES`).
- **`BrokerProfile`** — pojmenovaný broker preset (broker, port, user, password, useSsl). Duplicitní názvy nejsou povoleny (`isProfileNameTaken`).

### Stavová logika v `AppState`

- **Auto-fetch:** první ALIVE jednotky v rámci připojení → automatický `GET-DEVICES` (`_initialFetchDone`).
- **Restart-after-config:** po `ADD-DEVICES`/`RECREATE-DEVICES` s `restartAfter=true` se pošle `RESTART`, pak se čeká na první ALIVE mimo grace window 2 s a teprve potom se znovu volá `GET-DEVICES` (`_pendingRestart`, `_awaitingAliveAfterRestart`, `_restartSentAt`, `_restartGrace`).
- **Fallback pro firmware bez `O/.../*-DEVICES` odpovědi:** po 200 ms od publish se vynutí `GET-DEVICES` (nebo restart, pokud je požadován).

### Error handling

- MQTT chyby v `_lastError`, vystavené přes `AppState.lastError`.
- Stav připojení: `AppMqttState { disconnected, connecting, connected, error }`.
- `_statusMessage` pro UI feedback (snack bary, banner).

---

## MQTT komunikace

Aplikace podporuje **dvě generace** P2L zařízení:

| Generace | ID | Topic prefix | Formáty |
|----------|-----|--------------|---------|
| Stará jednotka | `< 1000` | `I/u<4dig>/SERVER/CMD` | jen JSON |
| Nová (P2L32) | `>= 1000` | `I/<6dig>/P2L/01<4dig>/CMD` | JSON; BIN přes `I/<6dig>/UNIT/<6dig>/BIN` (FW ≥ `P2L_25092501NT`) |

### Subscribe topicy (po connectu)

| Topic | Účel |
|-------|------|
| `D/+/UNIT/+/ALIVE` | objevování jednotek + battery/firmware update |
| `A/SERVER/+/CMD` | odpověď na `get_param` (IP, MAC, firmware, ID) |
| `O/+/UNIT/+/GET-DEVICES` | seznam atomických devices (P2L32) |
| `O/+/UNIT/+/{ADD,RECREATE,DELETE}-DEVICES` | potvrzení device-management operací |
| `O/+/UNIT/+/DEVICE-REPLACE` | potvrzení výměny vadného device (nový FW) |
| `O/+/UNIT/+/DEVICE-SET-ID` | potvrzení přečíslování device (nový FW) |

### Logika volby formátu testovacího příkazu

```
unitId >= 1000?
  ├─ NE  → stará jednotka  → I/u<4dig>/SERVER/CMD (JSON)
  └─ ANO → nová jednotka
            └─ uživatel přepnul BIN mode (toggleBinMode) a FW podporuje BIN?
                  ├─ NE  → I/<6dig>/P2L/01<4dig>/CMD (JSON)
                  └─ ANO → CMD (JSON: clr_strips) + BIN (set_leds)
```

`firmwareSupportsBin()` v [command_service.dart](lib/services/command_service.dart) kontroluje, zda 6 cifer v názvu firmware ≥ `250925`.

### Kódy zařízení v topicu (P2L32)

| Kód | Typ |
|-----|-----|
| `00` | UNIT (jednotka samotná) |
| `01` | P2L (LED pásky) |
| `04` | DIST (senzor vzdálenosti) |
| `05` | DISP (displej PUM-A) |
| `06` | BTN (tlačítko rodiny PUMA) |
| `11` | LEDS (PUMA LED) |

DEVICE_ID v topicu = 2-ciferný kód + 4-ciferná adresa, např. `050246` = DISP @246. DISP (`05`) i BTN (`06`) jsou z rodiny PUMA, ale mají vlastní prefix (zdroj `DeviceTypeExt.addressPrefix`).

### Detailní reference protokolu

- [README-P2L.md](README-P2L.md) — kompletní příkazy staré jednotky: `set_leds`, `set_Mqtt`, `set_WiFi`, `set_Config`, `set_brightness`, `set_default`, `get_param`, `restart`, `update`, `upload`, `set_color`, `set_id`, `set_led_count` + příklady ALIVE/Log payloadů.
- [README-P2L-32.md](README-P2L-32.md) — protokol nové generace: UNIT (`SCAN`, `RECREATE-DEVICES`, `ADD-DEVICES`, `DELETE-DEVICES`, `GET-DEVICES`, `RESTART`, `BIN` formát), P2L (`CMD`), DIST (`SET-CONFIG` se segmenty, `REPLACE-FROM`), DISP (`SET-DATA`, `SET-CONFIG`, `REPLACE-FROM`), LEDS (`SET-LEDS`, `CLEAR-LEDS`, `SET-RGB`).
- [MQTT-TOPICS.md](MQTT-TOPICS.md) — souhrn topiců používaných aplikací včetně tabulek a logiky volby formátu.

---

## Hardware topologie a PUMA moduly

### RS485 daisy-chain

P2L jednotka komunikuje s devices přes **RS485 sběrnici v sérii**:

```
[P2L jednotka] ──kabel── [device 1] ──kabel── [device 2] ──...── [device N]
```

- Všechny devices sdílejí jednu sběrnici.
- Adresace je podle **chip number** (vypálené v čipu), ne podle fyzické pozice.
- Pozice v řetězci **není z `GET-DEVICES` zjistitelná** — protokol pracuje jen s čipy.

### Modul vs. atomické device entries

**1 modul = 1 fyzický čip.** Čip může v `GET-DEVICES` reportovat víc entries (BTN/DISP/LEDS) podle své role. Protokol zná jen atomické typy (BTN/DISP/LEDS/DIST), pojem "modul" je rekonstruovaný čistě v aplikaci.

**Kapacita jednotky: max 100 čipů** (počítají se moduly, ne MQTT entries). PUM-A s displejem + tlačítkem + LEDS = 1 čip.

### Přehled modulů

| Modul | Popis | Samostatně? | Čipů | MQTT entries |
|-------|-------|-------------|------|--------------|
| **PUM-A** @N | displej + 0/1/2 tlačítka + volit. LEDS | ano | 1 | DISP `N` + volit. LEDS `N`; tlačítka viz níže |
| **PUM-B** @N | samostatné tlačítko + volit. LEDS | ano | 1 | BTN `N` (bez prefixu) + volit. LEDS `N` |
| **PUM-C** @M | vždy 2 tlačítka (+/−), připojeno k PUM-A | NE — jen doplněk PUM-A bez 2 tlačítek | 1 | BTN `1000+M` (+), BTN `M` (−) |
| **DIST** @N | senzor vzdálenosti | ano | 1 | DIST `N` s konfigurací |

### PUM-A tlačítka

| Počet | MQTT BTN entries |
|-------|------------------|
| 0 | žádné |
| 1 | buď BTN `N` (pravé) **nebo** BTN `1000+N` (levé) — strana se ukládá v `buttonSide` |
| 2 | BTN `1000+N` (levé) + BTN `N` (pravé) |

> **Důležité:** Pravé tlačítko je vždy bez prefixu (holé `N`), levé je s `1000+`. Žádný `2000+N` se nepoužívá. Autoritativní zdroj: [`module_reconstruction.dart`](lib/services/module_reconstruction.dart) a `PumaModule.toDevices()` v [`module.dart`](lib/models/module.dart).

### Klíčová pravidla

- **PUM-B** a **PUM-C mínus** jsou oba holá `N` — rozlišit se dají jen tak, že PUM-C mínus má vždy párového brata `1000+N`.
- **LEDS** jsou fyzicky součástí PUM-A nebo PUM-B (volitelný LED kroužek na tlačítku, nikdy samostatně). V `GET-DEVICES` se objeví jen pokud je jednotka "potřebuje znát" — registrace je volitelná. PUM-B s LEDS = BTN @N + LEDS @N (rekonstrukce: BTN bez DISP páru + LEDS na stejné adrese → PUM-B s LEDS).
- **DISP** vždy znamená PUM-A.
- **PUM-C** lze zapojit JEN k PUM-A, které má 0 nebo 1 tlačítko (PUM-C dodá chybějící). Kombinace PUM-A se 2 tlačítky + PUM-C vedle je neplatná.
- Adresy modulů jsou **nezávislé** — PUM-A na 128, PUM-C na 130 je validní.

### Algoritmus rekonstrukce z `GET-DEVICES`

1. Pro každý DISP `N`: vytvoř PUM-A @N. Podle přítomnosti BTN `1000+N` / BTN `N` urči 0/1/2 tlačítek a stranu. LEDS `N` → `hasLeds=true`.
2. Pro nezabrané dvojice (BTN `1000+M`, BTN `M`) bez DISP `M` → PUM-C @M.
3. Zbylé osamocené BTN `N` → PUM-B @N.
4. Každý DIST → samostatný DIST modul s konfigurací.

Implementace v [module_reconstruction.dart](lib/services/module_reconstruction.dart).

### Příklad rekonstrukce

`ADD-DEVICES` payload:
```json
[
  {"Type":"BTN",  "Id":[128, 1130, 130, 200]},
  {"Type":"DISP", "Id":[128]},
  {"Type":"LEDS", "Id":[128]}
]
```

Rekonstrukce:
- PUM-A @128: DISP 128, BTN 128 (1 tlačítko, pravé), LEDS osazeno
- PUM-C @130: BTN 1130 (+), BTN 130 (−) — přilepeno k PUM-A 128
- PUM-B @200: samostatné tlačítko

Celkem **3 čipy** ze 100.

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

---

## Workflow výměny a přečíslování device (nový FW)

Nový FW řeší obě operace **UNIT-level příkazy** na topicu `I/<unit>/UNIT/<unit>/<CMD>` s payloadem `{"From": <z>, "To": <na>}`. Typ device ani per-device topic se už neřeší.

**DEVICE-REPLACE — výměna vadného kusu:**
- Vadný device se fyzicky vymění za nový s **factory default chip adresou** (= horní mez rozsahu daného modulu).
- Platné rozsahy adres podle typu modulu (jeden zdroj pravdy [`ModuleTypeExt.addressRange`](lib/models/module.dart), default = horní mez):
  - **PUM-A: 128–246** (default 246)
  - **PUM-B: 128–247** (default 247)
  - **PUM-C: 128–247** (default 247)
  - **DIST: 1–127** (default 127)
- Aplikace pošle `DEVICE-REPLACE` s `{"From": <default_nového>, "To": <adresa_vadného>}` → jednotka přečipuje nový na ID původního.

**DEVICE-SET-ID — přečíslování funkčního device:**
- Změna adresy existujícího device: `{"From": <stará>, "To": <nová>}`.
- V UI položka „Přečíslovat" v menu modulu (ikona `tag`).

**Společné:**
- Firmware atomicky přemapuje všechny entries v rámci 1 fyzického čipu (PUM-A: DISP + volitelně LEDS + BTN; PUM-B: BTN + volitelně LEDS; PUM-C: BTN @M + BTN @1000+M). Aplikace tedy posílá 1 příkaz na modul.
- LEDS se v UI samostatně nenabízí — vyměňují se s PUM-A / PUM-B jako celek.
- Odpověď na zrcadlovém topicu `O/<unit>/UNIT/<unit>/<CMD>`; po `{"Code":0}` aplikace automaticky pošle `GET-DEVICES`.

V kódu: `AppState.replaceDevice(...)` → `CommandService.buildDeviceReplaceCommand(...)`, `AppState.setDeviceId(...)` → `CommandService.buildDeviceSetIdCommand(...)`. UI dialogy: [widgets/replace_device_dialog.dart](lib/widgets/replace_device_dialog.dart), [widgets/set_device_id_dialog.dart](lib/widgets/set_device_id_dialog.dart).

---

## Typy nasazení

### 1. Cloud server + mobil na mobilních datech

```
Mobil ──HTTPS:443──► Cloud server (Nginx)
                       ├─ /     → Flutter web app
                       └─ /ws   → MQTT WebSocket proxy → Mosquitto (TCP 1883 / WS 9001)
                                                              ▲
                                                              │ MQTT TCP 1883
                                                         Jednotky zákazníka
```

- Nginx servíruje web build a proxyuje WS na MQTT broker.
- Zákazník otevře `https://app.domena.cz` v mobilním prohlížeči.

### 2. On-premise server + mobil na Wi-Fi

```
Mobil (Wi-Fi)──HTTP:80──► On-prem server 192.168.1.10
                            ├─ /    → Flutter web app
                            └─ /ws  → Mosquitto (WS 9001)
                                          ▲ MQTT TCP 1883
                                     Jednotky (stejná síť)
```

- Identické řešení jako cloud, jen lokálně. HTTPS volitelné (self-signed).

### 3. Notebook jako dev server

```bash
flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0
```

Mobil i notebook na stejné Wi-Fi, firewall musí povolit port 8080.

### Požadavky pro web verzi

- MQTT broker s **WebSocket listenerem** (port 9001 / 8083).
- Aplikace detekuje platformu a volí WS klienta místo TCP.

---

## Reference

- [README-P2L.md](README-P2L.md) — protokol staré P2L jednotky (autoritativní zdroj příkazů).
- [README-P2L-32.md](README-P2L-32.md) — protokol nové generace P2L32 (UNIT/DIST/DISP/LEDS).
- [MQTT-TOPICS.md](MQTT-TOPICS.md) — souhrn topiců používaných aplikací.
- [CLAUDE.md](CLAUDE.md) — pokyny pro Claude Code (assistant) při práci na repu.
- Externí firmware repo: `Smart-Product-Solution-s-r-o/p2l-modul`.
