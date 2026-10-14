#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 13 - INUMAKI (MariaDB Slave, 192.217.4.41)
# CHANGE MASTER TO yaga, baca binlog dari mysql-bin.000001 posisi 4.
# bash /root/13-inumaki.sh   (jalankan SETELAH yaga)
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ---------- Persiapan ----------
ip -4 addr show eth0 | grep -q '192.217.4.41/24' || { ip link set eth0 up; ip addr add 192.217.4.41/24 broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
mkdir -p /root/modul3-state /root/bukti-m3
command -v mariadb >/dev/null || { apt-get update; apt-get install -y mariadb-server mariadb-client procps iproute2; }

# ---------- Script kontrol MariaDB (sama dengan yaga) ----------
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

# ---------- Konfigurasi slave ----------
cat > /root/m3-db-slave.cnf <<'CNF'
[mysqld]
server-id         = 2
relay-log         = /var/log/mysql/relay-bin
read_only         = 1
bind-address      = 0.0.0.0
skip-name-resolve = 1
CNF
cp /root/m3-db-slave.cnf /etc/mysql/mariadb.conf.d/60-m3-replication.cnf
bash /root/m3-db-control.sh restart
mariadb -h 192.217.4.40 -u repl_k12 -preplk12 -e 'SELECT "koneksi ke yaga OK" AS cek;'

# ---------- Hubungkan ke master ----------
cat > /root/m3-db-slave.sql <<'SQL'
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
    MASTER_HOST='192.217.4.40',
    MASTER_PORT=3306,
    MASTER_USER='repl_k12',
    MASTER_PASSWORD='replk12',
    MASTER_LOG_FILE='mysql-bin.000001',
    MASTER_LOG_POS=4,
    MASTER_USE_GTID=no,
    MASTER_CONNECT_RETRY=5;
START SLAVE;
SQL
# Lewati CHANGE MASTER kalau slave sudah berjalan (hindari replay ganda). Paksa ulang: bash 13-inumaki.sh --force
if [[ -n "$(mariadb -e 'SHOW SLAVE STATUS;')" && "${1:-}" != --force ]]; then
    echo 'Slave sudah dikonfigurasi, CHANGE MASTER dilewati.'
else
    mariadb < /root/m3-db-slave.sql
fi
sleep 3
mariadb -e 'SHOW SLAVE STATUS\G' | grep -E 'Master_Host|Master_User|Master_Log_File|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind|Last_IO_Error|Last_SQL_Error'
mariadb -e 'SHOW DATABASES;'

# ---------- Uji (manual saat SS) ----------
# mariadb -e 'SELECT * FROM db_shibuya_k12.request_logs ORDER BY id DESC LIMIT 3;'
# mariadb -h 192.217.4.40 -u shibuya_k12 -pshibuyak12 -e 'SELECT CURRENT_USER() AS login_sebagai, COUNT(*) AS jumlah_log FROM db_shibuya_k12.request_logs;'
