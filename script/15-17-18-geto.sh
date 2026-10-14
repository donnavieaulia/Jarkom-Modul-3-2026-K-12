#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 15, 17, 18 - GETO (hostname: getto, 192.217.4.20)
# Load balancer internal: upstream api_cluster WRR 3:1 (no.15),
# realip dari gojo + X-Real-IP/XFF (no.17), backup kirara + max_fails (no.18).
# bash /root/15-17-18-geto.sh   (isi = konfigurasi FINAL setelah no.18)
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ---------- Persiapan ----------
ip addr flush dev eth0 scope global
ip addr add 192.217.4.20/24 broadcast 192.217.4.255 dev eth0
ip route replace default via 192.217.4.1 dev eth0
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

# ---------- Konfigurasi load balancer ----------
cat > /etc/nginx/sites-available/m3-geto <<'SITE'
upstream api_cluster {
    zone api_cluster 64k;                                       # giliran dibagi antar proses nginx
    server 192.217.4.31 weight=3 max_fails=2 fail_timeout=5s;   # nanami (no.15 weight 3, no.18 health check)
    server 192.217.4.32 weight=1 max_fails=2 fail_timeout=5s;   # todo   (no.15 weight 1, no.18 health check)
    server 192.217.4.33 backup;                                 # kirara (no.18 cadangan)
}
# Hanya gojo + jaringan Data Center yang boleh memakai geto
map $realip_remote_addr $m3_geto_allowed {
    default            0;
    192.217.1.4        1;
    ~^192\.217\.4\.    1;
    127.0.0.1          1;
}
# No.17: tambahkan IP pengantar (gojo) ke rantai X-Forwarded-For
map $http_x_forwarded_for $m3_xff {
    ""       $realip_remote_addr;
    default  "$http_x_forwarded_for, $realip_remote_addr";
}
log_format m3geto '$remote_addr from=$realip_remote_addr [$time_local] "$request" $status upstream=$upstream_addr ustatus=$upstream_status xff="$http_x_forwarded_for"';
server {
    listen 80 default_server;
    server_name _;
    access_log /var/log/nginx/m3-geto.access.log m3geto;
    # No.17: hanya percaya X-Real-IP dari proxy terpercaya (gojo)
    set_real_ip_from 192.217.1.4;
    real_ip_header   X-Real-IP;
    if ($m3_geto_allowed = 0) { return 403; }
    location / {
        proxy_pass http://api_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host jujutsu.k12.com;
        proxy_set_header X-Real-IP $remote_addr;      # IP client terverifikasi
        proxy_set_header X-Forwarded-For $m3_xff;
        # No.18: failover tanpa 502 ke client
        proxy_connect_timeout 2s;
        proxy_read_timeout 10s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
    }
}
SITE
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-geto /etc/nginx/sites-enabled/m3-geto
bash /root/m3-web-control.sh restart
curl -s http://127.0.0.1/api | grep -o '"worker":"[a-z]*"'

# ---------- Catatan versi per nomor ----------
# No.15 saja : upstream tanpa max_fails/backup, tanpa blok realip & header X-Real-IP/XFF.
# No.17      : + set_real_ip_from, real_ip_header, X-Real-IP, X-Forwarded-For.
# No.18      : + max_fails=2 fail_timeout=5s, backup kirara, proxy_next_upstream.
