# 02 — Auth a bezpečnost

> **Status:** Draft v0.6 · **Datum:** 2026-05-22 · **Parent:** [01-PRD.md](01-PRD.md)
>
> **Změny v v0.6:**
> - **M4.5 ✅ dokončeno 2026-05-22** — admin endpointy v [server/routes/admin.js](../server/routes/admin.js), sdílená knihovna [server/db/users.js](../server/db/users.js), [lib/screens/admin_users_screen.dart](../lib/screens/admin_users_screen.dart). Strukturální fix `AuthGate` přes `MaterialApp.builder` (řeší route isolation pro InheritedWidget). Všech 7 akceptačních kritérií §9.2 odškrtnutých. Rate limit zvolněn z 5 na 50/IP/15min po praktické zkušenosti.
>
> **Změny v v0.5:**
> - **M4 ✅ dokončeno 2026-05-22** — backend `server/`, Flutter `lib/services/auth_*` + `lib/screens/{auth_gate,login_screen}.dart`, CLI skripty. Všech 11 akceptačních kritérií §9.1 odškrtnutých. Commits `93874d0`, `6a14043`, `a747ea9`.
>
> **Změny v v0.4:**
> - **Varianta A (vlastní Node backend) ROZHODNUTA** — viz §2.A a §3. Varianta B (ci4gui integrace) zůstává jako fallback, pokud později vyjde najevo, že má ci4gui použitelnou auth.
> - **Admin UI rozděleno na M4 a M4.5** — M4 dodá jen login (uživatelé spravováni přes CLI skripty na serveru), M4.5 přidá `AdminUsersScreen` ve Flutteru. Klíčové: schéma DB i JWT už od M4 obsahují `is_admin` / `isAdmin`, aby M4.5 byla čistá additive změna bez migrace.
> - §6 přepsáno: detailní specifikace M4 (CLI správa) vs. M4.5 (Admin UI).
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

## 3. Rozhodnutí (2026-05-22)

