#!/bin/bash
# =====================================================================
# Pemulihan TENGEN (DHCP server) setelah GNS3 ter-close / node restart
# Config dasar DHCP yang dipakai (subnet .4 tanpa pool, pool Net2 & Net3,
# DNS 192.217.1.2/.1.3, domain-search k12.com) disimpan di /root.
# bash /root/00-pemulihan-tengen.sh
# =====================================================================
export DEBIAN_FRONTEND=noninteractive
ip -4 addr show eth0 | grep -q '192.217.4.10/24' || { ip link set eth0 up; ip addr add 192.217.4.10/24 broadcast 192.217.4.255 dev eth0; }
ip route replace default via 192.217.4.1 dev eth0
printf 'nameserver 192.217.1.2\nnameserver 192.168.122.1\n' > /etc/resolv.conf
command -v dhcpd >/dev/null || { apt-get update; apt-get install -y isc-dhcp-server; }
mkdir -p /root/modul3
if [ ! -f /root/modul3/dhcpd.conf.backup ]; then
cat > /root/modul3/dhcpd.conf.backup <<'DHCPD_CONF'
authoritative;
ddns-update-style none;
default-lease-time 3600;
max-lease-time 7200;
option domain-name "k12.com";
option domain-search "k12.com";
option domain-name-servers 192.217.1.2, 192.217.1.3;

# Network 4 (tengen sendiri) - tanpa pool
subnet 192.217.4.0 netmask 255.255.255.0 {
    option routers 192.217.4.1;
    option broadcast-address 192.217.4.255;
}

# Network 2 - Divisi A
subnet 192.217.2.0 netmask 255.255.255.0 {
    option routers 192.217.2.1;
    option broadcast-address 192.217.2.255;
    pool { range 192.217.2.10 192.217.2.35; }
    pool { range 192.217.2.70 192.217.2.95; }
}

# Network 3 - Divisi B
subnet 192.217.3.0 netmask 255.255.255.0 {
    option routers 192.217.3.1;
    option broadcast-address 192.217.3.255;
    pool { range 192.217.3.10 192.217.3.89; }
    pool { range 192.217.3.100 192.217.3.199; }
}
DHCPD_CONF
fi
cp /root/modul3/dhcpd.conf.backup /etc/dhcp/dhcpd.conf
printf 'INTERFACESv4="eth0"\nINTERFACESv6=""\n' > /etc/default/isc-dhcp-server
dhcpd -t -cf /etc/dhcp/dhcpd.conf && echo 'CONFIG OK'
bash /root/m3-service.sh server restart
bash /root/m3-service.sh server status

# ---------- No.15: uji Weighted Round Robin dari Data Center ----------
# command -v curl >/dev/null || apt-get install -y curl
# : > /root/m3-wrr.txt
# for i in $(seq 1 40); do curl -s -m 5 http://192.217.4.20/api | grep -o '"worker":"[a-z]*"' | cut -d'"' -f4 >> /root/m3-wrr.txt; done
# head -n 12 /root/m3-wrr.txt | paste -sd' '; sort /root/m3-wrr.txt | uniq -c
