#!/bin/bash
# =====================================================================
# Modul 3 K12 - NOMOR 11 & 12 - SHOKO (DNS Slave, 192.217.1.3)
# Menyalin zona jujutsu.k12.com + 1.217.192.in-addr.arpa dari utahime.
# Jalankan SETELAH utahime aktif: bash /root/11-12-shoko.sh
# =====================================================================
set -e
export DEBIAN_FRONTEND=noninteractive

# ---------- Persiapan ----------
ip -4 addr show eth0 | grep -q '192.217.1.3/24' || { ip link set eth0 up; ip addr add 192.217.1.3/24 broadcast 192.217.1.255 dev eth0; }
ip route replace default via 192.217.1.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
mkdir -p /root/bukti-m3
command -v named >/dev/null || { apt-get update; apt-get install -y bind9 bind9-utils bind9-dnsutils procps iproute2; }

# ---------- Script kontrol BIND (sama dengan utahime) ----------
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

# ---------- Options slave (no.12: forwarder juga, untuk client yang bertanya ke shoko) ----------
cat > /etc/bind/named.conf.options <<'OPT'
options {
    directory "/var/cache/bind";
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    allow-query { any; };
    recursion yes;
    allow-recursion { 127.0.0.1; 192.217.0.0/16; };
    forwarders { 192.168.122.1; };
    forward only;
    dnssec-validation no;
    notify no;
    allow-transfer { none; };
};
OPT

# ---------- Zona secondary (= slave), tarik dari utahime ----------
cat > /etc/bind/named.conf.local <<'LOCAL'
zone "jujutsu.k12.com" {
    type secondary;
    primaries { 192.217.1.2; };
    file "/var/cache/bind/db.jujutsu.k12.com";
    masterfile-format text;
};
zone "1.217.192.in-addr.arpa" {
    type secondary;
    primaries { 192.217.1.2; };
    file "/var/cache/bind/db.192.217.1";
    masterfile-format text;
};
LOCAL

bash /root/m3-dns-control.sh restart
sleep 2
rndc retransfer jujutsu.k12.com || true
rndc retransfer 1.217.192.in-addr.arpa || true
sleep 2
grep -i 'transfer status' /root/m3-named.log | tail -n 2
dig @127.0.0.1 jujutsu.k12.com SOA +short
dig @127.0.0.1 -x 192.217.1.4 +short
