#!/usr/bin/env node
// moch — one command for the Moch mobile backend.
//
//   backend not installed  → runs the bundled install.sh (installer mode)
//   backend installed      → delegates to ~/.moch/moch-backend/scripts/moch-serve.sh
//                            (qr, status, restart, stop, uninstall — and bare
//                            `moch` re-runs the idempotent setup, reprinting the QR)
//
// Installer-only flags (--manifest, --no-serve, --with-*, ...) always go to
// install.sh, even on an installed machine. Published as `softland-moch`
// (plain `moch` was taken on npm); the command is `moch`.
'use strict'

const { spawnSync } = require('node:child_process')
const path = require('node:path')
const fs = require('node:fs')
const os = require('node:os')

const script = path.join(__dirname, '..', 'install.sh')
const serveScript = path.join(os.homedir(), '.moch', 'moch-backend', 'scripts', 'moch-serve.sh')
const CONTROL_SUBCOMMANDS = new Set(['setup', 'status', 'restart', 'stop', 'qr', 'uninstall', 'import-hermes'])

function usage() {
  console.log(`moch — install and control the Moch backend (mobile agent gateway)

Usage:
  moch                       install if needed; if installed, re-verify services + reprint the QR
  moch qr                    pairing QR + token
  moch status                backend health
  moch restart | stop        service control
  moch import-hermes         bring a ~/.hermes install's providers/skills/memories/cron/sessions over
  moch uninstall [--purge]   remove services and command (add --purge to delete ~/.moch data)

Installer options (work before/after install):
  --manifest                 print installer stages as JSON (for scripting)
  --no-serve                 install without starting the backend services
  --with-browser             also install the browser tools (agent-browser + Chromium)
  --with-computer-use        also install the computer-use driver
  --interactive              run the hermes setup wizard interactively
  --verbose                  stream every child command's output

Docs: https://github.com/SoftLand-Tech/moch#readme`)
}

const args = process.argv.slice(2)
const isControl = args.length > 0 && CONTROL_SUBCOMMANDS.has(args[0])
const isFlag = args.length > 0 && args[0].startsWith('-')

// Installed + control intent → delegate to the installed control script.
if (fs.existsSync(serveScript) && isControl) {
  const run = spawnSync('bash', [serveScript, ...args], { stdio: 'inherit', env: process.env })
  process.exit(run.status ?? 1)
}

if (args.includes('--help') || args.includes('-h')) {
  usage()
  process.exit(0)
}

// Installed + anything else non-flag (auth login, cron, skills, doctor, …)
// → the backend's own CLI, HERMES_HOME-scoped.
if (fs.existsSync(serveScript) && !isFlag) {
  const hermes = path.join(os.homedir(), '.moch', 'moch-backend', '.hermes', 'bin', 'hermes')
  if (fs.existsSync(hermes)) {
    const run = spawnSync(hermes, args, {
      stdio: 'inherit',
      env: { ...process.env, HERMES_HOME: path.join(os.homedir(), '.moch') },
    })
    process.exit(run.status ?? 1)
  }
}

if (process.platform === 'win32') {
  console.error('moch: Windows is not supported yet.')
  console.error('Install WSL2 first, then run this command inside WSL:')
  console.error('  curl -fsSL https://raw.githubusercontent.com/SoftLand-Tech/moch/main/scripts/install.sh | bash')
  process.exit(1)
}

if (!fs.existsSync(script)) {
  console.error(`moch: installer script missing at ${script} — package is broken, please report it.`)
  process.exit(1)
}

const bash = spawnSync('bash', [script, ...args], {
  stdio: 'inherit',
  env: process.env,
})

if (bash.error && bash.error.code === 'ENOENT') {
  console.error("moch: 'bash' not found — the Moch backend needs a Unix shell.")
  process.exit(127)
}

process.exit(bash.status ?? 1)
