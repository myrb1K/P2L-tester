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
  return (req, res, next) => {
    try {
      handler(req, res);
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

  router.get('/', wrap((req, res) => {
    res.json({ units: listUnits(db) });
  }));

  router.get('/:id', wrap((req, res) => {
    const unit = getUnit(db, req.params.id);
    if (!unit) return res.status(404).json({ error: 'not_found' });
    res.json({ unit });
  }));

  router.get('/:id/history', wrap((req, res) => {
    const unit = getUnit(db, req.params.id);
    if (!unit) return res.status(404).json({ error: 'not_found' });
    res.json({ history: getHistory(db, req.params.id) });
  }));

  router.put('/:id/observed', wrap((req, res) => {
    const id = upsertObserved(db, req.params.id, req.body || {});
    res.json({ ok: true, id });
  }));

  router.put('/:id/desired', wrap((req, res) => {
    const id = updateDesired(db, req.params.id, req.body, req.user.username);
    res.json({ ok: true, id });
  }));

  router.put('/:id/meta', wrap((req, res) => {
    const id = updateMeta(db, req.params.id, req.body || {}, req.user.username);
    res.json({ ok: true, id });
  }));

  router.post('/:id/change-id', wrap((req, res) => {
    const { newId } = req.body || {};
    if (typeof newId !== 'string' && typeof newId !== 'number') {
      return res.status(400).json({ error: 'invalid_body', message: 'Chybí newId.' });
    }
    const id = changeUnitId(db, req.params.id, String(newId), req.user.username);
    res.json({ ok: true, id });
  }));

  router.delete('/:id', wrap((req, res) => {
    if (!req.user.isAdmin) {
      return res.status(403).json({ error: 'admin_required' });
    }
    deleteUnit(db, req.params.id);
    res.status(204).end();
  }));

  // ── Hromadné operace ──────────────────────────────────────────────────
  // POST (ne PUT/DELETE) + pevné cesty /bulk/* → nekolidují s /:id routami.
  router.post('/bulk/desired', wrap((req, res) => {
    const { ids, fragment } = req.body || {};
    const count = bulkUpdateDesired(db, ids, fragment, req.user.username);
    res.json({ ok: true, count });
  }));

  router.post('/bulk/meta', wrap((req, res) => {
    const { ids, meta } = req.body || {};
    const count = bulkUpdateMeta(db, ids, meta || {}, req.user.username);
    res.json({ ok: true, count });
  }));

  // Společné hodnoty evidence vybraných (předvyplnění dialogu hromadné editace).
  router.post('/bulk/common-desired', wrap((req, res) => {
    const { ids } = req.body || {};
    res.json({ common: commonDesired(db, ids) });
  }));

  router.post('/bulk/delete', wrap((req, res) => {
    if (!req.user.isAdmin) {
      return res.status(403).json({ error: 'admin_required' });
    }
    const { ids } = req.body || {};
    const count = bulkDeleteUnits(db, ids);
    res.json({ ok: true, count });
  }));

  return router;
}

module.exports = { makeRouter };
