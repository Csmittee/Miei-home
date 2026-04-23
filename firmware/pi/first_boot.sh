#!/bin/bash
# =============================================================================
# MIEI HOME — First Boot Setup Script
# Runs ONCE on first power-on. Never runs again after completion.
# Target: Raspberry Pi 5 (8GB), Pi OS Lite 64-bit
# =============================================================================

set -euo pipefail

LOG="/var/log/mieihome_firstboot.log"
DONE_FLAG="/etc/mieihome/.firstboot_complete"
mieihome_DIR="/opt/mieihome"
DASHBOARD_DIR="/opt/mieihome/dashboard"
CONFIG_DIR="/etc/mieihome"
DATA_DIR="/mnt/data"          # NVMe SSD mount point
MQTT_USER="mieihome"
MQTT_PASS="$(openssl rand -hex 16)"
VERSION="1.0.0"

# ── guard: only run once ────────────────────────────────────────────────────
if [ -f "$DONE_FLAG" ]; then
    echo "First boot already completed. Exiting."
    exit 0
fi

exec > >(tee -a "$LOG") 2>&1
echo "========================================================"
echo " MIEI HOME first boot — $(date)"
echo " Version: $VERSION"
echo "========================================================"

# =============================================================================
# STEP 1 — System preparation
# =============================================================================
echo "[1/9] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git python3 python3-pip python3-venv \
    mosquitto mosquitto-clients \
    nginx \
    avahi-daemon \
    jq \
    qrencode \
    openssl \
    net-tools \
    htop \
    smartmontools

echo "[1/9] Done."

# =============================================================================
# STEP 2 — Mount NVMe SSD
# =============================================================================
echo "[2/9] Setting up NVMe SSD..."

NVME_DEV=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && $1 ~ /nvme/ {print "/dev/"$1}' | head -1)

if [ -z "$NVME_DEV" ]; then
    echo "WARNING: No NVMe device found. Using SD card fallback (not recommended for production)."
    DATA_DIR="/home/mieihome/data"
    mkdir -p "$DATA_DIR"
else
    echo "Found NVMe: $NVME_DEV"
    # Format only if no filesystem present
    if ! blkid "$NVME_DEV" | grep -q ext4; then
        echo "Formatting $NVME_DEV as ext4..."
        mkfs.ext4 -q -L mieihome-data "$NVME_DEV"
    fi
    mkdir -p "$DATA_DIR"
    # Add to fstab if not already there
    if ! grep -q "$NVME_DEV" /etc/fstab; then
        echo "$NVME_DEV  $DATA_DIR  ext4  defaults,noatime  0  2" >> /etc/fstab
    fi
    mount "$DATA_DIR" 2>/dev/null || mount -a
    echo "NVMe mounted at $DATA_DIR"
fi

mkdir -p \
    "$DATA_DIR/frigate/recordings" \
    "$DATA_DIR/frigate/clips" \
    "$DATA_DIR/logs" \
    "$DATA_DIR/firmware"

echo "[2/9] Done."

# =============================================================================
# STEP 3 — Create system user and directories
# =============================================================================
echo "[3/9] Creating mieihome user and directories..."

if ! id "mieihome" &>/dev/null; then
    useradd -r -s /bin/false -d "$mieihome_DIR" mieihome
fi

mkdir -p "$mieihome_DIR" "$CONFIG_DIR" "$DASHBOARD_DIR"
chown -R mieihome:mieihome "$mieihome_DIR" "$DATA_DIR"

echo "[3/9] Done."

# =============================================================================
# STEP 4 — Configure Mosquitto MQTT broker
# =============================================================================
echo "[4/9] Configuring Mosquitto MQTT broker..."

# Create MQTT credentials
mosquitto_passwd -c -b /etc/mosquitto/passwd "$MQTT_USER" "$MQTT_PASS"

cat > /etc/mosquitto/conf.d/mieihome.conf << EOF
listener 1883
allow_anonymous false
password_file /etc/mosquitto/passwd

# Persistence
persistence true
persistence_location /var/lib/mosquitto/

# Logging
log_dest file /var/log/mosquitto/mosquitto.log
log_type error
log_type warning
log_type information

# Keep-alive for ESP32 nodes
keepalive_interval 60
max_keepalive 120

# Retained messages for device state
retain_available true
EOF

systemctl enable mosquitto
systemctl restart mosquitto

# Save credentials to config
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/mqtt.conf" << EOF
MQTT_HOST=localhost
MQTT_PORT=1883
MQTT_USER=$MQTT_USER
MQTT_PASS=$MQTT_PASS
EOF
chmod 600 "$CONFIG_DIR/mqtt.conf"

echo "[4/9] Done."

# =============================================================================
# STEP 5 — Install and configure Frigate NVR
# =============================================================================
echo "[5/9] Installing Frigate NVR..."

# Install Docker (Frigate runs in Docker for dependency isolation)
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker mieihome
fi

