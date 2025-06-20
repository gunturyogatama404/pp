#!/bin/bash

# === KONFIGURASI ===
USERNAME="akirajie"
PASSWORD="wildan123"
PASSWD_FILE="/etc/squid/passwd"
BASE_PORT=3110
MAX_TOTAL_PORTS=500
MAX_PORT_PER_IP=3
MIN_PORT_PER_IP=1

# === AMBIL SEMUA IP PUBLIK DARI SEMUA INTERFACE YANG AKTIF ===
IPS=()
while IFS= read -r ip; do
    if [[ ! $ip =~ ^127\. && ! $ip =~ ^10\. && ! $ip =~ ^192\.168\. && ! $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
        IPS+=("$ip")
    fi
done < <(ip -4 -o addr show up | awk '{print $4}' | cut -d/ -f1 | sort -u)

if (( ${#IPS[@]} == 0 )); then
    echo "❌ Tidak ditemukan IP publik. Pastikan interface aktif dan memiliki IP publik."
    exit 1
fi

TOTAL_IPS=${#IPS[@]}
MAX_POSSIBLE_PORTS=$((TOTAL_IPS * MAX_PORT_PER_IP))

if (( MAX_POSSIBLE_PORTS < MAX_TOTAL_PORTS )); then
    TOTAL_PORTS=$MAX_POSSIBLE_PORTS
else
    TOTAL_PORTS=$MAX_TOTAL_PORTS
fi

# === INSTALL DEPENDENSI ===
apt update -y
apt install -y squid apache2-utils curl

# === BUAT USER ===
htpasswd -cb $PASSWD_FILE $USERNAME "$PASSWORD"
chmod 640 $PASSWD_FILE
chown proxy:proxy $PASSWD_FILE

# === DISTRIBUSI PORTS ===
declare -A IP_PORT_COUNT
PORT_LIST=()
PORT=$BASE_PORT

# 1. Semua IP dapat 1 port dulu
for ip in "${IPS[@]}"; do
    if (( ${#PORT_LIST[@]} >= TOTAL_PORTS )); then break; fi
    IP_PORT_COUNT["$ip"]=1
    PORT_LIST+=("$ip:$PORT")
    ((PORT++))
done

# 2. Tambah port ke IP yang belum mencapai batas
NEED_EXTRA=$((TOTAL_PORTS - ${#PORT_LIST[@]}))
if (( NEED_EXTRA > 0 )); then
    SHUFFLED_IPS=( $(shuf -e "${IPS[@]}") )
    i=0
    while (( NEED_EXTRA > 0 )); do
        ip="${SHUFFLED_IPS[$i]}"
        if (( ${IP_PORT_COUNT["$ip"]} < MAX_PORT_PER_IP )); then
            ((IP_PORT_COUNT["$ip"]++))
            PORT_LIST+=("$ip:$PORT")
            ((PORT++))
            ((NEED_EXTRA--))
        fi
        ((i++))
        if (( i >= TOTAL_IPS )); then i=0; fi
    done
fi

# === BUAT KONFIGURASI SQUID ===
cp /etc/squid/squid.conf /etc/squid/squid.conf.bak.$(date +%F-%T)

cat > /etc/squid/squid.conf <<EOF
auth_param basic program /usr/lib/squid/basic_ncsa_auth $PASSWD_FILE
auth_param basic realm Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
logfile_rotate 10
buffered_logs on
dns_v4_first on
visible_hostname proxy.local
EOF

for entry in "${PORT_LIST[@]}"; do
    ip="${entry%%:*}"
    port="${entry##*:}"
    echo "http_port $port" >> /etc/squid/squid.conf
    echo "acl toport$port myport $port" >> /etc/squid/squid.conf
    echo "tcp_outgoing_address $ip toport$port" >> /etc/squid/squid.conf
    echo "" >> /etc/squid/squid.conf
done

# === RESTART SQUID ===
systemctl restart squid

if systemctl is-active --quiet squid; then
    echo "✅ Squid berjalan!"
else
    echo "❌ Squid gagal jalan, cek log dengan: journalctl -xe"
fi

# === OUTPUT FILE ===
[ -f proxies.txt ] && mv proxies.txt proxies_backup_$(date +%F-%H%M%S).txt
> proxies.txt
for entry in "${PORT_LIST[@]}"; do
    ip="${entry%%:*}"
    port="${entry##*:}"
    echo "http://$USERNAME:$PASSWORD@$ip:$port" >> proxies.txt
done

echo "✅ proxies.txt selesai dibuat dengan total ${#PORT_LIST[@]} port"
