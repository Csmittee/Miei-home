#!/usr/bin/env python3
"""
MIEI HOME — Diagnostics API
Runs on Pi port 8081. Serves health data to:
  - Local dashboard (customer view, always on)
  - Developer admin panel (on-demand, only when customer taps 'send report')

Privacy rule: no video, no personal data, no automatic reporting.
"""
import os, json, time, subprocess, shutil, configparser
from flask import Flask, jsonify, request
import paho.mqtt.client as mqtt
import threading

app = Flask(__name__)

config = configparser.ConfigParser()
config.read('/etc/mieihome/mqtt.conf')
MQTT_HOST = config.get('DEFAULT', 'MQTT_HOST', fallback='localhost')
MQTT_USER = config.get('DEFAULT', 'MQTT_USER', fallback='mieihome')
MQTT_PASS = config.get('DEFAULT', 'MQTT_PASS', fallback='')

# In-memory device registry — populated by MQTT availability messages
device_registry = {}
registry_lock = threading.Lock()

# ── MQTT listener (tracks online/offline state of all devices) ──────────────

def on_connect(client, userdata, flags, rc):
    client.subscribe("mieihome/+/+/availability")
    client.subscribe("mieihome/system/heartbeat")

def on_message(client, userdata, msg):
    parts = msg.topic.split("/")
    if len(parts) == 4 and parts[3] == "availability":
        device_id = parts[2]
        state = msg.payload.decode()
        with registry_lock:
            if device_id not in device_registry:
                device_registry[device_id] = {}
            device_registry[device_id]["state"] = state
            device_registry[device_id]["last_seen"] = time.time()

mqtt_client = mqtt.Client()
mqtt_client.username_pw_set(MQTT_USER, MQTT_PASS)
mqtt_client.on_connect = on_connect
mqtt_client.on_message = on_message
mqtt_client.connect(MQTT_HOST, 1883, 60)
threading.Thread(target=mqtt_client.loop_forever, daemon=True).start()

# ── Helper functions ─────────────────────────────────────────────────────────

def get_cpu_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read()) / 1000, 1)
    except:
        return None

def get_disk_usage():
    total, used, free = shutil.disk_usage("/mnt/data")
    return {
        "total_gb": round(total / 1e9, 1),
        "used_gb":  round(used  / 1e9, 1),
        "free_gb":  round(free  / 1e9, 1),
        "percent":  round(used / total * 100, 1)
    }

def get_cpu_usage():
    try:
        result = subprocess.run(
            ["top", "-bn1"], capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            if "Cpu(s)" in line:
                idle = float(line.split("id,")[0].split(",")[-1].strip())
                return round(100 - idle, 1)
    except:
        return None

def get_memory_usage():
    try:
        result = subprocess.run(["free", "-m"], capture_output=True, text=True)
        lines = result.stdout.splitlines()
        parts = lines[1].split()
        total, used = int(parts[1]), int(parts[2])
        return {
            "total_mb": total,
            "used_mb": used,
            "percent": round(used / total * 100, 1)
        }
    except:
        return None

def get_uptime():
    try:
        with open("/proc/uptime") as f:
            seconds = float(f.read().split()[0])
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        return f"{hours}h {minutes}m"
    except:
        return None

def get_version():
    try:
        with open("/etc/mieihome/version.json") as f:
            return json.load(f)
    except:
        return {"version": "unknown"}

def get_services_status():
    services = ["mosquitto", "nginx", "mieihome-whisper", "mieihome-ota", "docker"]
    status = {}
    for svc in services:
        result = subprocess.run(
            ["systemctl", "is-active", svc],
            capture_output=True, text=True
        )
        status[svc] = result.stdout.strip()
    return status

def get_mqtt_devices():
    with registry_lock:
        now = time.time()
        devices = []
        for device_id, info in device_registry.items():
            devices.append({
                "id": device_id,
                "state": info.get("state", "unknown"),
                "last_seen_seconds_ago": round(now - info.get("last_seen", 0))
            })
        return devices

# ── API Routes ────────────────────────────────────────────────────────────────

@app.route("/api/health")
def health():
    """Full health snapshot — used by customer dashboard."""
    return jsonify({
        "timestamp": time.time(),
        "uptime": get_uptime(),
        "cpu_temp_c": get_cpu_temp(),
        "cpu_percent": get_cpu_usage(),
        "memory": get_memory_usage(),
        "disk": get_disk_usage(),
        "services": get_services_status(),
        "devices": get_mqtt_devices(),
        "version": get_version()
    })

@app.route("/api/devices")
def devices():
    """Device list with online/offline state."""
    return jsonify({"devices": get_mqtt_devices()})

@app.route("/api/system")
def system():
    """System metrics only — lightweight, polled every 30s by dashboard."""
    return jsonify({
        "cpu_temp_c": get_cpu_temp(),
        "cpu_percent": get_cpu_usage(),
        "memory": get_memory_usage(),
        "disk": get_disk_usage(),
        "uptime": get_uptime()
    })

@app.route("/api/report", methods=["POST"])
def send_report():
    """
    Customer taps 'Send diagnostic report to developer'.
    Packages a health snapshot and posts it to the developer admin server.
    NO video. NO camera feeds. NO personal data.
    """
    ADMIN_SERVER = os.environ.get("mieihome_ADMIN_URL", "https://admin.mieihome.io")
    version_info = get_version()
    pi_serial = version_info.get("pi_serial", "unknown")

    report = {
        "pi_serial_hash": __import__("hashlib").sha256(
            pi_serial.encode()
        ).hexdigest()[:12],   # hashed — never send raw serial
        "timestamp": time.time(),
        "version": version_info.get("version"),
        "cpu_temp_c": get_cpu_temp(),
        "cpu_percent": get_cpu_usage(),
        "memory": get_memory_usage(),
        "disk": get_disk_usage(),
        "services": get_services_status(),
        "device_count": len(device_registry),
        "offline_devices": sum(
            1 for d in device_registry.values() if d.get("state") != "online"
        )
        # No device IDs, no camera info, no personal data
    }

    try:
        import requests
        r = requests.post(
            f"{ADMIN_SERVER}/api/ingest",
            json=report,
            timeout=15
        )
        if r.status_code == 200:
            return jsonify({"sent": True, "message": "Report sent successfully."})
        return jsonify({"sent": False, "message": "Server error."}), 502
    except Exception as e:
        return jsonify({"sent": False, "message": str(e)}), 503

@app.route("/api/ping")
def ping():
    return jsonify({"ok": True, "timestamp": time.time()})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081)