# Frigate config
mkdir -p "$CONFIG_DIR/frigate"
cat > "$CONFIG_DIR/frigate/config.yml" << EOF
mqtt:
  host: 127.0.0.1
  port: 1883
  user: $MQTT_USER
  password: $MQTT_PASS
  topic_prefix: mieihome/camera

database:
  path: $DATA_DIR/frigate/frigate.db

record:
  enabled: true
  retain:
    days: 7
    mode: all
  events:
    retain:
      default: 14
      mode: motion

snapshots:
  enabled: true
  retain:
    default: 7

detect:
  width: 1280
  height: 720
  fps: 5

detectors:
  cpu1:
    type: cpu
    num_threads: 3

objects:
  track:
    - person
    - car

# Cameras are added dynamically by setup wizard
cameras: {}
EOF

# Docker compose for Frigate
cat > "$mieihome_DIR/docker-compose.yml" << EOF
version: "3.9"
services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    restart: unless-stopped
    privileged: true
    shm_size: "128mb"
    volumes:
      - $CONFIG_DIR/frigate/config.yml:/config/config.yml
      - $DATA_DIR/frigate:/media/frigate
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "5000:5000"   # Frigate web UI
      - "8554:8554"   # RTSP streams
    environment:
      FRIGATE_RTSP_PASSWORD: ""
EOF

cd "$mieihome_DIR" && docker compose up -d frigate
echo "[5/9] Done."

# =============================================================================
# STEP 6 — Install Whisper STT (local speech-to-text)
# =============================================================================
echo "[6/9] Installing Whisper STT..."

python3 -m venv "$mieihome_DIR/venv"
source "$mieihome_DIR/venv/bin/activate"

pip install -q \
    openai-whisper \
    paho-mqtt \
    flask \
    gunicorn

# Download small model (39MB — good accuracy, runs on Pi 5 CPU)
python3 -c "import whisper; whisper.load_model('small')"

deactivate

# Whisper MQTT bridge service
cat > "$mieihome_DIR/whisper_service.py" << 'PYEOF'
#!/usr/bin/env python3
"""
MIEI HOME — Whisper STT MQTT Bridge
Listens for audio data on mieihome/voice/+/audio_stream
Transcribes and publishes result to mieihome/voice/{node_id}/stt_result
"""
import json, io, time, threading, configparser
import paho.mqtt.client as mqtt
import whisper
import numpy as np

config = configparser.ConfigParser()
config.read('/etc/mieihome/mqtt.conf')

MQTT_HOST = config.get('DEFAULT', 'MQTT_HOST', fallback='localhost')
MQTT_PORT = int(config.get('DEFAULT', 'MQTT_PORT', fallback='1883'))
MQTT_USER = config.get('DEFAULT', 'MQTT_USER', fallback='mieihome')
MQTT_PASS = config.get('DEFAULT', 'MQTT_PASS', fallback='')

print("Loading Whisper model...")
model = whisper.load_model("small")
print("Whisper ready.")

def on_connect(client, userdata, flags, rc):
    print(f"MQTT connected (rc={rc})")
    client.subscribe("mieihome/voice/+/audio_stream")

def on_message(client, userdata, msg):
    topic_parts = msg.topic.split("/")
    node_id = topic_parts[2]
    try:
        audio_data = np.frombuffer(msg.payload, dtype=np.float32)
        result = model.transcribe(audio_data, language="en", fp16=False)
        text = result["text"].strip()
        if text:
            client.publish(
                f"mieihome/voice/{node_id}/stt_result",
                json.dumps({"text": text, "timestamp": time.time()})
            )
            print(f"[{node_id}] STT: {text}")
    except Exception as e:
        print(f"STT error for {node_id}: {e}")

client = mqtt.Client()
client.username_pw_set(MQTT_USER, MQTT_PASS)
client.on_connect = on_connect
client.on_message = on_message
client.connect(MQTT_HOST, MQTT_PORT, 60)
client.loop_forever()
PYEOF

chmod +x "$mieihome_DIR/whisper_service.py"

# Systemd service for Whisper
cat > /etc/systemd/system/mieihome-whisper.service << EOF
[Unit]
Description=MIEI HOME Whisper STT Service
After=network.target mosquitto.service
Requires=mosquitto.service

[Service]
Type=simple
User=mieihome
WorkingDirectory=$mieihome_DIR
ExecStart=$mieihome_DIR/venv/bin/python3 $mieihome_DIR/whisper_service.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable mieihome-whisper
echo "[6/9] Done."

# =============================================================================
# STEP 7 — Install OTA update server (serves firmware to ESP32 nodes)
# =============================================================================
echo "[7/9] Setting up local OTA firmware server..."

cat > "$mieihome_DIR/ota_server.py" << 'PYEOF'
#!/usr/bin/env python3
"""
MIEI HOME — Local OTA Firmware Server
Serves firmware files to ESP32 nodes over HTTP on port 8080
Also handles check-for-updates requests from Pi to external update server
"""
import os, json, hashlib, time, threading, requests
from flask import Flask, send_file, jsonify, abort
import paho.mqtt.client as mqtt
import configparser

config = configparser.ConfigParser()
config.read('/etc/mieihome/mqtt.conf')

