#!/usr/bin/env python3
"""
Sensor Monitor v0.5.2
Temperatur & Luftfeuchtigkeit – Multi-Raum Dashboard
Autor:  Tobias Meier <admin@secutobs.com>
"""

import sqlite3, time, threading, math, random, os, json
from datetime import datetime
from flask import Flask, jsonify, render_template, request

BASE_DIR    = os.path.dirname(os.path.abspath(__file__))
DB_PATH     = os.path.join(BASE_DIR, "sensor_data.db")
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")

DEFAULT_CONFIG = {
    "simulation_mode": True,
    "read_interval":   30,
    "ingest_token": "sensormonitor2026",
    "rooms": [
        {"id":"r1","name":"Öltankkellerraum","gpio":4,
         "thresholds":{"temp_max":18,"temp_min":5,"hum_max":70,"hum_min":40}},
        {"id":"r2","name":"Arbeitszimmer","gpio":17,
         "thresholds":{"temp_max":26,"temp_min":18,"hum_max":60,"hum_min":40}}
    ]
}

def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f:
                cfg = json.load(f)
            for k,v in DEFAULT_CONFIG.items():
                if k not in cfg:
                    cfg[k] = v
            return cfg
        except Exception:
            pass
    return dict(DEFAULT_CONFIG)

