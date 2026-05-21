# 02 — Auth a bezpečnost

> **Status:** Draft v0.3 · **Datum:** 2026-05-22 · **Parent:** [01-PRD.md](01-PRD.md)
>
> **Změny v v0.3:**
> - **Vercel mezikrok vyřazen** — nasazujeme rovnou na firemní server, takže placeholder login (`§9` v v0.2) zmizel a píšeme rovnou plnohodnotnou auth (M4 v novém číslování).
> - Backend cíleně Node.js na firemním serveru, žádné Vercel Functions.
>
> **Změny v v0.2:**
> - Auth se nyní implementuje **jako poslední milestone**, ne uprostřed. MQTT a responzivita jdou dřív.

Návrh autentizace a bezpečnostních požadavků pro webovou variantu P2L Testeru.

---

## 1. Požadavky

| # | Požadavek |
|---|-----------|
| A1 | Login obrazovka před přístupem ke zbytku aplikace. |
| A2 | Po úspěšném loginu se zobrazí standardní `HomeScreen`. |
| A3 | Žádné role — všichni přihlášení mají plný přístup. |
| A4 | Žádná self-registrace — účty zakládá admin. |
| A5 | Session persistence (refresh stránky neodhlašuje). |
| A6 | Session timeout: 7 dní s "remember me", jinak 24 h. |
| A7 | Logout button dostupný z user menu / AppBar. |
| A8 | Password reset přes admina (DB / admin obrazovka), ne přes email. |

---

## 2. Architektura — varianty

### Varianta A — vlastní lehký backend (doporučeno pokud ci4gui nemá použitelné API)

Vlastní Node.js (Express / Fastify) backend s těmito vlastnostmi:

| Vrstva | Volba | Důvod |
|--------|-------|-------|
| Backend framework | Node.js + Express (nebo Fastify) | Standardní, runs as systemd service na firemním serveru |
| DB uživatelů | SQLite (vývoj) / SQLite nebo Postgres (prod) | Stačí pár uživatelů, není potřeba clustering |
| Hashing | `bcrypt` (12+ rounds) nebo `argon2` | Standard |
| Session | **JWT v httpOnly cookie** | Bezpečnější než localStorage token, funguje same-origin (frontend i `/api` pod stejnou doménou) |
| Endpointy | `POST /api/login`, `POST /api/logout`, `GET /api/me` | Minimální plocha |

**API skica:**

```
POST /api/login
  Body: { username: string, password: string, rememberMe?: boolean }
  Response 200: { ok: true, user: { username } }      // + Set-Cookie session=<JWT>
  Response 401: { ok: false, error: "invalid_credentials" }

POST /api/logout
  Response 200: { ok: true }                          // + Set-Cookie session=; Max-Age=0

GET /api/me
  Response 200: { user: { username } }
  Response 401: { error: "not_authenticated" }
```

**JWT payload:**
```json
{
  "sub": "<username>",
  "iat": 1716290000,
  "exp": 1716894800
}
```

