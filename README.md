
## Persiapan sebelum Soal 11

Soal 11–20 bergantung pada hasil soal 1–10 (NAT di jichi, DHCP relay, DHCP server, dan IP client). Jika GNS3 sempat ter-close atau node di-restart, paket dan konfigurasi di `/etc` hilang, sedangkan isi `/root` tetap. Jalankan pemulihan berikut lebih dulu.

#### A. Router dan relay — Jichi

**Node:** Jichi

```bash
cat > /root/00-pemulihan-jichi.sh <<'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
printf 'nameserver 192.168.122.1\n' > /etc/resolv.conf
if ! command -v iptables >/dev/null || ! command -v dhcrelay >/dev/null; then
  apt-get update; apt-get install -y iptables isc-dhcp-relay
fi
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s 192.217.0.0/16 -o eth0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 192.217.0.0/16 -o eth0 -j MASQUERADE
iptables -P FORWARD ACCEPT
bash /root/m3-service.sh relay restart
bash /root/m3-service.sh relay status
EOF
chmod +x /root/00-pemulihan-jichi.sh
bash /root/00-pemulihan-jichi.sh
```

> Jika `m3-service.sh` error `here-document ... M3_FILE_END`, hapus baris nyasar: `sed -i "/^cat >> \/root\/m3-service.sh <<'M3_FILE_END'$/d" /root/m3-service.sh`

**Expected:** `net.ipv4.ip_forward = 1`, rule `MASQUERADE` keluar `eth0`, dan `isc-dhcp-relay RUNNING`.

#### B. DHCP server — Tengen

**Node:** Tengen

```bash
ip -4 addr show eth0 | grep -q '192.217.4.10/24' || { ip link set eth0 up; ip addr add 192.217.4.10/24 broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.168.122.1\n' > /etc/resolv.conf
command -v dhcpd >/dev/null || { apt-get update; apt-get install -y isc-dhcp-server; }
mkdir -p /root/modul3
cat > /root/modul3/dhcpd.conf.backup <<'DHCPD_CONF'
authoritative;
ddns-update-style none;
default-lease-time 3600;
max-lease-time 7200;
option domain-name "k12.com";
option domain-search "k12.com";
option domain-name-servers 192.217.1.2, 192.217.1.3;

subnet 192.217.4.0 netmask 255.255.255.0 {
    option routers 192.217.4.1;
    option broadcast-address 192.217.4.255;
}
subnet 192.217.2.0 netmask 255.255.255.0 {
    option routers 192.217.2.1;
    option broadcast-address 192.217.2.255;
    pool { range 192.217.2.10 192.217.2.35; }
    pool { range 192.217.2.70 192.217.2.95; }
}
subnet 192.217.3.0 netmask 255.255.255.0 {
    option routers 192.217.3.1;
    option broadcast-address 192.217.3.255;
    pool { range 192.217.3.10 192.217.3.89; }
    pool { range 192.217.3.100 192.217.3.199; }
}
DHCPD_CONF
cp /root/modul3/dhcpd.conf.backup /etc/dhcp/dhcpd.conf
printf 'INTERFACESv4="eth0"\nINTERFACESv6=""\n' > /etc/default/isc-dhcp-server
dhcpd -t -cf /etc/dhcp/dhcpd.conf && echo 'CONFIG OK'
bash /root/m3-service.sh server restart
bash /root/m3-service.sh server status
```

**Expected:** `CONFIG OK` dan `isc-dhcp-server RUNNING`.

#### C. Client — Itadori, Ino, Kusakabe

**Node:** Itadori (ulangi di Ino dan Kusakabe)

```bash
udhcpc -i eth0 -n -q
cp /etc/resolv.conf /root/resolv.conf.dhcp
printf 'nameserver 192.168.122.1\n' > /etc/resolv.conf
apk update && apk add bind-tools curl apache2-utils
cp /root/resolv.conf.dhcp /etc/resolv.conf
cat /etc/resolv.conf
```

**Expected:** client mendapat IP `192.217.2.x` / `192.217.3.x`, dan `/etc/resolv.conf` berisi `search k12.com`, `nameserver 192.217.1.2`, `nameserver 192.217.1.3`.

---

## Soal 11 — DNS Master dan DNS Slave

### Tujuan

- Mengonfigurasi BIND9 di utahime sebagai DNS Master untuk domain `jujutsu.k12.com`.
- Mengonfigurasi shoko sebagai DNS Slave yang menyalin zona dari utahime.
- Membuat SOA record dan NS untuk kedua server.
- Menerapkan `allow-transfer` hanya dari Master ke Slave.
- Membuktikan zona tersinkron otomatis ke shoko ketika serial di utahime dinaikkan.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| DNS Master | utahime `192.217.1.2` (`ns1.jujutsu.k12.com`) |
| DNS Slave | shoko `192.217.1.3` (`ns2.jujutsu.k12.com`) |
| Zona | `jujutsu.k12.com` |
| File zona master | `/etc/bind/m3/db.jujutsu.k12.com` |
| File zona slave | `/var/cache/bind/db.jujutsu.k12.com` |
| Serial awal | `2026101400` |

### Langkah Pengerjaan

#### A. Instalasi BIND9 dan script kontrol — Utahime dan Shoko

Script `m3-dns-control.sh` menjalankan `named` di foreground lewat `nohup`, log ditulis ke `/root/m3-named.log`.

**Node:** Utahime, lalu blok yang sama di Shoko

```bash
mkdir -p /root/bukti-m3 /root/modul3-state
printf 'nameserver 192.168.122.1\n' > /etc/resolv.conf
apt-get update
apt-get install -y bind9 bind9-utils bind9-dnsutils procps iproute2
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
bash -n /root/m3-dns-control.sh && echo 'SCRIPT OK'
```

**Expected:** `SCRIPT OK` dan `named -v` menampilkan versi BIND 9.

#### B. DNS Master — Utahime

`notify yes` dan `also-notify` membuat utahime memberi tahu shoko setiap kali zona berubah. `allow-transfer { 192.217.1.3; }` membatasi zone transfer (AXFR) hanya ke shoko.

**Node:** Utahime

```bash
cat > /etc/bind/named.conf.options <<'EOF'
options {
    directory "/var/cache/bind";
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    allow-query { any; };
    recursion yes;
    allow-recursion { 127.0.0.1; 192.217.0.0/16; };
    dnssec-validation no;
    notify yes;
    also-notify { 192.217.1.3; };
    allow-transfer { 192.217.1.3; };
};
EOF
cat > /etc/bind/named.conf.local <<'EOF'
zone "jujutsu.k12.com" {
    type primary;
    file "/etc/bind/m3/db.jujutsu.k12.com";
    notify yes;
    also-notify { 192.217.1.3; };
    allow-transfer { 192.217.1.3; };
};
EOF
mkdir -p /etc/bind/m3
cat > /etc/bind/m3/db.jujutsu.k12.com <<'EOF'
$TTL 300
@   IN SOA ns1.jujutsu.k12.com. root.jujutsu.k12.com. (
        2026101400 ; serial
        3600       ; refresh
        600        ; retry
        604800     ; expire
        300 )      ; negative cache TTL
@   IN NS  ns1.jujutsu.k12.com.
@   IN NS  ns2.jujutsu.k12.com.
ns1 IN A   192.217.1.2
ns2 IN A   192.217.1.3
EOF
chown root:bind /etc/bind/m3/db.jujutsu.k12.com
chmod 644 /etc/bind/m3/db.jujutsu.k12.com
named-checkzone jujutsu.k12.com /etc/bind/m3/db.jujutsu.k12.com
bash /root/m3-dns-control.sh restart
dig @127.0.0.1 jujutsu.k12.com SOA +short
```

**Expected:** `zone jujutsu.k12.com/IN: loaded serial 2026101400`, `OK`, `BIND9 AKTIF`, dan `dig` menjawab SOA `ns1.jujutsu.k12.com. root.jujutsu.k12.com. 2026101400 ...`.

#### C. DNS Slave — Shoko

`type secondary` (sinonim `slave`) membuat shoko tidak menulis zona sendiri, melainkan menarik dari `primaries { 192.217.1.2; }`. `masterfile-format text` agar file hasil transfer bisa dibaca dengan `cat`.

**Node:** Shoko

```bash
cat > /etc/bind/named.conf.options <<'EOF'
options {
    directory "/var/cache/bind";
    listen-on port 53 { any; };
    listen-on-v6 { none; };
    allow-query { any; };
    recursion yes;
    allow-recursion { 127.0.0.1; 192.217.0.0/16; };
    dnssec-validation no;
    notify no;
    allow-transfer { none; };
};
EOF
cat > /etc/bind/named.conf.local <<'EOF'
zone "jujutsu.k12.com" {
    type secondary;
    primaries { 192.217.1.2; };
    file "/var/cache/bind/db.jujutsu.k12.com";
    masterfile-format text;
};
EOF
rm -f /var/cache/bind/db.jujutsu.k12.com
bash /root/m3-dns-control.sh restart
sleep 3
grep -i 'transfer' /root/m3-named.log | tail -n 3
dig @127.0.0.1 jujutsu.k12.com SOA +short
```

**Expected:** log `Transfer status: success` dan serial di shoko sama dengan utahime.

#### D. Pengujian dari client — Itadori

**Node:** Itadori

```bash
for s in 192.217.1.2 192.217.1.3; do echo "===== DNS $s ====="; dig @$s jujutsu.k12.com SOA; dig @$s jujutsu.k12.com NS +short; done
```

**Expected:** kedua server menjawab SOA dengan flag `aa` (authoritative), serial sama, NS `ns1` dan `ns2`.

