#!/bin/bash
# Zeilenenden-Fix (falls von Mac/Windows kopiert)
sed -i 's/\r//g' "$0" 2>/dev/null || true
# ═══════════════════════════════════════════════════════════════════════════
#  Sensor Monitor – SLAVE First Boot Setup
#  Version: 0.2.1  |  2026-03-24
#  Autor:   Tobias Meier <admin@secutobs.com>
#
#  Pi 2: Kein Dashboard, nur DHT22 lesen + Daten an Master senden
# ═══════════════════════════════════════════════════════════════════════════

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()  { echo -e "${RED}  ✕ $*${NC}"; }
info() { echo -e "  → $*"; }

HOTSPOT_SSID="SensorMonitor2"
HOTSPOT_PASS="sensor1234"
PROJECT_DIR="/home/pi/sensor-sender"
DONE_FLAG="/boot/firmware/firstboot.done"
PORTAL_DIR="/tmp/portal"
HOSTNAME_NEW="pitemp2"

[ -f "$DONE_FLAG" ] && { echo "Setup bereits abgeschlossen."; exit 0; }

# Sicherstellen dass Script ausführbar ist
chmod +x "$0" 2>/dev/null || true

# cmdline.txt SOFORT bereinigen
[ -f /boot/firmware/cmdline.txt ] && \
    sed -i 's| systemd\.run=[^ ]*||g' /boot/firmware/cmdline.txt 2>/dev/null || true

exec > >(tee /boot/firmware/firstboot.log) 2>&1

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  SENSOR MONITOR SLAVE – FIRST BOOT v0.2.1   ║${NC}"
echo -e "${BLUE}║  Pi 2 (Slave) – sendet an pitemp.local       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── Portal schreiben ───────────────────────────────────────────────────────
mkdir -p "$PORTAL_DIR"
cat > "$PORTAL_DIR/portal.py" << 'PYEOF'
#!/usr/bin/env python3
import os, subprocess, threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

DONE_FILE   = "/tmp/wlan_verbunden"
FEHLER_FILE = "/tmp/wlan_fehler"

CSS = (
    "<style>*{box-sizing:border-box;margin:0;padding:0}"
    "body{font-family:-apple-system,sans-serif;background:#f2f2f7;color:#1c1c1e;"
    "min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}"
    ".card{background:#fff;border-radius:22px;padding:36px 28px;width:100%;max-width:380px;"
    "box-shadow:0 4px 24px rgba(0,0,0,.1)}"
    ".icon{font-size:3rem;text-align:center;margin-bottom:8px}"
    "h1{font-size:1.5rem;font-weight:700;text-align:center;margin-bottom:4px}"
    ".sub{font-size:.88rem;color:#8e8e93;text-align:center;margin-bottom:24px}"
    "label{display:block;font-size:.78rem;font-weight:600;color:#8e8e93;"
    "text-transform:uppercase;letter-spacing:.3px;margin-bottom:6px}"
    ".field{margin-bottom:16px}"
    "input{width:100%;padding:14px 16px;border-radius:12px;"
    "border:1.5px solid rgba(60,60,67,.15);background:#f2f2f7;color:#1c1c1e;"
    "font-size:1rem;outline:none;-webkit-appearance:none}"
    "input:focus{border-color:#007aff}"
    ".btn{width:100%;padding:16px;border-radius:14px;border:none;"
    "background:#007aff;color:#fff;font-size:1rem;font-weight:600;cursor:pointer}"
    ".hint{font-size:.75rem;color:#8e8e93;text-align:center;margin-top:18px}"
    ".sw{display:none;text-align:center;padding:24px 0}"
    ".sp{width:36px;height:36px;border:3px solid #e5e5ea;"
    "border-top-color:#007aff;border-radius:50%;"
    "animation:sp .8s linear infinite;margin:0 auto 14px}"
    "@keyframes sp{to{transform:rotate(360deg)}}</style>"
)
JS = ("<script>function showSpin(){"
      "document.getElementById('fm').style.display='none';"
      "document.getElementById('sw').style.display='block';}</script>")

def verbinde_wlan(ssid, pw):
    import time
    time.sleep(1)
    try:
        subprocess.run(["nmcli","connection","down","SensorMonitor2-Hotspot"],
                       capture_output=True, timeout=10)
        time.sleep(3)
        subprocess.run(["nmcli","connection","delete",ssid],
                       capture_output=True, timeout=10)
        r = subprocess.run(
            ["nmcli","dev","wifi","connect",ssid,"password",pw,"ifname","wlan0"],
            capture_output=True, text=True, timeout=40)
        if r.returncode == 0:
            open(DONE_FILE,"w").write(ssid)
        else:
            open(FEHLER_FILE,"w").write(r.stderr.strip() or "Fehlgeschlagen")
    except Exception as e:
        open(FEHLER_FILE,"w").write(str(e))

