# P2L Tester — Auth Backend

Node.js + SQLite + JWT backend pro webovou variantu P2L Testeru ([PRD-WEB/02-auth-bezpecnost.md](../PRD-WEB/02-auth-bezpecnost.md)).

## Quick start (lokálně)

```bash
cd server
cp .env.example .env
# Vyplň JWT_SECRET — vygeneruj: openssl rand -hex 32 (nebo node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
npm install
npm run dev
```

Backend poslouchá na `http://localhost:3001`. Při prvním startu se vytvoří `data/users.db` a založí initial admin podle `INITIAL_ADMIN_USER` / `INITIAL_ADMIN_PASSWORD`.

## Endpointy

Autentizace (DB1): chráněné endpointy přijímají session **cookie** (web) **nebo**
`Authorization: Bearer <JWT>` header (nativní klienti — EXE/APK, které cookies nedrží).
Cookie má přednost.

| Metoda | Path | Účel |
|--------|------|------|
| POST | `/api/login` | Body `{username, password, rememberMe?}` → 200 + Set-Cookie + `{ok, token, user:{username, isAdmin}}` / 401. `token` v body je pro nativní klienty (web ho ignoruje). `rememberMe` prodlouží TTL tokenu z 24 h na 7 dní. |
| POST | `/api/logout` | Smaže session cookie |
| GET | `/api/me` | Vrátí `{user: {username, isAdmin}}` nebo 401 |
| GET | `/api/health` | Health check pro monitoring |
| GET | `/api/firmware-list` | Proxy pro firmware autoindex serveru (obejde CORS na webu). Query param `?url=…`, vyžaduje přihlášení. |

Rate limit na `/api/login`: 50 pokusů / IP / 15 min. CORS pro dev přes `DEV_CORS_ORIGIN`.

## Databáze jednotek (DB2, PRD-DB)

Centrální evidence P2L jednotek v samostatném `data/units.db` ([db/units-schema.sql](db/units-schema.sql),
CRUD vrstva [db/units.js](db/units.js)). Vše za přihlášením; ID se normalizuje (`u0128`/`001209` → `128`/`1209`).
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

## Testy

```bash
npm test    # node --test (bez závislostí) — test/units.test.js
```

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
```

Skripty pracují přímo se SQLite souborem — fungují i když Node service neběží. Pro produkční běh je `npm start` (`node server.js`); `npm run dev` přidává watch.

## Schéma DB

Viz [db/schema.sql](db/schema.sql). Sloupec `is_admin` je od první migrace, aby M4.5 (Admin UI) nepotřebovala DB migraci.