![SS11-01-dig-kedua-server](image/SS11-01-dig-kedua-server.png)

*itadori: `dig` SOA dan NS ke `192.217.1.2` dan `192.217.1.3`, flag `aa`, serial sama*

**Node:** Itadori

```bash
dig @192.217.1.2 jujutsu.k12.com AXFR
```

**Expected:** `; Transfer failed.` karena client tidak termasuk `allow-transfer`.

![SS11-02-axfr-ditolak](image/SS11-02-axfr-ditolak.png)

*itadori: AXFR dari client ditolak (`Transfer failed`)*

#### E. Uji sinkronisasi serial — Utahime, Shoko, Itadori

Serial dinaikkan 1 dan record TXT `sync` diubah sebagai penanda isi zona baru.

**Node:** Utahime

```bash
Z=/etc/bind/m3/db.jujutsu.k12.com
old=$(awk '/; serial/ {print $1}' $Z); new=$((old + 1))
sed -i "s/$old ; serial/$new ; serial/" $Z
sed -i '/^sync /d' $Z
echo "sync IN TXT \"uji-sinkron $(date +%H%M%S)\"" >> $Z
named-checkzone jujutsu.k12.com $Z
bash /root/m3-dns-control.sh reload
echo "SERIAL: $old -> $new"
```

**Expected:** `loaded serial 2026101401`, `OK`, `BIND9 RELOAD`, `SERIAL: 2026101400 -> 2026101401`.

![SS11-03-naikkan-serial](image/SS11-03-naikkan-serial.png)

*utahime: serial naik dari `...00` ke `...01`*

**Node:** Shoko

```bash
grep -iE 'notify|transfer' /root/m3-named.log | tail -n 4
```

**Expected:** `received notify` dan `transferred serial 2026101401`.

![SS11-04-log-transfer-shoko](image/SS11-04-log-transfer-shoko.png)

*shoko: log notify dan transfer otomatis*

**Node:** Itadori

```bash
for s in 192.217.1.2 192.217.1.3; do echo "$s serial=$(dig @$s jujutsu.k12.com SOA +short | awk '{print $3}') sync=$(dig @$s sync.jujutsu.k12.com TXT +short)"; done
```

**Expected:** kedua baris menunjukkan serial `2026101401` dan isi `sync` yang sama.

![SS11-05-serial-sinkron](image/SS11-05-serial-sinkron.png)

*itadori: serial dan TXT `sync` identik di master dan slave*

**Node:** Utahime

```bash
cat /etc/bind/named.conf.options /etc/bind/named.conf.local /etc/bind/m3/db.jujutsu.k12.com
```

![SS11-06-config-master](image/SS11-06-config-master.png)

*utahime: konfigurasi options, local, dan file zona*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS11-01-dig-kedua-server.png` | itadori: `dig` SOA dan NS ke `192.217.1.2` dan `192.217.1.3`, flag `aa`, serial sama |
| `image/SS11-02-axfr-ditolak.png` | itadori: AXFR dari client ditolak (`Transfer failed`) |
| `image/SS11-03-naikkan-serial.png` | utahime: serial naik dari `...00` ke `...01` |
| `image/SS11-04-log-transfer-shoko.png` | shoko: log notify dan transfer otomatis |
| `image/SS11-05-serial-sinkron.png` | itadori: serial dan TXT `sync` identik di master dan slave |
| `image/SS11-06-config-master.png` | utahime: konfigurasi options, local, dan file zona |

### Analisis

- Flag `aa` membuktikan kedua server menjawab secara authoritative untuk zona `jujutsu.k12.com`.
- AXFR dari client ditolak sedangkan shoko berhasil, sehingga `allow-transfer` bekerja sesuai rancangan.
- Shoko memperbarui zona tanpa disentuh manual: utahime mengirim NOTIFY, shoko membandingkan serial lalu menarik zona baru.

### Kesimpulan

DNS Master–Slave berjalan: utahime memegang zona asli, shoko menyalinnya, dan perubahan serial tersinkron otomatis.

---

## Soal 12 — A Record, CNAME, Reverse DNS, dan Forwarder

### Tujuan

- Membuat A record `jujutsu.k12.com` yang mengarah ke gojo.
- Membuat CNAME `www` yang merujuk ke domain utama.
- Membuat zona reverse (PTR) untuk IP gojo.
- Mengaktifkan DNS Forwarder ke `192.168.122.1` agar client bisa mengakses domain internet.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| A record | `jujutsu.k12.com` → `192.217.1.4` |
| CNAME | `www.jujutsu.k12.com` → `jujutsu.k12.com.` |
| Zona reverse | `1.217.192.in-addr.arpa` |
| PTR | `4` → `jujutsu.k12.com.` |
| Forwarder | `192.168.122.1` (`forward only`) |
| Serial | `2026101402` |
| Salinan zona | `/root/m3-dns/` (bertahan saat node di-restart) |

### Langkah Pengerjaan

#### A. Zona forward dan reverse — Utahime

Zona disimpan di `/root/m3-dns/` agar tetap ada walaupun GNS3 ter-close.

**Node:** Utahime

```bash
mkdir -p /root/m3-dns
cat > /root/m3-dns/db.jujutsu.k12.com <<'EOF'
$TTL 300
@   IN SOA ns1.jujutsu.k12.com. root.jujutsu.k12.com. (
        2026101402 ; serial
        3600 600 604800 300 )
@   IN NS    ns1.jujutsu.k12.com.
@   IN NS    ns2.jujutsu.k12.com.
@   IN A     192.217.1.4
ns1 IN A     192.217.1.2
ns2 IN A     192.217.1.3
www IN CNAME jujutsu.k12.com.
EOF
cat > /root/m3-dns/db.192.217.1 <<'EOF'
$TTL 300
@   IN SOA ns1.jujutsu.k12.com. root.jujutsu.k12.com. (
        2026101402 ; serial
        3600 600 604800 300 )
@   IN NS  ns1.jujutsu.k12.com.
@   IN NS  ns2.jujutsu.k12.com.
2   IN PTR ns1.jujutsu.k12.com.
3   IN PTR ns2.jujutsu.k12.com.
4   IN PTR jujutsu.k12.com.
EOF
echo 'ZONA OK'
```

**Expected:** `ZONA OK`.

#### B. Script konfigurasi dan pemulihan DNS — Utahime dan Shoko

`m3-dns-restore.sh` menulis `named.conf.options` (dengan forwarder) dan `named.conf.local` (zona forward + reverse) sesuai hostname: utahime sebagai `primary`, shoko sebagai `secondary`. Shoko langsung melakukan `rndc retransfer` agar tidak menunggu refresh.

**Node:** Utahime, lalu blok yang sama di Shoko

```bash
cat > /root/m3-dns-restore.sh <<'XEOF'
#!/bin/bash
set -e
role=$(hostname)
mkdir -p /etc/bind/m3
if [ "$role" = utahime ]; then
  XFER='notify yes; also-notify { 192.217.1.3; }; allow-transfer { 192.217.1.3; };'
  TYPE='type primary;'
else
  XFER='notify no; allow-transfer { none; };'
  TYPE='type secondary; primaries { 192.217.1.2; }; masterfile-format text;'
