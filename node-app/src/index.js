// A real dependency set (express + helmet), not a formality, so this
// exercises the same npm-ci-then-COPY-src shape as any other Node app
// image, with the baseline hardening a production service needs:
// security headers, structured logs, a distinct liveness/readiness split,
// and a graceful shutdown that lets the Deployment roll without dropping
// in-flight requests.
const http = require('http')
const express = require('express')
const helmet = require('helmet')

const log = (msg, fields = {}) =>
  console.log(JSON.stringify({ ts: new Date().toISOString(), msg, ...fields }))

const app = express()
app.disable('x-powered-by')
app.use(helmet())

// Liveness: process is up and the event loop is answering. Never depends on
// anything downstream -- a flaky dependency should not make the kubelet
// restart a pod that is otherwise fine.
app.get('/healthz', (_req, res) => res.status(200).json({ status: 'ok' }))

// Readiness: this instance should receive traffic right now. False during
// startup and during the shutdown drain below, so the Service's endpoint
// controller pulls it out of rotation instead of routing requests it will
// refuse.
let ready = false
app.get('/readyz', (_req, res) =>
  ready ? res.status(200).json({ status: 'ready' }) : res.status(503).json({ status: 'not-ready' }))

app.get('/', (_req, res) => res.send('hello from node-app, built with ferry image build\n'))

// Errors thrown by a route land here instead of crashing the process or
// leaking a stack trace to the client.
app.use((err, _req, res, _next) => {
  log('unhandled request error', { error: err.message })
  res.status(500).json({ status: 'error' })
})

const port = process.env.PORT || 8080
const server = http.createServer(app)
server.listen(port, () => {
  ready = true
  log('listening', { port })
})

// SIGTERM is what the kubelet sends before a pod's grace period expires.
// Flip readiness first so new requests stop arriving, then let in-flight
// ones finish before the process exits -- the difference between a
// deploy that is invisible and one that serves a handful of resets.
function shutdown(signal) {
  log('shutting down', { signal })
  ready = false
  server.close(() => {
    log('closed all connections')
    process.exit(0)
  })
  setTimeout(() => {
    log('forced exit: connections did not close in time')
    process.exit(1)
  }, 10_000).unref()
}

process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))
