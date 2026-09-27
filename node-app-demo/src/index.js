// A real dependency (express), not a formality, so this exercises the same
// npm-install-then-COPY-src shape as any other Node app image.
const express = require('express')

const app = express()
app.get('/', (_req, res) => res.send('hello from node-app-demo, built with ferry image build\n'))

const port = process.env.PORT || 8080
app.listen(port, () => console.log(`listening on :${port}`))
