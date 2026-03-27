#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  Sensor Monitor – First Boot Setup
#  Version: 3.1.0  |  2026-03-24
#  Autor:   Tobias Meier <admin@secutobs.com>
#  Plattform: Raspberry Pi Zero 1 · 32-bit OS Lite · BCM43438
#
#  Fix v0.5.0:
#  - KEIN rmmod/modprobe mehr (hat wlan0 für NM unsichtbar gemacht)
#  - Ländercode via iw + cfg80211.conf (ohne Treiber-Reload)
#  - nmcli device set wlan0 managed true nach jedem Schritt
#  - Warten bis wlan0 in NM nicht mehr "unavailable"
# ═══════════════════════════════════════════════════════════════════════════

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()  { echo -e "${RED}  ✕ $*${NC}"; }
info() { echo -e "  → $*"; }
chk()  { echo -e "${BLUE}  ● $*${NC}"; }

HOTSPOT_SSID="SensorMonitor"
HOTSPOT_PASS="sensor1234"
PROJECT_DIR="/home/pi/sensor-tracker"
DONE_FLAG="/boot/firmware/firstboot.done"
PORTAL_DIR="/tmp/portal"
HOSTNAME_NEW="pitemp"

[ -f "$DONE_FLAG" ] && { echo "Setup bereits abgeschlossen."; exit 0; }

# cmdline.txt SOFORT bereinigen (VOR dem Log-Start!)
# Verhindert endlose Neustart-Schleife wenn Script neu gestartet wird
[ -f /boot/firmware/cmdline.txt ] && \
    sed -i 's| systemd\.run=[^ ]*||g' /boot/firmware/cmdline.txt 2>/dev/null || true

exec > >(tee /boot/firmware/firstboot.log) 2>&1

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   SENSOR MONITOR – FIRST BOOT v0.5.0        ║${NC}"
echo -e "${BLUE}║   $(date '+%Y-%m-%d %H:%M:%S') | Tobias Meier         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ══════════════════════════════════════════════════════════════════
#  SCHRITT 1: Ländercode setzen (OHNE Treiber-Reload!)
# ══════════════════════════════════════════════════════════════════
chk "Schritt 1: Ländercode DE setzen"

# cfg80211 Modul-Parameter (dauerhaft, kein Treiber-Reload nötig)
mkdir -p /etc/modprobe.d
echo 'options cfg80211 ieee80211_regdom=DE' > /etc/modprobe.d/cfg80211.conf
echo 'options brcmfmac roamoff=1' >> /etc/modprobe.d/cfg80211.conf

# Sofort wirksam
iw reg set DE 2>/dev/null && info "iw reg set DE: OK" || warn "iw reg set fehlgeschlagen"

# raspi-config (schreibt in /etc/default/crda und wpa_supplicant.conf)
raspi-config nonint do_wifi_country DE 2>/dev/null && \
    info "raspi-config: OK" || warn "raspi-config fehlgeschlagen (ignorierbar)"

# wpa_supplicant.conf
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
if [ -f "$WPA_CONF" ]; then
    grep -q "^country=" "$WPA_CONF" && \
        sed -i 's/^country=.*/country=DE/' "$WPA_CONF" || \
        sed -i '1s/^/country=DE\n/' "$WPA_CONF"
else
    printf 'country=DE\nctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\n' \
        > "$WPA_CONF"
fi

CC=$(iw reg get 2>/dev/null | awk '/^country/{print $2}' | tr -d ':')
info "Ländercode jetzt: '${CC:-unbekannt}'"

# ══════════════════════════════════════════════════════════════════
#  SCHRITT 2: NetworkManager bereit machen
# ══════════════════════════════════════════════════════════════════
chk "Schritt 2: NetworkManager"
systemctl start NetworkManager 2>/dev/null || true
for i in $(seq 1 30); do
    systemctl is-active --quiet NetworkManager && break
    sleep 2
done
systemctl is-active --quiet NetworkManager && ok "NM läuft" || \
    { warn "NM startet nicht – warte weitere 20s"; sleep 20; }
