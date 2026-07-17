# 02 — PRD: Kompletní konfigurace jednotek (GET-CONFIG, zálohy, obnova)

> **Status:** Draft v0.1 · **Datum:** 2026-07-16 · **Autor:** Radek Brym · **Branch:** `web`
>
> Navazuje na [01-PRD.md](01-PRD.md) (DB1–DB4 hotové). Vzniklo ze dvou podnětů:
> 1. Nový firmware **`P2L_26071501NT`** přidal UNIT-level `GET-CONFIG` / `SET-CONFIG` / `UPDATE`
>    ([README-P2L-32.md](../README-P2L-32.md)) — jednotka poprvé umí ohlásit svou uloženou konfiguraci.
> 2. Externí „doplňující zadání" (vygenerované jiným AI) o evidenci/zálohách/obnově — zde
>    destilované na realistické jádro; co bylo vymyšlené proti realitě FW nebo předimenzované,
>    je vyjmenováno v §1.

Tento dokument **nahrazuje §4.1 (inventář observed) a milestones DB5+ z 01-PRD.md**.
DB1–DB4 z jedničky zůstávají v platnosti beze změny.

---

## 1. Cíl a co to není

GET-CONFIG boří základní předpoklad jedničky („desired existuje, protože z jednotky se konfigurace
nedá zpětně vyčíst"). Jednotka teď umí říct, **co má uložené v NVS** i **jak reálně běží** — jediné,
co zůstává výhradně v evidenci, jsou **hodnoty tajemství** (a i ty kolega chystá zpřístupnit, viz §4).

Cíle nad rámec jedničky:

1. **Observed s rozlišením** „uloženo v jednotce" vs. „reálně běží" vs. „kde ji vidíme" (§2).
2. **Záloha kompletní konfigurace** jako očíslovaná revize s historií a diffem (§5).
3. **Obnova resetované jednotky a náhrada vadného kusu** s ověřením výsledku (§7).
4. **Přesnější drift** — místo jednoho „nesouhlasí" tři pojmenované kategorie (§6).

### Co tento projekt **není** (a co jsme ze zadání vědomě zahodili/odložili)

- **Není to enterprise CMDB.** Zůstáváme u rozšíření P2L Testeru (Flutter + `server/`).
- **Zahozeno:** šifrovaná lokální DB s klíčovým hospodářstvím, podepsané/šifrované exporty,
  role nad rámec `isAdmin`, konflikt-resoluce se zachováním obou variant, automatické zámky appky.
- **Odloženo (vyjmenované budoucí milestones, ne teď):** offline režim s frontou (§8, DB9),
  šifrování sloupců s hesly, audit každého zobrazení hesla, hromadná orchestrace pro tisíce jednotek.
- **Není to reconcile server → jednotka** — appka zůstává jediný vykonavatel (beze změny z jedničky).
- **Zadání si vymýšlelo:** sériové číslo, HW revizi, „názvy zařízení", kalibrační hodnoty — FW nic
  z toho nemá a PRD s nimi nepočítá. Sporná tvrzení (reset → `config.smartbox4you.com`, credentials
  v GET-CONFIG payloadu) jsou v §10 jako otázky na kolegu, ne jako fakta.

---

## 2. Tři vrstvy — revize definic

### 2.1 Observed nově rozlišuje tři pohledy

| Pohled | Co obsahuje | Zdroj | FW |
|--------|-------------|-------|-----|
| **Uloženo v NVS** | `mqttAddress`/`mqttPort`/`mqttUser`, `SSID`, statická `ip`/`dns`/`gateway`/`subnet`, `mqttInsec`, bool `PSWD`/`mqttPassword`/`mqttCert` | UNIT `GET-CONFIG` | ≥ `26071501NT` |
| **Reálně běží** | `actualIp`, `actualSSID` | UNIT `GET-CONFIG` | ≥ `26071501NT` |
| **Kde ji vidíme** | `seen_on_broker` (host brokeru aktivního připojení appky) | appka při každém ALIVE | všechny |

Beze změny zůstává: ALIVE → `HWModel`/`firmware`/`battery`/`last_seen`; `GET-DEVICES` → devices
(`PumaModule.toJson`); `get_param` → jedna „splácnutá" hodnota IP/SSID/broker/port/jas + LED počty
a barvy ([unit.dart](../lib/models/unit.dart) `updateFromGetParam`). Později P2L `GET-CONFIG`
(jas, `leds portN`, `colorN` — [README-P2L-32.md](../README-P2L-32.md) §P2L) jako třetí zdroj snapshotu.

Tvar UNIT GET-CONFIG odpovědi (1:1 z README, topic `O/<unit>/UNIT/<unit>/GET-CONFIG`):

```jsonc
{"Id":1001,"ver":"26071501NT","mac":"AA:BB:CC:DD:EE:FF","SSID":"ssid","PSWD":true,
 "mqttAddress":"mqtt.demo1.smartci4.com","mqttPort":1883,"mqttUser":"smartbox_user",
 "mqttPassword":true,"mqttInsec":false,"mqttCert":false,
 "ip":"10.0.0.72","dns":"10.0.0.10","gateway":"10.0.0.10","subnet":"255.255.255.0",
 "actualIp":"10.0.0.72","actualSSID":"ssid"}
```

Uložení na serveru: **celá odpověď 1:1 jako JSON** do nového sloupce `unit_config_json`
(+ `unit_config_fetched_at`) v tabulce `units` — přes existující mini-migraci
`ensureObservedColumns` ([server/db/units.js](../server/db/units.js)). Stávající skalární sloupce
(`ssid`, `mqtt_server`, `mqtt_port`, `brightness`) dál plní `get_param` (běžící stav) — nic se
nebourá, GET-CONFIG je vrstva navíc.

### 2.2 Desired — beze změny role, nová definice věty

Desired = **záměr/evidence + jediné místo s hodnotami tajemství**. Až bude credentials GET-CONFIG
(§4, DB8), půjde desired doplnit i z jednotky; do té doby vzniká výhradně odesláním z appky
(dnešní hooky v [app_state.dart](../lib/providers/app_state.dart) zůstávají).

### 2.3 Meta — jediné rozšíření

Volitelné pole **`customer`** (zákazník/instalace) — jediné převzetí z §8 zadání. Vyhledávání
v seznamu ho zahrne (dnes filtruje ID + název + umístění, [unit_db.dart](../lib/models/unit_db.dart)
`matches`).

### 2.4 UI zásady — mobil na prvním místě (platí pro celé PRD)

Obnova u zákazníka se reálně dělá z **mobilu** (technik s APK v terénu) — mobil je pro DB7
primární scénář, ne dodatek. Vizuál se **nepřekopává, evolvuje**: dnešní
[unit_db_screen.dart](../lib/screens/unit_db_screen.dart) (svislý `ListView` se sekcemi) zůstává
základem.

- **„Tři pohledy" observed ≠ tabulka se třemi sloupci.** Řádek na parametr: název (Broker, SSID,
  IP…) + až tři malé popsané hodnoty pod sebou (evidence / uloženo / běží). Shoda → jedna hodnota
  + ✓; rozepisuje se jen rozdíl. Starý FW → jedna hodnota jako dnes. **Žádný horizontální scroll.**
