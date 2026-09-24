# node:22-alpine: an HTTP server that serves itself twenty requests, then
# idles. The point of it is its binary: ~120 MiB, the kind of large executable
# whose page faults read around by the whole read-ahead window.
cat > /tmp/app.js <<'EOF'
const http = require("http"), crypto = require("crypto"), zlib = require("zlib");
const server = http.createServer((req, res) => {
  res.end(JSON.stringify({ h: crypto.createHash("sha256").update(req.url).digest("hex"),
                           z: zlib.gzipSync("x".repeat(1000)).length }));
});
server.listen(8080, "127.0.0.1", async () => {
  for (let i = 0; i < 20; i++) {
    await new Promise((ok) => http.get("http://127.0.0.1:8080/" + i, (r) => { r.resume(); r.on("end", ok); }));
  }
  console.log("P| served");
});
EOF
exec node /tmp/app.js
