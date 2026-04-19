# Plán: P2L Tester - Flutter aplikace pro testování Pick to Light jednotek

## Context
Testovací aplikace pro ~70 P2L jednotek komunikujících přes MQTT. Jednotky mají 8 portů (0-7) s LED pásky (až 600 LED/port). Aplikace musí:
- Připojit se k MQTT brokeru (např. `mqtt.lekarna.smartci4.com:1883`, TCP bez WebSocket)
- Objevit živé jednotky přes ALIVE zprávy (každých 5 min)
- Ručně ověřit jednotku (get_param)
- Odeslat testovací LED pattern na vybrané jednotky
- Fungovat na Windows, Android, iOS (mobile-first)

## Technologie
- **Flutter** (Dart) - cross-platform (Windows, Android, iOS)
- **mqtt_client** - Dart MQTT balíček, přímé TCP spojení
- **provider** - state management
- **shared_preferences** - lokální ukládání nastavení
- Žádná databáze

## MQTT Komunikace

### Topicy
| Akce | Topic | Směr |
|------|-------|------|
| Příkaz na jednotku | `I/<unit_id>/P2L/TESTER/CMD` | App → Broker |
| ALIVE od jednotky | `D/+/UNIT/+/ALIVE` | Broker → App |
| Odpověď get_param | `A/SERVER/+/CMD` | Broker → App |

### Testovací LED pattern
```json
{
  "request_id": -1,
  "cmds": [
    {"cmd": "clr_strips"},
    {"cmd": "set_leds", "args": {"port": 0, "x1": 0, "x2": 599, "style_id": 0, "colors_id": [0,0,0,6,6,6,6,6,6,6,6,6,6]}},
    ... (port 1-7 stejně)
  ]
}
```
Pattern `[0,0,0,6,6,6,6,6,6,6,6,6,6]` = 3× červená, 10× černá, opakuje se.

## Struktura projektu
```
p2l_tester/
├── lib/
│   ├── main.dart
│   ├── models/unit.dart
│   ├── services/mqtt_service.dart
│   ├── services/command_service.dart
│   ├── providers/app_state.dart
│   └── screens/
│       ├── home_screen.dart
│       └── settings_screen.dart
├── pubspec.yaml
└── README.md
```

## Implementační kroky
1. Založení Flutter projektu + dependencies
2. MQTT Service (mqtt_client)
3. Command Service (generování JSON příkazů)
4. State Management (provider)
5. Settings Screen
6. Home Screen (seznam jednotek, test, clear)
7. Build & Test

---

## Fyzická topologie: RS485 daisy-chain

Jednotka (P2L modul) komunikuje s devices přes **RS485 sběrnici zapojenou do série (daisy-chain)**:

```
[P2L jednotka] ──kabel── [device 1] ──kabel── [device 2] ──kabel── ... ──kabel── [device N]
```

- Všechny devices sdílejí jednu RS485 sběrnici
- Jednotka adresuje device podle jeho **chip number** (vypáleného v čipu), ne podle fyzické pozice v řetězci
- Pozice v řetězci **není z `GET-DEVICES` zjistitelná** — protokol pracuje jen s čipy
- Pokud chce UI zobrazovat fyzické pořadí, musí ho uživatel zadat ručně nebo ho odvodit z pořadí scanování

## PUMA moduly — fyzická zařízení a mapování na MQTT entries

Každý **modul = 1 fyzický čip** s vypáleným číslem. Čip ale může obsluhovat více MQTT device entries (BTN/DISP/LEDS) podle své role — takže `GET-DEVICES` vrací víc záznamů, než je fyzických čipů na sběrnici. Protokol (viz README-P2L-32.md) zná jen atomické device types (BTN/DISP/LEDS/DIST/P2L/UNIT), ne pojem "modul".

**Kapacita jednotky: max 100 čipů (=modulů)**. Počítají se moduly, ne MQTT entries. PUM-A s displejem + levým tlačítkem + LEDS = 1 čip (ne 3).

### Přehled modulů

| Modul | Popis | Samostatně? | Počet čipů | MQTT entries (1 čip pokrývá víc rolí) |
|---|---|---|---|---|
| **PUM-A** @N | displej + 0/1/2 tlačítka + volit. LEDS | ano | 1 | DISP `N` + volit. LEDS `N`; tlačítka viz níže |
| **PUM-B** @N | samostatné tlačítko (1) | ano | 1 | BTN `N` (holé, bez prefixu) |
| **PUM-C** @M | **vždy** 2 tlačítka +/− (nikdy jen jedno), fyzicky připojeno k PUM-A | NE — jen doplněk k PUM-A, který nemá 2 tlačítka | 1 | BTN `1000+M` (+), BTN `M` (−, bez prefixu!) |
| **DIST** @N | sensor vzdálenosti | ano | 1 | DIST `N` |

