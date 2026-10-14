#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 16, 17, 19, 20 - GOJO (Public reverse proxy, 192.217.1.4)
# Path-based routing / -> maki,panda (RR) ; /api -> geto (no.16)
# Header X-Real-IP / X-Forwarded-For (no.17)
# Proxy cache 10 menit + X-Cache-Status, rate limit /api 10 r/s (no.19)
# Script on/off rate limit + analisis access log (no.20)
# bash /root/16-17-19-gojo.sh   (isi = konfigurasi FINAL setelah no.19)
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ---------- Persiapan (hanya 1 IP: 192.217.1.4) ----------
ip addr flush dev eth0 scope global
ip addr add 192.217.1.4/24 broadcast 192.217.1.255 dev eth0
ip route replace default via 192.217.1.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
command -v nginx >/dev/null || { apt-get update; apt-get install -y nginx curl procps; }

# ---------- Script kontrol nginx ----------
cat > /root/m3-web-control.sh <<'WEBCTL'
#!/bin/bash
set -euo pipefail
action=${1:-status}
php_version() { ls /etc/php 2>/dev/null | sort -V | tail -n 1; }
fpm_bin() { local v; v=$(php_version); if [[ -n "$v" && -x "/usr/sbin/php-fpm$v" ]]; then echo "/usr/sbin/php-fpm$v"; fi; }
wait_gone() { for ((i=0; i<50; i++)); do pgrep "$@" >/dev/null || return 0; sleep 0.1; done; return 1; }
fpm_start() {
    local bin; bin=$(fpm_bin); [[ -n "$bin" ]] || return 0
    mkdir -p /run/php; "$bin" -t
    if pgrep -f 'php-fpm: master' >/dev/null; then pkill -USR2 -f 'php-fpm: master'; else "$bin" -D; fi
    sleep 0.5; pgrep -f 'php-fpm: master' >/dev/null || { echo 'PHP-FPM GAGAL START'; return 1; }
}
fpm_stop() { pkill -TERM -f 'php-fpm: master' 2>/dev/null || true; wait_gone -f 'php-fpm: master' || true; }
nginx_start() {
    nginx -t
    if pgrep -x nginx >/dev/null; then nginx -s reload; else nginx; fi
    sleep 0.5; pgrep -x nginx >/dev/null || { echo 'NGINX GAGAL START'; return 1; }
}
nginx_stop() { nginx -s quit 2>/dev/null || pkill -TERM -x nginx 2>/dev/null || true; wait_gone -x nginx || pkill -KILL -x nginx 2>/dev/null || true; }
status() {
    hostname
    pgrep -x nginx >/dev/null && echo 'NGINX AKTIF' || echo 'NGINX TIDAK AKTIF'
    pgrep -f 'php-fpm: master' >/dev/null && echo 'PHP-FPM AKTIF' || echo 'PHP-FPM TIDAK AKTIF / TIDAK DIPASANG'
}
case "$action" in
    start|reload) fpm_start; nginx_start; status ;;
    restart) nginx_stop; fpm_stop; fpm_start; nginx_start; status ;;
    stop) nginx_stop; fpm_stop; echo 'NGINX + PHP-FPM BERHENTI' ;;
    stop-nginx) nginx_stop; echo 'NGINX BERHENTI' ;;
    stop-fpm) fpm_stop; echo 'PHP-FPM BERHENTI' ;;
    status) status ;;
    *) echo 'Gunakan start|reload|restart|stop|stop-nginx|stop-fpm|status'; exit 1 ;;
esac
WEBCTL
chmod +x /root/m3-web-control.sh

# ---------- No.19: folder cache + file rate limit + script on/off ----------
mkdir -p /var/cache/nginx/m3_web
chown -R www-data:www-data /var/cache/nginx/m3_web
printf 'limit_req zone=m3_api_limit burst=9 nodelay;\nlimit_req_status 429;\nlimit_req_log_level error;\n' > /etc/nginx/m3-api-limit.conf
cat > /root/m3-gojo-ratelimit.sh <<'RL'
#!/bin/bash
case "${1:-status}" in
    on)  printf 'limit_req zone=m3_api_limit burst=9 nodelay;\nlimit_req_status 429;\nlimit_req_log_level error;\n' > /etc/nginx/m3-api-limit.conf
         bash /root/m3-web-control.sh reload >/dev/null && echo 'RATE LIMIT /api: ON (10 r/s per IP)' ;;
    off) echo '# rate limit dimatikan sementara' > /etc/nginx/m3-api-limit.conf
         bash /root/m3-web-control.sh reload >/dev/null && echo 'RATE LIMIT /api: OFF' ;;
    *)   cat /etc/nginx/m3-api-limit.conf ;;