def save_config(cfg):
    with open(CONFIG_PATH,"w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

_cfg              = load_config()
ROOMS             = _cfg["rooms"]
SIMULATION_MODE   = _cfg["simulation_mode"]
READ_INTERVAL_SEC = _cfg.get("read_interval", 30)

# ── Datenbank ────────────────────────────────────────────────────────────

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""CREATE TABLE IF NOT EXISTS readings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_id TEXT NOT NULL,
        ts DATETIME DEFAULT CURRENT_TIMESTAMP,
        temp REAL, hum REAL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_room_ts ON readings(room_id,ts)")
    # Slave-Verbindungslog
    conn.execute("""CREATE TABLE IF NOT EXISTS slave_log (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        slave_id   TEXT    NOT NULL,
        ts         DATETIME DEFAULT CURRENT_TIMESTAMP,
        success    INTEGER NOT NULL DEFAULT 1,
        latency_ms INTEGER,
        buffer_pending INTEGER DEFAULT 0,
        slave_ip   TEXT,
        slave_host TEXT,
        uptime_sec INTEGER
    )""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_slave_ts ON slave_log(slave_id, ts)")
    # Slave-Registry (letzte bekannte Infos)
    conn.execute("""CREATE TABLE IF NOT EXISTS slave_registry (
        slave_id   TEXT    PRIMARY KEY,
        slave_host TEXT,
        last_ip    TEXT,
        last_seen  DATETIME,
        version    TEXT
    )""")
    conn.commit(); conn.close()

def migrate_db():
    """Bestehende DB um neue Tabellen/Spalten erweitern (safe für Updates)."""
    conn = sqlite3.connect(DB_PATH)
    # slave_log nachrüsten falls DB aus alter Version
    conn.execute("""CREATE TABLE IF NOT EXISTS slave_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        slave_id TEXT NOT NULL,
        ts DATETIME DEFAULT CURRENT_TIMESTAMP,
        success INTEGER NOT NULL DEFAULT 1,
        latency_ms INTEGER,
        buffer_pending INTEGER DEFAULT 0,
        slave_ip TEXT, slave_host TEXT, uptime_sec INTEGER)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_slave_ts ON slave_log(slave_id, ts)")
    conn.execute("""CREATE TABLE IF NOT EXISTS slave_registry (
        slave_id TEXT PRIMARY KEY,
        slave_host TEXT, last_ip TEXT,
        last_seen DATETIME, version TEXT)""")
    conn.commit(); conn.close()

def reset_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("DELETE FROM readings")
    conn.commit(); conn.close()

def save_reading(room_id, temp, hum):
    conn = sqlite3.connect(DB_PATH)
    conn.execute("INSERT INTO readings (room_id,temp,hum) VALUES (?,?,?)",
                 (room_id, temp, hum))
    conn.execute("DELETE FROM readings WHERE ts < datetime('now','-7 days') AND room_id=?",
                 (room_id,))
    conn.commit(); conn.close()

# ── Sensor ───────────────────────────────────────────────────────────────

_sim_t = {}

def _find_iio_device(gpio_pin):
    """Sucht IIO-Device für den gegebenen GPIO-Pin."""
    import glob
    # Erstes verfügbares IIO-Device mit temp+humidity
    for path in glob.glob("/sys/bus/iio/devices/iio:device*/"):
        try:
            t = open(path + "in_temp_input").read().strip()
            h = open(path + "in_humidityrelative_input").read().strip()
            if t and h:
                return path
        except Exception:
            pass
    return None

def _read_iio(gpio_pin):
    """Liest Temp+Feuchte vom Kernel IIO-Treiber."""
    path = _find_iio_device(gpio_pin)
    if not path:
        return None, None
    try:
        raw_temp = int(open(path + "in_temp_input").read().strip())
        raw_hum  = int(open(path + "in_humidityrelative_input").read().strip())
        return round(raw_temp / 1000.0, 1), round(raw_hum / 1000.0, 1)
    except Exception as e:
        print(f"[IIO] Fehler: {e}")
        return None, None

def read_sensor(room):
    if SIMULATION_MODE:
        rid = room["id"]
        _sim_t[rid] = _sim_t.get(rid,0) + 1
        t  = _sim_t[rid]
        bt = {"r1":12.2,"r2":21.8,"r3":14.1,"r4":8.5}.get(rid, 20.0)
        bh = {"r1":62.7,"r2":47.3,"r3":74.6,"r4":80.1}.get(rid, 55.0)
        temp = round(bt + 1.1*math.sin(t/50) + 0.3*math.sin(t/17) + random.uniform(-.15,.15), 1)
        hum  = round(bh - 4*math.sin(t/60) + 2*math.cos(t/25) + random.uniform(-.3,.3), 1)
        return temp, hum
    else:
        # 1. Kernel IIO-Treiber (zuverlässig auf Pi Zero 1)
        temp, hum = _read_iio(room["gpio"])
        if temp is not None:
            return temp, hum
        # 2. Fallback: adafruit_dht
        try:
            import adafruit_dht, board
            GPIO_MAP = {4:board.D4, 17:board.D17, 27:board.D27, 22:board.D22}
            pin = GPIO_MAP.get(room["gpio"], board.D4)
            dht = adafruit_dht.DHT22(pin, use_pulseio=False)
            temp = dht.temperature; hum = dht.humidity
            dht.exit()
            return round(temp,1), round(hum,1)
        except Exception as e:
            print(f"[{room['id']}] DHT22 Fehler: {e}")
            return None, None

_stop_event    = threading.Event()
_sensor_thread = None

def sensor_loop():
    print(f"Sensor-Thread gestartet – Interval: {READ_INTERVAL_SEC}s")
    while not _stop_event.is_set():
        for room in ROOMS:
            temp, hum = read_sensor(room)
            if temp is not None:
                save_reading(room["id"], temp, hum)
                print(f"[{datetime.now().strftime('%H:%M:%S')}] {room['name']}: {temp}°C  {hum}%")
        _stop_event.wait(READ_INTERVAL_SEC)

def restart_sensor_thread():
    global _sensor_thread, _stop_event
    _stop_event.set()
    if _sensor_thread and _sensor_thread.is_alive():
        _sensor_thread.join(timeout=5)
    _stop_event = threading.Event()
    _sensor_thread = threading.Thread(target=sensor_loop, daemon=True)
    _sensor_thread.start()

# ── Flask ─────────────────────────────────────────────────────────────────

app = Flask(__name__)

def _read_version():
    try:
        for line in open(os.path.join(BASE_DIR,"VERSION")):
            if line.startswith("Version:"): return line.split(":")[-1].strip()
    except Exception: pass
    return "0.1.0"

@app.route("/")
def index():
    return render_template("index.html", rooms=ROOMS,
                           version=_read_version(), simulation=SIMULATION_MODE)

@app.route("/api/rooms")
def api_rooms():
    result = []
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    for room in ROOMS:
        row = conn.execute(
            "SELECT temp,hum,strftime('%Y-%m-%dT%H:%M:%S',ts) AS ts "
            "FROM readings WHERE room_id=? ORDER BY ts DESC LIMIT 1", (room["id"],)
        ).fetchone()
        result.append({"id":room["id"],"name":room["name"],"gpio":room["gpio"],
                       "thresholds":room["thresholds"],"latest":dict(row) if row else None})
    conn.close(); return jsonify(result)

@app.route("/api/history/<room_id>")
def api_history(room_id):
    hours = request.args.get("hours",1,type=float)
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT strftime('%Y-%m-%dT%H:%M:%S',ts) AS ts, temp AS t, hum AS h "
        "FROM readings WHERE room_id=? AND ts >= datetime('now',? || ' hours') ORDER BY ts ASC",
        (room_id, f"-{hours}")
    ).fetchall()
    conn.close(); return jsonify([dict(r) for r in rows])

