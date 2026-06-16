# MQTT Topics – P2L Tester

## Subscribe (příjem zpráv)

| Topic | Kdy | Co obsahuje |
|-------|-----|-------------|
| `D/+/UNIT/+/ALIVE` | Ihned po připojení | Pravidelné hlášení jednotky (každých ~5 min). Obsahuje firmware, battery, HWModel. Podle tohoto topicu se jednotky **automaticky objevují** v seznamu. |
| `A/SERVER/+/CMD` | Ihned po připojení | Odpověď na příkaz `get_param`. Obsahuje detailní info: IP, MAC, firmware, ID portů. |
| `O/+/UNIT/+/GET-DEVICES` | Ihned po připojení | Seznam atomických devices na sběrnici (P2L32) — vstup pro rekonstrukci PUM-A/B/C. |
| `O/+/UNIT/+/{ADD,RECREATE,DELETE}-DEVICES` | Ihned po připojení | Potvrzení device-management operací. |
| `O/+/UNIT/+/DEVICE-REPLACE` | Ihned po připojení | Potvrzení výměny vadného device (nový FW, UNIT-level). |
| `O/+/UNIT/+/DEVICE-SET-ID` | Ihned po připojení | Potvrzení přečíslování device (nový FW, UNIT-level). |

### Příklad ALIVE payloadu
```json
{"HWModel":"Unit32","firmware":"25092501NT","battery":100,"Level":"INFO","Code":0,"Message":"OK"}
```

### Příklad get_param odpovědi
```json
{"cmd":"get_param","args":{"id":"001017","firmware":"25092501NT","ip":"192.168.1.50","mac":"AA:BB:CC:DD:EE:FF"}}
```

---

## Publish (odesílání příkazů)

### Stará jednotka (ID < 1000, např. 472)

| Topic | Formát | Příklad |
|-------|--------|---------|
| `I/u<4digit>/SERVER/CMD` | JSON | `I/u0472/SERVER/CMD` |

- ID se ořízne na číslo a doplní na 4 cifry s nulami vlevo
- Vždy JSON formát (`buildTestCommand`, `buildClearCommand`, `buildGetParamCommand`)
- BIN formát **nepodporován** (starý firmware)

---

### Nová jednotka (ID ≥ 1000, např. 1017)

#### JSON příkaz (OLD mode nebo FW < 250925)

| Topic | Formát | Příklad |
|-------|--------|---------|
| `I/<6digit>/P2L/01<4digit>/CMD` | JSON | `I/001017/P2L/011017/CMD` |

- Unit ID se doplní na 6 číslic vlevo nulami: `1017` → `001017`
- `01` = kód zařízení P2L, za ním posledních 5 číslic ID: `1017` → `01017`... ne, přesně: `01` + poslední 4 cifry: `1017` → `011017`

#### BIN příkaz (FW ≥ P2L_25092501NT)

| Topic | Formát | Příklad |
|-------|--------|---------|
| `I/<unit_id>/UNIT/<unit_id>/BIN` | binární | `I/001017/UNIT/001017/BIN` |

- Nejprve se pošle `clr_strips` přes JSON CMD topic
- Pak `set_leds` data přes BIN topic jako binární payload
- BIN payload = sekvence `[0x03][port][x1_lo][x1_hi][x2_lo][x2_hi][style][count][color1]...[colorN]` × 8 portů, zakončeno `0x00`

---

## Souhrn podle akce

