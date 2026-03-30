#!/usr/bin/env python3
"""
Sensor Monitor – Slave Sender v0.3.1
Store & Forward: Puffert Daten lokal, sendet bei Reconnect nach.
Autor: Tobias Meier <admin@secutobs.com>
"""
import time, math, random, json, os, sqlite3, urllib.request, urllib.error, socket
from datetime import datetime

VERSION = "0.5.8"
_BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(_BASE_DIR, "config.json")
_START_TIME = time.time()
DB_PATH     = os.path.join(_BASE_DIR, "buffer.db")

DEFAULT_CONFIG = {
    "master_url":    "http://pitemp.local:5000",
    "ingest_token":  "sensormonitor2026",
    "room_id":       "r2",
    "room_name":     "Arbeitszimmer",
    "gpio_pin":      4,
    "interval_sec":  30,
    "simulation":    True,
    "buffer_days":   7,      # Puffer max. 7 Tage aufbewahren
    "batch_size":    50,     # Max. Datensätze pro Nachsend-Batch
}

# ── Konfiguration ──────────────────────────────────────────────────────────
def get_own_ip():
    """Eigene IP-Adresse ermitteln."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None

def get_hostname():
    try:
        return socket.gethostname()
    except Exception:
        return "pitemp2"

def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f:
                cfg = json.load(f)
            for k, v in DEFAULT_CONFIG.items():
                cfg.setdefault(k, v)
            return cfg
        except Exception:
            pass
    return dict(DEFAULT_CONFIG)

def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)

# ── Lokaler Puffer (SQLite) ────────────────────────────────────────────────
def init_buffer():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS buffer (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            room_id  TEXT    NOT NULL,
            ts       TEXT    NOT NULL,
            temp     REAL    NOT NULL,
            hum      REAL    NOT NULL,
            sent     INTEGER NOT NULL DEFAULT 0
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sent ON buffer(sent, ts)")
    conn.commit()
    conn.close()

def buffer_save(room_id, temp, hum):
    """Messung lokal speichern."""
    ts = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    conn = sqlite3.connect(DB_PATH)
    conn.execute("INSERT INTO buffer (room_id,ts,temp,hum) VALUES (?,?,?,?)",
                 (room_id, ts, temp, hum))
    conn.commit()
    conn.close()
    return ts

def buffer_get_unsent(limit=50):
    """Noch nicht gesendete Messungen laden."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT id,room_id,ts,temp,hum FROM buffer WHERE sent=0 ORDER BY ts ASC LIMIT ?",
        (limit,)
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]

def buffer_mark_sent(ids):
    """Datensätze als gesendet markieren."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute(f"UPDATE buffer SET sent=1 WHERE id IN ({','.join('?'*len(ids))})", ids)
    conn.commit()
    conn.close()

def buffer_cleanup(days=7):
    """Alte gesendete Daten löschen."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "DELETE FROM buffer WHERE sent=1 AND ts < datetime('now',? || ' days')",
        (f"-{days}",)
    )
    deleted = conn.execute("SELECT changes()").fetchone()[0]
    conn.commit()
    conn.close()
    return deleted

def buffer_stats():
    """Puffer-Status für Logging."""
    conn = sqlite3.connect(DB_PATH)
    total  = conn.execute("SELECT count(*) FROM buffer").fetchone()[0]
    unsent = conn.execute("SELECT count(*) FROM buffer WHERE sent=0").fetchone()[0]
    conn.close()
    return total, unsent

# ── Sensor ─────────────────────────────────────────────────────────────────
_t = 0

def _find_iio_device():
    """Sucht das DHT22 IIO-Device im Kernel-Treiber."""
    import glob
    for path in glob.glob("/sys/bus/iio/devices/iio:device*/"):
        try:
            name = open(path + "name").read().strip()
            if "dht" in name.lower():
                return path
        except Exception:
            pass
    # Fallback: erstes verfügbares IIO-Device
    devices = glob.glob("/sys/bus/iio/devices/iio:device*/in_temp_input")
    if devices:
        return devices[0].replace("in_temp_input", "")
    return None

