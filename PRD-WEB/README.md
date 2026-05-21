# PRD-WEB — Plánování webové varianty P2L Testeru

Webová varianta P2L Testeru pro branch `WEB`. Tato složka obsahuje veškerou plánovací dokumentaci, mockupy, výsledky průzkumu a draft API specifikace.

## Obsah

| Dokument | Co obsahuje |
|----------|-------------|
| [01-PRD.md](01-PRD.md) | Hlavní PRD: cíl, fáze, scope, funkční požadavky, milestones, akceptační kritéria, open questions |
| [02-auth-bezpecnost.md](02-auth-bezpecnost.md) | Návrh autentizace (vlastní backend vs. integrace s ci4gui), security požadavky |
| [03-mqtt-web.md](03-mqtt-web.md) | MQTT klient na webu — `MqttBrowserClient`, conditional imports, WSS + CORS rizika |
| [04-responzivita.md](04-responzivita.md) | Responzivita UX, breakpointy, místa v UI k úpravě |
| [05-deployment.md](05-deployment.md) | Deployment topologie — Vercel staging + finální firemní server |

## Status

- **v0.1** (2026-05-21) — první draft, rozdělený do dílčích dokumentů
- **Branch:** `WEB`
- **Autor:** Radek Brym

## Příští kroky

1. Projít [open questions](01-PRD.md#9-open-questions) s kolegou (hlavně auth integrace s ci4gui a MQTT credentials).
2. Začít M1 podle [milestones](01-PRD.md#10-milestones).

## Konvence

- Nové dokumenty: prefix `NN-` pro zachování pořadí (`06-mockups.md`, `07-api-spec.md` apod.).
- Mockupy / screenshoty: podsložka `assets/`.
- Když se něco rozhodne / uzavře, aktualizovat dotčený dokument a poznamenat datum změny do hlavičky.
