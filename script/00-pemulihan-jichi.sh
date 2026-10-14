#!/bin/bash
# =====================================================================
# Pemulihan JICHI setelah GNS3 ter-close / node restart
# (NAT + IP forwarding + DHCP relay, memakai m3-service.sh milik Ndaru)
# bash /root/00-pemulihan-jichi.sh
# =====================================================================
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
