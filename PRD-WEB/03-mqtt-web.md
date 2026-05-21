# 03 — MQTT klient na webu

> **Status:** Draft v0.1 · **Datum:** 2026-05-21 · **Parent:** [01-PRD.md](01-PRD.md)

Technický deep-dive na zprovoznění MQTT komunikace v prohlížeči. Toto je nejtěsnější technické místo celého projektu — pokud tady něco nesedí, web verze nefunguje.

---

## 1. Současný stav

`MqttService` ([lib/services/mqtt_service.dart](../lib/services/mqtt_service.dart)) používá `MqttServerClient` z balíčku `mqtt_client`. Ten dělá **TCP connection** (typicky port 1883 / 8883 TLS). V prohlížeči **TCP socket není dostupný** — browser umí jen HTTP a WebSocket.

`mqtt_client` má pro web alternativu **`MqttBrowserClient`**, která místo TCP otevírá WebSocket.

---

## 2. Conditional imports — pattern

Flutter Web target neumí importovat `dart:io` a `mqtt_client`'s `MqttServerClient` se na ní spoléhá. Řešení: **conditional import**.

```dart
// lib/services/mqtt_client_factory.dart
import 'mqtt_client_factory_stub.dart'
    if (dart.library.io) 'mqtt_client_factory_io.dart'
    if (dart.library.html) 'mqtt_client_factory_web.dart';

abstract class MqttClientFactory {
  static MqttClient create({
    required String host,
    required int port,
    required String clientId,
    required bool useTls,
  }) => createPlatform(host: host, port: port, clientId: clientId, useTls: useTls);
}
```

```dart
// lib/services/mqtt_client_factory_io.dart
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

MqttClient createPlatform({
  required String host,
  required int port,
  required String clientId,
  required bool useTls,
}) {
  final client = MqttServerClient.withPort(host, clientId, port);
  client.useWebSocket = false;
  client.secure = useTls;
  return client;
}
```

```dart
// lib/services/mqtt_client_factory_web.dart
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';

MqttClient createPlatform({
  required String host,
  required int port,
  required String clientId,
  required bool useTls,
}) {
  final scheme = useTls ? 'wss' : 'ws';
  final url = '$scheme://$host/mqtt';
  final client = MqttBrowserClient.withPort(url, clientId, port);
  return client;
}
```

```dart
// lib/services/mqtt_client_factory_stub.dart  (fallback, neměl by se volat)
import 'package:mqtt_client/mqtt_client.dart';

MqttClient createPlatform({
  required String host,
  required int port,
  required String clientId,
  required bool useTls,
}) => throw UnsupportedError('No MqttClient impl for this platform');
```

`MqttService` pak používá factory místo přímého `MqttServerClient`.

---

## 3. WebSocket URL formát

`MqttBrowserClient` vyžaduje **plnou WS URL**, ne jen hostname:

- `ws://broker.example.com:8083/mqtt` (plaintext, port 8083 / 9001 typicky)
- `wss://broker.example.com:8884/mqtt` (TLS, produkce)

