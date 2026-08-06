# 01 — PRD: Centrální databáze jednotek

> **Status:** Draft v0.1 · **Datum:** 2026-07-08 · **Autor:** Radek Brym · **Branch:** `web`
>
> Vzniklo z úvahy: „chtěl bych mít komplexní databázi, ve které by byly uloženy všechny jednotky
> s veškerým nastavením (broker, WiFi, devices, …), abych mohl jednotky nahrazovat a duplikovat."

Navazuje na dokončenou webovou variantu ([PRD-WEB](../PRD-WEB/README.md)) — znovu využívá její auth
backend (`server/`, Node + Express + SQLite + JWT).

> **⚠ Aktualizace 2026-08-06:** §8 („offline fronta") nahrazuje
> [03-PRD-sync.md](03-PRD-sync.md) — místo jednosměrné fronty zápisů se řeší plná
> offline-first synchronizace lokální (in-app SQLite) a serverové DB, kde je server
> zdrojem pravdy. Zároveň padá předpoklad „žádná MariaDB" z §1: server od v2.82 umí
> oba drivery a poběží trvale na firemním serveru.

> **⚠ Aktualizace 2026-07-16:** §4.1 (inventář observed) a milestones **DB5+** nahrazuje
> [02-PRD-konfigurace.md](02-PRD-konfigurace.md) — nový FW `P2L_26071501NT` přidal UNIT
> `GET-CONFIG`/`SET-CONFIG` a mění předpoklad „konfigurace se z jednotky nedá vyčíst".
> DB1–DB4 zde zůstávají v platnosti.

---

## 1. Cíl projektu

Vybudovat **centrální evidenci P2L jednotek** na firemním serveru:

1. Každá jednotka má v DB **kartu s kompletním nastavením** — broker, WiFi, devices, jas,
   DIST konfigurace + lidská metadata (název, umístění, poznámka).
2. DB se plní **jako vedlejší efekt normální práce s appkou** — každá konfigurační akce
   (set_Mqtt, set_WiFi, ADD-DEVICES, …) se zároveň zapíše na kartu jednotky.
3. Kartu lze **aplikovat na jinou jednotku** → náhrada vadného kusu nebo duplikát s novým ID.
4. Přístup k DB je **za přihlášením** (existující účty z PRD-WEB); na nativu (EXE/APK) je login
   **opt-in** — bez přihlášení appka funguje přesně jako dnes.
5. Historie změn: kdo, kdy, co (audit zadarmo díky účtům).

### Co tento projekt **není**

- Není to náhrada MQTT komunikace — konfigurace jednotek dál probíhá přes broker; DB je evidence.
- Není to nový backend systém — rozšiřuje se existující `server/` (žádný PocketBase, žádná MariaDB).
- Není to povinný login na nativu — nepřihlášený stav = dnešní appka, bez omezení a bez chybových hlášek.
- Není to konfigurační synchronizace „server → jednotka" (žádný reconcile/enforce; appka je jediný vykonavatel).

---

## 2. Klíčové principy

### 2.1 Tři vrstvy dat na kartě jednotky

| Vrstva | Co obsahuje | Odkud se bere | Důvěryhodnost |
|--------|-------------|---------------|---------------|
| **Observed** | HW model, firmware, MAC, IP, baterie, last_seen, seznam devices | jednotka sama (ALIVE, `get_param`, `GET-DEVICES`) | opravuje se sám při každém kontaktu |
| **Desired** | broker (host/port/credentials), WiFi SSID + heslo, jas, DIST config, firmware URL | to, co appka na jednotku poslala | **jinde neexistuje** — z jednotky zpětně nevyčtitelné (FW hesla nevrací); stárne, pokud jednotku nastaví někdo mimo appku |
| **Meta** | název/umístění, poznámka, stav (aktivní/vadná/sklad) | ručně od uživatele | jediný ručně udržovaný vstup |

Z toho plyne: DB **nelze naplnit skenem** existujících jednotek. Observed část se doplní sama,
desired část vzniká až od okamžiku, kdy se jednotka poprvé nakonfiguruje přes appku.

### 2.2 Zápis jako vedlejší efekt

| Akce v appce | Zápis do DB |
|---|---|
| ALIVE / odpověď na `get_param` | observed (firmware, IP, baterie, MAC, last_seen) |
| odpověď na `GET-DEVICES` | observed (devices JSON) |
| `set_Mqtt`, `set_WiFi`, jas, DIST config, OTA update | desired + historie |
| `ADD/RECREATE/DELETE-DEVICES`, `DEVICE-REPLACE`, `DEVICE-SET-ID` | devices + historie |
| `change_ID` | přenesení karty na nové ID + historie |
| uživatel vyplní název/umístění/poznámku | meta |

Nepřihlášený nebo server nedostupný → zápisy se tiše nekonají (MVP; offline fronta viz §8).

### 2.3 Login na nativu — opt-in, nikdy brána

- **Žádná vstupní LoginScreen na EXE/APK.** Start rovnou do HomeScreen jako dnes.
- Přihlášení v Nastavení: nová sekce **„Účet"** (Přihlásit se / jméno + Odhlásit).
- Session token uložený v `SharedPreferences`, při startu tiše obnoven → přihlášení je jednorázové.
- Uložená session + nedostupný server → tichý offline režim, indikace jen v Nastavení.
  **Nikdy neblokuje start ani práci s jednotkami.**
- Web zůstává beze změny (AuthGate brána dává smysl — appka žije na serveru).

---

## 3. Architektura

```
Flutter appka (Windows / Android / web)
   ├── MQTT (jako dnes) ───────────────► Mosquitto broker
   └── HTTPS /api/* (JWT) ─────────────► server/ (Node + Express)
                                            ├── users.db   (existující, auth)
                                            └── units.db   (nové, karty jednotek)
```

- Jediný proces, který sahá na SQLite, je Node backend → SQLite bez omezení stačí.
- Web: session cookie (jako dosud). Nativ: **`Authorization: Bearer <JWT>`** — backend přijme obojí.
  `POST /api/login` nově vrátí token i v response body (web ho ignoruje, cookie má přednost).

---

## 4. Datový model (skica)

```sql
CREATE TABLE units (
  id TEXT PRIMARY KEY,            -- normalizované ID bez 'u' (např. '1209')
  generation TEXT NOT NULL,       -- 'old' | 'new'
  mac TEXT,                       -- sekundární stabilní identifikátor (přežije change_ID)
  -- observed
  hw_model TEXT, firmware TEXT, ip TEXT, battery REAL,
  last_seen TEXT,                 -- ISO 8601
  devices_json TEXT,              -- poslední GET-DEVICES, formát PumaModule.toJson
  -- desired
  desired_json TEXT,              -- {broker:{...}, wifi:{ssid,password}, brightness, distConfig, fwUrl}
  desired_updated_at TEXT,
  desired_updated_by TEXT,
  -- meta
  name TEXT, location TEXT, note TEXT,
  status TEXT NOT NULL DEFAULT 'active',   -- active | faulty | stock | retired
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE unit_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  unit_id TEXT NOT NULL,
  at TEXT NOT NULL,
  username TEXT NOT NULL,
  action TEXT NOT NULL,           -- set_mqtt | set_wifi | devices | replace | set_id | change_id | meta | ...
  detail_json TEXT                -- detail změny; hesla se do historie NIKDY nezapisují
);
```

- JSON sloupce záměrně — formáty už existují v appce (`PumaModule.toJson`, `BrokerProfile.toJson`),
  nic se nevymýšlí dvakrát a schéma se nemusí měnit s každým novým polem.
- `units.db` jako samostatný soubor vedle `users.db` (nezávislé zálohy, users schema se nemění).

### 4.1 Inventář polí (doplněno 2026-07-08)

Upřesnění proti §2.1: `get_param` vrací i **aktuální broker (`mqtt_server`/`mqtt_port`), SSID a jas**
([unit.dart](../lib/models/unit.dart) `updateFromGetParam`) — zpětně nevyčtitelná jsou jen **hesla**.

**Identita:** ID (normalizované), generace (stará/nová), MAC (sekundární stabilní identifikátor —
přežije `change_ID`, odhalí fyzickou výměnu HW pod stejným ID).

**Observed:** HW model, firmware, baterie (ALIVE) · IP, aktuální SSID, aktuální broker+port,
jas, počty LED na portech 0–7, definice barev 0–9 (`get_param`) · devices — moduly vč. DIST
konfigurace (`GET-DEVICES`, formát `PumaModule.toJson`) · last_seen.

**Desired:** broker address/port/user/password/insecure (`set_Mqtt`) · WiFi SSID+heslo (`set_WiFi`) ·
jas P2L LED, jas PUM-A displejů · URL posledního OTA firmware.

**Meta:** název/umístění, poznámka, stav + created/updated.

**Neukládá se:** LED test pattern (nastavení testu v appce, ne jednotky) · živá diagnostika
(device faults, DIST vzdálenosti, výsledky skenu sběrnice — pomíjivé, session appky) ·
isOnline (odvozené z last_seen při čtení).

**Detekce driftu (plyne zadarmo):** observed obsahuje aktuální broker/SSID/jas, desired to, co
appka poslala → karta může ukázat „⚠ Nesouhlasí s evidencí" (jednotku přenastavil někdo mimo
appku, nebo se konfigurace nepovedla). Přímá odpověď na riziko driftu z §2.1.

