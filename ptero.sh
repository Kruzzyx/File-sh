#!/usr/bin/env bash
set -euo pipefail

PANEL_DIR="/var/www/pterodactyl"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
ART="php -d display_errors=0 $PANEL_DIR/artisan"

# Nest & Egg (bisa diubah lewat env: NEST_NAME="Nama" NEST_DESC="Deskripsi")
NEST_NAME="${NEST_NAME:-Kruzzy}"
NEST_DESC="${NEST_DESC:-Support @KruzzyX Terus Bang🙏}"
EGG_URLS=(
  "https://kruzzy.biz.id/node.json"
)

echo "=== AUTO CREATE LOCATION, NODE, ALLOCATION, NEST/EGG, SERVER & WINGS CONFIG ==="

fail() { echo "ERROR: $*" >&2; exit 1; }
clean() { printf '%s' "${1//[$'\r\n']/}"; }

# Teks prompt di bawah ini jangan diubah (dipakai auto-jawab oleh bot)
LOC_SHORT="" LOC_DESC="" NODE_FQDN="" NODE_NAME="" NODE_RAM="" NODE_DISK="" ALLOC_COUNT=""
read -r -p "Masukkan Location Short Code (contoh: SGP): " LOC_SHORT || true
read -r -p "Masukkan Location Description: " LOC_DESC || true
read -r -p "Masukkan FQDN / Domain Node: " NODE_FQDN || true
read -r -p "Masukkan Nama Node (contoh: NODES): " NODE_NAME || true
read -r -p "Masukkan Memory / RAM (MB): " NODE_RAM || true
read -r -p "Masukkan Disk Space (MB): " NODE_DISK || true
read -r -p "Masukkan jumlah Allocation port (contoh: 1): " ALLOC_COUNT || true

LOC_SHORT="$(clean "$LOC_SHORT")"
LOC_DESC="$(clean "$LOC_DESC")"
NODE_FQDN="$(clean "$NODE_FQDN")"
NODE_NAME="$(clean "$NODE_NAME")"
NODE_RAM="$(clean "$NODE_RAM")"
NODE_DISK="$(clean "$NODE_DISK")"

LOC_SHORT="${LOC_SHORT:-SGP}"
LOC_DESC="${LOC_DESC:-Jangan Lupa Support @KruzzyNotDev}"
NODE_NAME="${NODE_NAME:-NODES}"
[[ "$NODE_RAM" =~ ^[0-9]+$ ]] || NODE_RAM=4000
[[ "$NODE_DISK" =~ ^[0-9]+$ ]] || NODE_DISK=4000

[[ -n "$NODE_FQDN" ]] || fail "FQDN / Domain Node wajib diisi."
[[ -f "$PANEL_DIR/artisan" ]] || fail "Panel tidak ditemukan di $PANEL_DIR."
command -v php >/dev/null 2>&1 || fail "PHP tidak ditemukan."

# Jalankan kode PHP di dalam konteks panel.
# Kode dibaca dari stdin dan TIDAK boleh diawali <?php (sudah ada di header).
run_php() {
  local f rc=0
  f="$(mktemp)"
  {
    cat <<'PHP'
<?php
chdir('/var/www/pterodactyl');
require '/var/www/pterodactyl/vendor/autoload.php';
$app = require '/var/www/pterodactyl/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
PHP
    cat
  } > "$f"
  php -d display_errors=0 "$f" || rc=$?
  rm -f "$f"
  return $rc
}

# Ambil ID dari output bertanda __ID__=angka (kebal terhadap warning PHP)
get_loc_id() {
  LOC_SHORT="$LOC_SHORT" run_php 2>/dev/null <<'PHP' | sed -n 's/^__ID__=\([0-9][0-9]*\)$/\1/p' | tail -n 1
echo "__ID__=" . \Pterodactyl\Models\Location::where('short', getenv('LOC_SHORT'))->value('id') . "\n";
PHP
}

get_node_id() {
  NODE_FQDN="$NODE_FQDN" run_php 2>/dev/null <<'PHP' | sed -n 's/^__ID__=\([0-9][0-9]*\)$/\1/p' | tail -n 1
echo "__ID__=" . \Pterodactyl\Models\Node::where('fqdn', getenv('NODE_FQDN'))->value('id') . "\n";
PHP
}

