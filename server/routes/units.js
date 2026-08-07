// REST API centrální databáze jednotek (PRD-DB/01-PRD.md §5, milestone DB2).
//
// Všechny endpointy za přihlášením (cookie nebo Bearer — requireAuth).
// DELETE navíc vyžaduje isAdmin. Zásada: seznam NIKDY nevrací desired_json
// (hesla) — kompletní kartu vrací jen detail.
//
// Zápisové endpointy volá appka jako vedlejší efekt akcí (DB3):
//   PUT /:id/observed  ← ALIVE / get_param / GET-DEVICES
//   PUT /:id/desired   ← set_Mqtt / set_WiFi / jas / OTA
//   PUT /:id/meta      ← uživatel edituje název/umístění/poznámku/stav
//   POST /:id/change-id ← change_ID (karta se přenáší vč. historie)
//
// Datová vrstva je asynchronní (db/adapter.js — SQLite i MariaDB), takže
// handlery jsou async a `wrap` awaituje.

const express = require('express');

const { requireAuth } = require('./auth');
const {
  UnitOpError,
  listUnits,
  getUnit,
  upsertObserved,
  updateDesired,
  updateMeta,
  changeUnitId,
  deleteUnit,
  bulkUpdateDesired,
  bulkUpdateMeta,
  bulkDeleteUnits,
  commonDesired,
  getHistory,
  exportUnits,
  importUnits,
  listChanges,
  applySyncOps,
} = require('../db/units');

function mapErrorToStatus(err) {
  switch (err.code) {
    case 'not_found':
      return 404;
    case 'duplicate':
      return 409;
    case 'invalid_id':
    case 'invalid_status':
    case 'invalid_body':
    case 'same_id':
      return 400;
    default:
      return 500;
  }
}

// Obalí handler try/catch na UnitOpError → JSON chyba se správným statusem.
function wrap(handler) {
  return async (req, res, next) => {
    try {
      await handler(req, res);
    } catch (e) {
      if (e instanceof UnitOpError) {
        return res.status(mapErrorToStatus(e)).json({ error: e.code, message: e.message });
      }
      next(e);
    }
  };
}

