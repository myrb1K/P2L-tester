# 01 — PRD: P2L Tester Web

> **Status:** Draft v0.2 · **Datum:** 2026-05-21 · **Autor:** Radek Brym · **Branch:** `WEB`
>
> **Změny v v0.2:**
> - Pořadí fází přeskupeno — **auth je až jako poslední milestone** (M5 / M6), MQTT a responzivita dřív.
> - Responzivita zkrácena na verify-only (Android APK i zmenšené Windows okno už fungují skvěle). Viz [04-responzivita.md](04-responzivita.md).
> - Přidán mezikrok **Vercel built-in ochrana** pro staging deploy bez plné auth. Viz [02-auth-bezpecnost.md](02-auth-bezpecnost.md).

Hlavní dokument PRD. Detailní návrhy jsou v sourozeneckých dokumentech:
- Auth a security → [02-auth-bezpecnost.md](02-auth-bezpecnost.md)
- MQTT na webu → [03-mqtt-web.md](03-mqtt-web.md)
- Responzivita → [04-responzivita.md](04-responzivita.md)
- Deployment → [05-deployment.md](05-deployment.md)

---

## 1. Cíl projektu

Rozšířit P2L Tester (dosud Windows / Android) o **webovou variantu**, která:

1. Poběží v prohlížeči (desktop + mobil) bez instalace.
2. Je **responzivní** — použitelná jak na desktopu, tak na mobilu.
3. Je **chráněná uživatelským přihlášením** (admin zakládá účty, žádná self-registrace).
4. Komunikuje s MQTT brokery přes **WebSockets** (broker už WS endpoint má povolený).
5. Nasadí se nejprve na **Vercel** (vývoj / staging), finálně na **firemní server** vedle [`ci4gui.smartbox.smartci4.com`](https://ci4gui.smartbox.smartci4.com).

### Co tento projekt **není**

- Není to refactor existujícího Flutter kódu na jiný framework. Cílíme na **Flutter Web** build stejného codebase.
- Není to nová verze MQTT protokolu. Topicy a payloady zůstávají identické.
- Nezavádíme tenant isolaci, role ani per-user data. Po přihlášení **všichni uživatelé vidí to samé**.

---

## 2. Cílový stav a fázování (v0.2)

Pořadí je voleno tak, aby **nejvyšší technické riziko (MQTT WSS)** šlo nejdřív a **auth byla naposledy** — staging je mezitím chráněn Vercel built-in ochranou.

### Fáze 1 — Web build běží lokálně
- `flutter build web` projde bez chyb.
- Aplikace se otevře v Chrome bez crashe (zatím bez MQTT, bez auth).
- Identifikace `dart:io` použití mimo `MqttService` a zabalení do `kIsWeb` guards.

### Fáze 2 — MQTT přes WebSockets (high risk milestone)
- `MqttClientFactory` s conditional importem (`MqttServerClient` ↔ `MqttBrowserClient`).
- Lokální Mosquitto s WS listenerem → connect z `flutter run -d chrome`.
- Lokální WSS přes `mkcert` → ověřit, že TLS endpoint funguje.
- Otestovat na reálném produkčním brokeru (subscribe + publish).

Detaily viz [03-mqtt-web.md](03-mqtt-web.md).

### Fáze 3 — Responzivita (verify only)
- Smoke test v Chrome DevTools device emulation (iPhone, Pixel).
- Opravit edge cases specifické pro browser (klávesnice, hover).
- **Žádný velký refactor — APK už je responzivní.**

Detaily viz [04-responzivita.md](04-responzivita.md).

### Fáze 4 — Vercel staging deploy (chráněný)
- `vercel.json` + build pipeline (Flutter SDK install).
- Deploy na Vercel preview URL.
- **Ochrana proti náhodnému přístupu:** Vercel Authentication (Pro plán) **nebo** minimální placeholder login (1 hardcoded heslo) — žádná plná auth zatím.
- E2E ověření: WSS connect ze staging URL na produkční broker.

Detaily viz [05-deployment.md](05-deployment.md).

### Fáze 5 — Plnohodnotná auth
- Login obrazovka (Flutter) před přístupem ke zbytku aplikace.
- Backend `/api/login`, `/api/logout`, `/api/me` (Node.js + JWT v httpOnly cookie).
- Session persistence, logout button, admin reset přes DB / CLI script.
- Rate limiting na login endpoint.
- **Rozhodnutí o ci4gui integraci** — zjištěné v rámci open question §9.1, buď zapojit na ci4gui auth, nebo dokončit vlastní backend.

Detaily viz [02-auth-bezpecnost.md](02-auth-bezpecnost.md).

### Fáze 6 — Produkční nasazení na firemní server
- Migrace z Vercel na server kde běží `ci4gui`.
- HTTPS s validním certifikátem (Let's Encrypt nebo firemní CA).
- Reverse proxy (Nginx) pro statický web + proxy `/ws` na Mosquitto.
- Systemd service pro auth backend.
- Rollback strategie (záloha předchozí verze před deploy).

Detaily viz [05-deployment.md](05-deployment.md).

---

## 3. Funkční požadavky

### 3.1 Paritní funkce s desktop/mobile verzí

Webová varianta musí podporovat **všechny současné funkce** P2L Testeru:

- Discovery jednotek (ALIVE topic subscribe)
- Manuální přidání ID jednotky
- Detail jednotky (IP, MAC, firmware, baterie)
- LED test pattern (color, on/off duration, port selection)
- Konfigurace devices (ADD/RECREATE-DEVICES)
- REPLACE-FROM workflow pro výměnu vadného čipu
- Hromadná změna brokera / WiFi (`BulkConfigMenu`)
- Hromadný OTA firmware update
- Šablony zařízení (vč. export/import)
- Profily brokerů (přidávání, reorder, mazání)
- Export/import seznamu ID jednotek

### 3.2 Webově specifické funkce

- **Persistent storage**: `SharedPreferences` na webu používá `localStorage` — funguje out-of-the-box. Ověřit limity (~5 MB / origin).
- **File picker pro import/export**: `file_picker` a `share_plus` mají web implementaci, ale chování je odlišné (download místo share, browse místo path). Otestovat.
- **Clipboard**: kopírování ID/IP přes browser clipboard API.
- **Window title**: nastavit `<title>` v `web/index.html`.
- **Favicon + PWA manifest**: použít existující `Smartboxlogo.png`.

### 3.3 Autentizace

Krátký souhrn (detaily v [02-auth-bezpecnost.md](02-auth-bezpecnost.md)):

- Login obrazovka před přístupem ke zbytku aplikace.
- Po úspěšném loginu se zobrazí standardní `HomeScreen`.
- **Žádné role** — všichni přihlášení mají plný přístup.
- **Žádná self-registrace** — účty zakládá admin.
- Session timeout: 7 dní s "remember me", jinak 24 h.

---

## 4. Technický stack

| Vrstva | Volba |
|--------|-------|
| Frontend | **Flutter Web** (existující codebase, target `web`) |
| MQTT klient | `mqtt_client` — `MqttServerClient` na native, `MqttBrowserClient` na webu (conditional import) |
| Auth backend | Node.js (Express) + JWT v httpOnly cookie (nebo integrace s ci4gui auth) |
| DB | SQLite (vývoj) / Postgres (prod) — vlastní `users` tabulka |
| Hosting (vývoj) | Vercel (frontend) + Vercel Functions / Render / Railway (backend) |
| Hosting (prod) | Firemní server (Nginx + Node + Mosquitto WS) |
| CI/CD | GitHub Actions: na push do `WEB` → `flutter build web` → deploy Vercel preview |

Detail MQTT klienta na webu viz [03-mqtt-web.md](03-mqtt-web.md).
Detail deployment topologie viz [05-deployment.md](05-deployment.md).

---

## 5. Out of scope (zatím)

- **Multi-tenant / per-user data isolation** — všichni vidí všechno.
- **Role (admin/technik/read-only)** — všichni přihlášení mají plný přístup.
- **OAuth / SSO s Google/Microsoft** — jen username/password.
- **Password reset přes email** — admin reset přes DB / admin obrazovku.
- **2FA / TOTP** — nice-to-have pro pozdější iteraci.
- **PWA offline mode** — appka stejně bez brokeru nic nedělá, offline cache nemá smysl.
- **Audit log** — odsunuto do fáze 4+.

---

## 6. Risks summary

Detailní rizika jsou v jednotlivých dokumentech podle oblasti. Zde top 5 napříč:

| Risk | Pravděpodobnost | Dopad | Kam pro detail |
|------|-----------------|-------|----------------|
| Mixed content: HTTPS site ↔ ws:// broker | Vysoká | App nefunguje | [03-mqtt-web.md](03-mqtt-web.md) |
| Browser CORS na MQTT WS endpoint | Vysoká | Connect selže | [03-mqtt-web.md](03-mqtt-web.md) |
| `dart:io` použití v existujícím kódu | Střední | Runtime chyby na webu | [03-mqtt-web.md](03-mqtt-web.md) |
| ci4gui auth integrace komplikovanější než vlastní backend | Střední | Posun harmonogramu | [02-auth-bezpecnost.md](02-auth-bezpecnost.md) |
| Refresh page = ztráta MQTT connection a in-memory state | Jistota | UX issue | [03-mqtt-web.md](03-mqtt-web.md) |

---

## 7. Akceptační kritéria MVP

- [ ] Web build běží na Vercelu pod HTTPS.
- [ ] Nepřihlášený uživatel vidí jen login obrazovku, žádný jiný route.
- [ ] Po loginu existuje session, refresh stránky uživatele neodhlásí.
- [ ] Logout button funguje a invaliduje session.
- [ ] Aplikace se připojí přes WSS k brokeru s validním certem.
- [ ] Discovery jednotek funguje (ALIVE topic).
- [ ] LED test pattern funguje na vybrané jednotce.
- [ ] Hromadné konfigurace (broker / WiFi / firmware) projdou bez chyb.
- [ ] Layout je použitelný na 360 px šířce (žádný horizontální scroll).
- [ ] Tap targety na mobilu ≥ 44 px.
- [ ] Smartbox logo a název v záhlaví.

---

## 8. Out-of-scope decisions / commitments

- Všichni uživatelé vidí to samé (žádné role).
- Admin zakládá účty manuálně, žádná self-registrace.
- Vercel pro vývoj/staging, firemní server pro produkci.

---

## 9. Open questions

### 9.1 Integrace s `ci4gui` auth

Má `ci4gui.smartbox.smartci4.com` REST API / JWT endpoint, který by P2L Tester mohl konzumovat? Pokud ano:
- Ušetříme implementaci vlastního auth backend.
- Uživatelé budou mít jeden login pro obě appky.

**Akce:** zjistit s kolegou, jak je `ci4gui` postavený a jestli má SSO-friendly auth.

### 9.2 Konkrétní broker pro web testing

Které brokery už mají WSS endpoint živý a s validním certifikátem? Pro fázi 1 stačí jeden testovací (může být i self-signed na localhost s `mkcert`).

### 9.3 Doména pro produkční nasazení

- Subdoména `p2l.smartbox.smartci4.com`?
- Path pod `ci4gui` (`ci4gui.../p2l-tester`)?
- Jiné?

### 9.4 Mosquitto user/password vs. anonymous

Má broker zapnutý `allow_anonymous false`? Pokud ano, jsou MQTT credentials per-user (uvedené při loginu) nebo shared (zaháknuté v backendu)?

### 9.5 Branding a launch

- Loga, název v záhlaví, favicon — použít existující `Smartboxlogo.png`?
- Verze v UI — z `appVersion` v [`main.dart`](../lib/main.dart) (stávající mechanismus stačí).

---

## 10. Milestones (v0.3 — M1–M3 ✅)

| # | Milestone | Stav | Pozn. |
|---|-----------|:----:|-------|
| M1 | `flutter build web` projde, app se otevře v Chrome | ✅ | Web build prošel out-of-the-box; `kIsWeb` guards už v kódu; brand polish v `web/index.html` + `manifest.json` |
| M2 | MQTT WS klient přes `MqttBrowserClient`, connect k lokálnímu brokeru | ✅ | `MqttClientFactory` s conditional importem; klíčový fix: `websocketProtocols = ['mqtt']`; E2E ověřeno proti lokálnímu Mosquitto + ALIVE roundtrip |
| M3 | Responzivita smoke test | ✅ | Pixel 7 + iPad Mini OK bez úprav; iPhone SE (375px) skipnuto (relevance) |
| M4 | Vercel staging deploy s placeholder loginem (Hobby plán) | příští | |
| M5 | Plnohodnotná auth (backend + login screen + session) | čeká M4 | Závislé na rozhodnutí ci4gui integrace |
| M6 | Migrace na firemní server (Nginx, HTTPS, systemd) | čeká M5 | |

---

**Příští krok:** projít open questions s kolegou (hlavně 9.1 — ci4gui auth a 9.4 — MQTT credentials), pak začít M1.