@app.route("/api/thresholds/<room_id>", methods=["POST"])
def api_set_thresholds(room_id):
    data = request.json or {}
    for room in ROOMS:
        if room["id"] == room_id:
            for k in ("temp_max","temp_min","hum_max","hum_min"):
                if k in data: room["thresholds"][k] = float(data[k])
            cfg = load_config(); cfg["rooms"] = ROOMS; save_config(cfg)
            return jsonify({"ok":True})
    return jsonify({"ok":False}), 404

@app.route("/api/settings")
def api_get_settings():
    cfg = load_config()
    return jsonify({"simulation_mode":cfg.get("simulation_mode",True),
                    "read_interval":cfg.get("read_interval",30),
                    "rooms":cfg.get("rooms",[])})

@app.route("/api/settings/mode", methods=["POST"])
def api_set_mode():
    global SIMULATION_MODE
    data     = request.json or {}
    new_sim  = bool(data.get("simulation_mode", True))
    was_sim  = SIMULATION_MODE
    cfg      = load_config()
    cfg["simulation_mode"] = new_sim
    save_config(cfg)
    SIMULATION_MODE = new_sim
    db_reset = False
    if was_sim and not new_sim:
        reset_db(); db_reset = True
    restart_sensor_thread()
    return jsonify({"ok":True,"mode":"simulation" if new_sim else "live","db_reset":db_reset})

@app.route("/api/settings/rooms", methods=["POST"])
def api_save_rooms():
    global ROOMS
    data      = request.json or {}
    new_rooms = data.get("rooms",[])
    ids = set()
    for r in new_rooms:
        if not r.get("id") or not r.get("name"):
            return jsonify({"ok":False,"error":"id und name erforderlich"}), 400
        if r["id"] in ids:
            return jsonify({"ok":False,"error":f"Doppelte ID: {r['id']}"}), 400
        ids.add(r["id"])
        r.setdefault("gpio", 4)
        r.setdefault("thresholds",{"temp_max":30,"temp_min":0,"hum_max":80,"hum_min":30})
    ROOMS = new_rooms
    cfg = load_config(); cfg["rooms"] = ROOMS; save_config(cfg)
    restart_sensor_thread()
    return jsonify({"ok":True,"count":len(ROOMS)})

@app.route("/api/settings/interval", methods=["POST"])
def api_set_interval():
    global READ_INTERVAL_SEC
    data     = request.json or {}
    interval = max(10, min(int(data.get("interval",30)), 300))
    READ_INTERVAL_SEC = interval
    cfg = load_config(); cfg["read_interval"] = interval; save_config(cfg)
    restart_sensor_thread()
    return jsonify({"ok":True,"interval":interval})

