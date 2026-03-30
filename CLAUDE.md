# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Sensor Monitor** – Self-hosted temperature & humidity monitoring on Raspberry Pi Zero W. Two components:

- **`sensor-tracker/`** (Master): Flask app that receives data, stores in SQLite, serves the dashboard at `http://pitemp.local`
- **`sensor-sender/`** (Slave): Standalone Python script that reads DHT22 sensor and POSTs to master

## Running Locally (Development)

```bash
# Master – Simulation mode is on by default, no hardware needed
cd sensor-tracker
pip install flask
python app.py
# → http://localhost:5000
```

```bash
# Slave – test sending to a running master
cd sensor-sender
python sender.py
# Uses config.json (copy from config.example.json, set simulation: true for testing)
```

## Deployment (Raspberry Pi)

Files go to `/home/pi/sensor-tracker/` or `/home/pi/sensor-sender/` respectively. Install via firstboot scripts; after that use systemd:

```bash
sudo systemctl restart sensor-tracker   # master
sudo systemctl restart sensor-sender    # slave
journalctl -u sensor-tracker -f         # live logs
```

## Versioning

On every change, update **all** of these:
1. `sensor-tracker/VERSION` – increment version + update date, add changelog entry
2. `sensor-tracker/app.py` – docstring on line 3
3. `sensor-sender/sender.py` – `VERSION = "x.y.z"` on line 11

Schema: `PATCH` (x.x.+1) for bugfixes, `MINOR` (x.+1.0) for new features.

After changes: build ZIPs and push to GitHub.

```bash
# Master ZIP
zip -r sensor-tracker-vX.Y.Z.zip \
  sensor-tracker/app.py sensor-tracker/requirements.txt \
  sensor-tracker/config.example.json sensor-tracker/sensor-tracker.service \
  sensor-tracker/VERSION sensor-tracker/static/ sensor-tracker/templates/ \
  -x "*.pyc" -x "__pycache__/*" -x "*.db"

# Slave ZIP
zip -r sensor-sender-vX.Y.Z.zip \
  sensor-sender/sender.py sensor-sender/requirements.txt \
  sensor-sender/config.example.json sensor-sender/sensor-sender.service \
  -x "*.pyc" -x "__pycache__/*" -x "*.db"
```

## Architecture

### Master (`sensor-tracker/app.py`)

Single-file Flask app. Three layers:

1. **Config** – loaded from `config.json` at startup into globals `ROOMS`, `SIMULATION_MODE`, `READ_INTERVAL_SEC`. Written back on every settings change via `save_config()`.

2. **Sensor loop** – `sensor_loop()` runs in a daemon thread, calls `read_sensor(room)` per room every `READ_INTERVAL_SEC` seconds. Two read paths:
   - `_read_iio()` – primary: reads Kernel IIO driver (`/sys/bus/iio/devices/iio:device*/`), finds device by name containing `dht`
   - `adafruit_dht` – fallback if IIO returns None

3. **API** – all routes under `/api/`. Key endpoints:
   - `POST /api/ingest` – slaves send data here (token auth via `ingest_token` in config)
   - `GET /api/rooms` – current reading per room
   - `GET /api/history/<room_id>?hours=N` – time-series data for charts
   - `GET /api/slaves` – slave connection stats from `slave_log` + `slave_registry` tables

### Slave (`sensor-sender/sender.py`)

Single loop in `main()`:
1. Read sensor (`_read_iio()` → `_read_adafruit()` fallback)
2. Save to local SQLite buffer (`buffer.db`) with timestamp
3. Check master reachability
4. If online: fetch all unsent rows (`buffer_get_unsent()`), send as batch to `/api/ingest`, mark sent
5. Watchdog: `sys.exit(1)` after 5 min without success → systemd restarts

**Store & Forward**: every reading is written locally first, then flushed. Slave sends original timestamps so master charts have no gaps after reconnect.

### Database (Master)

Three tables in `sensor_data.db`:
- `readings` – `(room_id, ts, temp, hum)` – 7-day rolling window
- `slave_log` – per-transmission log: success, latency, buffer depth, IP, uptime
- `slave_registry` – latest known state per slave: IP, hostname, last_seen (UTC), version

`migrate_db()` runs at startup to safely add missing tables/columns to existing installs.

### Frontend (`sensor-tracker/templates/index.html`)

Single-page app (no framework). Tab navigation: Übersicht / Vergleich / Analyse / Netzwerk / Einstellungen. Chart.js loaded from CDN – dashboard degrades gracefully without internet (no charts). Push notifications use the browser Notification API.

## Key Configuration

`config.json` is git-ignored and auto-created from `DEFAULT_CONFIG` in `app.py`. The `ingest_token` must match on master and slave. Default: `sensormonitor2026` – change in production.

DHT22 requires Kernel IIO overlay on Pi Zero 1 (too slow for software polling):
```bash
echo "dtoverlay=dht11,gpiopin=4" | sudo tee -a /boot/firmware/config.txt
```