- **Diff revizí** = svislý seznam změn (přidáno / odebráno / změněno).
- **Obnova (§7)** = celoobrazovkový průvodce po krocích (stepper) s viditelným stavem automatu —
  ne dialog s tabulkou.
- **Revize** = obyčejný seznam (datum · autor · zdroj · poznámka).
- **Seznam jednotek: vizuálně úsporný** — počítat se stovkami záznamů. Kompaktní řádky
  (`visualDensity.compact`, vzor seznamu profilů z v2.51): jeden až dva řádky na jednotku,
  stav jako barevná tečka/mini-chip místo textu, drift jen ⚠ ikona, relativní last_seen zkráceně
  („5 m", „2 d"). Hustota má přednost před ozdobností; detail patří na kartu, ne do seznamu.
- Nové obrazovky ověřovat na úzkém displeji (~360 dp šířky) stejně jako na desktopu.

---

## 3. Starý firmware — detekce schopností a degradace

Prostupuje celým PRD. Zásada: **vrstvení, ne buď–anebo.**

- **`get_param` zůstává univerzální základ** observed (funguje na obou generacích) — dnešní chování
  se u starých jednotek nijak nezhorší. GET-CONFIG je **obohacení navrch** jen tam, kde FW umí.
- **Detekce:** stará generace (ID < 1000) → GET-CONFIG nikdy. Nová generace → podle FW verze
  z ALIVE/get_param (`YYMMDDVV` ≥ `26071501`), stejný vzor jako existující `firmwareSupportsBin`
  v [unit.dart](../lib/models/unit.dart) → nové `firmwareSupportsGetConfig`. Neznámý FW → poslat
  optimisticky; timeout bez odpovědi na `O/.../GET-CONFIG` = neumí (starý FW neznámý příkaz
  ignoruje, nic se nerozbije).
