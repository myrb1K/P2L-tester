// Sdílené utility pro CLI skripty.

const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

function die(msg, code = 1) {
  console.error(msg);
  process.exit(code);
}

function parseArgs(argv) {
  const positional = [];
  const flags = new Set();
  for (const a of argv) {
    if (a.startsWith('--')) flags.add(a.slice(2));
    else positional.push(a);
  }
  return { positional, flags };
}

/// Otevře DB (driver dle DB_DRIVER), pustí `fn(db)` a spojení vždy zavře —
/// bez toho by MariaDB pool držel event loop a skript by nedoběhl.
///
/// Očekávané chyby (UserOpError z guardů) skončí čitelnou hláškou a exit 1,
/// cokoli jiného vypíše stack.
function runCli(fn) {
  const { openDb } = require('../db');
  const { UserOpError } = require('../db/users');

  (async () => {
    const db = await openDb();
    try {
      await fn(db);
    } finally {
      await db.close();
    }
  })().catch((e) => {
    if (e instanceof UserOpError) die(e.message);
    console.error(e);
    process.exit(1);
  });
}

module.exports = { die, parseArgs, runCli };
