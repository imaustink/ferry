# python:3.12-slim: a small app that imports a spread of the standard library,
# fills an SQLite table and serves itself twenty requests, then idles.
cat > /tmp/app.py <<'EOF'
import asyncio, csv, decimal, email.parser, hashlib, http.server, json, logging
import sqlite3, ssl, threading, urllib.request, xml.etree.ElementTree, zlib
db = sqlite3.connect(":memory:", check_same_thread=False)
db.execute("create table t(x)")
db.executemany("insert into t values (?)", [(i,) for i in range(10000)])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"n": db.execute("select count(*) from t").fetchone()[0]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 8080), H)
threading.Thread(target=s.serve_forever, daemon=True).start()
for _ in range(20): urllib.request.urlopen("http://127.0.0.1:8080/").read()
print("P| served", flush=True)
threading.Event().wait()
EOF
exec python3 /tmp/app.py
