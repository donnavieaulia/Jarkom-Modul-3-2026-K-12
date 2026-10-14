#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 13 - YAGA (MariaDB Master, 192.217.4.40)
# DB db_shibuya_k12, tabel request_logs, binlog, user remote Network 4.
# bash /root/13-yaga.sh   (jalankan SEBELUM inumaki)
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ---------- Persiapan ----------
ip -4 addr show eth0 | grep -q '192.217.4.40/24' || { ip link set eth0 up; ip addr add 192.217.4.40/24 broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
mkdir -p /root/modul3-state /root/bukti-m3
command -v mariadb >/dev/null || { apt-get update; apt-get install -y mariadb-server mariadb-client procps iproute2; }

# ---------- Script kontrol MariaDB ----------
cat > /root/m3-db-control.sh <<'DBCTL'
#!/bin/bash
set -euo pipefail
action=${1:-status}
ADMIN=$(command -v mariadb-admin || command -v mysqladmin)
alive() { "$ADMIN" ping --silent >/dev/null 2>&1; }
start_db() {
    mkdir -p /run/mysqld /var/log/mysql
    chown mysql:mysql /run/mysqld /var/log/mysql
    if alive; then echo 'MariaDB sudah berjalan'; return 0; fi
    if [[ -x /etc/init.d/mariadb ]]; then /etc/init.d/mariadb start || true; fi
    if ! alive; then
        safe=$(command -v mariadbd-safe || command -v mysqld_safe)
        nohup "$safe" >> /root/m3-mariadb.log 2>&1 < /dev/null &
    fi
    for ((i=0; i<60; i++)); do alive && break; sleep 0.5; done
    alive || { tail -n 30 /root/m3-mariadb.log 2>/dev/null; echo 'MariaDB GAGAL START'; return 1; }
    echo 'MariaDB AKTIF'
}
stop_db() {
    "$ADMIN" shutdown 2>/dev/null || true
    for ((i=0; i<60; i++)); do alive || break; sleep 0.5; done
    if alive; then echo 'MariaDB belum berhenti'; return 1; fi
    return 0
}
case "$action" in
    start) start_db ;;
    stop) stop_db; echo 'MariaDB BERHENTI' ;;
    restart) stop_db; start_db ;;
    status) alive && echo 'MariaDB AKTIF' || { echo 'MariaDB TIDAK AKTIF'; exit 1; } ;;
    *) echo 'Gunakan start|stop|restart|status'; exit 1 ;;
esac
DBCTL
chmod +x /root/m3-db-control.sh

# ---------- Binary log + server-id + bind ke semua IP ----------
cat > /root/m3-db-master.cnf <<'CNF'
[mysqld]
server-id         = 1
log-bin           = /var/log/mysql/mysql-bin
binlog_format     = ROW
bind-address      = 0.0.0.0
skip-name-resolve = 1
CNF
cp /root/m3-db-master.cnf /etc/mysql/mariadb.conf.d/60-m3-replication.cnf
bash /root/m3-db-control.sh restart

# ---------- Database, tabel, user replikasi & user aplikasi ----------
cat > /root/m3-db-master.sql <<'SQL'
CREATE USER IF NOT EXISTS 'repl_k12'@'192.217.4.%' IDENTIFIED BY 'replk12';
GRANT REPLICATION SLAVE ON *.* TO 'repl_k12'@'192.217.4.%';
CREATE DATABASE IF NOT EXISTS db_shibuya_k12;
CREATE TABLE IF NOT EXISTS db_shibuya_k12.request_logs (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    worker          VARCHAR(32)  NOT NULL,
    method          VARCHAR(10)  NULL,
    uri             VARCHAR(255) NULL,
    client_ip       VARCHAR(45)  NOT NULL,
    peer_ip         VARCHAR(45)  NULL,
    x_forwarded_for VARCHAR(255) NULL,
    note            VARCHAR(100) NULL
);
CREATE USER IF NOT EXISTS 'shibuya_k12'@'192.217.4.%' IDENTIFIED BY 'shibuyak12';
GRANT ALL PRIVILEGES ON db_shibuya_k12.* TO 'shibuya_k12'@'192.217.4.%';
FLUSH PRIVILEGES;
SQL
# RESET MASTER hanya saat setup pertama, agar slave bisa membaca dari mysql-bin.000001
if [[ ! -f /root/modul3-state/db-master-initialized ]]; then
    mariadb -e 'RESET MASTER;'
    touch /root/modul3-state/db-master-initialized
fi
mariadb < /root/m3-db-master.sql
mariadb -e "SHOW VARIABLES WHERE Variable_name IN ('server_id','log_bin','bind_address');"
mariadb -e 'SHOW MASTER STATUS;'
mariadb -e "SELECT user, host FROM mysql.user WHERE user LIKE '%k12';"

# ---------- Uji replikasi (jalankan manual saat ambil SS) ----------
# mariadb -e "INSERT INTO db_shibuya_k12.request_logs (worker, method, uri, client_ip, note) VALUES ('yaga','SQL','/uji-replikasi','192.217.4.40',CONCAT('uji replikasi ',NOW()));"
# mariadb -e 'SELECT * FROM db_shibuya_k12.request_logs ORDER BY id DESC LIMIT 3;'
# Nomor 17: mariadb -e "SELECT id, worker, client_ip, peer_ip, x_forwarded_for FROM db_shibuya_k12.request_logs WHERE note='api' ORDER BY id DESC LIMIT 5;"