def html_form(fehler=""):
    err = f'<div style="background:rgba(255,59,48,.1);color:#c0392b;border-radius:10px;padding:10px;margin-bottom:16px;font-size:.85rem">{fehler}</div>' if fehler else ""
    return ("<!DOCTYPE html><html lang='de'><head><meta charset='UTF-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>Sensor Slave Setup</title>" + CSS + "</head><body>"
            "<div class='card'><div class='icon'>📡</div>"
            "<h1>Sensor Slave</h1>"
            "<p class='sub'>Pi 2 – Arbeitszimmer<br>WLAN einrichten</p>" + err +
            "<div id='fm'><form method='POST' action='/verbinden' onsubmit='showSpin()'>"
            "<div class='field'><label>WLAN Name</label>"
            "<input type='text' name='ssid' required autocomplete='off' "
            "autocorrect='off' autocapitalize='none'></div>"
            "<div class='field'><label>Passwort</label>"
            "<input type='password' name='pw' required></div>"
            "<button type='submit' class='btn'>Verbinden →</button></form>"
            "<p class='hint'>Verbindet sich mit pitemp.local</p></div>"
            "<div class='sw' id='sw'><div class='sp'></div>"
            "<p>Verbinde...</p></div>" + JS + "</div></body></html>")

def html_ok(ssid):
    return ("<!DOCTYPE html><html><head><meta charset='UTF-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>Verbunden!</title>" + CSS + "</head><body>"
            "<div class='card' style='text-align:center'>"
            "<div class='icon'>✅</div><h1>Verbunden!</h1>"
            f"<p class='sub'>Mit <strong>{ssid}</strong> verbunden.<br>"
            "Jetzt wieder mit Heimnetz verbinden<br>und http://pitemp.local aufrufen.</p>"
            "</div></body></html>")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _html(self, code, html):
        b = html.encode()
        self.send_response(code)
        self.send_header("Content-Type","text/html;charset=utf-8")
        self.send_header("Content-Length",str(len(b)))
        self.send_header("Cache-Control","no-cache")
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        p = urlparse(self.path).path
        if p in ("/hotspot-detect.html","/generate_204","/ncsi.txt",
                 "/connecttest.txt","/redirect","/canonical.html"):
            self.send_response(302)
            self.send_header("Location","http://192.168.4.1/")
            self.end_headers(); return
        if os.path.exists(FEHLER_FILE):
            f = open(FEHLER_FILE).read(); os.remove(FEHLER_FILE)
            self._html(200, html_form(f)); return
        self._html(200, html_form())
    def do_POST(self):
        if urlparse(self.path).path != "/verbinden":
            self.send_response(302)
            self.send_header("Location","/"); self.end_headers(); return
        n = int(self.headers.get("Content-Length",0))
        p = parse_qs(self.rfile.read(n).decode("utf-8","replace"))
        ssid = p.get("ssid",[""])[0].strip()
        pw   = p.get("pw",  [""])[0].strip()
        if not ssid or len(pw) < 8:
            self._html(200, html_form("WLAN-Name oder Passwort ungültig")); return
        threading.Thread(target=verbinde_wlan,args=(ssid,pw),daemon=True).start()
        self._html(200, html_ok(ssid))

if __name__ == "__main__":
    try:
        HTTPServer(("0.0.0.0",80),H).serve_forever()
    except OSError:
        HTTPServer(("0.0.0.0",8080),H).serve_forever()
PYEOF

# ── Phase 1: WLAN ─────────────────────────────────────────────────────────
echo ""; echo "── Phase 1: WLAN ──"

wlan_ok() { ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; }

info "Warte auf NetworkManager..."
systemctl start NetworkManager 2>/dev/null || true
for i in $(seq 1 30); do
    systemctl is-active --quiet NetworkManager && break
    sleep 2
done
ok "NetworkManager läuft"
sleep 3

# Ländercode
iw reg set DE 2>/dev/null || true
raspi-config nonint do_wifi_country DE 2>/dev/null || true
echo 'REGDOMAIN=DE' > /etc/default/crda 2>/dev/null || true

if wlan_ok; then
    ok "WLAN bereits verbunden"