**Doplněk (2026-07-08, z praxe):** `mqtt_server` jednotka hlásí jen v get_param — jednotku
přemigrovanou na jiný broker mimo appku by drift odhalil až po otevření detailu. Proto observed
nese i **`seen_on_broker`** = host brokeru, přes který appka jednotku naposledy viděla (plní se
každým ALIVE, appka ho zná ze svého aktivního připojení). Drift porovnává desired.broker.address
proti oběma polím → „jednotka žije na jiném brokeru" je vidět hned po discovery.

---

## 5. API (skica)

Všechny endpointy za přihlášením (cookie nebo Bearer).

```
GET    /api/units                → seznam: id, name, location, status, last_seen, firmware
                                   (BEZ desired/hesel — přehled a inventura)
GET    /api/units/:id            → kompletní karta (observed + desired + meta + kdy/kdo)
PUT    /api/units/:id/observed   → appka hlásí čerstvý observed state (upsert karty)
PUT    /api/units/:id/desired    → appka hlásí, co právě nakonfigurovala
PUT    /api/units/:id/meta       → název, umístění, poznámka, stav
POST   /api/units/:id/change-id  → { newId } — přenese kartu na nové ID + historie
GET    /api/units/:id/history    → audit log karty
DELETE /api/units/:id            → smazání karty (jen isAdmin)
```

