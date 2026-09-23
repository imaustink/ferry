# nginx:1.27-alpine: started, serves itself twenty requests, then idles.
nginx
for i in $(seq 20); do wget -q -O /dev/null http://127.0.0.1/; done
echo "P| served"
sleep 100000