- **Degradace driftu (§6):** kategorie se počítají jen z dostupných polí; bez GET-CONFIG drift
  degraduje na dnešní porovnání evidence vs. jediná hlášená hodnota.
- **Degradace snapshotů (§5):** snapshot nese záznam úplnosti (`sources`) — částečný snapshot
  ze staré jednotky je legitimní; UI obnovy ukáže, co z něj jde obnovit.
- **Degradace obnovy (§7):** cíl se starým FW → fallback `set_Mqtt`/`set_WiFi` (statická IP, cert
  a `mqttInsec` obnovit nejdou — upozornit **před** zahájením, ne po selhání).

---

## 4. Tajemství — tri-state pravidlo

Heslo (WiFi `PSWD`, broker `mqttPassword`, cert `mqttCert`) je vždy v právě jednom ze stavů:

| Stav | Reprezentace | Význam |
|------|--------------|--------|
| **Skutečná hodnota** | string | známe a můžeme použít při obnově |
| **Nastaveno, hodnota neznámá** | `true` | jednotka potvrdila existenci, hodnotu nevydala |
| **Nenastaveno** | chybí / `false` | parametr v jednotce není |

**Závazná pravidla (převzatá ze zadání doslova):**

1. `true` **NIKDY nepřepíše** skutečnou hodnotu v DB (merge při ukládání snapshotu/observed
   zachová existující string, `true` jen potvrdí „stále nastaveno").
2. `true` se **NIKDY neposílá** do jednotky jako hodnota hesla (ani jako bool, ani jako text).
3. Diff/drift hlásí „heslo nastaveno, nelze ověřit hodnotu" — nikdy „heslo změněno".
4. Před obnovou se kontroluje, zda evidence má skutečné hodnoty potřebných hesel; pokud jen `true`,
   uživatel to vidí **před** zahájením.

**Bezpečnostní postoj zůstává MVP** (HTTPS + auth + maskování v UI + `scrubSecrets` v historii,
[server/db/units.js](../server/db/units.js)). Šifrování sloupců a audit zobrazení hesel jsou
budoucí milestones — API design (hesla nikdy v seznamech) to už dnes umožňuje doplnit bez změny klientů.

**Credentials GET-CONFIG — OVĚŘENO na jednotce 1209 (FW 26071501NT, 2026-07-17).** Kolega
mechanismus už dodal, liší se od README:
- Request s přihlašovacími údaji `{"User":"admin","Password":"smartbox"}` → odpověď obsahuje
  **skutečná hesla jako string** (`PSWD`, `mqttPassword`). Prázdný `{}` → bool „je nastaveno"
  (ověřeno oboje na 1209).
- **DHCP = prázdný string** (`ip`/`dns`/`gateway`/`subnet` = `""`), ne `"0.0.0.0"`; reálná adresa
  v `actualIp`/`actualSSID`.

**Rozhodnutí (Radek, 2026-07-17): DB5 ukládá do evidence i skutečná hesla.** Je to interní tool
a kompletní config (vč. WiFi/MQTT hesel) je potřeba pro pozdější obnovu/náhradu jednotky. Appka
proto posílá GET-CONFIG **s přihlašovacími údaji** (default `admin`/`smartbox`, přepsatelné přes
`SharedPreferences` klíče `get_config_user`/`get_config_password`) a snapshot se ukládá do
`unit_config_json` **beze změny** — žádná redakce. Na kartě jsou hesla maskovaná s okem (jako
u desired). **Ochrana je zatím jen HTTPS + auth + přístup k serveru** (žádné šifrování sloupce);
akceptovaný kompromis pro interní nasazení — kdyby to byl problém, přejde se na šifrovaný trezor
(DB8). Tri-state pravidlo (výše) platí dál pro případ, kdy jednotka vrátí jen bool (bez creds /
špatné creds): `true` nikdy nepřepíše dřív uloženou skutečnou hodnotu.

---

## 5. Snapshot konfigurace a revize

### 5.1 Snapshot

**Snapshot** = kompletní konfigurace jednotky složená z až 3 zdrojů (každý zvlášť může chybět):

```jsonc
{
  "sources": {"unitConfig": true, "devices": true, "ledConfig": false},  // co se povedlo stáhnout
  "unitConfig": { /* UNIT GET-CONFIG odpověď 1:1, viz §2.1 */ },
  "devices":    [ /* PumaModule.toJson — jako dnes devices_json */ ],
  "ledConfig":  { /* P2L GET-CONFIG (brightness, leds portN, colorN) — pozdější etapa */ }
}
```

Výslovně: **žádné sériové číslo, HW revize, názvy zařízení** — FW je nemá a nevymýšlíme je.
Skutečné hodnoty hesel snapshot obsahuje jen pokud je FW vydá (DB8); jinak bool dle §4 a obnova
si hesla bere z desired.

### 5.2 Revize

Nová tabulka v `units.db`:

```sql
CREATE TABLE unit_config_revisions (
  id TEXT PRIMARY KEY,            -- UUID generované klientem (idempotence, připraveno pro offline DB9)
  unit_id TEXT NOT NULL,
  rev INTEGER NOT NULL,           -- pořadové číslo v rámci jednotky (přiděluje server)
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  username TEXT NOT NULL,
  source TEXT NOT NULL,           -- 'get-config' | 'app' | 'restore' | 'accept'
  snapshot_json TEXT NOT NULL,    -- tvar viz §5.1
  prev_revision TEXT,             -- id předchozí revize (řetěz pro diff „co se změnilo od minula")
  note TEXT                       -- volitelný důvod od uživatele
);
CREATE INDEX idx_unit_config_revisions ON unit_config_revisions(unit_id, rev);
```

- `unit_history` zůstává pro drobné akce (desired fragmenty, meta, change-id); **revize jsou pro
  celé snapshoty**. Zdroje revize: tlačítko „Zálohovat konfiguraci" (`get-config`), dokončená
  obnova (`restore`), „Převzít skutečnost do evidence" (`accept`).
- **Retence:** posledních **N = 20** revizí na jednotku (server maže nejstarší při insertu).
- API skica: `GET /api/units/:id/revisions` (seznam bez snapshotů), `GET .../revisions/:rid`
  (detail), `POST .../revisions` (nová, idempotentní podle UUID), za auth jako zbytek
  ([server/routes/units.js](../server/routes/units.js)).

### 5.3 Diff dvou revizí

Porovnání po klíčích: **přidané / odstraněné / změněné / beze změny**; tajemství výhradně dle
tri-state pravidla §4 (bool `true` vs. string = „nelze ověřit", ne „změněno"). Diff běží v appce
(má obě revize z API); server nic nepočítá.

---

## 6. Drift v2 — tři kategorie

Nahrazuje dnešní jednoúrovňový drift (`computeDrift` v [server/db/units.js](../server/db/units.js),
`driftWarnings` v [unit_db.dart](../lib/models/unit_db.dart)) — obě strany se předělají podle
téže specifikace:

| # | Porovnání | Otázka | Data |
|---|-----------|--------|------|
| 1 | **evidence ↔ uloženo** | Dorazila naše konfigurace do NVS? | desired vs. `unitConfig` (GET-CONFIG) |
| 2 | **uloženo ↔ běží** | Statická IP nastavená, ale jede DHCP? Jiné SSID? | `ip`/`SSID` vs. `actualIp`/`actualSSID` |
| 3 | **evidence ↔ kde-žije** | Hlásí se přes jiný broker? | desired.broker vs. `seen_on_broker` (+ `mqtt_server` z get_param) |

- V seznamu jednotek zůstává **jeden souhrnný flag `drift`** (server-side, jako dnes — seznam nenese
  desired/hesla); na kartě rozepsané kategorie s lidskými popisy.
- Bez GET-CONFIG (starý FW) existuje jen kategorie 3 + dnešní porovnání proti get_param hodnotám (§3).
- Kategorie 2 je čistě observed↔observed — ukáže se i u jednotky, kterou appka nikdy nekonfigurovala.

---

## 7. Obnova a náhrada (redefinice DB5 z jedničky)

### 7.1 Obnova resetované/rozbité konfigurace (stejná jednotka: ID i MAC sedí)

Zdroj: vybraná revize (default poslední) nebo desired. Aplikace:

1. **UNIT `SET-CONFIG`** — síť + broker jedním příkazem (`SSID`/`PSWD`, `mqttAddress`/`mqttPort`/
   `mqttUser`/`mqttPassword`, `mqttInsec`, `ip`/`dns`/`gateway`/`subnet`; `"0.0.0.0"` = DHCP).
   Hesla ze skutečných hodnot (desired / DB8 snapshot) — nikdy `true` (§4). Po změně sítě/Id/certu
   se jednotka sama restartuje (README).
2. **`RECREATE-DEVICES`** — devices ze snapshotu (existující `_buildDevicesPayload`,
   [command_service.dart](../lib/services/command_service.dart)).
3. **P2L `SET-CONFIG`** — jas/LED/barvy (pozdější etapa, až bude ledConfig ve snapshotu).

**Stavový automat obnovy** (jádro — odeslání zprávy ≠ úspěch):

```
připraveno → odesláno → potvrzeno (O/ odpověď Code:0)
   → očekávané odpojení (změna brokeru NENÍ chyba)
   → čekání na ALIVE na cílovém brokeru (appka se tam musí přepojit — nabídne to)
   → kontrolní GET-CONFIG → porovnání s očekáváním
   → ověřeno | dokončeno s varováním | selhalo | nelze ověřit
```

Vzor už v appce existuje: restart-after-config čeká na první ALIVE mimo grace window
(`_pendingRestart` v [app_state.dart](../lib/providers/app_state.dart)).

### 7.2 Náhrada vadného kusu jinou jednotkou

Přenáší se jen **přenositelná** část: broker, WiFi, devices, LED; statická IP jen na dotaz
(často je vázaná na místo, ne na kus). **ID a MAC cílové jednotky se nepřepisují.** Volitelný
krok: `change-id` karty v DB, pokud má nová jednotka převzít identitu staré v evidenci
(existující `POST /change-id`).

**Kompatibilita před náhradou:** cíl musí být nová generace; FW ≥ `26071501NT` pro plnou obnovu,
jinak fallback dle §3. Porovnat FW zdroj/cíl a ukázat, co se přenese / nepřenese / nedá ověřit —
před spuštěním, se zrušitelným souhrnem.

### 7.3 Detekce resetu — NEOVĚŘENO

Zadání tvrdí: po resetu zůstane ID + MAC, broker se nastaví na `config.smartbox4you.com`, zbytek
default. **Nic z toho není v README** — heuristika „broker = config.smartbox4you.com + default
hodnoty" se smí nabízet jen jako *hint* („jednotka vypadá resetovaná"), nikdy jako automatická
akce. Závisí na odpovědích kolegy (§10); do té doby je vstupem do obnovy vždy uživatel.

