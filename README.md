# MIEI HOME

**Privacy-first smart home. Works 100% offline. No cloud. No subscriptions. One-time setup.**

Your home, your data, your rules.

---

## What this is

MIEI HOME is a complete smart home system built on open hardware and open software.
It runs entirely on a Raspberry Pi 5 in your home — no data ever leaves unless you ask it to.

| Feature | MIEI HOME | Alexa / Google | Sonoff Cloud |
|---|---|---|---|
| Works without internet | ✅ Always | ❌ No | ❌ No |
| Monthly subscription | ✅ None | ❌ Yes | ❌ Yes |
| Voice processed locally | ✅ On-device | ❌ Cloud | ❌ Cloud |
| Camera stored locally | ✅ 7-day SSD | ❌ Cloud | ❌ Cloud |
| You own your data | ✅ Yes | ❌ No | ❌ No |

---

## Hardware required

### Hub (one per home)
| Part | Spec | Why |
|---|---|---|
| Raspberry Pi 5 | 8GB RAM | Whisper STT + Frigate NVR simultaneously |
| NVMe SSD | 512GB M.2 | 7-day camera recording (~320GB for 4 cameras) |
| Pi 5 M.2 HAT+ | Official RPi | PCIe 3.0 — NVMe speed required |
| Pi 5 Active Cooler | Official RPi | Keeps CPU under 70°C under full load |
| USB-C PSU | 5V/5A (27W) | Pi 5 requires 27W minimum |
| MicroSD | 32GB A2-rated | OS boot only — not for video |

### Voice node (one per room)
| Part | Spec | Why |
|---|---|---|
| ESP32-S3 | N16R8 (16MB flash + 8MB PSRAM) | Wake word + audio buffer |
| INMP441 mic | I2S breakout | Digital mic — no ADC noise |
| MAX98357A amp | I2S 3W mono | Feedback audio |
| Speaker | 4Ω 40mm | Audio response |
| WS2812B LEDs | ×4 | Status ring |

### Customer-side (already in most homes)
- Sonoff smart switches (any model — reflashed with ESPHome)
- RTSP IP cameras (Reolink, Tapo, Hikvision, etc.)

---

## Software stack

| Component | Purpose | Runs on |
|---|---|---|
| Mosquitto | MQTT broker — all device communication | Pi |
| Frigate NVR | Camera recording + motion detection | Pi (Docker) |
| Whisper (small) | Local speech-to-text, no cloud | Pi CPU |
| ESPHome | Firmware for all ESP32/Sonoff devices | ESP32 nodes |
| Tailscale | Optional remote access VPN | Pi |
| Custom dashboard | Web UI — works in any browser on LAN | Pi (Nginx) |

---

## Repository structure

```
mieihome/
│
├── firmware/
│   ├── pi/
│   │   ├── first_boot.sh              # Runs once on customer Pi — installs everything
│   │   ├── mieihome-firstboot.service  # Systemd unit that triggers first_boot.sh
│   │   ├── diagnostics_api.py         # Health API for dashboard + developer admin
│   │   ├── whisper_service.py         # MQTT bridge for Whisper STT
│   │   └── ota_server.py             # Local firmware server for ESP32 OTA
│   │
│   └── esp32/
│       ├── sonoff_switch.yaml         # Sonoff switch/relay (Basic, Mini, S31)
│       ├── voice_node.yaml            # ESP32-S3 voice satellite node
│       ├── sensor_pack.yaml           # Motion, water leak, soil moisture
│       └── secrets.yaml.template     # Copy → secrets.yaml, fill in your values
│
├── dashboard/
│   ├── index.html                     # Main customer dashboard (served by Nginx)
│   ├── setup/
│   │   └── index.html                 # Setup wizard (WiFi → device discovery → done)
│   ├── js/
│   │   ├── mqtt.js                    # MQTT WebSocket client
│   │   ├── devices.js                 # Device state management
│   │   └── dashboard.js               # UI logic
│   └── css/
│       └── main.css                   # Styles
│
├── admin/
│   ├── server.py                      # Developer admin panel (your VPS)
│   ├── ingest.py                      # Receives diagnostic reports from Pi
│   └── templates/
│       └── admin.html                 # Admin UIM
│
├── update-server/
│   ├── server.py                      # HTTPS endpoint customers ping for updates
│   ├── version.json                   # Current release manifest
│   └── releases/                      # Compiled firmware binaries
│       ├── pi/
│       └── esp32/
│
├── simulator/
│   └── index.html                     # Browser simulator — demo without hardware
│
├── docs/
│   ├── wiring/
│   │   ├── voice_node_pinout.svg      # ESP32-S3 wiring diagram
│   │   └── sensor_wiring.svg          # Sensor connection diagrams
│   ├── setup_guide.md                 # Customer-facing setup instructions
│   ├── sonoff_flash_guide.md          # How to free Sonoff from cloud
│   └── camera_rtsp_urls.md            # RTSP URL formats for major camera brands
│
├── .github/
│   └── workflows/
│       ├── build_esp32.yml            # Compile ESPHome YAMLs → .bin files
│       └── release.yml                # Tag → upload to update server
│
├── .gitignore
├── docker-compose.yml                 # Pi services (Frigate)
└── README.md
```

