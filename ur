#!/bin/bash
# uprock =================================================================
# Skrip Otomatisasi UpRock Network untuk Multi-IP
# Versi: 1.1
# Tanggal: 17 Juni 2025
#
# Deskripsi:
# Skrip ini mengotomatiskan seluruh proses penyiapan UpRock Network
# pada server dengan banyak alamat IP publik. Skrip ini akan:
# 1. Memastikan Docker dan iptables terinstal.
# 2. Mendeteksi semua alamat IP publik yang tersedia.
# 3. Untuk setiap IP, membuat jaringan Docker terisolasi.
# 4. Menambahkan aturan 'iptables' untuk merutekan lalu lintas keluar dari kontainer
#    melalui alamat IP spesifik tersebut.
# 5. Menjalankan kontainer UpRock Network pada jaringan yang sesuai.
# =================================================================

# --- CARA PENGGUNAAN ---
# 1. Ganti nilai 'USER_AUTH' dan 'PASSWORD' dengan kredensial dari akun UpRock Anda.
# 2. Simpan skrip ini (misal: ur.sh).
# 3. Beri izin eksekusi: chmod +x ur.sh
# 4. Jalankan dengan hak akses root: sudo ./ur.sh
# -----------------------------------------------------------------

# --- KONFIGURASI ---
# WAJIB: Ganti dengan kredensial akun UpRock Anda
USER_AUTH="gunturyogatamafebriadi@gmail.com"
PASSWORD="Wildan123@GF"

# Nama image Docker yang akan digunakan
IMAGE="ghcr.io/techroy23/docker-urnetwork:latest"

# Arsitektur platform. Ubah ke "linux/arm64" jika menggunakan Raspberry Pi atau server ARM.
PLATFORM="linux/amd64"

# Awalan untuk nama kontainer dan jaringan
NAME_PREFIX="uprock-cli"

# Subnet dasar untuk jaringan docker. Setiap kontainer akan mendapatkan
# subnet unik (misal: 172.29.1.0/24, 172.29.2.0/24, dst.)
SUBNET_BASE="172.29"


# --- FUNGSI & EKSEKUSI UTAMA ---

# Fungsi untuk cek dan install docker jika belum ada
install_docker_if_needed() {
    if ! command -v docker &> /dev/null; then
        echo "[INFO] Docker tidak ditemukan. Menginstal Docker..."
        # Perintah di bawah ini untuk Debian/Ubuntu.
        apt-get update -y
        apt-get install -y ca-certificates curl gnupg lsb-release iptables
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        echo "[INFO] Docker berhasil diinstal."
    else
        echo "[INFO] Docker sudah terinstal."
    fi
}

# Fungsi untuk membersihkan sumber daya lama (kontainer, jaringan, aturan iptables)
cleanup_resources() {
    local container_name=$1
    echo "[INFO] Membersihkan sumber daya lama untuk $container_name..."

    # 1. Hapus kontainer lama jika ada
    docker rm -f "$container_name" &> /dev/null

    # 2. Hapus aturan iptables lama yang memiliki komentar yang cocok
    while iptables-save | grep -q -- "-m comment --comment $container_name"; do
        local rule_to_delete
        rule_to_delete=$(iptables-save | grep -- "-m comment --comment $container_name" | sed 's/^-A/-D/')
        eval "iptables -t nat $rule_to_delete"
    done

    # 3. Hapus jaringan docker lama jika ada
    docker network rm "${container_name}-net" &> /dev/null
}


# --- EKSEKUSI UTAMA ---

# 1. Pastikan skrip dijalankan sebagai root
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] Skrip ini harus dijalankan sebagai root atau dengan 'sudo'." >&2
  exit 1
fi

# 2. Cek konfigurasi Kredensial
if [ "$USER_AUTH" == "ganti.dengan@email.anda" ] || [ "$PASSWORD" == "GantiDenganPasswordAnda" ]; then
    echo "[ERROR] Harap edit skrip ini dan ganti nilai variabel USER_AUTH dan PASSWORD dengan kredensial Anda."
    exit 1
fi

# 3. Instal Docker jika diperlukan
install_docker_if_needed

# 4. Ambil semua IP publik/eksternal
IP_LIST=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v -E '127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.|10\.')

if [ -z "$IP_LIST" ]; then
    echo "[PERINGATAN] Tidak ada alamat IP eksternal yang dapat digunakan yang ditemukan. Skrip berhenti."
    exit 1
fi

echo "[INFO] Ditemukan alamat IP berikut untuk diproses:"
echo "$IP_LIST"
echo "---"

# 5. Tarik image Docker terlebih dahulu
echo "[INFO] Menarik image Docker terbaru: $IMAGE..."
docker pull --platform "$PLATFORM" "$IMAGE"

# 6. Loop melalui setiap IP dan siapkan kontainer
i=1
for IP in $IP_LIST; do
    CONTAINER_NAME="${NAME_PREFIX}-${i}"
    NETWORK_NAME="${CONTAINER_NAME}-net"
    SUBNET="${SUBNET_BASE}.${i}.0/24"

    echo "=========================================================="
    echo "[PROSES] Menyiapkan IP: $IP (Kontainer: $CONTAINER_NAME)"
    echo "=========================================================="

    cleanup_resources "$CONTAINER_NAME"

    echo "[LANGKAH 1/3] Membuat jaringan Docker: $NETWORK_NAME dengan subnet: $SUBNET"
    docker network create "$NETWORK_NAME" --driver bridge --subnet "$SUBNET"
    if [ $? -ne 0 ]; then
        echo "[ERROR] Gagal membuat jaringan Docker. Lanjut ke IP berikutnya."
        continue
    fi

    echo "[LANGKAH 2/3] Menambahkan aturan iptables untuk merutekan $SUBNET via $IP"
    iptables -t nat -I POSTROUTING -s "$SUBNET" -j SNAT --to-source "$IP" -m comment --comment "$CONTAINER_NAME"
    if [ $? -ne 0 ]; then
        echo "[ERROR] Gagal menambahkan aturan iptables. Membersihkan dan lanjut ke IP berikutnya."
        docker network rm "$NETWORK_NAME"
        continue
    fi

    echo "[LANGKAH 3/3] Menjalankan kontainer $CONTAINER_NAME..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        --platform "$PLATFORM" \
        --restart=always \
        -e USER_AUTH="$USER_AUTH" \
        -e PASSWORD="$PASSWORD" \
        "$IMAGE"

    ((i++))
done

echo ""
echo "=========================================================="
echo "[SELESAI] Semua kontainer UpRock telah disiapkan dan dijalankan."
echo "Anda bisa memeriksa status kontainer dengan perintah: docker ps"
echo ""
echo "[PENTING!] Aturan iptables yang dibuat akan HILANG saat reboot."
echo "Untuk membuatnya permanen (di Debian/Ubuntu), jalankan perintah berikut:"
echo "sudo apt-get update && sudo apt-get install iptables-persistent -y"
echo "sudo netfilter-persistent save"
echo "=========================================================="
