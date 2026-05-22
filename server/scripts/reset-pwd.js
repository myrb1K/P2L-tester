#!/usr/bin/env node
// Použití: node scripts/reset-pwd.js <username> <new-password>

const bcrypt = require('bcrypt');
const { openDb } = require('../db');
const { BCRYPT_ROUNDS } = require('../db/init');
const { die, parseArgs } = require('./_lib');

const { positional } = parseArgs(process.argv.slice(2));
const [username, password] = positional;

if (!username || !password) {
  die('Použití: node scripts/reset-pwd.js <username> <new-password>');
}

const db = openDb();
const exists = db.prepare('SELECT 1 FROM users WHERE username = ?').get(username);
if (!exists) die(`Uživatel '${username}' neexistuje.`);

const hash = bcrypt.hashSync(password, BCRYPT_ROUNDS);
db.prepare('UPDATE users SET password_hash = ? WHERE username = ?').run(hash, username);

console.log(`✓ Heslo pro '${username}' změněno.`);