fi
cat > /etc/bind/named.conf.options <<OPT
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
    $XFER
};
OPT
XEOF
cat >> /root/m3-dns-restore.sh <<'XEOF'
for z in jujutsu.k12.com:db.jujutsu.k12.com 1.217.192.in-addr.arpa:db.192.217.1; do
  name=${z%%:*}; file=${z#*:}
  if [ "$role" = utahime ]; then path=/etc/bind/m3/$file; extra=$XFER; else path=/var/cache/bind/$file; extra=''; fi
  printf 'zone "%s" { %s file "%s"; %s };\n' "$name" "$TYPE" "$path" "$extra"
done > /etc/bind/named.conf.local
if [ "$role" = utahime ]; then
  cp /root/m3-dns/db.* /etc/bind/m3/
  chown root:bind /etc/bind/m3/db.*; chmod 644 /etc/bind/m3/db.*
fi
bash /root/m3-dns-control.sh restart
if [ "$role" = shoko ]; then sleep 2; rndc retransfer jujutsu.k12.com || true; rndc retransfer 1.217.192.in-addr.arpa || true; sleep 2; fi
XEOF
chmod +x /root/m3-dns-restore.sh
bash -n /root/m3-dns-restore.sh && echo 'SCRIPT OK'
bash /root/m3-dns-restore.sh
```

**Expected:** `loaded serial 2026101402` untuk kedua zona dan `BIND9 AKTIF`.

**Node:** Utahime

```bash
dig @127.0.0.1 www.jujutsu.k12.com +short; dig @127.0.0.1 -x 192.217.1.4 +short; dig @127.0.0.1 google.com +short | head -2
```

**Expected:** `jujutsu.k12.com.` + `192.217.1.4`, lalu `jujutsu.k12.com.`, lalu IP google.

**Node:** Shoko

```bash
grep -i 'transfer status' /root/m3-named.log | tail -n 2; dig @127.0.0.1 www.jujutsu.k12.com +short; dig @127.0.0.1 -x 192.217.1.4 +short
```

**Expected:** dua baris `Transfer status: success` dan jawaban yang sama dengan utahime.

#### C. Pengujian dari client — Itadori

**Node:** Itadori

```bash
dig jujutsu.k12.com
```

**Expected:** `ANSWER SECTION` berisi `A 192.217.1.4` dan `SERVER: 192.217.1.2#53`.

![SS12-01-a-record](image/SS12-01-a-record.png)

*itadori: A record `jujutsu.k12.com` → `192.217.1.4`*

```bash
dig www.jujutsu.k12.com
```

**Expected:** `CNAME jujutsu.k12.com.` lalu `A 192.217.1.4`.

![SS12-02-cname-www](image/SS12-02-cname-www.png)

*itadori: CNAME `www` diikuti A record*

```bash
dig -x 192.217.1.4
```

**Expected:** `4.1.217.192.in-addr.arpa. ... PTR jujutsu.k12.com.`

![SS12-03-ptr](image/SS12-03-ptr.png)

*itadori: reverse DNS `192.217.1.4` → `jujutsu.k12.com`*

```bash
dig @192.217.1.3 www.jujutsu.k12.com +short; dig @192.217.1.3 -x 192.217.1.4 +short
```

**Expected:** shoko menjawab sama: `jujutsu.k12.com.`, `192.217.1.4`, `jujutsu.k12.com.`

![SS12-04-slave-menjawab](image/SS12-04-slave-menjawab.png)

*itadori: shoko (slave) menjawab CNAME dan PTR*

```bash
ping -c 3 google.com
```

**Expected:** `google.com` ter-resolve dan `0% packet loss`.

![SS12-05-ping-google](image/SS12-05-ping-google.png)

*itadori: ping `google.com` berhasil berkat forwarder*

**Node:** Utahime

```bash
cat /etc/bind/named.conf.options /etc/bind/named.conf.local /etc/bind/m3/db.jujutsu.k12.com /etc/bind/m3/db.192.217.1
```

![SS12-06-config-zona](image/SS12-06-config-zona.png)

*utahime: options (forwarders) serta zona forward dan reverse*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS12-01-a-record.png` | itadori: A record `jujutsu.k12.com` → `192.217.1.4` |
| `image/SS12-02-cname-www.png` | itadori: CNAME `www` diikuti A record |
| `image/SS12-03-ptr.png` | itadori: reverse DNS `192.217.1.4` → `jujutsu.k12.com` |
| `image/SS12-04-slave-menjawab.png` | itadori: shoko (slave) menjawab CNAME dan PTR |
| `image/SS12-05-ping-google.png` | itadori: ping `google.com` berhasil berkat forwarder |
| `image/SS12-06-config-zona.png` | utahime: options (forwarders) serta zona forward dan reverse |

### Analisis

- CNAME membuat `www` cukup menjadi alias, sehingga jika IP gojo berubah hanya A record yang perlu diganti.
- PTR memungkinkan IP gojo dilacak kembali ke nama resminya.
- Domain di luar zona tidak diketahui utahime, sehingga diteruskan ke `192.168.122.1` (forwarder) dan client tetap bisa mengakses internet.

### Kesimpulan

Peta domain lengkap: pintu masuk utama mengarah ke gojo, alias `www` dan reverse DNS berjalan di master maupun slave, dan resolusi domain internet tetap berfungsi.

---

## Soal 13 — Replikasi MariaDB Master–Slave

### Tujuan

- Mengonfigurasi MariaDB di yaga sebagai DB-Master dan inumaki sebagai DB-Slave.
- Membuat database `db_shibuya_k12` dan tabel `request_logs` di master.
- Mengaktifkan binary logging (`log-bin`, `server-id`).
- Menghubungkan inumaki dengan `CHANGE MASTER TO`.
- Memberi akses remote untuk seluruh node Network 4.
- Membuktikan data baru di master tersalin ke slave.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Master | yaga `192.217.4.40`, `server-id = 1` |
| Slave | inumaki `192.217.4.41`, `server-id = 2`, `read_only = 1` |
| Binlog | `/var/log/mysql/mysql-bin`, `binlog_format = ROW` |
| Database | `db_shibuya_k12` |
| User replikasi | `repl_k12` / `replk12` @ `192.217.4.%` |
| User aplikasi | `shibuya_k12` / `shibuyak12` @ `192.217.4.%` |

### Langkah Pengerjaan

#### A. Instalasi MariaDB dan script kontrol — Yaga dan Inumaki

**Node:** Yaga (ulangi di Inumaki dengan IP `192.217.4.41`)

```bash
ip -4 addr show eth0 | grep -q '192.217.4.40/24' || { ip link set eth0 up; ip addr add 192.217.4.40/24 broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
mkdir -p /root/modul3-state /root/bukti-m3
apt-get update && apt-get install -y mariadb-server mariadb-client procps iproute2
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
bash -n /root/m3-db-control.sh && echo 'SCRIPT OK'
bash /root/m3-db-control.sh start
```

**Expected:** `SCRIPT OK` dan `MariaDB AKTIF`.

#### B. DB Master — Yaga

`RESET MASTER` dijalankan sebelum membuat database, sehingga binlog `mysql-bin.000001` mencatat pembuatan user, database, dan tabel. Slave yang membaca dari awal akan membuat objek yang sama secara otomatis.

**Node:** Yaga

```bash
cat > /root/m3-db-master.cnf <<'EOF'
[mysqld]
server-id         = 1
log-bin           = /var/log/mysql/mysql-bin
binlog_format     = ROW
bind-address      = 0.0.0.0
skip-name-resolve = 1
EOF
cp /root/m3-db-master.cnf /etc/mysql/mariadb.conf.d/60-m3-replication.cnf
bash /root/m3-db-control.sh restart
cat > /root/m3-db-master.sql <<'EOF'
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
EOF
mariadb -e 'RESET MASTER;'
mariadb < /root/m3-db-master.sql
mariadb -e 'SHOW MASTER STATUS;'
mariadb -e "SELECT user, host FROM mysql.user WHERE user LIKE '%k12';"
```

**Expected:** `SHOW MASTER STATUS` menampilkan `mysql-bin.000001` dan dua user `repl_k12`, `shibuya_k12` dengan host `192.217.4.%`.

#### C. DB Slave — Inumaki

**Node:** Inumaki

```bash
cat > /root/m3-db-slave.cnf <<'EOF'
[mysqld]
server-id         = 2
relay-log         = /var/log/mysql/relay-bin
read_only         = 1
bind-address      = 0.0.0.0
skip-name-resolve = 1
EOF
cp /root/m3-db-slave.cnf /etc/mysql/mariadb.conf.d/60-m3-replication.cnf
bash /root/m3-db-control.sh restart
mariadb -h 192.217.4.40 -u repl_k12 -preplk12 -e 'SELECT "koneksi ke yaga OK" AS cek;'
cat > /root/m3-db-slave.sql <<'EOF'
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
EOF
mariadb < /root/m3-db-slave.sql
sleep 3
mariadb -e 'SHOW SLAVE STATUS\G' | grep -E 'Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind|Last_IO_Error|Last_SQL_Error'
mariadb -e 'SHOW DATABASES;'
```

**Expected:** `koneksi ke yaga OK`, `Slave_IO_Running: Yes`, `Slave_SQL_Running: Yes`, `Seconds_Behind_Master: 0`, dan `db_shibuya_k12` muncul di `SHOW DATABASES`.

#### D. Pengujian replikasi

**Node:** Yaga

```bash
cat /etc/mysql/mariadb.conf.d/60-m3-replication.cnf
mariadb -e "SHOW VARIABLES WHERE Variable_name IN ('server_id','log_bin','bind_address');"
mariadb -e 'SHOW MASTER STATUS;'
mariadb -e "SHOW GRANTS FOR 'shibuya_k12'@'192.217.4.%';"
mariadb -e "INSERT INTO db_shibuya_k12.request_logs (worker, method, uri, client_ip, note) VALUES ('yaga', 'SQL', '/uji-replikasi', '192.217.4.40', CONCAT('uji replikasi ', NOW()));"
mariadb -e 'SELECT * FROM db_shibuya_k12.request_logs ORDER BY id DESC LIMIT 3;'
```

**Expected:** `server_id 1`, `log_bin ON`, `bind_address 0.0.0.0`, grant untuk `192.217.4.%`, dan baris baru `uji replikasi ...`.

![SS13-01-master-config](image/SS13-01-master-config.png)

*yaga: konfigurasi binlog, variabel server, status master, dan grant*

![SS13-02-insert-master](image/SS13-02-insert-master.png)

*yaga: INSERT data `uji replikasi`*

**Node:** Inumaki

```bash
cat /etc/mysql/mariadb.conf.d/60-m3-replication.cnf
mariadb -e 'SHOW SLAVE STATUS\G' | grep -E 'Master_Host|Master_User|Master_Log_File|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind|Last_IO_Error|Last_SQL_Error'
mariadb -e 'SELECT * FROM db_shibuya_k12.request_logs ORDER BY id DESC LIMIT 3;'
mariadb -h 192.217.4.40 -u shibuya_k12 -pshibuyak12 -e 'SELECT CURRENT_USER() AS login_sebagai, COUNT(*) AS jumlah_log FROM db_shibuya_k12.request_logs;'
```

**Expected:** status slave `Yes`/`Yes`, baris `uji replikasi` dengan `id` yang sama, dan login `shibuya_k12@192.217.4.%` berhasil.

![SS13-03-status-slave](image/SS13-03-status-slave.png)

*inumaki: konfigurasi slave dan `Slave_IO_Running`/`Slave_SQL_Running: Yes`*

![SS13-04-data-di-slave](image/SS13-04-data-di-slave.png)

*inumaki: data yang di-insert di yaga muncul di slave*

![SS13-05-akses-remote](image/SS13-05-akses-remote.png)

*inumaki: login remote user aplikasi dari Network 4*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS13-01-master-config.png` | yaga: konfigurasi binlog, variabel server, status master, dan grant |
| `image/SS13-02-insert-master.png` | yaga: INSERT data `uji replikasi` |
| `image/SS13-03-status-slave.png` | inumaki: konfigurasi slave dan `Slave_IO_Running`/`Slave_SQL_Running: Yes` |
| `image/SS13-04-data-di-slave.png` | inumaki: data yang di-insert di yaga muncul di slave |
| `image/SS13-05-akses-remote.png` | inumaki: login remote user aplikasi dari Network 4 |

### Analisis

- Slave tidak pernah di-insert manual, namun datanya identik dengan master, membuktikan replikasi berjalan secara real-time melalui binlog.
- `read_only = 1` mencegah user biasa menulis langsung ke slave, sehingga data hanya bersumber dari master.
- Host `192.217.4.%` memberi akses ke seluruh node Data Center tanpa membuka akses dari jaringan lain.

### Kesimpulan

Database terpusat redundan sudah aktif: yaga menyimpan log, inumaki menyalin otomatis, dan node Network 4 dapat mengakses database secara remote.

---

## Soal 14 — Worker Web dan Worker API

### Tujuan

- Memasang Nginx + PHP-FPM di maki dan panda untuk menampilkan hostname.
- Menyiapkan API di nanami, todo, kirara yang mencatat request ke database yaga.
- Mengatur virtual host agar worker hanya merespons domain layanan.
- Membatasi akses: web worker hanya dari gojo, API worker hanya dari geto.
- Membuktikan akses langsung dari client ditolak sedangkan lewat proxy berhasil.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Web worker | maki `.21`, panda `.22`, `allow 192.217.1.4` (gojo) |
| API worker | nanami `.31`, todo `.32`, kirara `.33`, `allow 192.217.4.20` (geto) |
| Virtual host | `server_name jujutsu.k12.com www.jujutsu.k12.com` |
| Host lain / IP mentah | `return 444` (koneksi ditutup) |
| Endpoint API | `/api` → `/var/www/m3-api/api.php` (di luar root publik) |
| PHP | `php8.4-fpm` (socket dideteksi otomatis) |

### Langkah Pengerjaan

#### A. Instalasi — Maki dan Panda

**Node:** Maki (ulangi di Panda dengan IP `192.217.4.22`)

```bash
ip -4 addr show eth0 | grep -q '192.217.4.21/24' || { ip link set eth0 up; ip addr add 192.217.4.21/24 broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
apt-get update && apt-get install -y nginx php-fpm curl procps iproute2
```

#### B. Script kontrol nginx/PHP-FPM — semua node web

Dipakai di maki, panda, nanami, todo, kirara, geto, dan gojo. Perintah `stop-nginx` dipakai untuk simulasi gangguan di Soal 18.

**Node:** Maki, Panda, Nanami, Todo, Kirara, Geto, Gojo

```bash
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
bash -n /root/m3-web-control.sh && echo 'SCRIPT OK'
```

**Expected:** `SCRIPT OK`.

#### C. Halaman web dan virtual host — Maki dan Panda

**Node:** Maki, lalu Panda

```bash
mkdir -p /var/www/m3-web
cat > /var/www/m3-web/index.php <<'EOF'
<?php $host = gethostname(); header('Content-Type: text/html; charset=utf-8'); ?>
<!doctype html>
<html><head><title>Jujutsu High Frontend</title></head>
<body>
<h1>Jujutsu High - Frontend</h1>
<p class="worker">worker=<?= htmlspecialchars($host) ?></p>
</body></html>
EOF
cat > /etc/nginx/sites-available/m3-web <<'EOF'
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
    allow 192.217.1.4;
    allow 127.0.0.1;
    deny all;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__SOCK__;
    }
}
EOF
v=$(ls /etc/php | sort -V | tail -n 1)
sed -i "s#__SOCK__#/run/php/php$v-fpm.sock#" /etc/nginx/sites-available/m3-web
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-web /etc/nginx/sites-enabled/m3-web
bash /root/m3-web-control.sh restart
curl -s -H 'Host: jujutsu.k12.com' http://127.0.0.1/ | grep worker=
```

**Expected:** `syntax is ok`, `NGINX AKTIF`, `PHP-FPM AKTIF`, dan `<p class="worker">worker=maki</p>` (atau `panda`).

#### D. Instalasi — Nanami, Todo, Kirara

**Node:** Nanami (ulangi di Todo `.32` dan Kirara `.33`)

```bash
ip -4 addr show eth0 | grep -q '192.217.4.31/24' || { ip link set eth0 up; ip addr add 192.217.4.31/24 broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
apt-get update && apt-get install -y nginx php-fpm php-mysql mariadb-client curl procps iproute2
```

Lalu salin juga blok script kontrol pada langkah B.

#### E. Script API — Nanami, Todo, Kirara

Setiap request ke `/api` mengembalikan JSON dan menulis satu baris ke `request_logs`. Header `X-Real-IP` hanya dipercaya jika koneksi berasal dari geto (dipakai pada Soal 17).

**Node:** Nanami, Todo, Kirara

```bash
mkdir -p /var/www/m3-api/public
cat > /var/www/m3-api/api.php <<'EOF'
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
EOF
php -l /var/www/m3-api/api.php
```

**Expected:** `No syntax errors detected`.

#### F. Virtual host API — Nanami, Todo, Kirara

**Node:** Nanami, Todo, Kirara

```bash
cat > /etc/nginx/sites-available/m3-api <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
server {
    listen 80;
    server_name jujutsu.k12.com www.jujutsu.k12.com;
    root /var/www/m3-api/public;
    allow 192.217.4.20;
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
EOF
v=$(ls /etc/php | sort -V | tail -n 1)
sed -i "s#__SOCK__#/run/php/php$v-fpm.sock#" /etc/nginx/sites-available/m3-api
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-api /etc/nginx/sites-enabled/m3-api
bash /root/m3-web-control.sh restart
curl -s -H 'Host: jujutsu.k12.com' http://127.0.0.1/api
```

**Expected:** JSON `"status":"ok"`, `"worker":"nanami"` (atau `todo`/`kirara`) dan `log_id`.

#### G. Uji pembatasan akses

**Node:** Gojo

```bash
ip addr flush dev eth0 scope global
ip addr add 192.217.1.4/24 broadcast 192.217.1.255 dev eth0
ip route replace default via 192.217.1.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
command -v curl >/dev/null || { apt-get update; apt-get install -y curl; }
echo 'gojo -> maki:'; curl -s -m 5 -H 'Host: jujutsu.k12.com' http://192.217.4.21/ | grep worker=
echo 'gojo -> panda:'; curl -s -m 5 -H 'Host: jujutsu.k12.com' http://192.217.4.22/ | grep worker=
echo 'gojo -> nanami (harus 403):'; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' -H 'Host: jujutsu.k12.com' http://192.217.4.31/api
```

**Expected:** `worker=maki`, `worker=panda`, dan `HTTP 403` ke nanami.

![SS14-01-dari-gojo](image/SS14-01-dari-gojo.png)

*gojo: diizinkan ke web worker, ditolak ke API worker*

**Node:** Geto

```bash
ip addr flush dev eth0 scope global
ip addr add 192.217.4.20/24 broadcast 192.217.4.255 dev eth0
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
hostname > /root/m3-role
command -v curl >/dev/null || { apt-get update; apt-get install -y curl; }
for ip in 192.217.4.31 192.217.4.32 192.217.4.33; do echo "geto -> $ip:"; curl -s -m 5 -H 'Host: jujutsu.k12.com' http://$ip/api; done
echo 'geto -> maki (harus 403):'; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' -H 'Host: jujutsu.k12.com' http://192.217.4.21/
```

**Expected:** tiga JSON `"status":"ok"` dengan `peer_ip 192.217.4.20`, dan `HTTP 403` ke maki.

![SS14-02-dari-geto](image/SS14-02-dari-geto.png)

*geto: diizinkan ke API worker, ditolak ke web worker*

**Node:** Itadori

```bash
for ip in 192.217.4.21 192.217.4.22; do printf "client -> web $ip: "; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' -H 'Host: jujutsu.k12.com' http://$ip/; done
for ip in 192.217.4.31 192.217.4.32 192.217.4.33; do printf "client -> API $ip: "; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' -H 'Host: jujutsu.k12.com' http://$ip/api; done
printf 'client -> maki pakai IP mentah: '; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' http://192.217.4.21/
```

**Expected:** lima baris `HTTP 403` dan `HTTP 000` untuk akses IP mentah.

![SS14-03-client-ditolak](image/SS14-03-client-ditolak.png)

*itadori: akses langsung ke semua worker ditolak*

**Node:** Maki dan Nanami

```bash
cat /etc/nginx/sites-available/m3-web     # di maki
cat /etc/nginx/sites-available/m3-api     # di nanami
```

![SS14-04-config-vhost](image/SS14-04-config-vhost.png)

*maki dan nanami: konfigurasi virtual host `m3-web` dan `m3-api`*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS14-01-dari-gojo.png` | gojo: diizinkan ke web worker, ditolak ke API worker |
| `image/SS14-02-dari-geto.png` | geto: diizinkan ke API worker, ditolak ke web worker |
| `image/SS14-03-client-ditolak.png` | itadori: akses langsung ke semua worker ditolak |
| `image/SS14-04-config-vhost.png` | maki dan nanami: konfigurasi virtual host `m3-web` dan `m3-api` |

### Analisis

- `allow`/`deny` menyaring berdasarkan IP koneksi, sehingga hanya proxy yang ditentukan yang bisa mencapai worker.
- `default_server` dengan `return 444` membuat worker diam terhadap host yang bukan domain layanan.
- `log_id` yang terus bertambah membuktikan API mencatat setiap request ke database yaga.

### Kesimpulan

Worker hanya melayani trafik melalui jalur proxy yang ditentukan; akses langsung dari client ditolak.

---

## Soal 15 — Load Balancer Weighted Round Robin

### Tujuan

- Mengonfigurasi Nginx di geto sebagai load balancer internal.
- Membuat `upstream api_cluster` ke nanami dan todo dengan bobot 3:1.
- Membuktikan distribusi beban dengan loop request dari jaringan Data Center.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Load balancer | geto `192.217.4.20` |
| Upstream | `api_cluster` |
| nanami | `weight=3` |
| todo | `weight=1` |
| Shared state | `zone api_cluster 64k` |
| Akses ke geto | gojo `192.217.1.4` dan `192.217.4.0/24`, selain itu 403 |
| Penguji | tengen `192.217.4.10` |

### Langkah Pengerjaan

#### A. Instalasi — Geto

**Node:** Geto

```bash
apt-get update && apt-get install -y nginx curl procps
```

Lalu salin blok script kontrol `m3-web-control.sh` (Soal 14 langkah B).

#### B. Konfigurasi load balancer — Geto

`zone api_cluster 64k` menyimpan status giliran di shared memory, sehingga semua proses worker nginx memakai urutan yang sama.

**Node:** Geto

```bash
cat > /etc/nginx/sites-available/m3-geto <<'EOF'
upstream api_cluster {
    zone api_cluster 64k;
    server 192.217.4.31 weight=3;   # nanami
    server 192.217.4.32 weight=1;   # todo
}
map $realip_remote_addr $m3_geto_allowed {
    default            0;
    192.217.1.4        1;
    ~^192\.217\.4\.    1;
    127.0.0.1          1;
}
log_format m3geto '$remote_addr from=$realip_remote_addr [$time_local] "$request" $status upstream=$upstream_addr ustatus=$upstream_status';
server {
    listen 80 default_server;
    server_name _;
    access_log /var/log/nginx/m3-geto.access.log m3geto;
    if ($m3_geto_allowed = 0) { return 403; }
    location / {
        proxy_pass http://api_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host jujutsu.k12.com;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-geto /etc/nginx/sites-enabled/m3-geto
bash /root/m3-web-control.sh restart
curl -s http://127.0.0.1/api | grep -o '"worker":"[a-z]*"'
```

**Expected:** `syntax is ok`, `NGINX AKTIF`, dan `"worker":"nanami"`.

#### C. Pengujian distribusi — Tengen

**Node:** Tengen

```bash
command -v curl >/dev/null || { apt-get update; apt-get install -y curl; }
: > /root/m3-wrr.txt
for i in $(seq 1 40); do curl -s -m 5 http://192.217.4.20/api | grep -o '"worker":"[a-z]*"' | cut -d'"' -f4 >> /root/m3-wrr.txt; done
echo 'URUTAN 12 RESPONS PERTAMA:'; head -n 12 /root/m3-wrr.txt | paste -sd' '
echo 'JUMLAH PER WORKER:'; sort /root/m3-wrr.txt | uniq -c
```

**Expected:** `30 nanami` dan `10 todo`.

![SS15-01-loop-wrr](image/SS15-01-loop-wrr.png)

*tengen: 40 request menghasilkan rasio 30:10 (3:1)*

**Node:** Geto

```bash
head -n 5 /etc/nginx/sites-available/m3-geto
tail -n 8 /var/log/nginx/m3-geto.access.log
```

**Expected:** upstream `weight=3`/`weight=1`, dan log menunjukkan `.31` tiga kali lebih sering dari `.32`.

![SS15-02-config-log-geto](image/SS15-02-config-log-geto.png)

*geto: upstream berbobot dan access log*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS15-01-loop-wrr.png` | tengen: 40 request menghasilkan rasio 30:10 (3:1) |
| `image/SS15-02-config-log-geto.png` | geto: upstream berbobot dan access log |

### Analisis

- Dari setiap 4 request, 3 diteruskan ke nanami dan 1 ke todo, sesuai bobot 3:1.
- Tanpa `zone`, setiap proses worker nginx menyimpan giliran masing-masing sehingga distribusi bisa terlihat tidak merata.

### Kesimpulan

Geto membagi beban API dengan Weighted Round Robin 3:1 secara konsisten.

---

## Soal 16 — Path-Based Routing di Gojo

### Tujuan

- Mengonfigurasi gojo untuk `jujutsu.k12.com` dan `www.jujutsu.k12.com`.
- Meneruskan `/` secara Round Robin ke maki dan panda.
- Meneruskan `/api` ke geto.
- Menguji dari client bahwa web dibalas maki/panda dan `/api` dijawab nanami/todo.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Reverse proxy | gojo `192.217.1.4` |
| `location /` | `upstream web_frontend` (maki, panda) |
| `location /api` | `upstream api_gateway` (geto) |
| Host lain / IP mentah | `return 444` |
| Log | `/var/log/nginx/m3-gojo.access.log` format `m3gojo` |

### Langkah Pengerjaan

#### A. Instalasi — Gojo

**Node:** Gojo

```bash
apt-get update && apt-get install -y nginx curl procps
```

Lalu salin blok script kontrol `m3-web-control.sh` (Soal 14 langkah B).

#### B. Konfigurasi routing — Gojo

**Node:** Gojo

```bash
cat > /etc/nginx/sites-available/m3-gojo <<'EOF'
upstream web_frontend {
    zone web_frontend 64k;
    server 192.217.4.21;   # maki
    server 192.217.4.22;   # panda
}
upstream api_gateway {
    zone api_gateway 64k;
    server 192.217.4.20;   # geto
}
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
    location / {
        proxy_pass http://web_frontend;
    }
    location /api {
        proxy_pass http://api_gateway;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/*
ln -sfn /etc/nginx/sites-available/m3-gojo /etc/nginx/sites-enabled/m3-gojo
bash /root/m3-web-control.sh restart
```

**Expected:** `syntax is ok` dan `NGINX AKTIF`.

#### C. Pengujian — Itadori

Ambil screenshot ini **sebelum** Soal 19, karena setelah cache aktif halaman `/` yang HIT selalu menampilkan worker yang sama.

**Node:** Itadori

```bash
echo '=== WEB (/) - harus gantian maki/panda ==='
for i in 1 2 3 4 5 6; do printf "request $i: "; curl -s -m 5 http://jujutsu.k12.com/ | grep -o 'worker=[a-z]*'; done
echo '=== /api - harus dijawab nanami/todo ==='
for i in 1 2 3 4 5 6 7 8; do printf "request $i: "; curl -s -m 5 http://jujutsu.k12.com/api | grep -o '"worker":"[a-z]*"'; done
D=jujutsu.k12.com; curl -s -m 5 http://www.$D/ | grep -o 'worker=[a-z]*'; curl -s -m 5 http://www.$D/api | grep -o '"worker":"[a-z]*"'
```

**Expected:** `/` bergantian `maki, panda, maki, panda, ...`; `/api` dijawab nanami/todo dengan pola 3:1; akses `www` juga berhasil.

![SS16-01-routing-client](image/SS16-01-routing-client.png)

*itadori: `/` round robin maki/panda, `/api` ke nanami/todo, domain `www`*

**Node:** Gojo

```bash
cat /etc/nginx/sites-available/m3-gojo
```

![SS16-02-config-gojo](image/SS16-02-config-gojo.png)

*gojo: konfigurasi upstream dan location*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS16-01-routing-client.png` | itadori: `/` round robin maki/panda, `/api` ke nanami/todo, domain `www` |
| `image/SS16-02-config-gojo.png` | gojo: konfigurasi upstream dan location |

### Analisis

- Gojo memilah request berdasarkan path: `/` ke web frontend, `/api` ke load balancer internal.
- Client cukup mengenal satu pintu masuk (gojo), struktur backend di belakangnya tidak terlihat.

### Kesimpulan

Gojo menjadi gerbang publik tunggal dengan Path-Based Routing yang berjalan sesuai rancangan.

---

## Soal 17 — Meneruskan IP Asli Client

### Tujuan

- Meneruskan alamat client lewat header `X-Real-IP` dan `X-Forwarded-For` di gojo dan geto.
- Membuat geto hanya mempercayai informasi IP dari proxy terpercaya (gojo).
- Menyimpan IP client terverifikasi ke kolom `client_ip` di `request_logs`.
- Menguji dari client Network 2 dan Network 3.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Gojo | `X-Real-IP $remote_addr`, `X-Forwarded-For $proxy_add_x_forwarded_for` |
| Geto | `set_real_ip_from 192.217.1.4`, `real_ip_header X-Real-IP` |
| Worker API | percaya `X-Real-IP` hanya jika `REMOTE_ADDR = 192.217.4.20` |
| Kolom | `client_ip`, `peer_ip`, `x_forwarded_for` |

### Langkah Pengerjaan

#### A. Header client — Gojo

**Node:** Gojo

```bash
cat > /etc/nginx/sites-available/m3-gojo <<'EOF'
upstream web_frontend {
    zone web_frontend 64k;
    server 192.217.4.21;   # maki
    server 192.217.4.22;   # panda
}
upstream api_gateway {
    zone api_gateway 64k;
    server 192.217.4.20;   # geto
}
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
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    location / {
        proxy_pass http://web_frontend;
    }
    location /api {
        proxy_pass http://api_gateway;
    }
}
EOF
bash /root/m3-web-control.sh reload
```

**Expected:** `NGINX AKTIF`.

#### B. Proxy terpercaya — Geto

Modul realip mengganti `$remote_addr` dengan isi `X-Real-IP` hanya jika koneksi datang dari gojo. Header palsu dari sumber lain diabaikan.

**Node:** Geto

```bash
cat > /etc/nginx/sites-available/m3-geto <<'EOF'
upstream api_cluster {
    zone api_cluster 64k;
    server 192.217.4.31 weight=3;   # nanami
    server 192.217.4.32 weight=1;   # todo
}
map $realip_remote_addr $m3_geto_allowed {
    default            0;
    192.217.1.4        1;
    ~^192\.217\.4\.    1;
    127.0.0.1          1;
}
map $http_x_forwarded_for $m3_xff {
    ""       $realip_remote_addr;
    default  "$http_x_forwarded_for, $realip_remote_addr";
}
log_format m3geto '$remote_addr from=$realip_remote_addr [$time_local] "$request" $status upstream=$upstream_addr ustatus=$upstream_status xff="$http_x_forwarded_for"';
server {
    listen 80 default_server;
    server_name _;
    access_log /var/log/nginx/m3-geto.access.log m3geto;
    set_real_ip_from 192.217.1.4;
    real_ip_header   X-Real-IP;
    if ($m3_geto_allowed = 0) { return 403; }
    location / {
        proxy_pass http://api_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host jujutsu.k12.com;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $m3_xff;
    }
}
EOF
bash /root/m3-web-control.sh reload
```

**Expected:** `NGINX AKTIF`.

#### C. Pengujian

**Node:** Itadori (Network 2)

```bash
ip -4 addr show eth0 | grep inet
echo '=== normal ==='; curl -s -m 5 http://jujutsu.k12.com/api
echo '=== header PALSU 6.6.6.6 (harus diabaikan) ==='; curl -s -m 5 -H 'X-Real-IP: 6.6.6.6' -H 'X-Forwarded-For: 6.6.6.6' http://jujutsu.k12.com/api
```

**Expected:** JSON dengan `client_ip` = IP itadori, termasuk pada request dengan header palsu `6.6.6.6`.

![SS17-01-itadori](image/SS17-01-itadori.png)

*itadori: request normal dan request dengan header palsu*

**Node:** Ino (Network 3)

```bash
udhcpc -i eth0 -n -q >/dev/null 2>&1; command -v curl >/dev/null || apk add curl
ip -4 addr show eth0 | grep inet
curl -s -m 5 http://jujutsu.k12.com/api
```

**Expected:** JSON dengan `client_ip` = IP ino.

![SS17-02-ino](image/SS17-02-ino.png)

*ino: request dari Network 3*

**Node:** Yaga

```bash
mariadb -e "SELECT id, worker, client_ip, peer_ip, x_forwarded_for FROM db_shibuya_k12.request_logs WHERE note='api' ORDER BY id DESC LIMIT 5;"
```

**Expected:** `client_ip` berisi `192.217.2.x` dan `192.217.3.x`, `peer_ip` = `192.217.4.20`, dan baris header palsu tetap mencatat IP asli.

![SS17-03-database](image/SS17-03-database.png)

*yaga: `request_logs` mencatat IP client asli, bukan IP gojo/geto*

```bash
grep X- /etc/nginx/sites-available/m3-gojo                                          # di gojo
grep -E 'set_real_ip|real_ip_header|X-Real-IP' /etc/nginx/sites-available/m3-geto     # di geto
```

![SS17-04-config-header](image/SS17-04-config-header.png)

*gojo dan geto: konfigurasi header dan realip*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS17-01-itadori.png` | itadori: request normal dan request dengan header palsu |
| `image/SS17-02-ino.png` | ino: request dari Network 3 |
| `image/SS17-03-database.png` | yaga: `request_logs` mencatat IP client asli, bukan IP gojo/geto |
| `image/SS17-04-config-header.png` | gojo dan geto: konfigurasi header dan realip |

### Analisis

- Sebelum Soal 17, `client_ip` berisi IP geto; setelahnya berisi IP client asli.
- Header palsu `6.6.6.6` tetap terlihat di `x_forwarded_for` sebagai jejak, tetapi `client_ip` tidak terpengaruh karena gojo menimpa `X-Real-IP` dan geto hanya mempercayai gojo.
- `peer_ip` selalu `192.217.4.20` karena worker memang menerima koneksi dari geto.

### Kesimpulan

IP asli client tercatat dengan benar di database tanpa tertukar dengan IP proxy perantara, dan pemalsuan header tidak berpengaruh.

---

## Soal 18 — Backup Worker dan Passive Health Check

### Tujuan

- Menjadikan kirara sebagai server backup pada `upstream api_cluster`.
- Menerapkan passive health check `max_fails=2 fail_timeout=5s` pada nanami dan todo.
- Mensimulasikan gangguan dengan mematikan nginx di nanami dan todo.
- Membuktikan request `/api` dialihkan ke kirara tanpa 502.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Worker utama | nanami, todo `max_fails=2 fail_timeout=5s` |
| Backup | kirara `192.217.4.33 backup` |
| Failover | `proxy_next_upstream error timeout http_502 http_503 http_504` |
| Timeout koneksi | `proxy_connect_timeout 2s` |

### Langkah Pengerjaan

#### A. Upstream dengan backup — Geto

**Node:** Geto

```bash
cat > /etc/nginx/sites-available/m3-geto <<'EOF'
upstream api_cluster {
    zone api_cluster 64k;
    server 192.217.4.31 weight=3 max_fails=2 fail_timeout=5s;   # nanami
    server 192.217.4.32 weight=1 max_fails=2 fail_timeout=5s;   # todo
    server 192.217.4.33 backup;                                 # kirara (cadangan)
}
map $realip_remote_addr $m3_geto_allowed {
    default            0;
    192.217.1.4        1;
    ~^192\.217\.4\.    1;
    127.0.0.1          1;
}
map $http_x_forwarded_for $m3_xff {
    ""       $realip_remote_addr;
    default  "$http_x_forwarded_for, $realip_remote_addr";
}
log_format m3geto '$remote_addr from=$realip_remote_addr [$time_local] "$request" $status upstream=$upstream_addr ustatus=$upstream_status xff="$http_x_forwarded_for"';
server {
    listen 80 default_server;
    server_name _;
    access_log /var/log/nginx/m3-geto.access.log m3geto;
    set_real_ip_from 192.217.1.4;
    real_ip_header   X-Real-IP;
    if ($m3_geto_allowed = 0) { return 403; }
    location / {
        proxy_pass http://api_cluster;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host jujutsu.k12.com;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $m3_xff;
        proxy_connect_timeout 2s;
        proxy_read_timeout 10s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
    }
}
EOF
bash /root/m3-web-control.sh reload
head -n 6 /etc/nginx/sites-available/m3-geto
```

**Expected:** `NGINX AKTIF` dan upstream berisi `max_fails=2 fail_timeout=5s` serta `backup`.

#### B. Kondisi normal — Itadori

**Node:** Itadori

```bash
cat > /root/m3-api-loop.sh <<'EOF'
#!/bin/sh
n=${1:-10}; i=1
while [ "$i" -le "$n" ]; do
    out=$(curl -s -m 5 -w ' HTTP=%{http_code}' http://jujutsu.k12.com/api)
    w=$(echo "$out" | grep -o '"worker":"[a-z]*"' | cut -d'"' -f4)
    s=$(echo "$out" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4)
    c=$(echo "$out" | grep -o 'HTTP=[0-9]*')
    echo "request $i: $c worker=${w:-?} status=${s:-?}"
    i=$((i + 1)); sleep 0.3
done
EOF
chmod +x /root/m3-api-loop.sh
sh /root/m3-api-loop.sh 8
```

**Expected:** semua `HTTP=200` dan worker hanya nanami/todo.

![SS18-01-normal](image/SS18-01-normal.png)

*itadori: kondisi normal, kirara tidak dipakai*

#### C. Simulasi gangguan — Nanami dan Todo

**Node:** Nanami, lalu Todo

```bash
bash /root/m3-web-control.sh stop-nginx
pkill -KILL -x nginx 2>/dev/null; sleep 1
pgrep -a nginx || echo "NGINX $(hostname) MATI"
```

**Expected:** `NGINX nanami MATI` dan `NGINX todo MATI`.

![SS18-02-matikan-worker](image/SS18-02-matikan-worker.png)

*nanami dan todo: nginx dihentikan*

**Node:** Itadori

```bash
sh /root/m3-api-loop.sh 10
```

**Expected:** semua `HTTP=200 worker=kirara status=ok`, tidak ada 502.

![SS18-03-failover-kirara](image/SS18-03-failover-kirara.png)

*itadori: seluruh request dijawab kirara tanpa 502*

**Node:** Geto

```bash
grep '192.217.4.33' /var/log/nginx/m3-geto.access.log | tail -n 6
```

**Expected:** baris awal `upstream=192.217.4.31:80, 192.217.4.32:80, 192.217.4.33:80 ustatus=502, 502, 200`, berikutnya langsung `.33`.

![SS18-04-log-geto](image/SS18-04-log-geto.png)

*geto: log percobaan worker utama lalu pengalihan ke kirara*

#### D. Pemulihan

**Node:** Nanami, lalu Todo

```bash
bash /root/m3-web-control.sh start
```

**Node:** Itadori

```bash
sleep 6; sh /root/m3-api-loop.sh 8
```

**Expected:** request kembali ke nanami/todo dengan pola 3:1.

![SS18-05-pulih](image/SS18-05-pulih.png)

*itadori: setelah pemulihan kembali ke nanami/todo*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS18-01-normal.png` | itadori: kondisi normal, kirara tidak dipakai |
| `image/SS18-02-matikan-worker.png` | nanami dan todo: nginx dihentikan |
| `image/SS18-03-failover-kirara.png` | itadori: seluruh request dijawab kirara tanpa 502 |
| `image/SS18-04-log-geto.png` | geto: log percobaan worker utama lalu pengalihan ke kirara |
| `image/SS18-05-pulih.png` | itadori: setelah pemulihan kembali ke nanami/todo |

### Analisis

- Geto tidak memeriksa worker secara aktif; worker dianggap down setelah 2 kegagalan dalam 5 detik (passive health check).
- `proxy_next_upstream` membuat request yang gagal langsung dicoba ke server berikutnya, sehingga client menerima 200, bukan 502.
- `ustatus=502` di log geto adalah catatan percobaan internal, bukan respons yang diterima client.

### Kesimpulan

Kirara berfungsi sebagai cadangan yang otomatis mengambil alih ketika worker utama tumbang, dan layanan kembali normal setelah pemulihan.

---

## Soal 19 — Proxy Cache dan Rate Limiting

### Tujuan

- Mengonfigurasi proxy caching halaman web di gojo dengan masa berlaku 10 menit.
- Menambahkan header `X-Cache-Status`.
- Menerapkan rate limiting `/api` 10 request per detik per IP client.
- Membuktikan MISS lalu HIT, dan status ketika batas rate limit terlampaui.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Cache path | `/var/cache/nginx/m3_web`, zone `m3_web_cache` |
| Masa berlaku | `proxy_cache_valid 200 301 302 10m` |
| Header | `X-Cache-Status $upstream_cache_status` |
| Bypass cache | `?nocache=1` |
| Rate limit | `limit_req_zone $binary_remote_addr rate=10r/s`, `burst=9 nodelay` |
| Status ditolak | `429` |
| On/off | `/root/m3-gojo-ratelimit.sh on|off` |

### Langkah Pengerjaan

#### A. Folder cache, file rate limit, dan script on/off — Gojo

`burst=9 nodelay` membuat maksimal 10 request (1 + 9) langsung diterima dalam satu detik, karena nginx menghitung jatah 10 r/s per 100 ms. Rate limit dipisah ke file include agar bisa dimatikan sementara untuk Soal 20.

**Node:** Gojo

```bash
mkdir -p /var/cache/nginx/m3_web
chown -R www-data:www-data /var/cache/nginx/m3_web
printf 'limit_req zone=m3_api_limit burst=9 nodelay;\nlimit_req_status 429;\nlimit_req_log_level error;\n' > /etc/nginx/m3-api-limit.conf
cat > /root/m3-gojo-ratelimit.sh <<'EOF'
#!/bin/bash
case "${1:-status}" in
    on)  printf 'limit_req zone=m3_api_limit burst=9 nodelay;\nlimit_req_status 429;\nlimit_req_log_level error;\n' > /etc/nginx/m3-api-limit.conf
         bash /root/m3-web-control.sh reload >/dev/null && echo 'RATE LIMIT /api: ON (10 r/s per IP)' ;;
    off) echo '# rate limit dimatikan sementara' > /etc/nginx/m3-api-limit.conf
         bash /root/m3-web-control.sh reload >/dev/null && echo 'RATE LIMIT /api: OFF' ;;
    *)   cat /etc/nginx/m3-api-limit.conf ;;
