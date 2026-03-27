# 🌡️ Sensor Monitor

**Temperatur & Luftfeuchtigkeit – Multi-Raum Dashboard auf dem Raspberry Pi Zero W**

Ein selbst gehostetes Monitoring-System für bis zu 4 Räume mit DHT22-Sensoren, Apple-inspiriertem Web-Dashboard und Master/Slave-Architektur.

![Dashboard Preview](docs/images/dashboard.png)

---

## 💡 Die Idee

Ich wollte die Temperatur und Luftfeuchtigkeit in meinem Öltankkellerraum überwachen – günstig, lokal, ohne Cloud. Aus diesem einfachen Wunsch entstand ein vollständiges System:

- Ein **Raspberry Pi Zero W** liest einen DHT22-Sensor und stellt ein Web-Dashboard bereit
- Ein zweiter Pi sendet Daten drahtlos an den ersten
- Alles läuft **headless**, wird per **Captive Portal** eingerichtet und startet automatisch

Das Projekt wurde vollständig selbst entwickelt und iterativ verbessert – von der ersten Version mit einem Raum bis zur Master/Slave-Architektur mit Store & Forward, Watchdog und Push-Benachrichtigungen.

---

## ✨ Features

| Feature | Details |
|---|---|
| **Multi-Raum** | Bis zu 4 DHT22-Sensoren gleichzeitig |
| **Apple-Design** | Helles, minimalistisches iOS-inspiriertes UI |
| **4 Dashboard-Tabs** | Übersicht · Vergleich · Analyse · Netzwerk |
| **Master/Slave** | Beliebig viele Pis verbinden |
| **Store & Forward** | Slave puffert offline, sendet mit Originalzeit nach |
| **Watchdog** | Automatischer Neustart bei Sensor-Ausfällen |
| **Headless Setup** | Captive Portal – kein Monitor nötig |
| **Push-Benachrichtigungen** | Browser-API bei Grenzwert-Alarm |
| **Schimmelrisiko** | Taupunkt-Berechnung nach Magnus-Formel |
| **Kein Cloud-Zwang** | 100% lokal, kein Account nötig |

---

## 🏗️ Architektur

```
Pi Zero W #1 (Master)          Pi Zero W #2+ (Slave)
┌─────────────────────┐        ┌──────────────────────┐
│  Flask Dashboard    │◄───────│  sender.py           │
│  SQLite Datenbank   │  HTTP  │  DHT22 über IIO      │
│  http://pitemp.local│  POST  │  Store & Forward     │
│  Port 5000          │        │  Watchdog            │
└─────────────────────┘        └──────────────────────┘
        │                               │
    DHT22                           DHT22
  Öltankraum                    Arbeitszimmer
```

---

## 🛒 Einkaufsliste

| Bauteil | Stück | Preis ca. |
|---|---|---|
| Raspberry Pi Zero W (oder WH) | 1-4 | ~15€ |
| DHT22 Sensor (AM2302) | 1 pro Pi | ~4€ |
| 10 kΩ Widerstand | 1 pro Sensor | <1€ |
| Micro-SD Karte (8GB+) | 1 pro Pi | ~8€ |
| 5V Micro-USB Netzteil | 1 pro Pi | ~8€ |
| Jumper-Kabel | 4 pro Sensor | ~2€ |

**Gesamt: ~40-50€ für zwei Räume**

---

## 🔌 Hardware – Verdrahtung

```
DHT22 Pin 1 (VCC)  →  Pi Pin 2  (5V)
DHT22 Pin 2 (DATA) →  Pi Pin 7  (GPIO4)
DHT22 Pin 3 (NC)   →  nicht belegt
DHT22 Pin 4 (GND)  →  Pi Pin 6  (GND)

10 kΩ Pull-Up: Bein 1 → DATA (Pi Pin 7)
               Bein 2 → 3,3V (Pi Pin 1)
```

> ⚠️ **Wichtig:** VCC muss an **5V** (Pin 2), nicht 3,3V! Der Pi Zero 1 liefert auf Pin 1 nur ~3,1V – zu wenig für den DHT22.

Der Schaltplan ist in der [Anleitung](docs/Sensor_Monitor_Anleitung.docx) und in den Einstellungen der Webseite integriert.

---

## 🚀 Installation – Master (Pi 1)

### Schritt 1: SD-Karte vorbereiten

