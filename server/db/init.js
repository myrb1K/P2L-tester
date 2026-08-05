// Initial admin seed — spouští se při startu server.js.
// Vytvoří admin uživatele z env, pokud je tabulka users prázdná.

const bcrypt = require('bcrypt');
const { nowIso } = require('./adapter');

const BCRYPT_ROUNDS = 12;

async function seedInitialAdmin(db) {
  const { n: count } = await db.get('SELECT COUNT(*) AS n FROM users');
  if (count > 0) return { seeded: false, reason: 'users table not empty' };

  const username = (process.env.INITIAL_ADMIN_USER || '').trim();
  const password = process.env.INITIAL_ADMIN_PASSWORD || '';

  if (!username || !password) {
    return {
      seeded: false,
      reason: 'INITIAL_ADMIN_USER / INITIAL_ADMIN_PASSWORD not set — manual user creation required',
    };
  }

  const hash = bcrypt.hashSync(password, BCRYPT_ROUNDS);
  await db.run(
    `INSERT INTO users (username, password_hash, is_admin, created_at)
     VALUES (:username, :password_hash, 1, :created_at)`,
    { username, password_hash: hash, created_at: nowIso() }
  );

  return { seeded: true, username };
}

module.exports = { seedInitialAdmin, BCRYPT_ROUNDS };
