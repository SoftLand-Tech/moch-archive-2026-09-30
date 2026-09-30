#!/usr/bin/env node
// Moch interactive wizard — the friendly face of install + phone pairing.
//
// Two flows, both driven by the existing engines (install.sh stages,
// moch-serve.sh setup/pairinfo/ts-link) so the bash behavior stays the
// single source of truth:
//   runInstall(script)  — stage checklist with spinners + elapsed time
//   runPairing(serve)   — anywhere/lan choice, tailscale sign-in panel, QR
//
// Only ever runs on a real interactive TTY with @clack/prompts loadable;
// every other context (npm postinstall, pipes, old node) falls back to the
// plain bash flow in bin/moch.js. Opt out with MOCH_NO_WIZARD=1.
'use strict'
const { spawn, spawnSync } = require('node:child_process')
const path = require('node:path')
const fs = require('node:fs')
const os = require('node:os')

let p = null
try { p = require('@clack/prompts') } catch { /* not installed / old node */ }

const APP_RELEASES = 'https://github.com/SoftLand-Tech/Relay/releases'

function available() {
  return !!p
    && !!process.stdout.isTTY
    && !!process.stdin.isTTY
    && process.env.MOCH_NO_WIZARD !== '1'
    && process.env.npm_lifecycle_event !== 'postinstall'
}

// ---- helpers -----------------------------------------------------------------

function run(script, args, opts = {}) {
  return spawnSync('bash', [script, ...args], { encoding: 'utf8', ...opts })
}

function manifest(script) {
  const r = run(script, ['--manifest'])
  if (r.status !== 0) return []
  try { return JSON.parse(r.stdout).stages || [] } catch { return [] }
}

function pairInfo(serve) {
  const r = run(serve, ['pairinfo'])
  if (r.status !== 0) return null
  const out = {}
  for (const line of String(r.stdout || '').split('\n')) {
    const i = line.indexOf('=')
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1).trim()
  }
  return out.TOKEN ? out : null
}

