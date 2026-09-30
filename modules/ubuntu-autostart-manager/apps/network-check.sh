#!/usr/bin/env bash
set -u

# ------------------------------------------------------------
# Uwuntu: interne Displayhelligkeit bei jedem App-Start auf 100 %
# ------------------------------------------------------------
uwuntu_set_display_brightness_100() {
    if command -v brightnessctl >/dev/null 2>&1; then
        brightnessctl -q set 100% >/dev/null 2>&1 && return 0
    fi

    local dev max brightness_file
    for dev in /sys/class/backlight/*; do
        [ -d "$dev" ] || continue

        max="$(cat "$dev/max_brightness" 2>/dev/null || true)"
        brightness_file="$dev/brightness"
        [ -n "$max" ] || continue

        if [ -w "$brightness_file" ]; then
            printf '%s\n' "$max" > "$brightness_file" 2>/dev/null || true
        elif command -v sudo >/dev/null 2>&1 \
            && sudo -n true >/dev/null 2>&1
        then
            printf '%s\n' "$max" \
                | sudo -n tee "$brightness_file" >/dev/null 2>&1 || true
        fi
    done

    return 0
}

uwuntu_set_display_brightness_100 >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Uwuntu: Ubuntu-Dock/Taskleiste automatisch ausblenden
# Position (z. B. LEFT) wird bewusst NICHT verändert.
# ------------------------------------------------------------
uwuntu_set_dock_autohide() {
    command -v gsettings >/dev/null 2>&1 || return 0

    local schema="org.gnome.shell.extensions.dash-to-dock"

    if ! gsettings list-schemas 2>/dev/null \
        | grep -Fxq "$schema"
    then
        return 0
    fi

    # Nicht dauerhaft sichtbar.
    gsettings set "$schema" dock-fixed false \
        >/dev/null 2>&1 || true

    # Klassisches Auto-Hide: Dock bleibt eingeklappt und erscheint
    # bei Bedarf am Bildschirmrand.
    gsettings set "$schema" autohide true \
        >/dev/null 2>&1 || true

    # Nicht nur bei überlappenden Fenstern ausblenden, sondern generell.
    gsettings set "$schema" intellihide false \
        >/dev/null 2>&1 || true

    return 0
}

uwuntu_set_dock_autohide >/dev/null 2>&1 || true
# ============================================================
# Network Check - separater Test
# ============================================================
# - Verändert den bestehenden Kiosk / Autostart NICHT
# - Eigenes GTK4-Fenster
# - LAN und WLAN getrennt
# - Live Download / Upload
# - Automatischer Test beim Start NUR für die aktive Verbindung
# - Automatischer Test bei Verbindungswechsel
# - REFRESH = nur die aktuell aktive LAN/WLAN-Verbindung neu testen
# - EXIT = Programm beenden
#
# Ablauf:
#   LINK -> kurzer PING -> DOWNLOAD -> UPLOAD
# Speedtest:
#   Download: Datalix Looking Glass Frankfurt
#   Upload:   Cloudflare /__up
# ============================================================
need_install=0

if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
    need_install=1
fi

for cmd in curl nmcli ip ping iw upower lsblk wipefs partprobe smartctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        need_install=1
    fi
done

if [ "$need_install" -eq 1 ]; then
    echo "Einige kleine Abhängigkeiten fehlen."
    echo "Installiere GTK-Python, Netzwerk- und Wipe-Abhängigkeiten ..."
    if sudo -n true 2>/dev/null; then
        sudo -n apt-get update || exit 1
        sudo -n apt-get install -y \
            python3-gi gir1.2-gtk-4.0 curl network-manager iproute2 iputils-ping iw upower util-linux parted psmisc smartmontools
    else
        sudo apt-get update || exit 1
        sudo apt-get install -y \
            python3-gi gir1.2-gtk-4.0 curl network-manager iproute2 iputils-ping iw upower util-linux parted psmisc smartmontools
    fi
fi

if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
    echo "FEHLER: GTK4/Python ist nicht verfügbar."
    exit 10
fi
for cmd in curl nmcli ip ping; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FEHLER: $cmd fehlt."
        exit 11
    fi
done

# ------------------------------------------------------------
# GNOME-/Taskleisten-Identität des kombinierten Fensters
# ------------------------------------------------------------
# Die sichtbare Fenstertitelleiste enthält weiterhin Versionsnummern.
# Im Dock/Favoriten-Hover bleibt der App-Name bewusst kurz und ohne Versionen.
NETWORK_DESKTOP_DIR="$HOME/.local/share/applications"
NETWORK_DESKTOP_FILE="$NETWORK_DESKTOP_DIR/com.david.NetworkCheck.desktop"

mkdir -p "$NETWORK_DESKTOP_DIR"
cat > "$NETWORK_DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Network Check + Wipe Auto + Audio Test
Comment=Uwuntu Netzwerk-, Wipe- und Audio-Diagnose
Exec=$HOME/.local/bin/network-check.sh
Icon=network-transmit-receive-symbolic
Terminal=false
StartupNotify=true
StartupWMClass=com.david.NetworkCheck
Categories=Utility;System;
NoDisplay=false
EOF
chmod 0644 "$NETWORK_DESKTOP_FILE"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$NETWORK_DESKTOP_DIR" >/dev/null 2>&1 || true
fi

TMP_PY="$(mktemp /tmp/network-check-XXXXXX.py)"
trap 'rm -f "$TMP_PY"' EXIT

cat > "$TMP_PY" <<'PY'
#!/usr/bin/env python3

import gi
gi.require_version("Gtk", "4.0")

from gi.repository import Gtk, GLib, Gdk, Pango, Gio

import os
import re
import json
import signal
import subprocess
import threading
import time
import queue
import math
from datetime import datetime
from pathlib import Path
VERSION = "2.64"
# ============================================================
# EINSTELLUNGEN
# Diese Grenzwerte sind für den ersten Praxistest bewusst
# einfach gehalten und können später angepasst werden.
# ============================================================

# Harte LAN-Regel:
LAN_LINK_MIN = 1000.0       # Mbps

# WLAN-Link: vorläufiger Mindestwert
WIFI_LINK_MIN = 100.0       # Mbps
# Internet-Durchsatz: vorläufige PASS-Grenzen
LAN_DOWNLOAD_MIN = 800.0    # Mbps
LAN_UPLOAD_MIN = 800.0      # Mbps
WIFI_DOWNLOAD_MIN = 50.0    # Mbps
WIFI_UPLOAD_MIN = 100.0     # Mbps

# Einheitliche Farbabstufung:
# Grün = Zielwert erreicht
# Orange = noch brauchbar, mindestens 70 % des Zielwerts
# Rot = darunter
NETWORK_WARN_FACTOR = 0.70

# Ping-Farben
PING_GOOD_MAX_MS = 40.0
PING_WARN_MAX_MS = 100.0

# Je Richtung maximal ungefähr 2,5 Sekunden.
# Gesamttest pro Verbindung damit ungefähr 5 Sekunden.
PHASE_SECONDS = 5.0
SAMPLE_SECONDS = 0.25
# Mehrere parallele Transfers sättigen schnelle Gigabit-Leitungen.
#
# Download:
# 4 parallele Streams gegen eine 10-GB-Testdatei in Frankfurt.
# Kein Stream kann innerhalb unserer 5 Sekunden fertig werden.
DOWNLOAD_STREAMS = 4
#
# Upload:
# 4 Streams reichen; jeder Stream bekommt 250 MB Daten angeboten.
# Bei insgesamt 1 Gbit/s wird auch davon keiner innerhalb von 5 Sekunden fertig.
UPLOAD_STREAMS = 4
# Die ersten Millisekunden enthalten Verbindungsaufbau / Hochlauf.
# Sie werden live angezeigt, aber nicht in den End-Durchschnitt genommen.
WARMUP_SECONDS = 0.5

# Endwert: Durchschnitt der schnellsten 50 % der stabilisierten Samples.
# Dadurch zieht der TCP-Hochlauf den Endwert nicht künstlich herunter,
# einzelne kurze Peaks bestimmen das Ergebnis aber ebenfalls nicht allein.
TOP_SAMPLE_FRACTION = 0.50

# Kleine Cloudflare-Anfrage als Internet-Bereitschaftstest.
CONNECTIVITY_TIMEOUT = 15.0
# Der öffentliche Cloudflare-Endpunkt reagiert bei sehr großen
# Einzelrequests nicht auf allen Systemen zuverlässig.
# 99.999.999 Bytes pro Stream ist groß genug für unseren kurzen Test.
# Download:
# Datalix Looking Glass in Frankfurt stellt große Speedtest-Dateien bereit.
# 10 GB pro Stream sind absichtlich viel größer als nötig:
# Wir brechen nach 5 Sekunden ab, sodass kein Stream neu gestartet werden muss.
DOWNLOAD_URL = "https://lg.datalix.de/download.php?size=10gb"
# Upload bleibt bei Cloudflare, weil dieser Test bei uns stabil funktioniert.
CF_UP_BYTES = 250000000

CF_CHECK = "https://speed.cloudflare.com/__down?bytes=1000"
CF_UP = "https://speed.cloudflare.com/__up"

# Sehr kurzer ICMP-Test vor dem Speedtest. Der zweite Host wird nur probiert,
# wenn der erste nicht innerhalb von 1 Sekunde antwortet.
PING_TARGETS = ("1.1.1.1", "8.8.8.8")
PING_TIMEOUT_SECONDS = 1

LOG = Path.home() / "network_check.log"

ENV_C = os.environ.copy()
ENV_C["LC_ALL"] = "C"
ENV_C["LANG"] = "C"
# ============================================================
# Hilfsfunktionen
# ============================================================

def log(message):
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}  {message}"
    try:
        with LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)

def run_text(args, timeout=4):
    try:
        p = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            env=ENV_C,
        )
        return p.stdout.strip()
    except Exception:
        return ""


def format_mbps(value, decimals=0):
    if value is None:
        return "--"
    if decimals:
        return f"{value:.1f} Mbps"
    return f"{value:,.0f}".replace(",", ".") + " Mbps"


def format_link_speed(value):
    """LAN/WLAN-Link kompakt anzeigen: ab 1000 Mbps in Gbps."""
    if value is None:
        return "--"
    if value >= 1000.0:
        gbps = value / 1000.0
        if abs(gbps - round(gbps)) < 0.01:
            return f"{int(round(gbps))} Gbps"
        return f"{gbps:.1f} Gbps"
    return format_mbps(value, decimals=0)

def get_devices():
    """
    Liefert pro Typ (ethernet/wifi) alle von NetworkManager
    bekannten Geräte. Verbundene Geräte werden zuerst sortiert.
    """
    out = run_text(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status"])
    result = {"ethernet": [], "wifi": []}
    for raw in out.splitlines():
        # nmcli escaped Doppelpunkte sind bei normalen Interface-Namen
        # nicht relevant; maxsplit hält den Parser trotzdem klein.
        parts = raw.split(":", 2)
        if len(parts) != 3:
            continue

        dev, typ, state = parts
        if typ not in result:
            continue
        if not dev or dev == "lo":
            continue
        result[typ].append({
            "iface": dev,
            "type": typ,
            "state": state,
            "connected": state == "connected",
        })

    for typ in result:
        result[typ].sort(key=lambda d: (not d["connected"], d["iface"]))

    return result


def get_default_iface():
    out = run_text(["ip", "-4", "route", "show", "default"])
    candidates = []

    for line in out.splitlines():
        parts = line.split()
        if "dev" not in parts:
            continue
        try:
            iface = parts[parts.index("dev") + 1]
        except Exception:
            continue

        metric = 0
        if "metric" in parts:
            try:
                metric = int(parts[parts.index("metric") + 1])
            except Exception:
                metric = 999999

        candidates.append((metric, iface))

    if not candidates:
        return None

    candidates.sort()
    return candidates[0][1]

def ethernet_link_speed(iface):
    p = Path("/sys/class/net") / iface / "speed"
    try:
        raw = p.read_text().strip()
        speed = float(raw)
        if speed > 0:
            return speed
    except Exception:
        pass
    return None


def wifi_link_speed(iface):
    if not shutil_which("iw"):
        return None

    out = run_text(["iw", "dev", iface, "link"])
    # Bevorzugt RX, falls vorhanden, sonst TX.
    rx = re.search(r"rx bitrate:\s*([0-9.]+)\s*MBit/s", out, re.I)
    tx = re.search(r"tx bitrate:\s*([0-9.]+)\s*MBit/s", out, re.I)

    match = rx or tx
    if not match:
        return None

    try:
        return float(match.group(1))
    except Exception:
        return None

def shutil_which(cmd):
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        p = Path(directory) / cmd
        if p.exists() and os.access(p, os.X_OK):
            return str(p)
    return None


def link_speed(iface, kind):
    if kind == "lan":
        return ethernet_link_speed(iface)
    return wifi_link_speed(iface)

def iface_counter(iface, direction):
    stat = "rx_bytes" if direction == "download" else "tx_bytes"
    p = Path("/sys/class/net") / iface / "statistics" / stat
    try:
        return int(p.read_text().strip())
    except Exception:
        return 0

def iface_mac(iface):
    """Aktuelle MAC-Adresse des Interfaces aus sysfs lesen."""
    p = Path("/sys/class/net") / iface / "address"
    try:
        mac = p.read_text().strip().upper()
        if re.fullmatch(r"[0-9A-F]{2}(?::[0-9A-F]{2}){5}", mac):
            return mac
    except Exception:
        pass
    return None
# ============================================================
# GTK-Karte
# ============================================================

class ConnectionCard:
    def __init__(self, title):
        self.title = title
        self.base_title = title

        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.root.add_css_class("card")

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)

        # LAN/WLAN + MAC und Interface liegen jetzt in derselben Zeile.
        # Das Interface behält bewusst die kleine graue Darstellung.
        identity = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        identity.set_hexpand(True)

        self.title_label = Gtk.Label(label=title)
        self.title_label.set_xalign(0)
        self.title_label.add_css_class("card-title")
        self.title_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.title_label.set_max_width_chars(48)

        self.interface_label = Gtk.Label(label="Interface: --")
        self.interface_label.set_xalign(0)
        self.interface_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.interface_label.set_max_width_chars(32)
        self.interface_label.add_css_class("interface")

        identity.append(self.title_label)
        # Interface-Name wird intern weiter gepflegt, aber nicht mehr sichtbar
        # angezeigt. Im kompakten LAN/WLAN-Zweispaltenlayout zählt jeder Pixel.
        self.interface_label.set_visible(False)

        self.state_label = Gtk.Label(label="CHECKING")
        # Wechselnde Texte wie CHECKING/DOWNLOAD/UPLOAD dürfen die Kartenbreite
        # nicht verändern. Breite bleibt stabil, bei sehr kleinem Fenster wird
        # nur der Text selbst gekürzt.
        # Feste Pixelbreite statt Zeichenbreite: Pango bemisst
        # width_chars nicht exakt nach dem tatsächlichen Text und kürzte
        # "NICHT VERBUNDEN" trotz rechnerisch ausreichender Zeichenanzahl.
        self.state_label.set_size_request(132, -1)
        self.state_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.state_label.set_xalign(1.0)
        self.state_label.set_halign(Gtk.Align.END)
        self.state_label.add_css_class("badge")
        self.set_widget_class(self.state_label, "warn")

        header.append(identity)
        header.append(self.state_label)
        self.root.append(header)

        metrics = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        metrics.set_homogeneous(True)
        self.metric_boxes = {}

        self.link_value = self.metric(metrics, "LINK")
        self.ping_value = self.metric(metrics, "PING")
        self.down_value = self.metric(metrics, "DOWNLOAD")
        self.up_value = self.metric(metrics, "UPLOAD")

        # Noch nicht geprüft = überall Orange.
        for widget in (
            self.link_value,
            self.ping_value,
            self.down_value,
            self.up_value,
        ):
            self.set_widget_class(widget, "warn")

        self.root.append(metrics)

        self.note_label = Gtk.Label(label="")
        self.note_label.set_xalign(0)
        self.note_label.set_wrap(False)
        self.note_label.set_hexpand(True)
        self.note_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.note_label.set_max_width_chars(1)
        self.note_label.add_css_class("note")
        self.root.append(self.note_label)

    def metric(self, parent, caption):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        box.add_css_class("metric")

        cap = Gtk.Label(label=caption)
        cap.add_css_class("metric-caption")
        value = Gtk.Label(label="--")
        value.set_width_chars(8)
        value.set_max_width_chars(8)
        value.set_ellipsize(Pango.EllipsizeMode.END)
        value.set_xalign(0.5)
        value.add_css_class("metric-value")
        value.add_css_class("neutral")

        box.append(cap)
        box.append(value)
        parent.append(box)
        self.metric_boxes[caption.lower()] = box
        return value

    def set_widget_class(self, widget, klass):
        for c in ("good", "bad", "warn", "neutral", "live"):
            widget.remove_css_class(c)
        widget.add_css_class(klass)
    def set_title_mac(self, mac=None, adapter_present=True):
        # Fehlende Hardware bzw. nicht lesbare MAC = orange/unklar.
        # Eine echte Null-MAC bleibt rot, weil das ein klarer Fehler ist.
        self.title_label.remove_css_class("mac-error")
        self.title_label.remove_css_class("mac-warning")

        if not adapter_present:
            self.title_label.set_text(f"{self.base_title} - KEINE NETZWERKKARTE")
            self.title_label.add_css_class("mac-warning")
            return

        if not mac:
            self.title_label.set_text(f"{self.base_title} - KEINE MAC")
            self.title_label.add_css_class("mac-warning")
            return

        self.title_label.set_text(f"{self.base_title} - {mac}")

        if mac == "00:00:00:00:00:00":
            self.title_label.add_css_class("mac-error")

    def set_state(self, text, klass):
        self.state_label.set_text(text)
        self.set_widget_class(self.state_label, klass)
    def set_metric(self, which, text, klass="neutral"):
        widget = {
            "link": self.link_value,
            "ping": self.ping_value,
            "down": self.down_value,
            "up": self.up_value,
        }[which]
        widget.set_text(text)
        self.set_widget_class(widget, klass)
# ============================================================
# Hauptanwendung
# ============================================================


# ============================================================
# Wipe Auto – kompakt im gemeinsamen Network/Wipe-Fenster
# ============================================================
WIPE_VERSION = "3.40"
BATTERY_BAD_BELOW = 75.0

def wipe_run(args, timeout=8, sudo=False):
    cmd = (["sudo", "-n"] if sudo else []) + list(args)
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            env=ENV_C,
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as exc:
        return 99, "", str(exc)

def wipe_lsblk_snapshot():
    """Liest die Blockgeräte nur ein; diese Funktion verändert nichts."""
    columns = (
        "PATH,NAME,KNAME,PKNAME,TYPE,ROTA,RM,TRAN,MODEL,SIZE,"
        "MOUNTPOINTS,MAJ:MIN,SERIAL,WWN"
    )
    rc, out, err = wipe_run(["lsblk", "-Jb", "-o", columns])
    if rc != 0:
        log(f"Zielerkennung: lsblk fehlgeschlagen: {err or rc}")
        return []
    try:
        import json
        return json.loads(out).get("blockdevices", [])
    except Exception as exc:
        log(f"Zielerkennung: ungültige lsblk-Ausgabe: {exc}")
        return []


def wipe_flatten_devices(devices, parent=None):
    flat = []
    for raw in devices:
        item = dict(raw)
        item["_parent"] = parent
        children = item.pop("children", []) or []
        flat.append(item)
        flat.extend(wipe_flatten_devices(children, item))
    return flat


def wipe_mounted_sources():
    sources = set()
    rc, out, _ = wipe_run(["findmnt", "-rn", "-o", "SOURCE,TARGET"])
    if rc == 0:
        for line in out.splitlines():
            parts = line.split(None, 1)
            if parts and parts[0].startswith("/dev/"):
                sources.add(os.path.realpath(parts[0]))

    # Live-Systeme haben oft overlay als /; /cdrom bzw. Persistence tauchen
    # jedoch als Blockquelle in mountinfo oder /proc/mounts auf.
    for filename in ("/proc/self/mountinfo", "/proc/mounts"):
        try:
            text = Path(filename).read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        for source in re.findall(r"(?:^|\s)(/dev/[^\s]+)", text):
            sources.add(os.path.realpath(source.replace("\\040", " ")))
    return sources


def wipe_udev_properties(path):
    rc, out, _ = wipe_run(
        ["udevadm", "info", "--query=property", f"--name={path}"]
    )
    if rc != 0:
        return {}
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def wipe_device_identity(device):
    return (
        str(device.get("maj:min") or ""),
        str(device.get("serial") or ""),
        str(device.get("wwn") or ""),
        os.path.realpath(str(device.get("path") or "")),
    )


def wipe_sysfs_path_is_usb(sys_path):
    path = sys_path.lower()
    return bool("/usb" in path or re.search(r"/(?:\d+-\d+(?:\.\d+)*)/", path))


def wipe_is_certainly_internal_ssd(device):
    path = str(device.get("path") or "")
    name = str(device.get("name") or "")
    dtype = str(device.get("type") or "")
    tran = str(device.get("tran") or "").strip().lower()
    if dtype != "disk" or not path.startswith("/dev/"):
        return False
    if device.get("rm") not in (False, 0, "0"):
        return False
    if device.get("rota") not in (False, 0, "0"):
        return False
    if tran not in ("", "nvme", "sata", "ata", "usb"):
        return False
    if re.match(r"^(loop|zram|dm-|md|sr|ram|fd|nbd|rbd)", name):
        return False

    # USB ist unabhängig von TRAN ein harter Ausschluss. Damit bleiben auch
    # USB-Bridges gesperrt, die sich ungewöhnlich als SATA/ATA/NVMe melden.
    sys_path = os.path.realpath(f"/sys/class/block/{name}")
    props = wipe_udev_properties(path)
    bus = props.get("ID_BUS", "").lower()
    if tran == "usb" or bus == "usb" or wipe_sysfs_path_is_usb(sys_path):
        return False

    if tran in ("nvme", "sata", "ata"):
        return True

    # Ein leeres TRAN ist nur mit einem zweiten, eindeutig internen Signal
    # zulässig. RM=0 allein ist ausdrücklich kein solches Signal.
    if "/virtual/" in sys_path:
        return False
    id_path = props.get("ID_PATH", "").lower()
    if bus in ("ata", "nvme"):
        return True
    return "/nvme/" in sys_path.lower() and "pci" in id_path


def wipe_detect_candidates():
    """Gibt sichere Kandidaten zurück und führt nie Destruktivbefehle aus."""
    flat = wipe_flatten_devices(wipe_lsblk_snapshot())
    by_path = {
        os.path.realpath(str(item.get("path") or "")): item
        for item in flat if item.get("path")
    }
    system_disks = set()
    mounted = wipe_mounted_sources()

    for item in flat:
        mountpoints = item.get("mountpoints") or []
        if isinstance(mountpoints, str):
            mountpoints = [mountpoints]
        item_path = os.path.realpath(str(item.get("path") or ""))
        if not any(mountpoints) and item_path not in mounted:
            continue
        current = item
        while current is not None:
            if current.get("type") == "disk":
                system_disks.add(os.path.realpath(str(current.get("path"))))
                break
            current = current.get("_parent")

    # findmnt kann Alias-Pfade liefern; deren lsblk-Knoten ebenfalls bis zum
    # gesamten Parent-Datenträger hochlaufen.
    for source in mounted:
        current = by_path.get(source)
        while current is not None:
            if current.get("type") == "disk":
                system_disks.add(os.path.realpath(str(current.get("path"))))
                break
            current = current.get("_parent")

    candidates = []
    for item in flat:
        path = os.path.realpath(str(item.get("path") or ""))
        if path in system_disks or not wipe_is_certainly_internal_ssd(item):
            continue
        candidates.append(item)
    return candidates


def wipe_detect_target():
    candidates = wipe_detect_candidates()
    return candidates[0] if len(candidates) == 1 else None, len(candidates)


def wipe_validate_target(path, identity):
    """Validiert genau das bestätigte Gerät; wählt nie Ersatz."""
    if not path or not Path(path).exists():
        return False
    for candidate in wipe_detect_candidates():
        if candidate.get("path") == path:
            return wipe_device_identity(candidate) == identity
    return False


def wipe_compact_battery_time(seconds):
    if seconds is None:
        return None
    try:
        seconds = float(seconds)
    except Exception:
        return None
    if seconds <= 0 or seconds > 7 * 24 * 3600:
        return None
    minutes = max(1, int(round(seconds / 60.0)))
    hours, mins = divmod(minutes, 60)
    if hours:
        return f"{hours}h {mins:02d}m"
    return f"{mins}m"


def wipe_parse_upower_time(value):
    if not value:
        return None
    m = re.match(
        r"\s*([0-9]+(?:\.[0-9]+)?)\s+"
        r"(second|seconds|minute|minutes|hour|hours|day|days)\s*$",
        value,
        re.I,
    )
    if not m:
        return None
    amount = float(m.group(1))
    unit = m.group(2).lower()
    if unit.startswith("second"):
        return amount
    if unit.startswith("minute"):
        return amount * 60.0
    if unit.startswith("hour"):
        return amount * 3600.0
    if unit.startswith("day"):
        return amount * 86400.0
    return None


def wipe_battery_power_w_sysfs(battery_name):
    if not battery_name:
        return None
    base = Path("/sys/class/power_supply") / battery_name
    if not base.exists():
        return None

    def number(name):
        try:
            return float((base / name).read_text().strip())
        except Exception:
            return None

    power_now = number("power_now")
    if power_now is not None and power_now >= 0:
        return power_now / 1_000_000.0

    current_now = number("current_now")
    voltage_now = number("voltage_now")
    if (
        current_now is not None
        and voltage_now is not None
        and current_now >= 0
        and voltage_now > 0
    ):
        return (current_now * voltage_now) / 1_000_000_000_000.0
    return None


def wipe_format_battery_power(power_w, state):
    if power_w is None:
        return ""
    try:
        power_w = abs(float(power_w))
    except Exception:
        return ""
    if power_w < 0.05:
        return ""
    if (state or "").strip().lower() == "discharging":
        return f"- {power_w:.1f}W"
    return f"{power_w:.1f}W"


def wipe_battery_info():
    rc, out, _ = wipe_run(["upower", "-e"])
    if rc != 0:
        return None, None, None, None, None
    bat = next((line.strip() for line in out.splitlines() if "BAT" in line), None)
    if not bat:
        return None, None, None, None, None
    rc, info, _ = wipe_run(["upower", "-i", bat])
    if rc != 0:
        return None, None, None, None, None

    health = None
    percentage = None
    state = None
    time_to_empty = None
    time_to_full = None
    power_w = None

    for line in info.splitlines():
        m = re.match(r"\s*capacity:\s*([0-9.,]+)%", line, re.I)
        if m:
            try:
                health = float(m.group(1).replace(",", "."))
            except Exception:
                health = None

        m = re.match(r"\s*percentage:\s*([0-9.,]+)%", line, re.I)
        if m:
            try:
                percentage = float(m.group(1).replace(",", "."))
            except Exception:
                percentage = None

        m = re.match(r"\s*state:\s*(.+?)\s*$", line, re.I)
        if m:
            state = m.group(1).strip().lower()

        m = re.match(r"\s*time to empty:\s*(.+?)\s*$", line, re.I)
        if m:
            time_to_empty = wipe_parse_upower_time(m.group(1))

        m = re.match(r"\s*time to full:\s*(.+?)\s*$", line, re.I)
        if m:
            time_to_full = wipe_parse_upower_time(m.group(1))

        m = re.match(r"\s*energy-rate:\s*([0-9.,]+)\s*W\s*$", line, re.I)
        if m:
            try:
                power_w = float(m.group(1).replace(",", "."))
            except Exception:
                power_w = None

    if power_w is None:
        battery_name = bat.rsplit("/", 1)[-1]
        if battery_name.startswith("battery_"):
            battery_name = battery_name[len("battery_"):]
        power_w = wipe_battery_power_w_sysfs(battery_name)

    remaining = None
    if state in {"discharging", "pending-discharge"}:
        remaining = time_to_empty
    elif state in {"charging", "pending-charge"}:
        remaining = time_to_full

    return (
        health,
        percentage,
        state,
        wipe_compact_battery_time(remaining),
        power_w,
    )

def wipe_disk_details(disk):
    if not disk or not Path(disk).exists():
        return None
    rc, out, _ = wipe_run(["lsblk", "-dn", "-o", "SIZE,MODEL", disk])
    if rc != 0:
        return {"size": "--", "model": "--"}
    parts = out.split(None, 1)
    return {
        "size": parts[0] if parts else "--",
        "model": parts[1].strip() if len(parts) > 1 else "--",
    }


SMART_TEMP_WARN_C = 60.0
SMART_TEMP_BAD_C = 70.0
SMART_SENSOR_TEMP_WARN_C = 70.0
SMART_SENSOR_TEMP_BAD_C = 80.0
SMART_WEAR_WARN_PERCENT = 80
SMART_WEAR_BAD_PERCENT = 100
SMART_UNSAFE_SHUTDOWN_WARN = 50
KEYBOARD_TEST_STATE_FILE = (
    Path.home() / ".local/state/uwuntu/keyboard_test_active"
)

def keyboard_test_active():
    try:
        pid = int(KEYBOARD_TEST_STATE_FILE.read_text(encoding="utf-8").strip())
    except Exception:
        return False

    if pid <= 0:
        return False

    try:
        os.kill(pid, 0)
    except OSError:
        return False

    try:
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().decode(
            "utf-8",
            errors="ignore",
        ).lower()
    except Exception:
        return False

    return "hardware-check" in cmdline


def smart_number(value, default=0):
    if isinstance(value, dict):
        for key in ("value", "hours", "minutes"):
            if key in value:
                value = value[key]
                break
    try:
        return int(value)
    except (TypeError, ValueError):
        return default

def smart_temperature_c(value):
    try:
        temp = float(value)
    except (TypeError, ValueError):
        return None
    # Manche NVMe-Werkzeuge liefern Kelvin, smartctl meist Celsius.
    if temp > 170:
        temp -= 273.15
    return temp

def smart_format_count(value):
    return f"{smart_number(value):,}".replace(",", ".")

def smart_format_tb(data_units):
    # Ein NVMe Data Unit entspricht 512.000 Byte.
    value = smart_number(data_units)
    return f"{value * 512000 / 1_000_000_000_000:.2f} TB".replace(".", ",")

def smart_format_minutes(value):
    minutes = smart_number(value)
    if minutes < 60:
        return f"{minutes} min"
    return f"{minutes / 60.0:.1f} h"

def smart_temp_state(temp):
    if temp is None:
        return "warn"
    if temp >= SMART_TEMP_BAD_C:
        return "bad"
    if temp >= SMART_TEMP_WARN_C:
        return "warn"
    return "good"

def smart_sensor_temp_state(temp):
    if temp is None:
        return "warn"
    if temp >= SMART_SENSOR_TEMP_BAD_C:
        return "bad"
    if temp >= SMART_SENSOR_TEMP_WARN_C:
        return "warn"
    return "good"

def smart_collect(disk):
    """SMART/NVMe-Daten lesen und in verständliche deutsche Zeilen übersetzen."""
    rows = []
    if not disk:
        return {
            "model": "Kein Datenträger",
            "serial": "--",
            "firmware": "--",
            "rows": [(
                "SMART-Auslesung",
                "NICHT MÖGLICH",
                "Es wurde kein eindeutiger interner Datenträger erkannt.",
                "warn",
            )],
        }

    commands = [
        ["sudo", "-n", "smartctl", "-a", "-j", disk],
        ["smartctl", "-a", "-j", disk],
    ]
    data = None
    last_error = ""
    for cmd in commands:
        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=12,
                env=ENV_C,
                check=False,
            )
            if proc.stdout.strip():
                try:
                    candidate = json.loads(proc.stdout)
                except Exception:
                    candidate = None
                if isinstance(candidate, dict) and candidate:
                    data = candidate
                    break
            last_error = (proc.stderr or "").strip()
        except Exception as exc:
            last_error = str(exc)

    if not data:
        text = "SMART-Daten konnten nicht gelesen werden."
        if last_error:
            text += " " + last_error.splitlines()[-1][:120]
        return {
            "model": Path(disk).name,
            "serial": "--",
            "firmware": "--",
            "rows": [("SMART-Auslesung", "NICHT VERFÜGBAR", text, "warn")],
        }

    def add(label, value, explanation, state="good"):
        rows.append((label, str(value), explanation, state))

    smart_passed = (data.get("smart_status") or {}).get("passed")
    if smart_passed is True:
        add("SMART-Gesamtzustand", "BESTANDEN",
            "Der Datenträger meldet aktuell keinen SMART-Gesamtfehler.", "good")
    elif smart_passed is False:
        add("SMART-Gesamtzustand", "FEHLER",
            "Der Datenträger meldet einen SMART-Gesamtfehler.", "bad")
    else:
        add("SMART-Gesamtzustand", "UNBEKANNT",
            "Der Gesamtstatus wurde vom Laufwerk nicht bereitgestellt.", "warn")

    nvme = data.get("nvme_smart_health_information_log")
    if isinstance(nvme, dict):
        critical = smart_number(nvme.get("critical_warning"))
        add("Kritische NVMe-Warnung", critical,
            "0 bedeutet: keine aktuelle kritische NVMe-Warnung.",
            "good" if critical == 0 else "bad")

        if "endurance_group_critical_warning_summary" in nvme:
            endurance_warn = smart_number(
                nvme.get("endurance_group_critical_warning_summary")
            )
            add("Kritische Endurance-Warnung", endurance_warn,
                "0 bedeutet: keine kritische Warnung der Speichergruppe.",
                "good" if endurance_warn == 0 else "bad")

        temp = smart_temperature_c(nvme.get("temperature"))
        if temp is not None:
            add("Temperatur", f"{temp:.0f} °C",
                "Unter 60 °C grün, ab 60 °C orange, ab 70 °C rot.",
                smart_temp_state(temp))

        spare = smart_number(nvme.get("available_spare"), -1)
        threshold = smart_number(nvme.get("available_spare_threshold"), -1)
        if spare >= 0:
            state = "good"
            if threshold >= 0 and spare <= threshold:
                state = "bad"
            elif threshold >= 0 and spare <= threshold + 10:
                state = "warn"
            add("Verfügbare Reserve", f"{spare} %",
                "Reserveblöcke des Flash-Speichers; mehr ist besser.", state)
        if threshold >= 0:
            add("Reserve-Warnschwelle", f"{threshold} %",
                "Ab dieser Restreserve warnt der Hersteller.", "good")

        used = smart_number(nvme.get("percentage_used"), -1)
        if used >= 0:
            state = (
                "bad" if used >= SMART_WEAR_BAD_PERCENT
                else "warn" if used >= SMART_WEAR_WARN_PERCENT
                else "good"
            )
            add("Verschleiß", f"{used} %",
                "Hersteller-Schätzwert der bereits verbrauchten SSD-Lebensdauer.",
                state)

        if "data_units_read" in nvme:
            add("Gelesene Daten", smart_format_tb(nvme.get("data_units_read")),
                "Gesamte vom Host gelesene Datenmenge.", "good")
        if "data_units_written" in nvme:
            add("Geschriebene Daten", smart_format_tb(nvme.get("data_units_written")),
                "Gesamte vom Host geschriebene Datenmenge.", "good")
        if "host_reads" in nvme:
            add("Lesevorgänge des Hosts", smart_format_count(nvme.get("host_reads")),
                "Anzahl der vom Betriebssystem angeforderten Leseoperationen.", "good")
        if "host_writes" in nvme:
            add("Schreibvorgänge des Hosts", smart_format_count(nvme.get("host_writes")),
                "Anzahl der vom Betriebssystem angeforderten Schreiboperationen.", "good")
        if "controller_busy_time" in nvme:
            add("Controller aktiv", smart_format_minutes(nvme.get("controller_busy_time")),
                "Gesamtzeit, in der der SSD-Controller beschäftigt war.", "good")
        if "power_cycles" in nvme:
            add("Einschaltvorgänge", smart_format_count(nvme.get("power_cycles")),
                "Wie oft der Datenträger eingeschaltet wurde.", "good")
        if "power_on_hours" in nvme:
            add("Betriebsstunden", f"{smart_format_count(nvme.get('power_on_hours'))} h",
                "Gesamte eingeschaltete Betriebszeit.", "good")

        unsafe = smart_number(nvme.get("unsafe_shutdowns"))
        add("Unsichere Abschaltungen", smart_format_count(unsafe),
            "Stromverlust oder hartes Ausschalten ohne sauberes Herunterfahren. Unter 50 unauffällig.",
            "good" if unsafe < SMART_UNSAFE_SHUTDOWN_WARN else "warn")

        media_errors = smart_number(nvme.get("media_errors"))
        add("Medienfehler", smart_format_count(media_errors),
            "Nicht korrigierbare Fehler des Flash-Speichers.",
            "good" if media_errors == 0 else "bad")

        error_entries = smart_number(nvme.get("num_err_log_entries"))
        add("Fehlerprotokoll-Einträge", smart_format_count(error_entries),
            "NVMe-Fehlerprotokoll; einzelne historische Einträge sind nicht automatisch ein Defekt.",
            "good" if error_entries == 0 else "warn")

        warning_time = smart_number(nvme.get("warning_temp_time"))
        add("Zeit über Warn-Temperatur", smart_format_minutes(warning_time),
            "Historische Zeit oberhalb der Warn-Temperatur.",
            "good" if warning_time == 0 else "warn")
        critical_time = smart_number(nvme.get("critical_comp_time"))
        add("Zeit über kritischer Temperatur", smart_format_minutes(critical_time),
            "Historische Zeit im kritischen Temperaturbereich.",
            "good" if critical_time == 0 else "warn")

        sensors = nvme.get("temperature_sensors") or []
        if isinstance(sensors, list):
            for index, raw_temp in enumerate(sensors, 1):
                temp = smart_temperature_c(raw_temp)
                if temp is None:
                    continue
                add(f"Temperatursensor {index}", f"{temp:.0f} °C",
                    "Zusätzlicher interner Temperatursensor: unter 70 °C grün, ab 70 °C orange, ab 80 °C rot.",
                    smart_sensor_temp_state(temp))

        for key, label in (
            ("thermal_management_t1_trans_count", "Thermische Regelung Stufe 1 – Ereignisse"),
            ("thermal_management_t2_trans_count", "Thermische Regelung Stufe 2 – Ereignisse"),
        ):
            if key in nvme:
                value = smart_number(nvme.get(key))
                add(label, smart_format_count(value),
                    "Thermische Drosselung; 0 bedeutet, dass sie bisher nicht nötig war.",
                    "good" if value == 0 else "warn")
        for key, label in (
            ("thermal_management_t1_total_time", "Thermische Regelung Stufe 1 – Zeit"),
            ("thermal_management_t2_total_time", "Thermische Regelung Stufe 2 – Zeit"),
        ):
            if key in nvme:
                value = smart_number(nvme.get(key))
                add(label, smart_format_minutes(value),
                    "Gesamtdauer der thermischen Drosselung.",
                    "good" if value == 0 else "warn")

    ata_temp = (data.get("temperature") or {}).get("current")
    if not isinstance(nvme, dict) and ata_temp is not None:
        temp = smart_temperature_c(ata_temp)
        if temp is not None:
            add("Temperatur", f"{temp:.0f} °C",
                "Unter 60 °C grün, ab 60 °C orange, ab 70 °C rot.",
                smart_temp_state(temp))

    if not isinstance(nvme, dict):
        hours = (data.get("power_on_time") or {}).get("hours")
        if hours is not None:
            add("Betriebsstunden", f"{smart_format_count(hours)} h",
                "Gesamte eingeschaltete Betriebszeit.", "good")
        cycles = data.get("power_cycle_count")
        if cycles is not None:
            add("Einschaltvorgänge", smart_format_count(cycles),
                "Wie oft der Datenträger eingeschaltet wurde.", "good")

        ata_log_count = (
            ((data.get("ata_smart_error_log") or {}).get("summary") or {}).get("count")
        )
        if ata_log_count is not None:
            count = smart_number(ata_log_count)
            add("SMART-Fehlerprotokoll", smart_format_count(count),
                "Historische ATA-SMART-Fehlerprotokolleinträge.",
                "good" if count == 0 else "warn")

        translations = {
            "Reallocated_Sector_Ct": "Neu zugewiesene Sektoren",
            "Reported_Uncorrect": "Gemeldete nicht korrigierbare Fehler",
            "Current_Pending_Sector": "Schwebende Sektoren",
            "Offline_Uncorrectable": "Nicht korrigierbare Sektoren",
            "UDMA_CRC_Error_Count": "Übertragungsfehler (CRC)",
            "Power_On_Hours": "Betriebsstunden (SMART-Attribut)",
            "Power_Cycle_Count": "Einschaltvorgänge (SMART-Attribut)",
            "Temperature_Celsius": "Temperatur (SMART-Attribut)",
            "Airflow_Temperature_Cel": "Luft-/SSD-Temperatur (SMART-Attribut)",
            "Wear_Leveling_Count": "Wear-Leveling / Verschleiß",
            "Media_Wearout_Indicator": "Medien-Verschleißindikator",
            "Percent_Lifetime_Remain": "Verbleibende Lebensdauer",
        }
        critical_ids = {5, 187, 197, 198}
        warning_ids = {188, 199}
        table = ((data.get("ata_smart_attributes") or {}).get("table") or [])
        for attr in table:
            if not isinstance(attr, dict):
                continue
            attr_id = smart_number(attr.get("id"), -1)
            name = str(attr.get("name") or f"Attribut {attr_id}")
            label = translations.get(name, f"SMART {attr_id} · {name}")
            raw = attr.get("raw") or {}
            raw_value = smart_number(raw.get("value"), 0)
            raw_text = str(raw.get("string") or raw_value)
            norm = attr.get("value")
            thresh = attr.get("thresh")
            when_failed = str(attr.get("when_failed") or "").strip()
            state = "good"
            if when_failed and when_failed not in {"-", "Never"}:
                state = "bad"
            elif attr_id in critical_ids and raw_value > 0:
                state = "bad"
            elif attr_id in warning_ids and raw_value > 0:
                state = "warn"
            try:
                if (
                    norm is not None and thresh is not None
                    and int(thresh) > 0 and int(norm) <= int(thresh)
                ):
                    state = "bad"
            except Exception:
                pass
            detail = f"Rohwert {raw_text}"
            if norm is not None:
                detail += f" · Normwert {norm}"
            if thresh is not None:
                detail += f" · Grenze {thresh}"
            add(label, raw_text, detail, state)

    return {
        "model": str(data.get("model_name") or data.get("model_family") or Path(disk).name),
        "serial": str(data.get("serial_number") or "--"),
        "firmware": str(data.get("firmware_version") or "--"),
        "rows": rows or [(
            "SMART-Auslesung", "KEINE WERTE",
            "Das Laufwerk lieferte keine auswertbaren SMART-Werte.", "warn"
        )],
    }

def wipe_disk_is_clean(disk):
    rc, sig, err = wipe_run(["wipefs", "-n", disk], timeout=10, sudo=True)
    if rc != 0:
        return False, err or "wipefs -n fehlgeschlagen"
    if sig.strip():
        return False, "Signaturen vorhanden"
    rc, out, err = wipe_run(["lsblk", "-nr", "-o", "NAME,TYPE", disk])
    if rc != 0:
        return False, err or "lsblk fehlgeschlagen"
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if any(line.split()[-1] == "part" for line in lines[1:]):
        return False, "Partitionen vorhanden"
    return True, ""

class WipeCompactPanel:
    def __init__(self, window):
        self.window = window
        self.wiping = False
        self.confirming = False
        self.confirmed_disk = None
        self.confirmed_identity = None
        self.refresh_button = None
        self.disk = None
        self.disk_info = None
        self.last_disk_display = None
        self.soh_alert_active = False
        self.soh_blink_on = False
        self.smart_window = None
        self.smart_refresh_button = None
        self.smart_disk_path = None
        self.smart_overall = None
        self.smart_data = None
        self.smart_check_disk = None

        # Batterie und Datenträger sind jetzt zwei eigenständige volle Zeilen.
        # Zusammen mit LAN und WLAN ergibt das exakt:
        # LAN / WLAN / BATTERIE / DATENTRÄGER – einspaltig über die gesamte Fensterbreite.
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.root.set_hexpand(True)
        self.root.set_vexpand(False)

        # Batterie
        battery = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        battery.set_hexpand(True)
        battery.set_vexpand(False)
        battery.add_css_class("card")
        btitle = Gtk.Label(label="BATTERIE")
        btitle.set_xalign(0)
        btitle.add_css_class("card-title")
        battery.append(btitle)

        battery_metrics = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=4,
        )
        battery_metrics.set_hexpand(True)

        self.battery_value = Gtk.Label(label="--")
        self.battery_value.set_xalign(0.5)
        self.battery_value.set_size_request(190, -1)
        self.battery_value.set_hexpand(False)
        self.battery_value.add_css_class("wipe-big")
        battery_metrics.append(self.battery_value)

        self.battery_soc = Gtk.Label(label="-- SoC")
        self.battery_soc.set_xalign(0.5)
        self.battery_soc.set_size_request(135, -1)
        self.battery_soc.set_hexpand(False)
        self.battery_soc.add_css_class("wipe-big")
        self.battery_soc.add_css_class("neutral")
        battery_metrics.append(self.battery_soc)

        self.battery_state = Gtk.Label(label="--")
        self.battery_state.set_xalign(0.5)
        self.battery_state.set_hexpand(True)
        self.battery_state.set_ellipsize(Pango.EllipsizeMode.END)
        self.battery_state.add_css_class("wipe-big")
        battery_metrics.append(self.battery_state)
        battery.append(battery_metrics)

        self.battery_note = Gtk.Label(label="")
        self.battery_note.set_xalign(0)
        self.battery_note.set_wrap(True)
        self.battery_note.add_css_class("note")
        battery.append(self.battery_note)
        self.root.append(battery)

        # Datenträger
        disk = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        disk.set_hexpand(True)
        disk.set_vexpand(False)
        disk.add_css_class("card")
        dhead = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        dtitle = Gtk.Label(label="DATENTRÄGER")
        dtitle.set_xalign(0)
        dtitle.set_hexpand(True)
        dtitle.add_css_class("card-title")
        self.disk_badge = Gtk.Label(label="CHECKING")
        self.disk_badge.set_xalign(1)
        self.disk_badge.add_css_class("ssd-status")
        dhead.append(dtitle)
        dhead.append(self.disk_badge)
        disk.append(dhead)

        # Datenträger/Modell links und WIPE-Bedienung rechts in EINER Zeile.
        disk_action_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=6,
        )
        disk_action_row.set_hexpand(True)

        self.disk_value = Gtk.Label(label="--")
        self.disk_value.set_xalign(0)
        self.disk_value.set_hexpand(True)
        self.disk_value.set_wrap(False)
        self.disk_value.set_ellipsize(Pango.EllipsizeMode.END)
        self.disk_value.set_max_width_chars(70)
        self.disk_value.add_css_class("disk-result")
        self.disk_value.set_tooltip_text("SSD-/SMART-Werte anzeigen (S)")
        smart_click = Gtk.GestureClick.new()
        smart_click.set_button(1)
        smart_click.connect(
            "released",
            lambda _gesture, n_press, _x, _y: (
                self.show_smart_window() if n_press == 1 else None
            ),
        )
        self.disk_value.add_controller(smart_click)
        disk_action_row.append(self.disk_value)

        self.action_area = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=4,
        )
        self.action_area.set_halign(Gtk.Align.END)
        self.action_area.set_valign(Gtk.Align.CENTER)
        # In allen Wipe-Zuständen dieselbe Zeilenhöhe reservieren:
        # LÖSCHEN, Bestätigung und leere Aktionsfläche nach Erfolg dürfen
        # die DATENTRÄGER-Karte nicht mehr in der Höhe verändern.
        self.action_area.set_size_request(-1, 36)

        self.wipe_button = Gtk.Button(label="LÖSCHEN")
        self.wipe_button.add_css_class("danger-action")
        # Der Fokus-Outline liegt 3 px außen plus 2 px Offset. Diese 5 px
        # werden dauerhaft reserviert, ohne das bewährte Fokus-CSS zu ändern.
        self.wipe_button.set_margin_start(5)
        self.wipe_button.set_margin_end(5)
        self.wipe_button.set_margin_top(3)
        self.wipe_button.set_margin_bottom(3)
        self.wipe_button.connect("clicked", self.on_wipe_clicked)
        self.wipe_button.connect(
            "notify::has-focus",
            self.on_action_focus_changed,
        )
        self.action_area.append(self.wipe_button)
        disk_action_row.append(self.action_area)
        disk.append(disk_action_row)

        self.disk_note = Gtk.Label(label="")
        self.disk_note.set_xalign(0)
        self.disk_note.set_wrap(True)
        self.disk_note.add_css_class("note")
        disk.append(self.disk_note)

        self.root.append(disk)

        self.refresh()
        GLib.timeout_add_seconds(1, self.refresh_battery_timer)
        # Unter 75 % SoH blinkt das linke SoH-Feld wieder rot.
        GLib.timeout_add(450, self.update_soh_blink)

    @staticmethod
    def set_class(widget, klass):
        for c in ("good", "bad", "warn", "neutral", "live"):
            widget.remove_css_class(c)
        widget.add_css_class(klass)

    def apply_disk_smart_color(self):
        if (
            self.disk
            and self.smart_disk_path == self.disk
            and self.smart_overall in {"good", "warn", "bad"}
        ):
            klass = self.smart_overall
        else:
            klass = "neutral"
        self.set_class(self.disk_value, klass)

    @staticmethod
    def smart_overall_from_data(data):
        states = [row[3] for row in (data or {}).get("rows", [])]
        return "bad" if "bad" in states else "warn" if "warn" in states else "good"

    def ensure_smart_check(self):
        disk = self.disk
        if not disk:
            return False

        if self.smart_disk_path == disk and self.smart_data is not None:
            self.apply_disk_smart_color()
            return False

        if self.smart_check_disk == disk:
            return False

        self.smart_check_disk = disk
        threading.Thread(
            target=self._smart_check_worker,
            args=(disk,),
            daemon=True,
            name="uwuntu-smart-check",
        ).start()
        return False

    def _smart_check_worker(self, disk):
        data = smart_collect(disk)
        overall = self.smart_overall_from_data(data)
        GLib.idle_add(self._finish_smart_check, disk, data, overall)

    def _finish_smart_check(self, disk, data, overall):
        if self.smart_check_disk == disk:
            self.smart_check_disk = None

        if self.disk != disk:
            return False

        self.smart_data = data
        self.smart_disk_path = disk
        self.smart_overall = overall
        self.apply_disk_smart_color()
        log(f"SMART-Startprüfung abgeschlossen: {disk} -> {overall}")
        return False

    def refresh_battery(self):
        health, percentage, state, remaining, power_w = wipe_battery_info()
        power_text = wipe_format_battery_power(power_w, state)

        self.set_soh_alert(
            health is not None and health < BATTERY_BAD_BELOW
        )

        if health is None:
            self.battery_value.set_text("-- SoH")
            self.set_class(self.battery_value, "warn")
            self.battery_note.set_text(
                "Akku nicht erkannt oder Battery Health konnte nicht gelesen werden."
            )
        elif health < BATTERY_BAD_BELOW:
            self.battery_value.set_text(f"{health:.1f} % SoH")
            self.set_class(self.battery_value, "bad")
            self.battery_note.set_text(
                f"Akku unter {BATTERY_BAD_BELOW:.0f} % – Gerät prüfen!"
            )
        else:
            self.battery_value.set_text(f"{health:.1f} % SoH")
            self.set_class(self.battery_value, "good")
            self.battery_note.set_text(
                "Battery Health innerhalb der Prüfgrenze."
            )

        if percentage is None:
            self.battery_soc.set_text("-- SoC")
            self.set_class(self.battery_soc, "warn")
        else:
            self.battery_soc.set_text(f"{percentage:.0f} % SoC")
            self.set_class(self.battery_soc, "neutral")

        # Dieselben deutschen UPower-Zustände wie im Standalone-Wipe.
        if state == "fully-charged":
            parts = ["VOLL GELADEN"]
            state_class = "good"
        elif state == "charging":
            parts = ["LÄDT"]
            if remaining:
                parts.append(remaining)
            state_class = "good"
        elif state == "pending-charge":
            parts = ["WARTET AUF LADUNG"]
            if remaining:
                parts.append(remaining)
            state_class = "warn"
        elif state == "discharging":
            parts = ["ENTLÄDT"]
            if remaining:
                parts.append(remaining)
            state_class = "warn"
        elif state == "pending-discharge":
            parts = ["WARTET AUF ENTLADUNG"]
            if remaining:
                parts.append(remaining)
            state_class = "warn"
        elif state == "empty":
            parts = ["LEER"]
            state_class = "warn"
        elif state in (None, ""):
            parts = ["--"]
            state_class = "warn"
        else:
            parts = ["UNBEKANNT"]
            state_class = "warn"

        if power_text:
            parts.append(power_text)

        self.battery_state.set_text(" · ".join(parts))
        self.set_class(self.battery_state, state_class)

    def set_soh_alert(self, active):
        active = bool(active)
        if active == self.soh_alert_active:
            return

        self.soh_alert_active = active
        self.soh_blink_on = active

        if active:
            self.battery_value.add_css_class("soh-alert")
        else:
            self.battery_value.remove_css_class("soh-alert")

    def update_soh_blink(self):
        if self.window is None:
            return False

        if not self.soh_alert_active:
            self.soh_blink_on = False
            self.battery_value.remove_css_class("soh-alert")
            return True

        self.soh_blink_on = not self.soh_blink_on
        if self.soh_blink_on:
            self.battery_value.add_css_class("soh-alert")
        else:
            self.battery_value.remove_css_class("soh-alert")

        return True

    def refresh_battery_timer(self):
        if self.window is None:
            return False
        self.refresh_battery()
        return True

    def refresh(self):
        if self.wiping or self.confirming:
            return
        self.refresh_battery()
        target, candidate_count = wipe_detect_target()
        self.disk_info = target
        self.disk = target.get("path") if target else None
        details = wipe_disk_details(self.disk)
        if candidate_count > 1:
            self.disk_badge.set_text("MEHRDEUTIG")
            self.set_class(self.disk_badge, "warn")
            self.disk_value.set_text("MEHRERE DATENTRÄGER GEFUNDEN")
            self.set_class(self.disk_value, "warn")
            self.disk_note.set_text(
                "Mehrere interne SSDs erkannt – automatische Auswahl gesperrt."
            )
            self.wipe_button.set_sensitive(False)
        elif details is None:
            self.disk_badge.set_text("NOT FOUND")
            self.set_class(self.disk_badge, "warn")
            self.disk_value.set_text("SSD NICHT GEFUNDEN")
            self.set_class(self.disk_value, "warn")
            self.disk_note.set_text("Kein sicherer interner Datenträger erkannt.")
            self.wipe_button.set_sensitive(False)
        else:
            self.disk_badge.set_text("BEREIT")
            self.set_class(self.disk_badge, "neutral")
            self.last_disk_display = f"{details['size']} • {details['model']}"
            self.disk_value.set_text(self.last_disk_display)
            self.apply_disk_smart_color()
            self.disk_note.set_text(f"{self.disk} · Bereit zum Löschen.")
            self.wipe_button.set_sensitive(True)
            self.ensure_smart_check()


    def close_smart_window(self, *_):
        window = self.smart_window
        self.smart_window = None
        self.smart_refresh_button = None
        if window is not None:
            try:
                window.destroy()
            except Exception:
                pass
        return True

    def on_smart_key(self, _controller, keyval, _keycode, state):
        name = Gdk.keyval_name(keyval) or ""
        if name == "Escape" or (
            state & Gdk.ModifierType.CONTROL_MASK and name.lower() == "w"
        ):
            self.close_smart_window()
            return True
        return False

    @staticmethod
    def _restore_center_new_windows(previous):
        try:
            subprocess.run(
                ["gsettings", "set", "org.gnome.mutter", "center-new-windows", previous],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
                check=False,
            )
        except Exception:
            pass
        return False

    def _bind_smart_window(self, window):
        try:
            if window.get_visible():
                window.set_transient_for(self.window)
        except Exception:
            pass
        return False

    def _present_smart_centered(self, window):
        previous = None
        try:
            current = subprocess.check_output(
                ["gsettings", "get", "org.gnome.mutter", "center-new-windows"],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
            ).strip().lower()
            if current in {"true", "false"}:
                previous = current
                if current != "true":
                    subprocess.run(
                        ["gsettings", "set", "org.gnome.mutter", "center-new-windows", "true"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=1.5,
                        check=False,
                    )
        except Exception:
            previous = None
        window.present()
        if previous == "false":
            GLib.timeout_add(500, self._restore_center_new_windows, previous)
        GLib.timeout_add(650, self._bind_smart_window, window)

    def _cache_smart_window_data(self, disk, data):
        overall = self.smart_overall_from_data(data)
        if disk:
            self.smart_data = data
            self.smart_disk_path = disk
            self.smart_overall = overall
            if self.disk == disk:
                self.apply_disk_smart_color()
        return overall

    def _build_smart_window_content(self, data, disk):
        overall = self.smart_overall_from_data(data)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.set_margin_top(12)
        outer.set_margin_bottom(12)
        outer.set_margin_start(14)
        outer.set_margin_end(14)

        model = Gtk.Label(
            label=f"{data['model']}  •  {disk or '--'}"
        )
        model.set_xalign(0)
        model.set_wrap(True)
        model.add_css_class("smart-subtitle")
        outer.append(model)

        meta = Gtk.Label(
            label=f"Seriennummer: {data['serial']}  •  Firmware: {data['firmware']}"
        )
        meta.set_xalign(0)
        meta.set_wrap(True)
        meta.add_css_class("smart-subtitle")
        outer.append(meta)

        overall_text = {
            "good": "GESAMTBEWERTUNG: IN ORDNUNG",
            "warn": "GESAMTBEWERTUNG: AUFFÄLLIGKEITEN",
            "bad": "GESAMTBEWERTUNG: FEHLER / PRÜFEN",
        }[overall]
        summary = Gtk.Label(label=overall_text)
        summary.set_xalign(0)
        summary.add_css_class("smart-summary")
        outer.append(summary)

        grid = Gtk.Grid()
        grid.set_row_spacing(5)
        grid.set_column_spacing(12)
        grid.set_hexpand(True)
        grid.add_css_class("smart-card")

        for col, text_value in enumerate(("WERT", "MESSWERT", "EINORDNUNG")):
            header = Gtk.Label(label=text_value)
            header.set_xalign(0)
            header.add_css_class("smart-header")
            grid.attach(header, col, 0, 1, 1)

        for row_index, (label_text, value_text, help_text, status) in enumerate(
            data["rows"], 1
        ):
            label = Gtk.Label(label=label_text)
            label.set_xalign(0)
            label.set_valign(Gtk.Align.START)
            label.set_wrap(True)
            label.set_max_width_chars(30)
            label.add_css_class("smart-label")

            value = Gtk.Label(label=value_text)
            value.set_xalign(0)
            value.set_valign(Gtk.Align.START)
            value.set_wrap(True)
            value.set_max_width_chars(18)
            value.add_css_class("smart-value")
            value.add_css_class(status)

            help_label = Gtk.Label(label=help_text)
            help_label.set_xalign(0)
            help_label.set_valign(Gtk.Align.START)
            help_label.set_hexpand(True)
            help_label.set_wrap(True)
            help_label.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
            help_label.set_max_width_chars(46)
            help_label.add_css_class("smart-help")

            grid.attach(label, 0, row_index, 1, 1)
            grid.attach(value, 1, row_index, 1, 1)
            grid.attach(help_label, 2, row_index, 1, 1)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_hexpand(True)
        scroll.set_vexpand(False)
        scroll.set_propagate_natural_height(True)
        scroll.set_max_content_height(650)
        scroll.set_child(grid)
        outer.append(scroll)

        footer = Gtk.Label(label="Schließen mit ESC oder STRG+W")
        footer.set_xalign(0)
        footer.add_css_class("smart-legend")
        outer.append(footer)

        return outer

    def refresh_smart_window(self, *_):
        if self.smart_window is None or not self.disk:
            return False

        disk = self.disk
        button = self.smart_refresh_button
        if button is not None:
            button.set_sensitive(False)

        threading.Thread(
            target=self._refresh_smart_window_worker,
            args=(disk,),
            daemon=True,
            name="uwuntu-smart-refresh",
        ).start()
        return False

    def _refresh_smart_window_worker(self, disk):
        data = smart_collect(disk)
        GLib.idle_add(self._finish_smart_window_refresh, disk, data)

    def _finish_smart_window_refresh(self, disk, data):
        button = self.smart_refresh_button
        if button is not None:
            button.set_sensitive(True)

        if self.smart_window is None or self.disk != disk:
            return False

        self._cache_smart_window_data(disk, data)
        self.smart_window.set_child(
            self._build_smart_window_content(data, disk)
        )
        self.smart_window.set_default_size(790, -1)
        self.smart_window.queue_resize()
        log(f"SMART-Werte neu eingelesen: {disk}")
        return False

    def show_smart_window(self, *_):
        if self.smart_window is not None:
            try:
                self.smart_window.present()
                return False
            except Exception:
                self.smart_window = None
                self.smart_refresh_button = None

        disk = self.disk
        if self.smart_disk_path == disk and self.smart_data is not None:
            data = self.smart_data
        else:
            data = smart_collect(disk)
            self._cache_smart_window_data(disk, data)

        app = self.window.get_application()
        window = Gtk.ApplicationWindow(application=app)
        window.set_title("SSD / SMART-WERTE")
        window.set_default_size(790, -1)
        window.set_resizable(True)
        window.connect("close-request", self.close_smart_window)

        header_bar = Gtk.HeaderBar()
        header_bar.set_show_title_buttons(True)

        title_label = Gtk.Label(label="SSD / SMART-WERTE")
        title_label.add_css_class("title")
        header_bar.set_title_widget(title_label)

        refresh_button = Gtk.Button(label="REFRESH")
        refresh_button.add_css_class("action")
        refresh_button.add_css_class("header-refresh")
        refresh_button.set_focusable(False)
        refresh_button.connect("clicked", self.refresh_smart_window)
        header_bar.pack_end(refresh_button)
        window.set_titlebar(header_bar)

        key_controller = Gtk.EventControllerKey.new()
        key_controller.connect("key-pressed", self.on_smart_key)
        window.add_controller(key_controller)

        window.set_child(self._build_smart_window_content(data, disk))
        self.smart_window = window
        self.smart_refresh_button = refresh_button
        self._present_smart_centered(window)
        log(f"SMART-Fenster geöffnet: {disk or '--'}")
        return False

    def clear_actions(self):
        child = self.action_area.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            self.action_area.remove(child)
            child = nxt

    def restore_wipe_button(self):
        self.clear_actions()
        self.action_area.set_halign(Gtk.Align.END)
        self.action_area.set_hexpand(False)
        self.action_area.append(self.wipe_button)
        self.wipe_button.set_sensitive(bool(self.disk and self.disk_info))
        self.window.set_default_widget(self.wipe_button)

    def on_wipe_clicked(self, button):
        if self.wiping or self.confirming or not self.disk or not self.disk_info:
            return

        # Das sichtbare Ziel wird schon beim ersten Klick eingefroren.
        self.confirmed_disk = self.disk
        self.confirmed_identity = wipe_device_identity(self.disk_info)
        self.confirming = True
        if self.refresh_button is not None:
            self.refresh_button.set_sensitive(False)

        self.clear_actions()
        self.action_area.set_halign(Gtk.Align.END)
        self.action_area.set_hexpand(False)

        warning = Gtk.Label(label="WIRKLICH LÖSCHEN?")
        warning.set_xalign(0)
        warning.set_hexpand(False)
        warning.add_css_class("confirm-warning")

        cancel = Gtk.Button(label="ABBRECHEN")
        cancel.connect("clicked", self.on_cancel)
        yes = Gtk.Button(label="JA")
        yes.add_css_class("confirm")
        yes.connect("clicked", self.on_confirm)
        yes.connect("notify::has-focus", self.on_action_focus_changed)

        self.action_area.append(warning)
        self.action_area.append(cancel)
        self.action_area.append(yes)
        self.window.set_default_widget(yes)
        yes.grab_focus()

        self.disk_badge.set_text("BESTÄTIGEN")
        self.set_class(self.disk_badge, "warn")
        self.disk_note.set_text(
            f"Alle Partitions-/Dateisystem-Signaturen auf {self.confirmed_disk} werden entfernt."
        )

    def on_cancel(self, button):
        if self.wiping:
            return
        self.confirming = False
        self.confirmed_disk = None
        self.confirmed_identity = None
        if self.refresh_button is not None:
            self.refresh_button.set_sensitive(True)
        self.restore_wipe_button()
        self.refresh()
        GLib.idle_add(self.focus_wipe_button)

    def on_confirm(self, button):
        if (
            self.wiping
            or not self.confirming
            or not self.confirmed_disk
            or not self.confirmed_identity
        ):
            return
        self.confirming = False
        self.wiping = True
        self.clear_actions()
        self.disk_badge.set_text("WIRD GELÖSCHT")
        self.set_class(self.disk_badge, "live")
        self.disk_value.set_text(
            (self.last_disk_display + " • Wird gelöscht …")
            if self.last_disk_display else "SSD WIRD GELÖSCHT …"
        )
        self.apply_disk_smart_color()
        self.disk_note.set_text("Bitte warten.")
        threading.Thread(
            target=self.wipe_worker,
            args=(self.confirmed_disk, self.confirmed_identity),
            daemon=True,
        ).start()

    def wipe_worker(self, disk, identity):
        # Direkt vor dem ersten Unmount exakt Ziel und Identität erneut prüfen;
        # bei Änderungen wird abgebrochen und niemals ein Ersatzgerät gewählt.
        if not wipe_validate_target(disk, identity):
            GLib.idle_add(
                self.finish_error,
                f"{disk or 'Ziel'} ist nicht mehr sicher – Wipe abgebrochen.",
            )
            return

        rc, out, _ = wipe_run(["lsblk", "-nrpo", "NAME,TYPE", disk])
        if rc == 0:
            children = []
            for line in out.splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 2 and parts[-1] == "part":
                    children.append(parts[0])
            for part in reversed(children):
                wipe_run(["umount", part], timeout=10, sudo=True)
                wipe_run(["fuser", "-k", part], timeout=10, sudo=True)

        wipe_run(["umount", disk], timeout=10, sudo=True)
        wipe_run(["fuser", "-k", disk], timeout=10, sudo=True)

        rc, _, err = wipe_run(["wipefs", "-a", disk], timeout=30, sudo=True)
        if rc != 0:
            GLib.idle_add(self.finish_error, err or "wipefs fehlgeschlagen")
            return

        wipe_run(["partprobe", disk], timeout=15, sudo=True)
        clean, reason = wipe_disk_is_clean(disk)
        if not clean:
            GLib.idle_add(self.finish_error, reason)
            return

        GLib.idle_add(self.finish_success, disk)

    def finish_success(self, disk):
        self.wiping = False
        self.confirmed_disk = None
        self.confirmed_identity = None
        if self.refresh_button is not None:
            self.refresh_button.set_sensitive(True)
        self.disk_badge.set_text("GELÖSCHT")
        self.set_class(self.disk_badge, "good")
        self.disk_value.set_text(
            (self.last_disk_display + " • Erfolgreich gelöscht")
            if self.last_disk_display else "Erfolgreich gelöscht"
        )
        self.apply_disk_smart_color()
        self.disk_note.set_text(
            f"{disk}: keine Signaturen und keine Partitionen mehr erkannt."
        )
        self.clear_actions()
        return False

    def finish_error(self, message):
        self.wiping = False
        self.confirming = False
        self.confirmed_disk = None
        self.confirmed_identity = None
        if self.refresh_button is not None:
            self.refresh_button.set_sensitive(True)
        self.disk_badge.set_text("ERROR")
        self.set_class(self.disk_badge, "bad")
        if self.last_disk_display:
            self.disk_value.set_text(
                self.last_disk_display + " • Löschen fehlgeschlagen"
            )
        else:
            self.disk_value.set_text("Löschen fehlgeschlagen")
        self.apply_disk_smart_color()
        self.disk_note.set_text(str(message))
        self.restore_wipe_button()
        self.wipe_button.set_sensitive(False)
        return False

    def on_action_focus_changed(self, widget, _pspec):
        try:
            focused = bool(widget.get_property("has-focus"))
        except Exception:
            focused = False
        if focused:
            widget.add_css_class("keyboard-focus")
        else:
            widget.remove_css_class("keyboard-focus")

    def focus_wipe_button(self):
        if not self.wiping and self.wipe_button.get_sensitive():
            self.window.set_default_widget(self.wipe_button)
            try:
                self.window.set_focus(self.wipe_button)
            except Exception:
                pass
            self.wipe_button.grab_focus()
        return False



# ============================================================
# Audio – kompakte Experiment-Leiste im Network/Wipe-Fenster
# ============================================================
AUDIO_ENGINE_APP_ID = "com.david.UwuntuAudioEngineExperiment"
AUDIO_UI_STATE_FILE = (
    Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp")
    / "uwuntu_audio_engine_ui.json"
)

class CompactAudioPanel:
    def __init__(self):
        self.waveform = []
        self.wave_color = "orange"
        self.last_engine_start = 0.0
        self.created_at = time.monotonic()
        self.button_states = {
            "left": "orange",
            "both": "orange",
            "right": "orange",
            "auto": "orange",
        }

        self.root = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=4,
        )
        self.root.set_hexpand(True)
        self.root.set_vexpand(False)
        self.root.add_css_class("card")

        title = Gtk.Label(label="AUDIO")
        title.set_xalign(0)
        title.add_css_class("card-title")
        self.root.append(title)

        audio_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=5,
        )
        audio_row.set_hexpand(True)
        audio_row.set_vexpand(False)

        self.wave = Gtk.DrawingArea()
        self.wave.set_content_width(210)
        self.wave.set_content_height(88)
        self.wave.set_hexpand(True)
        self.wave.set_vexpand(False)
        self.wave.set_draw_func(self.draw_wave)
        audio_row.append(self.wave)

        self.buttons = {}
        button_grid = Gtk.Grid()
        button_grid.set_row_spacing(4)
        button_grid.set_column_spacing(4)
        button_grid.set_row_homogeneous(True)
        button_grid.set_column_homogeneous(True)
        button_grid.set_hexpand(False)
        button_grid.set_vexpand(True)

        specs = (
            ("left", "← LINKS", 0, 0),
            ("right", "RECHTS →", 1, 0),
            ("both", "↑ MITTE", 0, 1),
            ("auto", "AUTO ↓", 1, 1),
        )
        for action, label, column, row in specs:
            button = Gtk.Button(label=label)
            button.set_focusable(False)
            button.set_hexpand(True)
            button.set_vexpand(True)
            button.add_css_class("audio-mini")
            button.add_css_class("audio-orange")
            button.connect(
                "clicked",
                lambda _button, value=action: self.trigger(value),
            )
            self.buttons[action] = button
            button_grid.attach(button, column, row, 1, 1)

        audio_row.append(button_grid)

        # Der normale Tiling-Slot startet die Engine parallel. NC wartet
        # zunächst kurz darauf und startet sie nur selbst, falls der Slot
        # nicht läuft (z. B. bei einzeln geöffnetem Network Check).
        self.root.append(audio_row)

        GLib.timeout_add(16, self.poll_state)

    def ensure_engine(self):
        try:
            if AUDIO_UI_STATE_FILE.exists():
                if time.time() - AUDIO_UI_STATE_FILE.stat().st_mtime <= 2.5:
                    return
        except Exception:
            pass

        now = time.monotonic()
        if now - self.last_engine_start < 2.0:
            return
        self.last_engine_start = now

        script = Path.home() / ".local/bin/uwuntu-audio-test.sh"
        if not script.exists():
            return

        env = os.environ.copy()
        env["UWUNTU_AUDIO_ENGINE"] = "1"
        try:
            subprocess.Popen(
                [str(script)],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception:
            pass

    def trigger(self, action):
        self.ensure_engine()
        try:
            subprocess.Popen(
                [
                    "gapplication",
                    "action",
                    AUDIO_ENGINE_APP_ID,
                    action,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception:
            pass

    def set_button_state(self, action, state):
        button = self.buttons.get(action)
        if button is None:
            return
        if state not in {"orange", "blue", "green", "red"}:
            state = "orange"
        if self.button_states.get(action) == state:
            return
        for css_class in (
            "audio-orange",
            "audio-blue",
            "audio-green",
            "audio-red",
        ):
            button.remove_css_class(css_class)
        button.add_css_class("audio-" + state)
        self.button_states[action] = state

    def poll_state(self):
        data = None
        try:
            if AUDIO_UI_STATE_FILE.exists():
                age = time.time() - AUDIO_UI_STATE_FILE.stat().st_mtime
                if age <= 2.5:
                    data = json.loads(
                        AUDIO_UI_STATE_FILE.read_text(encoding="utf-8")
                    )
        except Exception:
            data = None

        if not isinstance(data, dict):
            self.waveform = []
            self.wave_color = "orange"
            if time.monotonic() - self.created_at >= 1.5:
                self.ensure_engine()
            self.wave.queue_draw()
            return True

        states = data.get("buttons") or {}
        for action in self.buttons:
            self.set_button_state(
                action,
                str(states.get(action, "orange")),
            )

        values = data.get("waveform")
        if isinstance(values, list):
            cleaned = []
            for value in values[:512]:
                try:
                    cleaned.append(max(-1.0, min(1.0, float(value))))
                except Exception:
                    pass
            self.waveform = cleaned
        else:
            self.waveform = []

        self.wave_color = str(data.get("color") or "orange")
        self.wave.queue_draw()
        return True

    def draw_wave(self, _area, cr, width, height):
        colors = {
            "green": (0.38, 0.83, 0.42),
            "blue": (0.35, 0.64, 1.0),
            "red": (1.0, 0.30, 0.30),
            "orange": (0.96, 0.65, 0.14),
        }

        # Dunklen Waveform-Bereich wie die übrigen Karten abrunden und
        # sämtliche Zeichenoperationen auf diese Fläche begrenzen.
        radius = min(8.0, width / 2.0, height / 2.0)
        cr.new_sub_path()
        cr.arc(width - radius, radius, radius, -math.pi / 2.0, 0.0)
        cr.arc(
            width - radius,
            height - radius,
            radius,
            0.0,
            math.pi / 2.0,
        )
        cr.arc(
            radius,
            height - radius,
            radius,
            math.pi / 2.0,
            math.pi,
        )
        cr.arc(
            radius,
            radius,
            radius,
            math.pi,
            3.0 * math.pi / 2.0,
        )
        cr.close_path()
        cr.set_source_rgb(0.09, 0.09, 0.11)
        cr.fill_preserve()
        cr.clip()

        # Horizontal die komplette dunkle Fläche nutzen. Nur oben/unten bleibt
        # der kleine Abstand für die maximale Waveform-Amplitude erhalten.
        x0 = 0.0
        x1 = float(width)
        y0 = height * 0.05
        y1 = height - y0
        plot_width = max(2.0, x1 - x0)
        plot_height = max(2.0, y1 - y0)
        mid = y0 + plot_height / 2.0

        # Testweise wieder das dezente Gitter des früheren
        # Audio-Renderers hinter die Waveform legen.
        cr.set_source_rgb(0.16, 0.16, 0.19)
        cr.set_line_width(1.0)

        for index in range(1, 10):
            x = x0 + plot_width * index / 10.0
            cr.move_to(x, y0)
            cr.line_to(x, y1)
            cr.stroke()

        for fraction in (0.25, 0.75):
            y = y0 + plot_height * fraction
            cr.move_to(x0, y)
            cr.line_to(x1, y)
            cr.stroke()

        # Die Nulllinie bleibt etwas heller/stärker als das restliche Gitter.
        cr.set_source_rgb(0.24, 0.24, 0.28)
        cr.set_line_width(1.2)
        cr.move_to(x0, mid)
        cr.line_to(x1, mid)
        cr.stroke()

        values = self.waveform
        if len(values) < 2:
            return

        # Wie vorher etwa ein Stützpunkt je 1,5 Pixel. Die Engine liefert
        # genügend Samples, sodass die Kurve auch bei breiter Audio-Leiste
        # nicht zu einem spitzen Polygon mit wenigen Ecken wird.
        point_count = min(
            len(values),
            max(2, int(plot_width / 1.5)),
        )
        if point_count < len(values):
            last = len(values) - 1
            indices = [
                round(index * last / max(1, point_count - 1))
                for index in range(point_count)
            ]
            draw_values = [values[index] for index in indices]
        else:
            draw_values = values

        color = colors.get(self.wave_color, colors["orange"])
        cr.set_source_rgb(*color)
        cr.set_line_width(2.5)
        cr.set_line_join(1)  # cairo.LINE_JOIN_ROUND
        cr.set_line_cap(1)   # cairo.LINE_CAP_ROUND

        step = plot_width / max(1, len(draw_values) - 1)
        amplitude = plot_height * 0.45
        for index, value in enumerate(draw_values):
            x = x0 + index * step
            y = max(y0 + 1.5, min(y1 - 1.5, mid - value * amplitude))
            if index == 0:
                cr.move_to(x, y)
            else:
                cr.line_to(x, y)
        cr.stroke()

class NetworkCheckApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.david.NetworkCheck")

        smart_action = Gio.SimpleAction.new("smart", None)
        smart_action.connect("activate", self.on_smart_app_action)
        self.add_action(smart_action)

        self.window = None
        self.cards = {}
        self.stop_event = threading.Event()
        self.test_queue = queue.Queue()
        self.pending = set()
        self.testing_kinds = set()
        self.testing_ifaces = {}
        self.current_proc = {"lan": None, "wifi": None}
        self.proc_lock = threading.Lock()

        self.last_connected = set()
        self.last_default = None
        self.last_lan_link = {}
        self.max_wifi_link = {}
        self.initial_scan_done = False
        # Ergebnisse bleiben während der gesamten Programmsitzung erhalten.
        self.results = {
            "lan": {
                "iface": None,
                "link": None,
                "ping": None,
                "ping_ok": None,
                "down": None,
                "up": None,
                "tested": False,
                "passed": None,
            },
            "wifi": {
                "iface": None,
                "link": None,
                "ping": None,
                "ping_ok": None,
                "down": None,
                "up": None,
                "tested": False,
                "passed": None,
            },
        }
    # --------------------------------------------------------
    # GUI
    # --------------------------------------------------------

    def do_activate(self):
        if self.window:
            self.window.present()
            # Wichtig: Das Fenster kann bereits aktiv sein. Dann gibt es kein
            # neues notify::is-active-Signal. WIPE SSD deshalb bei jeder
            # erneuten GApplication-Aktivierung ausdrücklich neu fokussieren.
            if hasattr(self, "wipe_panel"):
                GLib.idle_add(self.wipe_panel.focus_wipe_button)
                self._wipe_focus_attempts = 0
                GLib.timeout_add(120, self.ensure_wipe_focus_after_start)
            return

        self.install_css()

        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_title("Network Check v2.64 + Wipe Auto v3.40 + Audio Test v1.29")
        self.window.set_default_size(960, 520)

        # Einheitliche Titelleiste: Name mittig, gemeinsamer REFRESH rechts.
        self.header_bar = Gtk.HeaderBar()
        self.header_bar.set_show_title_buttons(True)

        title_label = Gtk.Label(label="Network Check v2.64 + Wipe Auto v3.40 + Audio Test v1.29")
        title_label.add_css_class("title")
        self.header_bar.set_title_widget(title_label)

        self.header_refresh_button = Gtk.Button(label="REFRESH")
        self.header_refresh_button.add_css_class("action")
        self.header_refresh_button.add_css_class("header-refresh")
        self.header_refresh_button.set_focusable(False)
        self.header_refresh_button.connect("clicked", self.on_refresh_all)
        self.header_bar.pack_end(self.header_refresh_button)

        self.window.set_titlebar(self.header_bar)

        # Das kombinierte Fenster enthält jetzt WIPE SSD. Sobald es vom
        # Kiosk/Benutzer in den Vordergrund geholt wird, bekommt WIPE SSD
        # wieder automatisch den Tastaturfokus, damit ENTER wie früher direkt
        # den Wipe-Dialog startet.
        self.window.connect("notify::is-active", self.on_window_active_changed)

        key_controller = Gtk.EventControllerKey.new()
        key_controller.connect("key-pressed", self.on_key_pressed)
        self.window.add_controller(key_controller)

        # Gemeinsames Fenster ohne zusätzliche Refresh-Zeile im Inhalt.
        # REFRESH sitzt jetzt ausschließlich in der Titelleiste.
        shell = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        shell.set_margin_top(4)
        shell.set_margin_bottom(4)
        shell.set_margin_start(4)
        shell.set_margin_end(4)

        # Einspaltiges 4-Zeilen-Layout über die komplette Fensterbreite:
        # 1. LAN
        # 2. WLAN
        # 3. BATTERY
        # 4. SSD
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        content.set_hexpand(True)
        content.set_vexpand(True)

        # global_status bleibt intern für die bestehende Testlogik,
        # wird aber bewusst nicht angezeigt.
        self.global_status = Gtk.Label(label="Starting …")

        self.cards["lan"] = ConnectionCard("LAN")
        self.cards["wifi"] = ConnectionCard("WLAN")
        self.attach_network_metric_clicks()

        for key in ("lan", "wifi"):
            self.cards[key].root.set_hexpand(True)
            self.cards[key].root.set_vexpand(False)

        # LAN und WLAN teilen sich im Experiment eine Zeile. Dadurch wird
        # genau der Platz frei, den die schmale Audio-Leiste unten benötigt.
        network_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=3,
        )
        network_row.set_hexpand(True)
        network_row.set_vexpand(False)
        # LAN und WLAN bleiben bei jeder Live-Anzeige exakt gleich breit.
        # Die Aufteilung folgt weiter der verfügbaren Fensterbreite.
        network_row.set_homogeneous(True)
        network_row.append(self.cards["lan"].root)
        network_row.append(self.cards["wifi"].root)
        content.append(network_row)

        self.wipe_panel = WipeCompactPanel(self.window)
        self.wipe_panel.refresh_button = self.header_refresh_button
        self.wipe_panel.root.set_size_request(0, -1)
        self.wipe_panel.root.set_hexpand(True)
        self.wipe_panel.root.set_vexpand(False)
        content.append(self.wipe_panel.root)

        # Audio bleibt dauerhaft sichtbar: Überschrift oben, darunter
        # Waveform ab ganz links und die vier Testbuttons.
        self.audio_panel = CompactAudioPanel()
        content.append(self.audio_panel.root)

        shell.append(content)

        self.window.set_child(shell)
        self.window.present()

        # Beim Start mehrmals kurz nachfassen. Unter Wayland/Tiling Assistant
        # kann das Fenster erst einige Millisekunden nach present() wirklich
        # aktiv werden. Das macht den WIPE-SSD-Fokus beim Kioskstart robust.
        self._wipe_focus_attempts = 0
        GLib.timeout_add(180, self.ensure_wipe_focus_after_start)

        log("Network Check gestartet.")

        # Zwei Worker erlauben LAN- und WLAN-Test gleichzeitig.
        for worker_no in range(2):
            threading.Thread(
                target=self.worker,
                name=f"network-check-worker-{worker_no + 1}",
                daemon=True,
            ).start()
        # Zustandsüberwachung. Kein fester Start-Sleep:
        # die App reagiert, sobald NetworkManager einen Zustand meldet.
        GLib.timeout_add(750, self.poll_network)

    def on_window_active_changed(self, window, _pspec):
        try:
            active = bool(window.get_property("is-active"))
        except Exception:
            active = False
        if active and hasattr(self, "wipe_panel"):
            GLib.idle_add(self.wipe_panel.focus_wipe_button)

    def ensure_wipe_focus_after_start(self):
        if self.window is None or not hasattr(self, "wipe_panel"):
            return False

        self._wipe_focus_attempts = getattr(self, "_wipe_focus_attempts", 0) + 1

        # Fokus bei jedem Versuch setzen. Das funktioniert auch dann, wenn
        # das Fenster bereits aktiv war und deshalb kein is-active-Signal
        # mehr ausgelöst wurde.
        self.wipe_panel.focus_wipe_button()

        try:
            active = bool(self.window.get_property("is-active"))
        except Exception:
            active = False

        try:
            focused = bool(
                self.wipe_panel.wipe_button.get_property("has-focus")
            )
        except Exception:
            focused = False

        if active and focused:
            return False

        # Bis ca. 5,4 Sekunden nachfassen. Zusätzlich aktiviert der Kiosk
        # das Fenster am Ende noch einmal per gapplication + AT-SPI.
        return self._wipe_focus_attempts < 45

    def install_css(self):
        css = b"""
        headerbar {
            min-height: 26px;
            padding: 0px 4px;
            margin: 0px;
        }
        headerbar .title {
            font-size: 11px;
            font-weight: 700;
            padding: 0px;
            margin: 0px;
        }
        headerbar button {
            min-height: 20px;
            min-width: 20px;
            padding: 0px 4px;
            margin-top: 0px;
            margin-bottom: 0px;
        }
        headerbar button.header-refresh {
            min-height: 20px;
            padding: 0px 6px;
            border-radius: 6px;
            font-size: 11px;
            font-weight: 800;
        }

        button.audio-mini {
            min-height: 34px;
            min-width: 82px;
            padding: 2px 7px;
            border-radius: 7px;
            font-size: 10px;
            font-weight: 800;
        }
        button.audio-mini.audio-orange {
            background: #232329;
            color: #f5a623;
            border: 1px solid #f5a623;
        }
        button.audio-mini.audio-blue {
            background: #232329;
            color: #5aa2ff;
            border: 1px solid #5aa2ff;
        }
        button.audio-mini.audio-green {
            background: #232329;
            color: #61d36b;
            border: 1px solid #61d36b;
        }
        button.audio-mini.audio-red {
            background: #232329;
            color: #ff4c4c;
            border: 1px solid #ff4c4c;
        }

        window {
            background: #101216;
            color: #f4f4f5;
        }

        .main-title {
            font-size: 17px;
            font-weight: 800;
            letter-spacing: 0.4px;
        }
        .version {
            color: #9d9da7;
            font-size: 10px;
            font-weight: 600;
        }

        .global-status {
            color: #9d9da7;
            font-size: 11px;
            font-weight: 600;
        }

        .card {
            background: #191c22;
            border: 1px solid #303641;
            border-radius: 8px;
            padding: 5px 6px;
        }

        .card-title {
            font-size: 13px;
            font-weight: 800;
        }
        .mac-error {
            color: #ff4c4c;
        }
        .mac-warning {
            color: #f5a623;
        }

        .interface {
            color: #9d9da7;
            font-size: 11px;
            font-weight: 600;
        }

        .badge {
            border-radius: 8px;
            padding: 3px 7px;
            font-size: 12px;
            font-weight: 800;
        }

        .ssd-status {
            background: transparent;
            border: none;
            padding: 0px 1px;
            font-size: 12px;
            font-weight: 800;
        }

        .metric {
            background: #111318;
            border-radius: 8px;
            padding: 3px 4px;
        }
        .metric-caption {
            color: #9d9da7;
            font-size: 9px;
            font-weight: 600;
        }

        .metric-value {
            font-size: 14px;
            font-weight: 800;
        }

        .note {
            color: #9d9da7;
            font-size: 10px;
            font-weight: 500;
        }

        .good {
            color: #61d36b;
        }

        .bad {
            color: #ff4c4c;
            background: #111318;
        }

        .warn {
            color: #f5a623;
        }
        .neutral {
            color: #f4f4f5;
        }

        .live {
            color: #5aa2ff;
        }

        button.action {
            font-size: 12px;
            font-weight: 800;
            padding: 3px 8px;
            min-height: 24px;
            border-radius: 8px;
        }

        .wipe-big {
            background: #111318;
            border: 1px solid transparent;
            border-radius: 8px;
            padding: 4px 6px;
            font-size: 17px;
            font-weight: 800;
        }

        .wipe-big.soh-alert {
            background: #ff4c4c;
            color: #f4f4f5;
            border-color: #ff4c4c;
        }


        .smart-title {
            color: #f4f4f5;
            font-size: 17px;
            font-weight: 800;
        }
        .smart-subtitle {
            color: #f4f4f5;
            font-size: 10px;
            font-weight: 600;
        }
        .smart-summary {
            color: #f4f4f5;
            font-size: 13px;
            font-weight: 800;
        }
        .smart-legend {
            color: #f4f4f5;
            font-size: 10px;
            font-weight: 600;
        }
        .smart-card {
            background: #191c22;
            border: 1px solid #303641;
            border-radius: 8px;
            padding: 8px;
        }
        .smart-header {
            color: #f4f4f5;
            font-size: 10px;
            font-weight: 800;
        }
        .smart-label, .smart-help {
            color: #f4f4f5;
            font-size: 11px;
            font-weight: 700;
        }
        .smart-value {
            font-size: 11px;
            font-weight: 700;
        }
        .smart-help {
            font-weight: 600;
        }
        .disk-result {
            background: #111318;
            border: 1px solid transparent;
            border-radius: 8px;
            padding: 4px 6px;
            font-size: 17px;
            font-weight: 800;
        }

        button.danger-action {
            font-size: 11px;
            font-weight: 800;
            padding: 0px 9px;
            border-radius: 8px;
        }

        /* Clear keyboard focus, matching the old standalone Wipe Auto. */
        button.danger-action.keyboard-focus,
        button.danger-action:focus {
            background: #5aa2ff;
            color: #f4f4f5;
            border-color: #5aa2ff;
            outline: 3px solid #5aa2ff;
            outline-offset: 2px;
        }

        .confirm-warning {
            color: #ff4c4c;
            background: #111318;
            border-radius: 8px;
            padding: 6px 10px;
            font-size: 11px;
            font-weight: 800;
        }

        button.confirm {
            color: #ff4c4c;
            font-size: 12px;
            font-weight: 800;
        }

        button.confirm.keyboard-focus,
        button.confirm:focus {
            background: #5aa2ff;
            color: #f4f4f5;
            border-color: #5aa2ff;
            outline: 3px solid #5aa2ff;
            outline-offset: 2px;
        }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )
    # --------------------------------------------------------
    # Netzwerkzustand
    # --------------------------------------------------------

    def attach_network_metric_clicks(self):
        """Bestehende Messfelder unsichtbar für Maus und Touch aktivieren."""
        phase_map = {
            "link": "link",
            "ping": "ping",
            "download": "down",
            "upload": "up",
        }
        for kind, card in self.cards.items():
            for box_name, phase in phase_map.items():
                box = card.metric_boxes.get(box_name)
                if box is None:
                    continue
                gesture = Gtk.GestureClick.new()
                gesture.set_button(1)
                gesture.connect(
                    "released",
                    self.on_network_metric_clicked,
                    kind,
                    phase,
                )
                box.add_controller(gesture)

    def connected_iface_for_kind(self, kind):
        devices = get_devices()
        device_type = "ethernet" if kind == "lan" else "wifi"
        preferred = self.results[kind].get("iface")

        for dev in devices[device_type]:
            if dev["connected"] and dev["iface"] == preferred:
                return preferred
        for dev in devices[device_type]:
            if dev["connected"]:
                return dev["iface"]
        return None

    def on_network_metric_clicked(
        self,
        _gesture,
        n_press,
        _x,
        _y,
        kind,
        phase,
    ):
        if n_press != 1:
            return

        iface = self.connected_iface_for_kind(kind)
        if not iface:
            card = self.cards[kind]
            card.set_state("NICHT VERBUNDEN", "warn")
            card.note_label.set_text(
                "Einzeltest nicht möglich: keine aktive Verbindung."
            )
            return

        if kind in self.testing_kinds:
            log(
                f"Einzeltest ignoriert: {kind.upper()} läuft bereits "
                f"({phase.upper()})"
            )
            return

        self.enqueue_test(
            iface,
            kind,
            f"manual click {phase}",
            phase=phase,
        )

    def best_device(self, device_list):
        if not device_list:
            return None
        return device_list[0]

    def poll_network(self):
        if self.stop_event.is_set():
            return False

        devices = get_devices()
        default_iface = get_default_iface()
        lan = self.best_device(devices["ethernet"])
        wifi = self.best_device(devices["wifi"])

        current_connected = set()
        iface_to_kind = {}

        for dev in devices["ethernet"]:
            iface_to_kind[dev["iface"]] = "lan"
            if dev["connected"]:
                current_connected.add(dev["iface"])

        for dev in devices["wifi"]:
            iface_to_kind[dev["iface"]] = "wifi"
            if dev["connected"]:
                current_connected.add(dev["iface"])
        self.refresh_card_presence("lan", lan, default_iface)
        self.refresh_card_presence("wifi", wifi, default_iface)

        # Beim ersten Scan alle verbundenen LAN-/WLAN-Interfaces einplanen.
        # Mit zwei Workern laufen LAN und WLAN parallel.
        if not self.initial_scan_done:
            self.initial_scan_done = True
            self.last_connected = set(current_connected)
            self.last_default = default_iface
            for iface in sorted(current_connected):
                kind = iface_to_kind.get(iface)
                if kind:
                    self.enqueue_test(iface, kind, "initial connected interface")
        else:
            # Neu verbundene Interfaces sofort testen, unabhängig davon, ob
            # sie gerade die Default-Route stellen.
            for iface in sorted(current_connected - self.last_connected):
                kind = iface_to_kind.get(iface)
                if kind:
                    self.enqueue_test(iface, kind, "interface connected")

            # Ein reiner Wechsel der Default-Route startet KEINEN neuen
            # Speedtest mehr. Beispiel: LAN wird nach abgeschlossenem LAN/WLAN-
            # Test abgezogen und WLAN wird dadurch Default. Das bestehende
            # WLAN-Ergebnis muss erhalten bleiben. Neue Tests werden nur durch
            # echte Neuverbindungen (oben) oder relevante Link-Änderungen
            # desselben Adapters ausgelöst.

            # LAN-Link-Speed-Wechsel ist wichtig:
            # z.B. 1000 -> 100 Mbps bei Stecker/Kontaktproblem.
            for dev in devices["ethernet"]:
                iface = dev["iface"]
                if not dev["connected"]:
                    continue

                speed = ethernet_link_speed(iface)
                previous = self.last_lan_link.get(iface)
                self.last_lan_link[iface] = speed
                if (
                    previous is not None
                    and speed is not None
                    and int(previous) != int(speed)
                ):
                    log(f"LAN Link-Speed geändert: {iface}: {previous} -> {speed} Mbps")
                    self.enqueue_test(iface, "lan", "LAN link changed")

            self.last_connected = set(current_connected)
            self.last_default = default_iface
        return True

    def refresh_card_presence(self, kind, dev, default_iface):
        card = self.cards[kind]
        result = self.results[kind]
        if dev is None:
            card.set_title_mac(None, adapter_present=False)
            card.interface_label.set_text("Interface: --")
            if kind not in self.testing_kinds:
                card.set_state("NICHT GEFUNDEN", "warn")
                card.note_label.set_text(
                    "Kein Adapter erkannt – nicht verbaut oder prüfen."
                )
            return

        iface = dev["iface"]
        mac = iface_mac(iface)
        card.set_title_mac(mac)
        is_default = iface == default_iface
        suffix = " • AKTIV" if is_default else ""
        card.interface_label.set_text(f"Interface: {iface}{suffix}")

        if not dev["connected"]:
            if kind not in self.testing_kinds:
                card.set_state("NICHT VERBUNDEN", "warn")
                card.note_label.set_text(
                    "Adapter vorhanden, aktuell aber nicht verbunden."
                )
            return
        # Sichtbaren LINK-Wert nur für die Verbindung aktualisieren,
        # die gerade wirklich getestet wird.
        if kind in self.testing_kinds:
            speed = self.best_link_speed(iface, kind, link_speed(iface, kind))

            if speed is not None:
                result["link"] = speed
                result["iface"] = iface
                if kind == "lan":
                    klass = "good" if speed >= LAN_LINK_MIN else "bad"
                else:
                    klass = "good" if speed >= WIFI_LINK_MIN else "bad"

                card.set_metric("link", format_link_speed(speed), klass)
        # Wenn gerade nicht getestet wird, vorheriges Testergebnis erhalten.
        if kind not in self.testing_kinds:
            if result["tested"]:
                self.apply_final_state(kind)
            else:
                card.set_state("VERBUNDEN", "neutral")
                card.note_label.set_text("Bereit für Messung.")

    # --------------------------------------------------------
    # Queue / Buttons
    # --------------------------------------------------------
    def best_link_speed(self, iface, kind, speed):
        if speed is None:
            return None

        if kind != "wifi":
            return speed

        previous = self.max_wifi_link.get(iface)

        if previous is None or speed > previous:
            self.max_wifi_link[iface] = speed
            log(
                f"WLAN neuer maximaler LINK {iface}: "
                f"{speed} Mbps"
            )

        return self.max_wifi_link[iface]
    def enqueue_test(self, iface, kind, reason, phase="full"):
        key = (iface, kind)

        if key in self.pending:
            return
        if kind in self.testing_kinds:
            return

        self.pending.add(key)
        self.test_queue.put((iface, kind, reason, phase))
        log(
            f"Test eingeplant: {kind.upper()} {iface} "
            f"({reason}, phase={phase})"
        )

    def reset_refresh_values(self, devices):
        """Alle sichtbaren und internen Speedtest-Werte sofort verwerfen.

        REFRESH soll auf den ersten Blick zeigen, dass wirklich neu gemessen
        wird. Deshalb werden LINK/PING/DOWNLOAD/UPLOAD beider Karten direkt auf
        ``--`` gesetzt und alte Ergebniswerte nicht in den neuen Test
        übernommen. Hardware-/MAC-/Interface-Erkennung bleibt erhalten.
        """
        for kind in ("lan", "wifi"):
            result = self.results[kind]
            result["iface"] = None
            result["link"] = None
            result["ping"] = None
            result["ping_ok"] = None
            result["down"] = None
            result["up"] = None
            result["tested"] = False
            result["passed"] = None

            card = self.cards[kind]
            card.set_metric("link", "--", "warn")
            card.set_metric("ping", "--", "warn")
            card.set_metric("down", "--", "warn")
            card.set_metric("up", "--", "warn")

            connected = any(
                dev["connected"]
                for dev in devices["ethernet" if kind == "lan" else "wifi"]
            )
            if connected:
                card.set_state("REFRESH", "live")
                card.note_label.set_text("Neue Messung wird gestartet …")

        # WLAN-LINK ist absichtlich ein Maximum während eines einzelnen
        # Tests. Bei REFRESH muss dieses Maximum ebenfalls neu beginnen.
        self.max_wifi_link.clear()
        self.global_status.set_text("Messwerte gelöscht · neue Tests werden gestartet …")

    def on_refresh_all(self, button):
        # Ein gemeinsamer REFRESH für das komplette obere linke Fenster.
        #
        # Während Sicherheitsabfrage oder Löschvorgang darf REFRESH weder
        # das eingefrorene Ziel noch den Bedienzustand verändern.
        if self.wipe_panel.wiping or self.wipe_panel.confirming:
            return

        self.wipe_panel.restore_wipe_button()
        self.wipe_panel.refresh()
        GLib.idle_add(self.wipe_panel.focus_wipe_button)

        self.on_test_clicked(button)

    def on_test_clicked(self, button):
        devices = get_devices()

        # Zuerst ALLE bisherigen Werte sichtbar und intern löschen. Erst
        # danach neue Tests einplanen, damit der REFRESH sofort erkennbar ist.
        self.reset_refresh_values(devices)

        scheduled = 0

        for dev in devices["ethernet"]:
            if dev["connected"]:
                self.enqueue_test(dev["iface"], "lan", "manual REFRESH")
                scheduled += 1

        for dev in devices["wifi"]:
            if dev["connected"]:
                self.enqueue_test(dev["iface"], "wifi", "manual REFRESH")
                scheduled += 1

        if scheduled == 0:
            self.global_status.set_text("Keine LAN/WLAN-Verbindung vorhanden.")
        else:
            self.global_status.set_text("LAN/WLAN-Tests parallel gestartet.")

    # --------------------------------------------------------
    # Worker
    # --------------------------------------------------------
    def worker(self):
        while not self.stop_event.is_set():
            try:
                iface, kind, reason, phase = self.test_queue.get(timeout=0.5)
            except queue.Empty:
                continue

            self.pending.discard((iface, kind))

            if self.stop_event.is_set():
                break
            # Ist Interface immer noch verbunden?
            devices = get_devices()
            typ = "ethernet" if kind == "lan" else "wifi"
            still_connected = any(
                d["iface"] == iface and d["connected"]
                for d in devices[typ]
            )

            if not still_connected:
                log(f"Test übersprungen, nicht mehr verbunden: {iface}")
                continue

            if kind in self.testing_kinds:
                continue

            self.testing_kinds.add(kind)
            self.testing_ifaces[kind] = iface
            try:
                if phase == "full":
                    self.run_full_test(iface, kind, reason)
                else:
                    self.run_single_metric_test(
                        iface,
                        kind,
                        phase,
                        reason,
                    )
            except Exception as e:
                log(f"Testfehler {iface}: {e!r}")
                GLib.idle_add(self.mark_test_error, kind, iface, str(e))
            finally:
                self.testing_kinds.discard(kind)
                self.testing_ifaces.pop(kind, None)
    def run_single_metric_test(self, iface, kind, phase, reason):
        log(
            f"START EINZEL {kind.upper()} {iface}: "
            f"{phase.upper()} ({reason})"
        )

        result = self.results[kind]
        result["iface"] = iface

        if phase == "link":
            GLib.idle_add(
                self.mark_testing,
                kind,
                iface,
                "LINK",
            )
            current_link = link_speed(iface, kind)
            if kind == "wifi":
                # Manueller LINK-Klick soll den aktuellen Wert neu lesen und
                # nicht das Maximum eines früheren Speedtests konservieren.
                self.max_wifi_link.pop(iface, None)
                if current_link is not None:
                    self.max_wifi_link[iface] = current_link
            result["link"] = current_link
            GLib.idle_add(
                self.update_link_result,
                kind,
                current_link,
            )

        elif phase == "ping":
            GLib.idle_add(
                self.mark_ping_testing,
                kind,
                iface,
            )
            latency = self.measure_ping(iface)
            result["ping"] = latency
            result["ping_ok"] = latency is not None
            GLib.idle_add(
                self.update_ping_result,
                kind,
                latency,
            )

        elif phase in ("down", "up"):
            direction = "download" if phase == "down" else "upload"
            label = "DOWNLOAD" if phase == "down" else "UPLOAD"
            GLib.idle_add(
                self.mark_testing,
                kind,
                iface,
                label,
            )
            speed = self.measure_phase(
                iface,
                kind,
                direction,
            )
            result[phase] = speed
            GLib.idle_add(
                self.update_phase_final_value,
                kind,
                phase,
                speed,
            )
        else:
            raise ValueError(f"Unbekannte Einzeltest-Phase: {phase}")

        all_measured = (
            result["link"] is not None
            and result["ping_ok"] is not None
            and result["down"] is not None
            and result["up"] is not None
        )
        if all_measured:
            result["tested"] = True
            result["passed"] = self.result_passes(kind)
        else:
            result["tested"] = False
            result["passed"] = None

        GLib.idle_add(
            self.finish_single_metric_ui,
            kind,
            phase,
        )

    def run_full_test(self, iface, kind, reason):
        log(f"START {kind.upper()} {iface} ({reason})")

        result = self.results[kind]
        result["iface"] = iface
        result["ping"] = None
        result["ping_ok"] = None

        # 1) LINK sofort lesen.
        current_link = self.best_link_speed(
            iface,
            kind,
            link_speed(iface, kind),
        )
        if current_link is not None:
            result["link"] = current_link
            GLib.idle_add(
                self.update_link,
                kind,
                current_link,
            )

        if self.stop_event.is_set():
            return

        # 2) PING – bewusst sehr kurz, danach sofort Speedtest.
        GLib.idle_add(
            self.mark_ping_testing,
            kind,
            iface,
        )
        ping_ms = self.measure_ping(iface)

        result["ping"] = ping_ms
        result["ping_ok"] = ping_ms is not None

        GLib.idle_add(
            self.update_ping_result,
            kind,
            ping_ms,
        )

        if self.stop_event.is_set():
            return

        # 3) DOWNLOAD
        GLib.idle_add(
            self.mark_testing,
            kind,
            iface,
            "DOWNLOAD",
        )
        down = self.measure_phase(
            iface,
            kind,
            "download",
        )

        if self.stop_event.is_set():
            return

        result["down"] = down
        GLib.idle_add(
            self.update_phase_final_value,
            kind,
            "down",
            down,
        )

        # 4) UPLOAD
        GLib.idle_add(
            self.mark_testing,
            kind,
            iface,
            "UPLOAD",
        )
        up = self.measure_phase(
            iface,
            kind,
            "upload",
        )

        if self.stop_event.is_set():
            return

        result["up"] = up
        GLib.idle_add(
            self.update_phase_final_value,
            kind,
            "up",
            up,
        )

        result["iface"] = iface
        result["down"] = down
        result["up"] = up
        result["tested"] = True

        # Link nach dem Test nochmals lesen.
        final_link = self.best_link_speed(
            iface,
            kind,
            link_speed(iface, kind),
        )
        if final_link is not None:
            result["link"] = final_link

        result["passed"] = self.result_passes(kind)

        log(
            f"FERTIG {kind.upper()} {iface}: "
            f"Link={result['link']} Mbps, "
            f"Ping={result['ping']} ms, "
            f"PingOK={result['ping_ok']}, "
            f"Down={down:.1f} Mbps, Up={up:.1f} Mbps, "
            f"PASS={result['passed']}"
        )
        GLib.idle_add(
            self.apply_result_to_ui,
            kind,
        )

    # --------------------------------------------------------
    # Sehr schneller PING vor dem Speedtest
    # --------------------------------------------------------

    def measure_ping(self, iface):
        """Ein ICMP-Paket pro Ziel; Rückgabe = Latenz in ms oder None.

        Normalfall: erster Host antwortet nach wenigen Millisekunden.
        Nur bei Ausfall wird ein zweiter Host versucht. So bleibt der
        Vorabtest schnell und ist trotzdem weniger anfällig gegen einen
        einzelnen nicht erreichbaren Zielhost.
        """
        for target in PING_TARGETS:
            if self.stop_event.is_set():
                return None

            try:
                p = subprocess.run(
                    [
                        "ping",
                        "-4",
                        "-n",
                        "-I", iface,
                        "-c", "1",
                        "-W", str(PING_TIMEOUT_SECONDS),
                        target,
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=PING_TIMEOUT_SECONDS + 0.5,
                    env=ENV_C,
                )
            except Exception as exc:
                log(f"PING {iface} -> {target}: Fehler {exc!r}")
                continue

            if p.returncode != 0:
                log(f"PING {iface} -> {target}: keine Antwort")
                continue

            match = re.search(
                r"time[=<]\s*([0-9]+(?:\.[0-9]+)?)\s*ms",
                p.stdout,
                re.I,
            )
            if match:
                try:
                    latency = float(match.group(1))
                    log(
                        f"PING {iface} -> {target}: "
                        f"{latency:.1f} ms"
                    )
                    return latency
                except Exception:
                    pass

            # Antwort war erfolgreich, aber einzelne ping-Versionen liefern
            # bei extrem kleinen Zeiten ein anderes Textformat.
            log(
                f"PING {iface} -> {target}: Antwort OK, "
                "Latenz nicht parsebar"
            )
            return 0.0

        return None

    # --------------------------------------------------------
    # Bereitschaft
    # --------------------------------------------------------

    def wait_for_internet(self, iface):
        deadline = time.monotonic() + CONNECTIVITY_TIMEOUT
        while time.monotonic() < deadline and not self.stop_event.is_set():
            try:
                p = subprocess.run(
                    [
                        "curl",
                        "--interface", iface,
                        "--silent",
                        "--fail",
                        "--connect-timeout", "2",
                        "--max-time", "3",
                        "--output", "/dev/null",
                        CF_CHECK,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    env=ENV_C,
                )
                if p.returncode == 0:
                    log(f"Internet bereit auf {iface}")
                    return True
            except Exception:
                pass
            # Zustandsbasiertes Retry, kein Start-Delay.
            for _ in range(5):
                if self.stop_event.is_set():
                    return False
                time.sleep(0.1)

        return False

    # --------------------------------------------------------
    # Speedtest
    # --------------------------------------------------------
    def launch_download_stream(self, iface, remaining, stream_no):
        # Große Datalix-Testdatei aus Frankfurt.
        # Cache-Buster nur zur Sicherheit; der Transfer wird nach 5s beendet.
        sep = "&" if "?" in DOWNLOAD_URL else "?"
        url = f"{DOWNLOAD_URL}{sep}stream={stream_no}-{time.time_ns()}"
        cmd = [
            "curl",
            "--ipv4",
            "--interface", iface,
            "--silent",
            "--show-error",
            "--fail",
            "--location",
            "--connect-timeout", "2",
            "--max-time", f"{max(0.5, remaining):.2f}",
            "--header", "Cache-Control: no-cache",
            "--output", "/dev/null",
            url,
        ]
        return subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=ENV_C,
            start_new_session=True,
        )
    def launch_upload_stream(self, iface, remaining, stream_no):
        # Cloudflares eigener Referenz-Speedtest verwendet Uploadgrößen
        # bis 50 MB. Mehrere parallele Streams vermeiden, dass eine
        # Gigabit-Leitung durch einen einzelnen TCP-Stream limitiert wird.
        shell = (
            'head -c "$4" /dev/zero | '
            'curl --interface "$1" '
            '--silent --connect-timeout 2 '
            '--max-time "$2" '
            '--output /dev/null '
            '--request POST '
            '--header "Content-Type: application/octet-stream" '
            '--header "Cache-Control: no-cache" '
            '--data-binary @- '
            '"$3"'
        )
        return subprocess.Popen(
            [
                "bash", "-c", shell,
                "_",
                iface,
                f"{max(0.5, remaining):.2f}",
                CF_UP,
                str(CF_UP_BYTES),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=ENV_C,
            start_new_session=True,
        )

    def set_current_proc(self, kind, procs):
        with self.proc_lock:
            self.current_proc[kind] = procs
    def kill_process(self, proc):
        if proc is None:
            return

        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except Exception:
            try:
                proc.terminate()
            except Exception:
                pass
        try:
            proc.wait(timeout=0.5)
        except Exception:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass

    def kill_processes(self, procs):
        if not procs:
            return
        for proc in procs:
            self.kill_process(proc)
    def kill_current_process(self):
        with self.proc_lock:
            current = dict(self.current_proc)
            self.current_proc = {"lan": None, "wifi": None}

        for procs in current.values():
            if procs is None:
                continue
            if isinstance(procs, (list, tuple)):
                self.kill_processes(procs)
            else:
                self.kill_process(procs)

    def start_parallel_streams(self, iface, kind, direction, remaining):
        procs = []
        stream_count = (
            DOWNLOAD_STREAMS
            if direction == "download"
            else UPLOAD_STREAMS
        )

        for stream_no in range(stream_count):
            if direction == "download":
                proc = self.launch_download_stream(
                    iface, remaining, stream_no
                )
            else:
                proc = self.launch_upload_stream(
                    iface, remaining, stream_no
                )
            procs.append(proc)
        self.set_current_proc(kind, procs)
        return procs

    def measure_phase(self, iface, kind, direction):
        start_t = time.monotonic()
        deadline = start_t + PHASE_SECONDS

        last_bytes = iface_counter(iface, direction)
        last_t = start_t

        # Endwert = Mittelwert der stabilisierten Live-Samples.
        # Der Hochlauf der ersten WARMUP_SECONDS wird nicht eingerechnet.
        stable_samples = []
        all_samples = []
        procs = self.start_parallel_streams(
            iface,
            kind,
            direction,
            PHASE_SECONDS,
        )

        while time.monotonic() < deadline and not self.stop_event.is_set():
            time.sleep(SAMPLE_SECONDS)

            now = time.monotonic()
            cur = iface_counter(iface, direction)

            dt = now - last_t
            delta = max(0, cur - last_bytes)
            if dt > 0:
                live = delta * 8.0 / dt / 1_000_000.0
                all_samples.append(live)

                if now - start_t >= WARMUP_SECONDS:
                    stable_samples.append(live)

                GLib.idle_add(
                    self.update_live_speed,
                    kind,
                    direction,
                    live,
                )

            last_bytes = cur
            last_t = now
            # Falls alle Transfers auf einer schnellen Leitung schon
            # komplett fertig sind, sofort neue parallele Streams starten.
            if procs and all(p.poll() is not None for p in procs):
                remaining = deadline - time.monotonic()
                if remaining > 0.35:
                    procs = self.start_parallel_streams(
                        iface,
                        kind,
                        direction,
                        remaining,
                    )
        self.kill_processes(procs)
        self.set_current_proc(kind, None)

        samples = stable_samples if stable_samples else all_samples

        # Null-/Fehlersamples nicht schönrechnen.
        useful = [v for v in samples if v > 0.05]

        if not useful:
            raise RuntimeError(f"Keine {direction}-Daten gemessen")
        # Nicht den gesamten Mittelwert verwenden:
        # Der Verbindungsaufbau am Anfang ist real, aber für unsere
        # Prüfstation interessiert die stabil erreichbare Geschwindigkeit.
        #
        # Deshalb sortieren wir die stabilisierten Samples und bilden
        # den Mittelwert aus den schnellsten 50 %. Das ist robuster als
        # einfach den Maximalwert zu nehmen.
        sorted_samples = sorted(useful, reverse=True)
        top_count = max(1, int(len(sorted_samples) * TOP_SAMPLE_FRACTION + 0.5))
        top_samples = sorted_samples[:top_count]
        raw_avg = sum(useful) / len(useful)
        avg = sum(top_samples) / len(top_samples)

        stream_count = (
            DOWNLOAD_STREAMS
            if direction == "download"
            else UPLOAD_STREAMS
        )

        log(
            f"{iface} {direction}: TOP-AVG {avg:.1f} Mbps "
            f"(Gesamt-AVG={raw_avg:.1f}, "
            f"Top={top_count}/{len(useful)} Samples, "
            f"Streams={stream_count}, Phase={PHASE_SECONDS:.1f}s)"
        )

        return avg
    # --------------------------------------------------------
    # Bewertung
    # --------------------------------------------------------

    def result_passes(self, kind):
        r = self.results[kind]

        if (
            r["link"] is None
            or r["ping_ok"] is not True
            or r["down"] is None
            or r["up"] is None
        ):
            return False

        return self.result_quality(kind) == "good"

    def metric_class(self, kind, metric, value):
        if value is None:
            return "warn"

        if metric == "link":
            target = LAN_LINK_MIN if kind == "lan" else WIFI_LINK_MIN
        elif metric == "down":
            target = (
                LAN_DOWNLOAD_MIN
                if kind == "lan"
                else WIFI_DOWNLOAD_MIN
            )
        else:
            target = (
                LAN_UPLOAD_MIN
                if kind == "lan"
                else WIFI_UPLOAD_MIN
            )

        if value >= target:
            return "good"
        if value >= target * NETWORK_WARN_FACTOR:
            return "warn"
        return "bad"

    def ping_class(self, latency):
        if latency is None:
            return "bad"
        if latency <= PING_GOOD_MAX_MS:
            return "good"
        if latency <= PING_WARN_MAX_MS:
            return "warn"
        return "bad"

    def result_quality(self, kind):
        """Gesamtqualität anhand aller vier LAN/WLAN-Werte."""
        r = self.results[kind]

        if (
            r["link"] is None
            or r["ping_ok"] is not True
            or r["down"] is None
            or r["up"] is None
        ):
            return "bad"

        classes = [
            self.metric_class(kind, "link", r["link"]),
            self.ping_class(r["ping"]),
            self.metric_class(kind, "down", r["down"]),
            self.metric_class(kind, "up", r["up"]),
        ]

        if "bad" in classes:
            return "bad"
        if "warn" in classes:
            return "warn"
        return "good"

    # --------------------------------------------------------
    # UI-Updates aus Worker
    # --------------------------------------------------------
    def mark_testing(self, kind, iface, phase):
        card = self.cards[kind]
        card.interface_label.set_text(f"Interface: {iface}")
        card.set_state(phase, "live")
        card.note_label.set_text("Speedtest läuft …")
        # Laufender Test = Blau. Bereits abgeschlossene Werte behalten
        # ihre fertige Grün/Orange/Rot-Bewertung.
        if phase == "DOWNLOAD":
            card.set_metric("down", "0 Mbps", "live")
        elif phase == "UPLOAD":
            card.set_metric("up", "0 Mbps", "live")

        self.global_status.set_text(f"{kind.upper()} {iface}: {phase}")
        return False
    def update_link(self, kind, speed):
        card = self.cards[kind]
        card.set_metric(
            "link",
            format_link_speed(speed),
            self.metric_class(kind, "link", speed),
        )
        return False

    def update_link_result(self, kind, speed):
        if speed is None:
            self.cards[kind].set_metric("link", "--", "warn")
            return False
        return self.update_link(kind, speed)

    def finish_single_metric_ui(self, kind, phase):
        result = self.results[kind]
        all_measured = (
            result["link"] is not None
            and result["ping_ok"] is not None
            and result["down"] is not None
            and result["up"] is not None
        )
        if all_measured:
            return self.apply_result_to_ui(kind)

        card = self.cards[kind]
        card.set_state("VERBUNDEN", "neutral")
        labels = {
            "link": "LINK",
            "ping": "PING",
            "down": "DOWNLOAD",
            "up": "UPLOAD",
        }
        card.note_label.set_text(
            f"{labels.get(phase, phase.upper())} neu gemessen."
        )
        self.global_status.set_text(
            f"{kind.upper()} {labels.get(phase, phase.upper())} abgeschlossen"
        )
        return False

    def mark_ping_testing(self, kind, iface):
        card = self.cards[kind]
        card.interface_label.set_text(f"Interface: {iface}")
        card.set_state("PING", "live")
        card.set_metric("ping", "LÄUFT", "live")
        card.note_label.set_text("Ping wird geprüft …")
        self.global_status.set_text(
            f"{kind.upper()} {iface}: PING"
        )
        return False

    def update_ping_result(self, kind, latency):
        card = self.cards[kind]

        if latency is None:
            card.set_metric("ping", "FEHLER", "bad")
            return False

        if latency < 1.0:
            text_value = "<1 ms"
        elif latency < 10.0:
            text_value = f"{latency:.1f} ms"
        else:
            text_value = f"{latency:.0f} ms"

        card.set_metric(
            "ping",
            text_value,
            self.ping_class(latency),
        )
        return False

    def update_live_speed(self, kind, direction, speed):
        card = self.cards[kind]
        metric = "down" if direction == "download" else "up"
        # Solange die Messung läuft, bleibt der Live-Wert Blau.
        # Erst der fertige Messwert wird Grün/Orange/Rot bewertet.
        card.set_metric(
            metric,
            format_mbps(speed, decimals=0),
            "live",
        )
        return False

    def update_phase_final_value(self, kind, metric, speed):
        card = self.cards[kind]
        # Nach Abschluss einer Phase sofort den gleichen Endwert einsetzen,
        # der später auch im fertigen Ergebnis stehen wird.
        card.set_metric(
            metric,
            format_mbps(speed, decimals=0),
            self.metric_class(kind, metric, speed),
        )
        return False
    def mark_test_error(self, kind, iface, error):
        card = self.cards[kind]
        card.set_state("TEST ERROR", "bad")
        card.note_label.set_text(error)
        self.global_status.set_text(f"{kind.upper()}-Test fehlgeschlagen")
        return False

    def apply_result_to_ui(self, kind):
        r = self.results[kind]
        card = self.cards[kind]
        card.set_metric(
            "link",
            format_link_speed(r["link"]),
            self.metric_class(kind, "link", r["link"]),
        )

        if r["ping_ok"] is True:
            latency = r["ping"]
            if latency is None:
                ping_text = "OK"
            elif latency < 1.0:
                ping_text = "<1 ms"
            elif latency < 10.0:
                ping_text = f"{latency:.1f} ms"
            else:
                ping_text = f"{latency:.0f} ms"

            card.set_metric(
                "ping",
                ping_text,
                self.ping_class(latency),
            )
        elif r["ping_ok"] is False:
            card.set_metric("ping", "FEHLER", "bad")
        else:
            card.set_metric("ping", "--", "warn")

        card.set_metric(
            "down",
            format_mbps(r["down"], decimals=0),
            self.metric_class(kind, "down", r["down"]),
        )
        card.set_metric(
            "up",
            format_mbps(r["up"], decimals=0),
            self.metric_class(kind, "up", r["up"]),
        )

        self.apply_final_state(kind)
        self.global_status.set_text(
            f"{kind.upper()}-Test abgeschlossen • "
            f"Download {r['down']:.1f} / Upload {r['up']:.1f} Mbps"
        )

        return False

    def apply_final_state(self, kind):
        r = self.results[kind]
        card = self.cards[kind]

        if not r["tested"]:
            return

        if r["ping_ok"] is False:
            card.set_state("PING ERROR", "bad")
            card.note_label.set_text(
                "Keine ICMP-Antwort – PING-Feld prüfen."
            )
            return

        quality = self.result_quality(kind)

        if quality == "good":
            card.set_state("GETESTET", "good")
            card.note_label.set_text(
                "Alle Messwerte im guten Bereich."
            )
        elif quality == "warn":
            card.set_state("LANGSAM", "warn")
            card.note_label.set_text(
                "Mindestens ein Messwert liegt im orangenen Bereich."
            )
        else:
            card.set_state("ZU LANGSAM", "bad")
            card.note_label.set_text(
                "Mindestens ein Messwert liegt deutlich unter dem Zielbereich."
            )

    # --------------------------------------------------------
    # Ende
    # --------------------------------------------------------

    def on_smart_app_action(self, _action, _parameter):
        if self.window is None:
            self.activate()
        if hasattr(self, "wipe_panel"):
            GLib.idle_add(self.wipe_panel.show_smart_window)
        return False

    def on_key_pressed(self, controller, keyval, keycode, state):
        name = Gdk.keyval_name(keyval) or ""

        if (
            name.lower() == "s"
            and not (state & Gdk.ModifierType.CONTROL_MASK)
        ):
            if keyboard_test_active():
                log("SMART-Hotkey S ignoriert: Keyboard-Test aktiv")
                return True
            self.wipe_panel.show_smart_window()
            return True

        if state & Gdk.ModifierType.CONTROL_MASK:
            if name.lower() == "w":
                self.quit()
                return True
            if name.lower() == "q":
                helper = Path.home() / ".local/bin/close-diagnostic-apps.sh"
                try:
                    subprocess.Popen(
                        [str(helper)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        start_new_session=True,
                    )
                except Exception as exc:
                    log(f"Strg+Q Fehler: {exc}")
                return True
        return False

    def do_shutdown(self):
        self.stop_event.set()
        self.kill_current_process()
        log("Network Check beendet.")
        Gtk.Application.do_shutdown(self)


app = NetworkCheckApp()
raise SystemExit(app.run(None))
PY

python3 "$TMP_PY"
