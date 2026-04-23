-- =============================================================================
-- MIEI HOME — Cloudflare D1 Schema
-- Run once to initialise the database:
--   wrangler d1 execute miehome-db --file=schema.sql
-- =============================================================================

-- Firmware releases
-- One row per version published. Pi reads the latest row.
CREATE TABLE IF NOT EXISTS releases (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  version     TEXT    NOT NULL,                 -- "1.0.1"
  changelog   TEXT    DEFAULT '',               -- Human-readable notes
  components  TEXT    NOT NULL,                 -- JSON: per-component versions + URLs
  created_at  TEXT    NOT NULL                  -- ISO timestamp
);

-- Diagnostic reports from customer Pis
-- No personal data. Pi serial is hashed before sending.
CREATE TABLE IF NOT EXISTS diagnostic_reports (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  pi_hash         TEXT,           -- First 12 chars of SHA256(serial) — not reversible
  version         TEXT,           -- Firmware version running on Pi
  cpu_temp        REAL,           -- Celsius
  cpu_pct         REAL,           -- Percent 0-100
  mem_pct         REAL,           -- Percent 0-100
  disk_pct        REAL,           -- Percent 0-100
  disk_free_gb    REAL,           -- GB remaining on SSD
  device_count    INTEGER,        -- How many MQTT devices registered
  offline_devices INTEGER,        -- How many were offline at report time
  services        TEXT,           -- JSON: { mosquitto: "active", frigate: "active", ... }
  country         TEXT,           -- Cloudflare CF-country header (2-letter code)
  ts              INTEGER         -- Unix timestamp
);

-- Firmware download log (anonymised — no IP, just key + count for analytics)
CREATE TABLE IF NOT EXISTS download_log (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,
  r2_key  TEXT    NOT NULL,   -- e.g. "esp32/sonoff_switch-1.0.1.bin"
  ts      INTEGER NOT NULL    -- Unix timestamp
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_reports_pi_hash  ON diagnostic_reports(pi_hash);
CREATE INDEX IF NOT EXISTS idx_reports_ts       ON diagnostic_reports(ts);
CREATE INDEX IF NOT EXISTS idx_releases_created ON releases(created_at);
CREATE INDEX IF NOT EXISTS idx_downloads_key    ON download_log(r2_key);

-- Seed: initial version record
-- Update this after your first real build
INSERT INTO releases (version, changelog, components, created_at)
VALUES (
  '1.0.0',
  'Initial release',
  '{
    "pi":           { "version": "1.0.0", "url": "/firmware/pi/miehome-pi-1.0.0.tar.gz" },
    "esp32_switch": { "version": "1.0.0", "url": "/firmware/esp32/sonoff_switch-1.0.0.bin" },
    "esp32_voice":  { "version": "1.0.0", "url": "/firmware/esp32/voice_node-1.0.0.bin" },
    "esp32_sensor": { "version": "1.0.0", "url": "/firmware/esp32/sensor_pack-1.0.0.bin" }
  }',
  datetime('now')
);