esac
EOF
chmod +x /root/m3-gojo-ratelimit.sh
cat /etc/nginx/m3-api-limit.conf
```

**Expected:** isi file `limit_req zone=m3_api_limit burst=9 nodelay;`.

#### B. Konfigurasi cache dan rate limit — Gojo

**Node:** Gojo

```bash
cat > /etc/nginx/sites-available/m3-gojo <<'EOF'
upstream web_frontend {
    zone web_frontend 64k;
    server 192.217.4.21;   # maki
    server 192.217.4.22;   # panda
}
upstream api_gateway {
    zone api_gateway 64k;
    server 192.217.4.20;   # geto
}
proxy_cache_path /var/cache/nginx/m3_web levels=1:2 keys_zone=m3_web_cache:10m max_size=100m inactive=30m use_temp_path=off;
limit_req_zone $binary_remote_addr zone=m3_api_limit:10m rate=10r/s;
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
EOF
bash /root/m3-web-control.sh reload
```

**Expected:** `syntax is ok` dan `NGINX AKTIF`.

#### C. Pengujian cache — Itadori

**Node:** Itadori

```bash
url="http://jujutsu.k12.com/?uji=$(date +%s)"; echo "URL: $url"
for i in 1 2 3; do echo "--- akses ke-$i ---"; curl -s -m 5 -D - -o /tmp/p.html "$url" | grep -iE '^HTTP|x-cache-status'; grep -o 'worker=[a-z]*' /tmp/p.html; done
```

**Expected:** akses ke-1 `X-Cache-Status: MISS`, akses ke-2 dan ke-3 `HIT` dengan worker yang sama.

![SS19-01-cache-miss-hit](image/SS19-01-cache-miss-hit.png)

*itadori: header `X-Cache-Status` MISS lalu HIT*

#### D. Pengujian rate limit — Itadori

**Node:** Itadori

```bash
rm -f /tmp/rl.txt
for i in $(seq 1 30); do curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://jujutsu.k12.com/api >> /tmp/rl.txt & done; wait
echo 'Hasil 30 request barengan:'; sort /tmp/rl.txt | uniq -c
sleep 1; printf 'setelah jeda 1 detik: '; curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://jujutsu.k12.com/api
```

**Expected:** sekitar 10–11 `200` dan sisanya `429`; setelah jeda 1 detik kembali `200`.

![SS19-02-rate-limit](image/SS19-02-rate-limit.png)

*itadori: 30 request paralel menghasilkan 200 dan 429*

**Node:** Gojo

```bash
grep -E 'cache=(MISS|HIT)' /var/log/nginx/m3-gojo.access.log | tail -n 3
grep 'status=429' /var/log/nginx/m3-gojo.access.log | tail -n 3
```

**Expected:** `cache=MISS` lalu `cache=HIT upstream="-"`, dan `status=429 upstream="-" limit=REJECTED`.

![SS19-03-log-gojo](image/SS19-03-log-gojo.png)

*gojo: log cache dan request yang ditolak rate limit*

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS19-01-cache-miss-hit.png` | itadori: header `X-Cache-Status` MISS lalu HIT |
| `image/SS19-02-rate-limit.png` | itadori: 30 request paralel menghasilkan 200 dan 429 |
| `image/SS19-03-log-gojo.png` | gojo: log cache dan request yang ditolak rate limit |