**Path `/mqtt`** je Mosquitto default pro `listener ws`. Některé brokery používají `/` — to je potřeba zjistit per broker (viz [open question §9.4 v 01-PRD.md](01-PRD.md#94-mosquitto-userpassword-vs-anonymous)).

### Mosquitto config (broker side, pro referenci)

```
listener 9001
protocol websockets

listener 8884
protocol websockets
cafile /etc/letsencrypt/live/<domain>/fullchain.pem
certfile /etc/letsencrypt/live/<domain>/cert.pem
keyfile /etc/letsencrypt/live/<domain>/privkey.pem
```

Nebo (doporučené pro produkci) WSS terminace v Nginx jako reverse proxy → Mosquitto plain WS na localhost.

---

## 4. Klíčové risk-body

### 4.1 Mixed content (HTTPS → ws://)

Pokud aplikace běží na `https://...` a snaží se otevřít `ws://broker:9001/mqtt`, **prohlížeč spojení odmítne** (mixed content). Jediné řešení: **WSS s validním certifikátem**.

**Mitigation:**
- Vyžadovat WSS endpoint od brokeru pro každý profil v produkci.
- Pro lokální vývoj: `mkcert` na localhost broker.

### 4.2 Browser CORS

MQTT WebSocket connect podléhá CORS. Mosquitto sám **CORS hlavičky neumí nastavit**. Cesty:

- **A:** Nginx jako reverse proxy před Mosquitto WS (`/ws` → `ws://localhost:9001/mqtt`) + `add_header Access-Control-Allow-Origin <origin>`.
- **B:** Když broker servíruje na stejné doméně jako frontend, CORS neřešíme (same-origin).

**Pro Vercel staging:** broker MUSÍ explicitně povolit Vercel preview origin (`*.vercel.app`). To je nejpravděpodobnější místo, kde uvázneme. → otestovat v M2.

### 4.3 `dart:io` použití mimo `MqttService`

Code search potřebný — typická místa:
- `Platform.isWindows`, `Platform.isAndroid` v UI logice.
- `File` / `Directory` v export/import služby.
- `HttpClient` (firmware listing) — `http` package je už OK, ale ověřit.

**Mitigation:** obalit všechny `dart:io` použití kontrolou `kIsWeb` (`package:flutter/foundation.dart`) nebo conditional importem.

### 4.4 In-memory state se ztratí při refreshi

MQTT klient drží state v paměti (`_units`, subscriptions, broker connection). Refresh stránky všechno smaže.

**Mitigation:**
- Po reload → znovu `connect()` k brokeru z aktivního profilu.
- ID jednotek persistovat (už persistované v `SharedPreferences` přes `unit_ids_io`).
- Akceptovat, že seznam aktivních jednotek se zaplní z nových ALIVE / `get_param`.

### 4.5 Concurrent tabs

Pokud uživatel otevře web ve dvou tabech, každý si otevře vlastní MQTT klient connection. Broker pak vidí 2 klienty se stejným `clientId` → odpojuje předchozího.

**Mitigation:** generovat `clientId` per tab (např. `p2l-web-${randomId}`) místo per uživatel.

---

## 5. Test plán pro M2

1. Spustit Mosquitto lokálně s `listener 9001` (plain WS).
2. `flutter run -d chrome` → connect na `ws://localhost:9001/mqtt`.
3. Ověřit subscribe `D/+/UNIT/+/ALIVE`.
4. Ověřit publish `I/...CMD`.
5. Spustit `mkcert` + `listener 9002` (WSS) → otestovat WSS connect.
6. Otestovat reconnect po network drop.
7. Otestovat refresh stránky (full reconnect cyklus).

---

## 6. Webově specifické edge cases

| Edge case | Co dělat |
|-----------|----------|
| Tab v background (browser throttling) | `mqtt_client` má keep-alive — ověřit, že timer běží dál (browsers throttlují JS timery v hidden tabs na 1×/sec; MQTT ping každých 60s to ustojí) |
| Network change (Wi-Fi ↔ data) | `mqtt_client` má auto-reconnect — povolit `autoReconnect = true` |
| User zavře tab uprostřed publish | Akceptovatelná ztráta, není transakční |
| Service worker / PWA | Out of scope MVP |

---

## 7. Závislosti

`mqtt_client` v `pubspec.yaml` už je. Pravděpodobně netřeba nic přidávat — `MqttBrowserClient` je součást stejného balíčku.

Ověřit verzi:
```bash
flutter pub deps --no-dev | grep mqtt_client
```

Pokud verze < 10.0, zvážit upgrade — novější verze mají lepší web support.

---

## 8. Akceptační kritéria

- [ ] `MqttClientFactory` s conditional importem funguje na native i web.
- [ ] Web build se připojí k testovacímu brokeru přes WS i WSS.
- [ ] Subscribe + publish funguje, ALIVE zprávy přicházejí.
- [ ] Reconnect po network drop funguje.
- [ ] Po refresh stránky se aplikace připojí znovu bez user akce.
- [ ] Žádné `dart:io` runtime erroru ve web buildu (zkontrolovat browser console).
