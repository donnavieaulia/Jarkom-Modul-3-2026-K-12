#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 14 (+17, +18) - WORKER API:
#   NANAMI 192.217.4.31 | TODO 192.217.4.32 | KIRARA 192.217.4.33 (backup no.18)
# nginx + PHP-FPM + php-mysql, endpoint /api mencatat request ke yaga.
# Hanya menerima dari geto. Jalankan di ketiganya: bash /root/14-api-worker.sh
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive
case "$(hostname)" in
    nanami) IP=192.217.4.31 ;;
    todo)   IP=192.217.4.32 ;;
    kirara) IP=192.217.4.33 ;;
    *) echo 'Hanya untuk nanami/todo/kirara'; exit 1 ;;
esac

# ---------- Persiapan ----------
ip -4 addr show eth0 | grep -q "$IP/24" || { ip link set eth0 up; ip addr add "$IP/24" broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
command -v nginx >/dev/null && php -m 2>/dev/null | grep -q pdo_mysql || { apt-get update; apt-get install -y nginx php-fpm php-mysql mariadb-client curl procps iproute2; }

# ---------- Script kontrol nginx + PHP-FPM (no.18: stop-nginx untuk simulasi gangguan) ----------
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

# ---------- Script API (no.17: X-Real-IP hanya dipercaya dari geto) ----------
mkdir -p /var/www/m3-api/public
cat > /var/www/m3-api/api.php <<'PHP'
<?php
header('Content-Type: application/json');
const TRUSTED_PROXY = '192.217.4.20';
$peer    = $_SERVER['REMOTE_ADDR'] ?? '';
$realHdr = trim($_SERVER['HTTP_X_REAL_IP'] ?? '');
$xff     = $_SERVER['HTTP_X_FORWARDED_FOR'] ?? '';
$client = $peer; $source = 'remote_addr';
if ($peer === TRUSTED_PROXY && filter_var($realHdr, FILTER_VALIDATE_IP)) {
    $client = $realHdr; $source = 'x-real-ip dari geto (terpercaya)';
}
$resp = ['status' => 'ok', 'service' => 'jujutsu-api', 'worker' => gethostname(),
    'client_ip' => $client, 'client_ip_source' => $source, 'peer_ip' => $peer,
    'x_forwarded_for' => $xff, 'uri' => $_SERVER['REQUEST_URI'] ?? '', 'time' => date('c')];
try {
    $pdo = new PDO('mysql:host=192.217.4.40;dbname=db_shibuya_k12;charset=utf8mb4',
        'shibuya_k12', 'shibuyak12', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 3]);
    $st = $pdo->prepare('INSERT INTO request_logs (worker, method, uri, client_ip, peer_ip, x_forwarded_for, note) VALUES (?,?,?,?,?,?,?)');
    $st->execute([$resp['worker'], $_SERVER['REQUEST_METHOD'] ?? '', substr($resp['uri'], 0, 255),
        $client, $peer, substr($xff, 0, 255), 'api']);
    $resp['log_id'] = (int) $pdo->lastInsertId();
} catch (Throwable $e) {
    http_response_code(500); $resp['status'] = 'error'; $resp['error'] = 'database: ' . $e->getMessage();
}
echo json_encode($resp, JSON_UNESCAPED_SLASHES), "\n";
PHP
php -l /var/www/m3-api/api.php

# ---------- Virtual host API: hanya dari geto ----------
cat > /etc/nginx/sites-available/m3-api <<'SITE'
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
server {
    listen 80;
    server_name jujutsu.k12.com www.jujutsu.k12.com;
    root /var/www/m3-api/public;
    allow 192.217.4.20;   # geto (load balancer)
    allow 127.0.0.1;
    deny all;
    location /api {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /var/www/m3-api/api.php;
        fastcgi_param SCRIPT_NAME /api;
        fastcgi_pass unix:__SOCK__;
    }
    location / { try_files $uri =404; }
}
SITE
v=$(ls /etc/php | sort -V | tail -n 1)
sed -i "s#__SOCK__#/run/php/php$v-fpm.sock#" /etc/nginx/sites-available/m3-api
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-api /etc/nginx/sites-enabled/m3-api
bash /root/m3-web-control.sh restart
curl -s -H 'Host: jujutsu.k12.com' http://127.0.0.1/api

# ---------- No.18 simulasi gangguan (manual, di nanami & todo) ----------
# bash /root/m3-web-control.sh stop-nginx     # matikan
# bash /root/m3-web-control.sh start          # pulihkan
