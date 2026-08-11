# 05 — Deployment topologie

> **Status:** v0.4 · **Datum:** 2026-08-11 · **Parent:** [01-PRD.md](01-PRD.md)
>
> **Update v0.4 (M5):** Topologie z v0.3 (statika v `/var/www`, systemd, Nginx na hostu,
> `/ws` proxy na Mosquitto) je **nahrazená skutečností** — backend od v2.82 běží v Dockeru
> a od v2.85 je nasazený na `p2ltester.smartbox.smartci4.com` (image přes registry +
> Portainer). Web se proto nasazuje jako **druhý kontejner** vedle API, ne jako soubory na
> hostu; `/ws` proxy vůbec nevzniká, protože broker má vlastní WSS endpoint s platným
> certem. Routing dělá **Traefik**, web a API dostanou **vlastní subdomény 3. řádu**
> (`p2lweb.…` / `p2lapi.…`) — tedy cross-origin, viz §1. Mosquitto anonymní (§9.4).
>
> **Update v0.3:** Vercel jako mezikrok vyřazen — nasazení rovnou na firemní server. Důvody:
> jediný vývojář, lokální dev pokrývá iterace, Vercel build pipeline pro Flutter je netriviální,
> Hobby plán šedá zóna pro komerční use, auth backend by se psal dvakrát.

---

## 1. Cílová topologie (v0.4 — Docker)

Zvolená varianta (2026-08-11): **web a API dostanou vlastní subdomény**, routing dělá
Traefik dvěma nezávislými routery.

```
Browser ──HTTPS──> Traefik ──┬── p2lweb.domena.cz ──> `web`  (nginx + Flutter web build)
                             │                          └── / statika, SPA fallback na index.html
                             └── p2lapi.domena.cz ──> `api`  (Express :3001)
                                                        └── MariaDB (kontejner / firemní)

Browser ──WSS──> mqtt.smartbox.smartci4.com:443/mqtt   (broker, mimo tuhle topologii)
```

MQTT přes tuhle cestu neteče vůbec — appka jde na broker přímo.

### Co z oddělených domén plyne

| Oblast | Dopad |
|---|---|
| **Cookie** | Cross-origin, ale **same-site** (společná registrovatelná doména), takže `sameSite=lax` stačí a login projde. Jiná registrovatelná doména pro web by si vynutila `SameSite=None` — změna v [server/routes/auth.js](../server/routes/auth.js). |
| **CORS** | `CORS_ORIGIN=https://p2lweb.domena.cz` na API je **povinné**. Server to umí od M4 (`cors({origin, credentials: true})`), jen se to musí vyplnit. |
| **Build webu** | `--build-arg AUTH_API_BASE=https://p2lapi.domena.cz/api` — absolutní URL, ne `/api`. |
| **CSP** | `connect-src` musí obsahovat API origin, jinak prohlížeč zabije každé volání. Odvozuje ho build ze stejného build-argu → jeden zdroj pravdy. |
| **`TRUST_PROXY`** | Zůstává **1** — Traefik jde na `api` přímo, jeden hop. |
| **Nativní klienti** | Mají adresu API v buildu (`auth_api.dart`). Přestěhování API rozbije rozdané EXE/APK, dokud stará adresa nezůstane jako druhý router na `api`, nebo se nerozdistribuují nové buildy. |
| **Certifikát** | Nová subdoména ho potřebuje (u wildcardu netřeba). |

Config nginxu je pro všechny varianty routingu stejný; blok `location /api/` se uplatní jen
tehdy, kdyby web a API sdílely adresu (pak by ale platilo `TRUST_PROXY=2`, protože přibude hop).

### Co se změnilo proti v0.3 a proč

| v0.3 (návrh) | v0.4 (skutečnost) | Proč |
|---|---|---|
| Statika v `/var/www/p2l-tester` | `docker/nginx-web.conf` v image | Server je v Dockeru; nasazení = pull image, ne rsync |
| Nginx na hostu routuje `/`, `/api`, `/ws` | Vnější proxy → `web`, ten sám routuje `/` a `/api/` | Do vnější proxy stačí jeden zásah (přepnout cíl), path pravidla jsou v repu |
| systemd service pro backend | `restart: unless-stopped` v compose | Řeší Docker |
| `/ws` proxy na Mosquitto :9001 | **nevzniká** | Broker má vlastní WSS na 443 s platným certem (ověřeno v M2) |
| Let's Encrypt per subdoména | Řeší existující proxy | Doména už běží s HTTPS |

### Soubory