### Analisis

- Request HIT dijawab langsung oleh gojo (`upstream="-"`, `rt=0.000`) tanpa membebani maki/panda.
- Request yang melebihi batas ditolak di gojo dengan 429 dan tidak pernah diteruskan ke geto.
- Batas dihitung per IP client (`$binary_remote_addr`), sehingga satu client yang berlebihan tidak mengganggu client lain.

### Kesimpulan

Gojo berhasil mengoptimalkan halaman web dengan cache 10 menit dan melindungi `/api` dari request berlebihan dengan rate limit 10 r/s per IP.

---

## Soal 20 — Benchmark dan Analisis Rate Limit

### Tujuan

- Menjalankan Apache Benchmark `ab -n 600 -c 30` dari kusakabe ke `http://jujutsu.k12.com/`.
- Mencatat Requests per Second (RPS), latensi, dan request gagal.
- Menguji `/api` untuk mengamati efek rate limiting.
- Membandingkan baseline dengan kondisi rate limit aktif.
- Memakai access log gojo untuk membedakan kegagalan aplikasi, koneksi, dan penolakan rate limit.

### Informasi konfigurasi

| Komponen | Nilai |
|---|---|
| Penguji | kusakabe (Network 3) |
| Parameter | `-n 600 -c 30` |
| Pengujian 1 | `/` (cache aktif) |
| Pengujian 2 | `/api` rate limit OFF (baseline API) |
| Pengujian 3 | `/api` rate limit ON |
| Analisis log | `/root/m3-logstat.sh mark|show NAMA` di gojo |