---

## 8. Offline režim — skica budoucího milestone (DB9, neimplementuje se)

Technik u zákazníka bez přístupu k centrální DB: lokální cache karet + **fronta nesynchronizovaných
revizí**. Klientská UUID revizí (§5.2) už dnes zajišťují idempotenci → sync po připojení = push
fronty s dedupe podle UUID; konflikt (server má mezitím novější revizi) = obě revize vedle sebe
v řetězu + ruční volba na kartě. Žádné šifrování lokální DB v první verzi; jen upozornění v UI
„N změn čeká na synchronizaci". Výslovně: **teď se nestaví**, PRD jen zaručuje, že mu návrh
(UUID, revize jako append-only řetěz) nebude bránit.

---

## 9. Milestones (nahrazují DB5+ z jedničky)

| # | Milestone | Obsah | Závislosti |
|---|-----------|-------|------------|
| **DB5** | GET-CONFIG do observed | Appka: `firmwareSupportsGetConfig`, builder (`getUnitCommandTopic(unitId,'GET-CONFIG')`, payload `{}`), subscribe `O/+/UNIT/+/GET-CONFIG`, parser, rozšíření `pushObserved`. Server: `unit_config_json` + `unit_config_fetched_at` (via `ensureObservedColumns`), drift v2 (§6) na serveru i v appce. UI: karta se třemi pohledy observed. Fallback get_param beze změny. | DB3+DB4 (hotové) |
| **DB6** | Snapshoty a revize | Tabulka `unit_config_revisions` + endpointy (§5.2), tlačítko „Zálohovat konfiguraci" na kartě, seznam revizí, diff view (§5.3). | DB5 |
| **DB7** | Obnova a náhrada | Stavový automat (§7.1), náhrada s kontrolou kompatibility (§7.2), fallbacky pro starý FW (§3). Ověření na reálném HW. | DB6 |
| **DB8** | Skutečná hesla z jednotky | Credentials GET-CONFIG — **až kolega dodá FW + tvar** (§10). Tri-state merge do desired/snapshotů, zákaz logování credentials. | DB5 + FW |
| **DB9** *(volitelné)* | Offline cache + sync | Skica §8. | DB6 |
| **DB10** *(volitelné)* | Sync broker profilů | = původní DB6 z jedničky. | DB1 |
| **DB11** *(volitelné)* | Server-side MQTT collector | = původní DB7 z jedničky; nově by uměl i periodický GET-CONFIG → observed čerstvý 24/7. | DB2 + broker ze serveru |

