<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Akses node.sh</title>
  <style>
    * { box-sizing: border-box; font-family: system-ui, -apple-system, sans-serif; -webkit-tap-highlight-color: transparent; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #0b0f17;
      color: #f1f5f9;
      padding: 20px;
    }
    .card {
      width: 100%;
      max-width: 360px;
      background: #131a26;
      border: 1px solid #243044;
      border-radius: 16px;
      padding: 24px;
    }
    .title {
      font-size: 1rem;
      font-weight: 700;
      margin-bottom: 14px;
      line-height: 1.4;
    }
    input {
      width: 100%;
      padding: 12px 14px;
      border-radius: 10px;
      border: 1px solid #334155;
      background: #0b0f17;
      color: #ffffff;
      font-size: 1rem;
      letter-spacing: 3px;
      text-align: center;
      outline: none;
      margin-bottom: 12px;
    }
    input:focus {
      border-color: #38bdf8;
    }
    button {
      width: 100%;
      padding: 12px;
      border: 0;
      border-radius: 10px;
      background: #2563eb;
      color: #ffffff;
      font-size: 0.95rem;
      font-weight: 600;
      cursor: pointer;
    }
    .msg {
      margin-top: 12px;
      font-size: 0.85rem;
      min-height: 20px;
      text-align: center;
      color: #f87171;
    }
    .msg.ok {
      color: #4ade80;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="title">Masukkan pin untuk mengunduh file node.sh</div>
    <form id="pinForm">
      <input
        type="password"
        id="pinInput"
        inputmode="numeric"
        autocomplete="off"
        placeholder="PIN"
        required
      />
      <button type="submit">Unduh</button>
    </form>
    <div class="msg" id="msg"></div>
  </div>

  <script>
    const PIN_BENAR = "202611"; // Ganti PIN sesuai mau lu

    // Isi skrip node.sh ditaruh langsung di sini (atau ambil dari raw URL setelah PIN benar)
    const NODE_SH_CONTENT = `#!/usr/bin/env bash
set -euo pipefail

PANEL_DIR="/var/www/pterodactyl"
WINGS_CONFIG="/etc/pterodactyl/config.yml"
ART="php -d display_errors=0 $PANEL_DIR/artisan"

NEST_NAME="\${NEST_NAME:-Kruzzy}"
NEST_DESC="\${NEST_DESC:-Support @KruzzyX Terus Bang🙏}"
EGG_URLS=(
  "https://raw.githubusercontent.com/Nevest7251/kruzzyx/main/node.json"
)

echo "=== AUTO CREATE LOCATION, NODE, ALLOCATION, NEST/EGG, SERVER & WINGS CONFIG ==="

fail() { echo "ERROR: $*" >&2; exit 1; }
clean() { printf '%s' "\${1//[$'\\r\\n']/}"; }

LOC_SHORT="" LOC_DESC="" NODE_FQDN="" NODE_NAME="" NODE_RAM="" NODE_DISK="" ALLOC_COUNT=""
read -r -p "Masukkan Location Short Code (contoh: SGP): " LOC_SHORT || true
read -r -p "Masukkan Location Description: " LOC_DESC || true
read -r -p "Masukkan FQDN / Domain Node: " NODE_FQDN || true
read -r -p "Masukkan Nama Node (contoh: NODES): " NODE_NAME || true
read -r -p "Masukkan Memory / RAM (MB): " NODE_RAM || true
read -r -p "Masukkan Disk Space (MB): " NODE_DISK || true
read -r -p "Masukkan jumlah Allocation port (contoh: 1): " ALLOC_COUNT || true

LOC_SHORT="\$(clean "\$LOC_SHORT")"
LOC_DESC="\$(clean "\$LOC_DESC")"
NODE_FQDN="\$(clean "\$NODE_FQDN")"
NODE_NAME="\$(clean "\$NODE_NAME")"
NODE_RAM="\$(clean "\$NODE_RAM")"
NODE_DISK="\$(clean "\$NODE_DISK")"

LOC_SHORT="\${LOC_SHORT:-SGP}"
LOC_DESC="\${LOC_DESC:-Jangan Lupa Support @KruzzyNotDev}"
NODE_NAME="\${NODE_NAME:-NODES}"
[[ "\$NODE_RAM" =~ ^[0-9]+$ ]] || NODE_RAM=4000
[[ "\$NODE_DISK" =~ ^[0-9]+$ ]] || NODE_DISK=4000

[[ -n "\$NODE_FQDN" ]] || fail "FQDN / Domain Node wajib diisi."
[[ -f "\$PANEL_DIR/artisan" ]] || fail "Panel tidak ditemukan di \$PANEL_DIR."
command -v php >/dev/null 2>&1 || fail "PHP tidak ditemukan."
`;

    const form = document.getElementById("pinForm");
    const msg = document.getElementById("msg");

    form.addEventListener("submit", (e) => {
      e.preventDefault();
      const pin = document.getElementById("pinInput").value.trim();

      if (pin !== PIN_BENAR) {
        msg.className = "msg";
        msg.textContent = "PIN salah!";
        return;
      }

      const blob = new Blob([NODE_SH_CONTENT], { type: "text/x-sh;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "node.sh";
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);

      msg.className = "msg ok";
      msg.textContent = "PIN benar! Mengunduh node.sh...";
    });
  </script>
</body>
</html>