@app.route("/api/ingest", methods=["POST"])
def api_ingest():
    """Empfängt Messdaten von Slave-Pis."""
    cfg   = load_config()
    token = cfg.get("ingest_token", "")
    data  = request.json or {}

    # Token prüfen
    if token and data.get("token") != token:
        return jsonify({"ok": False, "error": "Ungültiger Token"}), 401

    room_id = data.get("room_id", "").strip()
    temp    = data.get("temp")
    hum     = data.get("hum")

    if not room_id or temp is None or hum is None:
        return jsonify({"ok": False, "error": "room_id, temp, hum erforderlich"}), 400

    # Raum muss in der Konfiguration existieren
    known = [r["id"] for r in ROOMS]
    if room_id not in known:
        return jsonify({"ok": False, "error": f"Unbekannte room_id: {room_id}"}), 404

    # Optionaler Timestamp vom Slave (Store & Forward)
    ts         = data.get("timestamp")
    slave_ip   = data.get("slave_ip")
    slave_host = data.get("slave_host", room_id)
    buf_pend   = int(data.get("buffer_pending", 0))
    uptime     = data.get("uptime_sec")
    t_start    = time.time()

    if ts:
        conn = sqlite3.connect(DB_PATH)
        conn.execute("INSERT INTO readings (room_id,ts,temp,hum) VALUES (?,?,?,?)",
                     (room_id, ts, float(temp), float(hum)))
        conn.execute(
            "DELETE FROM readings WHERE ts < datetime('now','-7 days') AND room_id=?",
            (room_id,))
        conn.commit(); conn.close()
    else:
        save_reading(room_id, float(temp), float(hum))

    latency_ms = int((time.time() - t_start) * 1000)

    # Slave-Log schreiben
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "INSERT INTO slave_log (slave_id,success,latency_ms,buffer_pending,slave_ip,slave_host,uptime_sec)"
        " VALUES (?,1,?,?,?,?,?)",
        (room_id, latency_ms, buf_pend, slave_ip, slave_host, uptime)
    )
    # Registry aktualisieren
    conn.execute(
        "INSERT INTO slave_registry (slave_id,slave_host,last_ip,last_seen,version)"
        " VALUES (?,?,?,datetime('now','localtime'),?)"
        " ON CONFLICT(slave_id) DO UPDATE SET"
        "   slave_host=excluded.slave_host,"
        "   last_ip=excluded.last_ip,"
        "   last_seen=excluded.last_seen,"
        "   version=excluded.version",
        (room_id, slave_host, slave_ip, data.get("version","–"))
    )
    conn.commit(); conn.close()

    print(f"[Ingest] {room_id}: {temp}°C  {hum}%  buf={buf_pend}"
          + (f"  ip={slave_ip}" if slave_ip else ""))
    return jsonify({"ok": True, "latency_ms": latency_ms})


@app.route("/static/<path:filename>")
def static_files(filename):
    from flask import send_from_directory
    return send_from_directory(os.path.join(BASE_DIR, "static"), filename)


@app.route("/api/summary")
def api_summary():
    """Min/Max/Avg heute pro Raum."""
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    result = []
    for room in ROOMS:
        row = conn.execute("""
            SELECT
              round(min(temp),1) AS temp_min,
              round(max(temp),1) AS temp_max,
              round(avg(temp),1) AS temp_avg,
              round(min(hum),1)  AS hum_min,
              round(max(hum),1)  AS hum_max,
              round(avg(hum),1)  AS hum_avg,
              count(*)           AS count
            FROM readings
            WHERE room_id=? AND ts >= datetime('now','start of day')
        """, (room["id"],)).fetchone()
        result.append({
            "id":   room["id"],
            "name": room["name"],
            "today": dict(row) if row and row["count"] else None
        })
    conn.close()
    return jsonify(result)

