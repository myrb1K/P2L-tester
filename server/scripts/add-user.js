#!/usr/bin/env node
// Použití: node scripts/add-user.js <username> <password> [--admin]

const bcrypt = require('bcrypt');
const { openDb } = require('../db');
const { BCRYPT_ROUNDS } = require('../db/init');
const { die, parseArgs } = require('./_lib');

const { positional, flags } = parseArgs(process.argv.slice(2));
const [username, password] = positional;

if (!username || !password) {
  die('Použití: node scripts/add-user.js <username> <password> [--admin]');
}

const db = openDb();
const exists = db.prepare('SELECT 1 FROM users WHERE username = ?').get(username);
if (exists) die(`Uživatel '${username}' už existuje.`);

const hash = bcrypt.hashSync(password, BCRYPT_ROUNDS);
const isAdmin = flags.has('admin') ? 1 : 0;

db.prepare(
  'INSERT INTO users (username, password_hash, is_admin) VALUES (?, ?, ?)'
).run(username, hash, isAdmin);

console.log(`✓ Uživatel '${username}' vytvořen${isAdmin ? ' jako admin' : ''}.`);