Zásada od začátku: **seznamové endpointy nikdy nevrací hesla.** Hesla jen v detailu karty
(`GET /api/units/:id`) — jestli zobrazovat v UI, nebo jen „aplikovat", viz open question §9.2.

---

## 6. Use-casy

### 6.1 Karta jednotky
Nová obrazovka „Databáze jednotek": seznam (`GET /api/units`) s vyhledáváním podle ID/názvu/umístění,
detail = karta se všemi třemi vrstvami + editace meta polí + historie.

**UI vstup (rozhodnuto 2026-07-08, revidováno týž den):** položka **„Databáze jednotek"
v hamburger menu** HomeScreen (`Icons.menu`, nad Šablony/Nastavení) — žádná samostatná ikona
v AppBaru. Viditelná **jen pro přihlášeného uživatele** (na webu vždy, na nativu po opt-in
loginu) — nepřihlášená nativní appka zůstává vizuálně identická s dneškem. Zároveň platí:
**žádná ikona účtu v AppBaru** na žádné platformě (dřívější webová ikona `account_circle` za
hamburgerem odstraněna v rámci DB1) — účet žije výhradně v **Nastavení → sekce Účet** dole
(web: přihlášený uživatel + odhlášení; nativ: login dialog / stav / offline). Stránka databáze:
vyhledávací pole (jedno, filtruje přes ID + název + umístění) + chipy stavu
(aktivní/vadná/sklad/vše) + seznam (ID, název, stav, last_seen relativně, firmware) → klepnutí
otevře kartu. Server nedostupný → hláška + „Zkusit znovu".

### 6.2 Náhrada vadné jednotky
Karta vadné jednotky → akce **„Aplikovat na jinou jednotku"** → appka pošle na cílové ID sekvenci
příkazů, které už umí (set_Mqtt → set_WiFi → RECREATE-DEVICES → jas → DIST config), se 100ms pauzami
jako u hromadných akcí. Stará karta se označí `faulty`/`retired`, historie na obou kartách.