---

## How deployment works

### First time (you → Pi SD card)

```bash
# 1. Flash Pi OS Lite 64-bit to SD card
# 2. Copy first_boot.sh to the image
sudo cp firmware/pi/first_boot.sh /mnt/boot/first_boot.sh
sudo cp firmware/pi/mieihome-firstboot.service \
    /mnt/boot/mieihome-firstboot.service

# 3. Enable the service in the image
# (done via systemctl enable in your image build script)

# 4. Flash SD card, insert into Pi, power on
# Pi runs first_boot.sh automatically — takes ~10 minutes
# QR code appears on screen when ready
```

### Updates (you → Pi, Pi → everything else)

```
You push to GitHub
    → GitHub Action builds ESP32 firmware binaries
    → Uploads to update-server/releases/
    → Publishes new version.json

Customer taps "Check for updates" in dashboard
    → Pi fetches version.json from your update server
    → Pi downloads new firmware package
    → Pi notifies all ESP32 nodes via MQTT
    → Each node downloads and flashes itself
    → All devices updated, no physical access needed
```

### Adding a new Sonoff device

```bash
# 1. Put Sonoff into DIY mode (hold button 5s — LED flashes fast)
# 2. Edit sonoff_switch.yaml — change device_id and device_name
# 3. Flash from your laptop:
esphome run firmware/esp32/sonoff_switch.yaml
# ESPHome finds the device on LAN and flashes it
# Device appears in dashboard automatically
```

---

## MQTT topic schema

All devices communicate via Mosquitto on the Pi. Full topic map:

```
mieihome/devices/{device_id}/command       →  Pi → device: ON / OFF / TOGGLE
mieihome/devices/{device_id}/status        ←  device → Pi: ON / OFF
mieihome/devices/{device_id}/config        ←  device announces itself on boot
mieihome/devices/{device_id}/availability  ←  online / offline (Last Will)

mieihome/voice/{node_id}/wake              ←  wake word detected
mieihome/voice/{node_id}/stt_result        ←  transcribed text from Whisper
mieihome/voice/{node_id}/tts_play         →  Pi → node: speak this text

mieihome/camera/{cam_id}/motion            ←  Frigate motion event
mieihome/camera/{cam_id}/detection        ←  person / car / object JSON
mieihome/camera/{cam_id}/snapshot          ←  JPEG on event

mieihome/sensor/{sensor_id}/state          ←  ON / OFF (motion, leak)
mieihome/sensor/{sensor_id}/value          ←  numeric (soil moisture %)
mieihome/sensor/{sensor_id}/alert          ←  threshold breach (leak, dry soil)

mieihome/system/heartbeat                  ←  Pi publishes every 60s
mieihome/system/ota/{device_id}           →  firmware update signal
mieihome/system/log                        ←  all devices log errors here
```

---

## Diagnostics

**Customer view** — available at `http://mieihome.local/api/health`
- Device online/offline status
- CPU temperature, disk usage, memory
- 7-day event log
- No internet required

**Developer view** — your admin panel, Tailscale-gated
- Customer taps "Send diagnostic report" → Pi sends anonymised health snapshot
- No video, no camera feeds, no personal data ever sent
- Pi serial is hashed before transmission

---

## Privacy promise

- No telemetry. The Pi never calls home unless the customer explicitly requests an update or sends a diagnostic report.
- No video leaves the home. Ever. Camera footage stays on the local SSD.
- No accounts. No login. No cloud.
- No forced updates. The system runs the firmware it shipped with until the customer chooses to update.
- Open source base. ESPHome, Frigate, Mosquitto, Whisper — all auditable.

---

## Development setup

```bash
# Clone the repo
git clone https://github.com/yourname/mieihome.git
cd mieihome

# Set up ESPHome for flashing ESP32 devices
pip install esphome

# Copy secrets template and fill in your values
cp firmware/esp32/secrets.yaml.template firmware/esp32/secrets.yaml
# Edit secrets.yaml with your WiFi, MQTT credentials

# Flash a Sonoff switch
esphome run firmware/esp32/sonoff_switch.yaml

# Flash a voice node
esphome run firmware/esp32/voice_node.yaml

# Run the browser simulator (no hardware needed)
open simulator/index.html
```

---

## Roadmap

- [x] MQTT schema
- [x] Pi first-boot script
- [x] Sonoff switch ESPHome YAML
- [x] Voice node ESPHome YAML
- [x] Sensor pack YAML
- [x] Diagnostics API
- [x] OTA update server
- [ ] Setup wizard UI (seed 3)
- [ ] Customer dashboard UI (seed 3)
- [ ] Browser simulator (seed 1)
- [ ] Admin panel (seed 5)
- [ ] Frigate camera integration (seed 1)
- [ ] Home Assistant automations (seed 1)

---

## License

Hardware designs: CERN-OHL-P v2  
Software: MIT  
ESPHome configs: MIT

---

*MIEI HOME — built for people who want their home to work for them, not the other way around.*