function fmtElapsed(ms) {
  const s = Math.floor(ms / 1000)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

function printQr(text) {
  try {
    require('qrcode-terminal').generate(text, { small: true })
  } catch {
    console.log(`  (qr renderer unavailable — type the link below instead)\n`)
    console.log(`  ${text}`)
  }
}

function phoneSteps(anywhere) {
  const lines = []
  if (anywhere) {
    lines.push('  1. Install the "Tailscale" app (Play Store) and sign in with the')
    lines.push('     SAME account you just used in the browser. Keep it connected —')
    lines.push('     that is what lets Moch reach this computer from anywhere.')
  } else {
    lines.push('  1. Make sure the phone is on the same Wi-Fi as this computer.')
  }
  lines.push('  2. Install the Moch app on your phone:')
  lines.push(`     ${APP_RELEASES}`)
  lines.push('  3. Open Moch → add a computer → scan the QR code below.')
  return lines
}

// ---- install -----------------------------------------------------------------

async function runInstall(script) {
  const stages = manifest(script)
  if (!stages.length) return 'engine'   // caller falls back to plain install.sh

  p.intro('Moch — your AI agent at home, in your pocket')
  p.log.message('This installs the Moch backend into ~/.moch and sets up')
  p.log.message('phone pairing. It needs internet, about 1 GB of disk and')
  p.log.message('10–15 minutes. Nothing needs sudo.')

  const go = await p.confirm({ message: 'Install Moch now?', initialValue: true })
  if (p.isCancel(go) || !go) {
    p.outro('No problem — run `moch` whenever you are ready.')
    return 'cancel'
  }

  const logPath = path.join(os.homedir(), '.moch', 'install.log')
  fs.mkdirSync(path.dirname(logPath), { recursive: true })
  const log = fs.openSync(logPath, 'a')
  fs.writeSync(log, `\n=== moch wizard install ${new Date().toISOString()} ===\n`)

  // `setup`/`gateway` run hermes' own terminal wizard — not part of the Moch
  // flow (provider keys come later via `moch auth login`).
  const skip = new Set(['setup', 'gateway'])
  const t0 = Date.now()
  for (const st of stages) {
    if (skip.has(st.name)) continue
    const s = p.spinner()
    s.start(st.title)
    const tick = setInterval(() => {
      try { s.message(`${st.title} — ${fmtElapsed(Date.now() - t0)} elapsed`) } catch {}
    }, 1000)
    const r = spawnSync('bash', [script, '--stage', st.name],
      { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'buffer' })
    clearInterval(tick)
    fs.writeSync(log, r.stdout || Buffer.alloc(0))
    fs.writeSync(log, r.stderr || Buffer.alloc(0))
    if (r.status === 0) {
      s.stop(`${st.title} (${fmtElapsed(Date.now() - t0)})`)
    } else {
      s.stop(`${st.title} failed`)
      const tail = String(r.stderr || r.stdout || '').trimEnd().split('\n').slice(-12).join('\n')
      p.log.error(`Stage "${st.title}" failed. Last output (full log: ${logPath}):`)
      for (const line of tail.split('\n')) p.log.error(`  ${line}`)
      p.outro('Fix the issue above and run `moch` again — the install picks up where it left off.')
      fs.closeSync(log)
      return 'fail'
    }
  }
  fs.closeSync(log)
  p.log.success(`Installed in ${fmtElapsed(Date.now() - t0)}.`)
  p.log.message('One more thing before chat works: an AI provider key. Later, run:  moch auth login')
  return 'ok'
}

// ---- pairing -----------------------------------------------------------------

async function runPairing(serve) {
  let info = pairInfo(serve)
  if (!info) {
    p.intro('Moch')
    p.log.error('Backend not found at ~/.moch — run `moch` to install first.')
    p.outro(' ')
    return false
  }

  p.intro('Moch — pair your phone')

  if (info.SERVICES !== 'up') {
    const s = p.spinner()
    s.start('Starting the Moch backend')
    const r = run(serve, ['setup'], { env: { ...process.env, MOCH_NO_TAILSCALE: '1' } })
    info = pairInfo(serve) || info
    if (info.SERVICES === 'up') s.stop('Backend running')
    else {
      s.stop('Backend did not come up')
      p.log.error(String(r.stderr || r.stdout || '').trimEnd().split('\n').slice(-6).join('\n'))
      p.log.message('Details: journalctl --user -u moch-serve.service -n 30   then re-run: moch')
      p.outro(' ')
      return false
    }
  }

  let host = info.HOST || ''
  if (!host) {
    const choice = await p.select({
      message: 'How should your phone reach this computer?',
      options: [
        { value: 'anywhere', label: 'From anywhere  (recommended)', hint: 'works on mobile data and other Wi-Fi — uses a free Tailscale account' },
        { value: 'lan', label: 'Same Wi-Fi only', hint: 'no extra apps, but the phone must be on this network' },
      ],
    })
    if (p.isCancel(choice)) { p.cancel(' '); return false }
    if (choice === 'anywhere') {
      const s = p.spinner()
      s.start('Preparing anywhere-access (tailscale)')
      let result = null
      let urlShown = false
      await new Promise((resolve) => {
        const child = spawn('bash', [serve, 'ts-link'], { stdio: ['ignore', 'pipe', 'pipe'] })
        let buf = ''
        const onLine = (line) => {
          if (line.startsWith('URL ')) {
            if (urlShown) return
            urlShown = true
            s.stop('One-time sign-in needed')
            p.log.step('Open this in any browser and sign in (creating a free account')
            p.log.step('is fine — your phone will use the SAME account):')
            console.log(`\n    ${line.slice(4)}\n`)
            s.start('Waiting for you to finish sign-in (up to 5 min)…')
          } else if (line.startsWith('LINKED ')) {
            result = { host: line.slice(7) }
          } else if (line.startsWith('FAIL ')) {
            result = { fail: line.slice(5) }
          }
        }
        child.stdout.on('data', (d) => { buf += d; const parts = buf.split('\n'); buf = parts.pop(); parts.forEach(onLine) })
        child.on('error', () => { result = { fail: 'spawn' }; resolve() })
        child.on('close', () => resolve())
      })
      if (result && result.host) {
        s.stop(`Anywhere-access ready (${result.host})`)
        host = result.host
      } else {
        s.stop('Anywhere-access not ready')
        p.log.warn(`Reason: ${result && result.fail ? result.fail : 'unknown'}. Continuing with same-Wi-Fi pairing — re-run \`moch\` anytime to retry.`)
      }
    }
  }

  const lan = info.LAN
  const token = info.TOKEN
  const anywhere = !!host
  const link = `hermes://connect?host=${encodeURIComponent(anywhere ? host : lan)}&tls=${anywhere ? '1' : '0'}&token=${encodeURIComponent(token)}`

  if (anywhere) p.log.success(`Pairing works from ANY network via ${host}`)
  else p.log.success(`Pairing works on this Wi-Fi (${lan})`)

  console.log('\n  Scan this in the Moch app:\n')
  printQr(link)
  console.log('')
  for (const line of phoneSteps(anywhere)) console.log(line)
  console.log('')
  p.log.message('Prefer typing? In Moch choose "add a computer" manually:')
  console.log(`      address: ${anywhere ? host : lan}${anywhere ? '   (TLS on)' : ''}`)
  console.log(`      token:   ${token}`)
  console.log('')
  p.outro('chat needs an AI key → moch auth login   ·   health → moch status   ·   this QR → moch qr')
  return true
}

module.exports = { available, runInstall, runPairing }
