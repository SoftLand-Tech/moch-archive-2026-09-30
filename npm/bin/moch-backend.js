#!/usr/bin/env node
// moch-backend — one command to install the Moch mobile backend.
// Thin launcher: runs the shipped install.sh with bash and passes through
// every argument (install.sh defaults are already Moch-appropriate).
'use strict'

const { spawnSync } = require('node:child_process')
const path = require('node:path')
const fs = require('node:fs')

const script = path.join(__dirname, '..', 'install.sh')

function usage() {
  console.log(`moch-backend — install the Moch backend (mobile agent gateway)

Usage:
  moch-backend               install to ~/.moch, start the backend, print the pairing QR
  moch-backend --help        this help
  moch-backend --manifest    print installer stages as JSON (for scripting)

Extra installer options:
  --no-serve                 install without starting the backend services
  --with-browser             also install the browser tools (agent-browser + Chromium)
  --with-computer-use        also install the computer-use driver
  --interactive              run the hermes setup wizard interactively
  --dir PATH                 install into a custom directory
  --verbose                  stream every child command's output

Docs: https://github.com/SoftLand-Tech/moch#readme`)
}

if (process.argv.slice(2).some((a) => a === '-h' || a === '--help')) {
  usage()
  process.exit(0)
}

if (process.platform === 'win32') {
  console.error('moch-backend: Windows is not supported yet.')
  console.error('Install WSL2 first, then run this command inside WSL:')
  console.error('  curl -fsSL https://raw.githubusercontent.com/SoftLand-Tech/moch/main/scripts/install.sh | bash')
  process.exit(1)
}

if (!fs.existsSync(script)) {
  console.error(`moch-backend: installer script missing at ${script} — package is broken, please report it.`)
  process.exit(1)
}

const bash = spawnSync('bash', [script, ...process.argv.slice(2)], {
  stdio: 'inherit',
  env: process.env,
})

if (bash.error && bash.error.code === 'ENOENT') {
  console.error("moch-backend: 'bash' not found — the Moch backend needs a Unix shell.")
  process.exit(127)
}

process.exit(bash.status ?? 1)
