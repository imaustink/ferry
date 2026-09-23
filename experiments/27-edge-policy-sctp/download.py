# download.py <url> [runs]: best-of-N throughput of one HTTP download, in MB/s.
import sys, time, urllib.request
url, runs = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 5
best = 0
for _ in range(runs):
    t = time.time()
    n = 0
    with urllib.request.urlopen(url) as r:
        while chunk := r.read(1 << 20):
            n += len(chunk)
    best = max(best, n / 1e6 / (time.time() - t))
print("%.0f MB/s" % best)
