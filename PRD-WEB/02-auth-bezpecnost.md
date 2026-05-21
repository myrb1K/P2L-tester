# 02 — Auth a bezpečnost

> **Status:** Draft v0.2 · **Datum:** 2026-05-21 · **Parent:** [01-PRD.md](01-PRD.md)
>
> **Změny v v0.2:**
> - Auth se nyní implementuje **jako poslední milestone (M5)**, ne uprostřed. MQTT a responzivita jdou dřív.
> - Přidaná sekce **§9 Vercel staging protection** — mezikrok pro fázi 4, kdy ještě nemáme plnou auth, ale staging deploy nesmí být veřejný.

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
| Backend framework | Node.js + Express | Snadno přenositelné mezi Vercel Functions a firemním Node serverem |
| DB uživatelů | SQLite (vývoj / Vercel KV); Postgres (prod) | Stačí pár uživatelů, není potřeba clustering |
| Hashing | `bcrypt` (12+ rounds) nebo `argon2` | Standard |
| Session | **JWT v httpOnly cookie** | Funguje cross-origin (Vercel ↔ broker subdomain), bezpečnější než localStorage token |
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
- CORS pro Vercel preview origins (pro fázi staging)?
- Cross-subdomain cookie sharing nebo OAuth flow?

→ rozhodnutí blokuje [open question §9.1 v 01-PRD.md](01-PRD.md#91-integrace-s-ci4gui-auth).

### Varianta C — Mosquitto username/password (zamítnuto)

Login obrazovka by přihlásila uživatele přímo na MQTT broker. Žádný extra backend.

**Proč ne:**
- Správa uživatelů žije v mosquitto password file → admin musí na server.
- Frontend by držel MQTT credentials v paměti / cookie — to není reálná autentizace aplikace, jen prokliknutí přihlášení na broker.
- Žádná možnost session managementu (logout, expirace).

Necháváme jako orientační poznámku, použijeme **A nebo B**.

---

## 3. Doporučení

**Pro fázi 2 (auth MVP):** začít s **Variantou A** (vlastní lehký Node backend), protože:
- Není závislé na zjišťování ci4gui internals.
- Snadno se přesune z Vercel Functions na firemní server.
- Pokud později vyjde najevo, že ci4gui má použitelné API, přepneme na B (Flutter client kód se mění minimálně, jen kam volá `/api/login`).

**Pro fázi 4 (produkce):** vyhodnotit znovu po průzkumu ci4gui.

---

## 4. Bezpečnostní požadavky

| Oblast | Požadavek |
|--------|-----------|
| Transport | HTTPS na frontendu **a** WSS na brokeru. Bez výjimky v produkci (mixed content blocking). |
| Cookies | `httpOnly`, `Secure`, `SameSite=Lax` pro session cookie. |
| Passwords | Bcrypt/argon2, min. 12 znaků, žádné password reset přes email v MVP (admin reset). |
| Rate limiting | Login endpoint: max 5 pokusů / IP / 15 min. |
| CORS (Varianta A) | Backend povolí jen origin Vercel preview + produkční doménu. |
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
- **Vercel staging:** přes Vercel CLI / DB konzoli.
- **Produkce:** SQL skript na serveru, nebo malý CLI script `node scripts/add-user.js <username> <password>`.

Admin obrazovka ve Flutter je out-of-scope MVP — když uživatelů přibude, doděláme.

---

## 7. Risks

| Risk | Mitigation |
|------|------------|
| Cookie cross-subdomain (Vercel: app.vercel.app, broker: broker.smartci4.com) | JWT cookie bude vázán na Vercel doménu, MQTT auth (pokud bude) řešit zvlášť přes user/password na MQTT connect |
| `SameSite=Lax` nestačí, potřebujeme `None` kvůli iframe? | Nepotřebujeme — appka neběží v iframe. Lax je správně. |
| Vercel Functions cold start prodlouží login | Akceptovatelné — login je low frequency, pár stovek ms navíc OK |
| ci4gui auth integrace komplikovanější než vlastní | Začít Variantou A, B vyhodnotit při migraci do produkce |

---

## 9. Vercel staging protection (mezikrok pro M4)

Plnou auth (login screen, backend, DB) implementujeme až v M5. Mezi M4 (staging deploy) a M5 ale musíme zajistit, že **Vercel preview URL není veřejně přístupná** — kdokoli by jinak mohl ovládat brokery / publishnout MQTT příkazy.

### Možnosti podle Vercel plánu

| Plán | Možnost | Cena | Vhodné pro |
|------|---------|------|------------|
| **Pro** ($20/měs) | **Vercel Authentication** — preview vyžaduje login do Vercel teamu | 0 navíc | Doporučeno, pokud tým je 1–3 lidi |
| **Pro** | **Password Protection** — jedno sdílené heslo na deploy | 0 navíc | Pokud chceme dát URL i lidem mimo Vercel team |
| **Hobby (free)** | Vlastní placeholder login: 1 hardcoded heslo v Flutter app | 0 | Pokud nechceme upgradovat plán |
| **Hobby** | Upgrade na Pro | $20/měs | Pokud projekt poběží na Vercelu dlouho |

### Placeholder login (varianta pro Hobby plán)

Pokud nechceme upgrade, M4 přidá **minimální Flutter login obrazovku** s těmito vlastnostmi:

- 1 username + password hardcoded v `dart-define` build args (ne v repo).
- Po úspěšném loginu se uloží flag do `localStorage` (`auth=true`).
- Při startu appky se flag zkontroluje → buď LoginScreen, nebo HomeScreen.
- Žádný backend, žádná session validace na server straně.

**Co to NEzajistí:**
- Nikdo nedrží relaci → kdokoli může nastavit `localStorage.auth=true` v DevTools a obejít login.
- Heslo je v JS bundlu (decompilable).
- Není to skutečná autentizace, jen **deterrent proti náhodnému přístupu**.

To je akceptovatelné pro staging, kde URL stejně nikomu nedáváme. Pro produkci ale M5 musí přepsat plnohodnotnou auth (Varianta A nebo B z §2).

### Doporučení

- **Pokud Radek upgraduje Vercel na Pro:** použít Vercel Authentication (žádný kód navíc, hotovo za 5 minut).
- **Pokud zůstane na Hobby:** udělat placeholder login v M4 a v M5 ho přepsat na plnou auth (kód není mnoho, dá se vyhodit).

---

## 10. Akceptační kritéria

- [ ] Nepřihlášený uživatel je vždy přesměrován na `LoginScreen`.
- [ ] Login s validními credentials zobrazí `HomeScreen` a uloží session cookie.
- [ ] Refresh stránky uživatele neodhlašuje.
- [ ] Logout invaliduje session (následné `GET /api/me` vrátí 401).
- [ ] Špatný login zobrazí chybovou zprávu, žádné session se nezaloží.
- [ ] Rate limit po 5 pokusech / IP / 15 min funguje.
- [ ] Cookies mají `Secure`, `HttpOnly`, `SameSite=Lax`.
