# MQTT Topics – P2L Tester

## Subscribe (příjem zpráv)

| Topic | Kdy | Co obsahuje |
|-------|-----|-------------|
| `D/+/UNIT/+/ALIVE` | Ihned po připojení | Pravidelné hlášení jednotky (každých ~5 min). Obsahuje firmware, battery, HWModel. Podle tohoto topicu se jednotky **automaticky objevují** v seznamu. |
| `A/SERVER/+/CMD` | Ihned po připojení | Odpověď na příkaz `get_param`. Obsahuje detailní info: IP, MAC, firmware, ID portů. |

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
| Připojení – subscribe | `D/+/UNIT/+/ALIVE` + `A/SERVER/+/CMD` |
| TEST (stará jednotka) | `I/u<4dig>/SERVER/CMD` (JSON) |
| TEST (nová, OLD mode) | `I/<6dig>/P2L/01<4dig>/CMD` (JSON) |
| TEST (nová, BIN mode) | `I/<6dig>/P2L/01<4dig>/CMD` (JSON: clr_strips) + `I/<6dig>/UNIT/<6dig>/BIN` (binary) |
| CLEAR | `I/u<4dig>/SERVER/CMD` nebo `I/<6dig>/P2L/01<4dig>/CMD` (JSON: clr_strips) |
| SCAN / Get Param | `I/u<4dig>/SERVER/CMD` nebo `I/<6dig>/P2L/01<4dig>/CMD` (JSON: get_param) |

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

| Kód | Typ |
|-----|-----|
| `00` | UNIT (jednotka samotná) |
| `01` | P2L (LED pásky) |
| `04` | DIST (senzor vzdálenosti) |
| `05` | DISP (displej PUMA) |
| `11` | LEDS (PUMA LED) |