### Langkah Pengerjaan

#### A. Persiapan — Kusakabe

**Node:** Kusakabe

```bash
udhcpc -i eth0 -n -q
command -v ab >/dev/null || apk add apache2-utils curl
ip -4 addr show eth0 | grep inet
```

**Expected:** IP `192.217.3.x` dan `ab` terpasang.

#### B. Script analisis access log — Gojo

`mark` menyimpan posisi baris log sebelum benchmark, `show` menghitung baris setelahnya dan mengelompokkan: sukses (2xx), ditolak rate limit (429), gagal koneksi (499/502/504), gagal aplikasi (5xx lain).

**Node:** Gojo

```bash
cat > /root/m3-logstat.sh <<'EOF'
#!/bin/bash
log=/var/log/nginx/m3-gojo.access.log; mark=/root/logmark-$2
case "$1" in
  mark) wc -l < "$log" > "$mark"; echo "Tanda '$2' di baris $(cat "$mark")" ;;
  show) tail -n +$(( $(cat "$mark") + 1 )) "$log" | awk -v n="$2" '
    { match($0,/status=[0-9]+/); s=substr($0,RSTART+7,RLENGTH-7); t++; c[s]++
      if (s=="429") rl++; else if (s=="499"||s=="502"||s=="504") cn++; else if (s ~ /^5/) ap++; else if (s ~ /^[23]/) ok++ }
    END { printf "ANALISIS LOG GOJO - %s\nTotal: %d\nSukses 2xx: %d\nDitolak rate limit (429): %d\nGagal koneksi (499/502/504): %d\nGagal aplikasi (5xx lain): %d\n", n,t,ok,rl,cn,ap
          for (k in c) printf "  HTTP %s : %d\n", k, c[k] }' ;;
esac
EOF
chmod +x /root/m3-logstat.sh; echo 'SCRIPT OK'
```