# 1. Location
echo "[1/6] Membuat Location $LOC_SHORT..."
LOC_ID="$(get_loc_id || true)"
if [[ -z "$LOC_ID" ]]; then
  $ART p:location:make --short="$LOC_SHORT" --long="$LOC_DESC" --no-interaction \
    || fail "Gagal membuat Location."
  LOC_ID="$(get_loc_id || true)"
fi
[[ -n "$LOC_ID" ]] || fail "Location ID tidak ditemukan."

# 2. Node
if [[ -d "/etc/letsencrypt/live/$NODE_FQDN" ]]; then SCHEME="https"; else SCHEME="http"; fi

echo "[2/6] Membuat Node $NODE_NAME ($NODE_FQDN, $SCHEME)..."
NODE_ID="$(get_node_id || true)"
if [[ -z "$NODE_ID" ]]; then
  $ART p:node:make \
    --name="$NODE_NAME" \
    --description="$LOC_DESC" \
    --locationId="$LOC_ID" \
    --fqdn="$NODE_FQDN" \
    --public=1 \
    --scheme="$SCHEME" \
    --proxy=0 \
    --maxMemory="$NODE_RAM" --overallocateMemory=0 \
    --maxDisk="$NODE_DISK" --overallocateDisk=0 \
    --uploadSize=100 \
    --daemonListeningPort=8080 --daemonSFTPPort=2022 \
    --daemonBase=/var/lib/pterodactyl/volumes \
    --no-interaction || fail "Gagal membuat Node."
  NODE_ID="$(get_node_id || true)"
else
  echo "Node dengan FQDN ini sudah ada (ID $NODE_ID), dipakai ulang."
fi
[[ -n "$NODE_ID" ]] || fail "Node ID tidak ditemukan."