**Cookie:** `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, `Max-Age=86400` (24 h) nebo `604800` (7 dní s remember me).

### Varianta B — integrace s `ci4gui` auth

Pokud `ci4gui.smartbox.smartci4.com` poskytuje:
- JWT/cookie session, kterou si Flutter aplikace umí vyžádat a používat,
- API endpoint k získání aktuálního uživatele (`GET /api/me` ekvivalent),

→ P2L Tester web by se zapojil na stejnou auth a nepotřeboval vlastní backend.

**Otevřené k zjištění:**
- Forma auth (cookie session vs. bearer token)?
- Endpointy?
- Cross-subdomain cookie sharing nebo OAuth flow (pokud bude P2L Tester pod jinou subdoménou než ci4gui)?

→ rozhodnutí blokuje [open question §9.1 v 01-PRD.md](01-PRD.md#9-open-questions).

### Varianta C — Mosquitto username/password (zamítnuto)

Login obrazovka by přihlásila uživatele přímo na MQTT broker. Žádný extra backend.

**Proč ne:**
- Správa uživatelů žije v mosquitto password file → admin musí na server.
- Frontend by držel MQTT credentials v paměti / cookie — to není reálná autentizace aplikace, jen prokliknutí přihlášení na broker.
- Žádná možnost session managementu (logout, expirace).

Necháváme jako orientační poznámku, použijeme **A nebo B**.

---

## 3. Doporučení

**Pro M4:** začít s **Variantou A** (vlastní lehký Node backend), protože:
- Není závislé na zjišťování ci4gui internals.
- Snadno se nasadí jako systemd service vedle ci4gui.
- Pokud později vyjde najevo, že ci4gui má použitelné API, přepneme na B (Flutter client kód se mění minimálně, jen kam volá `/api/login`).

**Pokud se ukáže, že ci4gui má použitelnou auth:** v rámci M5 (firemní server deploy) můžeme přepnout na variantu B a vlastní backend vyhodit.

---

## 4. Bezpečnostní požadavky

| Oblast | Požadavek |
|--------|-----------|
| Transport | HTTPS na frontendu **a** WSS na brokeru. Bez výjimky v produkci (mixed content blocking). |
| Cookies | `httpOnly`, `Secure`, `SameSite=Lax` pro session cookie. |
| Passwords | Bcrypt/argon2, min. 12 znaků, žádné password reset přes email v MVP (admin reset). |
| Rate limiting | Login endpoint: max 5 pokusů / IP / 15 min. |
| CORS (Varianta A) | Backend běží same-origin (`/api/*` proxyovaný Nginxem) → CORS odpadá. |
| MQTT WS | Pokud broker podporuje user/password, použít je. ACL: minimálně omezit publish na `I/+/...` topicy. |
| Brute force MQTT | Mosquitto má `auth_plugin` / fail2ban — out of scope tohoto PRD, ale upozornit IT. |
| CSP | `Content-Security-Policy` header v Nginx — povolit jen vlastní origin + WSS k brokeru. |
| Audit log | Nice-to-have pro fázi 4: log loginů a hromadných akcí (firmware OTA, REPLACE-FROM). |

---

## 5. Flutter integrace

### Login obrazovka

Nová obrazovka `LoginScreen` v [lib/screens/](../lib/screens/). Routing pattern:

```
App start
  └─ check GET /api/me
       ├─ 200 → HomeScreen
       └─ 401 → LoginScreen
```

Po úspěšném loginu → navigace na `HomeScreen` (`Navigator.pushReplacement`).

### HTTP klient

`http` package (už používaný pro firmware listing) — přidat:
- `withCredentials: true` (Flutter web) pro odeslání cookies.
- Centrální wrapper `AuthApi` (login/logout/me).

### Logout

PopupMenu / drawer item v `HomeScreen` AppBar → `POST /api/logout` → navigace zpět na `LoginScreen`.

### Auto-logout při 401

HTTP interceptor: pokud kterákoli odpověď vrátí 401, smazat lokální stav a přesměrovat na `LoginScreen`.

---

## 6. Admin správa uživatelů (MVP)

Pro MVP **nemáme admin UI**. Účty zakládá Radek:
- **Lokální vývoj:** přímo přes SQLite CLI nebo přidání seed skriptu.
- **Produkce:** SQL skript na serveru, nebo malý CLI script `node scripts/add-user.js <username> <password>`.

Admin obrazovka ve Flutter je out-of-scope MVP — když uživatelů přibude, doděláme.

---

## 7. Risks

| Risk | Mitigation |
|------|------------|
| Cookie cross-subdomain (pokud bude P2L Tester pod jinou subdoménou než broker) | JWT cookie bude vázán na frontend doménu; MQTT auth (pokud bude) řešit zvlášť přes user/password na MQTT connect |
| `SameSite=Lax` nestačí, potřebujeme `None` kvůli iframe? | Nepotřebujeme — appka neběží v iframe. Lax je správně. |
| ci4gui auth integrace komplikovanější než vlastní | Začít Variantou A, B vyhodnotit při M5 |

---

## 9. Akceptační kritéria

- [ ] Nepřihlášený uživatel je vždy přesměrován na `LoginScreen`.
- [ ] Login s validními credentials zobrazí `HomeScreen` a uloží session cookie.
- [ ] Refresh stránky uživatele neodhlašuje.
- [ ] Logout invaliduje session (následné `GET /api/me` vrátí 401).
- [ ] Špatný login zobrazí chybovou zprávu, žádné session se nezaloží.
- [ ] Rate limit po 5 pokusech / IP / 15 min funguje.
- [ ] Cookies mají `Secure`, `HttpOnly`, `SameSite=Lax`.