**Expected:** `SCRIPT OK`.

#### C. Pengujian 1 — web `/`

**Node:** Gojo

```bash
bash /root/m3-gojo-ratelimit.sh on; bash /root/m3-logstat.sh mark web
```

**Node:** Kusakabe

```bash
ab -n 600 -c 30 http://jujutsu.k12.com/ | tee /root/ab-web.txt | grep -E 'Complete|Failed|Non-2xx|Requests per second|Time per request|  50%|  99%'
```

![SS20-01-ab-web](image/SS20-01-ab-web.png)

*kusakabe: hasil `ab` ke `/`*

**Node:** Gojo

```bash
bash /root/m3-logstat.sh show web
```

![SS20-02-log-web](image/SS20-02-log-web.png)

*gojo: analisis log pengujian web*

#### D. Pengujian 2 — `/api` rate limit OFF

**Node:** Gojo

```bash
bash /root/m3-gojo-ratelimit.sh off; bash /root/m3-logstat.sh mark api-off
```

**Node:** Kusakabe

```bash
ab -n 600 -c 30 http://jujutsu.k12.com/api | tee /root/ab-api-off.txt | grep -E 'Complete|Failed|Non-2xx|Requests per second|Time per request|  50%|  99%'
```

![SS20-03-ab-api-off](image/SS20-03-ab-api-off.png)