else
    info "Starte Hotspot '$HOTSPOT_SSID'..."
    nmcli connection delete "SensorMonitor2-Hotspot" 2>/dev/null || true

    # Ländercode: Treiber neu laden
    rmmod brcmfmac 2>/dev/null || true
    sleep 2
    modprobe brcmfmac 2>/dev/null || true
    sleep 3
    nmcli radio wifi on 2>/dev/null || true
    sleep 3

    nmcli connection add \
        type wifi ifname wlan0 \
        con-name "SensorMonitor2-Hotspot" \
        autoconnect no ssid "$HOTSPOT_SSID" \
        mode ap ipv4.method shared \
        ipv4.addresses "192.168.4.1/24" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "$HOTSPOT_PASS" \
        wifi-sec.pmf 1 \
        802-11-wireless.band bg \
        802-11-wireless.channel 6 2>&1 | sed 's/^/  [add] /'

    for try in 1 2 3 4 5; do
        info "Hotspot-Start Versuch $try/5..."
        if nmcli connection up "SensorMonitor2-Hotspot" 2>&1; then
            break
        fi
        ip link set wlan0 down 2>/dev/null || true; sleep 3
        ip link set wlan0 up   2>/dev/null || true; sleep 5
    done

    sleep 4
    IW_MODE=$(iw dev wlan0 info 2>/dev/null | awk '/type/{print $2}')
    [ "$IW_MODE" = "AP" ] && ok "Hotspot aktiv – SSID wird gesendet" || \
        warn "Hotspot Modus: '$IW_MODE'"

    python3 "$PORTAL_DIR/portal.py" &
    PORTAL_PID=$!
    sleep 2

    echo ""
    echo "  ┌─────────────────────────────────────┐"
    echo "  │  WLAN:     $HOTSPOT_SSID             │"
    echo "  │  Passwort: $HOTSPOT_PASS             │"
    echo "  │  URL:      http://192.168.4.1        │"
    echo "  └─────────────────────────────────────┘"
    echo ""

    TIMEOUT=900; ELAPSED=0
    while [ ! -f /tmp/wlan_verbunden ] && [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 5; ELAPSED=$((ELAPSED+5))
        [ $((ELAPSED%60)) -eq 0 ] && info "Warte... (${ELAPSED}s)"
    done

    kill "$PORTAL_PID" 2>/dev/null || true
    nmcli connection delete "SensorMonitor2-Hotspot" 2>/dev/null || true

    [ ! -f /tmp/wlan_verbunden ] && { err "Timeout – Neustart"; sleep 5; reboot; exit 0; }
    SSID_OK=$(cat /tmp/wlan_verbunden)
    ok "WLAN verbunden: $SSID_OK"
    sleep 5
fi

for i in $(seq 1 30); do wlan_ok && break; sleep 5; done

# ── Phase 2: Pakete ────────────────────────────────────────────────────────
echo ""; echo "── Phase 2: Pakete ──"
export DEBIAN_FRONTEND=noninteractive

timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Europe/Berlin 2>/dev/null || true
echo 'Europe/Berlin' > /etc/timezone 2>/dev/null || true

HTTP_DATE=$(curl -sI --connect-timeout 5 http://google.com 2>/dev/null \
    | grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //')
[ -n "$HTTP_DATE" ] && date -s "$HTTP_DATE" 2>/dev/null || true
sleep 3

apt-get update -qq \
    -o Acquire::Check-Valid-Until=false \
    -o Acquire::AllowReleaseInfoChange=true 2>/dev/null || true

apt-get install -y -qq python3 python3-pip 2>/dev/null || warn "Paket-Fehler"

pip3 install --break-system-packages --quiet \
    adafruit-circuitpython-dht RPi.GPIO 2>/dev/null || warn "pip Fehler"

ok "Pakete installiert"

# ── Phase 3: Sender installieren ──────────────────────────────────────────
echo ""; echo "── Phase 3: Sender installieren ──"
mkdir -p "$PROJECT_DIR"

for FILE in sender.py config.json sensor-sender.service; do
    [ -f "/boot/firmware/sensor-sender/$FILE" ] && \
        cp "/boot/firmware/sensor-sender/$FILE" \
           "$( [ "$FILE" = "sensor-sender.service" ] && echo /etc/systemd/system/ || echo "$PROJECT_DIR/" )" || \
        warn "Fehlt: $FILE"
done

chown -R pi:pi "$PROJECT_DIR" 2>/dev/null || true

# Hostname
hostnamectl set-hostname "$HOSTNAME_NEW" 2>/dev/null || true
grep -q "$HOSTNAME_NEW" /etc/hosts || \
    echo "127.0.1.1  ${HOSTNAME_NEW}.local  ${HOSTNAME_NEW}" >> /etc/hosts

# userconfig.service deaktivieren
systemctl disable userconfig 2>/dev/null || true
systemctl mask    userconfig 2>/dev/null || true

systemctl daemon-reload
systemctl enable sensor-sender
systemctl start  sensor-sender
sleep 5
systemctl is-active --quiet sensor-sender && ok "Sender aktiv" || \
    warn "Sender prüfen: journalctl -u sensor-sender -n 20"

rm -rf /tmp/portal /tmp/wlan_verbunden /tmp/wlan_fehler 2>/dev/null || true
touch "$DONE_FLAG"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   SLAVE SETUP ABGESCHLOSSEN ✓  v0.2.1       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo -e "  Pi 2 IP:  ${BLUE}${IP}${NC}"
echo -e "  Dashboard:${BLUE} http://pitemp.local${NC}  (Pi 1)"
echo ""
echo "  Neustart in 5 Sekunden..."
sleep 5
reboot