function makeRouter(db) {
  const router = express.Router();
  router.use(requireAuth);

  router.get('/', wrap(async (req, res) => {
    res.json({ units: await listUnits(db) });
  }));

  // Export / import celé DB (kompletní záloha / obnova). MUSÍ být před /:id,
  // jinak by GET /export spadl do /:id (id='export' → 400). Za přihlášením
  // (requireAuth výš), bez admin gatingu — hesla už jsou na kartě viditelná
  // přihlášenému a upsert (sloučení) nic nemaže, jen jako ostatní zápisy.
  // Společný obal zálohy (stejný formát pro celou DB i podmnožinu).
  async function exportEnvelope(ids) {
    return {
      format: 'p2l-tester.unit-db',
      version: 1,
      exportedAt: new Date().toISOString(),
      units: await exportUnits(db, ids),
    };
  }

  // GET = celá DB; POST {ids} = jen vybrané jednotky (1 nebo víc).
  router.get('/export', wrap(async (req, res) => {
    res.json(await exportEnvelope(null));
  }));

  router.post('/export', wrap(async (req, res) => {
    const { ids } = req.body || {};
    res.json(await exportEnvelope(ids));
  }));

  router.post('/import', wrap(async (req, res) => {
    const body = req.body || {};
    if (body.format !== 'p2l-tester.unit-db') {
      return res
        .status(400)
        .json({ error: 'invalid_body', message: 'Neznámý formát souboru (očekávám zálohu databáze).' });
    }
    const result = await importUnits(db, body.units, req.user.username);
    res.json({ ok: true, ...result });
  }));

  // ── Synchronizace (DB9, PRD-DB/03-PRD-sync.md §6) ─────────────────────
  // Obojí MUSÍ být před /:id, jinak by 'changes' / 'sync' spadlo do detailu.

  // Rozdílový pull. `since` = poslední revize, kterou klient má (0 = bootstrap).
  // Na rozdíl od GET / vrací desired VČETNĚ hesel — lokální DB klienta je nese,
  // jinak by offline evidenci nešlo zobrazit (viz komentář u listChanges).
  router.get('/changes', wrap(async (req, res) => {
    const since = parseInt(req.query.since, 10);
    const limit = parseInt(req.query.limit, 10);
    res.json(await listChanges(
      db,
      Number.isFinite(since) ? since : 0,
      Number.isFinite(limit) ? limit : undefined
    ));
  }));

  // Dávkový push outboxu. Idempotentní přes opId, mazání jen pro admina.
  // `sourceDevice` je informativní popis klienta pro audit (exe@NB-RADEK).
  router.post('/sync', wrap(async (req, res) => {
    const { ops, sourceDevice } = req.body || {};
    res.json(await applySyncOps(db, ops, {
      username: req.user.username,
      isAdmin: !!req.user.isAdmin,
      sourceDevice: typeof sourceDevice === 'string' ? sourceDevice.slice(0, 64) : null,
    }));
  }));

  router.get('/:id', wrap(async (req, res) => {
    const unit = await getUnit(db, req.params.id);
    if (!unit) return res.status(404).json({ error: 'not_found' });
    res.json({ unit });
  }));

  router.get('/:id/history', wrap(async (req, res) => {
    const unit = await getUnit(db, req.params.id);
    if (!unit) return res.status(404).json({ error: 'not_found' });
    res.json({ history: await getHistory(db, req.params.id) });
  }));

  router.put('/:id/observed', wrap(async (req, res) => {
    const id = await upsertObserved(db, req.params.id, req.body || {});
    res.json({ ok: true, id });
  }));

  router.put('/:id/desired', wrap(async (req, res) => {
    const id = await updateDesired(db, req.params.id, req.body, req.user.username);
    res.json({ ok: true, id });
  }));

  router.put('/:id/meta', wrap(async (req, res) => {
    const id = await updateMeta(db, req.params.id, req.body || {}, req.user.username);
    res.json({ ok: true, id });
  }));

  router.post('/:id/change-id', wrap(async (req, res) => {
    const { newId } = req.body || {};
    if (typeof newId !== 'string' && typeof newId !== 'number') {
      return res.status(400).json({ error: 'invalid_body', message: 'Chybí newId.' });
    }
    const id = await changeUnitId(db, req.params.id, String(newId), req.user.username);
    res.json({ ok: true, id });
  }));

  router.delete('/:id', wrap(async (req, res) => {
    if (!req.user.isAdmin) {
      return res.status(403).json({ error: 'admin_required' });
    }
    await deleteUnit(db, req.params.id, req.user.username);
    res.status(204).end();
  }));

  // ── Hromadné operace ──────────────────────────────────────────────────
  // POST (ne PUT/DELETE) + pevné cesty /bulk/* → nekolidují s /:id routami.
  router.post('/bulk/desired', wrap(async (req, res) => {
    const { ids, fragment } = req.body || {};
    const count = await bulkUpdateDesired(db, ids, fragment, req.user.username);
    res.json({ ok: true, count });
  }));

  router.post('/bulk/meta', wrap(async (req, res) => {
    const { ids, meta } = req.body || {};
    const count = await bulkUpdateMeta(db, ids, meta || {}, req.user.username);
    res.json({ ok: true, count });
  }));

  // Společné hodnoty evidence vybraných (předvyplnění dialogu hromadné editace).
  router.post('/bulk/common-desired', wrap(async (req, res) => {
    const { ids } = req.body || {};
    res.json({ common: await commonDesired(db, ids) });
  }));

  router.post('/bulk/delete', wrap(async (req, res) => {
    if (!req.user.isAdmin) {
      return res.status(403).json({ error: 'admin_required' });
    }
    const { ids } = req.body || {};
    const count = await bulkDeleteUnits(db, ids, req.user.username);
    res.json({ ok: true, count });
  }));

  return router;
}

module.exports = { makeRouter };