@app.route("/api/mold_risk")
def api_mold_risk():
    """Schimmelrisiko pro Raum basierend auf letzter Messung."""
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    result = []
    for room in ROOMS:
        row = conn.execute(
            "SELECT temp,hum FROM readings WHERE room_id=? ORDER BY ts DESC LIMIT 1",
            (room["id"],)
        ).fetchone()
        risk = "none"; score = 0; label = "Kein Risiko"; advice = ""
        if row and row["temp"] is not None:
            t, h = row["temp"], row["hum"]
            # Taupunkt-Annäherung (Magnus-Formel)
            alpha = (17.27 * t) / (237.3 + t) + math.log(h / 100.0)
            dew   = (237.3 * alpha) / (17.27 - alpha)
            # Risikobewertung
            if h >= 80 and t < 18:
                risk="high"; score=90; label="Hohes Risiko"
                advice="Sofort lüften! Feuchte zu hoch bei kühler Temperatur."
            elif h >= 70 and t < 20:
                risk="medium"; score=60; label="Erhöhtes Risiko"
                advice="Regelmäßig lüften empfohlen."
            elif h >= 60 and t < 16:
                risk="medium"; score=45; label="Erhöhtes Risiko"
                advice="Auf Feuchtigkeitsquellen achten."
            else:
                risk="low"; score=15; label="Kein Risiko"
                advice="Optimale Bedingungen."
            result.append({
                "id": room["id"], "name": room["name"],
                "temp": t, "hum": h, "dew": round(dew, 1),
                "risk": risk, "score": score, "label": label, "advice": advice
            })
        else:
            result.append({"id":room["id"],"name":room["name"],
                           "risk":"none","score":0,"label":"Keine Daten","advice":""})
    conn.close()
    return jsonify(result)

@app.route("/api/compare")
def api_compare():
    """Alle Räume in einem Chart – letzten N Stunden."""
    hours = request.args.get("hours", 6, type=float)
    conn  = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    result = {}
    for room in ROOMS:
        rows = conn.execute(
            "SELECT strftime('%Y-%m-%dT%H:%M:%S',ts) AS ts, temp AS t, hum AS h "
            "FROM readings WHERE room_id=? AND ts >= datetime('now',? || ' hours') "
            "ORDER BY ts ASC",
            (room["id"], f"-{hours}")
        ).fetchall()
        result[room["id"]] = {"name": room["name"], "data": [dict(r) for r in rows]}
    conn.close()
    return jsonify(result)


# ── Slave Stats & Verwaltung ─────────────────────────────────────────────

@app.route("/api/slaves")
def api_slaves():
    """Alle bekannten Slaves mit Live-Status."""
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    slaves = []
    for room in ROOMS:
        rid = room["id"]
        reg = conn.execute(
            "SELECT * FROM slave_registry WHERE slave_id=?", (rid,)
        ).fetchone()
        if not reg:
            continue  # Nur Slaves die sich gemeldet haben

        # Letzten 24h: Erfolgsrate
        stats_24h = conn.execute("""
            SELECT
              count(*)                                   AS total,
              sum(success)                               AS ok,
              round(avg(latency_ms),1)                   AS avg_latency,
              round(avg(buffer_pending),1)               AS avg_buffer,
              max(buffer_pending)                        AS max_buffer,
              strftime('%Y-%m-%dT%H:%M:%S', max(ts))    AS last_ts
            FROM slave_log
            WHERE slave_id=? AND ts >= datetime('now','-24 hours')
        """, (rid,)).fetchone()

        # Letzten 60 Min: für "gerade jetzt" Status
        stats_1h = conn.execute("""
            SELECT count(*) AS total, sum(success) AS ok
            FROM slave_log
            WHERE slave_id=? AND ts >= datetime('now','-1 hour')
        """, (rid,)).fetchone()

        # Letzte 20 Übertragungen für Timeline
        timeline = conn.execute("""
            SELECT strftime('%Y-%m-%dT%H:%M:%S',ts) AS ts,
                   success, latency_ms, buffer_pending
            FROM slave_log WHERE slave_id=?
            ORDER BY ts DESC LIMIT 20
        """, (rid,)).fetchall()

        # Offline-Erkennung: letzte Messung > 2x Intervall?
        last_seen = reg["last_seen"]
        offline_sec = None
        if last_seen:
            import re
            # SQLite liefert String ohne Z
            offline_sec = int(time.time()) - int(
                __import__('datetime').datetime.strptime(
                    last_seen[:19], "%Y-%m-%d %H:%M:%S"
                ).timestamp()
            )

        s24 = dict(stats_24h) if stats_24h else {}
        s1h = dict(stats_1h)  if stats_1h  else {}

        slaves.append({
            "room_id":      rid,
            "room_name":    room["name"],
            "slave_host":   reg["slave_host"],
            "last_ip":      reg["last_ip"],
            "last_seen":    last_seen,
            "offline_sec":  offline_sec,
            "version":      reg["version"],
            "stats_24h": {
                "total":       s24.get("total",0),
                "success":     s24.get("ok",0),
                "rate_pct":    round(s24.get("ok",0)/s24.get("total",1)*100,1) if s24.get("total") else 0,
                "avg_latency": s24.get("avg_latency"),
                "avg_buffer":  s24.get("avg_buffer"),
                "max_buffer":  s24.get("max_buffer",0),
                "last_ts":     s24.get("last_ts"),
            },
            "stats_1h": {
                "total":   s1h.get("total",0),
                "success": s1h.get("ok",0),
                "rate_pct": round(s1h.get("ok",0)/s1h.get("total",1)*100,1) if s1h.get("total") else 0,
            },
            "timeline": [dict(r) for r in timeline],
        })
    conn.close()
    return jsonify(slaves)

