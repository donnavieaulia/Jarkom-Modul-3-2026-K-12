#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 14 - WORKER WEB: MAKI (192.217.4.21) & PANDA (192.217.4.22)
# nginx + PHP-FPM, halaman menampilkan hostname, hanya menerima dari gojo.
# Jalankan di maki DAN panda: bash /root/14-web-worker.sh
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive
case "$(hostname)" in
    maki)  IP=192.217.4.21 ;;
    panda) IP=192.217.4.22 ;;
    *) echo 'Hanya untuk maki/panda'; exit 1 ;;
esac

# ---------- Persiapan ----------
ip -4 addr show eth0 | grep -q "$IP/24" || { ip link set eth0 up; ip addr add "$IP/24" broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
command -v nginx >/dev/null && ls /etc/php >/dev/null 2>&1 || { apt-get update; apt-get install -y nginx php-fpm curl procps iproute2; }

# ---------- Script kontrol nginx + PHP-FPM ----------
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

# ---------- Halaman web (menampilkan hostname worker) ----------
mkdir -p /var/www/m3-web
cat > /var/www/m3-web/index.php <<'PHP'
<?php $host = gethostname(); header('Content-Type: text/html; charset=utf-8'); ?>
<!doctype html>
<html><head><title>Jujutsu High Frontend</title></head>
<body>
<h1>Jujutsu High - Frontend</h1>
<p class="worker">worker=<?= htmlspecialchars($host) ?></p>
</body></html>
PHP

# ---------- Virtual host: domain layanan saja, hanya dari gojo ----------
cat > /etc/nginx/sites-available/m3-web <<'SITE'
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
server {
    listen 80;
    server_name jujutsu.k12.com www.jujutsu.k12.com;
    root /var/www/m3-web;
    index index.php;
    allow 192.217.1.4;    # gojo (reverse proxy)
    allow 127.0.0.1;
    deny all;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__SOCK__;
    }
}
SITE
v=$(ls /etc/php | sort -V | tail -n 1)
sed -i "s#__SOCK__#/run/php/php$v-fpm.sock#" /etc/nginx/sites-available/m3-web
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-web /etc/nginx/sites-enabled/m3-web
bash /root/m3-web-control.sh restart
curl -s -H 'Host: jujutsu.k12.com' http://127.0.0.1/ | grep worker=
