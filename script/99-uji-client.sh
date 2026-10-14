#!/bin/sh
# =====================================================================
# Modul 3 K12 - PERINTAH UJI DARI CLIENT ALPINE (nomor 11-20)
# Pemakaian: sh /root/99-uji-client.sh NOMOR     contoh: sh /root/99-uji-client.sh 12
#   11,12,14,16,17,18,19 -> jalankan di ITADORI (17 juga di INO)
#   20                   -> jalankan di KUSAKABE
# =====================================================================
D=jujutsu.k12.com
prep() {
    ip -4 addr show eth0 | grep -q 'inet 192.217' || udhcpc -i eth0 -n -q
    command -v dig >/dev/null && command -v curl >/dev/null && command -v ab >/dev/null || apk add bind-tools curl apache2-utils
}
prep
case "$1" in
11)
    for s in 192.217.1.2 192.217.1.3; do echo "===== DNS $s ====="; dig @$s $D SOA; dig @$s $D NS +short; done
    echo '===== AXFR dari client (harus Transfer failed) ====='; dig @192.217.1.2 $D AXFR
    echo '>>> Sekarang di utahime: bash /root/m3-dns-bump.sh, lalu tekan Enter'; read x
    for s in 192.217.1.2 192.217.1.3; do echo "$s serial=$(dig @$s $D SOA +short | awk '{print $3}') sync=$(dig @$s sync.$D TXT +short)"; done
    ;;
12)
    dig $D; dig www.$D; dig -x 192.217.1.4
    dig @192.217.1.3 www.$D +short; dig @192.217.1.3 -x 192.217.1.4 +short
    ping -c 3 google.com
    ;;
14)
    for ip in 192.217.4.21 192.217.4.22; do printf "client -> web $ip: "; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' -H "Host: $D" http://$ip/; done
    for ip in 192.217.4.31 192.217.4.32 192.217.4.33; do printf "client -> API $ip: "; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' -H "Host: $D" http://$ip/api; done
    printf 'client -> maki pakai IP mentah: '; curl -s -m 5 -o /dev/null -w 'HTTP %{http_code}\n' http://192.217.4.21/
    ;;
16)
    echo '=== WEB (/) - gantian maki/panda ==='
    for i in 1 2 3 4 5 6; do printf "request $i: "; curl -s -m 5 "http://$D/?nocache=1" | grep -o 'worker=[a-z]*'; done
    echo '=== /api - nanami/todo ==='
    for i in 1 2 3 4 5 6 7 8; do printf "request $i: "; curl -s -m 5 http://$D/api | grep -o '"worker":"[a-z]*"'; done
    echo '=== www ==='; curl -s -m 5 "http://www.$D/?nocache=1" | grep -o 'worker=[a-z]*'; curl -s -m 5 http://www.$D/api | grep -o '"worker":"[a-z]*"'
    ;;
17)
    ip -4 addr show eth0 | grep inet
    echo '=== normal ==='; curl -s -m 5 http://$D/api
    echo '=== header PALSU 6.6.6.6 ==='; curl -s -m 5 -H 'X-Real-IP: 6.6.6.6' -H 'X-Forwarded-For: 6.6.6.6' http://$D/api
    ;;
18)
    n=${2:-10}; i=1
    while [ "$i" -le "$n" ]; do
        out=$(curl -s -m 5 -w ' HTTP=%{http_code}' http://$D/api)
        w=$(echo "$out" | grep -o '"worker":"[a-z]*"' | cut -d'"' -f4)
        s=$(echo "$out" | grep -o '"status":"[a-z]*"' | cut -d'"' -f4)
        c=$(echo "$out" | grep -o 'HTTP=[0-9]*')
        echo "request $i: $c worker=${w:-?} status=${s:-?}"
        i=$((i + 1)); sleep 0.3
    done
    ;;
19)
    url="http://$D/?uji=$(date +%s)"; echo "URL: $url"
    for i in 1 2 3; do echo "--- akses ke-$i ---"; curl -s -m 5 -D - -o /tmp/p.html "$url" | grep -iE '^HTTP|x-cache-status'; grep -o 'worker=[a-z]*' /tmp/p.html; done
    rm -f /tmp/rl.txt
    for i in $(seq 1 30); do curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://$D/api >> /tmp/rl.txt & done; wait
    echo 'Hasil 30 request barengan:'; sort /tmp/rl.txt | uniq -c
    sleep 1; printf 'setelah jeda 1 detik: '; curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://$D/api
    ;;
20)
    # Urutan: gojo "m3-gojo-ratelimit.sh on|off" + "m3-logstat.sh mark NAMA" sebelum tiap ab
    t=${2:?pakai: sh 99-uji-client.sh 20 web|api-off|api-on}
    case "$t" in web) u="http://$D/" ;; *) u="http://$D/api" ;; esac
    ab -n 600 -c 30 "$u" | tee /root/ab-$t.txt | grep -E 'Complete|Failed|Non-2xx|Requests per second|Time per request|  50%|  99%'
    ;;
20-ringkasan)
    for t in web api-off api-on; do f=/root/ab-$t.txt; [ -f $f ] || continue
        printf '%-8s RPS=%-9s mean=%-8sms p99=%-6sms failed=%-4s non2xx=%s\n' "$t" "$(awk '/Requests per second/{print $4}' $f)" "$(awk '/Time per request/&&/\(mean\)/{print $4;exit}' $f)" "$(awk '/ 99%/{print $2}' $f)" "$(awk '/Failed requests/{print $3}' $f)" "$(awk '/Non-2xx/{n=$3}END{print n+0}' $f)"; done
    ;;
*) echo 'Pakai: sh 99-uji-client.sh 11|12|14|16|17|18|19|20 web|api-off|api-on|20-ringkasan' ;;
esac
