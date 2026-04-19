# Typy připojení – P2L Tester

## 1. Cloud server + mobil na mobilních datech

```
Mobil (mobilní data)
    │
    │  HTTPS (port 443)
    ▼
┌──────────────────────────┐
│   Cloud server           │
│                          │
│  Nginx                   │
│   ├─ /     → Flutter web app (statické soubory)
│   └─ /ws   → MQTT WebSocket proxy
│                          │
│  MQTT broker (Mosquitto) │
│   ├─ TCP  1883           │
│   └─ WS   9001          │
└──────────────────────────┘
    ▲
    │  MQTT (TCP 1883)
    │
  Jednotky zákazníka
```

- Na cloud serveru běží Nginx, který servíruje Flutter web app a proxyuje WebSocket na MQTT broker.
- Zákazník otevře `https://app.domena.cz` na mobilu — vše běží v prohlížeči.
- Aplikace se přes WebSocket připojí k MQTT brokeru a ovládá jednotky.
- Jednotky se připojují klasicky přes MQTT TCP.

---

## 2. On-premise server + mobil na Wi-Fi (stejná síť)

```
Mobil (Wi-Fi 192.168.1.x)
    │
    │  HTTP (port 80)
    ▼
┌──────────────────────────┐
│  On-premise server       │
│  (192.168.1.10)          │
│                          │
│  Nginx                   │
│   ├─ /     → Flutter web app
│   └─ /ws   → MQTT WebSocket proxy
│                          │
│  MQTT broker             │
│   └─ WS 9001            │
└──────────────────────────┘
    ▲
    │  MQTT (TCP 1883)
    │
  Jednotky (stejná síť)
```

- Identické řešení jako cloud, ale běží lokálně u zákazníka.
- Zákazník na mobilu otevře `http://192.168.1.10` (IP serveru v lokální síti).
- Není potřeba veřejná doména ani HTTPS (volitelně lze přidat self-signed certifikát).

---

## 3. Notebook jako dev server (vývoj/testování)

```
Mobil (Wi-Fi)
    │
    │  HTTP (port 8080)
    ▼
  Notebook (192.168.1.50)
    │
    │  flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0
```

- Pro vývoj a testování — Flutter dev server na notebooku.
- Mobil i notebook musí být na stejné Wi-Fi.
- Firewall na notebooku musí povolit port 8080.

---

## Požadavky pro web verzi

- **MQTT broker** musí mít povolený **WebSocket listener** (port 9001 nebo 8083).
- **Flutter web app** na webu používá WebSocket místo TCP pro MQTT komunikaci.
- Aplikace musí detekovat platformu (web vs. nativní) a zvolit správný typ MQTT klienta.