@app.route("/api/slaves/<slave_id>/ping", methods=["POST"])
def api_slave_ping(slave_id):
    """Pingt einen Slave an seiner letzten bekannten IP."""
    import subprocess
    conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row
    reg  = conn.execute(
        "SELECT * FROM slave_registry WHERE slave_id=?", (slave_id,)
    ).fetchone()
    conn.close()
    if not reg:
        return jsonify({"ok": False, "error": "Slave unbekannt"}), 404

    results = {}
    # 1. mDNS Hostname (zuverlässigste Methode)
    host = reg["slave_host"] or f"pitemp2"
    if not host.endswith(".local"):
        host = host + ".local"
    try:
        r = subprocess.run(["ping","-c","2","-W","2", host],
                           capture_output=True, text=True, timeout=6)
        results["mdns"] = {"host": host, "reachable": r.returncode == 0,
                           "output": r.stdout.strip().split("\n")[-1]}
    except Exception as e:
        results["mdns"] = {"host": host, "reachable": False, "error": str(e)}

    # 2. Letzte bekannte IP
    if reg["last_ip"]:
        try:
            r = subprocess.run(["ping","-c","2","-W","2", reg["last_ip"]],
                               capture_output=True, text=True, timeout=6)
            results["last_ip"] = {"ip": reg["last_ip"], "reachable": r.returncode == 0}
        except Exception as e:
            results["last_ip"] = {"ip": reg["last_ip"], "reachable": False}

    reachable = any(v.get("reachable") for v in results.values())
    return jsonify({"ok": True, "reachable": reachable, "results": results,
                    "slave_id": slave_id})

@app.route("/api/slaves/<slave_id>/discover", methods=["POST"])
def api_slave_discover(slave_id):
    """Versucht Slave per mDNS zu finden."""
    import subprocess
    # Alle bekannten pitemp Hostnamen versuchen
    candidates = [f"pitemp2.local", f"pitemp3.local", f"{slave_id}.local"]
    found = []
    for host in candidates:
        try:
            r = subprocess.run(["ping","-c","1","-W","2", host],
                               capture_output=True, timeout=4)
            if r.returncode == 0:
                found.append(host)
        except Exception:
            pass
    return jsonify({"ok": True, "found": found, "slave_id": slave_id})


if __name__ == "__main__":
    init_db()
    migrate_db()  # Bestehende DBs aktualisieren
    _sensor_thread = threading.Thread(target=sensor_loop, daemon=True)
    _sensor_thread.start()
    time.sleep(1)
    mode = "SIMULATION" if SIMULATION_MODE else "HARDWARE"
    print("\n✅  Sensor Monitor v0.5.2 [" + mode + "]  →  http://0.0.0.0:5000\n")
    app.run(host="0.0.0.0", port=5000, debug=False)
