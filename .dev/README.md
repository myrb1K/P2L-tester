# .dev/ — lokální vývojová infrastruktura

Tato složka obsahuje konfigurace pro lokální vývoj webové varianty P2L Testeru (branch `WEB`).

## Mosquitto broker

[`mosquitto.conf`](mosquitto.conf) — konfigurace lokálního Mosquitto brokera s dvěma listenery:
- **1883** plain TCP MQTT (paralelně pro Windows/Android verzi appky)
- **9001** plain WebSockets (pro Flutter Web build)

### Instalace (jednou)

```powershell
winget install --id EclipseFoundation.Mosquitto --source winget
```

### Spuštění

Z root projektu v PowerShellu:

```powershell
& "C:\Program Files\mosquitto\mosquitto.exe" -c .dev\mosquitto.conf -v
```

Mosquitto bude logovat do konzole. Ukončení: `Ctrl+C`.

### Test z MQTTX

| Pole | TCP test | WS test |
|------|----------|---------|
| Name | `LOCAL-TCP` | `LOCAL-WS` |
| Host scheme | `mqtt://` | `ws://` |
| Host | `localhost` | `localhost` |
| Port | `1883` | `9001` |
| Path | — | `/mqtt` |
| SSL/TLS | OFF | OFF |
| Username / Password | (prázdné) | (prázdné) |

### Použití pro M2 (MQTT na webu)

1. Spustit Mosquitto (viz výše).
2. Spustit Flutter Web: `flutter run -d chrome --web-port 5555`.
3. V appce vytvořit broker profil: `ws://localhost:9001/mqtt`.
4. Connect → publish/subscribe.

## Bezpečnost

`allow_anonymous true` — **jen pro lokální dev**. NEPOUŽÍVAT na veřejně dostupných serverech.
