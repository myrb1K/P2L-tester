# 03 — PRD: Offline-first synchronizace lokální a serverové DB

> **Status:** Draft v0.1 · **Datum:** 2026-08-06 · **Autor:** Radek Brym · **Branch:** `web`
>
> Vzniklo z domluvy: „pokud appka má přístup na serverovou DB, používá ji; pokud nemá, používá
> lokální SQLite; když server zase vidí, srovnají se rozdíly. Zdrojem pravdy je serverová DB."

Navazuje na [01-PRD.md](01-PRD.md) (centrální DB jednotek, milníky DB1–DB4) a
[02-PRD-konfigurace.md](02-PRD-konfigurace.md) (observed vrstva z UNIT `GET-CONFIG`, drift v2).
**Nahrazuje §8 „offline fronta"** z 01-PRD — ta předpokládala jen frontu zápisů, tady jde
o plnou dvoucestnou synchronizaci.

Předpoklad, který se od 01-PRD změnil: **Node server poběží trvale na firemním serveru**
(domluveno s kolegou, 2026-08-06) a odtud obsluhuje MariaDB `P2Lunits`. Web, EXE i APK
tedy míří na jeden server; lokální DB je *cache*, ne druhá pravda.

---

## 1. Cíl

1. **Appka je použitelná bez serveru** — technik u zákazníka vidí jednotky přes MQTT,
   na firemní server nedosáhne, a přesto může evidenci čtou i zapisovat.
2. **Po návratu online se rozdíly srovnají samy** — bez ručního exportu/importu.
3. **Zdrojem pravdy je serverová DB** — lokál nikdy nepřepíše novější serverovou informaci
   jen proto, že je „poslední, kdo psal".
4. **Nic se neztratí neviditelně** — přehlasovaná lokální změna skončí v auditu, ne v koši.
5. **Log v serverové DB** dovolí procházet, kdo/kdy/odkud co změnil (napříč jednotkami).

### 1.1 Referenční scénář

Technik přijede k zákazníkovi s notebookem, připojí se do **jeho** sítě. Na jednotky přes MQTT
vidí, ale **přístup na internet je zakázaný** → firemní server nedostupný. Konfiguruje jednotky,
zakládá karty, píše poznámky a stavy. Po návratu do firmy (nebo na hotspot z telefonu) se
všechno nahraje na server a zároveň se stáhne, co mezitím udělali ostatní.

Z toho scénáře plyne, že **offline musí být možný i zápis**, ne jen čtení — evidence u zákazníka
teprve vzniká. Varianta „offline cache jen pro čtení" byla zvážena a **zamítnuta** (2026-08-07).

**Mobil v téže situaci může být online.** Android po připojení k WiFi bez internetu obvykle nechá
běžet mobilní data paralelně (provoz do `192.168.x.x` přes WiFi na MQTT, na server přes SIM) —
ale je to závislé na verzi systému, výrobci a nastavení, takže se na to **nelze spoléhat**.
Appka tedy nesmí stav odvozovat z typu připojení; jediné platné kritérium je, zda odpoví
`/api/health` (viz §7 bod 1). Notebook bez SIM tuhle šanci nemá vůbec — proto je offline režim
kritičtější pro EXE, přestože ho mají oba klienti stejný.

### Co to není

- Není to synchronizace „server → jednotka" (žádný reconcile konfigurace hardware; appka
  zůstává jediným vykonavatelem přes MQTT).
- Není to peer-to-peer sync mezi dvěma appkami. Vždy jen klient ↔ server.
- Není to multi-master s merge dialogy na každém poli — konfliktů je záměrně minimum (§5).
- Není to náhrada `/api/units/export|import` — ty zůstávají pro zálohu a přenos mezi drivery.

---

## 2. Rozhodnutí (2026-08-06)