sleep 3

# ══════════════════════════════════════════════════════════════════
#  SCHRITT 3: wlan0 für NM verfügbar machen
# ══════════════════════════════════════════════════════════════════
chk "Schritt 3: wlan0 verfügbar machen"

# Wlan0 Interface Status
IW=$(ip link show wlan0 2>/dev/null | head -1)
info "wlan0 Interface: ${IW:-NICHT GEFUNDEN}"

# wpa_supplicant stoppen – aber NM bekommt das Interface zurück
systemctl stop    wpa_supplicant 2>/dev/null || true
systemctl disable wpa_supplicant 2>/dev/null || true
sleep 2

# NM mitteilen: wlan0 gehört dir!
nmcli device set wlan0 managed true 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true
sleep 3

# Warten bis wlan0 in NM NICHT mehr "unavailable" ist (max 30s)
info "Warte bis wlan0 in NM verfügbar..."
for i in $(seq 1 15); do
    STATE=$(nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | cut -d: -f2)
    if ! echo "$STATE" | grep -qi "unavailable\|unmanaged"; then
        info "wlan0 NM-State: '$STATE' ✓"
        break
    fi
    info "wlan0 noch '$STATE' – warte... ($i/15)"
    nmcli device set wlan0 managed true 2>/dev/null || true
    sleep 2
done

STATE_FINAL=$(nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | cut -d: -f2)
info "wlan0 finaler State: '$STATE_FINAL'"
IW_TYPE=$(iw dev wlan0 info 2>/dev/null | awk '/type/{print $2}')
info "iw type: '${IW_TYPE}'"

# ══════════════════════════════════════════════════════════════════
#  PORTAL schreiben (vor Phase 1)
# ══════════════════════════════════════════════════════════════════
mkdir -p "$PORTAL_DIR"
cat > "$PORTAL_DIR/portal.py" << 'PYEOF'
#!/usr/bin/env python3
import os, subprocess, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

DONE_FILE   = "/tmp/wlan_verbunden"
FEHLER_FILE = "/tmp/wlan_fehler"

CSS = (
    "<style>:root{--bg:#f2f2f7;--card:#fff;--tx:#1c1c1e;--mu:#8e8e93;"
    "--bl:#007aff;--sep:rgba(60,60,67,.15);--rd:#ff3b30}"
    "@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;"
    "--tx:#fff;--mu:#636366;--sep:rgba(255,255,255,.1)}}"
    "*{box-sizing:border-box;margin:0;padding:0}"
    "body{background:var(--bg);color:var(--tx);"
    "font-family:-apple-system,'Helvetica Neue',sans-serif;"
    "min-height:100vh;display:flex;align-items:center;"
    "justify-content:center;padding:20px}"
    ".card{background:var(--card);border-radius:22px;padding:36px 28px;"
    "width:100%;max-width:380px;box-shadow:0 8px 40px rgba(0,0,0,.1)}"
    ".icon{font-size:3rem;text-align:center;margin-bottom:8px}"
    "h1{font-size:1.5rem;font-weight:700;text-align:center;margin-bottom:6px}"
    ".sub{font-size:.88rem;color:var(--mu);text-align:center;margin-bottom:28px}"
    "label{display:block;font-size:.78rem;font-weight:600;color:var(--mu);"
    "margin-bottom:6px;text-transform:uppercase}"
    ".field{margin-bottom:16px}"
    "input{width:100%;padding:14px 16px;border-radius:12px;"
    "border:1.5px solid var(--sep);background:var(--bg);color:var(--tx);"
    "font-size:1rem;outline:none;-webkit-appearance:none}"
    "input:focus{border-color:var(--bl)}"
    ".btn{width:100%;padding:16px;border-radius:14px;border:none;"
    "background:var(--bl);color:#fff;font-size:1rem;font-weight:600;cursor:pointer}"
    ".err{background:rgba(255,59,48,.1);color:var(--rd);"
    "border-radius:10px;padding:12px;font-size:.85rem;"
    "margin-bottom:16px;text-align:center}"
    ".hint{font-size:.75rem;color:var(--mu);text-align:center;margin-top:18px}"
    ".sw{display:none;text-align:center;padding:24px 0}"
    ".sp{width:36px;height:36px;border:3px solid var(--sep);"
    "border-top-color:var(--bl);border-radius:50%;"
    "animation:sp .8s linear infinite;margin:0 auto 14px}"
    "@keyframes sp{to{transform:rotate(360deg)}}</style>"
)
JS = ("<script>function showSpin(){"
      "document.getElementById('fm').style.display='none';"
      "document.getElementById('sw').style.display='block';}</script>")