---

## 10. Otázky na kolegu (FW)

1. **Credentials GET-CONFIG:** přesný tvar payloadu (`{"User":...,"Password":...}`?) a odpovědi —
   vrací hesla jako string místo bool? Kde se definují účty/oprávnění? Od jaké verze FW?
2. **Reset:** co přesně maže / zachovává / nastavuje na default? Existuje explicitní příznak
   „byla jsem resetována" (v ALIVE nebo GET-CONFIG)? Je `config.smartbox4you.com` garantovaný
   broker po resetu a jak se k němu appka autorizuje?
3. **SET-CONFIG restart:** README říká „po změně sítě/Id/certifikátu" — restartuje se i po změně
   jen MQTT credentials? Potvrzuje jednotka uložení každé části zvlášť?
4. **GET-CONFIG rozsah:** plánuje se doplnit `HWModel`/typ jednotky do odpovědi? (Teď jen v ALIVE.)
5. **Duplicitní ID:** může v praxi existovat stejné unit ID u dvou zákazníků (dva izolované
   brokery)? (Dopad na klíč karty v DB.)
6. **P2L GET-CONFIG:** je tvar `{"brightness":..,"leds portN":..,"colorN":"..."}` finální?
   (Klíče s mezerou — jen ověřit.)

---

## 11. Akceptační kritéria (DB5–DB7)

- [ ] Karta jednotky s novým FW ukazuje tři pohledy observed (uloženo / běží / kde-žije); stará jednotka vypadá jako dnes.
- [ ] Drift rozlišuje tři kategorie a v seznamu zůstává jeden flag; bez GET-CONFIG dat žádná kategorie „nehalucinuje".
- [ ] „Zálohovat konfiguraci" vytvoří revizi; opakované kliknutí bez změny nevytváří duplicitní obsah zbytečně (viditelné „beze změny od minula").
- [ ] Diff dvou revizí nikdy nehlásí změnu hesla na základě bool `true`.
- [ ] Obnova projde stavovým automatem a skončí až kontrolním GET-CONFIG; změna brokeru během obnovy není hlášena jako chyba.
- [ ] Obnova s hesly jen ve stavu `true` varuje před zahájením.
- [ ] Náhrada kusu nikdy nepřepíše ID ani MAC cílové jednotky.
- [ ] Vše za auth; seznamové endpointy dál nevrací hesla; historie dál scrubovaná.

---

**Příští krok:** poslat §10 kolegovi → review tohoto PRD → začít **DB5**.
