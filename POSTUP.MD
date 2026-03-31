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