1. [Raspberry Pi Imager](https://rpi.imager.raspberrypi.com) öffnen
2. Image: **Raspberry Pi OS Lite (32-bit, Bookworm)**
3. Einstellungen:
   - Hostname: `pitemp`
   - SSH aktivieren
   - WLAN: **leer lassen** (wird per Portal eingerichtet)
4. Auf SD-Karte schreiben

### Schritt 2: Dateien kopieren

```bash
cp firstboot_master.sh /Volumes/bootfs/firstboot.sh
cp -r sensor-tracker /Volumes/bootfs/
```

### Schritt 3: cmdline.txt anpassen

Die Datei `/Volumes/bootfs/cmdline.txt` öffnen und am Ende der **einzigen Zeile** anhängen:

```
systemd.run=/boot/firmware/firstboot.sh
```

> ❌ **NICHT** `systemd.run_success_action=none` hinzufügen – das führt zur Neustart-Schleife!

### Schritt 4: Captive Portal

1. SD-Karte einlegen, Pi starten
2. Ca. 90 Sekunden warten
3. WLAN: **SensorMonitor** / Passwort: `sensor1234`
4. Portal öffnet sich automatisch → Heimnetz-Daten eingeben
5. Ca. 5 Minuten warten → **http://pitemp.local**

### Schritt 5: Kernel-Treiber aktivieren

```bash
ssh pi@pitemp.local
echo "dtoverlay=dht11,gpiopin=4" | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

Testen:
```bash
cat /sys/bus/iio/devices/iio:device0/in_temp_input
# Beispiel: 22700 = 22,7°C ✅
```

---

## 🚀 Installation – Slave (Pi 2+)

> ⚠️ **Master muss zuerst laufen!**

Identisch wie Master, aber:

```bash
# Hostname im Imager: pitemp2
cp firstboot_slave.sh /Volumes/bootfs/firstboot.sh
cp -r sensor-sender /Volumes/bootfs/
```

Captive Portal: WLAN **SensorMonitor2** / Passwort: `sensor1234`

Kernel-Treiber nach Installation:
```bash
ssh pi@pitemp2.local
echo "dtoverlay=dht11,gpiopin=4" | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

---

## 📱 Dashboard

Nach erfolgreicher Installation unter **http://pitemp.local** erreichbar.

### Tabs

**Übersicht** – Alle Räume mit Status-Ampel (Optimal/Grenzwertig/Alarm), aktuelle Messwerte, Fortschrittsbalken

**Vergleich** – Alle Räume in einem Chart, Temperatur oder Feuchte, wählbar 1h/6h/24h

**Analyse** – Tageszusammenfassung (Min/Ø/Max), Schimmelrisiko mit Taupunkt-Berechnung, Alarmverlauf

**Netzwerk** – Slave-Verbindungsqualität, Timeline der letzten 20 Übertragungen, Latenz, Ping-Button

**Einstellungen** – Demo/Live-Modus, Raumverwaltung, Messintervall, DHT22 Schaltplan

---

## 🔧 Store & Forward

Wenn der Slave den Master nicht erreicht, puffert er alle Messungen lokal in `buffer.db`. Nach Reconnect werden alle Daten **mit den originalen Zeitstempeln** nachgesendet – keine Datenlücken im Chart.

```
Normal:     DHT22 → sofort senden → Master speichert
Offline:    DHT22 → buffer.db (lokal)
Reconnect:  buffer.db → Master (mit Originalzeit)
```

---

## 🐕 Watchdog

Der Slave überwacht sich selbst: Bei >5 Minuten ohne erfolgreiche Messung beendet sich der Service und systemd startet ihn automatisch neu. Der IIO-Treiber wird dabei neu initialisiert.

```
WATCHDOG_SEC = 300  # 5 Minuten
→ sys.exit(1)
→ systemd Restart nach 15s
→ IIO-Treiber neu geladen
```

---

## 📡 API-Endpunkte (Master)

| Endpunkt | Methode | Beschreibung |
|---|---|---|
| `/api/rooms` | GET | Alle Räume mit letzter Messung |
| `/api/history/<id>?hours=N` | GET | Verlauf der letzten N Stunden |
| `/api/summary` | GET | Min/Ø/Max heute pro Raum |
| `/api/mold_risk` | GET | Schimmelrisiko mit Taupunkt |
| `/api/compare?hours=N` | GET | Alle Räume im Vergleich |
| `/api/slaves` | GET | Slave-Statistiken |
| `/api/ingest` | POST | Slave sendet Messdaten |
| `/api/settings` | GET/POST | Konfiguration |

---

## 🗂️ Projektstruktur

```
sensor-monitor/
├── firstboot_master.sh          # First-Boot Setup Master
├── firstboot_slave.sh           # First-Boot Setup Slave
├── sensor-tracker/              # Master (Flask App)
│   ├── app.py                   # Backend + API
│   ├── templates/
│   │   └── index.html           # Dashboard (Single Page App)
│   ├── static/
│   │   └── wiring.svg           # Schaltplan
│   ├── requirements.txt
│   ├── sensor-tracker.service   # systemd Service
│   └── VERSION
├── sensor-sender/               # Slave (Sender)
│   ├── sender.py                # DHT22 lesen + senden
│   ├── config.json              # Konfiguration
│   └── sensor-sender.service    # systemd Service
└── docs/
    └── Sensor_Monitor_Anleitung.docx
```

---

## ⚙️ Konfiguration

### Master – `sensor-tracker/config.json` (wird automatisch erstellt)

```json
{
  "simulation_mode": false,
  "read_interval": 30,
  "ingest_token": "sensormonitor2026",
  "rooms": [
    {
      "id": "r1",
      "name": "Öltankraum",
      "gpio": 4,
      "thresholds": {
        "temp_max": 18, "temp_min": 5,
        "hum_max": 70,  "hum_min": 40
      }
    }
  ]
}
```

### Slave – `sensor-sender/config.json`

```json
{
  "master_url":   "http://pitemp.local:5000",
  "ingest_token": "sensormonitor2026",
  "room_id":      "r2",
  "room_name":    "Arbeitszimmer",
  "gpio_pin":     4,
  "interval_sec": 30,
  "simulation":   false
}
```

> 🔑 **Sicherheit:** Ändere `ingest_token` auf beiden Geräten auf den gleichen individuellen Wert.

---

## 🛠️ Fehlersuche

| Problem | Lösung |
|---|---|
| `kernel-command-line FAILED` | `firstboot.sh` fehlt oder falscher Name auf SD-Karte |
| `Unable to set line 4 to input` | Kernel-Treiber fehlt → `dtoverlay=dht11,gpiopin=4` in config.txt |
| `I/O error` beim IIO | VCC an 3,3V → auf 5V (Pi Pin 2) umstecken |
| Slave zeigt "Offline" | `journalctl -u sensor-sender -f` auf Pi 2 prüfen |
| `pitemp.local` nicht erreichbar | `sudo systemctl status avahi-daemon` |
| SSID nicht sichtbar | Ländercode-Problem → `firstboot.log` prüfen |

### Nützliche Befehle

```bash
# Master
sudo systemctl status sensor-tracker
journalctl -u sensor-tracker -f
cat /boot/firmware/firstboot.log

# Slave
sudo systemctl status sensor-sender
journalctl -u sensor-sender -f
cat /sys/bus/iio/devices/iio:device0/in_temp_input

# Setup wiederholen
rm /Volumes/bootfs/firstboot.done
# → Pi neu starten
```

---

## 🏗️ Entwicklungsgeschichte

Dieses Projekt entstand in mehreren Iterationen:

| Version | Was wurde gebaut |
|---|---|
| 0.0.1 | Erstes Dashboard, Captive Portal, mDNS |
| 0.1.x | Einstellungs-Seite, Raumverwaltung, Demo/Live-Toggle |
| 0.2.x | Analyse-Tab, Schimmelrisiko, Push-Benachrichtigungen |
| 0.3.x | Master/Slave Architektur, Token-Schutz |
| 0.4.x | Netzwerk-Tab, Store & Forward, Watchdog |
| 0.5.x | IIO-Kernel-Treiber, 5V-Fix, PYTHONUNBUFFERED, Chart-Redesign |

---

## 📋 Bekannte Einschränkungen

- Der **Pi Zero 1** ist zu langsam für Software-Polling des DHT22 → Kernel IIO-Treiber notwendig
- VCC muss an **5V** (nicht 3,3V) beim Pi Zero 1
- Nur **eine SD-Karte** pro Pi – kein Dual-Boot
- Dashboard läuft auf Port **5000** (kein HTTPS)

---

## 📄 Lizenz

MIT License – frei nutzbar, veränderbar und weiterzugeben.

---

## 👤 Autor

**Tobias Meier**
admin@secutobs.com

## ☕ Support If you find this project useful and want to say thanks, feel free to send a small donation in Bitcoin: **BTC:** 1ADFsY95oPRvVQ36yWcud8zM4qzZZDqf6F No pressure – a GitHub ⭐ star is also very much appreciated!

*Dieses Projekt wurde für den privaten Einsatz entwickelt und mit Hilfe von Claude (Anthropic) umgesetzt.*