| Akce | Topic(s) |
|------|----------|
| Připojení – subscribe | `D/+/UNIT/+/ALIVE` + `A/SERVER/+/CMD` + `O/+/UNIT/+/{GET,ADD,RECREATE,DELETE}-DEVICES` + `O/+/UNIT/+/{DEVICE-REPLACE,DEVICE-SET-ID}` |
| TEST (stará jednotka) | `I/u<4dig>/SERVER/CMD` (JSON) |
| TEST (nová, OLD mode) | `I/<6dig>/P2L/01<4dig>/CMD` (JSON) |
| TEST (nová, BIN mode) | `I/<6dig>/P2L/01<4dig>/CMD` (JSON: clr_strips) + `I/<6dig>/UNIT/<6dig>/BIN` (binary) |
| CLEAR | `I/u<4dig>/SERVER/CMD` nebo `I/<6dig>/P2L/01<4dig>/CMD` (JSON: clr_strips) |
| SCAN / Get Param | `I/u<4dig>/SERVER/CMD` nebo `I/<6dig>/P2L/01<4dig>/CMD` (JSON: get_param) |
| GET-DEVICES / device management | `I/<6dig>/UNIT/<6dig>/{GET-DEVICES,ADD-DEVICES,RECREATE-DEVICES,DELETE-DEVICES}` |
| Výměna vadného device (nový FW) | `I/<6dig>/UNIT/<6dig>/DEVICE-REPLACE` (JSON: `{"From":<default>,"To":<vadný>}`) |
| Přečíslování device (nový FW) | `I/<6dig>/UNIT/<6dig>/DEVICE-SET-ID` (JSON: `{"From":<stará>,"To":<nová>}`) |
| Firmware OTA (`update`) | `I/u<4dig>/SERVER/CMD` nebo `I/<6dig>/P2L/01<4dig>/CMD` (JSON: update) |
| Hromadná změna brokera/WiFi/jasu | `I/u<4dig>/SERVER/CMD` nebo `I/<6dig>/P2L/01<4dig>/CMD` (JSON: set_Mqtt / set_WiFi / set_brightness) |

---

## Logika volby formátu

```
unitId >= 1000 ?
  ├─ NE  → stará jednotka → I/u<4dig>/SERVER/CMD  (vždy JSON)
  └─ ANO → nová jednotka
              └─ firmware >= 250925 ?
                    ├─ NE  → I/<6dig>/P2L/01<4dig>/CMD  (JSON)
                    └─ ANO → uživatel může přepnout BIN/OLD
                                ├─ OLD → I/<6dig>/P2L/01<4dig>/CMD  (JSON)
                                └─ BIN → CMD (clr) + BIN (set_leds)
```

---

## Kód zařízení v topic (nový formát)

DEVICE_ID = 2-ciferný kód typu + 4-ciferná adresa (např. `050246` = DISP @246).

| Kód | Typ |
|-----|-----|
| `00` | UNIT (jednotka samotná) |
| `01` | P2L (LED pásky / test příkazy) |
| `04` | DIST (senzor vzdálenosti) |
| `05` | DISP (displej PUM-A) |
| `06` | BTN (tlačítko rodiny PUMA) |
| `11` | LEDS (PUMA LED) |

> **Pozn.:** DISP (`05`) i BTN (`06`) patří do rodiny PUMA, ale mají **vlastní prefix** (potvrzeno firmwarem i reálným tracem — BTN ALIVE `D/<unit>/BTN/06<addr>/ALIVE`). Adresné device příkazy (SET-DATA, SET-CONFIG, SET-LEDS…) používají `DeviceTypeExt.addressPrefix` v [lib/models/device.dart](lib/models/device.dart).

---

## Výměna a přečíslování device (nový FW, od v2.67)

Nový firmware řeší obě operace **UNIT-level příkazy** — typ device ani per-device topic se neřeší, firmware přemapuje celý fyzický čip podle adres.

| Operace | Topic | Payload | Odpověď |
|---------|-------|---------|---------|
| Výměna vadného | `I/<6dig>/UNIT/<6dig>/DEVICE-REPLACE` | `{"From":<factory default nového>,"To":<adresa vadného>}` | `O/<6dig>/UNIT/<6dig>/DEVICE-REPLACE` `{"Code":0,"Message":"OK"}` |
| Přečíslování | `I/<6dig>/UNIT/<6dig>/DEVICE-SET-ID` | `{"From":<stará>,"To":<nová>}` | `O/<6dig>/UNIT/<6dig>/DEVICE-SET-ID` `{"Code":0,"Message":"OK"}` |

Factory default adresy (= horní mez rozsahu typu): PUM-A/DISP **246**, PUM-B/PUM-C/BTN **247**, DIST **127**. Po `{"Code":0}` aplikace automaticky pošle `GET-DEVICES`. (Starší firmware používal per-device `REPLACE-FROM` — appka už ho neobsluhuje. Viz [README-P2L-32.md](README-P2L-32.md) a [CLAUDE.md](CLAUDE.md).)