# 3. Allocation 2000-2300 (dilewati kalau node sudah punya allocation)
echo "[3/6] Membuat Allocation 0.0.0.0:2000-2300..."
NODE_ID="$NODE_ID" run_php <<'PHP' || fail "Gagal membuat Allocation."
try {
    $node = \Pterodactyl\Models\Node::findOrFail((int) getenv('NODE_ID'));
    if ($node->allocations()->count() > 0) {
        echo "Allocation sudah ada, dilewati\n";
        exit(0);
    }
    app(\Pterodactyl\Services\Allocations\AssignmentService::class)->handle($node, [
        'allocation_ip' => '0.0.0.0',
        'allocation_ports' => ['2000-2300'],
        'allocation_alias' => 'KruzzyNotDev',
    ]);
    echo "Allocation dibuat\n";
} catch (\Throwable $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
PHP

# 3b. Hapus Nest bawaan (tidak fatal)
# Ubah lewat env: NEST_DELETE="Minecraft,Source Engine,Voice Servers,Rust"
NEST_DELETE="${NEST_DELETE:-Minecraft,Source Engine,Voice Servers,Rust}"

echo "[3b] Menghapus Nest bawaan: $NEST_DELETE..."
NEST_DELETE="$NEST_DELETE" NEST_NAME="$NEST_NAME" run_php <<'PHP' || echo "PERINGATAN: Hapus Nest ada yang gagal."
use Pterodactyl\Models\Nest;
$svc = app(\Pterodactyl\Services\Nests\NestDeletionService::class);
foreach (explode(',', getenv('NEST_DELETE')) as $n) {
    $n = trim($n);
    if ($n === '' || $n === getenv('NEST_NAME')) continue; // jangan hapus nest sendiri
    try {
        $nest = Nest::where('name', $n)->first();
        if (!$nest) { echo "Nest tidak ada, dilewati: $n\n"; continue; }
        $svc->handle($nest->id);
        echo "Nest dihapus: $n\n";
    } catch (\Throwable $e) {
        echo "PERINGATAN: gagal hapus '$n' - " . $e->getMessage() . "\n";
    }
}
PHP

# 4. Nest & Egg (tidak fatal: kalau gagal hanya muncul peringatan)
# Egg tambahan: taruh file .json di /root/eggs/ sebelum menjalankan script.
echo "[4/6] Membuat Nest '$NEST_NAME' & import Egg..."
EGG_DIR="$(mktemp -d)"
i=0
for url in "${EGG_URLS[@]}"; do
  i=$((i + 1))
  out="$EGG_DIR/egg-$i.json"
  if curl -fsSL --retry 2 --max-time 60 -o "$out" "$url" 2>/dev/null && [[ "$(head -c 1 "$out")" == "{" ]]; then
    echo "Download egg OK: ${url##*/}"
  else
    rm -f "$out"
    echo "PERINGATAN: gagal download egg ${url##*/}"
  fi
done
if compgen -G "/root/eggs/*.json" >/dev/null; then
  cp /root/eggs/*.json "$EGG_DIR/" 2>/dev/null || true
fi

NEST_NAME="$NEST_NAME" NEST_DESC="$NEST_DESC" EGG_DIR="$EGG_DIR" run_php <<'PHP' || echo "PERINGATAN: Nest/Egg tidak berhasil dibuat, lanjut ke tahap berikutnya."
$nestName = getenv('NEST_NAME');
$nestDesc = getenv('NEST_DESC');
$dir = rtrim(getenv('EGG_DIR'), '/');
try {
    $nest = \Pterodactyl\Models\Nest::where('name', $nestName)->first();
    if (!$nest) {
        $nest = app(\Pterodactyl\Services\Nests\NestCreationService::class)->handle([
            'name' => $nestName,
            'description' => $nestDesc,
        ]);
        echo "Nest dibuat: {$nest->name} (ID {$nest->id})\n";
    } else {
        echo "Nest sudah ada: {$nest->name} (ID {$nest->id})\n";
    }
} catch (\Throwable $e) {
    fwrite(STDERR, "Gagal membuat Nest: " . $e->getMessage() . "\n");
    exit(1);
}

$importer = app(\Pterodactyl\Services\Eggs\Sharing\EggImporterService::class);
$ok = $skip = $bad = 0;
foreach (glob($dir . '/*.json') ?: [] as $file) {
    $base = basename($file);
    try {
        $content = file_get_contents($file);
        $json = json_decode($content, true);
        if (!is_array($json) || empty($json['name'])) {
            throw new \RuntimeException('JSON egg tidak valid');
        }
        if (\Pterodactyl\Models\Egg::where('nest_id', $nest->id)->where('name', $json['name'])->exists()) {
            echo "Egg sudah ada, dilewati: {$json['name']}\n";
            $skip++;
            continue;
        }
        $egg = null;
        if (method_exists($importer, 'handleContent')) {
            try {
                $egg = $importer->handleContent($nest->id, $content, 'application/json');
            } catch (\Throwable $e) {
                $egg = null;
            }
        }
        if (!$egg) {
            $upload = new \Illuminate\Http\UploadedFile($file, $base, 'application/json', null, true);
            $egg = $importer->handle($upload, $nest->id);
        }
        echo "Egg diimpor: {$egg->name}\n";
        $ok++;
    } catch (\Throwable $e) {
        echo "PERINGATAN: egg {$base} gagal diimpor - " . $e->getMessage() . "\n";
        $bad++;
    }
}
echo "Egg: $ok diimpor, $skip dilewati, $bad gagal\n";
PHP
rm -rf "$EGG_DIR"

# 5. Config Wings + start
echo "[5/6] Menulis config Wings & start service..."
mkdir -p "$(dirname "$WINGS_CONFIG")"
TMP_CFG="$(mktemp)"
$ART p:node:configuration "$NODE_ID" > "$TMP_CFG" 2>/dev/null \
  || { rm -f "$TMP_CFG"; fail "Gagal generate config Wings."; }
grep -q '^uuid:' "$TMP_CFG" \
  || { rm -f "$TMP_CFG"; fail "Config Wings tidak valid (uuid tidak ditemukan)."; }
mv -f "$TMP_CFG" "$WINGS_CONFIG"
chmod 600 "$WINGS_CONFIG"

# Perbaiki owner (artisan dijalankan sebagai root, bisa bikin log/cache milik root)
chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true

systemctl daemon-reload
systemctl enable wings >/dev/null 2>&1 || true
systemctl restart wings || true

sleep 3
WINGS_STATUS="$(systemctl is-active wings 2>/dev/null || true)"
[[ -n "$WINGS_STATUS" ]] || WINGS_STATUS="inactive"

# 6. Auto-create Server (tidak fatal) - dijalankan terakhir setelah Wings aktif
SERVER_NAME="${SERVER_NAME:-kruzzy}"
SERVER_EGG="${SERVER_EGG:-Node.js}"
SERVER_OWNER="${SERVER_OWNER:-admin@gmail.com}"

echo "[6/6] Membuat Server '$SERVER_NAME'..."
if [[ "$WINGS_STATUS" == "active" ]]; then
  echo "Menunggu Wings siap..."
  sleep 5

  SERVER_NAME="$SERVER_NAME" SERVER_EGG="$SERVER_EGG" SERVER_OWNER="$SERVER_OWNER" \
  NEST_NAME="$NEST_NAME" NODE_ID="$NODE_ID" run_php <<'PHP' || echo "PERINGATAN: Server tidak berhasil dibuat."
use Pterodactyl\Models\{Server, User, Nest, Egg, Node};
try {
    $name = getenv('SERVER_NAME');
    if (Server::where('name', $name)->exists()) {
        echo "Server sudah ada, dilewati\n";
        exit(0);
    }
    $owner = User::where('email', getenv('SERVER_OWNER'))->first()
          ?? User::where('root_admin', 1)->first();
    if (!$owner) throw new \RuntimeException('Owner tidak ditemukan');

    $nest = Nest::where('name', getenv('NEST_NAME'))->firstOrFail();
    $egg = Egg::where('nest_id', $nest->id)->where('name', getenv('SERVER_EGG'))->firstOrFail();
    $node = Node::findOrFail((int) getenv('NODE_ID'));

    $alloc = $node->allocations()->whereNull('server_id')->orderBy('port')->first();
    if (!$alloc) throw new \RuntimeException('Allocation kosong');

    $env = [];
    foreach ($egg->variables as $v) {
        $env[$v->env_variable] = $v->default_value;
    }
    $images = array_values($egg->docker_images);

    $server = app(\Pterodactyl\Services\Servers\ServerCreationService::class)->handle([
        'name' => $name,
        'description' => '',
        'owner_id' => $owner->id,
        'node_id' => $node->id,
        'allocation_id' => $alloc->id,
        'allocation_additional' => [],
        'nest_id' => $nest->id,
        'egg_id' => $egg->id,
        'image' => $images[0] ?? '',
        'startup' => $egg->startup,
        'environment' => $env,
        'memory' => 0,
        'swap' => 0,
        'disk' => 0,
        'io' => 500,
        'cpu' => 0,
        'threads' => null,
        'oom_disabled' => true,
        'database_limit' => 0,
        'allocation_limit' => 0,
        'backup_limit' => 0,
        'start_on_completion' => true,
    ]);
    echo "Server dibuat: {$server->name} (ID {$server->id}, port {$alloc->port})\n";
} catch (\Throwable $e) {
    fwrite(STDERR, "Gagal membuat Server: " . $e->getMessage() . "\n");
    exit(1);
}
PHP
else
  echo "PERINGATAN: Wings tidak aktif, pembuatan server dilewati."
fi

echo "=== SELESAI ==="
echo "Location ID : $LOC_ID ($LOC_SHORT)"
echo "Node ID     : $NODE_ID ($NODE_NAME - $NODE_FQDN)"
echo "Allocation  : 0.0.0.0 | Alias: KruzzyNotDev | Ports: 2000-2300"
echo "Nest        : $NEST_NAME"
echo "Server      : $SERVER_NAME (egg: $SERVER_EGG, owner: $SERVER_OWNER)"
echo "Wings Status: $WINGS_STATUS"

if [[ "$WINGS_STATUS" != "active" ]]; then
  echo "PERINGATAN: Wings belum aktif. Log terakhir:"
  journalctl -u wings -n 15 --no-pager 2>/dev/null || true
fi