**Pro M4 jdeme cestou Varianty A** — vlastní lehký Node backend + SQLite + JWT v httpOnly cookie. Důvody:
- Nezávisíme na zjišťování ci4gui internals (B blokované [§9.1 v 01-PRD.md](01-PRD.md#9-open-questions)).
- Snadno se nasadí jako systemd service vedle ci4gui.
- Pokud později vyjde najevo, že ci4gui má použitelné API, přepnutí na B je nízkonákladová refaktor (mění se jen URL, kam Flutter klient volá).

### Stack

| Vrstva | Volba |
|--------|-------|
| Runtime | Node.js 20 LTS |
| Framework | Express |
| DB | SQLite přes `better-sqlite3` (jeden soubor, žádný server) |
| Hashing | `bcrypt` (12 rounds) |
| Session | JWT (`jsonwebtoken`) v httpOnly + Secure + SameSite=Lax cookie |
| Rate limit | `express-rate-limit` (5 pokusů / IP / 15 min na `/api/login`) |
| Service management | systemd unit, běží jako neprivilegovaný user |

### Fázování M4 / M4.5

**M4 (jako součást této etapy):** Plnohodnotný login pro běžné uživatele. Správa uživatelů přes CLI skripty na serveru přes SSH. Detail v §6.

**M4.5 (volitelně později, samostatný milestone):** `AdminUsersScreen` ve Flutteru — uživatel s `isAdmin=true` může z UI spravovat účty. Detail v §6.

**Pokud se ukáže, že ci4gui má použitelnou auth:** v rámci M5 můžeme přepnout na variantu B a vlastní backend vyhodit.

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

## 6. Admin správa uživatelů — M4 + M4.5

Rozděleno na dvě etapy. **M4 ship-uje login pro běžné uživatele se správou přes CLI**; **M4.5 přidá Admin UI ve Flutteru** jako čistě aditivní změnu, pokud reálné používání ukáže, že je potřeba.

### 6.1 Klíčový princip — co musí být v M4 správně od začátku

Aby M4.5 byla bezbolestná (žádná migrace, žádná breaking change), **M4 už musí obsahovat**:

1. **Schéma `users` tabulky obsahuje `is_admin BOOLEAN NOT NULL DEFAULT 0`** od první migrace.
2. **JWT payload obsahuje claim `isAdmin: true/false`** — i když ho Flutter v M4 zatím nevyužívá.
3. **Initial admin user** se vytváří automaticky při prvním startu Node service z env proměnných:
   ```
   INITIAL_ADMIN_USER=radek
   INITIAL_ADMIN_PASSWORD=<heslo, které admin po prvním loginu změní>
   ```
   Skript pro initial seed se spustí jen pokud je tabulka `users` prázdná.

Pokud na cokoli z těchto tří zapomeneme, M4.5 vyžaduje DB migraci nebo invalidaci existujících session → ztráta minimalistické čistoty fázování.

### 6.2 M4 — Správa uživatelů přes CLI

V M4 admin UI ve Flutteru NENÍ. Účty spravuje Radek z příkazové řádky na serveru:

```bash
ssh smartbox-server
cd /opt/p2l-tester-auth

# Přidat uživatele
node scripts/add-user.js <username> <password> [--admin]

# Smazat uživatele
node scripts/del-user.js <username>

# Reset hesla
node scripts/reset-pwd.js <username> <new-password>

# Seznam uživatelů
node scripts/list-users.js
```

Skripty otevřou `data/users.db` přímo (synchronně přes `better-sqlite3`), provedou operaci, vypíší výsledek. **Žádné HTTP, žádná dependence na běžícím backend procesu** — funguje, i když Node service neběží.

Tyto skripty jsou nutnou součástí M4 deliveru — bez nich se uživatelé spravovat nedají.

### 6.3 M4.5 — Admin UI ve Flutteru (později)

Doplnění poté, co M4 běží v produkci a má smysl admin UI doplnit (typicky: uživatelů přibývá, nebo někdo jiný než Radek má spravovat účty).

**Backend přibyde:**

```
GET    /api/admin/users                  → seznam uživatelů { username, isAdmin, createdAt }
POST   /api/admin/users                  → { username, password, isAdmin? } → 201 / 409 (duplikát)
DELETE /api/admin/users/:username        → 204 / 404
POST   /api/admin/users/:username/reset  → { newPassword } → 200
```

Všechny chráněné middleware `requireAdmin` (kontroluje JWT claim `isAdmin === true`). Backend zároveň brání:
- Smazat sebe sama (vrátí 400).
- Odebrat admin status / smazat **posledního** admina (vrátí 400) — DB nesmí zůstat bez admina.

**Flutter přibyde:**

- `AdminUsersScreen` v [lib/screens/](../lib/screens/) — seznam uživatelů + tlačítka [+ Nový], [🔑 Reset], [🗑 Smazat], badge "admin" u uživatelů s rolí.
- Položka **"Administrace uživatelů"** v `SettingsScreen` — viditelná **jen pokud aktuální user má `isAdmin: true`** (čte z `/api/me` response).
- Dialogy pro vytvoření / reset / potvrzení smazání.

**Žádná změna v existujícím LoginScreen / AuthGate / běžných endpointech.** M4.5 je čistá additive změna.

### 6.4 Effort

| Etapa | Effort |
|-------|--------|
| M4 (login + CLI skripty) | 2–3 dny |
| M4.5 (Admin UI: backend endpointy + Flutter screen + dialogy + testy) | +1 den |

### 6.5 Kdy M4.5 reálně dělat

- Pokud Radek přidává/mění uživatele ≤ 1× měsíčně → CLI stačí, M4.5 odkládat.
- Pokud frekvence vyroste, nebo má někdo jiný než Radek spravovat účty → M4.5 zahájit.
- M4.5 lze klidně nikdy nezahájit, pokud SSH workflow vyhovuje.

---

## 7. Risks

| Risk | Mitigation |
|------|------------|
| Cookie cross-subdomain (pokud bude P2L Tester pod jinou subdoménou než broker) | JWT cookie bude vázán na frontend doménu; MQTT auth (pokud bude) řešit zvlášť přes user/password na MQTT connect |
| `SameSite=Lax` nestačí, potřebujeme `None` kvůli iframe? | Nepotřebujeme — appka neběží v iframe. Lax je správně. |
| ci4gui auth integrace komplikovanější než vlastní | Začít Variantou A, B vyhodnotit při M5 |

---

## 9. Akceptační kritéria

### 9.1 M4 (login + CLI správa) — ✅ DOKONČENO 2026-05-22

- [x] Nepřihlášený uživatel je vždy přesměrován na `LoginScreen`.
- [x] Login s validními credentials zobrazí `HomeScreen` a uloží session cookie.
- [x] Refresh stránky uživatele neodhlašuje.
- [x] Logout invaliduje session (následné `GET /api/me` vrátí 401).
- [x] Špatný login zobrazí chybovou zprávu, žádné session se nezaloží.
- [x] Rate limit po 5 pokusech / IP / 15 min funguje (potvrzeno `RateLimit-Limit: 5` headery).
- [x] Cookies mají `HttpOnly`, `SameSite=Lax`. **`Secure` se zapne automaticky v produkci** přes `NODE_ENV=production` (v dev běží přes HTTP a Secure by spojení rozbilo).
- [x] DB schéma obsahuje `is_admin BOOLEAN` od první migrace ([server/db/schema.sql](../server/db/schema.sql)).
- [x] JWT payload obsahuje claim `isAdmin` ([server/routes/auth.js](../server/routes/auth.js) `signToken`).
- [x] Initial admin user se vytvoří při prvním startu z env, pokud je `users` tabulka prázdná ([server/db/init.js](../server/db/init.js) `seedInitialAdmin`).
- [x] CLI skripty `add-user.js`, `del-user.js`, `reset-pwd.js`, `list-users.js` fungují a manipulují přímo se SQLite souborem ([server/scripts/](../server/scripts/)). `del-user` má guard proti smazání posledního admina.
- [x] **Native APK / Windows EXE auth NEPOUŽÍVAJÍ** (`kIsWeb` guard v [lib/main.dart](../lib/main.dart) `_AppEntry`).

Implementační commits: `93874d0` (backend), `6a14043` (gitignore fix), `a747ea9` (Flutter).

### 9.2 M4.5 (Admin UI) — ✅ DOKONČENO 2026-05-22

- [x] Uživatel s `isAdmin=true` vidí v `SettingsScreen` položku "Administrace uživatelů".
- [x] Uživatel bez admin role tu položku NEVIDÍ.
- [x] `AdminUsersScreen` umí: seznam, přidání, reset hesla, smazání.
- [x] Admin nemůže smazat sám sebe (UI: tlačítko disabled + šedá ikona; backend 400).
- [x] Backend odmítne smazat posledního admina (vrátí 400 `last_admin`). Stejný guard sdílen s CLI přes [server/db/users.js](../server/db/users.js).
- [x] Všechny admin endpointy chráněné middleware `requireAdmin` — non-admin dostane 403.
- [x] Žádná DB migrace nebyla potřeba (`is_admin` sloupec už z M4).

#### Implementační poznámky

- **Strukturální fix `AuthGate` v widget tree**: přesunut **nad** `MaterialApp.Navigator` přes `builder:` parametr ([lib/main.dart](../lib/main.dart)). Důvod: `_AuthScope` jako InheritedWidget je teď viditelný pro **všechny pushnuté routy** (Settings, AdminUsersScreen), nejen pro home route. Routy pushnuté přes `Navigator.push` jsou v Overlay **sourozenci** root route, takže InheritedWidget uvnitř root route je jim neviditelný. Pre-fix: admin karta v Settings se nikdy nezobrazila, protože `AuthScope.userOf(context)` v Settings vracel `null`.
- **UX**: na webu vyřazen `SplashScreen` (LoginScreen už má branding s logem a verzí); na nativu (APK/EXE) splash zůstává kvůli Android 12+ ikoně.
- **Sdílená user-management knihovna**: [server/db/users.js](../server/db/users.js) s `createUser` / `deleteUser` / `resetPassword` / `listUsers` + `UserOpError` třídou. Používají ji jak admin endpointy ([server/routes/admin.js](../server/routes/admin.js)), tak CLI skripty ([server/scripts/](../server/scripts/)) — guardy (duplicate, last-admin, self-delete) jsou tím DRY.
- **Rate limit**: práh zvýšen z 5 na 50 pokusů / IP / 15 min po praktické zkušenosti v devu — striktních 5 zamykalo i běžné typo a zapomenutí hesla. 50 stále efektivně chrání proti rychlému brute force proti bcrypt-12 (~3.5 pokusů/s strop).