### 6.3 Duplikát s novým ID
Totéž co 6.2, zdrojová karta zůstává `active`. Volitelně předvyplnit meta („kopie z 1209").

---

## 7. Rozhodnutí

| # | Rozhodnutí | Důvod |
|---|-----------|-------|
| R1 | **SQLite, ne MariaDB** | Řádově menší provoz, než kde SQLite končí; `better-sqlite3` už běží; záloha = kopie souboru; MariaDB = nový provozní závazek bez přínosu. Revize jen pokud: víc aplikací potřebuje přímý přístup k DB z jiných strojů, NEBO firemní IT vyžaduje centrální DB. Migrace pár tabulek = skript na odpoledne. |
| R2 | **Rozšíření `server/`, žádný nový systém** | Auth, SQLite, deployment (systemd/Nginx z PRD-WEB M5) už existují. PocketBase zvažovaný v úvodní úvaze zamítnut — dublovalo by hotový backend. |
| R3 | **Bearer token pro nativ, cookie pro web** | Nativní `http` klient cookies nedrží; JWT infrastruktura se nemění, jen se token vydá i v body a middleware přijme `Authorization` header. |
| R4 | **Login na nativu opt-in** (ne brána) | Terén bez serveru musí fungovat jako dnes („vezmu exe a jedu"). |
| R5 | **DB se plní přes appku** (žádný sken, žádný import ze strany serveru v MVP) | Desired state (hesla) existuje jen v okamžiku odeslání; appka je jediná brána. |
| R6 | **Klíč karty = unit ID, MAC jako sekundární identifikátor** | `change_ID` kartu přenáší (`POST /change-id`), nezakládá novou; MAC pomůže odhalit fyzickou výměnu HW pod stejným ID. |

---

## 8. Out of scope (zatím)

- **Offline fronta zápisů** — MVP: bez připojení k serveru se nezapisuje. Fronta až pokud praxe ukáže díry v evidenci.
- **Server-side MQTT collector** (backend sám poslouchá ALIVE 24/7 a udržuje observed čerstvý i bez běžící appky) — silný kandidát na navazující etapu, viz DB7.
- **Synchronizace broker profilů / šablon přes server** — dnes lokální `SharedPreferences` + export/import; kandidát na DB6.
- **Šifrování hesel na úrovni sloupce** — MVP spoléhá na HTTPS + auth + server access control. API design (hesla nikdy v seznamech) je ale závazný od začátku, aby šlo šifrování doplnit bez změny klientů.
- **Per-unit oprávnění / role nad rámec isAdmin** — všichni přihlášení vidí všechno (konzistentní s PRD-WEB).
- **Reconcile server → jednotka** (automatické vynucování desired state) — appka zůstává jediný vykonavatel.

---

## 9. Open questions

### 9.1 Kde backend poběží v mezidobí
Produkční místo je firemní server (PRD-WEB M5 — deploy zatím nedokončen). Do té doby běží `server/`
jen lokálně u Radka → nativ v terénu bude typicky nepřihlášený a DB se plní jen při práci z domova/kanceláře.
**Akce:** dotáhnout M5 z PRD-WEB, tím se odblokuje reálný provoz DB.

### 9.2 Hesla v UI — „vidět" vs. „jen použít"
Smí běžný přihlášený uživatel WiFi/broker heslo z karty **zobrazit**, nebo ho appka smí jen
**aplikovat** na jednotku (a zobrazení je maskované / jen pro isAdmin)? MVP návrh: maskovat, ukázat
na kliknutí (jako ve správcích hesel), bez role-gatingu — všichni přihlášení mají plný přístup.

### 9.3 Retence historie
`unit_history` roste neomezeně. Stačí „neřešit" (řádky jsou malé), nebo zavést limit (např. posledních
500 záznamů na jednotku)? MVP: neřešit, jen sledovat velikost.

### 9.4 Placeholder karty z importu ID
Import seznamu ID (v2.60) umí založit placeholder jednotky. Má import zakládat i karty v DB
(prázdné, jen ID + generace), nebo karta vzniká až prvním reálným kontaktem? MVP návrh: až prvním kontaktem.

---

## 10. Milestones

Pořadí: nejdřív auth na nativu (bez ní není čím zapisovat), pak server, pak zápisy, pak čtecí UI,
nakonec aplikace karty. Každý milestone je samostatně shipovatelný.

| # | Milestone | Obsah | Závislosti |
|---|-----------|-------|------------|
| **DB1** ✅ | Login na nativu (opt-in) | **Hotovo 2026-07-08 (v2.76).** Backend: `POST /api/login` vrací token v body, `tokenFromReq` (cookie NEBO Bearer) sdílený v auth/admin/firmware routes. Flutter: `AuthSession` ([lib/services/auth_session.dart](../lib/services/auth_session.dart), ChangeNotifier singleton, stavy loggedOut/loggedIn/offline), `BearerClient` v `auth_http_client_io.dart` (Bearer jen na nativu, web dál cookie), sekce „Účet" v Nastavení ([lib/widgets/account_section.dart](../lib/widgets/account_section.dart)) s login dialogem (server/jméno/heslo, `normalizeApiBase` doplní `http://` a `/api`), tichá obnova session v `main.dart` (fire-and-forget, timeout 5 s). 13 testů v [test/auth_session_test.dart](../test/auth_session_test.dart); backend E2E ověřen curl (Bearer /me, firmware-list, admin 403, cookie flow beze změny). | — |
| **DB2** ✅ | DB jednotek na serveru | **Hotovo 2026-07-08.** `data/units.db` ([server/db/units-schema.sql](../server/db/units-schema.sql)), CRUD vrstva [server/db/units.js](../server/db/units.js) (normalizace ID `u0128`→`128`, generace odvozená z ID, `scrubSecrets` pro historii, observed=merge bez historie, desired=replace+historie, changeUnitId=přenos karty vč. historie v transakci), routes [server/routes/units.js](../server/routes/units.js) (8 endpointů dle §5, DELETE jen isAdmin, UnitOpError→400/404/409). Sdílený `requireAuth` v `routes/auth.js` (naplní `req.user`); fix pre-existing bugu: `/api/health` stínil requireAuth firmware routeru (401) → registrace před routery. 19 testů [server/test/units.test.js](../server/test/units.test.js) (`npm test`, node --test bez závislostí); E2E ověřeno curl (observed→desired→meta→seznam bez hesel→detail s hesly→historie scrubnutá→change-id s přenosem historie→delete 403/204). Odchylka od §4: `battery REAL` (v appce je double). Appka se nemění. | DB1 (auth middleware) |
| **DB3** ✅ | Zápisy z appky | **Hotovo 2026-07-08.** [lib/services/unit_db_service.dart](../lib/services/unit_db_service.dart) — fire-and-forget zápisy (timeout 5 s, chyby se polykají, bez retry), gating: web vždy (AuthGate), nativ jen `AuthSession.isLoggedIn`. Hooky v [app_state.dart](../lib/providers/app_state.dart): ALIVE → observed (throttle 30 s/jednotku), get_param → observed s `includeParams` (SSID/broker/jas — při ALIVE by default jasu přemazal reálnou hodnotu), GET-DEVICES → observed s devices (`PumaModule.toJson`), sendBulkBroker/Wifi/UnitBrightness/Brightness/FirmwareUpdate → desired fragmenty (`{broker}`/`{wifi}`/`{brightness}`/`{dispBrightness}`/`{fwUrl}`), setUnitId → POST change-id. Server: desired přepnut z replace na **merge po top-level klíčích** (fragmenty z akcí nepřemažou zbytek), observed rozšířen o `ssid`/`mqtt_server`/`mqtt_port`/`brightness` (drift detekce §4.1) + idempotentní mini-migrace `ensureObservedColumns` (ALTER TABLE pro existující DB). 8 testů [test/unit_db_service_test.dart](../test/unit_db_service_test.dart) + server 21 testů; E2E curl ověřil migraci sloupců na existující units.db i merge. | DB1 + DB2 |
| **DB4** ✅ | Obrazovka „Databáze jednotek" | **Hotovo 2026-07-08.** Vstup: položka v hamburger menu HomeScreen (`Icons.inventory_2_outlined`, nad Šablony), viditelná jen přihlášeným (`kIsWeb \|\| AuthSession.isLoggedIn`, vyhodnocuje se při otevření menu). [lib/screens/unit_db_screen.dart](../lib/screens/unit_db_screen.dart): seznam (jedno vyhledávací pole přes ID+název+umístění, chipy stavů, pull-to-refresh, relativní last_seen), detail karty (3 sekce: meta / observed / desired s maskovanými hesly + oko, historie s českými popisky akcí), dialog editace meta (název/umístění/poznámka/stav dropdown), **drift banner „Nesouhlasí s evidencí"** (`UnitDbCard.driftWarnings` — broker/SSID/jas: desired vs. observed); řádek seznamu s driftem má **⚠ odznak** — flag `drift` počítá server (`computeDrift` v db/units.js), aby seznam nenesl desired/hesla. Návrat z karty seznam obnoví (propsání editace meta). Observed nese i `seen_on_broker` (host, přes který appka jednotku vidí — plní každé ALIVE, vstupuje do driftu; viz §4.1 doplněk). Drift banner má akci **„Převzít skutečnost do evidence"** (`UnitDbCard.acceptObservedFragment` + `UnitDbService.saveDesired`) — pro záměrné změny mimo appku: desired se srovná podle observed, credentials z původní evidence zůstávají, zápis jde do historie. Opačný směr (nahrát evidenci do jednotky) = DB5. Modely [lib/models/unit_db.dart](../lib/models/unit_db.dart) (devices parsované přes `PumaModule.fromJson`, SQLite čas normalizovaný na UTC). `UnitDbService` rozšířen o čtecí metody (fetchUnits/fetchUnit/fetchHistory/saveMeta) — na rozdíl od push* HÁZÍ `UnitDbException` → obrazovka ukazuje hlášku + „Zkusit znovu". 7 testů [test/unit_db_screen_test.dart](../test/unit_db_screen_test.dart) (parsing, drift, filtr, widget testy s MockClient). Návod §10. | DB2 |
| **DB5** | Aplikovat kartu na jednotku | Náhrada / duplikát (§6.2, §6.3) — orchestrace existujících příkazů + zápis do historie obou karet. | DB3 + DB4 |
| **DB6** *(volitelné)* | Sync broker profilů | Profily za loginem sdílené mezi instalacemi; lokální úložiště jako cache/fallback. | DB1 |
| **DB7** *(volitelné)* | Server-side MQTT collector | Malý service vedle backendu: subscribe ALIVE (+ periodický GET-DEVICES?), observed state čerstvý 24/7 i bez běžící appky. | DB2 + broker dostupný ze serveru |

**Poznámka k nasazení:** DB1–DB5 jdou vyvinout a ověřit kompletně lokálně (`.dev/` Mosquitto +
`server/` na localhost:3001). Reálná hodnota v terénu ale přijde až s PRD-WEB M5 (backend na
firemním serveru) — do té doby je to „funguje u mě doma".

---

## 11. Akceptační kritéria MVP (DB1–DB5)

- [ ] EXE/APK startuje bez přihlášení a funguje přesně jako dosud (žádná brána, žádné chybové hlášky o serveru).
- [ ] Přihlášení ze sekce „Účet" na nativu; po restartu appky session drží (bez opětovného loginu).
- [ ] Uložená session + nedostupný server → appka běží normálně, stav vidět jen v Nastavení.
- [ ] Konfigurační akce přihlášeného uživatele (set_Mqtt, set_WiFi, devices, jas) se objeví na kartě jednotky v DB.
- [ ] ALIVE/GET-DEVICES aktualizují observed vrstvu karty (firmware, IP, last_seen, devices).
- [ ] Selhání zápisu do DB nikdy neshodí ani nezdrží samotnou MQTT akci.
- [ ] Obrazovka „Databáze jednotek": seznam s vyhledáváním, karta se všemi vrstvami, editace názvu/umístění/poznámky.
- [ ] Historie karty ukazuje kdo/kdy/co; hesla se v historii nikdy neobjeví.
- [ ] Seznamový endpoint nevrací hesla (ověřeno testem).
- [ ] „Aplikovat kartu na jinou jednotku" provede kompletní sekvenci a cílová jednotka je funkčním duplikátem (ověřeno na reálném HW).
- [ ] `change_ID` přenese kartu na nové ID včetně historie.

---

**Příští krok:** review tohoto PRD → začít **DB1** (bearer token na backendu + sekce „Účet" na nativu).
Paralelně dotáhnout PRD-WEB M5 (deploy), který odblokuje reálný provoz.
