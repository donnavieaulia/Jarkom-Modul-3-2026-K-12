#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 11 & 12 - UTAHIME (DNS Master, 192.217.1.2)
# Domain: jujutsu.k12.com | Slave: shoko 192.217.1.3
# Simpan di /root/11-12-utahime.sh lalu: bash /root/11-12-utahime.sh
# Aman dijalankan ulang (misal setelah GNS3 ter-close).
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ---------- Persiapan: IP + resolver + paket ----------
ip -4 addr show eth0 | grep -q '192.217.1.2/24' || { ip link set eth0 up; ip addr add 192.217.1.2/24 broadcast 192.217.1.255 dev eth0; }
ip route replace default via 192.217.1.1 dev eth0
printf 'nameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
mkdir -p /root/bukti-m3 /root/modul3-state /root/m3-dns /etc/bind/m3
command -v named >/dev/null || { apt-get update; apt-get install -y bind9 bind9-utils bind9-dnsutils procps iproute2; }

# ---------- Script kontrol BIND (container tanpa systemd) ----------
cat > /root/m3-dns-control.sh <<'DNS_CONTROL'
#!/bin/bash
set -euo pipefail
action=${1:-status}
validate() { named-checkconf -z /etc/bind/named.conf; }
stop_dns() {
    rndc stop >/dev/null 2>&1 || true
    pkill -TERM -x named 2>/dev/null || true
    for ((i=0; i<50; i++)); do pgrep -x named >/dev/null || break; sleep 0.1; done
    if pgrep -x named >/dev/null; then echo 'named belum berhenti'; return 1; fi
    return 0
}
start_dns() {
    validate
    if pgrep -x named >/dev/null; then echo 'BIND9 sudah berjalan'; return 0; fi
    mkdir -p /run/named /var/cache/bind
    chown bind:bind /run/named /var/cache/bind
    [[ -s /etc/bind/rndc.key ]] || rndc-confgen -a
    chown root:bind /etc/bind/rndc.key
    chmod 640 /etc/bind/rndc.key
    echo "START $(date -Is)" >> /root/m3-named.log
    nohup /usr/sbin/named -g -4 -u bind -c /etc/bind/named.conf \
        >> /root/m3-named.log 2>&1 < /dev/null &
    sleep 2
    pgrep -x named >/dev/null || { tail -n 40 /root/m3-named.log; return 1; }
    echo 'BIND9 AKTIF'
}
case "$action" in
    start) start_dns ;;
    stop) stop_dns; echo 'BIND9 BERHENTI' ;;
    restart) validate; stop_dns; start_dns ;;
    reload)
        validate
        if pgrep -x named >/dev/null; then rndc reload || pkill -HUP -x named; echo 'BIND9 RELOAD'; else start_dns; fi
        ;;
    status)
        date -Is; hostname
        pgrep -a -x named || { echo 'BIND9 TIDAK AKTIF'; exit 1; }
        ss -lntup | grep -E ':53([[:space:]]|$)'
        ;;
    *) echo 'Gunakan start|stop|restart|reload|status'; exit 1 ;;
esac
DNS_CONTROL
chmod +x /root/m3-dns-control.sh

# ---------- NOMOR 11: options (allow-transfer + notify ke shoko) ----------
# NOMOR 12: ditambah forwarders 192.168.122.1
cat > /etc/bind/named.conf.options <<'OPT'
options {
    directory "/var/cache/bind";
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    allow-query { any; };
    recursion yes;
    allow-recursion { 127.0.0.1; 192.217.0.0/16; };
    forwarders { 192.168.122.1; };      // nomor 12: DNS Forwarder
    forward only;
    dnssec-validation no;
    notify yes;                         // nomor 11: kabari slave saat serial naik
    also-notify { 192.217.1.3; };
    allow-transfer { 192.217.1.3; };    // nomor 11: hanya shoko boleh AXFR
};
OPT

# ---------- NOMOR 11 & 12: deklarasi zona master ----------
cat > /etc/bind/named.conf.local <<'LOCAL'
zone "jujutsu.k12.com" {
    type primary;            // = master
    file "/etc/bind/m3/db.jujutsu.k12.com";
    notify yes;
    also-notify { 192.217.1.3; };
    allow-transfer { 192.217.1.3; };
};
zone "1.217.192.in-addr.arpa" {      // nomor 12: reverse DNS
    type primary;
    file "/etc/bind/m3/db.192.217.1";
    notify yes;
    also-notify { 192.217.1.3; };
    allow-transfer { 192.217.1.3; };
};
LOCAL

# ---------- Zona forward: SOA + NS (no.11), A + CNAME (no.12) ----------
cat > /root/m3-dns/db.jujutsu.k12.com <<'FWD'
$TTL 300
@   IN SOA ns1.jujutsu.k12.com. root.jujutsu.k12.com. (
        2026101402 ; serial
        3600       ; refresh
        600        ; retry
        604800     ; expire
        300 )      ; negative cache TTL
@   IN NS    ns1.jujutsu.k12.com.
@   IN NS    ns2.jujutsu.k12.com.
@   IN A     192.217.1.4
ns1 IN A     192.217.1.2
ns2 IN A     192.217.1.3
www IN CNAME jujutsu.k12.com.
FWD

# ---------- Zona reverse / PTR (no.12) ----------
cat > /root/m3-dns/db.192.217.1 <<'REV'
$TTL 300
@   IN SOA ns1.jujutsu.k12.com. root.jujutsu.k12.com. (
        2026101402 ; serial
        3600       ; refresh
        600        ; retry
        604800     ; expire
        300 )      ; negative cache TTL
@   IN NS  ns1.jujutsu.k12.com.
@   IN NS  ns2.jujutsu.k12.com.
2   IN PTR ns1.jujutsu.k12.com.
3   IN PTR ns2.jujutsu.k12.com.
4   IN PTR jujutsu.k12.com.
REV

cp /root/m3-dns/db.* /etc/bind/m3/
chown root:bind /etc/bind/m3/db.*
chmod 644 /etc/bind/m3/db.*
named-checkzone jujutsu.k12.com /etc/bind/m3/db.jujutsu.k12.com
named-checkzone 1.217.192.in-addr.arpa /etc/bind/m3/db.192.217.1

# ---------- NOMOR 11: script uji sinkron (naikkan serial + TXT sync) ----------
cat > /root/m3-dns-bump.sh <<'BUMP'
#!/bin/bash
# Pemakaian: bash /root/m3-dns-bump.sh  -> serial +1, record TXT sync berubah
Z=/etc/bind/m3/db.jujutsu.k12.com
old=$(awk '/; serial/ {print $1}' $Z); new=$((old + 1))
sed -i "s/$old ; serial/$new ; serial/" $Z
sed -i '/^sync /d' $Z
echo "sync IN TXT \"uji-sinkron $(date +%H%M%S)\"" >> $Z
named-checkzone jujutsu.k12.com $Z
bash /root/m3-dns-control.sh reload
echo "SERIAL: $old -> $new"
BUMP
chmod +x /root/m3-dns-bump.sh

bash /root/m3-dns-control.sh restart
dig @127.0.0.1 jujutsu.k12.com SOA +short
dig @127.0.0.1 www.jujutsu.k12.com +short
dig @127.0.0.1 -x 192.217.1.4 +short
