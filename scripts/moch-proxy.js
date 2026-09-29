#!/usr/bin/env node
// Moch host-rewriting reverse proxy (LAN/Tailnet -> moch serve).
//
// The backend's WS gateway accepts the static pairing token only on loopback
// binds, and its host-header defence only accepts the bound hostname. Phones
// reach this proxy on the LAN / via `tailscale serve`; it rewrites
// Host/Origin to 127.0.0.1:<upstream> so the backend treats proxied traffic
// as local, keeping the token WS auth path available. WebSocket upgrades
// pass through transparently.
//
// Env: PORT (listen port, default 9223), UPSTREAM_PORT (default 9222),
//      BIND_HOST (default 0.0.0.0)
const http = require('http')
const net = require('net')

const UPSTREAM_HOST = '127.0.0.1'
const UPSTREAM_PORT = parseInt(process.env.UPSTREAM_PORT || '9222', 10)
const LISTEN_PORT = parseInt(process.env.PORT || '9223', 10)
const HOP = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'upgrade', 'host', 'origin'])

const server = http.createServer((req, res) => {
  const headers = { ...req.headers, host: `${UPSTREAM_HOST}:${UPSTREAM_PORT}` }
  const up = http.request(
    { host: UPSTREAM_HOST, port: UPSTREAM_PORT, method: req.method, path: req.url, headers },
    (ur) => {
      const h = { ...ur.headers }
      delete h['transfer-encoding']
      res.writeHead(ur.statusCode, h)
      ur.pipe(res)
    },
  )
  up.on('error', () => { res.writeHead(502); res.end('upstream error') })
  req.pipe(up)
})

// WebSocket upgrade: raw bidirectional pipe after rewriting headers
server.on('upgrade', (req, socket, head) => {
  const outHeaders = Object.entries(req.headers)
    .filter(([k]) => !HOP.has(k.toLowerCase()))
    .map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(', ') : v}`)
  outHeaders.push(`Host: ${UPSTREAM_HOST}:${UPSTREAM_PORT}`)
  outHeaders.push(`Origin: http://${UPSTREAM_HOST}:${UPSTREAM_PORT}`)
  outHeaders.push('Connection: Upgrade')
  if (req.headers.upgrade) outHeaders.push(`Upgrade: ${req.headers.upgrade}`)

  const up = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
    const wire = `GET ${req.url} HTTP/1.1\r\n${outHeaders.join('\r\n')}\r\n\r\n`
    up.write(wire)
    if (head && head.length) up.write(head)
    up.pipe(socket).pipe(up)
  })
  up.once('close', () => socket.destroy())
  up.on('error', () => socket.destroy())
  socket.on('error', () => up.destroy())
})

server.listen(LISTEN_PORT, process.env.BIND_HOST || '0.0.0.0', () => {
  console.log(`moch proxy ${process.env.BIND_HOST || '0.0.0.0'}:${LISTEN_PORT} -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}`)
})