def _read_iio():
    """Liest Temp+Feuchte vom Kernel IIO-Treiber (dht11 overlay)."""
    path = _find_iio_device()
    if not path:
        return None, None
    try:
        # Kernel liefert Werte in Milli-Grad bzw. Milli-Prozent
        raw_temp = int(open(path + "in_temp_input").read().strip())
        raw_hum  = int(open(path + "in_humidityrelative_input").read().strip())
        return round(raw_temp / 1000.0, 1), round(raw_hum / 1000.0, 1)
    except Exception as e:
        print(f"[IIO] Fehler: {e}")
        return None, None

def _read_adafruit(cfg):
    """Fallback: adafruit_dht Library."""
    try:
        import adafruit_dht, board
        GPIO_MAP = {4: board.D4, 17: board.D17, 27: board.D27, 22: board.D22}
        pin = GPIO_MAP.get(cfg["gpio_pin"], board.D4)
        dht = adafruit_dht.DHT22(pin, use_pulseio=False)
        temp = round(dht.temperature, 1)
        hum  = round(dht.humidity, 1)
        dht.exit()
        return temp, hum
    except Exception as e:
        print(f"[Adafruit] Fehler: {e}")
        return None, None

def read_sensor(cfg):
    global _t
    if cfg.get("simulation", True):
        _t += 1
        temp = round(21.8 + 1.1*math.sin(_t/50) + 0.3*math.sin(_t/17)
                     + random.uniform(-.15, .15), 1)
        hum  = round(47.3 - 4*math.sin(_t/60) + 2*math.cos(_t/25)
                     + random.uniform(-.3, .3), 1)
        return temp, hum
    else:
        # 1. Versuch: Kernel IIO-Treiber (zuverlässig auf Pi Zero)
        temp, hum = _read_iio()
        if temp is not None:
            return temp, hum
        # 2. Versuch: adafruit_dht Fallback
        return _read_adafruit(cfg)

# ── Senden an Master ────────────────────────────────────────────────────────
def send_batch(cfg, readings):
    """
    Sendet eine Liste von Messungen als Batch an Master.
    Gibt Liste der erfolgreich gesendeten IDs zurück.
    """
    sent_ids = []
    url       = cfg["master_url"].rstrip("/") + "/api/ingest"
    own_ip    = get_own_ip()
    hostname  = get_hostname()
    total     = len(readings)

    for i, r in enumerate(readings):
        payload = json.dumps({
            "room_id":        r["room_id"],
            "temp":           r["temp"],
            "hum":            r["hum"],
            "token":          cfg["ingest_token"],
            "timestamp":      r.get("ts"),
            "slave_ip":       own_ip,
            "slave_host":     hostname,
            "buffer_pending": total - i - 1,
            "uptime_sec":     int(time.time() - _START_TIME),
            "version":        VERSION,
        }).encode()
        req = urllib.request.Request(
            url, data=payload,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                result = json.loads(resp.read())
                if result.get("ok"):
                    sent_ids.append(r["id"])
        except Exception:
            break  # Verbindung weg → Rest abbrechen

    return sent_ids

def check_master(cfg):
    """Prüft ob Master erreichbar ist."""
    try:
        url = cfg["master_url"].rstrip("/") + "/api/rooms"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=5):
            return True
    except Exception:
        return False