def verbinde_wlan(ssid, passwort):
    import time as _t
    try:
        # KRITISCH: Hotspot ZUERST beenden, DANN verbinden!
        # (Vorher schlugt nmcli connect fehl weil Hotspot noch aktiv war)
        subprocess.run(["nmcli","connection","down","SensorMonitor-Hotspot"],
                       capture_output=True, timeout=10)
        _t.sleep(3)
        subprocess.run(["nmcli","connection","delete",ssid],
                       capture_output=True, timeout=10)
        _t.sleep(1)
        r = subprocess.run(
            ["nmcli","dev","wifi","connect",ssid,
             "password",passwort,"ifname","wlan0"],
            capture_output=True, text=True, timeout=40)
        if r.returncode == 0:
            open(DONE_FILE,"w").write(ssid)
        else:
            open(FEHLER_FILE,"w").write(r.stderr.strip() or r.stdout.strip() or "Fehlgeschlagen")
    except subprocess.TimeoutExpired:
        open(FEHLER_FILE,"w").write("Timeout")
    except Exception as e:
        open(FEHLER_FILE,"w").write(str(e))

def html_form(fehler=""):
    err = f'<div class="err">&#9888; {fehler}</div>' if fehler else ""
    return (
        "<!DOCTYPE html><html lang='de'><head><meta charset='UTF-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<title>Sensor Monitor Setup</title>" + CSS + "</head><body>"
        "<div class='card'><div class='icon'>&#x1F321;&#xFE0F;</div>"
        "<h1>Sensor Monitor</h1>"
        "<p class='sub'>WLAN-Zugangsdaten eingeben</p>" + err +
        "<div id='fm'><form method='POST' action='/verbinden' onsubmit='showSpin()'>"
        "<div class='field'><label>WLAN Name (SSID)</label>"
        "<input type='text' name='ssid' placeholder='z.B. FritzBox 7590' required "
        "autocomplete='off' autocorrect='off' autocapitalize='none' spellcheck='false'></div>"
        "<div class='field'><label>WLAN Passwort</label>"
        "<input type='password' name='pw' placeholder='Passwort eingeben' required></div>"
        "<button type='submit' class='btn'>Verbinden &#x2192;</button></form>"
        "<p class='hint'>Hotspot schaltet sich nach Verbindung automatisch ab</p></div>"
        "<div class='sw' id='sw'><div class='sp'></div>"
        "<p>Verbinde...<br><small>Bitte ~30 Sekunden warten</small></p></div>"
        + JS + "</div></body></html>")

def html_ok(ssid):
    return (
        "<!DOCTYPE html><html lang='de'><head><meta charset='UTF-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<title>Verbunden!</title>" + CSS + "</head><body>"
        "<div class='card' style='text-align:center'>"
        "<div class='icon'>&#x2705;</div><h1>Verbunden!</h1>"
        "<p class='sub'>Verbinde jetzt wieder mit<br>"
        f"<strong>{ssid}</strong></p>"
        "<div style='background:rgba(0,0,0,.04);border-radius:14px;"
        "padding:18px;margin-top:20px;font-size:.85rem;color:var(--mu);"
        "line-height:2;text-align:left'>"
        "<div><b>1.</b> Einstellungen &#x2192; WLAN</div>"
        f"<div><b>2.</b> Mit <b>{ssid}</b> verbinden</div>"
        "<div><b>3.</b> Browser: http://sensor.local</div>"
        "<div><b>4.</b> Ca. 3-5 Min warten</div>"
        "</div></div></body></html>")