| # | Rozhodnutí | Stav |
|---|---|---|
| R1 | Lokální DB je **v aplikaci** (`drift`/`sqflite`), ne lokální Node server. Jeden kód a jeden sync engine pro EXE i APK. | **potvrzeno** |
| R2 | **UI vždy čte i píše do lokální DB**; sync engine ji na pozadí slaďuje. Žádné přepínání „lokální / serverová DB" v UI. | **potvrzeno** |
| R3 | Konflikt v `desired`/`meta` řeší **automaticky novější změna**; přehlasovaná verze jde do historie. Uživatel se dozví jen tehdy, když prohrála **jeho vlastní neodeslaná** změna. | **potvrzeno** |
| R4 | Granularita rozhodování = **vrstva karty** (`observed` / `desired` / `meta`), ne celá karta a ne jednotlivá pole. | **potvrzeno** |
| R5 | Web zůstává **čistě online** (bez lokální DB) — appka žije na serveru, offline režim tam nemá smysl. | **potvrzeno** |
| R6 | Lokální Node server na desktopu (Nastavení → *Lokální server*) se **po DB10 odstraní** — in-app SQLite ho nahradí. Do té doby zůstává jako funkční záložní cesta. | **potvrzeno 2026-08-07** |
| R7 | **Šifrování lokální DB** (nese hesla brokerů z `desired`) — odloženo, řeší se později jako DB8. | **odloženo** |

---

## 3. Architektura

```
┌─────────────── Flutter appka (EXE / APK) ───────────────┐
│  UI (HomeScreen, Databáze P2L modulů)                   │
│        ↕ čte a píše VŽDY lokálně                        │
│  lokální SQLite (drift): units_cache + outbox + stav     │
│        ↕ sync engine (na pozadí)                        │
└──────────────────────┬──────────────────────────────────┘
                       │ HTTPS + JWT
              ┌────────▼─────────┐
              │  Node server     │  ← zdroj pravdy
              │  MariaDB P2Lunits│
              └────────▲─────────┘
                       │ HTTPS + JWT (bez lokální DB)
              ┌────────┴─────────┐
              │  Flutter web     │
              └──────────────────┘
```

Důsledky:

- **Zápis z MQTT akce jde do lokální DB okamžitě** (i offline) → `UnitDbService` přestane být
  fire-and-forget HTTP klient a stane se zápisem do lokálu + záznamem v outboxu.
- **Nepřihlášená appka** se nemění: bez přihlášení se needviduje nic (jako dnes). Lokální DB
  je pro přihlášeného uživatele, který zrovna nedosáhne na server.
- **Web** používá dnešní cestu (přímo API), sync engine se na něm neaktivuje.

---

## 4. Datový model

### 4.1 Server — co přidat do `units`

| Sloupec | Účel |
|---|---|
| `rev` INTEGER NOT NULL | **monotónní revize** z globálního čítače; roste s každým zápisem do karty. Podle ní klient pozná, co je nového. Index `(rev)`. |
| `observed_updated_at` TEXT | čas poslední změny observed vrstvy (ISO 8601) |
| `meta_updated_at` TEXT, `meta_updated_by` TEXT | totéž pro meta (`desired_updated_at` / `_by` už existují) |
| `deleted_at` TEXT, `deleted_by` TEXT | **tombstone** — smazaná karta se nemaže fyzicky, jinak by se při dalším syncu vrátila z lokálu |

Čítač revizí: tabulka `sync_counter(value INTEGER)` s jedním řádkem, inkrement **v téže transakci**
jako zápis karty (`UPDATE … SET value = value + 1` → přečti). Nepoužívat čas — `rev` musí být
monotónní i při zápisech ve stejné milisekundě.

`listUnits` a `getUnit` musí tombstones filtrovat; `/units/changes` je naopak vrací.

### 4.2 Server — rozšíření `unit_history` (audit)

| Sloupec | Účel |
|---|---|
| `uuid` TEXT UNIQUE | **globálně unikátní ID řádku.** Offline klienti si historii generují sami a nahrávají ji — `AUTO_INCREMENT` by se u dvou klientů srazil. |
| `layer` TEXT | `observed` / `desired` / `meta` / `change_id` / `delete` |
| `origin` TEXT | `online` (zápis proti serveru) / `sync` (doručeno ze offline klienta) / `mqtt` |
| `source_device` TEXT | odkud změna přišla (`exe@NB-RADEK`, `apk@Pixel7`, `web`) |
| `rev` INTEGER | revize, kterou zápis vyrobil — spojka mezi auditem a syncem |

Hesla se dál scrubují (`scrubSecrets`) — na tom se nic nemění.

### 4.3 Klient — lokální schéma (drift)

| Tabulka | Obsah |
|---|---|
| `units_cache` | zrcadlo serverové karty + `rev` + tři `*_updated_at` + `deleted_at` |
| `outbox` | čekající zápisy: `op_id` (UUID), `unit_id`, `layer`, `payload_json`, `at` (čas normalizovaný na server, §4.4), `tries`, `last_error` |
| `sync_state` | `last_rev`, `last_sync_at`, `clock_offset_ms` |
| `local_history` | lokálně vzniklé audit řádky (s `uuid`), nahrávají se s outboxem |

