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
| POST | `/api/login` | Body `{username, password}` → 200 + Set-Cookie / 401 |
| POST | `/api/logout` | Smaže session cookie |
| GET | `/api/me` | Vrátí `{user: {username, isAdmin}}` nebo 401 |
| GET | `/api/health` | Health check pro monitoring |

## Správa uživatelů (M4)

```bash
npm run add-user -- <username> <password> [--admin]
npm run del-user -- <username>
npm run reset-pwd -- <username> <new-password>
npm run list-users
```

Skripty pracují přímo se SQLite souborem — fungují i když Node service neběží.

## Schéma DB

Viz [db/schema.sql](db/schema.sql). Sloupec `is_admin` je od první migrace, aby M4.5 (Admin UI) nepotřebovala DB migraci.