### PUM-A tlačítka podle počtu

| Počet tlačítek | MQTT BTN entries |
|---|---|
| 0 | žádné |
| 1 | `BTN N` (stejné číslo jako displej, bez prefixu, strana se nerozlišuje) |
| 2 | `BTN 1000+N` (levé) + `BTN 2000+N` (pravé) |

Prefixy 1000/2000 slouží **jen k rozlišení levé/pravé** když jsou tlačítka dvě. Při jednom tlačítku prefix odpadá a BTN sdílí číslo s DISP.

### Klíčová pravidla a nekonzistence

- **PUM-A s 2 tl.: pravé = `2000+N`**, ale **PUM-C pravé (mínus) = `M`** (bez prefixu). Není to univerzální pravidlo "vlevo=1000, vpravo=2000".
- **PUM-B a PUM-C mínus** jsou oba holá čísla. Rozlišit se dají jen tak, že PUM-C mínus má vždy párového brata `1000+M` (plus tlačítko).
- **LEDS** jsou fyzicky VŽDY součástí displeje v PUM-A (nikdy samostatně). Ale registrace v jednotce je volitelná — když se nepotřebují ovládat, jednotka o nich nemusí vědět.
- **DISP nikdy neexistuje mimo PUM-A** (aspoň podle aktuální znalosti).
- PUM-C má **vlastní nezávislý čip**, jeho `M` nesouvisí s `N` PUM-A, ke kterému je přilepen.
- Adresy modulů jsou **nezávislé** — PUM-A na 128, PUM-C na 130 je validní.
- **PUM-C lze zapojit JEN k PUM-A, které nemá 2 tlačítka** (tedy PUM-A má 0 nebo 1 tlačítko). PUM-C fyzicky dodá chybějící tlačítka. Kombinace PUM-A se 2 tlačítky + PUM-C vedle je neplatná.

### Rekonstrukce fyzických modulů z `GET-DEVICES`

```
1. pro každý DISP N v payloadu:
   → vytvoř PUM-A @N
   → má-li BTN N (a NEmá-li 1000+N ani 2000+N)  → s 1 tlačítkem
   → má-li BTN 1000+N a BTN 2000+N               → s 2 tlačítky (L, R)
   → má-li LEDS N                                 → LEDS registrovány

2. pro každou dvojici (BTN 1000+M, BTN M) kde DISP M NEEXISTUJE:
   → PUM-C @M

3. zbylé osamocené BTN N bez DISP N a bez páru 1000+N:
   → PUM-B @N

4. DIST entries → samostatné DIST sensory
```

**Rozlišení BTN N**: je-li v seznamu DISP N → PUM-A s 1 tlačítkem. Není-li → PUM-B (nebo mínus od PUM-C, pokud existuje párové 1000+N).

### Příklad: PUM-A (128) + PUM-C (130) + PUM-B (200)

`ADD-DEVICES` payload:
```jsonc
[
  {"Type":"BTN",  "Id":[128, 1130, 130, 200]},
  {"Type":"DISP", "Id":[128]},
  {"Type":"LEDS", "Id":[128]}
]
```

Rozpis:
- PUM-A @128: DISP 128, BTN 128 (jedno tlačítko), LEDS 128 osazeno
- PUM-C @130: BTN 1130 (+), BTN 130 (−) — přilepeno k PUM-A 128
- PUM-B @200: BTN 200 (samostatné tlačítko)

Celkem **3 čipy** z povolených 100.

## Workflow výměny vadného device

- Vadný device se fyzicky vymění za nový s unikátní default adresou čipu.
- **DIST**: default nového = 127 (rozsah 0–126).
- **DISP**: default nového = 247 (rozsah 127–246).
- Jednotce se pošle `REPLACE-FROM` s `{"Id": default_adresa_nového}` na topic vadného device → jednotka přečipuje nový na ID původního.
- Podporováno od FW `P2L_06033101NT+`.
- README nedokumentuje `REPLACE-FROM` pro BTN a LEDS — nejasné, jestli funguje i tam.

## UI požadavky pro správu device v jednotce

- **Detail jednotky** se seznamem modulů rekonstruovaných z `GET-DEVICES` (PUM-A/B/C + DIST)
- **Počítadlo čipů** X / 100
- **Akce "Vyměnit"** u každého modulu — dialog, který pošle `REPLACE-FROM`
- **Akce "Přidat modul"** — dialog s výběrem typu (PUM-A konfigurace / PUM-B / PUM-C / DIST) a adresy, validace kapacity a podmínek (PUM-C jen k PUM-A bez 2 tlačítek)
- Využití stávajícího **offline filtru** z nedávných commitů pro vizualizaci nedostupných device
