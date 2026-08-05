// Admin endpointy (M4.5). Vše chráněné requireAdmin middleware:
// JWT musí být platné A mít claim isAdmin === true, jinak 403.
//
// Bezpečnostní guardy (společné s CLI v db/users.js):
// - createUser: 409 při duplikátu
// - deleteUser: 400 self-delete, 400 last-admin
// - resetPassword: 404 not_found

const express = require('express');
const jwt = require('jsonwebtoken');

const { tokenFromReq } = require('./auth');
const {
  listUsers,
  createUser,
  deleteUser,
  resetPassword,
  UserOpError,
} = require('../db/users');

function requireAdmin(req, res, next) {
  const token = tokenFromReq(req); // cookie (web) nebo Bearer (nativ, DB1)
  if (!token) return res.status(401).json({ error: 'no_session' });

  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET);
    if (!payload.isAdmin) {
      return res.status(403).json({ error: 'admin_required' });
    }
    req.user = { username: payload.sub, isAdmin: !!payload.isAdmin };
    next();
  } catch {
    return res.status(401).json({ error: 'invalid_session' });
  }
}

function mapErrorToStatus(err) {
  switch (err.code) {
    case 'duplicate':
      return 409;
    case 'not_found':
      return 404;
    case 'self_delete':
    case 'last_admin':
    case 'invalid_username':
    case 'invalid_password':
      return 400;
    default:
      return 500;
  }
}

// Obalí async handler: UserOpError → JSON chyba se správným statusem,
// cokoli jiného na error middleware (Express 4 rejected promise nezachytí).
function wrap(handler) {
  return async (req, res, next) => {
    try {
      await handler(req, res);
    } catch (e) {
      if (e instanceof UserOpError) {
        return res.status(mapErrorToStatus(e)).json({ error: e.code, message: e.message });
      }
      next(e);
    }
  };
}

function makeRouter(db) {
  const router = express.Router();
  router.use(requireAdmin);

  router.get('/users', wrap(async (req, res) => {
    res.json({ users: await listUsers(db) });
  }));

  router.post('/users', wrap(async (req, res) => {
    const { username, password, isAdmin } = req.body || {};
    const user = await createUser(db, { username, password, isAdmin: !!isAdmin });
    res.status(201).json({
      user: {
        username: user.username,
        isAdmin: !!user.isAdmin,
      },
    });
  }));

  router.delete('/users/:username', wrap(async (req, res) => {
    await deleteUser(db, req.params.username, { actingUser: req.user.username });
    res.status(204).end();
  }));

  router.post('/users/:username/reset', wrap(async (req, res) => {
    const { newPassword } = req.body || {};
    await resetPassword(db, req.params.username, newPassword);
    res.json({ ok: true });
  }));

  return router;
}

module.exports = { makeRouter, requireAdmin };
