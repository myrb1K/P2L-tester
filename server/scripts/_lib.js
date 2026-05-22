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

module.exports = { die, parseArgs };