FIRMWARE_DIR = "/mnt/data/firmware"
UPDATE_SERVER = "https://updates.mieihome.io"   # your VPS
CURRENT_VERSION_FILE = "/etc/mieihome/version.json"

app = Flask(__name__)

@app.route("/firmware/<device_type>/<filename>")
def serve_firmware(device_type, filename):
    path = os.path.join(FIRMWARE_DIR, device_type, filename)
    if not os.path.exists(path):
        abort(404)
    return send_file(path, mimetype="application/octet-stream")

@app.route("/version")
def version_info():
    if os.path.exists(CURRENT_VERSION_FILE):
        with open(CURRENT_VERSION_FILE) as f:
            return jsonify(json.load(f))
    return jsonify({"version": "1.0.0"})

@app.route("/check-update")
def check_update():
    """Called by customer tapping 'Check for updates' in dashboard"""
    try:
        r = requests.get(f"{UPDATE_SERVER}/version.json", timeout=10)
        remote = r.json()
        with open(CURRENT_VERSION_FILE) as f:
            local = json.load(f)
        if remote["version"] != local["version"]:
            return jsonify({"update_available": True, "version": remote["version"]})
        return jsonify({"update_available": False})
    except Exception as e:
        return jsonify({"error": str(e)}), 503

if __name__ == "__main__":
    os.makedirs(FIRMWARE_DIR, exist_ok=True)
    app.run(host="0.0.0.0", port=8080)
PYEOF

cat > /etc/systemd/system/mieihome-ota.service << EOF
[Unit]
Description=MIEI HOME OTA Firmware Server
After=network.target

[Service]
Type=simple
User=mieihome
ExecStart=$mieihome_DIR/venv/bin/python3 $mieihome_DIR/ota_server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl enable mieihome-ota
echo "[7/9] Done."

# =============================================================================
# STEP 8 — Configure Nginx (reverse proxy for dashboard + Frigate)
# =============================================================================
echo "[8/9] Configuring Nginx..."

cat > /etc/nginx/sites-available/mieihome << 'EOF'
server {
    listen 80 default_server;
    server_name mieihome.local _;

    # Dashboard (setup wizard + main UI)
    location / {
        root /opt/mieihome/dashboard;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    # Frigate NVR proxy
    location /cameras/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }

    # OTA server proxy
    location /ota/ {
        proxy_pass http://127.0.0.1:8080/;
    }

    # Diagnostics API
    location /api/ {
        proxy_pass http://127.0.0.1:8081/;
    }
}
EOF

ln -sf /etc/nginx/sites-available/mieihome /etc/nginx/sites-enabled/mieihome
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable nginx && systemctl restart nginx

echo "[8/9] Done."

# =============================================================================
# STEP 9 — Write version file, generate QR code, mark complete
# =============================================================================
echo "[9/9] Finalising setup..."

# Write version info
cat > "$CONFIG_DIR/version.json" << EOF
{
  "version": "$VERSION",
  "install_date": "$(date -Iseconds)",
  "pi_serial": "$(cat /proc/cpuinfo | grep Serial | awk '{print $3}')"
}
EOF

# Get local IP for QR code
LOCAL_IP=$(hostname -I | awk '{print $1}')

# Write the setup wizard HTML placeholder (replaced by full dashboard build)
mkdir -p "$DASHBOARD_DIR"
cat > "$DASHBOARD_DIR/index.html" << HTMLEOF
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MIEI HOME Setup</title>
<style>
  body { font-family: sans-serif; background: #f5f5f5; display: flex;
         align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
  .card { background: white; border-radius: 16px; padding: 40px;
          text-align: center; max-width: 400px; }
  h1 { font-size: 1.5rem; margin-bottom: 8px; }
  p  { color: #666; margin-bottom: 24px; }
  .btn { background: #1D9E75; color: white; border: none; border-radius: 10px;
         padding: 14px 32px; font-size: 1rem; cursor: pointer; }
</style>
</head><body>
<div class="card">
  <h1>MIEI HOME</h1>
  <p>Hub is ready. Tap below to begin setup.</p>
  <button class="btn" onclick="location.href='/setup'">Start Setup</button>
  <p style="margin-top:24px;font-size:0.85rem;color:#999">
    Or visit <strong>http://$LOCAL_IP</strong> from any device on your network.
  </p>
</div>
</body></html>
HTMLEOF

# Print QR code to console (visible on HDMI monitor during setup)
echo ""
echo "================================================================"
echo " MIEI HOME is ready!"
echo " Open this address on any phone or browser:"
echo " http://$LOCAL_IP"
echo ""
qrencode -t UTF8 "http://$LOCAL_IP"
echo "================================================================"

# Mark first boot complete — this file prevents re-running
mkdir -p "$(dirname $DONE_FLAG)"
echo "$VERSION $(date -Iseconds)" > "$DONE_FLAG"

# Start all services
systemctl start mieihome-whisper mieihome-ota

echo ""
echo "First boot complete. Log saved to $LOG"
echo "Rebooting in 5 seconds to apply all changes..."
sleep 5
reboot