class Portal(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass
    def _redir(self):
        self.send_response(302)
        self.send_header("Location","http://192.168.4.1/")
        self.end_headers()
    def _html(self, html, st=200):
        b = html.encode("utf-8")
        self.send_response(st)
        self.send_header("Content-Type","text/html; charset=utf-8")
        self.send_header("Content-Length",str(len(b)))
        self.send_header("Cache-Control","no-cache,no-store")
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        p = urlparse(self.path).path
        if p in ("/hotspot-detect.html","/library/test/success.html",
                 "/generate_204","/connecttest.txt","/ncsi.txt",
                 "/redirect","/canonical.html","/bag"):
            self._redir(); return
        if os.path.exists(FEHLER_FILE):
            f = open(FEHLER_FILE).read().strip()
            os.remove(FEHLER_FILE)
            self._html(html_form(f)); return
        self._html(html_form())
    def do_POST(self):
        if urlparse(self.path).path != "/verbinden":
            self._redir(); return
        n = int(self.headers.get("Content-Length",0))
        p = parse_qs(self.rfile.read(n).decode("utf-8","replace"))
        ssid = p.get("ssid",[""])[0].strip()
        pw   = p.get("pw",  [""])[0].strip()
        if not ssid or len(pw) < 8:
            self._html(html_form("WLAN-Name oder Passwort ungültig")); return
        threading.Thread(target=verbinde_wlan,args=(ssid,pw),daemon=True).start()
        self._html(html_ok(ssid))

if __name__ == "__main__":
    try:
        HTTPServer(("0.0.0.0",80),Portal).serve_forever()
    except OSError:
        HTTPServer(("0.0.0.0",8080),Portal).serve_forever()
PYEOF

# ══════════════════════════════════════════════════════════════════
#  PHASE 1 – WLAN
# ══════════════════════════════════════════════════════════════════
echo ""; echo "── Phase 1: WLAN ──"
wlan_ok() { ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; }

if wlan_ok; then
    ok "WLAN bereits verbunden"
else
    info "Kein Internet – starte Hotspot..."

    # Alte Verbindungen löschen
    nmcli connection delete "SensorMonitor-Hotspot" 2>/dev/null || true
    sleep 1

    # Hotspot anlegen – exakt wie Zisterne v0.5.0
    nmcli connection add \
        type wifi \
        ifname wlan0 \
        con-name "SensorMonitor-Hotspot" \
        autoconnect no \
        ssid "$HOTSPOT_SSID" \
        mode ap \
        ipv4.method shared \
        ipv4.addresses "192.168.4.1/24" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$HOTSPOT_PASS" \
        wifi-sec.pmf 1 \
        802-11-wireless.band bg \
        802-11-wireless.channel 6 2>&1 | sed 's/^/  [add] /'

    # Bis zu 5 Versuche
    HOTSPOT_OK=0
    for try in 1 2 3 4 5; do
        info "Versuch $try/5..."
        RESULT=$(nmcli connection up "SensorMonitor-Hotspot" 2>&1)
        echo "$RESULT" | sed "s/^/  [up$try] /"
        if echo "$RESULT" | grep -q "successfully activated"; then
            HOTSPOT_OK=1; break
        fi
        # wlan0 wieder managed machen und retry
        nmcli device set wlan0 managed true 2>/dev/null || true
        ip link set wlan0 down 2>/dev/null || true
        sleep 2
        ip link set wlan0 up   2>/dev/null || true
        nmcli device set wlan0 managed true 2>/dev/null || true
        sleep 4
    done

    # AP-Modus verifizieren
    IW_MODE=$(iw dev wlan0 info 2>/dev/null | awk '/type/{print $2}')
    NM_STATE=$(nmcli -t -f GENERAL.STATE dev show wlan0 2>/dev/null | cut -d: -f2)
    info "iw type:  '$IW_MODE'"
    info "NM State: '$NM_STATE'"

    [ "$IW_MODE" = "AP" ] && ok "wlan0 im AP-Modus – SSID wird gesendet!" || \
        warn "wlan0 Modus: '$IW_MODE' (erwartet: AP)"

    if [ $HOTSPOT_OK -eq 0 ]; then
        err "Hotspot fehlgeschlagen – Log: /boot/firmware/firstboot.log"
        sleep 15; reboot; exit 0
    fi

    sleep 4
    ok "Hotspot '$HOTSPOT_SSID' aktiv | Passwort: $HOTSPOT_PASS"

    # Portal starten
    python3 "$PORTAL_DIR/portal.py" &
    PORTAL_PID=$!
    sleep 2
    kill -0 "$PORTAL_PID" 2>/dev/null && \
        ok "Portal aktiv (PID $PORTAL_PID)" || warn "Portal-Start fehlgeschlagen"

    echo ""
    echo "  ┌────────────────────────────────────────┐"
    echo "  │  WLAN:     SensorMonitor               │"
    echo "  │  Passwort: sensor1234                  │"
    echo "  │  URL:      http://192.168.4.1          │"
    echo "  └────────────────────────────────────────┘"
    echo ""

    # Warten auf /tmp/wlan_verbunden
    TIMEOUT=900; ELAPSED=0
    while [ ! -f /tmp/wlan_verbunden ] && [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 5; ELAPSED=$((ELAPSED+5))
        [ $((ELAPSED%60)) -eq 0 ] && info "Warte... (${ELAPSED}s/${TIMEOUT}s)"
    done

    kill "$PORTAL_PID" 2>/dev/null || true
    nmcli connection delete "SensorMonitor-Hotspot" 2>/dev/null || true

    if [ ! -f /tmp/wlan_verbunden ]; then
        err "Timeout – Pi startet neu"; sleep 5; reboot; exit 0
    fi
    ok "WLAN verbunden: $(cat /tmp/wlan_verbunden)"
    sleep 5
fi

# Internet sicherstellen
for i in $(seq 1 30); do
    wlan_ok && { ok "Internet OK"; break; }
    sleep 5
    [ $i -eq 30 ] && { err "Kein Internet – Neustart"; sleep 5; reboot; exit 0; }
done

# ══════════════════════════════════════════════════════════════════
#  PHASE 2 – PAKETE
# ══════════════════════════════════════════════════════════════════
echo ""; echo "── Phase 2: Pakete ──"
export DEBIAN_FRONTEND=noninteractive

info "Systemzeit korrigieren (kritisch fuer apt-Signaturen)..."

# Methode 1: timedatectl NTP
timedatectl set-ntp true 2>/dev/null || true
sleep 5

# Methode 2: Datum via HTTP-Header (funktioniert ohne NTP)
HTTP_DATE=$(curl -sI --connect-timeout 5 http://google.com 2>/dev/null \
    | grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //')
if [ -n "$HTTP_DATE" ]; then
    date -s "$HTTP_DATE" 2>/dev/null && \
        info "Datum via HTTP gesetzt: $(date)" || true
fi

# Methode 3: chrony installieren und sync
apt-get install -y -qq chrony 2>/dev/null || true
chronyc makestep 2>/dev/null || true
sleep 3

# Zeitzone Europe/Berlin setzen (alle Methoden)
timedatectl set-timezone Europe/Berlin 2>/dev/null || true
echo 'Europe/Berlin' > /etc/timezone
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime 2>/dev/null || true
dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true
ok "Aktuelle Zeit: $(date)  [TZ: $(cat /etc/timezone)]"

# Sicherheitscheck: Jahr muss >= 2025 sein
YEAR=$(date +%Y)
if [ "$YEAR" -lt 2025 ]; then
    warn "Datum falsch (Jahr: $YEAR) – setze manuell..."
    date -s "2026-03-24 08:00:00" 2>/dev/null || true
    ok "Manuell gesetzt: $(date)"
fi

apt-get update -qq \
    -o Acquire::Check-Valid-Until=false \
    -o Acquire::AllowReleaseInfoChange=true \
    -o Acquire::http::Timeout=60 2>/dev/null || \
    { warn "apt update – nochmal..."
      sleep 10
      apt-get update -qq \
        -o Acquire::Check-Valid-Until=false \
        -o Acquire::AllowReleaseInfoChange=true 2>/dev/null || true; }

apt-get install -y -qq python3 python3-pip sqlite3 \
    avahi-daemon avahi-utils libnss-mdns 2>/dev/null || warn "Paket-Fehler"

grep -q "^hosts:" /etc/nsswitch.conf && \
    ! grep -q "mdns4_minimal" /etc/nsswitch.conf && \
    sed -i 's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
systemctl enable avahi-daemon 2>/dev/null; systemctl restart avahi-daemon 2>/dev/null
ok "avahi → http://sensor.local"

pip3 install --break-system-packages --quiet \
    flask adafruit-circuitpython-dht RPi.GPIO 2>/dev/null || \
    pip3 install --break-system-packages \
    flask adafruit-circuitpython-dht RPi.GPIO 2>/dev/null || warn "pip Fehler"
ok "Pakete installiert"

# ══════════════════════════════════════════════════════════════════
#  PHASE 3 – APP
# ══════════════════════════════════════════════════════════════════
echo ""; echo "── Phase 3: App ──"
mkdir -p "$PROJECT_DIR/templates"
for FILE in app.py requirements.txt VERSION; do
    [ -f "/boot/firmware/sensor-tracker/$FILE" ] && \
        cp "/boot/firmware/sensor-tracker/$FILE" "$PROJECT_DIR/" || warn "Fehlt: $FILE"
done
[ -f "/boot/firmware/sensor-tracker/templates/index.html" ] && \
    cp /boot/firmware/sensor-tracker/templates/index.html "$PROJECT_DIR/templates/"
# Static-Dateien (SVG, Icons)
if [ -d "/boot/firmware/sensor-tracker/static" ]; then
    mkdir -p "$PROJECT_DIR/static"
    cp -r /boot/firmware/sensor-tracker/static/. "$PROJECT_DIR/static/"
    ok "Static-Dateien kopiert"
fi
chown -R pi:pi "$PROJECT_DIR" 2>/dev/null || true
ok "App-Dateien kopiert"

cat > /etc/systemd/system/sensor-tracker.service << 'SVCEOF'
[Unit]
Description=Sensor Monitor
After=network-online.target avahi-daemon.service
Wants=network-online.target avahi-daemon.service
[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/sensor-tracker
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/python3 /home/pi/sensor-tracker/app.py
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable sensor-tracker
systemctl start  sensor-tracker
sleep 6
systemctl is-active --quiet sensor-tracker && ok "Service aktiv" || \
    warn "journalctl -u sensor-tracker -n 20"

hostnamectl set-hostname "$HOSTNAME_NEW" 2>/dev/null || true

# userconfig.service deaktivieren (Pi OS Bookworm Bug)
systemctl disable userconfig 2>/dev/null || true
systemctl mask    userconfig 2>/dev/null || true
grep -q "$HOSTNAME_NEW" /etc/hosts 2>/dev/null || \
    echo "127.0.1.1  ${HOSTNAME_NEW}.local  ${HOSTNAME_NEW}" >> /etc/hosts

rm -rf /tmp/portal /tmp/wlan_verbunden /tmp/wlan_fehler 2>/dev/null || true
touch "$DONE_FLAG"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   FIRST BOOT ABGESCHLOSSEN ✓  v0.5.0        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo -e "  ${BLUE}http://sensor.local${NC}"
[ -n "$IP" ] && echo -e "  ${BLUE}http://${IP}:5000${NC}"
echo ""; echo "  Neustart in 5 Sekunden..."
sleep 5
reboot