| Co | Kde |
|---|---|
| Build image (Flutter → nginx) | [Dockerfile.web](../Dockerfile.web) (kontext = root repa) |
| nginx config (SPA fallback, `/api/` proxy, CSP, cache) | [docker/nginx-web.conf](../docker/nginx-web.conf) |
| Služba `web` v compose | [server/docker-compose.yml](../server/docker-compose.yml), [server/docker-compose.external-db.yml](../server/docker-compose.external-db.yml) |
| Postup nasazení a pasti | [server/README.md §Webová varianta](../server/README.md#webová-varianta-flutter-web) |

---

## 2. Lokální dev workflow

| Účel | Příkaz |
|------|--------|
| Desktop iterace | `flutter run -d chrome --dart-define=AUTH_API_BASE=http://localhost:3001/api` |
| Mobilní real-device test (telefon na stejné WiFi) | `flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080` → na telefonu `http://<IP-počítače>:8080` |
| Lokální broker | `& "C:\Program Files\mosquitto\mosquitto.exe" -c .dev\mosquitto.conf -v` (viz [.dev/README.md](../.dev/README.md)) |
| Produkční build ručně | `flutter build web --release --no-web-resources-cdn --dart-define=AUTH_API_BASE=/api` |

**Past (Git Bash):** `--dart-define=AUTH_API_BASE=/api` v Git Bashi selže na
`'C:\Users\Radek' is not recognized` — MSYS přepíše hodnotu začínající `/` na Windows
cestu (a ta má v profilu mezeru). Spouštět **v PowerShellu**, nebo předřadit
`MSYS_NO_PATHCONV=1`. V Linuxovém build stage (`Dockerfile.web`) problém neexistuje.

Pro responzivita testing dostačuje Chrome DevTools mobile emulation (`Ctrl+Shift+M`).

---

## 3. CI/CD

Zatím ruční: `docker build -f Dockerfile.web` → push do registry → pull v Portaineru
(stejný postup, jakým se nasazuje backend). GitHub Actions job by dělal totéž — build
image a push; nasazení zůstane na Portaineru.

---

## 4. Versioning

- Verze v UI: stále z `appVersion` v [main.dart](../lib/main.dart).
- Web verze následuje stejné číslování jako native (žádné `2.87-web`, jen `2.87`).
- Tag image podle `appVersion` (`p2l-tester-web:2.87`), ať jde poznat, co na serveru běží.
- Pravidlo „neměnit `appVersion` automaticky" zůstává platné.

---

## 5. Rollback

Předchozí tag image zůstává v registry → rollback je pull starého tagu a `up -d web`
(proto tagovat verzí, ne jen `latest`). Databáze se rollbackem webu netýká — statika
žádný stav nemá.

---

## 6. Monitoring

- `web` kontejner: `HEALTHCHECK` na `/healthz` (obsluhuje nginx sám, takže nezávisí na API).
- `api` kontejner: `HEALTHCHECK` na `/api/health` (vrací i typ DB driveru).
- Logy: `docker compose logs -f web` / `… api`.

---

## 7. Open questions — dořešené

- **§9.3 doména** → **oddělené subdomény 3. řádu**: web na `p2lweb.<doména>`, API na
  `p2lapi.<doména>`, obojí z rootu (`/`). Podcesta by šla přes `--build-arg BASE_HREF=…`,
  ale není důvod. Otevřené zůstává, co se stávající `p2ltester.smartbox.smartci4.com`:
  buď zůstane jako alias na `api` (rozdané EXE/APK pak jedou dál), nebo se musí změnit
  konstanta v `auth_api.dart` a rozdistribuovat nové buildy.
- **§9.4 Mosquitto auth** → broker jede anonymně, credentials se v profilu nevyplňují
  (potvrzeno M2 proti produkčnímu brokeru).
- **Broker na stejném serveru?** → ne, zůstává samostatně. WSS na 443 s platným certem,
  takže proxy pro něj není potřeba.

---

## 8. Akceptační kritéria M5

Odškrtnuté položky jsou ověřené lokálním buildem image a spuštěným kontejnerem
(`docker build -f Dockerfile.web` + `docker run`), zbytek **čeká na nasazení**:

- [x] Statiku servíruje nginx v `web` kontejneru, SPA fallback na `index.html`.
- [x] `/api/*` proxy na `api:3001` pro případ nasazení na jedné doméně (přes `resolver`,
      takže restart API nginx nepoloží).
- [x] Bezpečnostní hlavičky: CSP, `nosniff`, `X-Frame-Options`, `Referrer-Policy`.
- [x] CSP `connect-src` se plní z `AUTH_API_BASE`, takže cross-origin volání API projde.
- [x] Cache: `no-cache` na statiku (Flutter nedává hash do názvů souborů).
- [x] Restart po rebootu serveru: `restart: unless-stopped`.
- [x] Rollback: předchozí tag image v registry.
- [ ] DNS + certifikát pro `p2lweb.…` (a `p2lapi.…`, pokud je nová).
- [ ] Routery v Traefiku: `p2lweb.…` → `web:80`, `p2lapi.…` → `api:3001`.
- [ ] Web sestavený s `--build-arg AUTH_API_BASE=https://p2lapi.…/api`.
- [ ] `CORS_ORIGIN=https://p2lweb.…` vyplněné na API a kontejner restartovaný.
- [ ] `TRUST_PROXY` odpovídá routingu (při přímém routeru na API zůstává `1`).
- [ ] Rozhodnuto, co se stávající adresou API kvůli rozdaným EXE/APK (alias vs. nové buildy).
- [ ] Login v prohlížeči projde, refresh neodhlásí (tj. cookie prošla cross-origin).
- [ ] Připojení k brokeru přes WSS a discovery jednotek funguje z webu.
- [ ] Konzole prohlížeče bez CSP a CORS hlášek.