# ── Hauptschleife ───────────────────────────────────────────────────────────
def main():
    cfg = load_config()
    save_config(cfg)
    init_buffer()

    mode = "SIMULATION" if cfg.get("simulation") else "DHT22"
    print(f"\n✅  Sensor Sender {VERSION} [{mode}] – Store & Forward aktiv")
    print(f"    Raum:     {cfg['room_name']} ({cfg['room_id']})")
    print(f"    GPIO:     {cfg['gpio_pin']}")
    print(f"    Master:   {cfg['master_url']}")
    print(f"    Interval: {cfg['interval_sec']}s")
    print(f"    Puffer:   {DB_PATH}\n")

    # IIO-Treiber abwarten (braucht nach Boot etwas Zeit)
    import glob
    print("[…] Warte auf IIO-Sensor-Treiber...")
    for _ in range(30):  # max 30s warten
        if glob.glob("/sys/bus/iio/devices/iio:device*/in_temp_input"):
            print("[✓] IIO-Treiber bereit")
            break
        time.sleep(1)

    online        = False
    offline_since = None
    cycle         = 0
    last_success  = time.time()
    WATCHDOG_SEC  = 300  # 5 Min ohne Erfolg → Neustart

    while True:
        cfg   = load_config()
        cycle += 1

        # ── 1. Messung lesen ───────────────────────────────────────────────
        temp, hum = read_sensor(cfg)
        if temp is None:
            print("[!!] Sensor-Lesefehler")
            # Watchdog prüfen
            if time.time() - last_success > WATCHDOG_SEC:
                print(f"[!!] Watchdog: {WATCHDOG_SEC}s ohne Erfolg – Neustart...")
                import sys; sys.exit(1)
            time.sleep(cfg["interval_sec"])
            continue

        ts = buffer_save(cfg["room_id"], temp, hum)
        total, unsent = buffer_stats()

        # ── 2. Verbindung prüfen ──────────────────────────────────────────
        was_online = online
        online     = check_master(cfg)

        if online and not was_online:
            # Reconnect!
            if offline_since:
                offline_secs = int(time.time() - offline_since)
                print(f"[✓] Master wieder erreichbar – war {offline_secs}s offline")
                offline_since = None
            else:
                print("[✓] Master erreichbar")

        elif not online and was_online:
            offline_since = time.time()
            print(f"[!] Master nicht erreichbar – Puffer aktiv")

        # ── 3. Senden ─────────────────────────────────────────────────────
        if online:
            batch = buffer_get_unsent(limit=cfg.get("batch_size", 50))
            if batch:
                sent_ids = send_batch(cfg, batch)
                if sent_ids:
                    buffer_mark_sent(sent_ids)
                    new_total, new_unsent = buffer_stats()
                    last_success = time.time()  # Watchdog zurücksetzen
                    if len(sent_ids) > 1:
                        # Nachsende-Modus: mehr als 1 Datensatz
                        print(f"[↑] Nachgesendet: {len(sent_ids)} Messungen "
                              f"(noch {new_unsent} ausstehend)")
                    else:
                        # Normalbetrieb
                        print(f"[→] {cfg['room_name']}: {temp}°C  {hum}%  "
                              f"[{ts[11:16]}]"
                              + (f"  Puffer: {new_unsent} ausstehend"
                                 if new_unsent > 0 else ""))
                else:
                    print(f"[!] Senden fehlgeschlagen – {unsent} im Puffer")
        else:
            offline_info = ""
            if offline_since:
                mins = int((time.time() - offline_since) / 60)
                offline_info = f"  ({mins} min offline)"
            print(f"[●] {cfg['room_name']}: {temp}°C  {hum}%  "
                  f"→ Puffer [{unsent} ausstehend]{offline_info}")

        # ── 4. Puffer aufräumen (alle 100 Zyklen) ─────────────────────────
        if cycle % 100 == 0:
            deleted = buffer_cleanup(cfg.get("buffer_days", 7))
            if deleted:
                print(f"[♻] Puffer: {deleted} alte Einträge gelöscht")

        # ── 5. Watchdog: Neustart wenn zu lange kein Erfolg ────────────────
        if time.time() - last_success > WATCHDOG_SEC:
            print(f"[!!] Watchdog: {WATCHDOG_SEC}s ohne erfolgreiche Messung – Neustart...")
            import sys; sys.exit(1)

        time.sleep(cfg["interval_sec"])

if __name__ == "__main__":
    main()
