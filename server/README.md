# P2L Tester — Auth Backend

Node.js + JWT backend pro webovou variantu P2L Testeru ([PRD-WEB/02-auth-bezpecnost.md](../PRD-WEB/02-auth-bezpecnost.md)).
Databáze: **SQLite** (default) nebo **MariaDB** — viz [Volba databáze](#volba-databáze).

## Quick start (lokálně)

```bash
cd server
cp .env.example .env
# Vyplň JWT_SECRET — vygeneruj: openssl rand -hex 32 (nebo node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
npm install
npm run dev
```

Backend poslouchá na `http://localhost:3001`. Při prvním startu se vytvoří `data/users.db` a založí initial admin podle `INITIAL_ADMIN_USER` / `INITIAL_ADMIN_PASSWORD`.

## Docker

Image obsahuje **jen backend** (build kontext je `server/`, ne root repa). Konfigurace
jde výhradně env proměnnými — `.env` se do image záměrně nekopíruje (nese JWT secret
a heslo k databázi).

### Celý stack (backend + MariaDB)

```bash
cd server
cp .env.docker.example .env.docker    # vyplnit JWT_SECRET (min. 32 znaků) a DB_PASSWORD
docker compose --env-file .env.docker up -d --build
docker compose --env-file .env.docker logs -f api
```

`--env-file .env.docker` patří ke **každému** compose příkazu (`up`, `logs`, `exec`, `down`) —
compose z něj bere hodnoty pro `${…}` v [docker-compose.yml](docker-compose.yml). Bez něj
se použijí jen defaulty a příkaz spadne na chybějícím `JWT_SECRET`.

Ověření: `curl http://127.0.0.1:3001/api/health` → `{"ok":true,"ts":…,"db":"mariadb"}`.
Databázi `P2Lunits` i uživatele zakládá MariaDB image, schéma tabulek si dodělá server
při startu. První admin vznikne z `INITIAL_ADMIN_USER` / `INITIAL_ADMIN_PASSWORD` jen
při startu nad prázdnou tabulkou `users`.

API se defaultně publikuje **na loopback** (`API_BIND=127.0.0.1`) — pro klienty
z sítě (EXE/APK na jiných počítačích) nastav `API_BIND=0.0.0.0`. Port MariaDB se
ven nemapuje vůbec, databáze je dostupná jen pro kontejner `api`.

### Proti existující MariaDB (firemní server)

Když už MariaDB běží (nativně nebo v jiném kontejneru), použij
[docker-compose.external-db.yml](docker-compose.external-db.yml) — spustí **jen backend**,
databázi nezakládá ani nespravuje:

```bash
cd server
cp .env.docker.example .env.docker     # JWT_SECRET, DB_HOST, DB_USER, DB_PASSWORD, DB_NAME
docker compose -f docker-compose.external-db.yml --env-file .env.docker up -d --build
docker compose -f docker-compose.external-db.yml --env-file .env.docker logs -f api
```

Tři pasti tohoto nasazení:

- **`DB_HOST=127.0.0.1` nefunguje** — uvnitř kontejneru je to sám kontejner. Pro MariaDB
  na tom samém stroji použij `host.docker.internal` (compose to mapuje na `host-gateway`,
  takže to platí i na Linuxu) nebo IP serveru v LAN.
- **MariaDB musí spojení z Dockeru přijmout** — `bind-address` nesmí být jen `127.0.0.1`
  a uživatel potřebuje grant pro adresu kontejneru (`'p2l'@'%'` nebo `'p2l'@'172.%'`).
- **`INITIAL_ADMIN_*` vs. `migrate-users`** — nad prázdnou DB si server admina naseeduje sám,
  a pozdější `npm run migrate-users` to jméno **přeskočí** (účet zůstane s heslem z env, ne
  s původním). Pokud se mají účty migrovat, buď `INITIAL_ADMIN_*` nevyplňuj vůbec, nebo
  migruj s `--overwrite`.

`API_BIND` je tady defaultně `0.0.0.0` (smysl nasazení je obsloužit APK a web ze sítě) —
port si ochraň firewallem, případně před něj dej reverzní proxy s TLS a publikuj jen loopback.

### Jen image (`docker run`)

```bash
docker build -t p2l-tester-server:latest server

docker run -d --name p2l-server \
  -p 3001:3001 \
  -e JWT_SECRET=<hex 32 B> \
  -e DB_DRIVER=mariadb \
  -e DB_HOST=192.168.1.10 -e DB_PORT=3306 \
  -e DB_USER=p2l -e DB_PASSWORD=<heslo> -e DB_NAME=P2Lunits \
  -v p2l-server-data:/data \
  p2l-tester-server:latest
```

Se `DB_DRIVER=sqlite` (nebo bez `DB_*`) jede kontejner na SQLite v připojeném
volume — databáze pak žije v `/data/{users,units}.db` (`P2L_DATA_DIR=/data`).
**Volume je povinný**, jinak data zmizí s kontejnerem. U bind mountu (`-v /srv/p2l:/data`)
musí být adresář na hostu zapisovatelný pro UID 1000 (`node`), image běží bez roota.

### Provoz

```bash
# CLI správa uživatelů uvnitř kontejneru (stejné skripty jako lokálně)
docker compose --env-file .env.docker exec api npm run list-users
docker compose --env-file .env.docker exec api npm run reset-pwd -- radek <nove-heslo>

# Záloha MariaDB (heslo z .env.docker)
docker compose --env-file .env.docker exec db \
  mariadb-dump -u p2l -p<heslo> P2Lunits > zaloha.sql
```

Zálohovat jde i **z aplikace** přes `GET /api/units/export` (kompletní snímek jednotek
vč. historie) — nezávisle na driveru.

Detaily buildu: `better-sqlite3` a `bcrypt` jsou native moduly a kompilují se
v build stage ([Dockerfile](Dockerfile)), takže výsledný image nenese `python3`/`g++`.
Obě stage stojí na `node:22-bookworm-slim`; při změně base image je nutný rebuild bez cache.

## Volba databáze

Driver se přepíná env proměnnou `DB_DRIVER`. Datová vrstva je jedna
([db/units.js](db/units.js), [db/users.js](db/users.js)) — rozdíly dialektů řeší
[db/adapter.js](db/adapter.js), takže se logika ani endpointy nemění.

| | `sqlite` (default) | `mariadb` |
|---|---|---|
| Umístění dat | `data/users.db` + `data/units.db` | jedna databáze se všemi tabulkami |
| Instalace | žádná | běžící MariaDB, existující databáze |
| Sdílení mezi počítači | ne | **ano** — společná evidence |
| Používá | portable Windows dist (appka si server spouští sama) | firemní / centrální nasazení |

### Nastavení MariaDB

Databázi vytvoří správce (schéma si server dodělá sám při startu):

```sql
CREATE DATABASE P2Lunits CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'p2l'@'%' IDENTIFIED BY '<heslo>';
GRANT ALL PRIVILEGES ON P2Lunits.* TO 'p2l'@'%';
FLUSH PRIVILEGES;
```

Pak v `.env`:

```ini
DB_DRIVER=mariadb
DB_HOST=192.168.1.10
DB_PORT=3306
DB_USER=p2l
DB_PASSWORD=<heslo>
DB_NAME=P2Lunits
```

Ověření spojení **před** startem serveru (vrátí čitelnou chybu místo pádu):

```bash
npm run db-check
```

Server při startu vypíše, na čem jede (`[db] mariadb p2l@192.168.1.10:3306/P2Lunits`),
a `GET /api/health` vrací `{"ok":true,"db":"mariadb"}` — podle toho appka pozná,
že mluví se serverem nad očekávanou databází.

### Poznámky ke schématu

Tabulky jsou stejné v obou driverech, liší se jen typy:
[schema.sql](db/schema.sql) / [schema.mariadb.sql](db/schema.mariadb.sql) (users) a
[units-schema.sql](db/units-schema.sql) / [units-schema.mariadb.sql](db/units-schema.mariadb.sql)
(units + unit_history). Klíčové rozdíly: `VARCHAR` s délkou místo `TEXT` u klíčů,
`LONGTEXT` u JSON snapshotů, `AUTO_INCREMENT`, indexy inline (MariaDB nezná
`CREATE INDEX IF NOT EXISTS`) a case-insensitive jména uživatelů přes
`utf8mb4_unicode_ci` místo `COLLATE NOCASE`.

**Časové značky** zapisuje aplikace jako ISO 8601 string (`db/adapter.js` →
`nowIso()`), ne SQL funkcí — `datetime('now')` a `UTC_TIMESTAMP()` by se lišily
formátem a drift výpočty by na tom klopýtly.

### Přenos existujících dat

**Uživatelé** — `npm run migrate-users` přenese účty ze SQLite `users.db` do cílové
databáze (podle `DB_DRIVER`/`DB_*`). Hesla se přenášejí jako **bcrypt hashe 1:1**,
takže se všichni přihlásí stejným heslem jako dřív; nic se neresetuje.

```bash
npm run migrate-users -- --dry-run    # náhled, nic nezapíše
npm run migrate-users                 # přenos
npm run migrate-users -- --overwrite  # přepíše i účty, které už v cíli jsou
npm run migrate-users -- --from "C:\Users\<jméno>\AppData\Roaming\P2L-Tester\server-data\users.db"
```

Zdroj se čte **read-only** (původní `users.db` zůstane nedotčený), účty existující
jen v cíli se nikdy nemažou a bez `--overwrite` se existující jména přeskočí —
opakované spuštění tedy nic nerozbije. Bez `--from` se bere `data/users.db`
(resp. `P2L_DATA_DIR`); portable instalace má svou v `%APPDATA%\P2L-Tester\server-data`.

> **Past: `INITIAL_ADMIN_*` vs. migrace.** Když nad prázdnou databází nejdřív
> nastartuje server (nebo `npm run db-check`), `seedInitialAdmin` v ní vytvoří
> admina podle `INITIAL_ADMIN_USER` / `INITIAL_ADMIN_PASSWORD`. Migrace pak
> **tohle jméno přeskočí** a ten účet má heslo z `.env`, ne původní z SQLite —
> přihlášení starým heslem selže. Řešení: migrovat **před** prvním startem, nebo
> spustit `npm run migrate-users -- --overwrite`.

**Jednotky** se nepřenášejí skriptem — použij `GET /api/units/export` na starém serveru
a `POST /api/units/import` na novém (kompletní snímek včetně hesel a historie; import je
upsert, takže je idempotentní). Jde to i z appky: *Databáze P2L modulů* → ☰ →
*Exportovat / Importovat databázi*.

## Endpointy

Autentizace (DB1): chráněné endpointy přijímají session **cookie** (web) **nebo**
`Authorization: Bearer <JWT>` header (nativní klienti — EXE/APK, které cookies nedrží).
Cookie má přednost.

| Metoda | Path | Účel |
|--------|------|------|
| POST | `/api/login` | Body `{username, password, rememberMe?}` → 200 + Set-Cookie + `{ok, token, user:{username, isAdmin}}` / 401. `token` v body je pro nativní klienty (web ho ignoruje). `rememberMe` prodlouží TTL tokenu z 24 h na 7 dní. |
| POST | `/api/logout` | Smaže session cookie |
| GET | `/api/me` | Vrátí `{user: {username, isAdmin}}` nebo 401 |
| GET | `/api/health` | Health check pro monitoring; vrací `{ok, ts, db}`, kde `db` je typ driveru (`sqlite`/`mariadb`) — bez údajů o spojení |
| GET | `/api/firmware-list` | Proxy pro firmware autoindex serveru (obejde CORS na webu). Query param `?url=…`, vyžaduje přihlášení. |

Rate limit na `/api/login`: 50 pokusů / IP / 15 min.

CORS: když frontend a API sdílí domenu (Nginx servíruje web i `/api/*`), není potřeba nic.
Pro Flutter **web build servírovaný jinde** nastav `CORS_ORIGIN` (platí i v produkci, víc
originů odděl čárkou); `DEV_CORS_ORIGIN` je původní dev-only varianta. Nativní klienti
(EXE/APK) CORS neřeší.

## Databáze jednotek (DB2, PRD-DB)

Centrální evidence P2L jednotek (tabulky `units` + `unit_history`; u SQLite v samostatném
`data/units.db`, u MariaDB ve společné databázi — CRUD vrstva [db/units.js](db/units.js)).
Vše za přihlášením; ID se normalizuje (`u0128`/`001209` → `128`/`1209`).
**Seznam nikdy nevrací `desired_json` (hesla)** — jen detail karty; do historie se hesla nezapisují
(scrubSecrets maskuje klíče `pass/pswd/secret`).

| Metoda | Path | Účel |
|--------|------|------|
| GET | `/api/units` | Seznam karet (id, name, location, status, last_seen, firmware, …) — bez desired/devices; navíc `drift: bool` (nesoulad desired vs. observed u brokeru/SSID/jasu, počítá `computeDrift` server-side, aby seznam nenesl hesla) |
| GET | `/api/units/:id` | Kompletní karta (observed + desired + meta) |
| GET | `/api/units/:id/history` | Audit log karty (kdo/kdy/co, bez hesel) |
| PUT | `/api/units/:id/observed` | Upsert observed vrstvy (ALIVE / get_param / GET-DEVICES); merge — přepíší se jen dodaná pole (`mac`, `hwModel`, `firmware`, `ip`, `battery`, `ssid`, `mqttServer`, `mqttPort`, `brightness`, `seenOnBroker`, `devices`); založí kartu při prvním kontaktu; negeneruje historii. `seenOnBroker` = host brokeru, přes který appka jednotku vidí — plní se každým ALIVE (na rozdíl od `mqttServer` z get_param) a vstupuje do driftu |
| PUT | `/api/units/:id/desired` | Merge desired po top-level klíčích (`{broker}` / `{wifi}` / `{brightness}` / `{dispBrightness}` / `{fwUrl}`) — fragment přepíše jen svoje klíče + zápis fragmentu do historie |
| PUT | `/api/units/:id/meta` | Partial update meta (name / location / note / status ∈ active·faulty·stock·retired) + historie |
| POST | `/api/units/:id/change-id` | Body `{newId}` — přenese kartu vč. historie na nové ID (409 při kolizi) |
| DELETE | `/api/units/:id` | Smaže kartu + historii — **jen isAdmin** (403 jinak) |
| GET | `/api/units/export` | Kompletní záloha celé DB — všechny karty (observed + desired vč. hesel + meta) + historie; `{format:'p2l-tester.unit-db', version, exportedAt, units:[…]}`. Registrováno **před** `/:id` (jinak by spadlo do `/:id`) |
| POST | `/api/units/export` | Záloha **jen vybraných** jednotek — body `{ids:[…]}` (1 nebo víc); stejný formát jako GET. Tolerantní k chybějícím ID (přeskočí) |
| POST | `/api/units/import` | Obnova ze zálohy — **upsert po ID** (existující přepíše snímkem, nové přidá, cizí nechá; historie jednotky se nahradí → idempotentní). Ověřuje `format`; vrací `{created, updated, total}` |

## Testy

```bash
npm test             # node --test nad SQLite :memory: — nic se neinstaluje
npm run test:mariadb # tatáž sada proti reálné MariaDB (TEST_DB_NAME)
```

`npm run test:mariadb` testovací databázi **před každým testem maže**, proto
`TEST_DB_NAME` (default `P2Lunits_test`) nikdy nesmí ukazovat na produkční
`P2Lunits` — skript to kontroluje a odmítne se spustit.

Pozn.: `/api/health` je registrovaný před routery — dříve ho stínil `requireAuth`
firmware routeru a vracel 401 (opraveno v DB2).

## Admin endpointy (M4.5)

Vyžadují přihlášeného uživatele s `isAdmin` claim (jinak 403). Konzumuje je Flutter admin UI.

| Metoda | Path | Účel |
|--------|------|------|
| GET | `/api/admin/users` | Seznam uživatelů |
| POST | `/api/admin/users` | Vytvoří uživatele, body `{username, password, isAdmin?}` |
| DELETE | `/api/admin/users/:username` | Smaže uživatele |
| POST | `/api/admin/users/:username/reset` | Reset hesla, body `{newPassword}` |

## Správa uživatelů z CLI

```bash
npm run add-user -- <username> <password> [--admin]
npm run del-user -- <username>
npm run reset-pwd -- <username> <new-password>
npm run list-users
npm run db-check              # ověří spojení a vypíše, co v DB je
npm run migrate-users         # přenese účty ze SQLite users.db (viz výše)
```

Skripty jdou na databázi přímo (stejná konfigurace jako server, tj. `.env`) — fungují i když
Node service neběží. Pro produkční běh je `npm start` (`node server.js`); `npm run dev` přidává watch.

## Schéma DB

Viz [db/schema.sql](db/schema.sql) (resp. [db/schema.mariadb.sql](db/schema.mariadb.sql)).
Sloupec `is_admin` je od první migrace, aby M4.5 (Admin UI) nepotřebovala DB migraci.

## Závislosti a portable dist

`better-sqlite3` a `bcrypt` jsou **native** moduly — přiložený `node.exe` v portable
distribuci musí být té major verze, kterou se dělal `npm install` (viz
[tools/pack-portable.ps1](../tools/pack-portable.ps1)). `mysql2` je naopak čistě
JS, takže MariaDB podpora žádný build nekomplikuje.