### 4.4 Hodiny klientů

Rozhodnutí „kdo je novější" nesmí stát na času klienta — telefon po vybití nebo notebook bez NTP
se rozchází v minutách až dnech. `GET /api/health` už vrací `ts`, takže:

1. při každém úspěšném kontaktu se serverem se spočítá `clock_offset_ms = server_ts − local_ts`,
2. všechny časy zapisované do vrstev i outboxu se ukládají **už opravené** na serverový čas,
3. offset se drží v `sync_state` a použije se i pro zápisy vzniklé kompletně offline.

---

## 5. Rozhodování konfliktů

Klíčové zjednodušení: **konflikt může vzniknout jen v `desired` a `meta`** (ruční editace člověkem).
`observed` plní MQTT a novější pozorování je prostě pravda.

| Vrstva | Lokální neodeslaná změna? | Server má novější? | Výsledek | Uživatel? |
|---|---|---|---|---|
| `observed` | — | — | vyhrává **novější čas pozorování**, per vrstva | ne |
| `desired`/`meta` | ne | ano | server verze se tiše zapíše do lokálu | ne |
| `desired`/`meta` | ano | ne | lokální změna se pushne (`applied`) | ne |
| `desired`/`meta` | ano | **ano** | **konflikt** → vyhrává novější (obvykle server), prohraná verze do historie jako `superseded_local` | **ano — upozornění** |
| karta smazaná na serveru | ano | — | mazání vyhrává; lokální fragment jen do historie | **ano — upozornění** |

