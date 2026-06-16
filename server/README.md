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

| Metoda | Path | Účel |
|--------|------|------|
| POST | `/api/login` | Body `{username, password, rememberMe?}` → 200 + Set-Cookie + `{ok, user:{username, isAdmin}}` / 401. `rememberMe` prodlouží TTL tokenu z 24 h na 7 dní. |
| POST | `/api/logout` | Smaže session cookie |
| GET | `/api/me` | Vrátí `{user: {username, isAdmin}}` nebo 401 |
| GET | `/api/health` | Health check pro monitoring |
| GET | `/api/firmware-list` | Proxy pro firmware autoindex serveru (obejde CORS na webu). Query param `?url=…`, vyžaduje přihlášení. |

Rate limit na `/api/login`: 50 pokusů / IP / 15 min. CORS pro dev přes `DEV_CORS_ORIGIN`.

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