*kusakabe: hasil `ab` ke `/api` tanpa rate limit*

**Node:** Gojo

```bash
bash /root/m3-logstat.sh show api-off
```

![SS20-04-log-api-off](image/SS20-04-log-api-off.png)

*gojo: analisis log `/api` tanpa rate limit*

#### E. Pengujian 3 — `/api` rate limit ON

**Node:** Gojo

```bash
bash /root/m3-gojo-ratelimit.sh on; bash /root/m3-logstat.sh mark api-on
```

**Node:** Kusakabe

```bash
ab -n 600 -c 30 http://jujutsu.k12.com/api | tee /root/ab-api-on.txt | grep -E 'Complete|Failed|Non-2xx|Requests per second|Time per request|  50%|  99%'
```

![SS20-05-ab-api-on](image/SS20-05-ab-api-on.png)

*kusakabe: hasil `ab` ke `/api` dengan rate limit*

**Node:** Gojo

```bash
bash /root/m3-logstat.sh show api-on
grep 'limiting requests' /var/log/nginx/error.log | tail -n 2
```

**Expected:** 600 total, 11 sukses, 589 ditolak rate limit (429), 0 gagal koneksi, 0 gagal aplikasi; error log `limiting requests ... client: 192.217.3.11`.

![SS20-06-log-api-on](image/SS20-06-log-api-on.png)

*gojo: analisis log `/api` dengan rate limit dan error log `limiting requests`*

#### F. Ringkasan — Kusakabe

**Node:** Kusakabe

```bash
for t in web api-off api-on; do f=/root/ab-$t.txt; printf '%-8s RPS=%-9s mean=%-8sms p99=%-6sms failed=%-4s non2xx=%s\n' "$t" "$(awk '/Requests per second/{print $4}' $f)" "$(awk '/Time per request/&&/\(mean\)/{print $4;exit}' $f)" "$(awk '/ 99%/{print $2}' $f)" "$(awk '/Failed requests/{print $3}' $f)" "$(awk '/Non-2xx/{n=$3}END{print n+0}' $f)"; done
```

![SS20-07-ringkasan](image/SS20-07-ringkasan.png)

*kusakabe: ringkasan RPS, latensi, failed, non-2xx ketiga pengujian*

#### G. Hasil

| Pengujian | RPS | Latensi mean (ms) | p99 (ms) | Failed (`ab`) | Non-2xx | Log gojo |
|---|---|---|---|---|---|---|
| `/` cache aktif | ... | ... | ... | ... | ... | ... |
| `/api` rate limit OFF | ... | ... | ... | ... | ... | ... |
| `/api` rate limit ON | ... | ... | ... | ... | 589 | 11 sukses, 589 ditolak 429, 0 koneksi, 0 aplikasi |

### Dokumentasi screenshot

| File | Isi yang harus terlihat |
|---|---|
| `image/SS20-01-ab-web.png` | kusakabe: hasil `ab` ke `/` |
| `image/SS20-02-log-web.png` | gojo: analisis log pengujian web |
| `image/SS20-03-ab-api-off.png` | kusakabe: hasil `ab` ke `/api` tanpa rate limit |
| `image/SS20-04-log-api-off.png` | gojo: analisis log `/api` tanpa rate limit |
| `image/SS20-05-ab-api-on.png` | kusakabe: hasil `ab` ke `/api` dengan rate limit |
| `image/SS20-06-log-api-on.png` | gojo: analisis log `/api` dengan rate limit dan error log `limiting requests` |
| `image/SS20-07-ringkasan.png` | kusakabe: ringkasan RPS, latensi, failed, non-2xx ketiga pengujian |

### Analisis

- `/` memiliki RPS tertinggi dan latensi terendah karena hampir seluruh request dijawab dari cache gojo (`cache=HIT`).
- `/api` tanpa rate limit paling lambat karena setiap request melewati gojo, geto, PHP, lalu INSERT ke database yaga.
- `/api` dengan rate limit terlihat lebih cepat secara semu: 589 request langsung ditolak gojo dengan 429 tanpa diproses backend (`upstream="-"`, `limit=REJECTED`).
- Jenis kegagalan dibedakan dari log gojo: `429` + `limit=REJECTED` = kebijakan rate limit; `502/504/499` = kegagalan koneksi; `500/503` dari upstream = kegagalan aplikasi. Pada pengujian ini kegagalan koneksi dan aplikasi bernilai 0.
- `Failed requests (Length)` pada `ab` bukan kegagalan sebenarnya, melainkan panjang respons yang berbeda (nama worker, `log_id`, waktu). Kegagalan sebenarnya dibaca dari `Non-2xx`, `Connect`, `Receive`, `Exceptions`, dan log gojo.

### Kesimpulan

Layanan web mampu menangani beban tinggi berkat cache, sedangkan rate limit efektif membatasi request berlebihan ke `/api` tanpa menimbulkan kegagalan koneksi maupun aplikasi.

---

## Rekap Screenshot

| Soal | File |
|---|---|
| 11 | `SS11-01-dig-kedua-server.png`<br>`SS11-02-axfr-ditolak.png`<br>`SS11-03-naikkan-serial.png`<br>`SS11-04-log-transfer-shoko.png`<br>`SS11-05-serial-sinkron.png`<br>`SS11-06-config-master.png` |
| 12 | `SS12-01-a-record.png`<br>`SS12-02-cname-www.png`<br>`SS12-03-ptr.png`<br>`SS12-04-slave-menjawab.png`<br>`SS12-05-ping-google.png`<br>`SS12-06-config-zona.png` |
| 13 | `SS13-01-master-config.png`<br>`SS13-02-insert-master.png`<br>`SS13-03-status-slave.png`<br>`SS13-04-data-di-slave.png`<br>`SS13-05-akses-remote.png` |
| 14 | `SS14-01-dari-gojo.png`<br>`SS14-02-dari-geto.png`<br>`SS14-03-client-ditolak.png`<br>`SS14-04-config-vhost.png` |
| 15 | `SS15-01-loop-wrr.png`<br>`SS15-02-config-log-geto.png` |
| 16 | `SS16-01-routing-client.png`<br>`SS16-02-config-gojo.png` |
| 17 | `SS17-01-itadori.png`<br>`SS17-02-ino.png`<br>`SS17-03-database.png`<br>`SS17-04-config-header.png` |
| 18 | `SS18-01-normal.png`<br>`SS18-02-matikan-worker.png`<br>`SS18-03-failover-kirara.png`<br>`SS18-04-log-geto.png`<br>`SS18-05-pulih.png` |
| 19 | `SS19-01-cache-miss-hit.png`<br>`SS19-02-rate-limit.png`<br>`SS19-03-log-gojo.png` |
| 20 | `SS20-01-ab-web.png`<br>`SS20-02-log-web.png`<br>`SS20-03-ab-api-off.png`<br>`SS20-04-log-api-off.png`<br>`SS20-05-ab-api-on.png`<br>`SS20-06-log-api-on.png`<br>`SS20-07-ringkasan.png` |

## Kendala dan Solusi

| Kendala | Penyebab | Solusi |
|---|---|---|
| Node kehilangan paket dan config setelah GNS3 ter-close | Hanya `/root` yang persisten | Script dan salinan konfigurasi disimpan di `/root`, lalu dijalankan ulang (`00-pemulihan-*.sh`, `m3-dns-restore.sh`) |
| `apt-get` gagal resolve setelah restart | NAT dan IP forwarding di jichi hilang | `bash /root/00-pemulihan-jichi.sh` |
| `m3-service.sh` error `here-document` | Baris `cat >> ... M3_FILE_END` ikut tertulis ke file | Hapus baris tersebut dengan `sed` |
| `dhcpd` gagal: `No subnet declaration for eth0` | `dhcpd.conf` kembali ke default setelah reinstall | Tulis ulang config dan simpan backup di `/root/modul3/dhcpd.conf.backup` |
| Client `dig` ke `127.0.0.1` | `resolv.conf` client kosong karena belum mendapat lease | `udhcpc -i eth0 -n -q` |
| `connection refused` ke DNS master | BIND di utahime belum aktif | `bash /root/m3-dns-control.sh start` |
| curl dari gojo ke Data Center `HTTP 000` | Gojo memiliki IP ganda (`192.217.4.20` ikut terpasang) | `ip addr flush dev eth0 scope global` lalu pasang ulang IP yang benar |
| `/` tidak bergantian maki/panda | Setiap proses worker nginx menyimpan giliran sendiri | Tambahkan `zone ... 64k` di dalam `upstream` |