Upozornění (poslední dva řádky) je **nemodální** — banner v kartě jednotky + souhrn po syncu
(„2 změny byly přehlasovány novější verzí ze serveru"), s možností otevřít detail a lokální verzi
**znovu poslat jako novou změnu** (nový zápis s aktuálním časem, tedy legitimní výhra).

`desired` push je **fragment vrstvy**, ne celá vrstva — server už dnes slévá `desired` hloubkově
po podklíčích (`updateDesired`, v2.80), takže „já jsem změnil broker, kolega WiFi" konflikt vůbec
nevyrobí.

---

## 6. Protokol

| Metoda | Path | Účel |
|---|---|---|
| GET | `/api/units/changes?since=<rev>&limit=500` | rozdílový pull. Vrací `{serverTs, maxRev, more, units:[…], deleted:[{id, deletedAt}]}` — karty s `rev > since` vzestupně. `since=0` = bootstrap (stránkovaně). |
| POST | `/api/units/sync` | dávkový push outboxu: `{ops:[{opId, unitId, layer, at, payload, historyUuid}]}` → `{serverTs, maxRev, results:[{opId, status, rev, current?}]}`, kde `status` ∈ `applied` / `superseded` / `conflict` / `rejected`. |
| GET | `/api/health` | už existuje — `ts` slouží ke kalibraci hodin |

Vlastnosti, na kterých to stojí:

- **Idempotence** — `opId` (UUID) si server pamatuje; opakované poslání téže operace (spadlá síť,
  restart appky) nesmí zápis zdvojit. Bez toho by se historie plnila duplikáty.
- **Jedna transakce na operaci** — inkrement `rev` + zápis karty + zápis historie.
- **Stránkování pullu** — `limit` + `more`, ať bootstrap nad tisíci kartami nespadne na timeoutu.
- **Push jde jen z outboxu.** Nikdy „nahrát celou lokální DB" — týden starý lokál by přepsal kartu,
  kterou mezitím editoval kolega. Co appka jen přečetla, se nahoru neposílá.

---

## 7. Průběh synchronizace

1. **Kalibrace** — `GET /api/health` → `clock_offset_ms`. Když neodpoví, sync končí (zůstává offline).
   Dvě podmínky, bez kterých to v uzavřených sítích selže: **krátký timeout** (2–3 s, ne default
   30 s — jinak UI čeká na každý pokus) a **validace obsahu odpovědi**, ne jen HTTP statusu.
   Captive portály zákazníkových WiFi vrací na libovolný request `200 OK` s přihlašovací
   stránkou; probe proto musí trvat na JSON s `ok: true` a `db`, jinak by se appka považovala
   za online a sync by opakovaně padal.
2. **Push** — outbox v pořadí vzniku, dávkami. Výsledky se zapíšou: `applied`/`superseded` → smaž
   z outboxu, `conflict` → smaž a založ upozornění, `rejected` (např. 403 u mazání) → nech s `last_error`.
3. **Pull** — `/units/changes?since=last_rev`, dokud `more == true`. Karty se zapisují do
   `units_cache`, tombstones mažou lokální řádky.
4. **Commit** — `last_rev = maxRev`, `last_sync_at = serverTs`.

Push **před** pullem záměrně: server tak rozhoduje o konfliktu s plnou znalostí obou verzí a klient
si hned stáhne výsledek (včetně vlastní přehlasované karty).

**Bootstrap** (první přihlášení / nová instalace / vyčištěná cache) = totéž s `last_rev = 0`.
Žádný speciální „migrační" krok, žádné `export`/`import`.

### Kdy se sync spustí

| Trigger | Poznámka |
|---|---|
| start appky / obnovení sezení | po naběhnutí `AuthSession` |
| přechod offline → online | health probe uspěla / síť se vrátila |
| po lokálním zápisu | debounce ~2 s → v online provozu fakticky okamžitě |
| periodicky | 5–10 min, kvůli změnám od jiných uživatelů |
| ručně | tlačítko v *Databázi P2L modulů* |

---

## 8. UI

- **Indikátor stavu synchronizace** v AppBaru *Databáze P2L modulů*: sladěno `hh:mm` / `N čeká` /
  offline + tlačítko ruční synchronizace.
- **Banner na kartě** u přehlasované změny (viz §5) s možností poslat lokální verzi znovu.
- **Nová obrazovka „Změny"** — audit napříč jednotkami (dnes je historie jen per karta):
  filtr podle jednotky / uživatele / vrstvy / časového rozsahu, sloupce
  *kdy · kdo · odkud (`source_device`, `origin`) · jednotka · vrstva · detail*.
- Nikde v UI se **nevybírá databáze** — to je právě to, co R2 ruší.

---

## 9. Milníky

| # | Rozsah | Výstup |
|---|---|---|
| **DB9** ✅ | Server: `rev` + čítač, `*_updated_at`, tombstones, rozšířený `unit_history`, endpointy `/units/changes` a `/units/sync` (idempotence přes `opId`) | hotovo 2026-08-07; 86 testů nad SQLite. **MariaDB sada zatím neproběhla** — na firemním serveru chybí databáze `P2Lunits_test` a práva pro účet `p2l` (viz server/README §Testy) |
| **DB10** ✅ | Klient: lokální schéma (**sqflite**, ne drift — viz níže), `UnitDbService` přesměrovaný na lokál, UI čte z lokálu, **pull** ze serveru | hotovo 2026-08-07; appka čte i zapisuje offline, odesílání outboxu je DB11 |
| **DB11** ✅ | Sync engine: kalibrace hodin, push/pull, konflikty, triggery, indikátor + banner | hotovo 2026-08-07; synchronizace je obousměrná |
| **DB12** ✅ | Obrazovka „Změny" (audit napříč jednotkami) | hotovo 2026-08-07 |

Web se v žádném milníku nemění (R5).

---

## 9.1 K R6 — proč lokální Node server skončí

Rozhodnuto **2026-08-07**, po nasazení serveru na `p2ltester.smartbox.smartci4.com`
(Docker + Traefik, HTTPS na 443, MariaDB `P2Lunits`).

**Pozor na záměnu: nezaniká offline režim, zaniká jen jeho dnešní nosič.** Lokální DB zůstává —
přesune se z Node serveru do samotné appky (in-app SQLite, DB10), takže referenční scénář §1.1
funguje dál a poprvé i na Androidu.

Vnitřní Node server v EXE existoval z jediného důvodu: appka neměla vlastní datovou vrstvu,
takže lokální evidence šla jen přes lokální server nad SQLite. Po DB10 to platit přestane.
Jediný scénář, který by ho udržel — *místo bez internetu i bez firemní sítě, kde k jedné
evidenci potřebuje víc lidí zároveň* — neexistuje: firemní server je dostupný přes HTTPS
z internetu a mobil se na internet dostane všude.

Co odstranění přinese:

| | dnes | po DB10 |
|---|---|---|
| portable zip | ≈ 128 MB (`server\` ≈ 100 MB: `node.exe` ~80 MB + `node_modules` ~19 MB) | ≈ 30 MB |
| závislost na major verzi Node | native moduly (`better-sqlite3`, `bcrypt`) musí sedět s přiloženým `node.exe` | žádná |
| kód, který zmizí | `local_server_io.dart`, `local_server_section.dart`, PID file + úklid sirotků, adopce cizího serveru, bootstrap správce, `dbMismatch` | — |
| `tools\pack-portable.ps1` | kopíruje `server\`, hlídá `.env` a `data\` | jen přejmenování exe + zip |

**Timing je podmínka, ne detail:** odstranit **až** bude in-app SQLite hotová, jinak by EXE
mezitím přišlo o offline režim úplně. Provést jako samostatný commit, ne jako součást DB10.

Poznámka: přepínač *Nastavení → Lokální server → Databáze* (SQLite/MariaDB) je fakticky mrtvý
už teď — na MariaDB se appka dostane přihlášením ke vzdálenému serveru, lokálním serverem si
ji nastavovat nemusí.

---

## 9.2 K DB10 — co se při realizaci ukázalo

**Zvoleno `sqflite`, ne `drift`.** Schéma je malé a záměrně blízké serverovému, takže
typová vrstva drift nevyváží codegen krok (`build_runner`) při každé změně.

**`sqlite3` musí zůstat na řadě 2.x.** Verze 3.x staví native knihovnu přes Dart build
hooks a Flutter tool je na Windows spustí přes `dart compile kernel` s cestou k hooku —
na profilu s mezerou (`C:\Users\Radek Brym`) to skončí
`'C:\Users\Radek' is not recognized as an internal or external command`. Stejná past jako
`path_provider_foundation` 2.6+. V `pubspec.yaml` proto drží: `sqlite3` 2.9.x,
`sqlite3_flutter_libs` 0.5.x, `sqflite_common_ffi` **pod 2.4.0** (2.4 už na sqlite3 3.x
trvá; pozor, `^2.3.3` by ji pustil — rozsah musí být uzavřený).

**Pull patří do DB10, ne až do DB11.** Kdyby DB10 jen přepnula čtení na lokál, uživatel
by po instalaci neviděl nic, co je na serveru — appka by se zhoršila. `UnitDbService`
proto při `fetchUnits()` nejdřív zkusí `GET /units/changes?since=<rev>` (chyby polyká,
offline je normální stav) a pak čte lokál. **Odesílání outboxu zůstává na DB11** — do té
doby lokální změny na server nedojdou.

**Editace offline uspěje.** `saveDesired`/`saveMeta`/bulk zapíšou do lokální DB a vrátí
úspěch; o čekajících změnách informuje indikátor (DB11), ne chybová hláška. Bez toho by
uživatel u zákazníka dostával „server nedostupný" na každou editaci.

**Observed operace se ve frontě slučují.** ALIVE chodí à 5 min a po dni offline by fronta
měla tisíce položek; serveru stačí poslední stav, takže se payload merguje do jedné
operace na jednotku. Throttle 30 s zůstává jen pro přímou HTTP cestu — do lokální DB se
zapisuje vždy, aby offline evidence ukazovala aktuální stav.

**`change-id` je zatím online-only** (viz §10 bod 3) — přenos karty mezi dvěma klíči se do
outboxu jako jedna operace nevejde a offline se dělat nebude.

## 9.3 K DB11 — co se při realizaci ukázalo

**Konflikty potřebují vlastní tabulku.** Server prohranou verzi zapíše do své historie, ale
klient ji musí umět zobrazit na kartě — proto lokální `conflicts` (schéma v2, přírůstková
migrace, ať lokální data přežijí update appky). Záznam se `dismissed`, nemaže: dohledatelnost
je celý smysl toho, že se změna nezahodí mlčky. UI dává „Poslat znovu" (nový zápis s aktuálním
časem → legitimní výhra) a „Rozumím".

**Výsledky pushe se vyhodnocují per operace** a všechny čtyři stavy končí odebráním z fronty:
`applied` a `superseded` bez upozornění, `conflict` s uložením prohrané verze, `rejected`
s poznámkou o chybě — vadná operace by se jinak přeposílala donekonečna. Operace, ke které
odpověď **nepřišla**, ve frontě zůstane se stejným `opId`; idempotence na serveru zajistí, že
se druhým pokusem nic nezdvojí.

**Souběžná kola se musí zahazovat.** Bez `_running` guardu by debounce + periodický timer +
ruční klik poslali tři pushe zároveň a fronta by se rozjela.

**Offline se zkouší po minutě, ne po deseti.** Periodický cyklus je 10 min (změny od ostatních),
ale když je server nedostupný a fronta neprázdná, plánuje se retry po 1 min — technik po návratu
do signálu nemá čekat, ani otevírat obrazovku Databáze.

**Engine musí slyšet na přihlášení.** Nativní login je opt-in a uživatel se může přihlásit až za
běhu; bez listeneru na `AuthSession` by se do restartu appky nesynchronizovalo nic.

**`source_device` se bere z LocalUnitDb**, ne z `UnitDbService` — hostname jde jen z `dart:io`
a service se kompiluje i pro web.

## 9.4 K DB12 — co se při realizaci ukázalo

**`/units/history` musí být registrované před `/:id`**, jinak by spadlo do detailu karty
s `id='history'` — stejná past jako u `/export`, `/changes` a `/sync`.

**`hasMore` se pozná načtením o řádek víc** (`LIMIT n+1`), ne druhým `COUNT` dotazem nad celou
`unit_history` — ta poroste rychle a počítat ji při každém scrollu je zbytečné.

**Audit je serverová veličina.** Lokální DB drží jen změny z tohohle zařízení, takže offline
obrazovka ukáže je a nahoře řekne „server není dostupný — ukazují se jen změny z tohoto
zařízení". Bez toho by offline vypadala jako prázdná databáze.

**Odhalený flaky test (ne bug v produkci).** Drift testy zapisovaly observed *před* desired,
takže evidence byla novější než poslední pozorování → `computeDrift` správně vrátil „čekající
změna, žádný drift". Procházely jen tehdy, když se oba zápisy vešly do stejné milisekundy.
Opraveno explicitním časem evidence (`hourAgo()`); potvrzeno 8 běhy v řadě. Gate v produkci je
v pořádku, chyba byla v očekávání testu — a je to připomínka, že testy nad časem potřebují
časy zadané, ne odvozené od rychlosti stroje.

---

## 10. Otevřené otázky

0. **Offline autentizace** — dnes je přístup k evidenci vázaný na platný JWT (7 dní).
   V referenčním scénáři (§1.1) je appka celý den bez serveru; kdyby token mezitím vypršel,
   nesmí to znamenat ztrátu přístupu k **lokální** DB — přihlásit se totiž nejde. Návrh:
   expirace tokenu blokuje jen komunikaci se serverem, lokální čtení i zápis běží dál
   (a sync po návratu vyžádá nové přihlášení). Rozhodnout v DB10.
1. **Retence historie** — audit poroste rychleji (i observed zápisy z offline klientů). Kolik
   měsíců držet, co prunovat? (Dnes prune existuje v `prepareUnitsSchema`.)
2. **Mazání karty offline** — mazat smí jen admin. Má se offline mazání vůbec povolit,
   nebo ho nechat jen online?
3. **`change-id` offline** — přenos karty na nové ID je operace nad dvěma klíči; buď zakázat
   offline, nebo popsat jako speciální op v outboxu.
4. **Strop lokální cache** — držet všechny karty, nebo jen ty, které uživatel viděl?
   (Odhad: stovky až tisíce karet, takže zatím vše.)
5. **R6/R7** — budoucnost lokálního Node serveru a šifrování lokální DB.

---

## 11. Testy

- **Server:** `rev` monotónnost při souběžných zápisech, idempotence `opId`, tombstones
  se nevrací v `listUnits` ale vrací v `changes`, stránkování pullu, `superseded` větev.
  Celá sada musí projít v obou driverech (`npm test` + `npm run test:mariadb`).
- **Klient:** rozhodovací tabulka §5 jako unit testy sync engine (bez sítě, s fake serverem),
  outbox po restartu appky, kalibrace hodin s rozjetými hodinami (offset ±2 dny),
  bootstrap nad prázdným lokálem, přerušený pull (`more`).
- **E2E proti reálnému serveru** ([test/sync_e2e_test.dart](../test/sync_e2e_test.dart), hotovo
  2026-08-07): test si spustí `server/server.js` nad SQLite v temp adresáři (port 3098, vlastní
  `INITIAL_ADMIN`), přihlásí se a prožene celý cyklus přes skutečné HTTP — push, pull, konflikt
  i „poslat znovu", idempotenci, audit, tombstone a offline→online. Odhalí to, co fake klient
  nikdy nemůže: tvar payloadu, chování routeru, serializaci časů.
  **Pozor:** `DB_DRIVER=sqlite` se procesu předává explicitně — `server/.env` může mít
  `mariadb` a dotenv existující env nepřepisuje, takže bez toho by test jel proti firemní DB.