esac
RL
chmod +x /root/m3-gojo-ratelimit.sh

# ---------- Konfigurasi gojo ----------
cat > /etc/nginx/sites-available/m3-gojo <<'SITE'
upstream web_frontend {            # no.16: round robin maki/panda
    zone web_frontend 64k;
    server 192.217.4.21;   # maki
    server 192.217.4.22;   # panda
}
upstream api_gateway {             # no.16: /api ke geto
    zone api_gateway 64k;
    server 192.217.4.20;   # geto
}
# no.19: cache halaman web & rate limit /api
proxy_cache_path /var/cache/nginx/m3_web levels=1:2 keys_zone=m3_web_cache:10m max_size=100m inactive=30m use_temp_path=off;
limit_req_zone $binary_remote_addr zone=m3_api_limit:10m rate=10r/s;
# no.20: format log untuk membedakan sukses / rate limit / koneksi / aplikasi
log_format m3gojo '$remote_addr [$time_local] "$request" status=$status bytes=$body_bytes_sent rt=$request_time upstream="$upstream_addr" ustatus="$upstream_status" limit=$limit_req_status cache=$upstream_cache_status';
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
server {
    listen 80;
    server_name jujutsu.k12.com www.jujutsu.k12.com;
    access_log /var/log/nginx/m3-gojo.access.log m3gojo;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    # no.17: teruskan IP client asli
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    location / {
        proxy_pass http://web_frontend;
        proxy_cache m3_web_cache;
        proxy_cache_key "$scheme$host$request_uri";
        proxy_cache_valid 200 301 302 10m;
        proxy_cache_bypass $arg_nocache;
        proxy_no_cache $arg_nocache;
        add_header X-Cache-Status $upstream_cache_status always;
    }
    location /api {
        include /etc/nginx/m3-api-limit.conf;
        proxy_pass http://api_gateway;
    }
}
SITE
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-gojo /etc/nginx/sites-enabled/m3-gojo
bash /root/m3-web-control.sh restart

# ---------- No.20: analisis access log gojo ----------
cat > /root/m3-logstat.sh <<'LS'
#!/bin/bash
# Pemakaian: bash /root/m3-logstat.sh mark NAMA ; (jalankan ab) ; bash /root/m3-logstat.sh show NAMA
log=/var/log/nginx/m3-gojo.access.log; mark=/root/logmark-$2
case "$1" in
  mark) wc -l < "$log" > "$mark"; echo "Tanda '$2' di baris $(cat "$mark")" ;;
  show) tail -n +$(( $(cat "$mark") + 1 )) "$log" | awk -v n="$2" '
    { match($0,/status=[0-9]+/); s=substr($0,RSTART+7,RLENGTH-7); t++; c[s]++
      if (s=="429") rl++; else if (s=="499"||s=="502"||s=="504") cn++; else if (s ~ /^5/) ap++; else if (s ~ /^[23]/) ok++ }
    END { printf "ANALISIS LOG GOJO - %s\nTotal: %d\nSukses 2xx: %d\nDitolak rate limit (429): %d\nGagal koneksi (499/502/504): %d\nGagal aplikasi (5xx lain): %d\n", n,t,ok,rl,cn,ap
          for (k in c) printf "  HTTP %s : %d\n", k, c[k] }' ;;
esac
LS
chmod +x /root/m3-logstat.sh

# ---------- Catatan versi per nomor ----------
# No.16 saja : upstream + location / dan /api, tanpa header X-Real-IP/XFF, tanpa cache & limit.
# No.17      : + proxy_set_header X-Real-IP, X-Forwarded-For, X-Forwarded-Proto.
# No.19      : + proxy_cache_path, proxy_cache..., X-Cache-Status, limit_req_zone + include limit.
# Fix        : "zone ... 64k" di upstream agar round robin konsisten antar proses nginx.
