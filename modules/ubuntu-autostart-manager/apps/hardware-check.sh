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

TMP_PY="$(mktemp /tmp/hardware-check.XXXXXX.py)"
trap 'rm -f "$TMP_PY"' EXIT
cat > "$TMP_PY" <<'PY'
#!/usr/bin/env python3
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")

from gi.repository import Gtk, Gdk, GLib, Pango, Gio
from pathlib import Path
import ast
import glob
import json
import math
import os
import fcntl
import random
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import select

BENCHMARK_WINDOW_MODE = os.environ.get("UWUNTU_BENCHMARK_WINDOW") == "1"
APP_ID = (
    "com.david.UwuntuAudioTest"
    if BENCHMARK_WINDOW_MODE
    else "com.david.HardwareCheck"
)
AUDIO_ACTION_APP_ID = "com.david.UwuntuAudioEngineExperiment"
BENCHMARK_ACTION_APP_ID = "com.david.UwuntuAudioTest"
LOG_FILE = Path.home() / "hardware_check.log"

SYS_USB = Path("/sys/bus/usb/devices")
SYS_TYPEC = Path("/sys/class/typec")
CSS = """
headerbar {
    min-height: 28px;
    padding: 0px 4px;
}
headerbar .title {
    font-size: 11px;
    font-weight: 700;
    padding: 0px;
}
headerbar button {
    min-height: 22px;
    min-width: 22px;
    padding: 0px 4px;
    margin-top: 0px;
    margin-bottom: 0px;
}

window { background: #17171c; color: #f4f4f5; }
.header-title { font-size: 17px; font-weight: 800; }
.header-version { color: #9d9da7; font-size: 10px; font-weight: 600; padding-top: 4px; }
.card { background: #232329; border: 1px solid #34343c; border-radius: 8px; padding: 5px 6px; }
.card-title { color: #f4f4f5; font-size: 13px; font-weight: 800; }
.big-status { font-size: 12px; font-weight: 800; }
.status-green { color: #61d36b; }
.status-blue { color: #5aa2ff; }
.status-orange { color: #f5a623; }
.status-yellow { color: #f5a623; }
.status-red { color: #ff4c4c; }
.muted { color: #9d9da7; font-size: 10px; font-weight: 500; }
button.action { min-height: 38px; border-radius: 8px; font-size: 12px; font-weight: 800; }
button.action-orange { background: #232329; color: #f5a623; border: 1px solid #f5a623; }
button.action-green { background: #232329; color: #61d36b; border: 1px solid #61d36b; }
button.secondary { min-height: 30px; border-radius: 8px; font-size: 12px; font-weight: 800; }
button.refresh-button {
    min-height: 22px;
    padding: 1px 7px;
    border-radius: 7px;
    font-size: 11px;
    font-weight: 800;
}


button.tiny-button {
    min-height: 26px;
    padding: 2px 8px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 800;
}
button.benchmark-open {
    min-height: 20px;
    padding: 0px 8px;
    border-radius: 7px;
    font-size: 11px;
    font-weight: 800;
}

button.benchmark-choice,
button.benchmark-compact {
    min-height: 28px;
    padding: 1px 6px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 800;
}
button.benchmark-choice.benchmark-running,
button.benchmark-choice.benchmark-running:disabled {
    background: #232329;
    color: #5aa2ff;
    border: 1px solid #5aa2ff;
    opacity: 1;
}
button.benchmark-choice.benchmark-passed,
button.benchmark-choice.benchmark-passed:disabled {
    background: #232329;
    color: #61d36b;
    border: 1px solid #61d36b;
    opacity: 1;
}
button.benchmark-choice.benchmark-failed,
button.benchmark-choice.benchmark-failed:disabled {
    background: #232329;
    color: #ff4c4c;
    border: 1px solid #ff4c4c;
    opacity: 1;
}

.benchmark-status {
    font-size: 12px;
    font-weight: 800;
}

.benchmark-result {
    font-size: 13px;
    font-weight: 800;
}
label.benchmark-result.status-green,
label.benchmark-status.status-green {
    color: #61d36b;
}
label.benchmark-result.status-red,
label.benchmark-status.status-red {
    color: #ff4c4c;
}

.usb-row {
    background: #1d1d22;
    border: 1px solid #34343c;
    border-radius: 8px;
    padding: 3px 6px;
}
.usb-port-name { font-size: 11px; font-weight: 800; }
.usb-port-state { font-size: 11px; font-weight: 600; }
.input-status-strong { font-size: 11px; font-weight: 800; }
.key {
    background: #292930;
    color: #f4f4f5;
    border: 1px solid #44444e;
    border-radius: 6px;
    padding: 2px 4px;
    font-size: 10px;
    font-weight: 600;
}
.key-tested { background: #232329; color: #61d36b; border-color: #61d36b; }
.key-tested-blue { background: #232329; color: #5aa2ff; border-color: #5aa2ff; }
.progress-label { font-size: 12px; font-weight: 800; }
.info-title { font-size: 17px; font-weight: 800; }
.info-card {
    background: #232329;
    border: 1px solid #34343c;
    border-radius: 8px;
    padding: 8px;
}
.info-label {
    color: #9d9da7;
    font-size: 10px;
    font-weight: 600;
}
.info-value {
    color: #f4f4f5;
    font-size: 12px;
    font-weight: 800;
}
button.info-serial-link {
    color: #5aa2ff;
    background: transparent;
    border: 1px solid transparent;
    border-radius: 6px;
    padding: 2px 6px;
    min-height: 24px;
    font-size: 12px;
    font-weight: 800;
}
button.info-serial-link:focus {
    background: #232329;
    border-color: #5aa2ff;
    outline: 2px solid #5aa2ff;
    outline-offset: 1px;
}
.hotkey-grid {
    background: #232329;
    border: 1px solid #34343c;
    border-radius: 8px;
    padding: 8px;
}
.hotkey-key {
    color: #5aa2ff;
    font-size: 12px;
    font-weight: 800;
}
.hotkey-desc {
    color: #f4f4f5;
    font-size: 11px;
    font-weight: 600;
}
.hotkey-note {
    color: #9d9da7;
    font-size: 10px;
    font-weight: 500;
}
.update-status {
    background: #232329;
    border: 1px solid #34343c;
    border-radius: 8px;
    padding: 8px;
    color: #f4f4f5;
    font-size: 12px;
    font-weight: 800;
}

button.wlan-diag-button {
    min-height: 26px;
    padding: 2px 9px;
    border-radius: 8px;
    font-size: 11px;
    font-weight: 800;
    color: #5aa2ff;
    background: #232329;
    border: 1px solid #5aa2ff;
}
.wlan-diag-shade {
    background: rgba(23, 23, 28, 0.92);
}
.wlan-diag-card {
    background: #232329;
    border: 1px solid #5aa2ff;
    border-radius: 10px;
    padding: 14px;
}
.wlan-diag-title {
    font-size: 14px;
    font-weight: 800;
}
.wlan-diag-live {
    color: #d7d7dd;
    font-family: monospace;
    font-size: 11px;
    font-weight: 600;
}

/* Update-Statusfarben bewusst spezifischer als .update-status.
   Dadurch kann dessen allgemeines Weiß die Zustandsfarbe nicht überschreiben. */
.update-status.status-orange { color: #f5a623; }
.update-status.status-blue   { color: #5aa2ff; }
.update-status.status-green  { color: #61d36b; }
.update-status.status-red    { color: #ff4c4c; }
"""
def log(msg):
    try:
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {msg}\n")
    except Exception:
        pass

def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="ignore").strip()
    except Exception:
        return ""

def detect_tpm():
    tpm = Path("/sys/class/tpm/tpm0")
    if not tpm.exists():
        return "red", "TPM AUS", "Kein TPM erkannt"
    for p in (tpm/"tpm_version_major", tpm/"device"/"tpm_version_major"):
        v = read_text(p)
        if v == "2":
            return "green", "TPM 2.0 AN", "TPM 2.0 erkannt"
        if v == "1":
            return "orange", "TPM AN", "TPM 1.x erkannt"

    if Path("/dev/tpmrm0").exists():
        return "green", "TPM 2.0 AN", "TPM 2.0 Resource Manager erkannt"

    caps = read_text(tpm/"caps").lower()
    if "2.0" in caps:
        return "green", "TPM 2.0 AN", "TPM 2.0 erkannt"
    return "orange", "TPM AN", "TPM vorhanden, Version nicht eindeutig"
def detect_secure_boot():
    if shutil.which("mokutil"):
        try:
            env = os.environ.copy()
            env["LC_ALL"] = "C"
            p = subprocess.run(["mokutil", "--sb-state"], capture_output=True, text=True, timeout=3, env=env)
            s = (p.stdout + " " + p.stderr).lower()
            if "secureboot enabled" in s or "secure boot enabled" in s:
                return "green", "SECURE BOOT AN", "UEFI Secure Boot aktiv"
            if "secureboot disabled" in s or "secure boot disabled" in s:
                return "orange", "SECURE BOOT AUS", "UEFI Secure Boot deaktiviert"
        except Exception:
            pass
    for f in glob.glob("/sys/firmware/efi/efivars/SecureBoot-*"):
        try:
            b = Path(f).read_bytes()
            if len(b) >= 5:
                return ("green", "SECURE BOOT AN", "UEFI Secure Boot aktiv") if b[4] == 1 else ("orange", "SECURE BOOT AUS", "UEFI Secure Boot deaktiviert")
        except Exception:
            pass

    return "orange", "SECURE BOOT AUS", "Secure Boot nicht aktiv/ermittelbar"
def _normalize_display_connector(name):
    """DRM- und Mutter-Namen vergleichbar machen (HDMI-A-1 -> HDMI-1)."""
    value = str(name or "").strip().upper()
    value = re.sub(r"^CARD\d+-", "", value)
    return value.replace("HDMI-A-", "HDMI-")


def _variant_value(value):
    """GLib.Variant-Werte sicher in normale Python-Werte entpacken."""
    try:
        return value.unpack() if hasattr(value, "unpack") else value
    except Exception:
        return value


def _valid_hdmi_edid(connector_dir):
    """EDID-Header, Vollständigkeit und Prüfsummen kontrollieren."""
    try:
        data = (Path(connector_dir) / "edid").read_bytes()
    except Exception:
        return False

    if len(data) < 128 or len(data) % 128 != 0:
        return False
    if data[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
        return False

    available_blocks = len(data) // 128
    declared_blocks = 1 + int(data[126])
    if available_blocks < declared_blocks:
        return False

    for index in range(declared_blocks):
        block = data[index * 128:(index + 1) * 128]
        if sum(block) % 256 != 0:
            return False
    return True


def _format_hdmi_mode(width, height, refresh):
    try:
        hz = int(round(float(refresh)))
        return f"{int(width)}x{int(height)} · {hz}Hz"
    except Exception:
        return ""


def _active_hdmi_mode_mutter(connector_name):
    """Aktiven physischen Modus direkt aus GNOME Mutter lesen."""
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        reply = bus.call_sync(
            "org.gnome.Mutter.DisplayConfig",
            "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig",
            "GetCurrentState",
            None,
            None,
            Gio.DBusCallFlags.NONE,
            1200,
            None,
        )
        _serial, monitors, _logical_monitors, _properties = reply.unpack()
    except Exception:
        return ""

    wanted = _normalize_display_connector(connector_name)
    for monitor in monitors:
        try:
            monitor_spec, modes, _monitor_properties = monitor
            current_connector = monitor_spec[0]
        except Exception:
            continue

        if _normalize_display_connector(current_connector) != wanted:
            continue

        for mode in modes:
            try:
                _mode_id, width, height, refresh, _preferred_scale, _supported_scales, mode_properties = mode
                is_current = _variant_value(mode_properties.get("is-current", False))
            except Exception:
                continue

            if bool(is_current):
                return _format_hdmi_mode(width, height, refresh)

    return ""


def _active_hdmi_mode_xrandr(connector_name):
    """Xorg-Fallback, falls Mutter nicht erreichbar ist."""
    if not shutil.which("xrandr"):
        return ""

    try:
        env = os.environ.copy()
        env["LC_ALL"] = "C"
        proc = subprocess.run(
            ["xrandr", "--current"],
            capture_output=True,
            text=True,
            timeout=2.0,
            env=env,
            check=False,
        )
    except Exception:
        return ""

    if proc.returncode != 0:
        return ""

    wanted = _normalize_display_connector(connector_name)
    in_wanted_connector = False

    for line in proc.stdout.splitlines():
        if line and not line[0].isspace():
            parts = line.split()
            in_wanted_connector = (
                len(parts) >= 2
                and _normalize_display_connector(parts[0]) == wanted
                and parts[1] == "connected"
            )
            continue

        if not in_wanted_connector:
            continue

        match = re.match(r"\s+(\d+)x(\d+)(?:i)?\s+(.+)$", line)
        if not match:
            continue

        width, height, rates = match.groups()
        for token in rates.split():
            if "*" not in token:
                continue
            rate_match = re.search(r"(\d+(?:\.\d+)?)", token)
            if rate_match:
                return _format_hdmi_mode(width, height, rate_match.group(1))

    return ""


def _active_hdmi_mode(connector_name):
    return _active_hdmi_mode_mutter(connector_name) or _active_hdmi_mode_xrandr(connector_name)


def _hdmi_connected_problem(reason):
    """Kurze Hotplug-Kulanz verhindert einen roten Blitz beim Einstecken."""
    now = time.monotonic()
    started = getattr(detect_hdmi, "_problem_since", None)
    if started is None:
        detect_hdmi._problem_since = now
        return "checking", "PRÜFE VERBINDUNG"
    if now - started < 2.0:
        return "checking", "PRÜFE VERBINDUNG"
    return "error", reason


def detect_hdmi():
    """HDMI über DRM, EDID und den tatsächlich aktiven Anzeigemodus prüfen."""
    connectors = sorted(glob.glob("/sys/class/drm/*HDMI*/status"))
    if not connectors:
        detect_hdmi._problem_since = None
        return "error", "Kein HDMI-Connector erkannt"

    connected_paths = []
    readable = 0
    for status_path in connectors:
        try:
            with open(status_path, "r", encoding="utf-8") as handle:
                status = handle.read().strip().lower()
            readable += 1
        except OSError:
            continue

        if status == "connected":
            connected_paths.append(status_path)

    if connected_paths:
        problems = []
        for status_path in connected_paths:
            connector_dir = Path(status_path).parent
            connector_name = connector_dir.name

            if not _valid_hdmi_edid(connector_dir):
                problems.append("HDMI verbunden, aber EDID ungültig")
                continue

            mode = _active_hdmi_mode(connector_name)
            if mode:
                detect_hdmi._problem_since = None
                return "connected", mode

            problems.append("HDMI verbunden, aber kein aktiver Anzeigemodus")

        return _hdmi_connected_problem(problems[0])

    detect_hdmi._problem_since = None
    if readable == 0:
        return "error", "HDMI-Status nicht lesbar"

    return "disconnected", "HDMI nicht verbunden"


def read_float(path):
    try:
        return float(read_text(path))
    except Exception:
        return None


def natural_key(value):
    return [
        int(part) if part.isdigit() else part.lower()
        for part in re.split(r"(\d+)", str(value))
    ]


def symlink_target(path):
    try:
        if path.exists() or path.is_symlink():
            return str(path.resolve())
    except Exception:
        pass
    return ""


def root_usb_hubs():
    result = []
    if not SYS_USB.exists():
        return result

    for link in sorted(SYS_USB.glob("usb*"), key=lambda p: natural_key(p.name)):
        if not re.fullmatch(r"usb\d+", link.name):
            continue

        bus = link.name[3:]
        speed = read_float(link / "speed") or 0.0

        try:
            resolved = link.resolve()
        except Exception:
            continue

        interface = resolved / f"{bus}-0:1.0"
        if not interface.exists():
            candidates = sorted(
                resolved.glob(f"{bus}-0:*"),
                key=lambda p: natural_key(p.name),
            )
            interface = candidates[0] if candidates else None

        if not interface or not interface.exists():
            continue

        result.append({
            "bus": bus,
            "speed": speed,
            "root": resolved,
            "interface": interface,
        })

    return result

def port_number_from_name(name):
    m = re.search(r"-port(\d+)$", name)
    if not m:
        return None
    return int(m.group(1))


def port_device_name(bus, port_no):
    return f"{bus}-{port_no}"


def collect_root_port_objects(include_unknown=False, superspeed_only=False):
    objects = []

    for hub in root_usb_hubs():
        if superspeed_only and hub["speed"] <= 480.0:
            continue

        pattern = f"usb{hub['bus']}-port*"
        for port in sorted(
            hub["interface"].glob(pattern),
            key=lambda p: natural_key(p.name),
        ):
            connect_type = read_text(port / "connect_type").lower()
            port_no = port_number_from_name(port.name)

            if port_no is None:
                continue

            if not include_unknown and connect_type != "hotplug":
                continue
            if include_unknown and connect_type in {"hardwired", "not used", "unused"}:
                continue

            peer = symlink_target(port / "peer")
            connector = symlink_target(port / "connector")
            objects.append({
                "path": str(port.resolve()),
                "name": port.name,
                "bus": hub["bus"],
                "port_no": port_no,
                "speed": hub["speed"],
                "connect_type": connect_type or "unknown",
                "peer": peer,
                "connector": connector,
                "device_name": port_device_name(hub["bus"], port_no),
            })

    return objects

def canonical_group_key(obj):
    paths = [obj["path"]]
    if obj["peer"]:
        paths.append(obj["peer"])
    return " | ".join(sorted(set(paths)))


def group_physical_ports(objects):
    groups = {}

    for obj in objects:
        key = canonical_group_key(obj)
        groups.setdefault(key, []).append(obj)

    changed = True
    while changed:
        changed = False
        keys = list(groups)

        for i, key_a in enumerate(keys):
            if key_a not in groups:
                continue
            paths_a = {
                item["path"] for item in groups[key_a]
            } | {
                item["peer"] for item in groups[key_a] if item["peer"]
            }

            for key_b in keys[i + 1:]:
                if key_b not in groups:
                    continue

                paths_b = {
                    item["path"] for item in groups[key_b]
                } | {
                    item["peer"] for item in groups[key_b] if item["peer"]
                }
                if paths_a & paths_b:
                    groups[key_a].extend(groups.pop(key_b))
                    changed = True
                    break

            if changed:
                break

    result = []

    for idx, items in enumerate(groups.values(), 1):
        unique = {}
        for item in items:
            unique[item["path"]] = item
        items = list(unique.values())
        typec_name = None
        for item in items:
            connector = item["connector"]
            if not connector:
                continue

            base = Path(connector).name
            if re.fullmatch(r"port\d+", base):
                typec_name = base
                break

            m = re.search(r"/(port\d+)(?:/|$)", connector)
            if m:
                typec_name = m.group(1)
                break
        result.append({
            "key": f"physical-{idx}",
            "raw_key": " | ".join(sorted(x["path"] for x in items)),
            "items": items,
            "typec_name": typec_name,
        })

    return result


def discover_typec_ports():
    result = []

    if not SYS_TYPEC.exists():
        return result

    for path in sorted(SYS_TYPEC.glob("port*"), key=lambda p: natural_key(p.name)):
        if not re.fullmatch(r"port\d+", path.name):
            continue
        result.append({
            "name": path.name,
            "path": str(path.resolve()),
            "partner": (path / f"{path.name}-partner"),
        })

    return result


def usb_port_layout_quirk():
    """Dokumentierte physische Portanzahl für bekannte Firmware-Sonderfälle."""
    dmi = Path("/sys/class/dmi/id")
    vendor = read_first_value(dmi / "sys_vendor", dmi / "board_vendor")
    model = read_first_value(dmi / "product_name", dmi / "board_name")

    vendor_key = "" if vendor == "--" else vendor.strip().lower()
    model_key = "" if model == "--" else model.strip().lower()

    # Dell dokumentiert für das Latitude 5450 zwei USB-A- und zwei
    # Thunderbolt-4/USB-C-Buchsen. Auf einzelnen Firmwareständen meldet
    # Linux zusätzlich einen hotplug-fähigen logischen Root-Port, der keine
    # weitere physische Buchse darstellt.
    if "dell" in vendor_key and re.search(r"\blatitude\s+5450\b", model_key):
        return {
            "name": "Dell Latitude 5450",
            "usb_a": 2,
            "usb_c": 2,
        }

    return None


def group_present(group):
    for item in group["items"]:
        if (SYS_USB / item["device_name"]).exists():
            return True
    return False

def boot_usb_device_name():
    try:
        source = subprocess.check_output(
            ["findmnt", "-n", "-o", "SOURCE", "/cdrom"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        ).strip()

        if not source.startswith("/dev/"):
            return None

        parent = subprocess.check_output(
            ["lsblk", "-no", "PKNAME", source],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        ).strip()
        if not parent:
            return None

        dev = (Path("/sys/class/block") / parent / "device").resolve()

        for part in reversed(dev.parts):
            if re.fullmatch(r"\d+-\d+(?:\.\d+)*", part):
                return part

    except Exception:
        pass

    return None


def discover_physical_ports():
    mode = "hotplug"
    objects = collect_root_port_objects(
        include_unknown=False,
        superspeed_only=False,
    )
    if not objects:
        mode = "fallback-superspeed"
        objects = collect_root_port_objects(
            include_unknown=True,
            superspeed_only=True,
        )

    if not objects:
        mode = "fallback-usb"
        objects = collect_root_port_objects(
            include_unknown=True,
            superspeed_only=False,
        )

    groups = group_physical_ports(objects)
    typec = discover_typec_ports()
    layout_quirk = usb_port_layout_quirk()

    raw_count = len(groups)
    c_count_hint = min(len(typec), len(groups))
    a_map = {}
    c_map = {}
    a_reserve = []
    classification = "generic"

    def group_max_speed(group):
        values = [float(item.get("speed") or 0.0) for item in group["items"]]
        return max(values) if values else 0.0

    def group_port_numbers(group):
        return sorted({
            int(item["port_no"])
            for item in group["items"]
            if item.get("port_no") is not None
        })

    def group_has_peer(group):
        return any(bool(item.get("peer")) for item in group["items"])

    def select_a_groups(a_groups, c_count):
        """Bekannte Überzählung ohne falsche Typ-Umsortierung begrenzen.

        Kandidaten, an denen bereits ein Gerät steckt, werden bevorzugt
        sichtbar gehalten. Weitere Kandidaten bleiben als Reserve erhalten
        und können beim echten Hotplug dynamisch einen unbestätigten Slot
        ersetzen.
        """
        if not layout_quirk:
            return a_groups, []

        wanted_a = int(layout_quirk.get("usb_a") or 0)
        wanted_c = int(layout_quirk.get("usb_c") or 0)
        if wanted_a <= 0 or c_count != wanted_c or len(a_groups) < wanted_a:
            return a_groups, []

        ordered = sorted(
            a_groups,
            key=lambda g: (
                0 if group_present(g) else 1,
                0 if group_has_peer(g) else 1,
                min(group_port_numbers(g) or [999]),
                g["raw_key"],
            ),
        )
        return ordered[:wanted_a], ordered[wanted_a:]

    unpaired_ss = [
        g for g in groups
        if not group_has_peer(g) and group_max_speed(g) > 480.0
    ]

    unpaired_usb2 = [
        g for g in groups
        if not group_has_peer(g) and group_max_speed(g) <= 480.0
    ]

    ss_by_port = {}
    usb2_by_port = {}

    for group in unpaired_ss:
        ports = group_port_numbers(group)
        if len(ports) == 1:
            ss_by_port[ports[0]] = group
    for group in unpaired_usb2:
        ports = group_port_numbers(group)
        if len(ports) == 1:
            usb2_by_port[ports[0]] = group

    common_ports = sorted(set(ss_by_port) & set(usb2_by_port))

    # Dell Latitude 5450, BIOS 1.23.x: gemessene 4-Port-Topologie.
    #
    # Physisch liegen links zwei USB-C und ein USB-A gemeinsam am
    # Thunderbolt/USB4-Controller 00:0d.0. Rechts sitzt ein einzelner USB-A
    # am PCH-xHCI-Controller 00:14.0.
    #
    # Gemessen mit zwei vollständigen Mapper-Läufen (Boot über A und C):
    #   USB-C links #1 -> 00:0d.0 / 2-3 + UCSI port0
    #   USB-A rechts   -> 00:14.0 / 4-1 <-> 3-3 Peer
    #   USB-A links    -> 00:0d.0 / 2-1
    #   USB-C links #2 -> 00:0d.0 / 2-4 + UCSI port1
    #
    # Wichtig: Die zusätzlichen USB2-Pfade 3-1 / 3-2 / 3-4 dürfen NICHT
    # anhand ihrer Portnummer fest an A/C gebunden werden. Sie sind Teil des
    # gemeinsam gemultiplexten linken Portblocks und werden beim Hotplug
    # dynamisch über UCSI zugeordnet.
    if (
        layout_quirk
        and layout_quirk.get("name") == "Dell Latitude 5450"
        and c_count_hint == 2
    ):
        def dell_group(controller, port_no, superspeed=None, peer=None):
            matches = []
            token = f"/0000:00:{controller}/"
            for group in groups:
                if peer is not None and group_has_peer(group) != peer:
                    continue

                matched = False
                for item in group["items"]:
                    if token not in item.get("path", ""):
                        continue
                    if int(item.get("port_no") or -1) != int(port_no):
                        continue
                    speed = float(item.get("speed") or 0.0)
                    if superspeed is True and speed <= 480.0:
                        continue
                    if superspeed is False and speed > 480.0:
                        continue
                    matched = True
                    break

                if matched:
                    matches.append(group)

            return matches[0] if len(matches) == 1 else None

        dell_a_right = next(
            (
                group
                for group in groups
                if group_has_peer(group)
                and any(
                    "/0000:00:14.0/" in item.get("path", "")
                    and float(item.get("speed") or 0.0) > 480.0
                    for item in group["items"]
                )
            ),
            None,
        )
        dell_a_left_ss = dell_group("0d.0", 1, superspeed=True, peer=False)
        dell_c1_ss = dell_group("0d.0", 3, superspeed=True, peer=False)
        dell_c2_ss = dell_group("0d.0", 4, superspeed=True, peer=False)

        dynamic_usb2 = []
        for port_no in (1, 2, 4):
            group = dell_group("14.0", port_no, superspeed=False, peer=False)
            if group is not None:
                dynamic_usb2.append(group)

        required = (
            dell_a_right,
            dell_a_left_ss,
            dell_c1_ss,
            dell_c2_ss,
        )
        required_keys = {
            group["raw_key"]
            for group in required
            if group is not None
        }

        if (
            all(group is not None for group in required)
            and len(required_keys) == 4
            and len(dynamic_usb2) == 3
        ):
            classification = "dell-5450-left-cluster"

            # UI-Reihenfolge:
            # C links oben, A rechts, A links, C links unten.
            a_map[dell_a_right["raw_key"]] = 0
            a_map[dell_a_left_ss["raw_key"]] = 1

            c_map[dell_c1_ss["raw_key"]] = 0
            c_map[dell_c2_ss["raw_key"]] = 1

            a_reserve = []
            a_count = 2
            c_count = 2
            physical_total = 4

            return {
                "mode": mode,
                "classification": classification,
                "groups": groups,
                "typec": typec,
                "raw_group_count": raw_count,
                "physical_total": physical_total,
                "usb_a_count": a_count,
                "usb_c_count": c_count,
                "a_map": a_map,
                "c_map": c_map,
                "a_reserve": a_reserve,
                "dynamic_usb2": [
                    group["raw_key"]
                    for group in dynamic_usb2
                ],
                "layout_quirk": layout_quirk["name"],
            }

    if c_count_hint > 0 and len(common_ports) >= c_count_hint:
        classification = "ucsi-companion-topology"
        c_ports = common_ports[:c_count_hint]
        for idx, port_no in enumerate(c_ports):
            ss_group = ss_by_port[port_no]
            usb2_group = usb2_by_port[port_no]

            c_map[ss_group["raw_key"]] = idx
            c_map[usb2_group["raw_key"]] = idx

        used_keys = set(c_map)
        a_groups = [g for g in groups if g["raw_key"] not in used_keys]
        a_groups.sort(
            key=lambda g: (
                min(group_port_numbers(g) or [999]),
                g["raw_key"],
            )
        )

        c_count = len(c_ports)
        visible_a, reserve_a = select_a_groups(a_groups, c_count)
        if reserve_a:
            classification += "+layout-reserve"
            a_reserve = [g["raw_key"] for g in reserve_a]

        for idx, group in enumerate(visible_a):
            a_map[group["raw_key"]] = idx

        a_count = len(visible_a)
        physical_total = a_count + c_count
    else:
        classification = "generic-fallback"
        direct_c = [g for g in groups if g.get("typec_name")]
        direct_c.sort(key=lambda g: natural_key(g.get("typec_name") or ""))

        for idx, group in enumerate(direct_c):
            c_map[group["raw_key"]] = idx

        c_count = max(len(direct_c), c_count_hint)
        c_count = min(c_count, len(groups))
        used_keys = set(c_map)
        a_groups = [g for g in groups if g["raw_key"] not in used_keys]

        visible_a, reserve_a = select_a_groups(a_groups, c_count)
        if reserve_a:
            classification += "+layout-reserve"
            a_reserve = [g["raw_key"] for g in reserve_a]
            a_count = len(visible_a)
            physical_total = a_count + c_count
        else:
            if c_count > 0 and len(groups) >= 2 * c_count:
                physical_total = max(c_count, len(groups) - c_count)
            else:
                physical_total = len(groups)
            a_count = max(0, physical_total - c_count)
            visible_a = a_groups[:a_count]

        for idx, group in enumerate(visible_a):
            a_map[group["raw_key"]] = idx

    return {
        "mode": mode,
        "classification": classification,
        "groups": groups,
        "typec": typec,
        "raw_group_count": raw_count,
        "physical_total": physical_total,
        "usb_a_count": a_count,
        "usb_c_count": c_count,
        "a_map": a_map,
        "c_map": c_map,
        "a_reserve": a_reserve,
        "layout_quirk": layout_quirk["name"] if layout_quirk else "",
    }


def usb_device_snapshot():
    result = {}

    if not SYS_USB.exists():
        return result
    for dev in SYS_USB.iterdir():
        name = dev.name
        if not re.fullmatch(r"\d+-\d+(?:\.\d+)*", name):
            continue
        if not (dev / "idVendor").exists():
            continue

        maker = read_text(dev / "manufacturer")
        product = read_text(dev / "product")
        title = " ".join(x for x in (maker, product) if x).strip() or "USB-Gerät"
        result[name] = title

    return result


def usb_fallback_ignore_reason(device_name):
    """Interne USB-Komponenten aus dem unsicheren Backup-Fallback fernhalten.

    Die reguläre Port-Topologie bleibt unangetastet. Diese Prüfung gilt nur,
    wenn ein neu aufgetauchtes USB-Gerät keiner bekannten physischen Buchse
    sicher zugeordnet werden konnte.

    Besonders wichtig bei integrierten Webcams mit Wackelkontakt:
    Ab-/Anmelden darf niemals einen scheinbaren zusätzlichen USB-Port erzeugen.
    """
    if not device_name or not SYS_USB.exists():
        return ""

    dev = SYS_USB / device_name
    if not dev.exists():
        return ""

    # Linux kennzeichnet fest eingebaute USB-Komponenten häufig direkt.
    removable = read_text(dev / "removable").strip().lower()
    if removable == "fixed":
        return "fest eingebaut (removable=fixed)"

    # USB Video Class = 0x0e. Manche Kameras setzen die Klasse am Gerät,
    # andere nur auf einem oder mehreren Interfaces.
    device_class = read_text(dev / "bDeviceClass").strip().lower()
    try:
        if device_class and int(device_class, 16) == 0x0E:
            return "USB-Video-Gerät (bDeviceClass=0x0e)"
    except ValueError:
        pass

    for interface in SYS_USB.glob(device_name + ":*"):
        interface_class = read_text(
            interface / "bInterfaceClass"
        ).strip().lower()
        try:
            if interface_class and int(interface_class, 16) == 0x0E:
                return (
                    "USB-Video-Interface "
                    f"({interface.name}, bInterfaceClass=0x0e)"
                )
        except ValueError:
            continue

    return ""

def group_contains_device(group, device_name):
    if not device_name:
        return False

    for item in group["items"]:
        root_name = item["device_name"]
        if device_name == root_name or device_name.startswith(root_name + "."):
            return True

    return False


def group_min_port(group):
    ports = [
        int(item["port_no"])
        for item in group["items"]
        if item.get("port_no") is not None
    ]
    return min(ports) if ports else 999
def read_cpu_temperature():
    """
    CPU-Package-/Die-Temperatur in °C.
    Ein Fehler bei Sensoren darf den Benchmark NIEMALS verhindern.
    """
    def read_text(path):
        try:
            return Path(path).read_text(
                encoding="utf-8",
                errors="ignore",
            ).strip()
        except Exception:
            return ""

    try:
        preferred = []
        fallback = []
        for hwmon in Path("/sys/class/hwmon").glob("hwmon*"):
            name = read_text(hwmon / "name").lower()

            if name not in {
                "coretemp",
                "k10temp",
                "zenpower",
                "cpu_thermal",
                "cpu-thermal",
            }:
                continue
            for temp_file in hwmon.glob("temp*_input"):
                try:
                    raw = float(temp_file.read_text().strip())
                    value = raw / 1000.0 if raw > 500 else raw
                except Exception:
                    continue

                if not (-20.0 <= value <= 130.0):
                    continue

                stem = temp_file.name.replace("_input", "")
                label = read_text(hwmon / f"{stem}_label").lower()
                if any(
                    token in label
                    for token in (
                        "package",
                        "tctl",
                        "tdie",
                        "cpu",
                    )
                ):
                    preferred.append(value)
                else:
                    fallback.append(value)

        values = preferred or fallback
        if values:
            return max(values)
        for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
            ztype = read_text(zone / "type").lower()

            if not any(
                token in ztype
                for token in (
                    "x86_pkg_temp",
                    "cpu",
                    "soc",
                    "package",
                )
            ):
                continue
            try:
                raw = float((zone / "temp").read_text().strip())
                value = raw / 1000.0 if raw > 500 else raw
            except Exception:
                continue

            if -20.0 <= value <= 130.0:
                return value

    except Exception:
        # Temperaturanzeige ist Zusatzinformation.
        # Der Benchmark muss trotzdem immer starten.
        pass

    return None


def read_cpu_times():
    """Gesamt-/Idle-Zähler aus /proc/stat für CPU-Auslastung."""
    try:
        line = Path("/proc/stat").read_text(
            encoding="utf-8",
            errors="ignore",
        ).splitlines()[0]
        parts = line.split()
        if not parts or parts[0] != "cpu":
            return None

        values = [int(v) for v in parts[1:]]
        if len(values) < 4:
            return None

        idle = values[3]
        if len(values) > 4:
            idle += values[4]

        return sum(values), idle
    except Exception:
        return None


def read_cpu_average_frequency_mhz():
    """Aktueller Durchschnittstakt über alle gemeldeten CPU-Kerne."""
    values = []

    try:
        for path in Path("/sys/devices/system/cpu").glob(
            "cpu[0-9]*/cpufreq/scaling_cur_freq"
        ):
            try:
                raw = float(path.read_text().strip())
            except Exception:
                continue

            mhz = raw / 1000.0
            if 50.0 <= mhz <= 10000.0:
                values.append(mhz)
    except Exception:
        pass

    if not values:
        try:
            data = Path("/proc/cpuinfo").read_text(
                encoding="utf-8",
                errors="ignore",
            )
            for match in re.finditer(
                r"^cpu MHz\s*:\s*([0-9.]+)\s*$",
                data,
                re.M,
            ):
                try:
                    mhz = float(match.group(1))
                except Exception:
                    continue

                if 50.0 <= mhz <= 10000.0:
                    values.append(mhz)
        except Exception:
            pass

    if not values:
        return None

    return sum(values) / len(values)


def short_gpu_renderer_name(renderer):
    """Kompakter GPU-Name für Ergebnis- und Statuszeilen."""
    raw = (renderer or "").strip()
    if not raw:
        return "GPU"

    lower = raw.lower()
    if "iris" in lower and "xe" in lower:
        return "Intel Iris Xe"
    if "(lnl)" in lower or "lunar lake" in lower:
        return "Intel Graphics (LNL)"
    if "intel" in lower and "arc" in lower:
        match = re.search(r"(Arc[^()]*)", raw, re.I)
        if match:
            return ("Intel " + match.group(1).strip())[:32]
        return "Intel Arc Graphics"
    if "radeon" in lower:
        match = re.search(r"(Radeon[^()]*)", raw, re.I)
        if match:
            return ("AMD " + match.group(1).strip())[:32]
        return "AMD Radeon"
    if "nvidia" in lower:
        cleaned = re.sub(r"(?i)NVIDIA\s*(Corporation)?\s*", "", raw).strip()
        cleaned = re.sub(r"\s*\([^)]*\)\s*$", "", cleaned).strip()
        return ("NVIDIA " + cleaned)[:32]

    cleaned = re.sub(r"(?i)^Mesa\s+", "", raw)
    cleaned = cleaned.replace("(R)", "").replace("(TM)", "")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if len(cleaned) > 32:
        cleaned = cleaned[:29].rstrip() + "..."
    return cleaned


def read_gpu_telemetry():
    """Best-effort GPU-Temperatur und Takt unter Linux."""
    result = {
        "load": None,
        "temp": None,
        "temp_source": None,
        "clock_mhz": None,
        "driver": None,
    }

    def read_number(path, scale=1.0):
        try:
            value = float(Path(path).read_text().strip()) / scale
        except Exception:
            return None
        return value

    try:
        cards = sorted(
            Path("/sys/class/drm").glob("card[0-9]*"),
            key=lambda path: path.name,
        )
    except Exception:
        cards = []

    for card in cards:
        device = card / "device"
        if not device.exists():
            continue

        try:
            driver = (device / "driver").resolve().name.lower()
        except Exception:
            driver = None

        load = None
        for path in (
            device / "gpu_busy_percent",
            device / "busy_percent",
        ):
            value = read_number(path)
            if value is not None and 0.0 <= value <= 100.0:
                load = value
                break

        clock_mhz = None
        frequency_paths = [
            card / "gt_cur_freq_mhz",
            device / "gt_cur_freq_mhz",
            card / "gt" / "gt0" / "rps_cur_freq_mhz",
            device / "gt" / "gt0" / "rps_cur_freq_mhz",
            card / "gt" / "gt0" / "rps_act_freq_mhz",
            device / "gt" / "gt0" / "rps_act_freq_mhz",
        ]

        # Xe / Lunar Lake: neue Frequenz-API unter tile#/gt#/freq0.
        for pattern in (
            "tile*/gt*/freq0/act_freq",
            "tile*/gt*/freq0/cur_freq",
        ):
            try:
                frequency_paths.extend(sorted(device.glob(pattern)))
            except Exception:
                pass

        for path in frequency_paths:
            value = read_number(path)
            if value is not None and 10.0 <= value <= 10000.0:
                clock_mhz = value
                break

        if clock_mhz is None:
            try:
                dpm = (device / "pp_dpm_sclk").read_text(
                    encoding="utf-8",
                    errors="ignore",
                )
                match = re.search(
                    r"([0-9]+(?:\.[0-9]+)?)\s*Mhz\s*\*",
                    dpm,
                    re.I,
                )
                if match:
                    value = float(match.group(1))
                    if 10.0 <= value <= 10000.0:
                        clock_mhz = value
            except Exception:
                pass

        temperatures = []
        try:
            for hwmon in (device / "hwmon").glob("hwmon*"):
                for temp_file in hwmon.glob("temp*_input"):
                    value = read_number(temp_file, 1000.0)
                    if value is not None and -20.0 <= value <= 130.0:
                        temperatures.append(value)
        except Exception:
            pass

        temp = max(temperatures) if temperatures else None

        if load is not None or temp is not None or clock_mhz is not None:
            result["load"] = load
            result["temp"] = temp
            result["temp_source"] = "gpu" if temp is not None else None
            result["clock_mhz"] = clock_mhz
            result["driver"] = driver
            break

    # NVIDIA-Fallback.
    if (
        result["load"] is None
        and result["temp"] is None
        and result["clock_mhz"] is None
        and shutil.which("nvidia-smi")
    ):
        try:
            proc = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=utilization.gpu,temperature.gpu,clocks.gr",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True,
                text=True,
                timeout=1.5,
                check=False,
            )
            lines = (proc.stdout or "").splitlines()
            if lines:
                parts = [part.strip() for part in lines[0].split(",")]
                if len(parts) >= 3:
                    load = float(parts[0])
                    temp = float(parts[1])
                    clock_mhz = float(parts[2])
                    if 0.0 <= load <= 100.0:
                        result["load"] = load
                    if -20.0 <= temp <= 130.0:
                        result["temp"] = temp
                        result["temp_source"] = "gpu"
                    if 10.0 <= clock_mhz <= 10000.0:
                        result["clock_mhz"] = clock_mhz
                    result["driver"] = "nvidia"
        except Exception:
            pass

    # Intel-iGPUs haben nicht auf jedem Kernel einen eigenen GPU-Temperaturwert.
    # Dann wird die gemeinsame Package-Temperatur ausdrücklich als PKG TEMP
    # gekennzeichnet, statt einen GPU-Sensor vorzutäuschen.
    if (
        result["temp"] is None
        and result["driver"] in {"i915", "xe"}
    ):
        try:
            package_temp = read_cpu_temperature()
        except Exception:
            package_temp = None
        if package_temp is not None:
            result["temp"] = package_temp
            result["temp_source"] = "package"

    return result


def read_gpu_process_usage_snapshot(pid):
    """
    DRM-Usage-Snapshot eines Prozesses.

    i915 liefert drm-engine-<name> in ns. Xe liefert dagegen
    drm-cycles-<name> plus drm-total-cycles-<name>. Doppelte File Descriptors
    desselben DRM-Clients werden über drm-client-id/drm-pdev dedupliziert.
    """
    if not pid:
        return None

    snapshot = {
        "engine_ns": {},
        "cycles": {},
        "total_cycles": {},
        "capacity": {},
    }
    seen_clients = set()
    found = False

    try:
        fdinfo_dir = Path(f"/proc/{int(pid)}/fdinfo")
        for path in fdinfo_dir.glob("*"):
            try:
                data = path.read_text(
                    encoding="utf-8",
                    errors="ignore",
                )
            except Exception:
                continue

            driver_match = re.search(r"^drm-driver:\s*(\S+)\s*$", data, re.M)
            if not driver_match:
                continue

            client_match = re.search(r"^drm-client-id:\s*(\S+)\s*$", data, re.M)
            pdev_match = re.search(r"^drm-pdev:\s*(\S+)\s*$", data, re.M)
            client_key = (
                driver_match.group(1),
                pdev_match.group(1) if pdev_match else "",
                client_match.group(1) if client_match else path.name,
            )
            if client_key in seen_clients:
                continue
            seen_clients.add(client_key)

            capacities = {}
            for match in re.finditer(
                r"^drm-engine-capacity-([^:]+):\s*([0-9]+)\s*$",
                data,
                re.M,
            ):
                capacities[match.group(1)] = max(1, int(match.group(2)))

            for match in re.finditer(
                r"^drm-engine-(?!capacity-)([^:]+):\s*([0-9]+)\s+ns\s*$",
                data,
                re.M,
            ):
                key = match.group(1)
                snapshot["engine_ns"][key] = (
                    snapshot["engine_ns"].get(key, 0) + int(match.group(2))
                )
                snapshot["capacity"][key] = max(
                    snapshot["capacity"].get(key, 1),
                    capacities.get(key, 1),
                )
                found = True

            for match in re.finditer(
                r"^drm-cycles-([^:]+):\s*([0-9]+)\s*$",
                data,
                re.M,
            ):
                key = match.group(1)
                snapshot["cycles"][key] = (
                    snapshot["cycles"].get(key, 0) + int(match.group(2))
                )
                snapshot["capacity"][key] = max(
                    snapshot["capacity"].get(key, 1),
                    capacities.get(key, 1),
                )
                found = True

            for match in re.finditer(
                r"^drm-total-cycles-([^:]+):\s*([0-9]+)\s*$",
                data,
                re.M,
            ):
                key = match.group(1)
                snapshot["total_cycles"][key] = (
                    snapshot["total_cycles"].get(key, 0) + int(match.group(2))
                )
                found = True
    except Exception:
        return None

    return snapshot if found else None

def build_gpu_benchmark_args(duration, mode):
    """glmark2-Szenen für kurzen oder erweiterten GPU-Test."""
    executable = shutil.which("glmark2")
    if not executable:
        return None

    if mode == "short":
        scenes = (
            "terrain",
            "shadow",
            "refract",
            "bump",
        )
    else:
        scenes = (
            "terrain",
            "shadow",
            "refract",
            "bump",
            "shading",
            "jellyfish",
        )

    # Die angegebene Testdauer ist die echte Renderdauer.
    # Setup-/Abschlusszeit wird nicht mehr von den 20 bzw. 600 Sekunden
    # abgezogen; der separate Watchdog schützt weiterhin vor Hängern.
    scene_duration = max(
        2.0,
        float(duration) / len(scenes),
    )
    args = [
        executable,
        "--off-screen",
        "--size",
        "1920x1080",
    ]
    for scene in scenes:
        args.extend(
            [
                "--benchmark",
                f"{scene}:duration={scene_duration:.1f}",
            ]
        )
    return args


def detect_primary_ssd_device_name():
    """Bevorzugtes internes Solid-State-Laufwerk."""
    candidates = []

    try:
        for block in Path("/sys/block").iterdir():
            name = block.name

            if (
                name.startswith(
                    ("loop", "ram", "zram", "dm-", "sr", "md")
                )
            ):
                continue

            try:
                removable = int(
                    (block / "removable").read_text().strip() or "0"
                )
            except Exception:
                removable = 0

            try:
                rotational = int(
                    (block / "queue/rotational").read_text().strip() or "1"
                )
            except Exception:
                rotational = 1

            try:
                sectors = int(
                    (block / "size").read_text().strip() or "0"
                )
            except Exception:
                sectors = 0

            if removable != 0 or rotational != 0 or sectors <= 0:
                continue

            priority = 0 if name == "nvme0n1" else 1
            candidates.append(
                (priority, natural_key(name), name)
            )
    except Exception:
        return None

    if not candidates:
        return None

    candidates.sort(key=lambda item: (item[0], item[1]))
    return candidates[0][2]


def read_temperature_input(path):
    try:
        raw = float(path.read_text().strip())
    except Exception:
        return None

    value = raw / 1000.0 if abs(raw) > 500 else raw
    if -20.0 <= value <= 130.0:
        return value
    return None


def read_ssd_temperature():
    """Temperatur des bevorzugten internen SSD/NVMe-Laufwerks."""
    device_name = detect_primary_ssd_device_name()
    controller = None

    if device_name:
        match = re.match(r"(nvme\d+)n\d+$", device_name)
        if match:
            controller = match.group(1)

    preferred = []
    fallback = []

    try:
        hwmons = list(
            Path("/sys/class/hwmon").glob("hwmon*")
        )
    except Exception:
        hwmons = []

    for hwmon in hwmons:
        name = read_text(hwmon / "name").strip().lower()
        if name not in {"nvme", "drivetemp"}:
            continue

        try:
            real_path = str(hwmon.resolve()).lower()
        except Exception:
            real_path = str(hwmon).lower()

        target = (
            preferred
            if controller and controller.lower() in real_path
            else fallback
        )

        for temp_file in hwmon.glob("temp*_input"):
            value = read_temperature_input(temp_file)
            if value is None:
                continue

            stem = temp_file.name.replace("_input", "")
            label = read_text(
                hwmon / f"{stem}_label"
            ).strip().lower()

            score = 0
            if any(
                token in label
                for token in ("composite", "drive", "disk")
            ):
                score -= 10

            target.append((score, value))

    values = preferred or fallback
    if not values:
        return None

    values.sort(key=lambda item: item[0])
    return values[0][1]


def read_fan_status(preferred_key=None):
    """Stabilen FAN-Sensor lesen: key, RPM, optional PWM-Prozent.

    Beim ersten Aufruf wird bevorzugt ein Sensor gewählt, der sowohl
    fanN_input als auch pwmN bereitstellt. Danach kann der Aufrufer denselben
    Sensor über preferred_key festhalten. Nur wenn dieser Sensor wirklich
    verschwindet, wird neu gewählt.
    """
    readings = []
    found_sensor = False

    try:
        for hwmon in Path("/sys/class/hwmon").glob("hwmon*"):
            try:
                hwmon_real = str(hwmon.resolve())
            except Exception:
                hwmon_real = str(hwmon)

            for fan_file in hwmon.glob("fan*_input"):
                found_sensor = True

                match = re.fullmatch(
                    r"fan(\d+)_input",
                    fan_file.name,
                )
                if not match:
                    continue

                index = match.group(1)
                sensor_key = f"{hwmon_real}|fan{index}"

                try:
                    rpm = float(
                        fan_file.read_text().strip()
                    )
                except Exception:
                    continue

                if not (0.0 <= rpm <= 100000.0):
                    continue

                percent = None
                pwm_file = hwmon / f"pwm{index}"

                if pwm_file.exists():
                    try:
                        pwm = float(
                            pwm_file.read_text().strip()
                        )
                    except Exception:
                        pwm = None

                    if pwm is not None and 0.0 <= pwm <= 255.0:
                        percent = max(
                            0,
                            min(
                                100,
                                int(round(pwm / 255.0 * 100.0)),
                            ),
                        )

                readings.append(
                    {
                        "key": sensor_key,
                        "rpm": rpm,
                        "percent": percent,
                    }
                )
    except Exception:
        return None, None, None

    if readings:
        # Bestehenden Sensor unbedingt beibehalten, solange er existiert.
        if preferred_key:
            for item in readings:
                if item["key"] == preferred_key:
                    return (
                        item["key"],
                        item["rpm"],
                        item["percent"],
                    )

        # Erstwahl: PWM-fähigen Sensor bevorzugen. Bei mehreren davon
        # die höhere aktuelle RPM nehmen.
        readings.sort(
            key=lambda item: (
                item["percent"] is None,
                -item["rpm"],
                item["key"],
            )
        )
        selected = readings[0]
        return (
            selected["key"],
            selected["rpm"],
            selected["percent"],
        )

    if found_sensor:
        return preferred_key, 0.0, None

    return None, None, None

CPU_BENCH_WORKER = r"""
import hashlib
import multiprocessing as mp
import os
import queue
import sys
import time

duration = float(sys.argv[1])
workers = max(1, int(sys.argv[2]))

def worker(deadline, q, seed):
    count = 0
    block = (b"Uwuntu-CPU-Benchmark-" + bytes([seed & 0xff])) * 64
    digest = hashlib.sha256(block).digest()

    while time.monotonic() < deadline:
        digest = hashlib.sha256(digest + block).digest()
        count += 1

    q.put(count)
if __name__ == "__main__":
    ctx = mp.get_context("fork")
    q = ctx.Queue()
    start = time.monotonic()
    deadline = start + duration

    procs = [
        ctx.Process(target=worker, args=(deadline, q, i))
        for i in range(workers)
    ]

    for p in procs:
        p.start()

    for p in procs:
        p.join()

    total = 0
    for _ in procs:
        try:
            total += q.get(timeout=1.0)
        except queue.Empty:
            pass
    elapsed = max(0.001, time.monotonic() - start)
    print(f"RESULT CPU {total} {elapsed:.6f} {workers}", flush=True)
"""

RAM_TEST_WORKER = r"""
import mmap
import os
import sys
import time

duration = float(sys.argv[1])
mode = sys.argv[2]

MIB = 1024 * 1024
CHUNK = 1 * MIB
ALLOC_CHUNK = 64 * MIB

def mem_available():
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) * 1024
    except Exception:
        pass
    return 512 * MIB

def fill_region(region, pattern):
    expected = bytes([pattern]) * CHUNK
    size = len(region)
    for offset in range(0, size, CHUNK):
        end = min(offset + CHUNK, size)
        region[offset:end] = expected[:end-offset]

def allocate_committed(target, reserve):
    # RAM stufenweise reservieren und jede Seite sofort anfassen.
    # Ein einzelnes großes anonymes mmap kann unter Linux wegen Overcommit
    # erfolgreich aussehen, obwohl noch gar kein physischer RAM belegt wurde.
    # Deshalb wird der Extended-Test in 64-MiB-Blöcken aufgebaut. Jeder Block
    # wird direkt beschrieben; nach jedem Block wird MemAvailable erneut geprüft.
    # So belastet der Test wirklich fast den gesamten aktuell verfügbaren RAM,
    # stoppt aber, bevor der Sicherheitsrest für GNOME/Live-System verbraucht ist.
    regions = []
    allocated = 0

    while allocated < target:
        current_available = mem_available()
        headroom = current_available - reserve
        if headroom < CHUNK:
            break

        block = min(ALLOC_CHUNK, target - allocated, headroom)
        block = (int(block) // CHUNK) * CHUNK
        if block < CHUNK:
            break

        try:
            region = mmap.mmap(-1, block, access=mmap.ACCESS_WRITE)
            # Physische Seiten jetzt wirklich belegen, nicht nur virtuell mappen.
            fill_region(region, 0x00)
            regions.append(region)
            allocated += block
        except Exception:
            try:
                region.close()
            except Exception:
                pass
            break

    return regions, allocated

initial_available = mem_available()

if mode == "short":
    # Kurzer Test bleibt bewusst kompakt und schnell.
    reserve = max(768 * MIB, int(initial_available * 0.25))
    target_request = min(max(64 * MIB, initial_available - reserve), 512 * MIB)
    target_request = (int(target_request) // CHUNK) * CHUNK
    patterns = [0x00, 0xFF, 0xAA, 0x55]
else:
    # Extended = Hochlasttest: kein 8-GB-Limit mehr und keine 65-%-Grenze.
    # Es werden bis zu rund 92 % des beim Start tatsächlich verfügbaren RAM
    # angefordert. Mindestens 1 GiB bleibt als Sicherheitsreserve für Ubuntu.
    reserve = max(1024 * MIB, int(initial_available * 0.08))
    target_request = max(64 * MIB, initial_available - reserve)
    target_request = (int(target_request) // CHUNK) * CHUNK

    # Neben klassischen Wechselmustern auch Walking-Bit-Muster verwenden.
    # Das erhöht die Chance, datenabhängige RAM-/Busfehler unter Last zu sehen.
    patterns = [
        0x00, 0xFF, 0xAA, 0x55, 0x33, 0xCC, 0x0F, 0xF0,
        0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
        0xFE, 0xFD, 0xFB, 0xF7, 0xEF, 0xDF, 0xBF, 0x7F,
    ]

overall_start = time.monotonic()
regions, target = allocate_committed(target_request, reserve)

if target < 64 * MIB or not regions:
    for region in regions:
        try:
            region.close()
        except Exception:
            pass
    print(
        "ERROR RAM Nicht genug sicher nutzbarer RAM für den Test verfügbar",
        flush=True,
    )
    raise SystemExit(2)

print(
    f"INFO RAM initial_available={initial_available} reserve={reserve} "
    f"target={target} regions={len(regions)} mode={mode}",
    flush=True,
)

# Die angegebene Testdauer umfasst bewusst auch die aggressive
# RAM-Belegung, damit der 10-Minuten-Test nicht heimlich länger läuft.
start = overall_start
deadline = start + duration
checked = 0
errors = 0
passes = 0

try:
    while time.monotonic() < deadline:
        for pattern in patterns:
            expected = bytes([pattern]) * CHUNK

            # Erst das komplette belegte RAM-Gebiet mit dem Muster schreiben.
            for region in regions:
                size = len(region)
                for offset in range(0, size, CHUNK):
                    end = min(offset + CHUNK, size)
                    region[offset:end] = expected[:end-offset]

            # Danach denselben gesamten Bereich wieder lesen und vergleichen.
            for region in regions:
                size = len(region)
                for offset in range(0, size, CHUNK):
                    end = min(offset + CHUNK, size)
                    data = region[offset:end]
                    if data != expected[:end-offset]:
                        errors += 1
                    checked += end - offset

            passes += 1
            if time.monotonic() >= deadline:
                break
finally:
    for region in regions:
        try:
            region.close()
        except Exception:
            pass

elapsed = max(0.001, time.monotonic() - start)
print(
    f"RESULT RAM {errors} {checked} {elapsed:.6f} {target} {passes}",
    flush=True,
)
"""


def get_keyboard_event_paths():
    """Nur echte Tastatur-event-Geräte für den globalen Monitor ermitteln.

    Wichtig für EVIOCGRAB:
    Ein event-Gerät darf nur exklusiv übernommen werden, wenn es wirklich eine
    reine Tastatur ist. Manche Laptop-/USB-Geräte besitzen gleichzeitig einen
    ``kbd``-Handler UND Pointer-Funktionen. Würden wir so ein kombiniertes
    Gerät greifen, könnte anschließend z. B. die Touchpad-/Mausbewegung
    blockiert sein.

    Deshalb:
    - Kandidaten zunächst aus /proc/bus/input/devices mit ``kbd``-Handler.
    - Geräte mit mouse-Handler sofort ausschließen.
    - Wenn udev verfügbar ist, ID_INPUT_KEYBOARD=1 verlangen und
      TOUCHPAD/MOUSE/POINTINGSTICK/TABLET ausschließen.
    - Offensichtliche Systemtasten wie Power/Sleep/Video Bus nicht greifen.
    """
    candidates = []
    try:
        raw = Path("/proc/bus/input/devices").read_text(
            encoding="utf-8", errors="ignore"
        )
        for block in raw.split("\n\n"):
            handlers = ""
            name = ""

            for line in block.splitlines():
                if line.startswith("N: Name="):
                    name = line.split("=", 1)[1].strip().strip('"')
                elif line.startswith("H: Handlers="):
                    handlers = line.split("=", 1)[1].strip()

            tokens = handlers.split()
            if "kbd" not in tokens:
                continue

            # Ein Event-Knoten mit mouseN ist ein gemischtes Pointer-Gerät.
            if any(token.startswith("mouse") for token in tokens):
                continue

            lowered = name.lower()
            if any(
                marker in lowered
                for marker in (
                    "touchpad",
                    "trackpoint",
                    "pointing stick",
                    "mouse",
                )
            ):
                continue

            if lowered in {
                "power button",
                "sleep button",
                "video bus",
            }:
                continue

            for token in tokens:
                if token.startswith("event") and token[5:].isdigit():
                    candidates.append((f"/dev/input/{token}", name))

    except OSError:
        pass

    paths = set()
    udevadm = shutil.which("udevadm")

    for dev, name in candidates:
        if udevadm:
            try:
                p = subprocess.run(
                    [udevadm, "info", "--query=property", f"--name={dev}"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=1.0,
                    check=False,
                )
                props = set(
                    line.strip()
                    for line in (p.stdout or "").splitlines()
                    if line.strip()
                )

                if p.returncode == 0 and props:
                    if "ID_INPUT_KEYBOARD=1" not in props:
                        continue

                    if any(
                        flag in props
                        for flag in (
                            "ID_INPUT_TOUCHPAD=1",
                            "ID_INPUT_MOUSE=1",
                            "ID_INPUT_POINTINGSTICK=1",
                            "ID_INPUT_TABLET=1",
                        )
                    ):
                        continue
            except Exception:
                # /proc-Filter bleibt als sicherer Fallback bestehen.
                pass

        paths.add(dev)

    # Fallback für ungewöhnliche Systeme ohne brauchbare /proc-/udev-Daten.
    # *-event-kbd verweist gezielt auf Tastatur-Interfaces.
    if not paths:
        for link in glob.glob("/dev/input/by-path/*-event-kbd"):
            try:
                paths.add(os.path.realpath(link))
            except OSError:
                pass

    return sorted(paths)


def get_touchpad_event_paths():
    """Echte Touchpad-event-Geräte über udev bestimmen."""
    paths = set()
    for dev in sorted(glob.glob("/dev/input/event*")):
        try:
            p = subprocess.run(
                ["udevadm", "info", "--query=property", f"--name={dev}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=1.2,
                check=False,
            )
        except Exception:
            continue
        props = set(line.strip() for line in p.stdout.splitlines())
        if "ID_INPUT_TOUCHPAD=1" in props:
            paths.add(dev)
    return sorted(paths)


def run_global_arrow_monitor(parent_pid):
    """Globale Diagnose-Hotkeys ausschließlich von echten Tastaturen lesen.

    Normalbetrieb: nur mitlesen, damit die globalen Diagnose-Hotkeys weiter
    funktionieren.

    Tastatur-Test: Auf Kommando über stdin werden alle erkannten Tastatur-
    event-Geräte per EVIOCGRAB exklusiv übernommen. Die Prüftasten erreichen
    weiterhin diesen Monitor, aber GNOME/XWayland/Tiling Assistant bekommen
    sie während des Tests nicht mehr. Damit sind nicht nur Print Screen,
    sondern auch Alt+F4, Super-Kombinationen, Alt+F2, Ctrl+Alt+T,
    Shift+F10 usw. automatisch neutralisiert.

    Beim UNGRAB, Prozessende oder Absturz werden die Geräte wieder freigegeben.
    """
    event_struct = struct.Struct("llHHI")
    ev_key = 0x01

    # Linux: #define EVIOCGRAB _IOW('E', 0x90, int)
    IOC_WRITE = 1
    IOC_READ = 2
    IOC_NRBITS = 8
    IOC_TYPEBITS = 8
    IOC_SIZEBITS = 14
    IOC_NRSHIFT = 0
    IOC_TYPESHIFT = IOC_NRSHIFT + IOC_NRBITS
    IOC_SIZESHIFT = IOC_TYPESHIFT + IOC_TYPEBITS
    IOC_DIRSHIFT = IOC_SIZESHIFT + IOC_SIZEBITS
    EVIOCGRAB = (
        (IOC_WRITE << IOC_DIRSHIFT)
        | (ord("E") << IOC_TYPESHIFT)
        | (0x90 << IOC_NRSHIFT)
        | (struct.calcsize("i") << IOC_SIZESHIFT)
    )

    def eviocgbit(event_type, length):
        # Linux: EVIOCGBIT(ev, len) = _IOC(_IOC_READ, 'E', 0x20 + ev, len)
        return (
            (IOC_READ << IOC_DIRSHIFT)
            | (ord("E") << IOC_TYPESHIFT)
            | ((0x20 + event_type) << IOC_NRSHIFT)
            | (length << IOC_SIZESHIFT)
        )

    def bit_is_set(buf, bit):
        byte_index = bit // 8
        if byte_index >= len(buf):
            return False
        return bool(buf[byte_index] & (1 << (bit % 8)))

    def fd_has_pointer_movement(fd):
        """Kernel-seitig prüfen, ob das Event-Gerät Zeigerbewegung liefert.

        Udev-/proc-Klassifikation allein ist bei manchen Laptop-HID-Geräten
        nicht eindeutig genug. Ein Gerät mit echten X/Y-Maus-, Touchpad- oder
        Multitouch-Achsen darf niemals per EVIOCGRAB übernommen werden.
        """
        # EV_REL: REL_X=0, REL_Y=1
        rel_bits = bytearray(16)
        try:
            fcntl.ioctl(fd, eviocgbit(0x02, len(rel_bits)), rel_bits, True)
            if bit_is_set(rel_bits, 0) or bit_is_set(rel_bits, 1):
                return True
        except OSError:
            pass

        # EV_ABS: ABS_X=0, ABS_Y=1, ABS_MT_POSITION_X=53, Y=54
        abs_bits = bytearray(16)
        try:
            fcntl.ioctl(fd, eviocgbit(0x03, len(abs_bits)), abs_bits, True)
            if any(
                bit_is_set(abs_bits, bit)
                for bit in (0, 1, 53, 54)
            ):
                return True
        except OSError:
            pass

        return False

    key_map = {
        1: "escape",        # KEY_ESC
        48: "benchmark",    # KEY_B
        30: "all",          # KEY_A
        37: "keyboard",     # KEY_K
        19: "ram",          # KEY_R
        23: "info",         # KEY_I
        22: "update",       # KEY_U
        34: "warranty",     # KEY_G
        59: "hotkeys",      # KEY_F1
        20: "touch",        # KEY_T
        32: "display",      # KEY_D
        105: "audio-left",  # KEY_LEFT
        103: "audio-both",  # KEY_UP
        106: "audio-right", # KEY_RIGHT
        108: "audio-auto",  # KEY_DOWN
    }
    ctrl_codes = {29, 97}
    ctrl_down = set()
    fds = {}
    grabbable_fds = set()
    next_scan = 0.0
    first_scan = True
    grab_active = False
    grab_escape_count = 0
    grab_escape_last_at = 0.0
    grab_escape_window = 3.0
    command_buffer = b""

    try:
        command_fd = sys.stdin.fileno()
    except Exception:
        command_fd = None

    def emit(line):
        try:
            print(line, flush=True)
            return True
        except BrokenPipeError:
            return False

    def set_fd_grab(fd, enabled):
        try:
            fcntl.ioctl(fd, EVIOCGRAB, 1 if enabled else 0)
            return True
        except OSError:
            return False

    def apply_grab(enabled):
        nonlocal grab_active, grab_escape_count, grab_escape_last_at
        ok = 0
        failed = 0

        for fd in list(grabbable_fds):
            if set_fd_grab(fd, enabled):
                ok += 1
                continue

            failed += 1

            # Beim UNGRAB ist Schließen des FDs die letzte Instanz:
            # Der Kernel löst jeden EVIOCGRAB beim Close garantiert.
            if not enabled:
                try:
                    os.close(fd)
                except OSError:
                    pass
                fds.pop(fd, None)
                grabbable_fds.discard(fd)

        grab_active = bool(enabled and ok > 0)
        grab_escape_count = 0
        grab_escape_last_at = 0.0

        if enabled:
            emit(f"grabbed {ok} {failed}")
        else:
            emit(f"ungrabbed {ok} {failed}")

    while Path(f"/proc/{parent_pid}").exists():
        now = time.monotonic()
        if now >= next_scan:
            next_scan = now + 2.0
            current_paths = set(get_keyboard_event_paths())

            for fd, path in list(fds.items()):
                if path not in current_paths:
                    if grab_active:
                        set_fd_grab(fd, False)
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    fds.pop(fd, None)
                    grabbable_fds.discard(fd)

            opened_paths = set(fds.values())
            open_failures = 0
            for path in sorted(current_paths - opened_paths):
                try:
                    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                except OSError:
                    open_failures += 1
                    continue

                fds[fd] = path

                # Zweite Sicherheitsstufe direkt aus den Kernel-Capabilities:
                # Keyboard-Ereignisse dürfen wir weiterhin LESEN, aber Geräte
                # mit Pointer-Achsen werden niemals exklusiv gegriffen.
                if fd_has_pointer_movement(fd):
                    emit(f"pointer-capable-keyboard {path}")
                else:
                    grabbable_fds.add(fd)

                    # Wird während eines laufenden Keyboard-Tests z.B. eine
                    # externe USB-Tastatur angesteckt, ebenfalls sofort greifen.
                    if grab_active and not set_fd_grab(fd, True):
                        grabbable_fds.discard(fd)
                        emit(f"grab-device-failed {path}")

            if first_scan:
                if not fds or open_failures:
                    for fd in list(fds):
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                    return 77

                if not emit(f"ready {len(fds)}"):
                    return 0
                first_scan = False

        if not fds:
            time.sleep(0.25)
            continue

        wait_fds = list(fds)
        if command_fd is not None:
            wait_fds.append(command_fd)

        try:
            ready, _, _ = select.select(wait_fds, [], [], 0.35)
        except (OSError, ValueError):
            ready = []

        if command_fd is not None and command_fd in ready:
            try:
                chunk = os.read(command_fd, 256)
            except OSError:
                chunk = b""

            if not chunk:
                command_fd = None
            else:
                command_buffer += chunk
                while b"\n" in command_buffer:
                    raw_cmd, command_buffer = command_buffer.split(b"\n", 1)
                    cmd = raw_cmd.decode("ascii", errors="ignore").strip().lower()
                    if cmd == "grab":
                        apply_grab(True)
                    elif cmd == "ungrab":
                        apply_grab(False)

        for fd in ready:
            if fd == command_fd:
                continue

            try:
                data = os.read(fd, event_struct.size * 32)
            except BlockingIOError:
                continue
            except OSError:
                if grab_active:
                    set_fd_grab(fd, False)
                try:
                    os.close(fd)
                except OSError:
                    pass
                fds.pop(fd, None)
                grabbable_fds.discard(fd)
                continue

            usable = len(data) - (len(data) % event_struct.size)
            for offset in range(0, usable, event_struct.size):
                _, _, event_type, code, value = event_struct.unpack_from(data, offset)
                if event_type != ev_key:
                    continue

                if code in ctrl_codes:
                    token = (fd, code)
                    if value in (1, 2):
                        ctrl_down.add(token)
                    elif value == 0:
                        ctrl_down.discard(token)

                    # Auch Strg links/rechts müssen im Tastatur-Test unabhängig
                    # vom Fensterfokus als echte Prüftasten ankommen.
                    if value in (0, 1):
                        state = "down" if value == 1 else "up"
                        if not emit(f"keycode:{state}:{code}"):
                            return 0

                    # Während des exklusiven Tests zählt jede andere gedrückte
                    # Taste als Unterbrechung einer begonnenen ESC-x3-Folge.
                    if grab_active and value == 1:
                        grab_escape_count = 0
                        grab_escape_last_at = 0.0
                    continue

                # Roh-Keycode als PRESS und RELEASE melden:
                # gedrückt/gehalten = blau, losgelassen = grün.
                if value in (0, 1):
                    state = "down" if value == 1 else "up"
                    if not emit(f"keycode:{state}:{code}"):
                        return 0

                if value != 1:
                    continue

                # Während EVIOCGRAB aktiv ist, bleiben ALLE Tasten reine
                # Prüftasten. Es werden bewusst keine Diagnose-Hotkeys
                # (K/U/B/F1/Pfeile/...) erzeugt. So kann z. B. ein noch
                # wartendes K-Ereignis den Tastatur-Test nach ESC x3 nicht
                # direkt wieder öffnen.
                if grab_active:
                    now_key = time.monotonic()

                    if code == 1:  # KEY_ESC
                        if (
                            grab_escape_last_at <= 0.0
                            or now_key - grab_escape_last_at > grab_escape_window
                        ):
                            grab_escape_count = 1
                        else:
                            grab_escape_count += 1

                        grab_escape_last_at = now_key

                        if grab_escape_count >= 3:
                            # Sicherheitsentscheidend: Erst IM HELFER selbst
                            # freigeben, danach die GUI informieren. Selbst
                            # wenn GTK kurz hängt, ist kein Input-Gerät mehr
                            # exklusiv blockiert.
                            apply_grab(False)
                            if not emit("keyboard-exit"):
                                return 0
                    else:
                        grab_escape_count = 0
                        grab_escape_last_at = 0.0

                    continue

                if code == 32 and ctrl_down:
                    # Ctrl+D gehört dem Diagnose-Kiosk, nicht dem Display-Hotkey.
                    continue

                channel = key_map.get(code)
                if channel and not emit(channel):
                    return 0

    # Sauber freigeben; beim Schließen der FDs würde der Kernel den Grab
    # ebenfalls lösen, explizit ist es aber leichter nachvollziehbar.
    for fd in list(fds):
        if grab_active and fd in grabbable_fds:
            set_fd_grab(fd, False)
        try:
            os.close(fd)
        except OSError:
            pass
    return 0


def clean_dmi_value(value):
    value = (value or "").strip()
    if not value:
        return "--"

    placeholders = {
        "none",
        "not specified",
        "not applicable",
        "to be filled by o.e.m.",
        "default string",
        "system serial number",
    }
    if value.lower() in placeholders:
        return "--"
    return value


def read_first_value(*paths):
    for path in paths:
        value = clean_dmi_value(read_text(path))
        if value != "--":
            return value
    return "--"


def detect_cpu_name():
    try:
        text = Path("/proc/cpuinfo").read_text(
            encoding="utf-8", errors="ignore"
        )
        for line in text.splitlines():
            if line.lower().startswith("model name") and ":" in line:
                value = line.split(":", 1)[1].strip()
                if value:
                    return re.sub(r"\s+", " ", value)
    except Exception:
        pass

    try:
        env = os.environ.copy()
        env["LC_ALL"] = "C"
        out = subprocess.check_output(
            ["lscpu"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
            env=env,
        )
        for line in out.splitlines():
            if line.startswith("Model name:"):
                value = line.split(":", 1)[1].strip()
                if value:
                    return re.sub(r"\s+", " ", value)
    except Exception:
        pass

    return "--"


def detect_ram_size():
    try:
        text = Path("/proc/meminfo").read_text(
            encoding="utf-8", errors="ignore"
        )
        m = re.search(r"^MemTotal:\s+(\d+)\s+kB$", text, re.M)
        if m:
            gib = int(m.group(1)) * 1024 / (1024 ** 3)
            return f"{gib:.1f} GB"
    except Exception:
        pass
    return "--"


def detect_ssd_info():
    try:
        env = os.environ.copy()
        env["LC_ALL"] = "C"
        out = subprocess.check_output(
            [
                "lsblk", "-bdn",
                "-o", "NAME,SIZE,MODEL,ROTA,TYPE,RM",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=3,
            env=env,
        )
    except Exception:
        return "--"

    candidates = []
    for raw in out.splitlines():
        parts = raw.split()
        if len(parts) < 5:
            continue

        name = parts[0]
        try:
            size = int(parts[1])
        except Exception:
            continue

        # Die letzten drei Spalten sind sicher ROTA, TYPE und RM.
        try:
            rota = int(parts[-3])
            dev_type = parts[-2]
            removable = int(parts[-1])
        except Exception:
            continue

        model = " ".join(parts[2:-3]).strip() or "Unbekanntes Modell"

        if dev_type != "disk" or removable != 0 or rota != 0:
            continue

        size_gb = size / 1_000_000_000.0
        display = f"{size_gb:.0f} GB · {model}"
        priority = 0 if name == "nvme0n1" else 1
        candidates.append((priority, natural_key(name), display))

    if not candidates:
        return "--"

    candidates.sort(key=lambda item: (item[0], item[1]))
    return candidates[0][2]


def detect_system_serial():
    # Bewährte zentrale Seriennummer-Erkennung.
    #
    # Uwuntu bevorzugt jetzt bewusst dmidecode, weil diese Methode sowohl
    # beim getesteten Dell-Service-Tag als auch beim Lenovo-Testgerät die
    # tatsächlich benötigte System-Seriennummer liefert. Insbesondere Lenovo
    # kann in product_serial zusätzlich MTM-/Typinformationen enthalten.
    try:
        result = subprocess.run(
            ["sudo", "-n", "dmidecode", "-s", "system-serial-number"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
        value = clean_dmi_value(result.stdout or "")
        if value != "--":
            return value
    except Exception:
        pass

    # Sysfs bleibt ausschließlich als Fallback erhalten, falls dmidecode auf
    # einem Gerät ausnahmsweise nicht verfügbar oder nicht lesbar ist.
    candidates = [
        Path("/sys/class/dmi/id/product_serial"),
        Path("/sys/devices/virtual/dmi/id/product_serial"),
        Path("/sys/class/dmi/id/chassis_serial"),
        Path("/sys/class/dmi/id/board_serial"),
    ]

    for path in candidates:
        value = clean_dmi_value(read_text(path))
        if value != "--":
            return value

    return "--"


def system_information():
    dmi = Path("/sys/class/dmi/id")
    return [
        ("Hersteller", read_first_value(dmi / "sys_vendor", dmi / "board_vendor")),
        ("Modell", read_first_value(dmi / "product_name", dmi / "board_name")),
        ("Seriennummer", detect_system_serial()),
        ("CPU", detect_cpu_name()),
        ("RAM", detect_ram_size()),
        ("SSD", detect_ssd_info()),
    ]


def warranty_support_target(serial):
    """Garantie-/Supportziel für Dell und Lenovo bestimmen.

    Die Seriennummer wurde vor diesem Aufruf bereits zentral ausgelesen und
    über die vorhandene Clipboard-Funktion kopiert. Diese Funktion entscheidet
    danach nur noch anhand des Herstellers, welche bestehende Garantie-URL
    geöffnet wird.
    """
    dmi = Path("/sys/class/dmi/id")
    manufacturer = read_first_value(
        dmi / "sys_vendor",
        dmi / "board_vendor",
    )

    if manufacturer == "--" or serial == "--":
        return None

    vendor = manufacturer.lower()

    if "dell" in vendor:
        # Bestehende Dell-Service-Tag-Logik unverändert.
        if not re.fullmatch(r"[A-Za-z0-9]{5,20}", serial):
            return None

        url = (
            "https://www.dell.com/support/product-details/de-de/servicetag/"
            + serial
            + "/overview"
        )
        return "Dell", manufacturer, serial, url

    if "lenovo" in vendor:
        if not re.fullmatch(r"[A-Za-z0-9-]{4,32}", serial):
            return None

        # Getesteter Lenovo-Direktlink. Lenovo löst die Seriennummer selbst
        # auf; MTM und Produktname werden dafür nicht benötigt.
        url = (
            "https://pcsupport.lenovo.com/de/de/products/"
            + serial
            + "/warranty"
        )
        return "Lenovo", manufacturer, serial, url

    # Andere Hersteller: bewusst kein Browser-Ziel.
    return None


def format_test_clock(seconds):
    seconds = max(0, int(seconds))
    minutes, sec = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{sec:02d}"
    return f"{minutes:02d}:{sec:02d}"


def format_benchmark_points(value):
    """Ganzzahl mit deutschem Tausenderpunkt, unabhängig von Locale."""
    number = int(value)
    sign = "-" if number < 0 else ""
    digits = str(abs(number))
    groups = []
    while digits:
        groups.append(digits[-3:])
        digits = digits[:-3]
    return sign + ".".join(reversed(groups))


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self.window = None
        self.stack = None
        self.usb_discovery = None
        self.usb_slots = []
        self.usb_group_to_slot = {}
        self.usb_tested = set()
        self.usb_connected = set()
        # Gelernte Beziehung: ein logisch als USB-A sichtbarer Root-Pfad kann
        # bei einem USB-C-Hotplug als xHCI-Begleitpfad desselben C-Ports
        # auftauchen. Die A-Zuordnung bleibt dabei erhalten; sie wird nur
        # solange unterdrückt, wie der zugehörige C-Port wirklich aktiv ist.
        self.usb_a_c_companions = {}
        # Modellbezogene dynamische Doppelzuordnung. Key = USB-C-Slot,
        # Value = USB-A-Slot. Wird nur genutzt, wenn derselbe Root-Pfad
        # ohne aktives Type-C/UCSI-Signal erscheint.
        self.usb_c_a_shadow_slots = {}
        # Dynamische USB2-Pfade, die bei gemeinsam gemultiplexten
        # A/C-Portblöcken erst beim Hotplug sicher zugeordnet werden können.
        self.usb_dynamic_group_slots = {}
        self.usb_dynamic_group_seen_at = {}
        # USB-C-Hubs enumerieren oft zuerst den SuperSpeed-Teil und etwas
        # später einen separaten USB2-Hub. Diese kurze Sitzung verbindet beide
        # Enumerationen mit derselben physischen USB-C-Buchse.
        self.usb_recent_c_hotplug_slot = None
        self.usb_recent_c_hotplug_at = 0.0
        self.usb_last_group_present = {}
        self.usb_last_devices = {}
        self.usb_fallback = {}
        self.usb_boot_device = None
        self.usb_boot_slot = None
        self.key_widgets = {}
        self.key_aliases = {}
        self.key_tested = set()
        self.key_phase = {}
        self.hdmi_ever_connected = False

        # Live-Sensoren
        self.cpu_usage_prev = read_cpu_times()
        self.fan_sensor_key = None

        self.touchpad_tested = {"left": False, "right": False}
        self.touchpad_pressed = {"left": False, "right": False}
        self.touchpad_monitor_stop = threading.Event()
        self.touchpad_monitor_processes = []
        self.touchpad_monitor_threads = []
        # Globaler, nicht-blockierender Tastatur-Hotkey-Listener.
        # Touchpad-Klicks werden separat über libinput ausgewertet.
        self.global_input_stop = threading.Event()
        self.global_input_thread = None
        self.global_input_proc = None
        self.global_input_active = False
        self.global_input_command_lock = threading.Lock()
        self.keyboard_input_grab_desired = False
        self.keyboard_input_grab_active = False
        self.last_global_hotkey_at = {
            "escape": 0.0,
            "benchmark": 0.0,
            "all": 0.0,
            "keyboard": 0.0,
            "ram": 0.0,
            "info": 0.0,
            "update": 0.0,
            "warranty": 0.0,
            "hotkeys": 0.0,
            "touch": 0.0,
            "display": 0.0,
        }
        self.info_window = None
        self.hotkeys_window = None
        self.wlan_diag_button = None
        self.wlan_diag_overlay = None
        self.wlan_diag_spinner = None
        self.wlan_diag_title_label = None
        self.wlan_diag_live_label = None
        self.wlan_diag_active = False
        self.wlan_diag_thread = None
        self.wlan_diag_lines = []
        self.wlan_diag_hide_source = None
        self.wlan_diag_stop = threading.Event()
        self.update_window = None
        self.update_status_label = None
        self.update_proc = None
        self.serial_clipboard = None
        self.serial_clipboard_text = None
        self.test_proc = None
        self.test_kind = None
        self.test_duration = 0.0
        self.test_started = 0.0
        self.test_hard_deadline = 0.0
        self.test_cancelled = False
        self.test_output_lines = []
        self.test_reader_thread = None
        self.test_sequence_active = False
        self.test_sequence_mode = None
        self.test_sequence = []
        self.test_sequence_index = 0
        self.test_sequence_results = []
        self.test_sequence_total_duration = 0.0
        self.test_sequence_completed_duration = 0.0
        self.test_sequence_finalize_pending = False
        self.benchmark_buttons = []
        self.benchmark_button_by_kind = {}
        self.touch_state_file = Path.home() / ".local/state/uwuntu/touch_tester_status.json"
        self.touch_script = Path.home() / ".local/bin/uwuntu-touch-tester.sh"
        self.touch_status_cache = None
        self.touch_present_cache = None
        self.touch_present_checked_at = 0.0
        self.touch_proc = None
        self.touch_launch_guard_until = 0.0

        # AT-SPI läuft ausschließlich in einem persistenten Helper. Der
        # Hauptprozess liest für Audio-Pfeiltasten nur diesen lokalen Cache.
        self.power_dialog_cache_value = False
        self.power_dialog_guard_until = 0.0
        self.power_dialog_helper_proc = None
        self.power_dialog_helper_thread = None
        self.power_dialog_helper_stopping = False
        self.power_dialog_helper_restart_source = None
        self.display_state_file = Path.home() / ".local/state/uwuntu/display_test_status.json"
        self.display_script = Path.home() / ".local/bin/uwuntu-display-test.sh"
        self.display_test_active = False
        self.display_proc = None
        self.display_launch_grace_until = 0.0
        self.camera_state_file = Path.home() / ".local/state/uwuntu/camera_test_status.json"
        self.audio_state_file = Path.home() / ".local/state/uwuntu/audio_test_status.json"
        self.hardware_refresh_file = Path.home() / ".local/state/uwuntu/hardware_refresh.json"

        # Während des Tastatur-Tests wird nur Mutters Overlay-Key (einzelne
        # SUPER-Taste) temporär deaktiviert. Der Originalwert wird beim
        # Verlassen zuverlässig wiederhergestellt.
        self.super_overlay_original = None
        self.super_block_active = False
        self.super_restore_helper = None

        # GNOME öffnet mit ALT+SPACE normalerweise das Fenster-Menü.
        # Während des Tastatur-Tests wird diese WM-Tastenkombination temporär
        # deaktiviert und danach exakt wiederhergestellt.
        self.alt_space_original = None
        self.alt_space_block_active = False
        self.alt_space_restore_helper = None

        # Während des Tastatur-Tests dürfen SUPER+Pfeiltasten keine GNOME-
        # oder Tiling-Assistant-Fensteraktion auslösen. Die aktuell wirksamen
        # Bindings werden dynamisch gesichert, deaktiviert und danach exakt
        # wiederhergestellt.
        self.super_arrow_bindings_original = []
        self.super_arrow_block_active = False
        self.super_arrow_restore_helper = None

        # HC4.5.45: Kein EVIOCGRAB mehr. Stattdessen werden während des
        # Keyboard-Tests die normalen GNOME-/Mutter-Keybindings temporär
        # deaktiviert und danach exakt wiederhergestellt.
        self.desktop_shortcut_bindings_original = []
        self.desktop_shortcut_block_active = False
        self.desktop_shortcut_restore_helper = None

        # Tastatur-Test wird nur durch drei schnelle ESC-Tastendrücke beendet.
        # So bleibt ESC weiterhin als normale Prüftaste testbar.
        self.keyboard_escape_count = 0
        self.keyboard_escape_last_at = 0.0
        self.keyboard_escape_window = 3.0

        # Linux input-event Keycodes -> Alias aus keyboard_layout().
        # Damit arbeitet der Tastatur-Test direkt mit der physischen
        # Tastatur und ist nicht vom Fokus eines GTK-Fensters abhängig.
        self.keyboard_linux_aliases = {
            1: "Escape",
            2: "1", 3: "2", 4: "3", 5: "4", 6: "5",
            7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
            12: "ssharp", 13: "dead_acute", 14: "BackSpace",
            15: "Tab",
            16: "q", 17: "w", 18: "e", 19: "r", 20: "t",
            21: "z", 22: "u", 23: "i", 24: "o", 25: "p",
            26: "udiaeresis", 27: "plus", 28: "Return",
            29: "Control_L",
            30: "a", 31: "s", 32: "d", 33: "f", 34: "g",
            35: "h", 36: "j", 37: "k", 38: "l",
            39: "odiaeresis", 40: "adiaeresis",
            41: "dead_circumflex", 42: "Shift_L",
            43: "numbersign",
            44: "y", 45: "x", 46: "c", 47: "v", 48: "b",
            49: "n", 50: "m", 51: "comma", 52: "period",
            53: "minus", 54: "Shift_R", 56: "Alt_L", 57: "space",
            58: "Caps_Lock",
            59: "F1", 60: "F2", 61: "F3", 62: "F4",
            63: "F5", 64: "F6", 65: "F7", 66: "F8",
            67: "F9", 68: "F10", 70: "Scroll_Lock",
            86: "less", 87: "F11", 88: "F12",
            97: "Control_R", 99: "Print",
            100: "ISO_Level3_Shift",
            102: "Home", 103: "Up", 104: "Page_Up",
            105: "Left", 106: "Right", 107: "End",
            108: "Down", 109: "Page_Down", 110: "Insert",
            111: "Delete", 119: "Pause",
            125: "Super_L", 126: "Super_R", 127: "Menu",
        }

        self.keyboard_focus_widget = None

        # Die separate Benchmark-Instanz wird von der normalen HC-Instanz
        # über GApplication angesprochen. Dadurch funktionieren B/R/A global,
        # auch wenn Network, Kamera oder ein anderes Diagnosefenster Fokus hat.
        self.last_benchmark_shortcut_at = {
            "cpu": 0.0,
            "ram": 0.0,
            "all": 0.0,
        }
        if BENCHMARK_WINDOW_MODE:
            for action_name in ("cpu", "ram", "all"):
                app_action = Gio.SimpleAction.new(action_name, None)
                app_action.connect(
                    "activate",
                    self.on_benchmark_app_action,
                    action_name,
                )
                self.add_action(app_action)

    def do_activate(self):
        if self.window:
            self.window.present()
            return

        self.window = Gtk.ApplicationWindow(application=self)
        window_title = (
            "Hardware Benchmark EXP"
            if BENCHMARK_WINDOW_MODE
            else "Hardware Check v4.5.135"
        )
        self.window.set_title(window_title)
        self.window.set_default_size(860, 360)

        # Einheitliche Titelleiste wie Network/Wipe und Audio.
        self.header_bar = Gtk.HeaderBar()
        self.header_bar.set_show_title_buttons(True)

        title_label = Gtk.Label(
            label=(
                "Hardware Benchmark EXP"
                if BENCHMARK_WINDOW_MODE
                else "Hardware Check v4.5.135"
            )
        )
        title_label.add_css_class("title")
        self.header_bar.set_title_widget(title_label)

        self.header_refresh_button = Gtk.Button(label="REFRESH")
        self.header_refresh_button.add_css_class("refresh-button")
        self.header_refresh_button.set_focusable(False)
        if BENCHMARK_WINDOW_MODE:
            self.header_refresh_button.connect(
                "clicked",
                lambda *_: self.reset_benchmark_ui(),
            )
        else:
            self.header_refresh_button.connect("clicked", self.reset_all)
        self.header_bar.pack_end(self.header_refresh_button)

        self.window.set_titlebar(self.header_bar)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        controller = Gtk.EventControllerKey.new()
        controller.connect("key-pressed", self.on_key)
        controller.connect("key-released", self.on_key_released)
        self.window.add_controller(controller)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        if BENCHMARK_WINDOW_MODE:
            self.stack.add_named(self.build_benchmarks(), "benchmarks")
            self.stack.set_visible_child_name("benchmarks")
        else:
            self.stack.add_named(self.build_overview(), "overview")
            self.stack.add_named(self.build_keyboard(), "keyboard")
            self.stack.add_named(self.build_benchmarks(), "benchmarks")
        # Die Hardware-Test-Buttons dürfen niemals Tastaturfokus bekommen.
        # Dadurch kann z.B. SPACE im Tastatur-Test nicht versehentlich
        # "ÜBERSICHT", "RESET" oder einen anderen Button auslösen.
        self.disable_button_focus(self.stack)

        self.window.set_child(self.stack)

        if BENCHMARK_WINDOW_MODE:
            # Zweite HC-Instanz nur für die dauerhaft sichtbare Benchmark-Seite.
            # Keine USB-, Keyboard-, Touchpad- oder globalen Hotkey-Monitore
            # doppelt starten.
            GLib.timeout_add(1200, self.start_experimental_benchmark)
            log("Hardware Benchmark EXP gestartet")
        else:
            self.refresh_security()
            self.refresh_hdmi_status()
            self.reset_touchpad_test()
            self.start_touchpad_click_monitors()
            self.usb_rediscover(reset=True)
            self.refresh_touch_status()
            self.refresh_display_status()
            self.refresh_media_status()
            self.refresh_sensors()
            GLib.timeout_add(300, self.poll_usb)
            GLib.timeout_add(500, self.poll_hdmi_status)
            GLib.timeout_add(500, self.poll_touch_status)
            GLib.timeout_add(500, self.poll_display_status)
            GLib.timeout_add(400, self.poll_media_status)
            GLib.timeout_add(1000, self.poll_sensors)
            self.start_power_dialog_helper()
            self.start_global_input_listener()
            log("Hardware Check gestartet")
        # Beim ersten Start nur sichtbar mappen, ohne eine Fokus-/Aktivierungs-
        # Anforderung an GNOME zu senden. Dadurch soll die Shell keinen
        # "Hardware Check ... ist bereit"-Hinweis mehr erzeugen.
        self.window.set_visible(True)
    def header(
        self,
        title,
        back=False,
        refresh=False,
        version=None,
        back_label="← ÜBERSICHT",
        compact_back=False,
    ):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.set_margin_start(10)
        row.set_margin_end(10)
        row.set_margin_top(5)
        row.set_margin_bottom(3)

        if back:
            b = Gtk.Button(label=back_label)
            b.add_css_class("secondary")
            if compact_back:
                b.add_css_class("benchmark-compact")
            b.connect("clicked", self.show_overview)
            row.append(b)
        title_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        title_row.set_hexpand(True)

        t = Gtk.Label(label=title)
        t.set_xalign(0)
        t.add_css_class("header-title")
        title_row.append(t)

        if version:
            v = Gtk.Label(label=version)
            v.set_xalign(0)
            v.set_valign(Gtk.Align.START)
            v.add_css_class("header-version")
            title_row.append(v)

        row.append(title_row)
        # REFRESH sitzt global in der Fenster-Titelleiste.
        return row

    def disable_button_focus(self, widget):
        if isinstance(widget, Gtk.Button):
            widget.set_focusable(False)
        child = widget.get_first_child()
        while child is not None:
            self.disable_button_focus(child)
            child = child.get_next_sibling()

    def card(self, title):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        box.add_css_class("card"); box.set_hexpand(True)
        l = Gtk.Label(label=title); l.set_xalign(0); l.add_css_class("card-title")
        box.append(l)
        return box
    def build_overview(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)

        content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        content.set_margin_start(8)
        content.set_margin_end(8)
        content.set_margin_bottom(4)
        # Beide Übersichtsseiten teilen sich die verfügbare Breite exakt 50/50.
        # Dadurch liegt die optische Trennung unabhängig vom Inhalt mittig.
        content.set_homogeneous(True)
        # =====================================================
        # LINKE SPALTE
        # Security -> Webcam/Mic -> Eingabegeräte
        # =====================================================
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        left.set_hexpand(True)

        # TPM und Secure Boot bleiben in EINER Karte, bekommen aber – genau
        # wie HDMI und Touchpad – jeweils eine eigene dunkle Status-Kapsel.
        security = self.card("TPM / SECURE BOOT")

        tpm_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        tpm_row.add_css_class("usb-row")
        self.tpm_status = Gtk.Label(label="● PRÜFE …")
        self.tpm_status.set_xalign(0)
        self.tpm_status.set_hexpand(True)
        self.tpm_status.add_css_class("usb-port-name")
        self.tpm_detail = Gtk.Label()  # intern für bestehende Diagnose/Logs
        tpm_row.append(self.tpm_status)

        sb_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        sb_row.add_css_class("usb-row")
        self.sb_status = Gtk.Label(label="● PRÜFE …")
        self.sb_status.set_xalign(0)
        self.sb_status.set_hexpand(True)
        self.sb_status.add_css_class("usb-port-name")
        self.sb_detail = Gtk.Label()
        sb_row.append(self.sb_status)

        security.append(tpm_row)
        security.append(sb_row)
        left.append(security)

        # =====================================================
        # WEBCAM / MIC
        # =====================================================
        media = self.card("WEBCAM / MIC")

        webcam_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        webcam_row.add_css_class("usb-row")
        self.webcam_status_dot = Gtk.Label(label="●")
        self.webcam_status_dot.add_css_class("status-red")
        self.webcam_status_name = Gtk.Label(label="WEBCAM")
        self.webcam_status_name.set_xalign(0)
        self.webcam_status_name.set_hexpand(True)
        self.webcam_status_name.add_css_class("usb-port-name")
        self.webcam_status_name.add_css_class("status-red")
        self.webcam_status_text = Gtk.Label(label="NICHT ERKANNT")
        self.webcam_status_text.set_xalign(1)
        self.webcam_status_text.add_css_class("usb-port-state")
        self.webcam_status_text.add_css_class("status-red")
        webcam_row.append(self.webcam_status_dot)
        webcam_row.append(self.webcam_status_name)
        webcam_row.append(self.webcam_status_text)
        media.append(webcam_row)

        mic_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        mic_row.add_css_class("usb-row")
        self.mic_status_dot = Gtk.Label(label="●")
        self.mic_status_dot.add_css_class("status-red")
        self.mic_status_name = Gtk.Label(label="MIC")
        self.mic_status_name.set_xalign(0)
        self.mic_status_name.set_hexpand(True)
        self.mic_status_name.add_css_class("usb-port-name")
        self.mic_status_name.add_css_class("status-red")
        self.mic_status_text = Gtk.Label(label="NICHT ERKANNT")
        self.mic_status_text.set_xalign(1)
        self.mic_status_text.add_css_class("usb-port-state")
        self.mic_status_text.add_css_class("status-red")
        mic_row.append(self.mic_status_dot)
        mic_row.append(self.mic_status_name)
        mic_row.append(self.mic_status_text)
        media.append(mic_row)

        left.append(media)

        # =====================================================
        # DISPLAY
        # Touchscreen bleibt als Eingabegerät links.
        # =====================================================
        display = self.card("DISPLAY")
        display.set_hexpand(True)

        display_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=7,
        )
        display_row.add_css_class("usb-row")

        self.display_status_dot = Gtk.Label(label="●")
        self.display_status_dot.add_css_class("status-orange")

        self.display_status_name = Gtk.Label(
            label="DISPLAY TEST (D)"
        )
        self.display_status_name.set_xalign(0)
        self.display_status_name.set_hexpand(True)
        self.display_status_name.add_css_class("usb-port-name")
        self.display_status_name.add_css_class("status-orange")

        self.display_status_text = Gtk.Label(
            label="NICHT GETESTET"
        )
        self.display_status_text.set_xalign(1)
        self.display_status_text.add_css_class("usb-port-state")
        self.display_status_text.add_css_class("status-orange")

        display_row.append(self.display_status_dot)
        display_row.append(self.display_status_name)
        display_row.append(self.display_status_text)
        display.append(display_row)
        left.append(display)

        # =====================================================
        # EINGABEGERÄTE
        # Touchpad + Keyboard + Touchscreen in einer gemeinsamen Karte.
        # Die bestehende Testlogik/Statusobjekte bleiben unverändert.
        # =====================================================
        input_devices = self.card("EINGABEGERÄTE")

        # Touchpad-Klicktest: beim Gedrückthalten blau, nach Loslassen grün.
        self.touchpad_rows = {}
        for side, label in (("left", "TOUCHPAD LINKS"), ("right", "TOUCHPAD RECHTS")):
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
            row.add_css_class("usb-row")
            dot = Gtk.Label(label="●")
            dot.add_css_class("status-orange")
            name = Gtk.Label(label=label)
            name.set_xalign(0)
            name.set_hexpand(True)
            name.add_css_class("usb-port-name")
            state = Gtk.Label(label="NICHT GETESTET")
            state.set_xalign(1)
            state.add_css_class("usb-port-state")
            state.add_css_class("status-orange")
            row.append(dot)
            row.append(name)
            row.append(state)
            input_devices.append(row)
            self.touchpad_rows[side] = (dot, name, state)

        # Touchscreen: feste Bezeichnung links, Zustand rechts.
        touch_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        touch_row.add_css_class("usb-row")

        self.touch_status_dot = Gtk.Label(label="●")
        self.touch_status_dot.add_css_class("status-orange")

        self.touch_status_name = Gtk.Label(label="TOUCHSCREEN (T)")
        self.touch_status_name.set_xalign(0)
        self.touch_status_name.set_hexpand(True)
        self.touch_status_name.add_css_class("usb-port-name")
        self.touch_status_name.add_css_class("status-orange")

        self.touch_status_text = Gtk.Label(label="NICHT GETESTET")
        self.touch_status_text.set_xalign(1)
        self.touch_status_text.add_css_class("usb-port-state")
        self.touch_status_text.add_css_class("status-orange")

        touch_row.append(self.touch_status_dot)
        touch_row.append(self.touch_status_name)
        touch_row.append(self.touch_status_text)

        # TOUCHSCREEN komplett ausblenden, solange auf dem aktuell getesteten
        # Notebook kein ID_INPUT_TOUCHSCREEN=1 Gerät erkannt wird.
        self.touchscreen_row = touch_row
        self.touchscreen_row.set_visible(False)
        input_devices.append(touch_row)

        # Keyboard wie die übrigen Eingabegeräte.
        # Start ausschließlich über den globalen Hotkey K.
        kb_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=7,
        )
        kb_row.add_css_class("usb-row")

        self.keyboard_status_dot = Gtk.Label(label="●")
        self.keyboard_status_dot.add_css_class("status-orange")

        self.keyboard_status_name = Gtk.Label(
            label="KEYBOARD (K)"
        )
        self.keyboard_status_name.set_xalign(0)
        self.keyboard_status_name.set_hexpand(True)
        self.keyboard_status_name.add_css_class("usb-port-name")
        self.keyboard_status_name.add_css_class("status-orange")

        self.keyboard_summary = Gtk.Label(label="0 GETESTET")
        self.keyboard_summary.set_xalign(1)
        self.keyboard_summary.add_css_class("usb-port-state")
        self.keyboard_summary.add_css_class("status-orange")

        kb_row.append(self.keyboard_status_dot)
        kb_row.append(self.keyboard_status_name)
        kb_row.append(self.keyboard_summary)
        input_devices.append(kb_row)

        left.append(input_devices)

        # =====================================================
        # RECHTE SPALTE
        # PORTS -> SENSOREN
        # =====================================================
        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        right.set_hexpand(True)

        ports = self.card("PORTS")
        ports.set_hexpand(True)
        ports.set_vexpand(False)

        # HDMI gehört jetzt gemeinsam mit den physischen USB-Anschlüssen
        # in die Kategorie PORTS. Testlogik/Statusobjekte bleiben unverändert.
        hdmi_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        hdmi_row.add_css_class("usb-row")
        self.hdmi_status_dot = Gtk.Label(label="●")
        self.hdmi_status_dot.add_css_class("status-orange")

        self.hdmi_status_detail = Gtk.Label(label="HDMI")
        self.hdmi_status_detail.set_xalign(0)
        self.hdmi_status_detail.set_hexpand(True)
        self.hdmi_status_detail.add_css_class("usb-port-name")
        self.hdmi_status_detail.add_css_class("status-orange")

        self.hdmi_status_text = Gtk.Label(label="NICHT GETESTET")
        self.hdmi_status_text.set_xalign(1)
        self.hdmi_status_text.add_css_class("usb-port-state")
        self.hdmi_status_text.add_css_class("status-orange")

        hdmi_row.append(self.hdmi_status_dot)
        hdmi_row.append(self.hdmi_status_detail)
        hdmi_row.append(self.hdmi_status_text)

        ports.append(hdmi_row)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(False)
        # Port-Erkennung bleibt auf dem bewährten Stand vor HC4.5.55.
        # Bei Überlauf soll der vertikale Scrollbalken jedoch sichtbar sein.
        scroll.set_overlay_scrolling(False)
        scroll.set_min_content_height(120)
        scroll.set_size_request(-1, 120)
        self.usb_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=4
        )
        scroll.set_child(self.usb_box)
        ports.append(scroll)
        right.append(ports)

        # =====================================================
        # SENSOREN
        # =====================================================
        sensors = self.card("SENSOREN")
        self.sensor_rows = {}

        for key, label in (
            ("cpu_temp", "CPU TEMP."),
            ("cpu_load", "CPU LAST"),
            ("cpu_clock", "CPU TAKT"),
            ("ssd_temp", "SSD TEMP."),
            ("fan", "FAN"),
        ):
            row = Gtk.Box(
                orientation=Gtk.Orientation.HORIZONTAL,
                spacing=7,
            )
            row.add_css_class("usb-row")

            dot = Gtk.Label(label="●")
            dot.add_css_class("status-blue")

            name = Gtk.Label(label=label)
            name.set_xalign(0)
            name.set_hexpand(True)
            name.add_css_class("usb-port-name")
            name.add_css_class("status-blue")

            state = Gtk.Label(label="--")
            state.set_xalign(1)
            state.add_css_class("usb-port-state")
            state.add_css_class("status-blue")

            row.append(dot)
            row.append(name)
            row.append(state)
            sensors.append(row)

            self.sensor_rows[key] = (dot, name, state)

        right.append(sensors)

        content.append(left)
        content.append(right)

        root.append(content)
        return root
    def set_status(self, widget, color, text):
        for c in ("status-green", "status-orange", "status-red"):
            widget.remove_css_class(c)
        widget.add_css_class("status-" + color)
        widget.set_text("● " + text)
    def refresh_security(self):
        c, t, d = detect_tpm()
        self.set_status(self.tpm_status, c, t); self.tpm_detail.set_text(d)
        c, t, d = detect_secure_boot()
        self.set_status(self.sb_status, c, t); self.sb_detail.set_text(d)
        log(f"Security aktualisiert: {self.tpm_status.get_text()} | {self.sb_status.get_text()}")

    def read_external_test_state(self, path):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return str(data.get("status") or "").strip().lower()
        except Exception:
            pass
        return ""

    def webcam_present_now(self):
        try:
            return any(Path("/dev").glob("video*"))
        except Exception:
            return False

    def ipu7_raw_camera_only_now(self):
        """Reines Intel-IPU7-ISYS-System ohne direkt nutzbare Webcam erkennen.

        So zeigt Hardware Check den Sonderstatus bereits korrekt an, auch wenn
        der separate Kamera-Test seine Statusdatei noch nicht geschrieben hat.
        Eine zusätzlich angeschlossene normale USB/UVC-Webcam verhindert den
        Sonderstatus und wird weiterhin normal getestet.
        """
        try:
            nodes = sorted(Path("/dev").glob("video*"))
        except Exception:
            return False

        if not nodes:
            return False

        ipu7_nodes = 0
        other_nodes = 0

        for dev in nodes:
            try:
                name = (
                    Path("/sys/class/video4linux")
                    / dev.name
                    / "name"
                ).read_text(
                    encoding="utf-8",
                    errors="ignore",
                ).strip().lower()
            except Exception:
                name = ""

            if "ipu7" in name and "isys capture" in name:
                ipu7_nodes += 1
            else:
                other_nodes += 1

        return ipu7_nodes > 0 and other_nodes == 0

    def microphone_present_now(self):
        try:
            data = Path("/proc/asound/pcm").read_text(
                encoding="utf-8",
                errors="ignore",
            ).lower()
            return "capture" in data
        except Exception:
            return False

    def write_hardware_refresh_request(self):
        try:
            self.hardware_refresh_file.parent.mkdir(
                parents=True,
                exist_ok=True,
            )
            payload = {
                "time": time.time(),
                "pid": os.getpid(),
            }
            tmp = self.hardware_refresh_file.with_suffix(".tmp")
            tmp.write_text(
                json.dumps(payload),
                encoding="utf-8",
            )
            tmp.replace(self.hardware_refresh_file)
            log("HC REFRESH-Signal für Camera/Audio geschrieben")
        except Exception as exc:
            log(f"HC REFRESH-Signal konnte nicht geschrieben werden: {exc}")

    def set_media_status_ui(self, kind, color, text):
        if kind == "webcam":
            dot = getattr(self, "webcam_status_dot", None)
            name = getattr(self, "webcam_status_name", None)
            label = getattr(self, "webcam_status_text", None)
        else:
            dot = getattr(self, "mic_status_dot", None)
            name = getattr(self, "mic_status_name", None)
            label = getattr(self, "mic_status_text", None)

        if dot is None or name is None or label is None:
            return False

        for widget in (dot, name, label):
            for cls in ("status-green", "status-orange", "status-red", "status-blue"):
                widget.remove_css_class(cls)
            widget.add_css_class("status-" + color)

        label.set_text(text)
        return False

    def refresh_media_status(self):
        camera_state = self.read_external_test_state(self.camera_state_file)
        if not camera_state:
            if self.ipu7_raw_camera_only_now():
                camera_state = "linux_unsupported"
            else:
                camera_state = (
                    "detected"
                    if self.webcam_present_now()
                    else "missing"
                )

        camera_map = {
            "missing": ("red", "NICHT ERKANNT"),
            "detected": ("orange", "ERKANNT"),
            "linux_unsupported": (
                "orange",
                "UNTER LINUX NICHT TESTBAR",
            ),
            "face": ("blue", "GESICHT ERKANNT"),
            "tested": ("green", "GETESTET"),
        }
        color, label = camera_map.get(
            camera_state,
            ("red", "NICHT ERKANNT"),
        )
        self.set_media_status_ui("webcam", color, label)

        audio_state = self.read_external_test_state(self.audio_state_file)
        if not audio_state:
            audio_state = (
                "detected"
                if self.microphone_present_now()
                else "missing"
            )

        audio_map = {
            "missing": ("red", "NICHT ERKANNT"),
            "detected": ("orange", "ERKANNT"),
            "auto": ("blue", "AUTO"),
            "tested": ("green", "GETESTET"),
        }
        color, label = audio_map.get(
            audio_state,
            ("red", "NICHT ERKANNT"),
        )
        self.set_media_status_ui("mic", color, label)
        return False

    def poll_media_status(self):
        if self.window is None:
            return False
        self.refresh_media_status()
        return True

    def set_sensor_status_ui(self, key, color, text):
        row = getattr(self, "sensor_rows", {}).get(key)
        if not row:
            return False

        dot, name, state = row

        for widget in (dot, name, state):
            for cls in (
                "status-green",
                "status-orange",
                "status-red",
                "status-blue",
            ):
                widget.remove_css_class(cls)
            widget.add_css_class("status-" + color)

        state.set_text(text)
        return False

    def read_cpu_usage_percent(self):
        current = read_cpu_times()
        previous = self.cpu_usage_prev
        self.cpu_usage_prev = current

        if not current or not previous:
            return None

        total_delta = current[0] - previous[0]
        idle_delta = current[1] - previous[1]

        if total_delta <= 0:
            return None

        usage = (
            (total_delta - idle_delta)
            / total_delta
            * 100.0
        )
        return max(0.0, min(100.0, usage))

    def refresh_sensors(self):
        # CPU TEMP.
        cpu_temp = read_cpu_temperature()
        if cpu_temp is None:
            self.set_sensor_status_ui(
                "cpu_temp",
                "orange",
                "NICHT GEFUNDEN",
            )
        else:
            if cpu_temp >= 95.0:
                color = "red"
            elif cpu_temp >= 85.0:
                color = "orange"
            else:
                color = "blue"

            self.set_sensor_status_ui(
                "cpu_temp",
                color,
                f"{cpu_temp:.0f} °C",
            )

        # CPU LAST
        cpu_load = self.read_cpu_usage_percent()
        if cpu_load is None:
            self.set_sensor_status_ui(
                "cpu_load",
                "orange",
                "NICHT GEFUNDEN",
            )
        else:
            shown_load = max(
                0,
                min(100, int(round(cpu_load))),
            )

            color = (
                "orange"
                if shown_load >= 100
                else "blue"
            )
            self.set_sensor_status_ui(
                "cpu_load",
                color,
                f"{shown_load} %",
            )

        # CPU TAKT
        cpu_mhz = read_cpu_average_frequency_mhz()
        if cpu_mhz is None:
            self.set_sensor_status_ui(
                "cpu_clock",
                "orange",
                "NICHT GEFUNDEN",
            )
        else:
            if cpu_mhz >= 1000.0:
                value = (
                    f"{cpu_mhz / 1000.0:.2f}"
                    .replace(".", ",")
                )
                value_text = f"{value} GHz"
            else:
                value_text = f"{cpu_mhz:.0f} MHz"

            self.set_sensor_status_ui(
                "cpu_clock",
                "blue",
                value_text,
            )

        # Datenträger TEMP.
        ssd_temp = read_ssd_temperature()
        if ssd_temp is None:
            self.set_sensor_status_ui(
                "ssd_temp",
                "orange",
                "NICHT GEFUNDEN",
            )
        else:
            if ssd_temp >= 70.0:
                color = "red"
            elif ssd_temp >= 60.0:
                color = "orange"
            else:
                color = "blue"

            self.set_sensor_status_ui(
                "ssd_temp",
                color,
                f"{ssd_temp:.0f} °C",
            )

        # FAN
        fan_key, fan_rpm, fan_percent = read_fan_status(
            self.fan_sensor_key
        )

        # Solange der gewählte Sensor vorhanden ist, bleibt HC exakt bei
        # diesem FAN. Nur bei echtem Verschwinden wird neu ausgewählt.
        if fan_key is not None:
            self.fan_sensor_key = fan_key
        else:
            self.fan_sensor_key = None

        if fan_rpm is None:
            self.set_sensor_status_ui(
                "fan",
                "orange",
                "NICHT GEFUNDEN",
            )
        else:
            rpm_text = (
                f"{int(round(fan_rpm)):,}"
                .replace(",", ".")
                + " RPM"
            )

            if fan_percent is not None:
                rpm_text += f" · {fan_percent}%"

            self.set_sensor_status_ui(
                "fan",
                "blue",
                rpm_text,
            )

        return False

    def poll_sensors(self):
        if self.window is None:
            return False

        self.refresh_sensors()
        return True

    def set_hdmi_status_ui(self, color, text, detail="HDMI"):
        if not hasattr(self, "hdmi_status_text"):
            return False

        # HDMI-Bezeichnung, Punkt und Status verwenden dieselbe Zustandsfarbe.
        self.hdmi_status_detail.set_text("HDMI")

        for widget in (
            self.hdmi_status_dot,
            self.hdmi_status_detail,
            self.hdmi_status_text,
        ):
            for cls in ("status-green", "status-orange", "status-red", "status-blue"):
                widget.remove_css_class(cls)
            widget.add_css_class("status-" + color)

        self.hdmi_status_text.set_text(text)
        return False

    def refresh_hdmi_status(self):
        state, detail = detect_hdmi()
        if state == "connected":
            self.hdmi_ever_connected = True
            self.set_hdmi_status_ui("blue", detail, "HDMI")
        elif state == "checking":
            self.set_hdmi_status_ui("blue", "PRÜFE VERBINDUNG", "HDMI")
        elif state == "error":
            self.set_hdmi_status_ui("red", "FEHLERHAFT", "HDMI")
        elif self.hdmi_ever_connected:
            self.set_hdmi_status_ui("green", "GETESTET", "HDMI")
        else:
            self.set_hdmi_status_ui("orange", "NICHT GETESTET", "HDMI")
        return False

    def poll_hdmi_status(self):
        if self.window is None:
            return False
        self.refresh_hdmi_status()
        return True

    def set_touchpad_state(self, side, state):
        row = getattr(self, "touchpad_rows", {}).get(side)
        if not row:
            return False
        dot, name, status = row
        for widget in (dot, name, status):
            for cls in ("status-green", "status-orange", "status-red", "status-blue"):
                widget.remove_css_class(cls)
        if state == "blue":
            color, text = "blue", "GEDRÜCKT"
        elif state == "green":
            color, text = "green", "GETESTET"
        elif state == "red":
            color, text = "red", "FEHLER"
        else:
            color, text = "orange", "NICHT GETESTET"
        dot.add_css_class("status-" + color)
        name.add_css_class("status-" + color)
        status.add_css_class("status-" + color)
        status.set_text(text)
        return False

    def reset_touchpad_test(self):
        self.touchpad_tested = {"left": False, "right": False}
        self.touchpad_pressed = {"left": False, "right": False}
        present = bool(get_touchpad_event_paths())
        for side in ("left", "right"):
            self.set_touchpad_state(side, "orange" if present else "red")
        return False

    def handle_touchpad_event(self, token):
        parts = token.split("-")
        if len(parts) != 3 or parts[0] != "touchpad":
            return False
        side, phase = parts[1], parts[2]
        if side not in ("left", "right"):
            return False
        if phase == "down":
            self.touchpad_pressed[side] = True
            self.set_touchpad_state(side, "blue")
        elif phase == "up":
            self.touchpad_pressed[side] = False
            self.touchpad_tested[side] = True
            self.set_touchpad_state(side, "green")
        return False

    def touchpad_libinput_command(self, device):
        """Command exactly matching the proven standalone v1.1 approach.

        libinput is important here because clickpads may synthesize logical
        BTN_RIGHT only after libinput processing; raw evdev is not sufficient.
        """
        base = ["libinput", "debug-events", "--device", device]

        if os.access(device, os.R_OK):
            return base

        sudo = shutil.which("sudo")
        if sudo:
            try:
                check = subprocess.run(
                    [sudo, "-n", "true"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1.2,
                    check=False,
                )
                if check.returncode == 0:
                    return [sudo, "-n"] + base
            except Exception:
                pass

        pkexec = shutil.which("pkexec")
        if pkexec:
            return [pkexec] + base

        return ([sudo] + base) if sudo else base

    def stop_touchpad_click_monitors(self):
        self.touchpad_monitor_stop.set()
        for proc in list(self.touchpad_monitor_processes):
            try:
                if proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass
        self.touchpad_monitor_processes = []

    def start_touchpad_click_monitors(self):
        self.stop_touchpad_click_monitors()
        self.touchpad_monitor_stop = threading.Event()
        self.touchpad_monitor_threads = []

        devices = get_touchpad_event_paths()
        if not devices:
            for side in ("left", "right"):
                self.set_touchpad_state(side, "red")
            log("Touchpad-Klicktest: kein ID_INPUT_TOUCHPAD=1 Gerät gefunden")
            return False

        if not shutil.which("libinput"):
            for side in ("left", "right"):
                self.set_touchpad_state(side, "red")
            log("Touchpad-Klicktest: libinput fehlt")
            return False

        monitor_stop = self.touchpad_monitor_stop
        for device in devices:
            thread = threading.Thread(
                target=self.touchpad_libinput_worker,
                args=(device, monitor_stop),
                name=f"touchpad-libinput-{Path(device).name}",
                daemon=True,
            )
            self.touchpad_monitor_threads.append(thread)
            thread.start()

        log(f"Touchpad-Klicktest: libinput Monitor für {len(devices)} Gerät(e) gestartet")
        return False

    def touchpad_libinput_worker(self, device, monitor_stop):
        cmd = self.touchpad_libinput_command(device)
        saw_event = False
        proc = None
        try:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            self.touchpad_monitor_processes.append(proc)

            if proc.stdout is None:
                raise RuntimeError("libinput stdout fehlt")

            for raw in proc.stdout:
                if monitor_stop.is_set():
                    break

                line = raw.strip()
                if "POINTER_BUTTON" not in line:
                    continue

                side = None
                if "BTN_LEFT" in line:
                    side = "left"
                elif "BTN_RIGHT" in line:
                    side = "right"

                if side is None:
                    continue

                saw_event = True
                if " pressed" in line:
                    GLib.idle_add(self.handle_touchpad_event, f"touchpad-{side}-down")
                elif " released" in line:
                    GLib.idle_add(self.handle_touchpad_event, f"touchpad-{side}-up")
        except Exception as exc:
            log(f"Touchpad libinput Fehler ({device}): {exc}")
        finally:
            if proc is not None:
                try:
                    self.touchpad_monitor_processes.remove(proc)
                except ValueError:
                    pass
            if not monitor_stop.is_set() and not saw_event:
                GLib.idle_add(self.set_touchpad_state, "left", "red")
                GLib.idle_add(self.set_touchpad_state, "right", "red")

    def touchscreen_present(self, force=False):
        now = time.monotonic()
        if (
            not force
            and self.touch_present_cache is not None
            and now - self.touch_present_checked_at < 5.0
        ):
            return self.touch_present_cache

        present = False
        for dev in sorted(glob.glob("/dev/input/event*")):
            try:
                p = subprocess.run(
                    ["udevadm", "info", "--query=property", f"--name={dev}"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=1.5,
                    check=False,
                )
            except Exception:
                continue
            if any(line.strip() == "ID_INPUT_TOUCHSCREEN=1" for line in p.stdout.splitlines()):
                present = True
                break

        self.touch_present_cache = present
        self.touch_present_checked_at = now
        return present

    def set_touch_status_ui(self, color, text, detail=None):
        if not hasattr(self, "touch_status_text"):
            return False

        for widget in (
            self.touch_status_dot,
            self.touch_status_name,
            self.touch_status_text,
        ):
            for cls in ("status-green", "status-orange", "status-red", "status-blue"):
                widget.remove_css_class(cls)
            widget.add_css_class("status-" + color)

        self.touch_status_text.set_text(text)
        return False

    def refresh_touch_status(self):
        data = None
        try:
            if self.touch_state_file.exists():
                data = json.loads(self.touch_state_file.read_text(encoding="utf-8"))
        except Exception as exc:
            log(f"Touch-Status nicht lesbar: {exc}")

        result = (data or {}).get("result")
        present = self.touchscreen_present()

        # Die gesamte Touchscreen-Zeile existiert nur auf Geräten, die
        # tatsächlich einen Touchscreen melden. So kann ein Notebook ohne
        # Touchscreen beim Test vollständig "grün" abgeschlossen werden.
        if hasattr(self, "touchscreen_row"):
            self.touchscreen_row.set_visible(present)

        # Statusdatei liegt auf dem persistenten Uwuntu-System. Deshalb hat
        # die aktuell erkannte Hardware immer Vorrang vor einem alten Ergebnis
        # von einem zuvor getesteten Notebook.
        if not present:
            self.touch_status_cache = result
            return False
        elif result == "success":
            self.set_touch_status_ui("green", "GETESTET")
        elif result == "running":
            self.set_touch_status_ui("blue", "TEST LÄUFT")
        elif result in {"error", "failed"}:
            self.set_touch_status_ui("red", "NICHT BESTANDEN")
        elif result == "aborted":
            self.set_touch_status_ui("orange", "ABGEBROCHEN")
        elif result == "no_touchscreen":
            self.set_touch_status_ui("orange", "NICHT GETESTET")
        else:
            self.set_touch_status_ui("orange", "NICHT GETESTET")

        self.touch_status_cache = result
        return False

    def poll_touch_status(self):
        if self.window is None:
            return False
        self.refresh_touch_status()
        return True

    def start_touch_test(self, *_):
        if not self.touchscreen_present(force=True):
            if hasattr(self, "touchscreen_row"):
                self.touchscreen_row.set_visible(False)
            log("Touch-Test per T ignoriert: kein Touchscreen erkannt")
            return False

        if not self.touch_script.exists():
            self.set_touch_status_ui("red", "TOUCH-TESTER FEHLT")
            log("Touch-Test per T fehlgeschlagen: Script fehlt")
            return False

        now = time.monotonic()

        # Ein physischer T-Tastendruck kann nahezu gleichzeitig über GTK und
        # den globalen /dev/input-Monitor ankommen. Vor pgrep greift deshalb
        # eine eigene Start-Sperre, damit niemals zwei Starts durchrutschen.
        if now < self.touch_launch_guard_until:
            log("Touch-Test per T ignoriert: Startsperre aktiv")
            return False

        # Von HC selbst gestartete Instanz direkt verfolgen.
        try:
            if self.touch_proc is not None and self.touch_proc.poll() is None:
                log("Touch-Test per T bereits geöffnet (eigener Prozess)")
                return False
        except Exception:
            self.touch_proc = None

        # Der Shell-Launcher exec't unmittelbar zu
        # "uwuntu-touch-tester-python". Deshalb sowohl den echten Prozessnamen
        # als auch den Script-Pfad prüfen.
        running = False
        for pattern in (
            "uwuntu-touch-tester-python",
            str(self.touch_script),
        ):
            try:
                if subprocess.run(
                    ["pgrep", "-f", pattern],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1.0,
                    check=False,
                ).returncode == 0:
                    running = True
                    break
            except Exception:
                pass

        if running:
            log("Touch-Test per T bereits geöffnet")
            return False

        # Sperre VOR Popen setzen: genau hier lag bisher das Race-Fenster.
        self.touch_launch_guard_until = now + 1.5

        try:
            self.touch_proc = subprocess.Popen(
                [str(self.touch_script)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            self.set_touch_status_ui("blue", "TEST WIRD GESTARTET")
            log(
                "Touch-Test per T gestartet "
                f"(PID {self.touch_proc.pid})"
            )
        except Exception as exc:
            self.touch_proc = None
            self.touch_launch_guard_until = 0.0
            self.set_touch_status_ui("red", "TOUCH-TEST STARTFEHLER")
            log(f"Touch-Test per T Startfehler: {exc}")
        return False

    def set_display_status_ui(self, color, text, detail=None):
        if not hasattr(self, "display_status_text"):
            return False

        for widget in (
            self.display_status_dot,
            self.display_status_name,
            self.display_status_text,
        ):
            for cls in (
                "status-green",
                "status-orange",
                "status-red",
                "status-blue",
            ):
                widget.remove_css_class(cls)
            widget.add_css_class("status-" + color)

        self.display_status_text.set_text(text)
        return False

    def refresh_display_status(self):
        data = None
        try:
            if self.display_state_file.exists():
                data = json.loads(
                    self.display_state_file.read_text(encoding="utf-8")
                )
        except Exception as exc:
            log(f"Display-Status nicht lesbar: {exc}")

        result = (data or {}).get("result")

        if result == "success":
            self.display_test_active = False
            self.display_proc = None
            self.display_launch_grace_until = 0.0
            self.set_display_status_ui(
                "green",
                "GETESTET",
            )

        elif result == "running":
            self.display_test_active = True
            self.set_display_status_ui(
                "blue",
                "LÄUFT",
            )

        elif result == "aborted":
            self.display_test_active = False
            self.display_proc = None
            self.display_launch_grace_until = 0.0
            self.set_display_status_ui(
                "orange",
                "ABGEBROCHEN",
            )

        elif result == "error":
            self.display_test_active = False
            self.display_proc = None
            self.display_launch_grace_until = 0.0
            self.set_display_status_ui(
                "red",
                "FEHLER",
            )

        elif self.display_test_active:
            # Direkt nach D kann der Poller schneller sein als der gestartete
            # Display-Test beim Schreiben seiner ersten "running"-Statusdatei.
            # Solange unser eigener Prozess noch lebt oder die kurze
            # Start-Schonfrist läuft, darf HC deshalb NICHT auf
            # NICHT GETESTET zurückspringen.
            proc_running = False
            try:
                proc_running = (
                    self.display_proc is not None
                    and self.display_proc.poll() is None
                )
            except Exception:
                proc_running = False

            if (
                proc_running
                or time.monotonic() < self.display_launch_grace_until
            ):
                self.set_display_status_ui(
                    "blue",
                    "LÄUFT",
                )
            else:
                self.display_test_active = False
                self.display_proc = None
                self.display_launch_grace_until = 0.0
                self.set_display_status_ui(
                    "orange",
                    "NICHT GETESTET",
                )

        else:
            self.set_display_status_ui(
                "orange",
                "NICHT GETESTET",
            )

        return False

    def poll_display_status(self):
        if self.window is None:
            return False
        self.refresh_display_status()
        return True

    def start_display_test(self, *_):
        if not self.display_script.exists():
            self.set_display_status_ui("orange", "TESTER FEHLT")
            log("Display-Test per D fehlgeschlagen: Script fehlt")
            return False

        # Eigener gestarteter Prozess ist die zuverlässigste Erkennung.
        try:
            if (
                self.display_proc is not None
                and self.display_proc.poll() is None
            ):
                self.display_test_active = True
                self.set_display_status_ui("blue", "LÄUFT")
                log("Display-Test per D bereits geöffnet")
                return False
        except Exception:
            self.display_proc = None

        # Zusätzlich alte/externe Instanz erkennen.
        try:
            running = subprocess.run(
                [
                    "pgrep",
                    "-f",
                    "uwuntu-display-test-python",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.0,
                check=False,
            ).returncode == 0
        except Exception:
            running = False

        if running:
            self.display_test_active = True
            self.set_display_status_ui("blue", "LÄUFT")
            log("Display-Test per D bereits geöffnet")
            return False

        # Ein altes SUCCESS/ABORTED darf beim Start eines neuen Tests nicht
        # für einen Poll-Zyklus wieder angezeigt werden.
        try:
            self.display_state_file.unlink(missing_ok=True)
        except Exception as exc:
            log(f"Alter Display-Status konnte nicht gelöscht werden: {exc}")

        try:
            self.display_test_active = True
            self.display_launch_grace_until = time.monotonic() + 3.0
            self.set_display_status_ui("blue", "LÄUFT")

            self.display_proc = subprocess.Popen(
                [str(self.display_script)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )

            log(
                "Display-Test per D gestartet "
                f"(PID {self.display_proc.pid})"
            )

        except Exception as exc:
            self.display_test_active = False
            self.display_proc = None
            self.display_launch_grace_until = 0.0
            self.set_display_status_ui("red", "STARTFEHLER")
            log(f"Display-Test per D Startfehler: {exc}")

        return False

    def start_global_input_listener(self):
        """Hardware-Hotkeys und Touchpad-Klicks auch ohne Fokus erkennen.

        Der Monitor liest /dev/input ausschließlich mit und greift niemals
        ein Eingabegerät exklusiv. Dadurch kann der Keyboard-Test keine Maus-
        oder Touchpadbewegung blockieren.
        Zuerst wird direkter Zugriff probiert; falls Ubuntu /dev/input sperrt,
        folgt automatisch ``sudo -n``.
        """
        if self.global_input_thread and self.global_input_thread.is_alive():
            return

        self.global_input_stop.clear()
        self.global_input_thread = threading.Thread(
            target=self.global_input_listener_loop,
            name="hardware-check-global-input",
            daemon=True,
        )
        self.global_input_thread.start()

    def start_input_monitor_process(self, use_sudo=False):
        cmd = [
            sys.executable,
            "-u",
            sys.argv[0],
            "--global-arrow-monitor",
            str(os.getpid()),
        ]
        if use_sudo:
            sudo = shutil.which("sudo")
            if not sudo:
                return None
            cmd = [sudo, "-n"] + cmd

        try:
            return subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
                start_new_session=True,
            )
        except Exception as exc:
            log(
                "Globaler Hotkey-Monitor konnte nicht gestartet werden: "
                f"{exc}"
            )
            return None

    def send_global_input_command(self, command, proc=None):
        """Kommando an den /dev/input-Helfer senden."""
        target = proc if proc is not None else self.global_input_proc
        if target is None or target.poll() is not None or target.stdin is None:
            return False

        try:
            with self.global_input_command_lock:
                target.stdin.write((command.strip() + "\n").encode("ascii"))
                target.stdin.flush()
            return True
        except Exception as exc:
            log(f"Globaler Eingabe-Monitor Kommando '{command}' fehlgeschlagen: {exc}")
            return False

    def set_keyboard_input_grab(self, enabled):
        """HC4.5.45: Exklusive /dev/input-Grabs sind bewusst deaktiviert.

        Einige Laptop-HID-Geräte melden Keyboard- und Pointer-Funktionen über
        gekoppelte Event-Interfaces. Ein EVIOCGRAB kann dort die Mausbewegung
        blockieren. Der globale Monitor bleibt deshalb ausschließlich
        read-only. Desktop-Shortcuts werden über GSettings neutralisiert.
        """
        self.keyboard_input_grab_desired = False
        self.keyboard_input_grab_active = False
        return False


    def sudo_input_monitor_available(self):
        sudo = shutil.which("sudo")
        if not sudo:
            return False
        try:
            check = subprocess.run(
                [sudo, "-n", "true"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
            )
            return check.returncode == 0
        except Exception:
            return False

    def stop_input_monitor_process(self, proc):
        if proc is None or proc.poll() is not None:
            return

        # Der Helfer läuft in einer eigenen Session/Prozessgruppe. Dadurch
        # wird auch ein möglicher sudo->python-Kindprozess sicher beendet und
        # dessen /dev/input-FDs werden garantiert geschlossen.
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=0.7)
            return
        except Exception:
            pass

        try:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=0.5)
            return
        except Exception:
            pass

        try:
            proc.kill()
        except Exception:
            pass


    def run_input_monitor_session(self, use_sudo):
        """Eine Monitor-Sitzung ausführen.

        True = echte Tastatur wurde geöffnet (ready empfangen).
        False = Start/Handshake fehlgeschlagen, anderer Modus probieren.
        """
        proc = self.start_input_monitor_process(use_sudo=use_sudo)
        if proc is None or proc.stdout is None:
            return False

        mode = "sudo -n" if use_sudo else "direkter Zugriff"
        self.global_input_proc = proc
        self.global_input_active = False

        pending = b""
        fd = proc.stdout.fileno()
        ready_seen = False
        ready_deadline = time.monotonic() + 1.5

        try:
            while not self.global_input_stop.is_set() and proc.poll() is None:
                # Erst nach einem echten 'ready N' gilt der globale Listener
                # als aktiv. So kann ein kurzlebiger/fehlerhafter Helfer den
                # GTK-Fallback nicht fälschlich abschalten.
                if not ready_seen and time.monotonic() >= ready_deadline:
                    log(
                        "Globaler Hotkey-Monitor ohne Tastatur-READY "
                        f"({mode})"
                    )
                    break

                try:
                    ready, _, _ = select.select([fd], [], [], 0.25)
                except (OSError, ValueError):
                    break
                if not ready:
                    continue

                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break

                pending += chunk
                while b"\n" in pending:
                    raw, pending = pending.split(b"\n", 1)
                    token = raw.decode("ascii", errors="ignore").strip()

                    if token.startswith("ready "):
                        ready_seen = True
                        self.global_input_active = True
                        log(
                            "Globaler Hotkey-Monitor aktiv ("
                            + mode
                            + "): "
                            + token.split(" ", 1)[1]
                            + " Tastaturgerät(e)"
                        )
                        if self.keyboard_input_grab_desired:
                            self.send_global_input_command("grab", proc=proc)
                        continue

                    if token.startswith("grabbed "):
                        try:
                            _, ok, failed = token.split()
                            ok_count = int(ok)
                        except (ValueError, TypeError):
                            ok, failed = "?", "?"
                            ok_count = 0

                        self.keyboard_input_grab_active = ok_count > 0
                        log(
                            "Tastatur-Test: exklusiver Input-Grab aktiv "
                            f"({ok} Gerät(e), {failed} Fehler)"
                        )
                        continue

                    if token.startswith("ungrabbed "):
                        self.keyboard_input_grab_active = False
                        log("Tastatur-Test: exklusiver Input-Grab freigegeben")
                        continue

                    if token == "keyboard-exit":
                        self.keyboard_input_grab_active = False
                        self.keyboard_input_grab_desired = False
                        GLib.idle_add(self.finish_keyboard_test_from_monitor)
                        continue

                    if token.startswith("grab-device-failed "):
                        log("Keyboard-Test: Grab fehlgeschlagen: " + token.split(" ", 1)[1])
                        continue

                    if token.startswith("pointer-capable-keyboard "):
                        log(
                            "Keyboard-Test: Gerät liefert auch Pointer-Achsen "
                            "und wird deshalb NICHT exklusiv gegriffen: "
                            + token.split(" ", 1)[1]
                        )
                        continue

                    if (
                        token.startswith("keycode:")
                        or token in {
                            "escape", "benchmark", "all", "keyboard", "ram",
                            "info", "update", "warranty",
                            "hotkeys", "touch", "display",
                            "audio-left", "audio-both", "audio-right", "audio-auto",
                        }
                    ):
                        GLib.idle_add(self.handle_global_hotkey, token)
        finally:
            self.global_input_active = False
            self.keyboard_input_grab_active = False
            self.global_input_proc = None
            self.stop_input_monitor_process(proc)

        if ready_seen and not self.global_input_stop.is_set():
            log(
                "Globaler Hotkey-Monitor unerwartet beendet; "
                "wird automatisch neu gestartet"
            )

        return ready_seen

    def global_input_listener_loop(self):
        # Selbstheilender Listener: Der globale Monitor läuft so lange neu an,
        # wie Hardware Check geöffnet ist. Auf Uwuntu bevorzugen wir sudo -n,
        # weil /dev/input/event* für normale Desktop-Benutzer häufig nur
        # teilweise lesbar ist. Direkter Zugriff bleibt als Fallback erhalten.
        while not self.global_input_stop.is_set():
            modes = []
            if self.sudo_input_monitor_available():
                modes.append(True)
            modes.append(False)

            had_ready = False
            for use_sudo in modes:
                if self.global_input_stop.is_set():
                    break

                had_ready = self.run_input_monitor_session(use_sudo)
                if had_ready:
                    # Eine funktionierende Sitzung ist erst hierher
                    # zurückgekehrt, wenn sie beendet wurde. Danach nicht noch
                    # einen zweiten Modus starten, sondern sauber neu verbinden.
                    break

            if self.global_input_stop.is_set():
                break

            if not had_ready:
                log(
                    "Globaler Hotkey-Monitor: keine Tastatur lesbar; "
                    "erneuter Versuch in 1 Sekunde"
                )
                self.global_input_stop.wait(1.0)
            else:
                self.global_input_stop.wait(0.35)

    def close_system_info(self, *_):
        window = self.info_window
        self.info_window = None
        if window is not None:
            try:
                window.destroy()
            except Exception:
                pass
        return True

    def on_info_key(self, controller, keyval, keycode, state):
        name = Gdk.keyval_name(keyval) or ""
        if name == "Escape" or (
            state & Gdk.ModifierType.CONTROL_MASK and name.lower() == "w"
        ):
            self.close_system_info()
            return True
        return False

    def restore_center_new_windows(self, previous):
        try:
            subprocess.run(
                [
                    "gsettings", "set",
                    "org.gnome.mutter",
                    "center-new-windows",
                    previous,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
                check=False,
            )
        except Exception:
            pass
        return False

    def present_centered(self, window):
        # Unter Wayland dürfen Anwendungen Fenster nicht selbst per X/Y
        # verschieben. Für dieses einzelne Infofenster bitten wir daher
        # Mutter kurzzeitig um zentrierte Platzierung und stellen die
        # vorherige Einstellung direkt danach wieder her.
        previous = None
        try:
            current = subprocess.check_output(
                [
                    "gsettings", "get",
                    "org.gnome.mutter",
                    "center-new-windows",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
            ).strip().lower()
            if current in {"true", "false"}:
                previous = current
                if current != "true":
                    subprocess.run(
                        [
                            "gsettings", "set",
                            "org.gnome.mutter",
                            "center-new-windows",
                            "true",
                        ],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=1.5,
                        check=False,
                    )
        except Exception:
            previous = None

        window.present()

        if previous == "false":
            GLib.timeout_add(500, self.restore_center_new_windows, previous)

    def bind_priority_window_after_centering(self, window):
        """Vordergrundbindung erst nach der Bildschirm-Zentrierung setzen.

        Ein bereits vor dem ersten Mapping gesetztes transient-for lässt
        Mutter/Wayland das Fenster relativ zum gekachelten Hardware-Check
        platzieren. Deshalb wird zuerst normal zentriert und die Bindung erst
        nach dem Platzieren ergänzt.
        """
        if window is None or self.window is None:
            return False
        try:
            if not window.get_visible():
                return False
            window.set_transient_for(self.window)
        except Exception:
            pass
        return False

    def copy_serial_to_clipboard(self, serial):
        """Erkannte Seriennummer für anschließendes Strg+V kopieren.

        Unter Wayland wird bewusst wl-copy als primärer Weg verwendet.
        Das hält die Zwischenablage unabhängig von GTK/GDK zuverlässig im
        Wayland-Compositor. GTK bleibt nur noch als Fallback.
        """
        if not serial:
            return False

        serial = str(serial).strip()
        if not serial:
            return False

        session_type = os.environ.get("XDG_SESSION_TYPE", "").strip().lower()

        # Wayland: wl-copy ist der zuverlässigste systemweite Clipboard-Weg.
        # Das Paket wl-clipboard wird vom Manager automatisch installiert.
        if session_type == "wayland":
            wl_copy = shutil.which("wl-copy")
            if wl_copy:
                try:
                    proc = subprocess.run(
                        [wl_copy],
                        input=serial,
                        text=True,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=3.0,
                        check=False,
                    )
                    if proc.returncode == 0:
                        self.serial_clipboard_text = serial
                        log(f"Seriennummer per wl-copy kopiert: {serial}")
                        return True
                    log(
                        "wl-copy konnte Seriennummer nicht kopieren "
                        f"(Exit {proc.returncode})"
                    )
                except Exception as exc:
                    log(f"wl-copy fehlgeschlagen: {exc}")
            else:
                log("Wayland aktiv, aber wl-copy nicht gefunden")

        # GTK4/GDK als Fallback.
        try:
            display = Gdk.Display.get_default()
            if display is None:
                raise RuntimeError("Kein GDK-Display verfügbar")

            clipboard = display.get_clipboard()
            if clipboard is None:
                raise RuntimeError("Keine GDK-Zwischenablage verfügbar")

            clipboard.set_text(serial)
            self.serial_clipboard = clipboard
            self.serial_clipboard_text = serial

            try:
                display.flush()
            except Exception:
                pass

            log(f"Seriennummer per GTK4-Fallback kopiert: {serial}")
            return True
        except Exception as exc:
            log(f"GTK4-Zwischenablage fehlgeschlagen: {exc}")

        # X11-Fallback, falls xclip bereits vorhanden ist.
        xclip = shutil.which("xclip")
        if xclip:
            try:
                proc = subprocess.run(
                    [xclip, "-selection", "clipboard"],
                    input=serial,
                    text=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3.0,
                    check=False,
                )
                if proc.returncode == 0:
                    self.serial_clipboard_text = serial
                    log(f"Seriennummer per xclip kopiert: {serial}")
                    return True
            except Exception as exc:
                log(f"xclip fehlgeschlagen: {exc}")

        log("Seriennummer konnte nicht in die Zwischenablage kopiert werden")
        return False

    def open_warranty_support(self, *_):
        # 1) IMMER zuerst Seriennummer zentral auslesen und über die bereits
        # vorhandene/getestete Clipboard-Funktion kopieren.
        serial = detect_system_serial()
        if serial != "--":
            self.copy_serial_to_clipboard(serial)

        # 2) Erst danach Hersteller-/Garantie-Ziel bestimmen.
        target = warranty_support_target(serial)

        # Unbekannter/anderer Hersteller: Seriennummer bleibt im Clipboard,
        # ansonsten bewusst keinerlei Aktion, Meldung oder Browserfenster.
        if target is None:
            return False

        vendor, _, _, url = target

        opener = shutil.which("xdg-open")
        cmd = [opener, url] if opener else None

        if cmd is None:
            gio = shutil.which("gio")
            if gio:
                cmd = [gio, "open", url]

        # Kein sichtbares Fehlerfenster erzeugen.
        if cmd is None:
            return False

        try:
            subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            log(
                f"{vendor}-Garantie/Support geöffnet: "
                f"Seriennummer {serial}"
            )
        except Exception:
            # Garantie-Shortcut bleibt bewusst still.
            pass

        return False

    def focus_info_serial_button(self, button):
        if self.info_window is not None:
            try:
                button.grab_focus()
            except Exception:
                pass
        return False

    def show_system_info(self, *_):
        if not self.stack or self.stack.get_visible_child_name() == "keyboard":
            return False

        if self.info_window is not None:
            try:
                self.info_window.present()
                return False
            except Exception:
                self.info_window = None

        info = Gtk.ApplicationWindow(application=self)
        info.set_title("Systeminformationen")
        info.set_default_size(560, 300)
        info.set_resizable(False)
        info.connect("close-request", self.close_system_info)

        key_controller = Gtk.EventControllerKey.new()
        key_controller.connect("key-pressed", self.on_info_key)
        info.add_controller(key_controller)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.set_margin_top(10)
        outer.set_margin_bottom(10)
        outer.set_margin_start(16)
        outer.set_margin_end(16)

        title = Gtk.Label(label="SYSTEMINFORMATIONEN")
        title.set_xalign(0)
        title.add_css_class("info-title")
        outer.append(title)

        card = Gtk.Grid()
        card.set_row_spacing(8)
        card.set_column_spacing(18)
        card.add_css_class("info-card")

        info_values = system_information()
        displayed_serial = next(
            (
                value
                for label, value in info_values
                if label == "Seriennummer"
            ),
            "--",
        )
        support_target = warranty_support_target(displayed_serial)
        support_vendor = support_target[0] if support_target else None
        support_serial = support_target[2] if support_target else None
        serial_button = None

        for row, (label_text, value_text) in enumerate(info_values):
            label = Gtk.Label(label=label_text)
            label.set_xalign(0)
            label.set_valign(Gtk.Align.START)
            label.add_css_class("info-label")

            if (
                label_text == "Seriennummer"
                and support_serial is not None
                and value_text == support_serial
            ):
                # Bei unterstützten Dell-/Lenovo-Geräten ist die
                # Seriennummer direkt bedienbar. Enter/Leertaste oder Klick
                # öffnen die passende Garantie-/Supportseite.
                value = Gtk.Button(label=value_text)
                value.set_halign(Gtk.Align.START)
                value.set_focusable(True)
                value.add_css_class("info-serial-link")
                value.set_tooltip_text(
                    f"{support_vendor} Garantie / Support öffnen "
                    "(Enter oder Leertaste)"
                )
                value.connect("clicked", self.open_warranty_support)
                serial_button = value
            else:
                value = Gtk.Label(label=value_text)
                value.set_xalign(0)
                value.set_hexpand(True)
                value.set_wrap(True)
                # Alle übrigen Info-Werte sind reine Anzeige und bekommen
                # keinen Fokus bzw. keine Textauswahl.
                value.set_selectable(False)
                value.set_focusable(False)
                value.add_css_class("info-value")

            card.attach(label, 0, row, 1, 1)
            card.attach(value, 1, row, 1, 1)

        outer.append(card)
        info.set_child(outer)

        self.info_window = info
        if serial_button is not None:
            info.set_default_widget(serial_button)
        self.present_centered(info)
        if serial_button is not None:
            GLib.timeout_add(60, self.focus_info_serial_button, serial_button)
        log("Systeminformationen per I mittig geöffnet")
        return False

    def _wlan_diag_set_title_color(self, color=None):
        label = getattr(self, "wlan_diag_title_label", None)
        if label is None:
            return False
        for cls in ("status-green", "status-orange", "status-red", "status-blue"):
            label.remove_css_class(cls)
        if color:
            label.add_css_class("status-" + color)
        return False

    def _wlan_diag_push_status(self, text):
        if not getattr(self, "wlan_diag_active", False):
            return False
        self.wlan_diag_lines.append(
            f"[{time.strftime('%H:%M:%S')}] {str(text).strip()}"
        )
        self.wlan_diag_lines = self.wlan_diag_lines[-8:]
        label = getattr(self, "wlan_diag_live_label", None)
        if label is not None:
            label.set_text("\n".join(self.wlan_diag_lines))
        return False

    def _wlan_diag_hide_overlay(self):
        self.wlan_diag_hide_source = None
        overlay = getattr(self, "wlan_diag_overlay", None)
        if overlay is not None and not self.wlan_diag_active:
            overlay.set_visible(False)
        return False

    @staticmethod
    def _wlan_diag_run_command(args, sudo_ok=False, root=False, timeout=12, env=None):
        cmd = [str(value) for value in args]
        sudo = shutil.which("sudo")
        if root and sudo_ok and sudo:
            cmd = [sudo, "-n"] + cmd
        try:
            proc = subprocess.run(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=timeout,
                env=env,
                check=False,
            )
            return proc.returncode, proc.stdout or ""
        except subprocess.TimeoutExpired as exc:
            output = exc.stdout or ""
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            return 124, output + f"\n[Timeout nach {timeout}s]\n"
        except Exception as exc:
            return 99, f"[Befehl nicht ausführbar: {exc}]\n"

    def _wlan_diag_worker(self):
        output_path = None
        try:
            env = os.environ.copy()
            env["LC_ALL"] = "C"
            env["LANG"] = "C"

            sudo_ok = False
            sudo = shutil.which("sudo")
            if sudo:
                rc, _ = self._wlan_diag_run_command(
                    [sudo, "-n", "true"],
                    timeout=2,
                    env=env,
                )
                sudo_ok = rc == 0

            home = Path.home()
            output_dir = home
            for candidate in (home / "Schreibtisch", home / "Desktop"):
                if candidate.is_dir():
                    output_dir = candidate
                    break

            stamp = time.strftime("%Y-%m-%d_%H-%M-%S")
            output_path = output_dir / f"Uwuntu-WLAN-Diagnose-{stamp}.txt"

            rc, devices = self._wlan_diag_run_command(
                ["nmcli", "-t", "-f", "DEVICE,TYPE", "device", "status"],
                timeout=5,
                env=env,
            )
            wifi_iface = ""
            lan_iface = ""
            if rc == 0:
                for raw in devices.splitlines():
                    parts = raw.rsplit(":", 1)
                    if len(parts) != 2:
                        continue
                    dev, kind = parts
                    if kind == "wifi" and not wifi_iface:
                        wifi_iface = dev
                    elif kind == "ethernet" and not lan_iface:
                        lan_iface = dev

            def status(text):
                GLib.idle_add(self._wlan_diag_push_status, text)

            def write_section(handle, title):
                handle.write("\n\n" + "=" * 70 + "\n")
                handle.write(title + "\n")
                handle.write("=" * 70 + "\n")

            def write_command(handle, args, root=False, timeout=12, filter_pattern=None, exclude_pattern=None, tail=None):
                handle.write("\n$ " + " ".join(str(x) for x in args) + "\n")
                handle.write("-" * 70 + "\n")
                _, output = self._wlan_diag_run_command(
                    args,
                    sudo_ok=sudo_ok,
                    root=root,
                    timeout=timeout,
                    env=env,
                )
                lines = output.splitlines()
                if filter_pattern is not None:
                    pattern = re.compile(filter_pattern, re.I)
                    lines = [line for line in lines if pattern.search(line)]
                if exclude_pattern is not None:
                    pattern = re.compile(exclude_pattern, re.I)
                    lines = [line for line in lines if not pattern.search(line)]
                if tail is not None:
                    lines = lines[-int(tail):]
                if not lines and (filter_pattern is not None or exclude_pattern is not None):
                    lines = ["[keine relevanten Treffer]"]
                handle.write("\n".join(lines))
                handle.write("\n")

            status("Vorbereitung und Rechte prüfen")
            with output_path.open("w", encoding="utf-8", errors="replace") as handle:
                handle.write("UWUNTU WLAN DIAGNOSE – SOFORTAUFNAHME\n")
                handle.write("=" * 70 + "\n")
                handle.write(f"Zeit:              {time.strftime('%Y-%m-%d %H:%M:%S %z')}\n")
                handle.write(f"Hostname:          {os.uname().nodename}\n")
                handle.write(f"WLAN:              {wifi_iface or 'NICHT ERKANNT'}\n")
                handle.write(f"LAN:               {lan_iface or 'NICHT ERKANNT'}\n")
                handle.write("Ziel-SSID:         Guest\n")
                handle.write(f"Root-Zugriff:      {'sudo -n' if sudo_ok else 'ohne Root-Rechte'}\n")
                try:
                    uptime = Path("/proc/uptime").read_text().split()[0]
                except Exception:
                    uptime = "unbekannt"
                handle.write(f"Monotone Uptime:   {uptime} Sekunden\n")

                status("Netzwerkzustand erfassen")
                write_section(handle, "1. SOFORTIGER NETZWERK-ZUSTAND")
                for args in (
                    ["nmcli", "general", "status"],
                    ["nmcli", "radio"],
                    ["nmcli", "device", "status"],
                    ["nmcli", "-f", "NAME,UUID,TYPE,DEVICE", "connection", "show", "--active"],
                    ["ip", "-4", "address"],
                    ["ip", "route"],
                ):
                    write_command(handle, args)

                status("WLAN-Link und Access Points erfassen")
                write_section(handle, "2. WLAN LIVE")
                if wifi_iface:
                    for args in (
                        ["nmcli", "device", "show", wifi_iface],
                        ["iw", "dev", wifi_iface, "link"],
                        ["iw", "dev", wifi_iface, "info"],
                        ["iw", "dev", wifi_iface, "get", "power_save"],
                        ["iw", "dev", wifi_iface, "station", "dump"],
                        ["ip", "-s", "link", "show", "dev", wifi_iface],
                        [
                            "nmcli", "-f",
                            "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,RATE,SECURITY",
                            "device", "wifi", "list", "ifname", wifi_iface,
                            "--rescan", "no",
                        ],
                    ):
                        write_command(handle, args)
                else:
                    handle.write("\nKein WLAN-Interface erkannt.\n")

                status("NetworkManager und wpa_supplicant sammeln")
                write_section(handle, "3. WPA_SUPPLICANT / GUEST-PROFIL")
                if wifi_iface:
                    write_command(
                        handle,
                        ["wpa_cli", "-i", wifi_iface, "status"],
                        root=True,
                    )
                write_command(
                    handle,
                    ["systemctl", "status", "wpa_supplicant", "--no-pager", "-l"],
                )
                profile_fields = ",".join((
                    "connection.id",
                    "connection.uuid",
                    "connection.interface-name",
                    "connection.autoconnect",
                    "connection.autoconnect-priority",
                    "connection.autoconnect-retries",
                    "802-11-wireless.ssid",
                    "802-11-wireless.bssid",
                    "802-11-wireless.mac-address",
                    "802-11-wireless.cloned-mac-address",
                    "802-11-wireless.powersave",
                    "ipv4.method",
                    "ipv6.method",
                ))
                write_command(
                    handle,
                    ["nmcli", "-f", profile_fields, "connection", "show", "Guest"],
                )

                write_section(handle, "4. WLAN-HARDWARE")
                write_command(
                    handle,
                    ["lspci", "-nnk"],
                    filter_pattern=r"Network controller|Ethernet controller|Subsystem:|Kernel driver|Kernel modules",
                )
                if wifi_iface:
                    write_command(handle, ["ethtool", "-i", wifi_iface], root=True)
                write_command(handle, ["rfkill", "list"])
                write_command(handle, ["iw", "reg", "get"])
                for args in (
                    ["dmidecode", "-s", "system-product-name"],
                    ["dmidecode", "-s", "bios-version"],
                    ["dmidecode", "-s", "bios-release-date"],
                ):
                    write_command(handle, args, root=True)

                status("Self-Heal-Zustand erfassen")
                write_section(handle, "5. UWUNTU WLAN SELF-HEAL")
                write_command(
                    handle,
                    ["systemctl", "status", "uwuntu-wifi-selfheal.timer", "--no-pager", "-l"],
                )
                write_command(
                    handle,
                    ["systemctl", "status", "uwuntu-wifi-selfheal.service", "--no-pager", "-l"],
                )
                write_command(
                    handle,
                    ["tail", "-n", "1000", "/var/log/uwuntu-wifi-selfheal.log"],
                    root=True,
                )
                script = Path("/usr/local/sbin/uwuntu-wifi-selfheal.sh")
                if script.exists():
                    handle.write("\nInstallierte Self-Heal-Version:\n")
                    try:
                        for line in script.read_text(
                            encoding="utf-8", errors="replace"
                        ).splitlines():
                            if (
                                line.startswith("# Version")
                                or line.startswith("AUTOCONNECT_GRACE_SECONDS=")
                                or line.startswith("READY_STABLE_SECONDS=")
                                or line.startswith("READY_WAIT_SECONDS=")
                            ):
                                handle.write(line + "\n")
                    except Exception as exc:
                        handle.write(f"[nicht lesbar: {exc}]\n")

                status("NetworkManager- und WPA-Logs sammeln")
                since = "-60 min"
                write_section(handle, "6. NETWORKMANAGER – LETZTE 60 MINUTEN")
                write_command(
                    handle,
                    ["journalctl", "-b", "-u", "NetworkManager", "--since", since,
                     "--no-pager", "-o", "short-precise"],
                    root=True,
                    timeout=20,
                )
                write_section(handle, "7. WPA_SUPPLICANT – LETZTE 60 MINUTEN")
                write_command(
                    handle,
                    ["journalctl", "-b", "-u", "wpa_supplicant", "--since", since,
                     "--no-pager", "-o", "short-precise"],
                    root=True,
                    timeout=20,
                )
                selfheal_lifecycle_pattern = (
                    r"systemd\[1\]: (?:Starting|Finished|Started|Stopping|Stopped) "
                    r"uwuntu-wifi-selfheal\.(?:service|timer)\b|"
                    r"systemd\[1\]: uwuntu-wifi-selfheal\.(?:service|timer): "
                    r"Deactivated successfully\."
                )
                write_section(handle, "8. SELF-HEAL – LETZTE 60 MINUTEN (BEREINIGT)")
                write_command(
                    handle,
                    ["journalctl", "-b", "-u", "uwuntu-wifi-selfheal.service",
                     "--since", since, "--no-pager", "-o", "short-precise"],
                    root=True,
                    timeout=20,
                    exclude_pattern=selfheal_lifecycle_pattern,
                )

                status("Kernel- und iwlwifi-Logs sammeln")
                wlan_pattern = (
                    r"iwlwifi|iwlmld|cfg80211|mac80211|wlp[0-9a-z]+|wlan[0-9]+|"
                    r"IEEE 802\.11|80211|rfkill|beacon|deauth|disassoc|"
                    r"microcode|firmware.*(?:iwl|wifi)|(?:iwl|wifi).*firmware"
                )
                write_section(handle, "9. KERNEL WLAN – LETZTE 60 MINUTEN")
                write_command(
                    handle,
                    ["journalctl", "-b", "-k", "--since", since,
                     "--no-pager", "-o", "short-precise"],
                    root=True,
                    timeout=20,
                    filter_pattern=wlan_pattern,
                )
                write_section(handle, "10. KOMBINIERTE WLAN-EREIGNISSE")
                write_command(
                    handle,
                    ["journalctl", "-b", "--since", since,
                     "--no-pager", "-o", "short-precise"],
                    root=True,
                    timeout=25,
                    filter_pattern=(
                        r"NetworkManager|wpa_supplicant|uwuntu-wifi-selfheal|"
                        r"iwlwifi|wlp|wlan|wifi|rfkill|dhcp|beacon|deauth|"
                        r"disassoc|disconnect|authenticat|associat|supplicant-timeout|"
                        r"CONN_FAILED"
                    ),
                    exclude_pattern=selfheal_lifecycle_pattern,
                )

                status("Routing, DNS und WLAN-Erreichbarkeit prüfen")
                write_section(handle, "11. DNS / ROUTING / ERREICHBARKEIT")
                for args in (
                    ["ip", "rule"],
                    ["ip", "route"],
                    ["resolvectl", "status"],
                ):
                    write_command(handle, args)
                if wifi_iface:
                    _, gateway_text = self._wlan_diag_run_command(
                        ["nmcli", "-g", "IP4.GATEWAY", "device", "show", wifi_iface],
                        timeout=4,
                        env=env,
                    )
                    gateway = next(
                        (line.strip() for line in gateway_text.splitlines() if line.strip()),
                        "",
                    )
                    if gateway:
                        write_command(
                            handle,
                            ["ping", "-I", wifi_iface, "-c", "3", "-W", "1", gateway],
                            timeout=6,
                        )
                    write_command(
                        handle,
                        ["ping", "-I", wifi_iface, "-c", "3", "-W", "1", "1.1.1.1"],
                        timeout=6,
                    )
                    write_command(
                        handle,
                        ["resolvectl", "query", "-i", wifi_iface, "example.com"],
                        timeout=8,
                    )

                status("Boot-Historie und Konfiguration ergänzen")
                write_section(handle, "12. BOOT / SYSTEM")
                for args in (
                    ["uptime"],
                    ["uptime", "-s"],
                    ["who", "-b"],
                    ["uname", "-a"],
                    ["journalctl", "--list-boots", "--no-pager"],
                ):
                    write_command(handle, args)
                write_command(handle, ["cat", "/etc/os-release"])

                write_section(handle, "13. VORHERIGER BOOT – WLAN-EREIGNISSE")
                write_command(
                    handle,
                    ["journalctl", "-b", "-1", "--no-pager", "-o", "short-precise"],
                    root=True,
                    timeout=25,
                    filter_pattern=(
                        r"NetworkManager|wpa_supplicant|uwuntu-wifi-selfheal|"
                        r"iwlwifi|wlp|wlan|wifi|rfkill|dhcp|beacon|deauth|"
                        r"disassoc|disconnect|authenticat|associat|CONN_FAILED"
                    ),
                    tail=1500,
                )

                write_section(handle, "14. NETWORKMANAGER KONFIGURATION")
                config_paths = [Path("/etc/NetworkManager/NetworkManager.conf")]
                config_paths.extend(sorted(Path("/etc/NetworkManager/conf.d").glob("*.conf")))
                config_paths.extend(sorted(Path("/usr/lib/NetworkManager/conf.d").glob("*.conf")))
                for path in config_paths:
                    if not path.is_file():
                        continue
                    handle.write(f"\n----- {path} -----\n")
                    _, text = self._wlan_diag_run_command(
                        ["cat", str(path)],
                        sudo_ok=sudo_ok,
                        root=True,
                        timeout=5,
                        env=env,
                    )
                    handle.write(text)
                    if text and not text.endswith("\n"):
                        handle.write("\n")

                write_section(handle, "15. IWLWIFI / FIRMWARE – AKTUELLER BOOT")
                write_command(
                    handle,
                    ["journalctl", "-b", "-k", "--no-pager", "-o", "short-precise"],
                    root=True,
                    timeout=20,
                    filter_pattern=r"iwlwifi|cfg80211|firmware.*wifi|wireless",
                )

                status("Diagnosedatei abschließen")
                write_section(handle, "16. ABSCHLUSS")
                handle.write(f"Ende: {time.strftime('%Y-%m-%d %H:%M:%S %z')}\n")
                handle.write(f"Datei: {output_path}\n")

            try:
                os.chmod(output_path, 0o600)
            except Exception:
                pass

            if self.wlan_diag_stop.is_set():
                return

            GLib.idle_add(
                self._wlan_diag_finish,
                True,
                output_path.name,
                "",
            )
        except Exception as exc:
            log(f"WLAN-Diagnose Fehler: {exc}")
            if self.wlan_diag_stop.is_set():
                return
            GLib.idle_add(
                self._wlan_diag_finish,
                False,
                output_path.name if output_path else "",
                str(exc),
            )

    def _wlan_diag_finish(self, success, filename, error_text):
        self.wlan_diag_active = False
        button = getattr(self, "wlan_diag_button", None)
        if button is not None:
            button.set_sensitive(True)

        spinner = getattr(self, "wlan_diag_spinner", None)
        if spinner is not None:
            spinner.stop()
            spinner.set_visible(False)

        title = getattr(self, "wlan_diag_title_label", None)
        live = getattr(self, "wlan_diag_live_label", None)

        if success:
            if title is not None:
                title.set_text("✅ WLAN-Diagnosebericht gespeichert:")
            self._wlan_diag_set_title_color("green")
            if live is not None:
                live.set_text(filename)
            delay = 4500
            log(f"WLAN-Diagnosebericht gespeichert: {filename}")
        else:
            if title is not None:
                title.set_text("❌ WLAN-Diagnosebericht fehlgeschlagen")
            self._wlan_diag_set_title_color("red")
            if live is not None:
                live.set_text(error_text or "Unbekannter Fehler")
            delay = 6000
            log(f"WLAN-Diagnosebericht fehlgeschlagen: {error_text}")

        if self.wlan_diag_hide_source is not None:
            try:
                GLib.source_remove(self.wlan_diag_hide_source)
            except Exception:
                pass
        self.wlan_diag_hide_source = GLib.timeout_add(
            delay,
            self._wlan_diag_hide_overlay,
        )
        return False

    def start_wlan_diagnosis(self, *_):
        if self.wlan_diag_active:
            return False

        if self.wlan_diag_hide_source is not None:
            try:
                GLib.source_remove(self.wlan_diag_hide_source)
            except Exception:
                pass
            self.wlan_diag_hide_source = None

        self.wlan_diag_active = True
        self.wlan_diag_stop.clear()
        self.wlan_diag_lines = []

        if self.wlan_diag_button is not None:
            self.wlan_diag_button.set_sensitive(False)
        if self.wlan_diag_overlay is not None:
            self.wlan_diag_overlay.set_visible(True)
        if self.wlan_diag_spinner is not None:
            self.wlan_diag_spinner.set_visible(True)
            self.wlan_diag_spinner.start()
        if self.wlan_diag_title_label is not None:
            self.wlan_diag_title_label.set_text("📋 WLAN-Diagnosebericht wird erstellt ...")
        self._wlan_diag_set_title_color("blue")
        if self.wlan_diag_live_label is not None:
            self.wlan_diag_live_label.set_text("Vorbereitung …")

        self.wlan_diag_thread = threading.Thread(
            target=self._wlan_diag_worker,
            name="uwuntu-wlan-diagnose",
            daemon=True,
        )
        self.wlan_diag_thread.start()
        log("WLAN-Diagnosebericht über F1-Menü gestartet")
        return False

    def close_hotkeys_window(self, *_):
        # Während die Diagnose läuft bleibt das F1-Fenster offen, damit der
        # Benutzer den Live-Status bis zum Abschluss sehen kann.
        if self.wlan_diag_active:
            return True

        window = self.hotkeys_window
        self.hotkeys_window = None
        self.wlan_diag_button = None
        self.wlan_diag_overlay = None
        self.wlan_diag_spinner = None
        self.wlan_diag_title_label = None
        self.wlan_diag_live_label = None

        if self.wlan_diag_hide_source is not None:
            try:
                GLib.source_remove(self.wlan_diag_hide_source)
            except Exception:
                pass
            self.wlan_diag_hide_source = None

        if window is not None:
            try:
                window.destroy()
            except Exception:
                pass
        return True

    def on_hotkeys_key(self, controller, keyval, keycode, state):
        name = Gdk.keyval_name(keyval) or ""

        if self.wlan_diag_active:
            return True

        # F1 öffnet die Übersicht ausschließlich. Solange sie bereits offen
        # ist, hat F1 bewusst keine weitere Funktion. Geschlossen wird nur
        # über ESC, STRG+W oder den normalen Fenster-Schließen-Button.
        if name == "F1":
            return True

        if name == "Escape" or (
            state & Gdk.ModifierType.CONTROL_MASK and name.lower() == "w"
        ):
            self.close_hotkeys_window()
            return True
        return False

    def show_hotkeys(self, *_):
        # Während des Tastatur-Tests bleibt F1 eine reine Prüftaste.
        if not self.stack or self.stack.get_visible_child_name() == "keyboard":
            return False

        if self.hotkeys_window is not None:
            # Bereits offen: weitere F1-Tastendrücke vollständig ignorieren.
            # Nicht erneut präsentieren, nicht toggeln und nicht schließen.
            return False

        window = Gtk.ApplicationWindow(application=self)
        window.set_title("Shortcuts / Hotkeys")
        window.set_default_size(560, 470)
        window.set_resizable(False)

        # Zuerst ohne transient-for präsentieren, damit Mutter das Fenster
        # wirklich auf dem Bildschirm zentriert. Die Vordergrundbindung folgt
        # direkt nach dem Platzieren.
        window.set_modal(False)

        window.connect("close-request", self.close_hotkeys_window)

        key_controller = Gtk.EventControllerKey.new()
        key_controller.connect("key-pressed", self.on_hotkeys_key)
        window.add_controller(key_controller)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        outer.set_margin_top(14)
        outer.set_margin_bottom(14)
        outer.set_margin_start(12)
        outer.set_margin_end(12)

        title_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)

        title = Gtk.Label(label="SHORTCUTS / HOTKEYS")
        title.set_xalign(0)
        title.set_hexpand(True)
        title.add_css_class("info-title")
        title_row.append(title)

        diag_button = Gtk.Button(label="📋 WLAN-Diagnosebericht")
        diag_button.add_css_class("wlan-diag-button")
        diag_button.set_focusable(False)
        diag_button.connect("clicked", self.start_wlan_diagnosis)
        title_row.append(diag_button)
        self.wlan_diag_button = diag_button

        outer.append(title_row)

        grid = Gtk.Grid()
        grid.set_row_spacing(8)
        grid.set_column_spacing(14)
        grid.set_hexpand(True)
        grid.set_halign(Gtk.Align.FILL)
        grid.add_css_class("hotkey-grid")

        shortcuts = [
            ("F1", "Diese Übersicht öffnen"),
            ("STRG+D", "4-Felder-Diagnose-Layout starten"),
            ("←", "Audio Test: linken Lautsprecher testen"),
            ("↑", "Audio Test: beide Lautsprecher testen"),
            ("→", "Audio Test: rechten Lautsprecher testen"),
            ("↓", "Audio Test: kompletten Auto-Test starten"),
            ("B", "GLOBAL: CPU-Kurztest im Benchmark-Fenster starten"),
            ("K", "Keyboard-Test global öffnen"),
            ("R", "GLOBAL: RAM-Kurztest im Benchmark-Fenster starten"),
            ("A", "GLOBAL: ALLE Kurztests im Benchmark-Fenster starten"),
            ("I", "Systeminformationen anzeigen"),
            ("U", "Uwuntu-Update suchen und installieren"),
            ("G", "Garantieprüfung Dell / Lenovo"),
            ("T", "Touchscreen-Test manuell öffnen"),
            ("D", "Display-Test starten"),
            ("ENTER", "Wipe Auto: LÖSCHEN / danach JA bestätigen"),
            ("STRG+W", "Aktuelles Diagnosefenster schließen"),
            ("STRG+Q", "Alle Uwuntu-Diagnosefenster schließen"),
            ("ESC", "Benchmark/RAM abbrechen · Tastatur-Test mit ESC x3 beenden"),
        ]

        for row, (key_text, desc_text) in enumerate(shortcuts):
            key = Gtk.Label(label=key_text)
            key.set_xalign(0)
            key.set_valign(Gtk.Align.START)
            key.set_size_request(88, -1)
            key.add_css_class("hotkey-key")

            desc = Gtk.Label(label=desc_text)
            desc.set_xalign(0)
            desc.set_halign(Gtk.Align.FILL)
            desc.set_hexpand(True)
            desc.set_wrap(True)
            desc.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
            desc.set_max_width_chars(38)
            desc.add_css_class("hotkey-desc")

            grid.attach(key, 0, row, 1, 1)
            grid.attach(desc, 1, row, 1, 1)

        outer.append(grid)

        note = Gtk.Label(
            label=(
                "Hinweis: Im KEYBOARD TEST sind F1, A, B, K, R, I, U, G, T, D,\n"
                "SUPER und alle Pfeiltasten normale Prüftasten. ESC zählt ebenfalls\n"
                "als Prüftaste; erst ESC x3 beendet den Tastatur-Test. SUPER allein,\n"
                "SUPER+Pfeile und ALT+SPACE lösen während des Tests keine\n"
                "GNOME-/Fensteraktion aus."
            )
        )
        note.set_xalign(0)
        note.set_halign(Gtk.Align.FILL)
        note.set_hexpand(True)
        note.set_wrap(False)
        note.set_focusable(False)
        note.add_css_class("hotkey-note")
        outer.append(note)

        overlay = Gtk.Overlay()
        overlay.set_child(outer)

        shade = Gtk.Grid()
        shade.set_hexpand(True)
        shade.set_vexpand(True)
        shade.set_halign(Gtk.Align.FILL)
        shade.set_valign(Gtk.Align.FILL)
        shade.add_css_class("wlan-diag-shade")

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.set_halign(Gtk.Align.CENTER)
        card.set_valign(Gtk.Align.CENTER)
        card.set_size_request(430, -1)
        card.add_css_class("wlan-diag-card")

        heading = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        spinner = Gtk.Spinner()
        heading.append(spinner)

        diag_title = Gtk.Label(label="📋 WLAN-Diagnosebericht wird erstellt ...")
        diag_title.set_xalign(0)
        diag_title.set_hexpand(True)
        diag_title.add_css_class("wlan-diag-title")
        diag_title.add_css_class("status-blue")
        heading.append(diag_title)
        card.append(heading)

        live = Gtk.Label(label="Vorbereitung …")
        live.set_xalign(0)
        live.set_yalign(0)
        live.set_halign(Gtk.Align.FILL)
        live.set_hexpand(True)
        live.set_wrap(True)
        live.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        live.set_size_request(390, 150)
        live.add_css_class("wlan-diag-live")
        card.append(live)

        shade.attach(card, 0, 0, 1, 1)
        shade.set_visible(False)
        overlay.add_overlay(shade)

        self.wlan_diag_overlay = shade
        self.wlan_diag_spinner = spinner
        self.wlan_diag_title_label = diag_title
        self.wlan_diag_live_label = live

        window.set_child(overlay)
        self.hotkeys_window = window
        self.present_centered(window)
        GLib.timeout_add(
            650,
            self.bind_priority_window_after_centering,
            window,
        )
        log("Shortcut-/Hotkey-Übersicht per F1 geöffnet")
        return False

    def close_update_window(self, *_):
        # Während eines laufenden Updates darf das Statusfenster zwar mit ESC
        # geschlossen werden, der Update-Prozess läuft bewusst weiter.
        window = self.update_window
        self.update_window = None
        self.update_status_label = None
        if window is not None:
            try:
                window.destroy()
            except Exception:
                pass
        return True

    def on_update_key(self, controller, keyval, keycode, state):
        name = Gdk.keyval_name(keyval) or ""
        if name == "Escape" or (
            state & Gdk.ModifierType.CONTROL_MASK and name.lower() == "w"
        ):
            self.close_update_window()
            return True
        return False

    def set_update_status(self, text):
        """Nur die Statusmeldung passend zum Update-Zustand einfärben."""
        label = self.update_status_label
        if label is None:
            return False

        label.set_text(text)

        for css_class in (
            "status-orange",
            "status-blue",
            "status-green",
            "status-red",
        ):
            label.remove_css_class(css_class)

        normalized = (text or "").strip()

        if normalized.startswith("FEHLER:"):
            color = "red"
        elif normalized.startswith("Suche") or normalized.startswith("Prüfe"):
            color = "orange"
        elif (
            normalized.startswith("Bereits aktuell")
            or normalized == "GitHub-Version ist älter · kein Update"
        ):
            color = "green"
        elif normalized.startswith("Update erfolgreich"):
            color = "green"
        elif (
            normalized.startswith("Update gefunden")
            or normalized.startswith("Installiere")
            or "wird installiert" in normalized
        ):
            color = "blue"
        else:
            # Unbekannte Zwischenmeldung neutral lassen.
            return False

        label.add_css_class("status-" + color)
        return False

    def auto_close_update_window(self):
        if self.update_proc is None and self.update_window is not None:
            self.close_update_window()
        return False

    def finish_force_update(self, returncode, last_status):
        self.update_proc = None

        if returncode == 0:
            if (
                last_status.startswith("Bereits aktuell")
                or last_status == "GitHub-Version ist älter · kein Update"
            ):
                GLib.timeout_add(2500, self.auto_close_update_window)
            return False

        if last_status.startswith("FEHLER:"):
            self.set_update_status(last_status)
        else:
            self.set_update_status("FEHLER: Update konnte nicht ausgeführt werden.")
        return False

    def force_update_worker(self, helper):
        last_status = "Suche frisch auf GitHub nach Update …"
        try:
            proc = subprocess.Popen(
                [str(helper)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                start_new_session=True,
            )
            self.update_proc = proc

            if proc.stdout is not None:
                for raw in proc.stdout:
                    line = raw.strip()
                    if not line.startswith("STATUS|"):
                        continue
                    last_status = line.split("|", 1)[1].strip()
                    GLib.idle_add(self.set_update_status, last_status)

            returncode = proc.wait()
        except Exception as exc:
            returncode = 99
            last_status = f"FEHLER: {exc}"

        GLib.idle_add(
            self.finish_force_update,
            returncode,
            last_status,
        )

    def show_force_update(self, *_):
        if not self.stack or self.stack.get_visible_child_name() == "keyboard":
            return False

        if self.update_proc is not None and self.update_proc.poll() is None:
            if self.update_window is not None:
                try:
                    self.update_window.present()
                except Exception:
                    pass
            return False

        helper = Path.home() / ".local/bin/uwuntu-force-update.sh"

        if self.update_window is not None:
            try:
                self.update_window.destroy()
            except Exception:
                pass
            self.update_window = None
            self.update_status_label = None

        window = Gtk.ApplicationWindow(application=self)
        window.set_title("Uwuntu Update")
        window.set_default_size(560, 145)
        window.set_resizable(False)
        # Wie beim Shortcut-Fenster erst mittig platzieren und die
        # Vordergrundbindung anschließend setzen.
        window.set_modal(False)
        window.connect("close-request", self.close_update_window)

        key_controller = Gtk.EventControllerKey.new()
        key_controller.connect("key-pressed", self.on_update_key)
        window.add_controller(key_controller)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        outer.set_margin_top(16)
        outer.set_margin_bottom(16)
        outer.set_margin_start(18)
        outer.set_margin_end(18)

        title = Gtk.Label(label="UWUNTU UPDATE")
        title.set_xalign(0)
        title.add_css_class("info-title")
        outer.append(title)

        status = Gtk.Label(label="Suche frisch auf GitHub nach Update …")
        status.set_xalign(0)
        status.set_wrap(True)
        status.set_focusable(False)
        status.add_css_class("update-status")
        status.add_css_class("status-orange")
        outer.append(status)

        window.set_child(outer)
        self.update_window = window
        self.update_status_label = status
        self.present_centered(window)
        GLib.timeout_add(
            650,
            self.bind_priority_window_after_centering,
            window,
        )

        if not helper.exists():
            self.set_update_status(
                "FEHLER: Update-Helfer fehlt · Hardware Check neu installieren."
            )
            return False

        log("Manuelles GitHub-Update per U gestartet")
        threading.Thread(
            target=self.force_update_worker,
            args=(helper,),
            name="uwuntu-force-update",
            daemon=True,
        ).start()
        return False

    def start_power_dialog_helper(self):
        """Genau einen persistenten, isolierten AT-SPI-Helper starten."""
        if self.power_dialog_helper_stopping:
            return False
        if (
            self.power_dialog_helper_proc is not None
            and self.power_dialog_helper_proc.poll() is None
        ):
            return False

        helper_code = r"""
import pyatspi

cancel_tokens = ("abbrechen", "cancel")
power_tokens = (
    "herunterfahren", "ausschalten", "abschalten",
    "power off", "poweroff", "shut down", "shutdown",
)


def walk(obj, depth=0):
    if depth > 7:
        return
    try:
        count = obj.childCount
    except Exception:
        count = 0
    for i in range(count):
        try:
            child = obj.getChildAtIndex(i)
        except Exception:
            continue
        yield child
        yield from walk(child, depth + 1)


last_detected = None


def detect():
    try:
        desktop = pyatspi.Registry.getDesktop(0)
        app_count = desktop.childCount
    except Exception:
        return False

    for app_index in range(app_count):
        try:
            app = desktop.getChildAtIndex(app_index)
        except Exception:
            continue

        for candidate in walk(app):
            try:
                role = (candidate.getRoleName() or "").lower()
            except Exception:
                role = ""

            if role not in ("dialog", "alert", "frame", "window"):
                continue

            names = []
            try:
                candidate_name = (candidate.name or "").strip()
                if candidate_name:
                    names.append(candidate_name.lower())
            except Exception:
                pass

            for item in walk(candidate):
                try:
                    name = (item.name or "").strip()
                except Exception:
                    name = ""
                if name:
                    names.append(name.lower())

            haystack = " | ".join(names)
            if (
                any(token in haystack for token in cancel_tokens)
                and any(token in haystack for token in power_tokens)
            ):
                return True

    return False


def publish():
    global last_detected
    detected = detect()
    if detected != last_detected:
        print(f"power-dialog {1 if detected else 0}", flush=True)
        last_detected = detected


def on_relevant_event(event):
    # object:state-changed:showing wird für sehr viele normale Widgets
    # ausgelöst. Ein kompletter Desktop-Scan für jedes einzelne dieser
    # Ereignisse kostet unnötig CPU. Nur Top-Level-Objekte können hier
    # einen Power-/Ausschalt-Dialog darstellen; window:* bleibt wie
    # bisher vollständig ereignisgesteuert erhalten.
    try:
        event_type = (getattr(event, "type", "") or "").lower()
    except Exception:
        event_type = ""

    if event_type.startswith("object:state-changed:showing"):
        try:
            role = (event.source.getRoleName() or "").lower()
        except Exception:
            role = ""
        if role not in ("dialog", "alert", "frame", "window"):
            return

    publish()


def main():
    publish()
    for event_name in (
        "window:create",
        "window:destroy",
        "window:activate",
        "window:deactivate",
        "object:state-changed:showing",
    ):
        pyatspi.Registry.registerEventListener(on_relevant_event, event_name)
    pyatspi.Registry.start()

try:
    main()
except Exception:
    raise SystemExit(1)
"""
        try:
            proc = subprocess.Popen(
                [sys.executable, "-u", "-c", helper_code],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except Exception as exc:
            log(f"Powerdialog-Helper konnte nicht starten: {exc}")
            self.schedule_power_dialog_helper_restart()
            return False

        self.power_dialog_helper_proc = proc
        self.power_dialog_helper_thread = threading.Thread(
            target=self._read_power_dialog_helper,
            args=(proc,),
            name="uwuntu-power-dialog-helper-reader",
            daemon=True,
        )
        self.power_dialog_helper_thread.start()
        log("Persistenter Powerdialog-Helper gestartet")
        return False

    def _read_power_dialog_helper(self, proc):
        """Zustandsänderungen lesen; niemals im GTK-/Hotkey-Pfad warten."""
        try:
            for line in proc.stdout:
                value = line.strip()
                if value == "power-dialog 1":
                    GLib.idle_add(self._set_power_dialog_cache, True)
                elif value == "power-dialog 0":
                    GLib.idle_add(self._set_power_dialog_cache, False)
        except Exception as exc:
            if not self.power_dialog_helper_stopping:
                log(f"Powerdialog-Helper Lesefehler: {exc}")
        finally:
            try:
                proc.wait()
            except Exception:
                pass
            GLib.idle_add(self._power_dialog_helper_exited, proc)

    def _set_power_dialog_cache(self, detected):
        self.power_dialog_cache_value = bool(detected)
        return False

    def _power_dialog_helper_exited(self, proc):
        if proc is not self.power_dialog_helper_proc:
            return False
        if proc.stdout is not None:
            try:
                proc.stdout.close()
            except Exception:
                pass
        self.power_dialog_helper_proc = None
        self.power_dialog_helper_thread = None
        # Bei Ausfall nicht unnötig blockieren; Neustart frühestens nach 2 s.
        self.power_dialog_cache_value = False
        if not self.power_dialog_helper_stopping:
            log("Powerdialog-Helper beendet; Neustart mit 2 s Backoff")
            self.schedule_power_dialog_helper_restart()
        return False

    def schedule_power_dialog_helper_restart(self):
        if self.power_dialog_helper_stopping:
            return
        if self.power_dialog_helper_restart_source is not None:
            return
        self.power_dialog_helper_restart_source = GLib.timeout_add(
            2000, self._restart_power_dialog_helper
        )

    def _restart_power_dialog_helper(self):
        self.power_dialog_helper_restart_source = None
        self.start_power_dialog_helper()
        return False

    def stop_power_dialog_helper(self):
        self.power_dialog_helper_stopping = True
        if self.power_dialog_helper_restart_source is not None:
            GLib.source_remove(self.power_dialog_helper_restart_source)
            self.power_dialog_helper_restart_source = None

        proc = self.power_dialog_helper_proc
        self.power_dialog_helper_proc = None
        if proc is None:
            return
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=1.0)
        except Exception as exc:
            log(f"Powerdialog-Helper Shutdown-Fehler: {exc}")
        finally:
            if proc.stdout is not None:
                try:
                    proc.stdout.close()
                except Exception:
                    pass

    def system_power_dialog_open(self):
        """Ausschließlich den Cache lesen – ohne Prozess, Scan oder Wartezeit."""
        return bool(self.power_dialog_cache_value)

    def activate_power_dialog_guard(self):
        """Audio-Pfeile kurz bis zur asynchronen AT-SPI-Erkennung sperren."""
        self.power_dialog_guard_until = time.monotonic() + 2.5

    def power_dialog_guard_active(self):
        """Den lokalen Power-Tasten-Schutz ohne Timer oder Polling abfragen."""
        return time.monotonic() < self.power_dialog_guard_until

    def run_benchmark_shortcut(self, action_name):
        """B/R/A in der separaten Benchmark-Instanz genau einmal ausführen."""
        if not BENCHMARK_WINDOW_MODE or self.stack is None:
            return False

        specs = {
            "cpu": ("cpu-short", 10.0, "B", "CPU"),
            "ram": ("ram-short", 10.0, "R", "RAM"),
            "all": ("all-short", 30.0, "A", "ALLE"),
        }
        spec = specs.get(action_name)
        if spec is None:
            return False

        now = time.monotonic()
        if now - self.last_benchmark_shortcut_at.get(action_name, 0.0) < 0.15:
            return False
        self.last_benchmark_shortcut_at[action_name] = now

        kind, duration, key_name, label = spec
        self.start_test(None, kind, duration)
        log(f"Benchmark global {key_name}: {label} Kurztest gestartet")
        return False

    def on_benchmark_app_action(self, _action, _parameter, action_name):
        return self.run_benchmark_shortcut(action_name)

    def send_benchmark_action(self, action):
        action_name = {
            "benchmark": "cpu",
            "ram": "ram",
            "all": "all",
        }.get(action)
        if not action_name:
            return False

        gapplication = shutil.which("gapplication")
        if not gapplication:
            log("Benchmark-Hotkey ignoriert: gapplication fehlt")
            return False

        try:
            subprocess.Popen(
                [
                    gapplication,
                    "action",
                    BENCHMARK_ACTION_APP_ID,
                    action_name,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            log(f"Globaler Benchmark-Hotkey weitergereicht: {action_name}")
        except Exception as exc:
            log(f"Benchmark-Hotkey Fehler ({action_name}): {exc}")
        return False

    def send_audio_action(self, action):
        action_name = {
            "audio-left": "left",
            "audio-both": "both",
            "audio-right": "right",
            "audio-auto": "auto",
        }.get(action)
        if not action_name:
            return False

        gapplication = shutil.which("gapplication")
        if not gapplication:
            log("Audio-Hotkey ignoriert: gapplication fehlt")
            return False

        try:
            subprocess.Popen(
                [
                    gapplication,
                    "action",
                    AUDIO_ACTION_APP_ID,
                    action_name,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            log(f"Audio-Hotkey weitergereicht: {action_name}")
        except Exception as exc:
            log(f"Audio-Hotkey Fehler ({action_name}): {exc}")
        return False

    def handle_global_hotkey(self, action):


        visible = self.stack.get_visible_child_name()

        # Rohe Tastendrücke werden im Tastatur-Test immer verarbeitet,
        # unabhängig davon, welches Desktop-Fenster gerade den Fokus hat.
        if action.startswith("keycode:"):
            try:
                _, key_state, raw_code = action.split(":", 2)
                code = int(raw_code)
            except (TypeError, ValueError):
                return False

            # Linux KEY_POWER, KEY_SLEEP und KEY_SUSPEND nur beobachten. Der
            # /dev/input-Listener bleibt read-only; der kurze Timestamp-Guard
            # schließt lediglich die Lücke bis zum AT-SPI-Dialogereignis.
            if key_state == "down" and code in {116, 142, 205}:
                self.activate_power_dialog_guard()

            if visible == "keyboard":
                if key_state not in ("down", "up"):
                    return False

                return self.handle_keyboard_linux_keycode(code, key_state)
            return False

        # Im Tastatur-Test sind die normalen Diagnose-Hotkeys gesperrt.
        # Die Tasten selbst wurden bereits über keycode:<n> als Prüftasten
        # verarbeitet. So lösen B/K/U/F1/Pfeile dort keine Aktionen aus.
        if visible == "keyboard":
            return False

        if self.display_test_active:
            return False

        # Wenn Hardware Check selbst den Fokus hat, kommt dieselbe Taste
        # sowohl über GTK als auch über /dev/input. Sehr kurze Duplikate
        # zusammenfassen, damit EIN B nicht gleichzeitig öffnet UND startet.
        now = time.monotonic()
        if now - self.last_global_hotkey_at.get(action, 0.0) < 0.05:
            return False
        self.last_global_hotkey_at[action] = now

        if action.startswith("audio-"):
            if visible == "keyboard":
                log("Audio-Hotkey blockiert: Keyboard-Test aktiv")
                return False

            # Solange der GNOME-Power-/Ausschalt-Dialog offen ist, gehören die
            # Pfeiltasten ausschließlich diesem Systemdialog. Die Erkennung
            # stammt aus einem asynchron gepflegten Cache und verzögert den
            # Audiotastendruck selbst nicht mehr.
            if (
                self.system_power_dialog_open()
                or self.power_dialog_guard_active()
            ):
                log(
                    "Audio-Hotkey blockiert: "
                    "GNOME Power-/Ausschalt-Dialog ist geöffnet oder wird geöffnet"
                )
                return False

            self.send_audio_action(action)
            return False

        if action == "escape":
            if visible == "benchmarks":
                if self.test_proc is not None and self.test_proc.poll() is None:
                    self.cancel_test()
                self.show_overview()
                log("Globaler Hotkey ESC: Benchmark/RAM abgebrochen bzw. Übersicht geöffnet")
                return False

            return False

        if action == "info":
            self.show_system_info()
            return False

        if action == "update":
            self.show_force_update()
            return False

        if action == "warranty":
            self.open_warranty_support()
            return False

        if action == "hotkeys":
            self.show_hotkeys()
            return False

        if action == "touch":
            self.start_touch_test()
            return False

        if action == "display":
            self.start_display_test()
            return False

        if action in {"benchmark", "ram", "all"}:
            benchmark_action = {
                "benchmark": "cpu",
                "ram": "ram",
                "all": "all",
            }[action]
            if BENCHMARK_WINDOW_MODE:
                return self.run_benchmark_shortcut(benchmark_action)
            self.send_benchmark_action(action)
            return False

        if action == "keyboard":
            self.show_keyboard()
            log("Globaler Hotkey K: Tastatur-Test geöffnet")
            return False

        return False

    def reset_all(self, *_):
        self.restore_super_after_keyboard_test()
        self.restore_desktop_shortcuts_after_keyboard_test()
        self.restore_alt_space_after_keyboard_test()
        self.restore_super_arrows_after_keyboard_test()

        # Persistente Testergebnisse vollständig entfernen.
        for path in (
            self.camera_state_file,
            self.audio_state_file,
            self.touch_state_file,
            self.display_state_file,
        ):
            try:
                path.unlink(missing_ok=True)
            except Exception as exc:
                log(f"REFRESH: Statusdatei nicht löschbar {path}: {exc}")

        # Camera und Audio laufen im Kiosk dauerhaft und setzen darüber
        # zusätzlich ihre eigenen internen Testergebnisse zurück.
        self.write_hardware_refresh_request()

        # Benchmark ebenfalls wieder auf Anfang.
        self.reset_benchmark_ui()

        # Live-Hardware neu einlesen.
        self.refresh_security()

        self.hdmi_ever_connected = False
        self.refresh_hdmi_status()

        self.reset_touchpad_test()
        self.start_touchpad_click_monitors()

        self.touch_status_cache = None
        self.refresh_touch_status()

        self.display_test_active = False
        self.display_proc = None
        self.display_launch_grace_until = 0.0
        self.refresh_display_status()

        self.refresh_media_status()

        # Ports werden neu erkannt; aktuell belegte Ports bleiben korrekt Blau.
        self.reset_usb()
        self.reset_keyboard()

        # Sensoren sind Live-Telemetrie und werden nur neu eingelesen.
        self.cpu_usage_prev = read_cpu_times()
        self.fan_sensor_key = None
        self.refresh_sensors()

        self.stack.set_visible_child_name("overview")
        self.window.set_default_size(860, 360)

        log(
            "REFRESH: Media/Touch/Display/HDMI/USB/Keyboard/"
            "Benchmark zurückgesetzt; Live-Hardware neu gelesen"
        )

    def build_usb_slots(self):
        discovery = self.usb_discovery
        groups_by_key = {
            group["raw_key"]: group
            for group in discovery["groups"]
        }
        raw_slots = {}

        for raw_key, local_idx in discovery.get("a_map", {}).items():
            slot = raw_slots.setdefault(
                ("USB-A", int(local_idx)),
                {
                    "type": "USB-A",
                    "groups": set(),
                    "local_idx": int(local_idx),
                },
            )
            slot["groups"].add(raw_key)
        for raw_key, local_idx in discovery.get("c_map", {}).items():
            slot = raw_slots.setdefault(
                ("USB-C", int(local_idx)),
                {
                    "type": "USB-C",
                    "groups": set(),
                    "local_idx": int(local_idx),
                },
            )
            slot["groups"].add(raw_key)

        mapped = {
            raw_key
            for slot in raw_slots.values()
            for raw_key in slot["groups"]
        }

        expected = int(discovery.get("physical_total") or 0)
        missing = max(0, expected - len(raw_slots))
        if missing:
            unmapped = [
                group
                for group in discovery["groups"]
                if group["raw_key"] not in mapped
            ]
            unmapped.sort(key=lambda g: (group_min_port(g), g["raw_key"]))

            for idx, group in enumerate(unmapped[:missing]):
                raw_slots[("USB", idx)] = {
                    "type": "USB",
                    "groups": {group["raw_key"]},
                }
        slots = []
        for slot in raw_slots.values():
            groups = [
                groups_by_key[key]
                for key in slot["groups"]
                if key in groups_by_key
            ]
            slot["sort"] = min(
                (group_min_port(group) for group in groups),
                default=999,
            )
            slots.append(slot)
        if discovery.get("classification") == "dell-5450-left-cluster":
            # Physische Reihenfolge am Latitude 5450:
            # USB-C 1, USB-A 2, USB-A 3, USB-C 4.
            dell_order = {
                ("USB-C", 0): 0,
                ("USB-A", 0): 1,
                ("USB-A", 1): 2,
                ("USB-C", 1): 3,
            }
            slots.sort(
                key=lambda slot: dell_order.get(
                    (slot.get("type"), slot.get("local_idx")),
                    99,
                )
            )
        else:
            slots.sort(
                key=lambda slot: (
                    slot["sort"],
                    0 if slot["type"] == "USB-C" else 1,
                    slot["type"],
                )
            )

        self.usb_slots = slots
        self.usb_group_to_slot = {}
        for slot_idx, slot in enumerate(self.usb_slots):
            for raw_key in slot["groups"]:
                self.usb_group_to_slot[raw_key] = slot_idx

        # Beim 5450 sind die High-Speed-Pfade eindeutig. Nur die drei
        # zusätzlichen USB2-Pfade der linken Portgruppe bleiben dynamisch.
        self.usb_c_a_shadow_slots = {}
        self.usb_dynamic_group_slots = {}
        self.usb_dynamic_group_seen_at = {}
        self.usb_recent_c_hotplug_slot = None
        self.usb_recent_c_hotplug_at = 0.0
    def usb_slot_for_device(self, device_name):
        if not device_name or not self.usb_discovery:
            return None

        for group in self.usb_discovery["groups"]:
            if not group_contains_device(group, device_name):
                continue

            raw_key = group["raw_key"]
            slot_idx = self.usb_group_to_slot.get(raw_key)
            if slot_idx is not None:
                return slot_idx

            dynamic_idx = self.usb_dynamic_group_slots.get(raw_key)
            if dynamic_idx is not None:
                return dynamic_idx

        return None

    def usb_typec_slot_for_name(self, typec_name):
        """UCSI-Portname auf den sichtbaren USB-C-Slot abbilden."""
        if not self.usb_discovery:
            return None

        typec_idx = next(
            (
                idx
                for idx, port in enumerate(
                    self.usb_discovery.get("typec", [])
                )
                if port.get("name") == typec_name
            ),
            None,
        )
        if typec_idx is None:
            return None

        for slot_idx, slot in enumerate(self.usb_slots):
            if slot.get("type") != "USB-C":
                continue
            if slot.get("local_idx") == typec_idx:
                return slot_idx

        return None

    def usb_left_a_slot(self):
        """Beim Latitude 5450 den USB-A-Slot der linken Dreiergruppe finden."""
        if (
            not self.usb_discovery
            or self.usb_discovery.get("classification")
            != "dell-5450-left-cluster"
        ):
            return None

        for slot_idx, slot in enumerate(self.usb_slots):
            if (
                slot.get("type") == "USB-A"
                and slot.get("local_idx") == 1
            ):
                return slot_idx
        return None

    def usb_assign_dynamic_group(self, raw_key, slot_idx, reason):
        if raw_key not in set(
            self.usb_discovery.get("dynamic_usb2") or []
        ):
            return False
        if slot_idx is None or not (0 <= slot_idx < len(self.usb_slots)):
            return False

        previous = self.usb_dynamic_group_slots.get(raw_key)
        self.usb_dynamic_group_slots[raw_key] = slot_idx
        self.usb_dynamic_group_seen_at[raw_key] = time.monotonic()

        if previous != slot_idx:
            log(
                f"USB2 dynamisch: {raw_key} -> "
                f"{self.usb_slots[slot_idx]['type']} Port {slot_idx + 1} "
                f"({reason})"
            )
            return True
        return False

    def usb_initialize_dynamic_groups(
        self,
        group_states,
        typec_partner_present,
    ):
        """Bereits beim Start belegte dynamische USB2-Pfade zuordnen."""
        if (
            not self.usb_discovery
            or self.usb_discovery.get("classification")
            != "dell-5450-left-cluster"
        ):
            return

        dynamic_keys = set(self.usb_discovery.get("dynamic_usb2") or [])
        present_keys = [
            key for key in dynamic_keys
            if group_states.get(key, False)
        ]
        if not present_keys:
            return

        # Bootstick auf einem USB2-Pfad: UCSI entscheidet C, andernfalls A.
        boot_key = None
        if self.usb_boot_device:
            for group in self.usb_discovery.get("groups", []):
                if group["raw_key"] not in dynamic_keys:
                    continue
                if group_contains_device(group, self.usb_boot_device):
                    boot_key = group["raw_key"]
                    break

        active_typec = [
            name
            for name, present in typec_partner_present.items()
            if present
        ]

        if boot_key is not None and len(active_typec) == 1:
            c_slot = self.usb_typec_slot_for_name(active_typec[0])
            if c_slot is not None:
                self.usb_assign_dynamic_group(
                    boot_key,
                    c_slot,
                    "Boot + UCSI",
                )

        left_a = self.usb_left_a_slot()
        for raw_key in present_keys:
            if raw_key in self.usb_dynamic_group_slots:
                continue
            if left_a is not None:
                self.usb_assign_dynamic_group(
                    raw_key,
                    left_a,
                    "Start ohne eindeutiges UCSI-Hotplug",
                )
    def usb_group_states(self):
        if not self.usb_discovery:
            return {}
        return {
            group["raw_key"]: group_present(group)
            for group in self.usb_discovery["groups"]
        }

    def usb_active_c_slots(self, group_states, typec_partner_present=None):
        """Aktuell aktive USB-C-Slots aus Root-Pfaden und UCSI ableiten."""
        active = set()
        shadow_c_slots = set(self.usb_c_a_shadow_slots)

        # Nicht mehrdeutige C-Pfade dürfen weiterhin über ihren Root-Present-
        # Zustand erkannt werden. Bei bekannten C/A-Shadow-Pfaden ist genau
        # dieses Signal dagegen unbrauchbar, weil auch der echte USB-A-Port
        # denselben Pfad aktiviert.
        for raw_key, present in group_states.items():
            if not present:
                continue
            slot_idx = self.usb_group_to_slot.get(raw_key)
            if slot_idx is None:
                continue
            if not (0 <= slot_idx < len(self.usb_slots)):
                continue
            if self.usb_slots[slot_idx].get("type") != "USB-C":
                continue
            if slot_idx in shadow_c_slots:
                continue
            active.add(slot_idx)

        # Für den mehrdeutigen Dell-Pfad ist UCSI die entscheidende Quelle.
        if typec_partner_present:
            discovery = self.usb_discovery or {}
            c_map = discovery.get("c_map", {})
            for typec_idx, port in enumerate(discovery.get("typec", [])):
                if not typec_partner_present.get(port["name"], False):
                    continue

                for slot_idx, slot in enumerate(self.usb_slots):
                    if slot.get("type") != "USB-C":
                        continue
                    if any(
                        c_map.get(key) == typec_idx
                        for key in slot.get("groups", set())
                    ):
                        active.add(slot_idx)
                        break

        return active

    def usb_effective_slot_for_group(self, raw_key, active_c_slots):
        """Statischen oder dynamisch gelernten Port-Slot bestimmen."""
        slot_idx = self.usb_group_to_slot.get(raw_key)
        if slot_idx is None:
            slot_idx = self.usb_dynamic_group_slots.get(raw_key)
        if slot_idx is None:
            return None

        shadow_a_slot = self.usb_c_a_shadow_slots.get(slot_idx)
        if (
            shadow_a_slot is not None
            and slot_idx not in set(active_c_slots or ())
        ):
            return shadow_a_slot

        return slot_idx

    def usb_a_companion_suppressed(self, raw_key, active_c_slots):
        c_slot_idx = self.usb_a_c_companions.get(raw_key)
        return (
            c_slot_idx is not None
            and c_slot_idx in active_c_slots
        )

    def sync_usb_connected(
        self,
        group_states,
        mark_tested=True,
        active_c_slots=None,
    ):
        connected = set()
        active_c_slots = set(active_c_slots or ())

        for raw_key, present in group_states.items():
            if not present:
                continue
            slot_idx = self.usb_effective_slot_for_group(
                raw_key,
                active_c_slots,
            )
            if slot_idx is None:
                continue

            if self.usb_a_companion_suppressed(
                raw_key,
                active_c_slots,
            ):
                continue

            connected.add(slot_idx)
            if mark_tested:
                self.usb_tested.add(slot_idx)

        self.usb_connected = connected

    def rebuild_usb(self):
        child = self.usb_box.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            self.usb_box.remove(child)
            child = nxt
        for idx, slot in enumerate(self.usb_slots):
            connected = idx in self.usb_connected
            tested = idx in self.usb_tested

            if connected:
                css_class = "status-blue"
                state_text = "BELEGT"
            elif tested:
                css_class = "status-green"
                state_text = "GETESTET"
            else:
                css_class = "status-orange"
                state_text = "NICHT GETESTET"

            # Port mit Uwuntu-Bootstick unabhängig vom normalen Zustand Blau.
            if idx == self.usb_boot_slot:
                css_class = "status-blue"

            # Einheitliche zweispaltige Darstellung:
            # links  USB-A Port 1
            # rechts NICHT GETESTET / BELEGT / GETESTET
            label = f"{slot['type']} Port {idx + 1}"
            if idx == self.usb_boot_slot:
                label += " (Uwuntu Stick)"

            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
            row.add_css_class("usb-row")

            dot = Gtk.Label(label="●")
            dot.add_css_class(css_class)

            name = Gtk.Label(label=label)
            name.set_xalign(0)
            name.set_hexpand(True)
            name.add_css_class("usb-port-name")
            name.add_css_class(css_class)

            state = Gtk.Label(label=state_text)
            state.set_xalign(1)
            state.add_css_class(css_class)
            state.add_css_class("usb-port-state")

            row.append(dot)
            row.append(name)
            row.append(state)
            self.usb_box.append(row)
        # Backup: nur neue/geänderte Geräte, die keiner bekannten
        # physischen Buchse sicher zugeordnet werden konnten.
        for dev_name in sorted(self.usb_fallback, key=natural_key):
            info = self.usb_fallback[dev_name]
            connected = bool(info.get("connected"))

            css_class = "status-blue" if connected else "status-green"
            state_text = "BELEGT" if connected else "GETESTET"
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
            row.add_css_class("usb-row")

            dot = Gtk.Label(label="●")
            dot.add_css_class(css_class)

            title = info.get("title") or "USB-Gerät"

            name = Gtk.Label(label=f"Backup {title} ({dev_name})")
            name.set_xalign(0)
            name.set_hexpand(True)
            name.set_ellipsize(3)
            name.add_css_class("usb-port-name")
            name.add_css_class(css_class)

            state = Gtk.Label(label=state_text)
            state.set_xalign(1)
            state.add_css_class(css_class)
            state.add_css_class("usb-port-state")

            row.append(dot)
            row.append(name)
            row.append(state)
            self.usb_box.append(row)
        if not self.usb_slots and not self.usb_fallback:
            empty = Gtk.Label(label="Keine USB-Ports erkannt")
            empty.set_xalign(0)
            empty.add_css_class("muted")
            self.usb_box.append(empty)

    def usb_rediscover(self, reset=False):
        self.usb_discovery = discover_physical_ports()
        self.build_usb_slots()

        if reset:
            self.usb_tested.clear()
            self.usb_connected.clear()
            self.usb_fallback.clear()
        self.usb_boot_device = boot_usb_device_name()
        self.usb_boot_slot = self.usb_slot_for_device(self.usb_boot_device)

        group_states = self.usb_group_states()
        self.usb_last_group_present = dict(group_states)
        self.usb_last_typec_partner_present = {
            port["name"]: bool(port["partner"].exists())
            for port in self.usb_discovery.get("typec", [])
        }
        self.usb_initialize_dynamic_groups(
            group_states,
            self.usb_last_typec_partner_present,
        )
        self.sync_usb_connected(group_states, mark_tested=True)
        self.usb_last_devices = usb_device_snapshot()
        discovery = self.usb_discovery
        log(
            "USB Topologie: "
            f"mode={discovery['mode']} | "
            f"classification={discovery['classification']} | "
            f"logische_Pfade={discovery['raw_group_count']} | "
            f"physische_Ports={discovery['physical_total']} | "
            f"USB-A={discovery['usb_a_count']} | "
            f"USB-C={discovery['usb_c_count']} | "
            f"Reserve-A={len(discovery.get('a_reserve') or [])} | "
            f"Quirk={discovery.get('layout_quirk') or '-'}"
        )
        for idx, slot in enumerate(self.usb_slots):
            log(
                f"{slot['type']} Port {idx + 1}: "
                f"groups={' || '.join(sorted(slot['groups']))}"
            )
        if self.usb_boot_device:
            if self.usb_boot_slot is not None:
                log(
                    f"Uwuntu Stick: {self.usb_slots[self.usb_boot_slot]['type']} Port {self.usb_boot_slot + 1} "
                    f"({self.usb_boot_device})"
                )
            else:
                log(
                    f"Uwuntu Stick ohne sichere Port-Zuordnung: "
                    f"{self.usb_boot_device}"
                )

        self.rebuild_usb()
    def attach_usb_c_reserve(self, raw_key, typec_idx, group_states):
        """Einen bestätigten Reservepfad einer vorhandenen USB-C-Buchse zuordnen."""
        discovery = self.usb_discovery or {}
        reserve = list(discovery.get("a_reserve") or [])
        if raw_key not in reserve:
            return None

        c_slots = []
        for slot_idx, slot in enumerate(self.usb_slots):
            if slot.get("type") != "USB-C":
                continue

            local_indices = {
                discovery.get("c_map", {}).get(key)
                for key in slot.get("groups", set())
                if key in discovery.get("c_map", {})
            }
            slot_connected = any(
                bool(group_states.get(key, False))
                for key in slot.get("groups", set())
            )
            c_slots.append((
                1 if slot_connected else 0,
                0 if typec_idx in local_indices else 1,
                slot_idx,
                next(iter(local_indices), None),
            ))

        if not c_slots:
            log(f"USB-C Reserve ohne vorhandenen C-Slot: {raw_key}")
            return None

        _connected_penalty, _index_penalty, slot_idx, local_idx = min(c_slots)
        if local_idx is None:
            local_idx = typec_idx

        slot = self.usb_slots[slot_idx]
        slot["groups"].add(raw_key)
        self.usb_group_to_slot[raw_key] = slot_idx
        discovery["c_map"][raw_key] = local_idx
        discovery["a_reserve"] = [
            key for key in reserve
            if key != raw_key
        ]

        log(
            f"USB-C Reserve bestätigt: {raw_key} ergänzt "
            f"USB-C Slot {slot_idx + 1}"
        )
        return slot_idx

    def attach_active_a_companion_to_c(self, raw_key, c_slot_idx):
        """A-Pfad als temporären Begleitpfad eines USB-C-Ports merken.

        Wichtig: Der Pfad bleibt Eigentum seines USB-A-Slots. Nur solange
        der zugehörige USB-C-Port aktiv ist, wird sein A-Status unterdrückt.
        So funktioniert derselbe Root-Pfad beim späteren echten USB-A-Hotplug
        wieder als USB-A.
        """
        a_slot_idx = self.usb_group_to_slot.get(raw_key)
        if a_slot_idx is None or a_slot_idx == c_slot_idx:
            return False
        if not (0 <= a_slot_idx < len(self.usb_slots)):
            return False
        if not (0 <= c_slot_idx < len(self.usb_slots)):
            return False

        a_slot = self.usb_slots[a_slot_idx]
        c_slot = self.usb_slots[c_slot_idx]
        if a_slot.get("type") != "USB-A" or c_slot.get("type") != "USB-C":
            return False
        if raw_key not in a_slot.get("groups", set()):
            return False

        previous = self.usb_a_c_companions.get(raw_key)
        self.usb_a_c_companions[raw_key] = c_slot_idx

        # Der gleichzeitig aufgegangene A-Pfad ist in diesem Moment kein
        # getesteter A-Port, sondern nur der Begleitpfad des C-Steckvorgangs.
        self.usb_connected.discard(a_slot_idx)
        self.usb_tested.discard(a_slot_idx)

        if previous != c_slot_idx:
            log(
                f"USB-C Companion gelernt: {raw_key} bleibt USB-A Slot "
                f"{a_slot_idx + 1}, wird bei aktivem USB-C Slot "
                f"{c_slot_idx + 1} nur unterdrückt"
            )
            return True

        return False

    def promote_usb_a_reserve(self, raw_key, group_states, current_devices):
        """Einen beim Hotplug bestätigten Reservepfad als echten USB-A übernehmen."""
        discovery = self.usb_discovery or {}
        reserve = list(discovery.get("a_reserve") or [])
        if raw_key not in reserve:
            return None

        candidates = []
        for slot_idx, slot in enumerate(self.usb_slots):
            if slot.get("type") != "USB-A":
                continue

            slot_connected = False
            for key in slot.get("groups", set()):
                group = next(
                    (
                        item
                        for item in self.usb_discovery.get("groups", [])
                        if item["raw_key"] == key
                    ),
                    None,
                )
                if not group:
                    continue

                for dev_name in current_devices:
                    if not group_contains_device(group, dev_name):
                        continue
                    if dev_name == self.usb_boot_device:
                        slot_connected = True
                        break
                    if not usb_fallback_ignore_reason(dev_name):
                        slot_connected = True
                        break

                if slot_connected:
                    break

            if slot_connected:
                continue

            candidates.append((
                1 if slot_idx == self.usb_boot_slot else 0,
                1 if slot_idx in self.usb_tested else 0,
                slot_idx,
            ))

        if not candidates:
            log(
                f"USB-A Reserve aktiv, aber kein freier Slot ersetzbar: {raw_key}"
            )
            return None

        _boot_penalty, _tested_penalty, slot_idx = min(candidates)
        slot = self.usb_slots[slot_idx]
        old_groups = set(slot.get("groups", set()))

        local_idx = None
        for old_key in old_groups:
            if old_key in discovery.get("a_map", {}):
                local_idx = discovery["a_map"].pop(old_key)
                break

        if local_idx is None:
            local_idx = slot.get("local_idx")

        if local_idx is None:
            log(f"USB-A Reserve konnte keinem lokalen A-Slot zugeordnet werden: {raw_key}")
            return None

        for old_key in old_groups:
            self.usb_group_to_slot.pop(old_key, None)
            if old_key not in reserve:
                reserve.append(old_key)

        reserve = [key for key in reserve if key != raw_key]
        discovery["a_reserve"] = reserve
        discovery["a_map"][raw_key] = local_idx

        slot["groups"] = {raw_key}
        self.usb_group_to_slot[raw_key] = slot_idx

        # Der Slot repräsentiert ab jetzt eine andere physische Buchse.
        self.usb_tested.discard(slot_idx)
        self.usb_connected.discard(slot_idx)

        log(
            f"USB-A Reserve bestätigt: {raw_key} ersetzt "
            f"{' || '.join(sorted(old_groups))} in USB-A Slot {slot_idx + 1}"
        )
        return slot_idx

    def poll_usb(self):
        if self.window is None or not self.usb_discovery:
            return False

        current_groups = self.usb_group_states()
        current_devices = usb_device_snapshot()
        previous_names = set(self.usb_last_devices)
        current_names = set(current_devices)
        new_device_names = current_names - previous_names
        current_typec_partner_present = {
            port["name"]: bool(port["partner"].exists())
            for port in self.usb_discovery.get("typec", [])
        }
        previous_typec_partner_present = getattr(
            self,
            "usb_last_typec_partner_present",
            {},
        )
        newly_active_typec = [
            port["name"]
            for port in self.usb_discovery.get("typec", [])
            if current_typec_partner_present.get(port["name"], False)
            and not previous_typec_partner_present.get(port["name"], False)
        ]
        old_connected = set(self.usb_connected)
        changed = False

        # Beim 5450 sind 3-1 / 3-2 / 3-4 keine eigenen physischen
        # Buchsen. USB-C-Hubs können zusätzlich zum SuperSpeed-Gerät einen
        # separaten USB2-Hub (z.B. GenesysLogic) etwas später enumerieren.
        # Deshalb wird ein neuer C-Hotplug als kurze "Sitzung" gemerkt.
        if (
            self.usb_discovery.get("classification")
            == "dell-5450-left-cluster"
        ):
            dynamic_keys = set(
                self.usb_discovery.get("dynamic_usb2") or []
            )
            now_mono = time.monotonic()

            newly_present_dynamic = [
                key
                for key in dynamic_keys
                if current_groups.get(key, False)
                and not self.usb_last_group_present.get(key, False)
            ]

            newly_gone_dynamic = [
                key
                for key in dynamic_keys
                if not current_groups.get(key, False)
                and self.usb_last_group_present.get(key, False)
            ]

            # Eindeutigen C-Hotplug schon hier bestimmen, damit ein im selben
            # oder folgenden Poll erscheinender USB2-Hub sofort zu C gehört.
            c_event_slot = None

            # 1) UCSI ist die stärkste Quelle.
            if len(newly_active_typec) == 1:
                c_event_slot = self.usb_typec_slot_for_name(
                    newly_active_typec[0]
                )

            # 2) Neues Gerät direkt unter einem fest gemappten C-SuperSpeed-Pfad.
            if c_event_slot is None:
                for dev_name in sorted(new_device_names, key=natural_key):
                    candidate_idx = self.usb_slot_for_device(dev_name)
                    if candidate_idx is None:
                        continue
                    if not (0 <= candidate_idx < len(self.usb_slots)):
                        continue
                    if self.usb_slots[candidate_idx].get("type") != "USB-C":
                        continue
                    c_event_slot = candidate_idx
                    break

            # 3) Ein statischer C-Root-Pfad wurde gerade present.
            if c_event_slot is None:
                c_candidates = set()
                for raw_key, present in current_groups.items():
                    if not present:
                        continue
                    if self.usb_last_group_present.get(raw_key, False):
                        continue
                    candidate_idx = self.usb_group_to_slot.get(raw_key)
                    if candidate_idx is None:
                        continue
                    if not (0 <= candidate_idx < len(self.usb_slots)):
                        continue
                    if self.usb_slots[candidate_idx].get("type") == "USB-C":
                        c_candidates.add(candidate_idx)

                if len(c_candidates) == 1:
                    c_event_slot = next(iter(c_candidates))

            if c_event_slot is not None:
                self.usb_recent_c_hotplug_slot = c_event_slot
                self.usb_recent_c_hotplug_at = now_mono
                log(
                    f"USB-C Hotplug-Sitzung: "
                    f"USB-C Port {c_event_slot + 1}"
                )

            active_c_now = self.usb_active_c_slots(
                current_groups,
                current_typec_partner_present,
            )

            recent_c_slot = self.usb_recent_c_hotplug_slot
            recent_c_valid = (
                recent_c_slot is not None
                and recent_c_slot in active_c_now
                and now_mono - self.usb_recent_c_hotplug_at <= 5.0
            )

            if not recent_c_valid:
                self.usb_recent_c_hotplug_slot = None
                self.usb_recent_c_hotplug_at = 0.0
                recent_c_slot = None

            left_a_slot = self.usb_left_a_slot()

            for raw_key in newly_present_dynamic:
                self.usb_dynamic_group_seen_at.setdefault(
                    raw_key,
                    now_mono,
                )

            # Ein USB2-Pfad, der innerhalb derselben C-Hotplug-Sitzung
            # erscheint, ist die USB2-Seite desselben USB-C-Geräts/Hubs.
            if recent_c_slot is not None:
                for raw_key in dynamic_keys:
                    if not current_groups.get(raw_key, False):
                        continue
                    first_seen = self.usb_dynamic_group_seen_at.get(raw_key)
                    if first_seen is None:
                        continue
                    if now_mono - first_seen > 5.0:
                        continue
                    if self.usb_dynamic_group_slots.get(raw_key) == recent_c_slot:
                        continue

                    if self.usb_assign_dynamic_group(
                        raw_key,
                        recent_c_slot,
                        "USB-C-Hotplug-Sitzung",
                    ):
                        changed = True

            # Nur ohne aktive C-Hotplug-Sitzung darf ein neuer dynamischer
            # USB2-Pfad nach kurzer Karenz als linker USB-A gelten.
            if recent_c_slot is None:
                for raw_key in dynamic_keys:
                    if not current_groups.get(raw_key, False):
                        continue
                    if raw_key in self.usb_dynamic_group_slots:
                        continue

                    first_seen = self.usb_dynamic_group_seen_at.get(raw_key)
                    if first_seen is None:
                        continue
                    if now_mono - first_seen < 1.0:
                        continue

                    if self.usb_assign_dynamic_group(
                        raw_key,
                        left_a_slot,
                        "1s ohne C-Hotplug-Sitzung",
                    ):
                        changed = True

            for raw_key in newly_gone_dynamic:
                self.usb_dynamic_group_seen_at.pop(raw_key, None)

        groups_by_key = {
            group["raw_key"]: group
            for group in self.usb_discovery["groups"]
        }

        # Bereits vor der Hotplug-Klassifizierung bestimmen, welche C-Slots
        # durch ein echtes Type-C-Signal bestätigt sind. Das verhindert, dass
        # der Dell-Shadow-Pfad beim Einstecken in USB-A Port 3 als C1 gilt.
        active_c_slots = self.usb_active_c_slots(
            current_groups,
            current_typec_partner_present,
        )

        # Einen USB-C-Hotplug nicht ausschließlich über UCSI erkennen.
        # Auf dem Latitude 5450 meldet die Firmware den Type-C-Partner nicht
        # auf jedem Steckvorgang rechtzeitig. Deshalb wird zusätzlich geprüft,
        # ob genau ein bereits als USB-C klassifizierter Root-Pfad in diesem
        # Poll neu aktiv geworden ist.
        newly_present_c_slots = set()
        for raw_key, present in current_groups.items():
            if not present:
                continue
            if self.usb_last_group_present.get(raw_key, False):
                continue

            candidate_idx = self.usb_group_to_slot.get(raw_key)
            if candidate_idx is None:
                continue
            if not (0 <= candidate_idx < len(self.usb_slots)):
                continue
            if self.usb_slots[candidate_idx].get("type") == "USB-C":
                if (
                    candidate_idx in self.usb_c_a_shadow_slots
                    and candidate_idx not in active_c_slots
                ):
                    continue
                newly_present_c_slots.add(candidate_idx)

        hotplug_c_slot_idx = None

        # Höchste Sicherheit: ein wirklich neu erschienenes Gerät hängt
        # bereits unter einem bekannten USB-C-Slot.
        for dev_name in sorted(new_device_names, key=natural_key):
            candidate_idx = self.usb_slot_for_device(dev_name)
            if candidate_idx is None:
                continue
            if not (0 <= candidate_idx < len(self.usb_slots)):
                continue
            if self.usb_slots[candidate_idx].get("type") != "USB-C":
                continue
            if (
                candidate_idx in self.usb_c_a_shadow_slots
                and candidate_idx not in active_c_slots
            ):
                continue
            hotplug_c_slot_idx = candidate_idx
            break

        # Zweite Quelle: genau ein C-Slot ist im selben Poll neu present.
        if hotplug_c_slot_idx is None and len(newly_present_c_slots) == 1:
            hotplug_c_slot_idx = next(iter(newly_present_c_slots))

        # Letzter Fallback: UCSI-Partner wurde neu aktiv. Den dazugehörigen
        # lokalen C-Index gegen die bestehende c_map auflösen.
        if hotplug_c_slot_idx is None and len(newly_active_typec) == 1:
            typec_name = newly_active_typec[0]
            typec_idx = next(
                (
                    idx
                    for idx, port in enumerate(
                        self.usb_discovery.get("typec", [])
                    )
                    if port["name"] == typec_name
                ),
                None,
            )
            if typec_idx is not None:
                for candidate_idx, slot in enumerate(self.usb_slots):
                    if slot.get("type") != "USB-C":
                        continue
                    if any(
                        self.usb_discovery.get("c_map", {}).get(key)
                        == typec_idx
                        for key in slot.get("groups", set())
                    ):
                        hotplug_c_slot_idx = candidate_idx
                        break

        # Ein echter Geräte-Hotplug ist aussagekräftiger als der reine
        # Present-Zustand des Root-Ports. Ein Root-Port kann bei Hubs/USB4
        # dauerhaft present bleiben, während erst ein Child-Gerät neu erscheint.
        for raw_key in list(self.usb_discovery.get("a_reserve") or []):
            group = groups_by_key.get(raw_key)
            if not group:
                continue

            external_hotplug = False
            for dev_name in new_device_names:
                if not group_contains_device(group, dev_name):
                    continue
                if dev_name != self.usb_boot_device:
                    if usb_fallback_ignore_reason(dev_name):
                        continue
                external_hotplug = True
                break

            if not external_hotplug:
                continue

            slot_idx = None
            if hotplug_c_slot_idx is not None:
                c_slot = self.usb_slots[hotplug_c_slot_idx]
                c_local_idx = c_slot.get("local_idx")
                if c_local_idx is None:
                    for c_key in c_slot.get("groups", set()):
                        if c_key in self.usb_discovery.get("c_map", {}):
                            c_local_idx = self.usb_discovery["c_map"][c_key]
                            break
                if c_local_idx is not None:
                    slot_idx = self.attach_usb_c_reserve(
                        raw_key,
                        int(c_local_idx),
                        current_groups,
                    )

            if (
                slot_idx is None
                and hotplug_c_slot_idx is None
                and not newly_active_typec
            ):
                slot_idx = self.promote_usb_a_reserve(
                    raw_key,
                    current_groups,
                    current_devices,
                )

            if slot_idx is not None:
                self.usb_tested.add(slot_idx)
                changed = True


        # Dell/USB4-Sonderfall: derselbe physische USB-C-Hotplug kann
        # zusätzlich einen Root-Pfad aktivieren, den die Firmware beim Start
        # wie einen USB-A-Port aussehen lässt. Entscheidend ist deshalb nicht
        # mehr nur UCSI, sondern das gemeinsame Hotplug-Ereignis.
        #
        # Ein A-Pfad wird nur dann umgehängt, wenn im selben Poll ein C-Slot
        # eindeutig als neu aktiv erkannt wurde UND der A-Pfad ebenfalls neu
        # aktiv wurde oder tatsächlich ein neu erschienenes externes Gerät
        # unter diesem Pfad hängt.
        if (
            self.usb_discovery.get("layout_quirk")
            and self.usb_discovery.get("classification")
            != "dell-5450-left-cluster"
            and hotplug_c_slot_idx is not None
        ):
            companion_keys = []

            for a_slot_idx, a_slot in enumerate(self.usb_slots):
                if a_slot_idx == hotplug_c_slot_idx:
                    continue
                if a_slot.get("type") != "USB-A":
                    continue

                for a_key in list(a_slot.get("groups", set())):
                    group = groups_by_key.get(a_key)
                    if not group:
                        continue

                    became_present = (
                        bool(current_groups.get(a_key, False))
                        and not self.usb_last_group_present.get(
                            a_key,
                            False,
                        )
                    )

                    has_new_external_device = False
                    for dev_name in new_device_names:
                        if not group_contains_device(group, dev_name):
                            continue
                        if (
                            dev_name != self.usb_boot_device
                            and usb_fallback_ignore_reason(dev_name)
                        ):
                            continue
                        has_new_external_device = True
                        break

                    if became_present or has_new_external_device:
                        companion_keys.append(a_key)

            for a_key in companion_keys:
                if self.attach_active_a_companion_to_c(
                    a_key,
                    hotplug_c_slot_idx,
                ):
                    changed = True

        active_c_slots = self.usb_active_c_slots(
            current_groups,
            current_typec_partner_present,
        )

        for raw_key, present in current_groups.items():
            before = self.usb_last_group_present.get(raw_key, False)
            slot_idx = self.usb_effective_slot_for_group(
                raw_key,
                active_c_slots,
            )

            if present == before:
                continue

            suppressed_a_companion = self.usb_a_companion_suppressed(
                raw_key,
                active_c_slots,
            )

            if present:
                if slot_idx is not None and not suppressed_a_companion:
                    self.usb_tested.add(slot_idx)
                    log(f"USB-Port {slot_idx + 1} verbunden")
                elif suppressed_a_companion:
                    log(
                        f"USB-A Begleitpfad unterdrückt: {raw_key} | "
                        f"USB-C Slot "
                        f"{self.usb_a_c_companions.get(raw_key, -1) + 1}"
                    )
                else:
                    log(f"Nicht zugeordneter USB-Pfad verbunden: {raw_key}")
            else:
                if slot_idx is not None:
                    log(f"USB-Port {slot_idx + 1}: Pfad entfernt")
            changed = True

        self.sync_usb_connected(
            current_groups,
            mark_tested=True,
            active_c_slots=active_c_slots,
        )
        if self.usb_connected != old_connected:
            changed = True
        self.usb_last_group_present = dict(current_groups)

        if (
            self.usb_discovery.get("classification")
            == "dell-5450-left-cluster"
        ):
            for raw_key in list(self.usb_dynamic_group_slots):
                if not current_groups.get(raw_key, False):
                    self.usb_dynamic_group_slots.pop(raw_key, None)
                    self.usb_dynamic_group_seen_at.pop(raw_key, None)

        # Falls ein Hub zuerst als Backup auftauchte und der dynamische
        # Companion-Pfad erst danach dem C-Port zugeordnet wurde, Backup
        # sofort wieder entfernen.
        for dev_name in list(self.usb_fallback):
            if self.usb_slot_for_device(dev_name) is None:
                continue
            self.usb_fallback.pop(dev_name, None)
            log(
                f"USB Backup nach Port-Zuordnung entfernt: {dev_name}"
            )
            changed = True

        for dev_name in sorted(new_device_names, key=natural_key):
            if self.usb_slot_for_device(dev_name) is not None:
                continue

            # Der Uwuntu-Bootstick darf auch bei ungewöhnlicher Firmware-
            # Kennzeichnung niemals durch den internen Gerätefilter fallen.
            if dev_name != self.usb_boot_device:
                ignore_reason = usb_fallback_ignore_reason(dev_name)
                if ignore_reason:
                    self.usb_fallback.pop(dev_name, None)
                    log(
                        f"USB Backup ignoriert: {dev_name} | "
                        f"{current_devices[dev_name]} | {ignore_reason}"
                    )
                    continue

            info = self.usb_fallback.setdefault(dev_name, {})
            info["title"] = current_devices[dev_name]
            info["connected"] = True
            log(
                f"USB Backup neu erkannt: {dev_name} | "
                f"{current_devices[dev_name]}"
            )
            changed = True

        for dev_name in sorted(previous_names - current_names, key=natural_key):
            if dev_name not in self.usb_fallback:
                continue

            self.usb_fallback[dev_name]["connected"] = False
            log(f"USB Backup entfernt: {dev_name}")
            changed = True

        for dev_name in current_names:
            if dev_name not in self.usb_fallback:
                continue

            if dev_name != self.usb_boot_device:
                ignore_reason = usb_fallback_ignore_reason(dev_name)
                if ignore_reason:
                    title = current_devices.get(dev_name, "USB-Gerät")
                    self.usb_fallback.pop(dev_name, None)
                    log(
                        f"USB Backup nachträglich entfernt: {dev_name} | "
                        f"{title} | {ignore_reason}"
                    )
                    changed = True
                    continue

            if not self.usb_fallback[dev_name].get("connected"):
                changed = True
            self.usb_fallback[dev_name]["connected"] = True
            self.usb_fallback[dev_name]["title"] = current_devices[dev_name]

        self.usb_last_devices = current_devices
        self.usb_last_typec_partner_present = current_typec_partner_present

        if changed:
            self.rebuild_usb()

        return True

    def reset_usb(self, *_):
        log("USB REFRESH / Neu-Erkennung")
        self.usb_rediscover(reset=True)


    def build_benchmarks(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.append(
            self.header(
                "BENCHMARKS",
                back=not BENCHMARK_WINDOW_MODE,
                back_label="← ÜBERSICHT (ESC)",
                compact_back=True,
            )
        )

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        body.set_margin_start(10)
        body.set_margin_end(10)
        body.set_margin_bottom(8)
        body.set_vexpand(True)
        chooser = Gtk.Grid()
        chooser.set_row_spacing(6)
        chooser.set_column_spacing(6)
        chooser.set_column_homogeneous(True)
        chooser.set_hexpand(True)

        specs = [
            ("CPU (B)", "cpu-short", 10.0),
            ("CPU ERW.", "cpu-long", 600.0),
            ("RAM (R)", "ram-short", 10.0),
            ("RAM ERW.", "ram-long", 600.0),
            ("GPU", "gpu-short", 10.0),
            ("GPU ERW.", "gpu-long", 600.0),
            ("ALLE (A)", "all-short", 30.0),
            ("ALLE ERW.", "all-long", 1800.0),
        ]

        self.benchmark_buttons = []
        self.benchmark_button_by_kind = {}
        for index, (label, kind, duration) in enumerate(specs):
            b = Gtk.Button(label=label)
            b.add_css_class("benchmark-choice")
            b.set_hexpand(True)
            child = b.get_child()
            if isinstance(child, Gtk.Label):
                child.set_ellipsize(Pango.EllipsizeMode.END)
                child.set_single_line_mode(True)
            b.connect("clicked", self.start_test, kind, duration)
            self.benchmark_buttons.append(b)
            self.benchmark_button_by_kind[kind] = b
            chooser.attach(b, index % 4, index // 4, 1, 1)

        body.append(chooser)

        # Status, Laufzeit und ABBRECHEN sitzen gemeinsam direkt unter den
        # Testbuttons. Dadurch bleibt unten mehr Platz für die Ergebniszeile
        # und die jeweilige Telemetrie-Grafik.
        status_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )

        self.benchmark_status = Gtk.Label(label="Bereit")
        self.benchmark_status.set_xalign(0)
        self.benchmark_status.set_hexpand(True)
        self.benchmark_status.set_ellipsize(Pango.EllipsizeMode.END)
        self.benchmark_status.set_single_line_mode(True)
        self.benchmark_status.add_css_class("benchmark-status")
        status_row.append(self.benchmark_status)

        self.benchmark_time = Gtk.Label(label="00:00 / 00:00")
        self.benchmark_time.set_xalign(1)
        self.benchmark_time.add_css_class("muted")
        status_row.append(self.benchmark_time)

        self.cancel_test_button = Gtk.Button(label="ABBRECHEN")
        self.cancel_test_button.add_css_class("benchmark-compact")
        self.cancel_test_button.set_sensitive(False)
        self.cancel_test_button.connect("clicked", self.cancel_test)
        status_row.append(self.cancel_test_button)

        body.append(status_row)

        self.benchmark_progress = Gtk.ProgressBar()
        self.benchmark_progress.set_fraction(0.0)
        self.benchmark_progress.set_show_text(False)
        body.append(self.benchmark_progress)

        self.cpu_activity = Gtk.DrawingArea()
        self.cpu_activity.set_content_height(150)
        self.cpu_activity.set_hexpand(True)
        self.cpu_activity.set_vexpand(True)
        self.cpu_activity.set_draw_func(self.draw_cpu_activity)
        self.cpu_activity.update_property(
            [Gtk.AccessibleProperty.LABEL],
            ["Visuelle Aktivitätsanzeige des CPU-Benchmarks"],
        )
        self.cpu_activity.set_visible(False)
        self.cpu_visual_state = "idle"
        self.cpu_activity_progress = 0.0
        self.cpu_visual_temp = None
        self.cpu_visual_fan_rpm = None
        self.cpu_visual_clock_mhz = None
        self.cpu_thread_values = [0.0] * max(1, min(24, os.cpu_count() or 1))
        body.append(self.cpu_activity)

        self.ram_activity = Gtk.DrawingArea()
        self.ram_activity.set_content_height(112)
        self.ram_activity.set_hexpand(True)
        self.ram_activity.set_vexpand(True)
        self.ram_activity.set_draw_func(self.draw_ram_activity)
        self.ram_activity.update_property(
            [Gtk.AccessibleProperty.LABEL],
            ["Visuelle Aktivitätsanzeige des RAM-Tests"],
        )
        self.ram_activity.set_visible(False)
        self.ram_visual_state = "idle"
        self.ram_activity_values = [0.0] * (40 * 8)
        self.ram_activity_targets = [0.0] * (40 * 8)
        self.ram_activity_hotspots = []
        self.ram_activity_green_thresholds = [1.0] * (40 * 8)
        self.ram_activity_progress = 0.0
        body.append(self.ram_activity)

        self.gpu_activity = Gtk.DrawingArea()
        self.gpu_activity.set_content_height(150)
        self.gpu_activity.set_hexpand(True)
        self.gpu_activity.set_vexpand(True)
        self.gpu_activity.set_draw_func(self.draw_gpu_activity)
        self.gpu_activity.update_property(
            [Gtk.AccessibleProperty.LABEL],
            ["Visuelle Aktivitätsanzeige des GPU-Benchmarks"],
        )
        self.gpu_activity.set_visible(False)
        self.gpu_visual_state = "idle"
        self.gpu_activity_progress = 0.0
        self.gpu_visual_load = None
        self.gpu_visual_temp = None
        self.gpu_visual_temp_source = None
        self.gpu_visual_clock_mhz = None
        self.gpu_visual_fps = None
        self.gpu_peak_temp = None
        self.gpu_peak_load = None
        self.gpu_renderer = None
        self.gpu_usage_prev_snapshot = None
        self.gpu_usage_prev_ts_ns = None
        self.gpu_frame_values = [0.0] * 24
        body.append(self.gpu_activity)

        self.benchmark_result = Gtk.Label(label="")
        self.benchmark_result.set_xalign(0)
        self.benchmark_result.set_hexpand(True)
        self.benchmark_result.set_wrap(False)
        self.benchmark_result.set_ellipsize(Pango.EllipsizeMode.END)
        self.benchmark_result.set_single_line_mode(True)
        self.benchmark_result.add_css_class("benchmark-result")
        body.append(self.benchmark_result)

        root.append(body)
        return root

    def set_benchmark_result_class(self, color):
        for cls in ("status-green", "status-orange", "status-red"):
            self.benchmark_result.remove_css_class(cls)
        if color:
            self.benchmark_result.add_css_class("status-" + color)

    def set_benchmark_result_text(self, text, color=None):
        """
        Ergebnistext setzen und Erfolgs-/Fehlerfarbe zusätzlich über Pango
        erzwingen. So bleibt die Farbe unabhängig von GTK-Theme-Prioritäten.
        """
        palette = {
            "green": "#61d36b",
            "orange": "#f5a623",
            "red": "#ff4c4c",
        }
        self.set_benchmark_result_class(color)
        if color in palette:
            escaped = GLib.markup_escape_text(str(text))
            self.benchmark_result.set_markup(
                f'<span foreground="{palette[color]}">{escaped}</span>'
            )
        else:
            self.benchmark_result.set_text(str(text))

    def draw_ram_activity(self, area, cr, width, height):
        """Zeichnet die organische RAM-Aktivität mit Uwuntu-Farbpalette."""
        columns = 40
        rows = 8
        gap = 3.0
        padding = 8.0
        tile_width = max(2.0, (width - 2 * padding - gap * (columns - 1)) / columns)
        tile_height = max(2.0, (height - 2 * padding - gap * (rows - 1)) / rows)
        total = columns * rows

        background = (0x17 / 255.0, 0x17 / 255.0, 0x1C / 255.0)
        base = (0x23 / 255.0, 0x23 / 255.0, 0x29 / 255.0)
        blue = (0x5A / 255.0, 0xA2 / 255.0, 0xFF / 255.0)
        green = (0x61 / 255.0, 0xD3 / 255.0, 0x6B / 255.0)
        orange = (0xF5 / 255.0, 0xA6 / 255.0, 0x23 / 255.0)
        red = (0xFF / 255.0, 0x4C / 255.0, 0x4C / 255.0)

        cr.set_source_rgb(*background)
        cr.rectangle(0, 0, width, height)
        cr.fill()

        progress = max(0.0, min(1.0, self.ram_activity_progress))

        for index in range(total):
            row, column = divmod(index, columns)
            x = padding + column * (tile_width + gap)
            y = padding + row * (tile_height + gap)

            intensity = self.ram_activity_values[index]
            if self.ram_visual_state == "error":
                color = red
            elif self.ram_visual_state == "cancelled":
                color = orange
            elif self.ram_visual_state == "complete":
                color = green
            else:
                glow = min(1.0, intensity * 1.35)
                accent = max(0.0, min(1.0, (intensity - 0.62) / 0.38))
                active = tuple(
                    base[channel] * (1.0 - glow) + blue[channel] * glow
                    for channel in range(3)
                )
                active = tuple(
                    active[channel] * (1.0 - accent) + green[channel] * accent
                    for channel in range(3)
                )

                threshold = self.ram_activity_green_thresholds[index]
                green_mix = max(0.0, min(1.0, (progress - threshold) / 0.05))
                green_mix = green_mix * green_mix * (3.0 - 2.0 * green_mix)
                color = tuple(
                    active[channel] * (1.0 - green_mix)
                    + green[channel] * green_mix
                    for channel in range(3)
                )

            cr.set_source_rgb(*color)
            cr.rectangle(x, y, tile_width, tile_height)
            cr.fill()

    def _cpu_visual_color(self, temp_c):
        if self.cpu_visual_state == "complete":
            return (0x61 / 255.0, 0xD3 / 255.0, 0x6B / 255.0)
        if self.cpu_visual_state == "error":
            return (0xFF / 255.0, 0x4C / 255.0, 0x4C / 255.0)
        if self.cpu_visual_state == "cancelled":
            return (0xF5 / 255.0, 0xA6 / 255.0, 0x23 / 255.0)
        if temp_c is None:
            return (0x5A / 255.0, 0xA2 / 255.0, 0xFF / 255.0)
        if temp_c >= 95.0:
            return (0xFF / 255.0, 0x4C / 255.0, 0x4C / 255.0)
        if temp_c >= 88.0:
            return (0xF5 / 255.0, 0xA6 / 255.0, 0x23 / 255.0)
        if temp_c >= 72.0:
            return (0x61 / 255.0, 0xD3 / 255.0, 0x6B / 255.0)
        return (0x5A / 255.0, 0xA2 / 255.0, 0xFF / 255.0)

    @staticmethod
    def benchmark_growing_bar_value(raw_value, progress):
        """Lebendige Balken, deren Grundhöhe zugleich den Fortschritt zeigt."""
        raw = max(0.0, min(1.0, float(raw_value)))
        p = max(0.0, min(1.0, float(progress)))

        # Kurz vor Schluss sind alle Balken bewusst vollständig gefüllt.
        if p >= 0.95:
            return 1.0

        # Smoothstep: am Anfang sehr flach, in der Mitte klar wachsend und
        # gegen Ende schnell nahe 100 %. Das bisherige Springen bleibt als
        # kleine Abweichung um diese Fortschritts-Grundhöhe erhalten.
        eased = p * p * (3.0 - 2.0 * p)
        base = 0.04 + 0.92 * eased
        jitter_span = 0.20 - 0.10 * p
        jitter = (raw - 0.5) * jitter_span

        return max(0.025, min(0.985, base + jitter))

    def draw_cpu_activity(self, area, cr, width, height):
        """Technische CPU-Telemetrie mit responsiver Kernmatrix."""
        background = (0x17 / 255.0, 0x17 / 255.0, 0x1C / 255.0)
        panel = (0x23 / 255.0, 0x23 / 255.0, 0x29 / 255.0)
        track = (0x34 / 255.0, 0x34 / 255.0, 0x3C / 255.0)
        text = (0xF4 / 255.0, 0xF4 / 255.0, 0xF5 / 255.0)
        muted = (0x9D / 255.0, 0x9D / 255.0, 0xA7 / 255.0)
        green = (0x61 / 255.0, 0xD3 / 255.0, 0x6B / 255.0)
        blue = (0x5A / 255.0, 0xA2 / 255.0, 0xFF / 255.0)
        orange = (0xF5 / 255.0, 0xA6 / 255.0, 0x23 / 255.0)
        red = (0xFF / 255.0, 0x4C / 255.0, 0x4C / 255.0)

        cr.set_source_rgb(*background)
        cr.rectangle(0, 0, width, height)
        cr.fill()

        # Dezentes technisches Raster. Es skaliert mit der Zeichenfläche und
        # bleibt bewusst im Hintergrund, damit die Werte gut lesbar bleiben.
        cr.set_line_width(1.0)
        cr.set_source_rgba(track[0], track[1], track[2], 0.28)
        grid_step = 24.0
        x = grid_step
        while x < width:
            cr.move_to(x, 0)
            cr.line_to(x, height)
            x += grid_step
        y = grid_step
        while y < height:
            cr.move_to(0, y)
            cr.line_to(width, y)
            y += grid_step
        cr.stroke()

        progress = max(0.0, min(1.0, self.cpu_activity_progress))
        cores = os.cpu_count() or 1
        temp_c = self.cpu_visual_temp
        fan_rpm = self.cpu_visual_fan_rpm
        clock_mhz = self.cpu_visual_clock_mhz
        accent = self._cpu_visual_color(temp_c)
        running = self.cpu_visual_state == "running"
        complete = self.cpu_visual_state == "complete"

        padding = 8.0
        gap = 6.0

        # Die vier Kennwerte wechseln bei schmaler Fläche automatisch auf 2x2.
        metric_columns = 4 if width >= 650 else 2
        metric_rows = int(math.ceil(4 / metric_columns))
        metric_h = 46.0
        metric_w = max(
            72.0,
            (width - 2 * padding - gap * (metric_columns - 1))
            / metric_columns,
        )
        if clock_mhz is None:
            clock_text = "-- GHz"
        elif clock_mhz >= 1000.0:
            clock_text = f"{clock_mhz / 1000.0:.2f} GHz"
        else:
            clock_text = f"{clock_mhz:.0f} MHz"

        metrics = (
            ("THREADS", str(cores)),
            ("TEMP", "-- °C" if temp_c is None else f"{temp_c:.0f} °C"),
            ("FAN", "-- RPM" if fan_rpm is None else f"{int(round(fan_rpm))} RPM"),
            ("CPU TAKT", clock_text),
        )

        for index, (label, value) in enumerate(metrics):
            row = index // metric_columns
            col = index % metric_columns
            x = padding + col * (metric_w + gap)
            y = padding + row * (metric_h + gap)

            cr.set_source_rgb(*panel)
            cr.rectangle(x, y, metric_w, metric_h)
            cr.fill()

            if complete:
                color = green
            elif index == 1:
                color = accent
            else:
                color = blue

            # Kleine obere Telemetrie-Markierung und untere Statuskante.
            cr.set_source_rgba(color[0], color[1], color[2], 0.65)
            cr.rectangle(x + 8.0, y + 7.0, 18.0, 2.0)
            cr.fill()
            cr.set_source_rgb(*color)
            cr.rectangle(x, y + metric_h - 3.0, metric_w, 3.0)
            cr.fill()

            cr.set_source_rgb(*muted)
            cr.set_font_size(9.0)
            cr.move_to(x + 8.0, y + 18.0)
            cr.show_text(label)

            cr.set_source_rgb(*(color if index == 1 or complete else text))
            cr.set_font_size(16.0)
            cr.move_to(x + 8.0, y + 37.0)
            cr.show_text(value)

        metric_bottom = (
            padding
            + metric_rows * metric_h
            + max(0, metric_rows - 1) * gap
        )

        values = list(self.cpu_thread_values) or [0.0]
        shown = min(24, len(values))

        # Kopfzeile der Lastmatrix mit wanderndem LIVE-Scan.
        matrix_title_y = metric_bottom + 17.0
        cr.set_source_rgb(*muted)
        cr.set_font_size(9.0)
        cr.move_to(padding, matrix_title_y)
        cr.show_text("CORE LOAD MATRIX")

        state_text = {
            "complete": "COMPLETE",
            "error": "ERROR",
            "cancelled": "STOPPED",
        }.get(self.cpu_visual_state, "LIVE")
        state_color = green if complete else accent if not running else blue
        label_width = max(34.0, len(state_text) * 6.0)
        cr.set_source_rgb(*state_color)
        cr.arc(
            max(padding + 4.0, width - padding - label_width - 9.0),
            matrix_title_y - 3.0,
            3.0,
            0,
            math.tau,
        )
        cr.fill()
        cr.set_font_size(9.0)
        cr.move_to(width - padding - label_width, matrix_title_y)
        cr.show_text(state_text)

        activity_top = matrix_title_y + 8.0
        bottom_rail_h = 12.0
        available_h = max(
            34.0,
            height - activity_top - padding - bottom_rail_h,
        )

        min_bar_w = 22.0
        columns = max(
            4,
            min(
                shown,
                int(
                    max(1.0, width - 2 * padding + gap)
                    / (min_bar_w + gap)
                ),
            ),
        )
        rows = int(math.ceil(shown / max(1, columns)))
        row_h = available_h / max(1, rows)
        bar_gap = gap
        bar_w = max(
            8.0,
            (width - 2 * padding - bar_gap * max(0, columns - 1))
            / max(1, columns),
        )

        scan_index = -1
        if running and shown > 0:
            scan_index = int(time.monotonic() * 5.0) % shown

        for index in range(shown):
            row = index // columns
            col = index % columns
            x = padding + col * (bar_w + bar_gap)
            y = activity_top + row * row_h
            bar_h = max(18.0, row_h - 15.0)
            raw_value = max(0.0, min(1.0, values[index]))
            value = (
                self.benchmark_growing_bar_value(raw_value, progress)
                if running
                else max(0.06, raw_value)
            )
            if running and progress < 0.95:
                # CPU bewusst lebendiger als GPU: Fortschritt bleibt die
                # Grundhöhe, die Kerne dürfen aber sichtbar auf/ab springen.
                extra_span = 0.28 - 0.10 * progress
                value += (raw_value - 0.5) * extra_span
                value = max(0.025, min(0.985, value))

            # Äußerer Slot-Rahmen.
            cr.set_source_rgb(*panel)
            cr.rectangle(x, y, bar_w, bar_h)
            cr.fill()
            cr.set_line_width(1.0)
            if index == scan_index:
                scan_color = accent if temp_c is not None else blue
                cr.set_source_rgba(
                    scan_color[0],
                    scan_color[1],
                    scan_color[2],
                    0.85,
                )
            else:
                cr.set_source_rgba(track[0], track[1], track[2], 0.90)
            cr.rectangle(x + 0.5, y + 0.5, max(1.0, bar_w - 1.0), max(1.0, bar_h - 1.0))
            cr.stroke()

            if complete:
                active_color = green
                value = 1.0
            elif self.cpu_visual_state in ("error", "cancelled"):
                active_color = accent
            else:
                active_color = blue

            # Segmentierte Kernlast statt eines simplen Vollbalkens.
            segment_gap = 2.0
            segment_count = max(4, min(9, int(bar_h / 11.0)))
            segment_h = max(
                3.0,
                (bar_h - 8.0 - segment_gap * (segment_count - 1))
                / segment_count,
            )
            active_segments = int(math.ceil(value * segment_count))
            for segment in range(segment_count):
                seg_y = (
                    y
                    + bar_h
                    - 4.0
                    - (segment + 1) * segment_h
                    - segment * segment_gap
                )
                if segment < active_segments:
                    seg_color = active_color
                    if not complete:
                        # Hohe Balken bekommen wieder die frühere heiße Spitze:
                        # obere Segmente orange, die letzte Spitze bei sehr
                        # hohem Füllstand rot. Temperaturwarnungen haben Vorrang.
                        if (
                            temp_c is not None
                            and temp_c >= 95.0
                            and segment >= segment_count - 2
                        ):
                            seg_color = red
                        elif (
                            temp_c is not None
                            and temp_c >= 88.0
                            and segment >= segment_count - 2
                        ):
                            seg_color = orange
                        elif (
                            value >= 0.70
                            and segment >= segment_count - 2
                        ):
                            # Hohe Auslastung bleibt nur orange. Rot ist
                            # ausschließlich für echte Übertemperatur reserviert.
                            seg_color = orange
                    alpha = 1.0 if segment < active_segments - 1 else 0.78
                    cr.set_source_rgba(
                        seg_color[0],
                        seg_color[1],
                        seg_color[2],
                        alpha,
                    )
                else:
                    cr.set_source_rgba(track[0], track[1], track[2], 0.55)
                cr.rectangle(
                    x + 4.0,
                    seg_y,
                    max(2.0, bar_w - 8.0),
                    segment_h,
                )
                cr.fill()

            if bar_w >= 18.0 and row_h >= 36.0:
                cr.set_source_rgb(*muted)
                cr.set_font_size(8.0)
                cr.move_to(x + 2.0, y + bar_h + 10.0)
                cr.show_text(f"{index + 1:02d}")

        # Untere Telemetrie-Schiene: segmentierter Fortschritt und Temperaturfarbe.
        rail_y = height - padding - 5.0
        rail_segments = max(12, min(48, int(width / 22.0)))
        rail_gap = 2.0
        rail_w = (
            width - 2 * padding - rail_gap * (rail_segments - 1)
        ) / rail_segments
        filled = int(math.ceil(progress * rail_segments))
        rail_color = green if complete else accent
        for segment in range(rail_segments):
            x = padding + segment * (rail_w + rail_gap)
            if segment < filled:
                cr.set_source_rgba(
                    rail_color[0],
                    rail_color[1],
                    rail_color[2],
                    0.95,
                )
            else:
                cr.set_source_rgba(track[0], track[1], track[2], 0.55)
            cr.rectangle(x, rail_y, max(1.0, rail_w), 3.0)
            cr.fill()

    def reset_cpu_activity_field(self):
        count = max(1, min(24, os.cpu_count() or 1))
        self.cpu_thread_values = [
            random.uniform(0.05, 0.95)
            for _ in range(count)
        ]
        self.cpu_activity_progress = 0.0
        self.cpu_visual_temp = None
        self.cpu_visual_fan_rpm = None
        self.cpu_visual_clock_mhz = None

    def step_cpu_activity_field(self):
        if not self.cpu_thread_values:
            self.reset_cpu_activity_field()
        for index, current in enumerate(self.cpu_thread_values):
            target = random.uniform(0.08, 1.0)
            blend = 0.58 if target > current else 0.46
            self.cpu_thread_values[index] += (target - current) * blend

    def update_cpu_activity(
        self,
        state=None,
        temp_c=None,
        fan_rpm=None,
        clock_mhz=None,
        progress=None,
    ):
        if not hasattr(self, "cpu_activity"):
            return
        is_cpu = bool(self.test_kind and self.test_kind.startswith("cpu"))
        self.cpu_activity.set_visible(is_cpu)

        if state is not None:
            self.cpu_visual_state = state
            if is_cpu and state == "running":
                self.reset_cpu_activity_field()
            elif state == "complete":
                self.cpu_thread_values = [1.0] * max(
                    1, min(24, os.cpu_count() or 1)
                )
                self.cpu_activity_progress = 1.0

        if temp_c is not None:
            self.cpu_visual_temp = temp_c
        if fan_rpm is not None:
            self.cpu_visual_fan_rpm = fan_rpm
        if clock_mhz is not None:
            self.cpu_visual_clock_mhz = clock_mhz
        if progress is not None:
            self.cpu_activity_progress = max(0.0, min(1.0, progress))

        if is_cpu and self.cpu_visual_state == "running":
            self.step_cpu_activity_field()
        if is_cpu:
            self.cpu_activity.queue_draw()

    def _gpu_visual_color(self, temp_c):
        if self.gpu_visual_state == "complete":
            return (0x61 / 255.0, 0xD3 / 255.0, 0x6B / 255.0)
        if self.gpu_visual_state == "error":
            return (0xFF / 255.0, 0x4C / 255.0, 0x4C / 255.0)
        if self.gpu_visual_state == "cancelled":
            return (0xF5 / 255.0, 0xA6 / 255.0, 0x23 / 255.0)
        if temp_c is not None and temp_c >= 95.0:
            return (0xFF / 255.0, 0x4C / 255.0, 0x4C / 255.0)
        if temp_c is not None and temp_c >= 85.0:
            return (0xF5 / 255.0, 0xA6 / 255.0, 0x23 / 255.0)
        return (0x5A / 255.0, 0xA2 / 255.0, 0xFF / 255.0)

    def draw_gpu_activity(self, area, cr, width, height):
        """GPU-Telemetrie mit Render-Pipeline und Frame-Historie."""
        background = (0x17 / 255.0, 0x17 / 255.0, 0x1C / 255.0)
        panel = (0x23 / 255.0, 0x23 / 255.0, 0x29 / 255.0)
        track = (0x34 / 255.0, 0x34 / 255.0, 0x3C / 255.0)
        text = (0xF4 / 255.0, 0xF4 / 255.0, 0xF5 / 255.0)
        muted = (0x9D / 255.0, 0x9D / 255.0, 0xA7 / 255.0)
        green = (0x61 / 255.0, 0xD3 / 255.0, 0x6B / 255.0)
        blue = (0x5A / 255.0, 0xA2 / 255.0, 0xFF / 255.0)

        cr.set_source_rgb(*background)
        cr.rectangle(0, 0, width, height)
        cr.fill()

        cr.set_source_rgba(track[0], track[1], track[2], 0.28)
        cr.set_line_width(1.0)
        step = 24.0
        pos = step
        while pos < width:
            cr.move_to(pos, 0)
            cr.line_to(pos, height)
            pos += step
        pos = step
        while pos < height:
            cr.move_to(0, pos)
            cr.line_to(width, pos)
            pos += step
        cr.stroke()

        temp_c = self.gpu_visual_temp
        accent = self._gpu_visual_color(temp_c)
        load = self.gpu_visual_load
        clock_mhz = self.gpu_visual_clock_mhz
        fps = self.gpu_visual_fps
        complete = self.gpu_visual_state == "complete"
        running = self.gpu_visual_state == "running"

        if clock_mhz is None:
            clock_text = "-- MHz"
        elif clock_mhz >= 1000.0:
            clock_text = f"{clock_mhz / 1000.0:.2f} GHz"
        else:
            clock_text = f"{clock_mhz:.0f} MHz"

        temp_label = (
            "PKG TEMP"
            if self.gpu_visual_temp_source == "package"
            else "TEMP"
        )
        metrics = (
            ("GPU LOAD", "-- %" if load is None else f"{load:.0f} %"),
            (temp_label, "-- °C" if temp_c is None else f"{temp_c:.0f} °C"),
            ("GPU TAKT", clock_text),
            ("FPS", "--" if fps is None else f"{fps:.0f}"),
        )

        padding = 8.0
        gap = 6.0
        metric_columns = 4 if width >= 650 else 2
        metric_rows = int(math.ceil(4 / metric_columns))
        metric_h = 46.0
        metric_w = max(
            72.0,
            (width - 2 * padding - gap * (metric_columns - 1))
            / metric_columns,
        )

        for index, (label, value) in enumerate(metrics):
            row = index // metric_columns
            col = index % metric_columns
            x = padding + col * (metric_w + gap)
            y = padding + row * (metric_h + gap)
            cr.set_source_rgb(*panel)
            cr.rectangle(x, y, metric_w, metric_h)
            cr.fill()

            if complete:
                color = green
            elif index == 1:
                color = accent
            elif index == 3 and fps is not None:
                color = green
            else:
                color = blue

            cr.set_source_rgba(color[0], color[1], color[2], 0.65)
            cr.rectangle(x + 8.0, y + 7.0, 18.0, 2.0)
            cr.fill()
            cr.set_source_rgb(*color)
            cr.rectangle(x, y + metric_h - 3.0, metric_w, 3.0)
            cr.fill()

            cr.set_source_rgb(*muted)
            cr.set_font_size(9.0)
            cr.move_to(x + 8.0, y + 18.0)
            cr.show_text(label)

            cr.set_source_rgb(*(color if index in (1, 3) or complete else text))
            cr.set_font_size(16.0)
            cr.move_to(x + 8.0, y + 37.0)
            cr.show_text(value)

        metric_bottom = (
            padding
            + metric_rows * metric_h
            + max(0, metric_rows - 1) * gap
        )
        title_y = metric_bottom + 17.0
        cr.set_source_rgb(*muted)
        cr.set_font_size(9.0)
        cr.move_to(padding, title_y)
        cr.show_text("RENDER PIPELINE / FRAME HISTORY")

        state_text = {
            "complete": "COMPLETE",
            "error": "ERROR",
            "cancelled": "STOPPED",
        }.get(self.gpu_visual_state, "LIVE")
        state_color = green if complete else accent if not running else blue
        label_width = max(34.0, len(state_text) * 6.0)
        cr.set_source_rgb(*state_color)
        cr.arc(
            max(padding + 4.0, width - padding - label_width - 9.0),
            title_y - 3.0,
            3.0,
            0,
            math.tau,
        )
        cr.fill()
        cr.set_font_size(9.0)
        cr.move_to(width - padding - label_width, title_y)
        cr.show_text(state_text)

        values = list(self.gpu_frame_values) or [0.0]
        count = len(values)
        bar_gap = 4.0
        top = title_y + 8.0
        bottom = height - padding - 8.0
        bar_h = max(18.0, bottom - top)
        bar_w = max(
            4.0,
            (width - 2 * padding - bar_gap * (count - 1)) / count,
        )
        scan_index = -1
        if running and count:
            scan_index = int(time.monotonic() * 7.0) % count

        progress = max(0.0, min(1.0, self.gpu_activity_progress))

        for index, raw in enumerate(values):
            x = padding + index * (bar_w + bar_gap)
            raw_value = max(0.0, min(1.0, raw))
            value = (
                self.benchmark_growing_bar_value(raw_value, progress)
                if running
                else max(0.05, raw_value)
            )
            cr.set_source_rgba(track[0], track[1], track[2], 0.65)
            cr.rectangle(x, top, bar_w, bar_h)
            cr.fill()

            active_color = green if complete else accent if temp_c is not None and temp_c >= 85.0 else blue
            active_h = bar_h if complete else max(3.0, bar_h * value)
            cr.set_source_rgba(
                active_color[0],
                active_color[1],
                active_color[2],
                0.95 if index == scan_index else 0.72,
            )
            cr.rectangle(x, top + bar_h - active_h, bar_w, active_h)
            cr.fill()

        cr.set_source_rgb(*(green if complete else accent))
        cr.rectangle(
            padding,
            height - 4.0,
            max(0.0, (width - 2 * padding) * progress),
            3.0,
        )
        cr.fill()

    def reset_gpu_activity_field(self):
        self.gpu_activity_progress = 0.0
        self.gpu_visual_load = None
        self.gpu_visual_temp = None
        self.gpu_visual_temp_source = None
        self.gpu_visual_clock_mhz = None
        self.gpu_visual_fps = None
        self.gpu_peak_temp = None
        self.gpu_peak_load = None
        self.gpu_renderer = None
        self.gpu_usage_prev_snapshot = None
        self.gpu_usage_prev_ts_ns = None
        self.gpu_frame_values = [
            random.uniform(0.05, 0.95)
            for _ in range(24)
        ]

    def step_gpu_activity_field(self):
        target_base = (
            0.78
            if self.gpu_visual_load is None
            else max(0.12, min(1.0, self.gpu_visual_load / 100.0))
        )
        self.gpu_frame_values = self.gpu_frame_values[1:] + [
            max(
                0.05,
                min(1.0, target_base + random.uniform(-0.16, 0.16)),
            )
        ]

    def sample_gpu_process_load(self):
        """
        Renderlast des laufenden glmark2-Prozesses.

        i915: busy-ns pro Engine gegen reale Sample-Zeit.
        xe: busy-cycles gegen total-cycles direkt in der GPU-Zeitdomäne.
        Angezeigt wird die am stärksten ausgelastete Engine.
        """
        proc = self.test_proc
        if proc is None or proc.poll() is not None:
            return None

        now_ns = time.monotonic_ns()
        current = read_gpu_process_usage_snapshot(proc.pid)
        if current is None:
            return None

        previous = self.gpu_usage_prev_snapshot
        previous_ts = self.gpu_usage_prev_ts_ns
        self.gpu_usage_prev_snapshot = current
        self.gpu_usage_prev_ts_ns = now_ns

        if previous is None or previous_ts is None:
            return None

        loads = []

        # Xe: busy cycles / total cycles; capacity berücksichtigt Engine-Gruppen.
        for key, busy_now in current["cycles"].items():
            if key not in previous["cycles"]:
                continue
            total_now = current["total_cycles"].get(key)
            total_prev = previous["total_cycles"].get(key)
            if total_now is None or total_prev is None:
                continue

            delta_busy = busy_now - previous["cycles"][key]
            delta_total = total_now - total_prev
            if delta_busy < 0 or delta_total <= 0:
                continue

            capacity = max(1, current["capacity"].get(key, 1))
            loads.append(
                max(
                    0.0,
                    min(
                        100.0,
                        (delta_busy / delta_total) * 100.0 / capacity,
                    ),
                )
            )

        # i915: busy-Zeit in ns gegen reale Sample-Zeit.
        delta_time = now_ns - previous_ts
        if delta_time > 0:
            for key, busy_now in current["engine_ns"].items():
                if key not in previous["engine_ns"]:
                    continue

                delta_busy = busy_now - previous["engine_ns"][key]
                if delta_busy < 0:
                    continue

                capacity = max(1, current["capacity"].get(key, 1))
                loads.append(
                    max(
                        0.0,
                        min(
                            100.0,
                            (delta_busy / delta_time) * 100.0 / capacity,
                        ),
                    )
                )

        if not loads:
            return None

        load = max(loads)
        if self.gpu_peak_load is None or load > self.gpu_peak_load:
            self.gpu_peak_load = load
        return load

    def redraw_gpu_activity(self):
        if hasattr(self, "gpu_activity"):
            self.gpu_activity.queue_draw()
        return False

    def force_gpu_visual_state(self, state):
        """Finalzustand gegen verspätete LIVE-Redraws absichern."""
        self.gpu_visual_state = state
        if state == "complete":
            self.gpu_frame_values = [1.0] * 24
            self.gpu_activity_progress = 1.0
        if hasattr(self, "gpu_activity"):
            self.gpu_activity.queue_draw()
        return False

    def update_gpu_activity(
        self,
        state=None,
        load=None,
        temp_c=None,
        temp_source=None,
        clock_mhz=None,
        fps=None,
        progress=None,
    ):
        if not hasattr(self, "gpu_activity"):
            return
        is_gpu = bool(self.test_kind and self.test_kind.startswith("gpu"))
        self.gpu_activity.set_visible(is_gpu)

        if state is not None:
            self.gpu_visual_state = state
            if is_gpu and state == "running":
                self.reset_gpu_activity_field()
            elif state == "complete":
                self.gpu_frame_values = [1.0] * 24
                self.gpu_activity_progress = 1.0

        if load is not None:
            self.gpu_visual_load = load
            if self.gpu_peak_load is None or load > self.gpu_peak_load:
                self.gpu_peak_load = load
        if temp_c is not None:
            self.gpu_visual_temp = temp_c
            if temp_source is not None:
                self.gpu_visual_temp_source = temp_source
            if self.gpu_peak_temp is None or temp_c > self.gpu_peak_temp:
                self.gpu_peak_temp = temp_c
        if clock_mhz is not None:
            self.gpu_visual_clock_mhz = clock_mhz
        if fps is not None:
            self.gpu_visual_fps = fps
        if progress is not None:
            self.gpu_activity_progress = max(0.0, min(1.0, progress))

        if is_gpu and self.gpu_visual_state == "running":
            self.step_gpu_activity_field()
        if is_gpu:
            self.gpu_activity.queue_draw()

        # Abschlusszustand sicher neu zeichnen. Sonst kann der letzte blaue
        # LIVE-Frame im DrawingArea sichtbar bleiben.
        if state in ("complete", "error", "cancelled"):
            GLib.idle_add(self.force_gpu_visual_state, state)
            GLib.timeout_add(80, self.force_gpu_visual_state, state)
            GLib.timeout_add(220, self.force_gpu_visual_state, state)

    def reset_ram_activity_field(self):
        total = 40 * 8
        self.ram_activity_values = [random.uniform(0.02, 0.16) for _ in range(total)]
        self.ram_activity_targets = list(self.ram_activity_values)
        self.ram_activity_progress = 0.0

        order = list(range(total))
        random.shuffle(order)
        self.ram_activity_green_thresholds = [1.0] * total
        for rank, index in enumerate(order):
            position = rank / max(1, total - 1)
            threshold = 0.04 + position * 0.90 + random.uniform(-0.012, 0.012)
            self.ram_activity_green_thresholds[index] = max(0.025, min(0.94, threshold))

        self.ram_activity_hotspots = [
            {
                "x": random.uniform(0.0, 39.0),
                "y": random.uniform(0.0, 7.0),
                "vx": random.uniform(-0.38, 0.38),
                "vy": random.uniform(-0.16, 0.16),
                "strength": random.uniform(0.48, 0.95),
            }
            for _ in range(4)
        ]

    def step_ram_activity_field(self):
        """Bewegt weiche Hotspots und lässt ihre Aktivität langsam nachglühen."""
        columns = 40
        rows = 8
        if not self.ram_activity_hotspots:
            self.reset_ram_activity_field()

        for hotspot in self.ram_activity_hotspots:
            hotspot["x"] = (hotspot["x"] + hotspot["vx"]) % columns
            hotspot["y"] += hotspot["vy"]
            if hotspot["y"] < 0.0 or hotspot["y"] > rows - 1:
                hotspot["vy"] *= -1.0
                hotspot["y"] = min(rows - 1.0, max(0.0, hotspot["y"]))
            hotspot["vx"] = min(
                0.48, max(-0.48, hotspot["vx"] + random.uniform(-0.045, 0.045))
            )
            hotspot["vy"] = min(
                0.22, max(-0.22, hotspot["vy"] + random.uniform(-0.025, 0.025))
            )
            hotspot["strength"] = min(
                1.0, max(0.4, hotspot["strength"] + random.uniform(-0.06, 0.06))
            )

        raw_targets = []
        for row in range(rows):
            for column in range(columns):
                activity = random.uniform(0.015, 0.12)
                for hotspot in self.ram_activity_hotspots:
                    dx = abs(column - hotspot["x"])
                    dx = min(dx, columns - dx)
                    dy = row - hotspot["y"]
                    activity += hotspot["strength"] * math.exp(
                        -(dx * dx / 20.0 + dy * dy / 3.2)
                    )
                if random.random() < 0.025:
                    activity += random.uniform(0.18, 0.42)
                raw_targets.append(min(1.0, activity))

        for index, target in enumerate(raw_targets):
            row, column = divmod(index, columns)
            neighbours = []
            for d_row, d_column in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                near_row = row + d_row
                near_column = (column + d_column) % columns
                if 0 <= near_row < rows:
                    neighbours.append(raw_targets[near_row * columns + near_column])
            smoothed = target * 0.72 + sum(neighbours) / len(neighbours) * 0.28
            self.ram_activity_targets[index] = smoothed
            current = self.ram_activity_values[index]
            blend = 0.24 if smoothed > current else 0.10
            self.ram_activity_values[index] += (smoothed - current) * blend

    def update_ram_activity(self, state=None):
        if not hasattr(self, "ram_activity"):
            return
        is_ram = bool(self.test_kind and self.test_kind.startswith("ram"))
        self.ram_activity.set_visible(is_ram)
        if state is not None:
            self.ram_visual_state = state
            if is_ram and state == "running":
                self.reset_ram_activity_field()
        if is_ram and self.ram_visual_state == "running":
            self.step_ram_activity_field()
        if is_ram:
            self.ram_activity.queue_draw()

    def reset_benchmark_ui(self):
        self.stop_test_process()
        self.test_kind = None
        self.test_duration = 0.0
        self.test_started = 0.0
        self.test_hard_deadline = 0.0
        self.test_cancelled = False
        self.test_sequence_active = False
        self.test_sequence_mode = None
        self.test_sequence = []
        self.test_sequence_index = 0
        self.test_sequence_results = []
        self.test_sequence_total_duration = 0.0
        self.test_sequence_completed_duration = 0.0
        self.test_sequence_finalize_pending = False

        if hasattr(self, "benchmark_status"):
            self.set_benchmark_status_temp_class(None)
            self.benchmark_status.set_text("Bereit")
            self.benchmark_progress.set_fraction(0.0)
            self.benchmark_time.set_text("00:00 / 00:00")
            self.benchmark_result.set_text("")
            self.set_benchmark_result_class(None)
            self.set_benchmark_controls(False)
            self.update_cpu_activity("idle")
            self.update_ram_activity("idle")
            self.update_gpu_activity("idle")

    def set_benchmark_status_temp_class(self, temp_c):
        for cls in ("status-green", "status-yellow", "status-red"):
            self.benchmark_status.remove_css_class(cls)

        if temp_c is None:
            return

        if temp_c >= 97.0:
            self.benchmark_status.add_css_class("status-red")
        elif temp_c >= 90.0:
            self.benchmark_status.add_css_class("status-yellow")
    def update_cpu_benchmark_status(self):
        cores = os.cpu_count() or 1

        # Temperatur und FAN sind Zusatzinformationen.
        # Sensorfehler dürfen die CPU-Lastmessung niemals blockieren.
        try:
            temp_c = read_cpu_temperature()
        except Exception as exc:
            temp_c = None
            log(f"CPU-Temperatur nicht lesbar: {exc}")

        fan_rpm = None
        try:
            fan_key, fan_rpm, _fan_percent = read_fan_status(
                self.fan_sensor_key
            )
            if fan_key is not None:
                self.fan_sensor_key = fan_key
        except Exception as exc:
            log(f"FAN-Drehzahl nicht lesbar: {exc}")

        try:
            clock_mhz = read_cpu_average_frequency_mhz()
        except Exception as exc:
            clock_mhz = None
            log(f"CPU-Takt nicht lesbar: {exc}")

        # Temperatur, FAN und CPU-Takt stehen vollständig in der Telemetrie-Anzeige.
        # Die Kopfzeile bleibt absichtlich kurz, damit sie niemals die
        # Fensterbreite des Hardware Checks vergrößert.
        text = (
            f"{self.sequence_step_prefix()}"
            f"CPU Benchmark läuft · {cores} Threads / Kerne"
        )

        self.benchmark_status.set_text(text)
        self.set_benchmark_status_temp_class(temp_c)
        self.update_cpu_activity(
            temp_c=temp_c,
            fan_rpm=fan_rpm,
            clock_mhz=clock_mhz,
            progress=self.cpu_activity_progress,
        )

    def update_gpu_benchmark_status(self):
        try:
            telemetry = read_gpu_telemetry()
        except Exception as exc:
            telemetry = {
                "load": None,
                "temp": None,
                "clock_mhz": None,
            }
            log(f"GPU-Telemetrie nicht lesbar: {exc}")

        process_load = self.sample_gpu_process_load()
        if process_load is not None:
            telemetry["load"] = process_load

        prefix = ""
        if self.test_sequence_active:
            prefix = (
                f"{self.test_sequence_mode} · "
                f"{self.test_sequence_index + 1}/"
                f"{len(self.test_sequence)} · "
            )

        renderer = self.gpu_renderer
        if renderer:
            renderer_text = short_gpu_renderer_name(renderer)
            text = f"{prefix}GPU Test läuft · {renderer_text}"
        else:
            text = f"{prefix}GPU Test läuft · OpenGL"

        self.benchmark_status.set_text(text)
        self.set_benchmark_status_temp_class(None)
        self.update_gpu_activity(
            load=telemetry.get("load"),
            temp_c=telemetry.get("temp"),
            temp_source=telemetry.get("temp_source"),
            clock_mhz=telemetry.get("clock_mhz"),
            progress=self.gpu_activity_progress,
        )

    def apply_gpu_output_line(self, line):
        if not self.test_kind or not self.test_kind.startswith("gpu"):
            return False

        renderer = re.search(r"GL_RENDERER\s*:\s*(.+)$", line, re.I)
        if renderer:
            self.gpu_renderer = renderer.group(1).strip()

        fps_match = re.search(r"FPS\s*:\s*([0-9]+(?:\.[0-9]+)?)", line, re.I)
        if fps_match:
            try:
                self.gpu_visual_fps = float(fps_match.group(1))
            except Exception:
                pass

        if hasattr(self, "gpu_activity"):
            self.gpu_activity.queue_draw()
        return False

    def collect_test_output(self, proc, kind):
        try:
            if proc.stdout is None:
                return
            for raw_line in proc.stdout:
                line = raw_line.rstrip("\r\n")
                if not line:
                    continue
                self.test_output_lines.append(line)
                if kind.startswith("gpu"):
                    GLib.idle_add(self.apply_gpu_output_line, line)
        except Exception as exc:
            log(f"Benchmark-Ausgabe konnte nicht gelesen werden: {exc}")

    def sequence_step_prefix(self):
        if not self.test_sequence_active:
            return ""
        return (
            f"{self.test_sequence_mode} · "
            f"{self.test_sequence_index + 1}/"
            f"{len(self.test_sequence)} · "
        )

    def clear_benchmark_button_results(self):
        for button in self.benchmark_buttons:
            button.remove_css_class("benchmark-running")
            button.remove_css_class("benchmark-passed")
            button.remove_css_class("benchmark-failed")

    def set_benchmark_button_running(self, kind):
        for button in self.benchmark_buttons:
            button.remove_css_class("benchmark-running")

        button = self.benchmark_button_by_kind.get(kind)
        if button is None:
            return

        button.remove_css_class("benchmark-passed")
        button.remove_css_class("benchmark-failed")
        button.add_css_class("benchmark-running")

    def set_benchmark_button_result(self, kind, ok):
        button = self.benchmark_button_by_kind.get(kind)
        if button is None:
            return
        button.remove_css_class("benchmark-running")
        button.remove_css_class("benchmark-passed")
        button.remove_css_class("benchmark-failed")
        button.add_css_class(
            "benchmark-passed" if ok else "benchmark-failed"
        )

    def start_test_sequence(self, kind):
        if self.test_proc is not None and self.test_proc.poll() is None:
            return

        extended = kind == "all-long"
        self.clear_benchmark_button_results()
        self.test_sequence_active = True
        self.test_sequence_mode = "ALLE ERW." if extended else "ALLE"
        # CPU absichtlich zuletzt: Beim automatischen Start laufen parallel
        # noch LAN/WLAN-Tests. Der CPU-Benchmark belastet Scheduling und
        # Netzwerk-Userspace deutlich stärker als RAM/GPU und soll deren
        # Messergebnisse deshalb nicht mehr direkt beim Start beeinflussen.
        self.test_sequence = (
            [
                ("ram-long", 600.0),
                ("gpu-long", 600.0),
                ("cpu-long", 600.0),
            ]
            if extended
            else [
                ("ram-short", 10.0),
                ("gpu-short", 10.0),
                ("cpu-short", 10.0),
            ]
        )
        self.test_sequence_index = 0
        self.test_sequence_results = []
        self.test_sequence_total_duration = sum(
            duration for _step_kind, duration in self.test_sequence
        )
        self.test_sequence_completed_duration = 0.0
        self.test_sequence_finalize_pending = False
        self.test_cancelled = False
        self.set_benchmark_controls(True)
        self.start_next_sequence_test()

    def start_next_sequence_test(self):
        if not self.test_sequence_active:
            return False
        if self.test_sequence_index >= len(self.test_sequence):
            self.finish_test_sequence()
            return False

        kind, duration = self.test_sequence[self.test_sequence_index]
        self.set_benchmark_button_running(kind)
        self.start_single_test(kind, duration)
        return False

    def finish_sequence_step(self, outcome, step_kind=None, force=False):
        """
        Einen ALLE-Schritt robust abschließen.

        force=True wird aus poll_test mit dem vor finish_test_result gemerkten
        Sequenzzustand verwendet. Damit kann der letzte GPU-Schritt die
        Gesamtauswertung nicht verlieren, selbst wenn während der
        Ergebnisverarbeitung ein UI-Zustand umgeschaltet wurde.
        """
        if not self.test_sequence_active and not force:
            return False

        if not isinstance(outcome, dict):
            outcome = {
                "ok": False,
                "name": "TEST",
                "summary": "kein Ergebnis",
            }

        kind = step_kind or self.test_kind
        if kind:
            self.set_benchmark_button_result(
                kind,
                bool(outcome.get("ok")),
            )

        self.test_sequence_results.append(outcome)
        self.test_sequence_completed_duration += self.test_duration
        self.test_sequence_index += 1

        if self.test_sequence_index < len(self.test_sequence):
            GLib.timeout_add(350, self.start_next_sequence_test)
        elif not self.test_sequence_finalize_pending:
            # Finalisierung bewusst im nächsten GTK-Durchlauf. So konkurriert
            # sie nicht mit letzten glmark2-/DrawingArea-Callbacks.
            self.test_sequence_finalize_pending = True
            GLib.idle_add(self.finish_test_sequence)
            # Zweiter unabhängiger Abschlussweg. Falls ein fremder GTK-Idle-
            # Callback den ersten Durchlauf stört, finalisiert spätestens
            # dieser Timeout dieselbe idempotente Sequenz.
            GLib.timeout_add(300, self.finish_test_sequence)
        return False

    def finish_test_sequence(self):
        if not self.test_sequence_finalize_pending and not self.test_sequence_active:
            return False

        results = [
            item
            for item in self.test_sequence_results
            if isinstance(item, dict)
        ]
        sequence_name = self.test_sequence_mode or "ALLE"
        expected_count = len(self.test_sequence) or 3

        if len(results) < expected_count:
            missing = expected_count - len(results)
            for _ in range(missing):
                results.append(
                    {
                        "ok": False,
                        "name": "TEST",
                        "summary": "Ergebnis fehlt",
                    }
                )

        all_ok = bool(results) and all(
            bool(item.get("ok"))
            for item in results
        )

        # Ausführungsreihenfolge ist RAM → GPU → CPU, die gewohnte
        # Ergebnisdarstellung bleibt trotzdem CPU · RAM · GPU.
        display_order = {
            "CPU": 0,
            "RAM": 1,
            "GPU": 2,
        }
        display_results = sorted(
            results,
            key=lambda item: display_order.get(item.get("name"), 99),
        )

        parts = []
        for item in display_results:
            mark = "✓" if item.get("ok") else "✕"
            summary = item.get("summary") or ""
            text = item.get("name", "TEST")
            if summary:
                text += f" {summary}"
            parts.append(f"{text} {mark}")

        overall_kind = (
            "all-long"
            if sequence_name == "ALLE ERW."
            else "all-short"
        )
        self.set_benchmark_button_result(overall_kind, all_ok)

        self.test_sequence_active = False
        self.test_sequence_finalize_pending = False
        self.test_sequence_mode = None
        self.test_sequence = []
        self.test_sequence_index = 0
        self.test_sequence_total_duration = 0.0
        self.test_sequence_completed_duration = 0.0
        self.set_benchmark_controls(False)
        self.benchmark_progress.set_fraction(1.0)
        total_duration = (
            1800.0
            if sequence_name == "ALLE ERW."
            else 30.0
        )
        self.benchmark_time.set_text(
            f"{format_test_clock(total_duration)} / "
            f"{format_test_clock(total_duration)}"
        )
        self.set_benchmark_status_temp_class(None)
        self.benchmark_status.set_text(
            f"{sequence_name} abgeschlossen"
            if all_ok
            else f"{sequence_name} mit Auffälligkeiten abgeschlossen"
        )
        self.benchmark_status.add_css_class(
            "status-green" if all_ok else "status-red"
        )
        self.set_benchmark_result_text(
            " · ".join(parts),
            "green" if all_ok else "red",
        )

        # Der letzte Test ist GPU. Dessen Visual bleibt sichtbar, erhält aber
        # sicher den finalen COMPLETE/ERROR-Zustand statt LIVE.
        if self.test_kind and self.test_kind.startswith("gpu"):
            self.force_gpu_visual_state(
                "complete" if all_ok else "error"
            )

        log(
            f"{sequence_name} fertig: "
            + " | ".join(
                f"{item.get('name')}={'OK' if item.get('ok') else 'FEHLER'}"
                for item in results
            )
        )
        return False

    def set_benchmark_controls(self, running):
        for b in self.benchmark_buttons:
            b.set_sensitive(not running)

        if hasattr(self, "cancel_test_button"):
            self.cancel_test_button.set_sensitive(running)

    def start_experimental_benchmark(self):
        if not BENCHMARK_WINDOW_MODE:
            return False
        if self.test_proc is not None and self.test_proc.poll() is None:
            return False
        self.start_test(None, "all-short", 30.0)
        log("Benchmark EXP: ALLE Kurztests automatisch gestartet")
        return False

    def show_benchmarks(self, *_):
        # Die Benchmark-Seite übernimmt exakt die bestehende Fenstergröße.
        # Kein set_default_size: weder Seitenwechsel noch Teststart dürfen das
        # Hardware-Check-Fenster künstlich verbreitern.
        self.stack.set_visible_child_name("benchmarks")

    def start_test(self, button, kind, duration):
        if kind.startswith("all-"):
            self.start_test_sequence(kind)
            return

        self.test_sequence_active = False
        self.test_sequence_mode = None
        self.test_sequence = []
        self.test_sequence_results = []
        self.test_sequence_finalize_pending = False
        button_for_kind = self.benchmark_button_by_kind.get(kind)
        if button_for_kind is not None:
            button_for_kind.remove_css_class("benchmark-running")
            button_for_kind.remove_css_class("benchmark-passed")
            button_for_kind.remove_css_class("benchmark-failed")
        self.set_benchmark_button_running(kind)
        self.start_single_test(kind, duration)

    def start_single_test(self, kind, duration):
        if self.test_proc is not None and self.test_proc.poll() is None:
            return

        self.stop_test_process()

        self.test_kind = kind
        self.test_duration = float(duration)
        self.test_started = time.monotonic()
        grace = (
            12.0
            if kind == "gpu-short"
            else 45.0
            if kind == "gpu-long"
            else 8.0
        )
        self.test_hard_deadline = self.test_started + float(duration) + grace
        self.test_cancelled = False
        self.test_output_lines = []
        if self.test_sequence_active:
            base_fraction = (
                self.test_sequence_completed_duration
                / max(0.1, self.test_sequence_total_duration)
            )
            self.benchmark_progress.set_fraction(base_fraction)
            self.benchmark_time.set_text(
                f"{format_test_clock(self.test_sequence_completed_duration)} / "
                f"{format_test_clock(self.test_sequence_total_duration)}"
            )
        else:
            self.benchmark_progress.set_fraction(0.0)
            self.benchmark_time.set_text(
                f"00:00 / {format_test_clock(duration)}"
            )
        self.benchmark_result.set_text("")
        self.set_benchmark_result_class(None)

        if kind.startswith("cpu"):
            self.update_ram_activity("idle")
            self.update_gpu_activity("idle")
            self.update_cpu_activity("running")
            cores = os.cpu_count() or 1

            log(
                f"CPU Benchmark wird vorbereitet: "
                f"{kind}, Dauer={duration:.0f}s, Kerne={cores}"
            )
            self.update_cpu_benchmark_status()
            args = [
                sys.executable,
                "-c",
                CPU_BENCH_WORKER,
                str(duration),
                str(cores),
            ]
        elif kind.startswith("ram"):
            self.update_cpu_activity("idle")
            self.update_gpu_activity("idle")
            self.update_ram_activity("running")
            self.set_benchmark_status_temp_class(None)
            mode = "short" if kind == "ram-short" else "long"
            if mode == "short":
                status = "RAM Test läuft · mehrere Bitmuster"
            else:
                status = "RAM Test (Erweitert) läuft · maximale RAM-Last"
            self.benchmark_status.set_text(
                self.sequence_step_prefix() + status
            )
            args = [
                sys.executable,
                "-c",
                RAM_TEST_WORKER,
                str(duration),
                mode,
            ]
        else:
            self.update_cpu_activity("idle")
            self.update_ram_activity("idle")
            self.update_gpu_activity("running")
            self.set_benchmark_status_temp_class(None)
            mode = "short" if kind == "gpu-short" else "long"
            args = build_gpu_benchmark_args(duration, mode)
            if args is None:
                message = "glmark2 fehlt - GPU-Test nicht verfügbar"
                self.benchmark_status.set_text("GPU Test nicht verfügbar")
                self.benchmark_result.set_text(message)
                self.set_benchmark_result_class("red")
                self.update_gpu_activity("error")
                self.set_benchmark_controls(False)
                outcome = {
                    "ok": False,
                    "name": "GPU",
                    "summary": "glmark2 fehlt",
                }
                if self.test_sequence_active:
                    self.finish_sequence_step(
                        outcome,
                        step_kind=kind,
                    )
                return
            self.update_gpu_benchmark_status()

        log(
            f"Test gestartet: {kind}, Dauer={duration:.0f}s"
        )
        try:
            self.test_proc = subprocess.Popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                start_new_session=True,
            )
        except Exception as exc:
            self.test_proc = None
            self.benchmark_status.set_text("Test konnte nicht gestartet werden")
            self.benchmark_result.set_text(str(exc))
            self.set_benchmark_result_class("red")
            if kind.startswith("cpu"):
                self.update_cpu_activity("error")
            elif kind.startswith("ram"):
                self.update_ram_activity("error")
            else:
                self.update_gpu_activity("error")
            outcome = {
                "ok": False,
                "name": (
                    "CPU" if kind.startswith("cpu")
                    else "RAM" if kind.startswith("ram")
                    else "GPU"
                ),
                "summary": "Startfehler",
            }
            if self.test_sequence_active:
                self.finish_sequence_step(
                    outcome,
                    step_kind=kind,
                )
            return

        self.test_reader_thread = threading.Thread(
            target=self.collect_test_output,
            args=(self.test_proc, kind),
            daemon=True,
        )
        self.test_reader_thread.start()
        self.set_benchmark_controls(True)
        GLib.timeout_add(200, self.poll_test)

    def poll_test(self):
        proc = self.test_proc

        if proc is None:
            return False

        elapsed = max(0.0, time.monotonic() - self.test_started)
        duration = max(0.1, self.test_duration)

        # Kein Einzeltest darf eine ALLE-Sequenz dauerhaft blockieren.
        # glmark2 erhält Setup-Reserve, danach greift ein harter Watchdog.
        if (
            proc.poll() is None
            and self.test_hard_deadline > 0.0
            and time.monotonic() > self.test_hard_deadline
        ):
            log(
                f"Benchmark-Watchdog: {self.test_kind} "
                f"nach {elapsed:.1f}s beendet"
            )
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except Exception:
                try:
                    proc.terminate()
                except Exception:
                    pass
            try:
                proc.wait(timeout=2.0)
            except Exception:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass

        if proc.poll() is None:
            fraction = min(0.99, elapsed / duration)

            if self.test_sequence_active:
                overall_elapsed = (
                    self.test_sequence_completed_duration
                    + min(elapsed, duration)
                )
                overall_fraction = min(
                    0.99,
                    overall_elapsed
                    / max(0.1, self.test_sequence_total_duration),
                )
                self.benchmark_progress.set_fraction(overall_fraction)
                self.benchmark_time.set_text(
                    f"{format_test_clock(overall_elapsed)} / "
                    f"{format_test_clock(self.test_sequence_total_duration)}"
                )
            else:
                self.benchmark_progress.set_fraction(fraction)
                self.benchmark_time.set_text(
                    f"{format_test_clock(elapsed)} / "
                    f"{format_test_clock(duration)}"
                )

            if self.test_kind and self.test_kind.startswith("ram"):
                self.ram_activity_progress = fraction
            elif self.test_kind and self.test_kind.startswith("cpu"):
                self.cpu_activity_progress = fraction
            elif self.test_kind and self.test_kind.startswith("gpu"):
                self.gpu_activity_progress = fraction

            self.update_ram_activity()

            if self.test_kind and self.test_kind.startswith("cpu"):
                self.update_cpu_benchmark_status()
            elif self.test_kind and self.test_kind.startswith("gpu"):
                self.update_gpu_benchmark_status()

            return True

        if self.test_reader_thread is not None:
            self.test_reader_thread.join(timeout=1.0)
        output = "\n".join(self.test_output_lines)

        self.test_proc = None
        sequence_was_active = self.test_sequence_active
        completed_kind = self.test_kind

        if sequence_was_active:
            overall_elapsed = min(
                self.test_sequence_total_duration,
                self.test_sequence_completed_duration + duration,
            )
            self.benchmark_progress.set_fraction(
                overall_elapsed
                / max(0.1, self.test_sequence_total_duration)
            )
            self.benchmark_time.set_text(
                f"{format_test_clock(overall_elapsed)} / "
                f"{format_test_clock(self.test_sequence_total_duration)}"
            )
        else:
            # Nach Abschluss immer die Sollzeit zeigen. Ein glmark2-Lauf darf
            # früher fertig werden, soll aber optisch nicht bei 00:16/00:20
            # "hängen" bleiben.
            self.benchmark_progress.set_fraction(1.0)
            self.benchmark_time.set_text(
                f"{format_test_clock(duration)} / "
                f"{format_test_clock(duration)}"
            )
            self.set_benchmark_controls(False)

        self.update_ram_activity()

        if self.test_cancelled:
            return False

        outcome = None
        try:
            outcome = self.finish_test_result(output, proc.returncode)
        except Exception as exc:
            log(
                f"Ergebnisdarstellung fehlgeschlagen: "
                f"{completed_kind}: {exc}"
            )
            outcome = {
                "ok": False,
                "name": (
                    "CPU" if completed_kind and completed_kind.startswith("cpu")
                    else "RAM" if completed_kind and completed_kind.startswith("ram")
                    else "GPU"
                ),
                "summary": "Auswertung fehlgeschlagen",
            }
            self.set_benchmark_status_temp_class(None)
            self.benchmark_status.set_text("Auswertung fehlgeschlagen")
            self.benchmark_status.add_css_class("status-red")
            self.set_benchmark_result_text(str(exc), "red")
        finally:
            # Diese Finalisierung muss auch dann passieren, wenn die letzte
            # UI-Aktualisierung des GPU-Ergebnisses eine Ausnahme wirft.
            if completed_kind and completed_kind.startswith("gpu"):
                self.force_gpu_visual_state(
                    "complete"
                    if outcome and outcome.get("ok")
                    else "error"
                )

            if sequence_was_active and not self.test_cancelled:
                self.finish_sequence_step(
                    outcome,
                    step_kind=completed_kind,
                    force=True,
                )
            elif not sequence_was_active:
                # Einzeltests erhalten nach Abschluss denselben sichtbaren
                # Grün/Rot-Zustand wie die Schritte einer ALLE-Sequenz.
                self.set_benchmark_button_result(
                    completed_kind,
                    bool(outcome and outcome.get("ok")),
                )
                self.set_benchmark_controls(False)

        return False

    def finish_test_result(self, output, returncode):
        lines = [
            line.strip()
            for line in output.splitlines()
            if line.strip()
        ]

        result = next(
            (line for line in reversed(lines) if line.startswith("RESULT ")),
            None,
        )
        error = next(
            (line for line in reversed(lines) if line.startswith("ERROR ")),
            None,
        )
        is_gpu = bool(
            self.test_kind and self.test_kind.startswith("gpu")
        )
        if returncode != 0 or (not result and not is_gpu):
            self.set_benchmark_status_temp_class(None)
            self.benchmark_status.set_text("Test fehlgeschlagen")
            self.benchmark_status.add_css_class("status-red")
            self.set_benchmark_result_text(
                error[6:] if error else (
                    lines[-1] if lines else "Keine Ergebnisdaten"
                ),
                "red",
            )
            if self.test_kind and self.test_kind.startswith("cpu"):
                self.update_cpu_activity("error")
            elif self.test_kind and self.test_kind.startswith("ram"):
                self.update_ram_activity("error")
            else:
                self.update_gpu_activity("error")
            log(
                f"Test fehlgeschlagen: {self.test_kind}; "
                f"returncode={returncode}; output={output[-1000:]}"
            )
            name = (
                "CPU" if self.test_kind and self.test_kind.startswith("cpu")
                else "RAM" if self.test_kind and self.test_kind.startswith("ram")
                else "GPU"
            )
            return {
                "ok": False,
                "name": name,
                "summary": error[6:] if error else "fehlgeschlagen",
            }
        parts = result.split() if result else []

        if len(parts) >= 5 and parts[1] == "CPU":
            total = int(parts[2])
            elapsed = float(parts[3])
            workers = int(parts[4])

            points = int((total / max(0.001, elapsed)) / 1000.0)
            points_text = format_benchmark_points(points)
            self.set_benchmark_status_temp_class(None)
            self.benchmark_status.set_text("CPU Benchmark abgeschlossen")
            self.benchmark_status.add_css_class("status-green")
            self.set_benchmark_result_text(
                f"{points_text} Punkte · "
                f"{workers} Threads · "
                f"{elapsed:.1f}s",
                "green",
            )
            self.update_cpu_activity("complete")
            log(
                f"CPU Benchmark fertig: "
                f"{points} Punkte, {workers} Threads, {elapsed:.2f}s"
            )
            return {
                "ok": True,
                "name": "CPU",
                "summary": f"{points_text} P",
            }

        if len(parts) >= 7 and parts[1] == "RAM":
            errors = int(parts[2])
            checked = int(parts[3])
            elapsed = float(parts[4])
            target = int(parts[5])
            passes = int(parts[6])
            target_gib = target / (1024 ** 3)
            checked_gib = checked / (1024 ** 3)
            throughput = checked_gib / max(0.001, elapsed)
            if errors == 0:
                self.set_benchmark_status_temp_class(None)
                self.benchmark_status.set_text("RAM Test abgeschlossen")
                self.benchmark_status.add_css_class("status-green")
                self.set_benchmark_result_text(
                    f"0 Fehler · "
                    f"{target_gib:.1f} GB RAM · "
                    f"{checked_gib:.1f} GB geprüft · "
                    f"{throughput:.1f} GB/s",
                    "green",
                )
                self.update_ram_activity("complete")
            else:
                self.benchmark_status.set_text(
                    "RAM FEHLER ERKANNT"
                )
                self.set_benchmark_result_text(
                    f"{errors} fehlerhafte Blöcke · "
                    f"{target_gib:.1f} GB RAM · "
                    f"{passes} Prüfmuster",
                    "red",
                )
                self.update_ram_activity("error")
            log(
                f"RAM Test fertig: errors={errors}, "
                f"target={target}, checked={checked}, "
                f"elapsed={elapsed:.2f}s, passes={passes}"
            )
            return {
                "ok": errors == 0,
                "name": "RAM",
                "summary": (
                    "0 Fehler"
                    if errors == 0
                    else f"{errors} Fehler"
                ),
            }

        if self.test_kind and self.test_kind.startswith("gpu"):
            renderer_match = re.search(
                r"GL_RENDERER\s*:\s*(.+)$",
                output,
                re.I | re.M,
            )
            renderer = (
                renderer_match.group(1).strip()
                if renderer_match
                else self.gpu_renderer
            )
            score_matches = re.findall(
                r"glmark2 Score\s*:\s*([0-9]+)",
                output,
                re.I,
            )
            fps_matches = re.findall(
                r"FPS\s*:\s*([0-9]+(?:\.[0-9]+)?)",
                output,
                re.I,
            )
            fps_values = [float(value) for value in fps_matches]
            avg_fps = (
                sum(fps_values) / len(fps_values)
                if fps_values
                else self.gpu_visual_fps
            )
            score = (
                int(score_matches[-1])
                if score_matches
                else int(avg_fps or 0)
            )

            renderer_lower = (renderer or "").lower()
            software = any(
                token in renderer_lower
                for token in (
                    "llvmpipe",
                    "softpipe",
                    "swrast",
                    "software rasterizer",
                )
            )

            if renderer:
                self.gpu_renderer = renderer
            if avg_fps is not None:
                self.gpu_visual_fps = avg_fps

            if self.gpu_peak_temp is None:
                temp_text = ""
            elif self.gpu_visual_temp_source == "package":
                temp_text = f" · max. {self.gpu_peak_temp:.0f}°C PKG"
            else:
                temp_text = f" · max. {self.gpu_peak_temp:.0f}°C"

            load_text = (
                ""
                if self.gpu_peak_load is None
                else f" · max. {self.gpu_peak_load:.0f}% GPU"
            )
            renderer_text = short_gpu_renderer_name(renderer)

            if software:
                self.set_benchmark_status_temp_class(None)
                self.benchmark_status.set_text(
                    "GPU TEST: SOFTWARE-RENDERING ERKANNT"
                )
                self.benchmark_status.add_css_class("status-red")
                self.set_benchmark_result_text(
                    f"{renderer_text} · {avg_fps or 0:.0f} FPS",
                    "red",
                )
                self.update_gpu_activity("error")
                ok = False
                summary = "Software-Rendering"
            else:
                self.set_benchmark_status_temp_class(None)
                self.benchmark_status.set_text("GPU Test abgeschlossen")
                self.benchmark_status.add_css_class("status-green")
                score_text = format_benchmark_points(score)
                self.set_benchmark_result_text(
                    f"{score_text} P · "
                    f"{renderer_text}{load_text}{temp_text}",
                    "green",
                )
                self.update_gpu_activity("complete")
                ok = True
                summary = f"{format_benchmark_points(score)} P"

            log(
                f"GPU Test fertig: score={score}, "
                f"avg_fps={avg_fps}, renderer={renderer}, "
                f"software={software}, peak_temp={self.gpu_peak_temp}"
            )
            return {
                "ok": ok,
                "name": "GPU",
                "summary": summary,
            }

        self.benchmark_status.set_text("Unbekanntes Testergebnis")
        self.benchmark_result.set_text(result)
        self.set_benchmark_result_class("red")
        return {
            "ok": False,
            "name": "TEST",
            "summary": "unbekanntes Ergebnis",
        }

    def stop_test_process(self):
        proc = self.test_proc

        if proc is None:
            return
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except Exception:
                try:
                    proc.terminate()
                except Exception:
                    pass
            try:
                proc.wait(timeout=2.0)
            except Exception:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass

        self.test_proc = None
        if self.test_reader_thread is not None:
            self.test_reader_thread.join(timeout=0.5)
        self.test_reader_thread = None

    def cancel_test(self, *_):
        if self.test_proc is None:
            return
        self.test_cancelled = True
        self.test_sequence_active = False
        self.test_sequence_finalize_pending = False
        self.test_sequence_mode = None
        self.test_sequence = []
        self.test_sequence_results = []
        self.stop_test_process()
        self.set_benchmark_controls(False)

        self.set_benchmark_status_temp_class(None)
        self.benchmark_status.set_text("Test abgebrochen")
        self.benchmark_progress.set_fraction(0.0)
        self.benchmark_result.set_text("")
        self.set_benchmark_result_class("orange")
        if self.test_kind and self.test_kind.startswith("cpu"):
            self.update_cpu_activity("cancelled")
        elif self.test_kind and self.test_kind.startswith("ram"):
            self.update_ram_activity("cancelled")
        else:
            self.update_gpu_activity("cancelled")

        log(f"Test abgebrochen: {self.test_kind}")

    def build_keyboard(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.set_focusable(True)
        self.keyboard_focus_widget = root
        root.append(
            self.header(
                "KEYBOARD TEST",
                back=True,
                back_label="← ÜBERSICHT (ESC x3)",
            )
        )

        tools = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        tools.set_margin_start(8)
        tools.set_margin_end(8)
        tools.set_margin_bottom(4)
        self.keyboard_progress = Gtk.Label(label="0 von 0 getestet")
        self.keyboard_progress.set_xalign(0)
        self.keyboard_progress.set_hexpand(True)
        self.keyboard_progress.add_css_class("progress-label")

        reset = Gtk.Button(label="RESET")
        reset.add_css_class("secondary")
        reset.connect("clicked", self.reset_keyboard)

        tools.append(self.keyboard_progress)
        tools.append(reset)
        root.append(tools)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)

        board = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        board.set_margin_start(8)
        board.set_margin_end(8)
        board.set_margin_bottom(8)

        self.keyboard_key_geometry = []
        self.keyboard_spacer_geometry = []
        self.keyboard_spacing_boxes = [(board, 4)]
        self.keyboard_board = board
        self.keyboard_scale = None

        def add_key(parent, label, aliases, width, height=25):
            key = Gtk.Label(label=label)
            key.add_css_class("key")
            key.set_size_request(width, height)
            key_id = label + "|" + ",".join(aliases)
            self.key_widgets[key_id] = key
            self.keyboard_key_geometry.append((key, width, height))

            for alias in aliases:
                self.key_aliases[alias] = key_id

            parent.append(key)
            return key

        rows = self.keyboard_layout()
        row_base_widths = []
        row_base_heights = []

        for row_index, row_spec in enumerate(rows):
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=3)
            self.keyboard_spacing_boxes.append((row, 3))

            row_width = sum(width for _label, _aliases, width in row_spec)
            row_width += max(0, len(row_spec) - 1) * 3
            row_height = 25

            for label, aliases, width in row_spec:
                add_key(row, label, aliases, width)

            # Pfeilblock rechts neben der untersten Tastenreihe:
            #
            #       ↑
            #     ← ↓ →
            #
            # Damit entspricht die Anordnung einer echten Tastatur und
            # verbraucht trotzdem möglichst wenig Breite.
            if row_index == len(rows) - 1:
                arrows = Gtk.Box(
                    orientation=Gtk.Orientation.VERTICAL,
                    spacing=2
                )
                upper = Gtk.Box(
                    orientation=Gtk.Orientation.HORIZONTAL,
                    spacing=2
                )
                lower = Gtk.Box(
                    orientation=Gtk.Orientation.HORIZONTAL,
                    spacing=2
                )
                self.keyboard_spacing_boxes.extend(
                    ((arrows, 2), (upper, 2), (lower, 2))
                )

                blank_left = Gtk.Box()
                blank_left.set_size_request(24, 22)
                self.keyboard_spacer_geometry.append((blank_left, 24, 22))
                blank_right = Gtk.Box()
                blank_right.set_size_request(24, 22)
                self.keyboard_spacer_geometry.append((blank_right, 24, 22))
                upper.append(blank_left)
                add_key(upper, "↑", ("Up",), 24, 22)
                upper.append(blank_right)

                add_key(lower, "←", ("Left",), 24, 22)
                add_key(lower, "↓", ("Down",), 24, 22)
                add_key(lower, "→", ("Right",), 24, 22)

                arrows.append(upper)
                arrows.append(lower)
                row.append(arrows)

                arrow_width = 24 * 3 + 2 * 2
                arrow_height = 22 * 2 + 2
                row_width += 3 + arrow_width
                row_height = max(row_height, arrow_height)

            row_base_widths.append(row_width)
            row_base_heights.append(row_height)
            board.append(row)

        self.keyboard_reference_width = (
            max(row_base_widths, default=1) + 8 + 8
        )
        self.keyboard_reference_height = (
            sum(row_base_heights)
            + max(0, len(row_base_heights) - 1) * 4
            + 8
        )

        scroll.set_child(board)

        viewport = Gtk.Overlay()
        viewport.set_vexpand(True)
        viewport.set_child(scroll)

        resize_probe = Gtk.DrawingArea()
        resize_probe.set_hexpand(True)
        resize_probe.set_vexpand(True)
        resize_probe.set_can_target(False)
        resize_probe.connect("resize", self.on_keyboard_viewport_resize)
        viewport.add_overlay(resize_probe)

        self.keyboard_resize_probe = resize_probe
        root.append(viewport)
        self.update_keyboard()
        return root

    def on_keyboard_viewport_resize(self, _area, width, height):
        self.apply_keyboard_layout_scale(width, height)

    def refresh_keyboard_layout_scale(self):
        probe = getattr(self, "keyboard_resize_probe", None)
        if probe is not None:
            self.apply_keyboard_layout_scale(
                probe.get_width(),
                probe.get_height(),
            )
        return False

    def apply_keyboard_layout_scale(self, width, height):
        """Tastatur proportional auf den tatsächlich verfügbaren Platz skalieren."""
        reference_width = max(
            1,
            int(getattr(self, "keyboard_reference_width", 1)),
        )
        reference_height = max(
            1,
            int(getattr(self, "keyboard_reference_height", 1)),
        )
        if width <= 1 or height <= 1:
            return

        # Ein kleiner Sicherheitsrand verhindert Scrollbalken durch Rundung.
        scale = 0.985 * min(
            float(width) / reference_width,
            float(height) / reference_height,
        )
        scale = max(0.45, min(scale, 6.0))

        old_scale = getattr(self, "keyboard_scale", None)
        if old_scale is not None and abs(scale - old_scale) < 0.01:
            return
        self.keyboard_scale = scale

        font_size = max(6.0, 10.0 * scale)
        for key, base_width, base_height in self.keyboard_key_geometry:
            key.set_size_request(
                max(10, int(round(base_width * scale))),
                max(10, int(round(base_height * scale))),
            )
            attrs = Pango.AttrList()
            attrs.insert(
                Pango.attr_size_new_absolute(
                    int(round(font_size * Pango.SCALE))
                )
            )
            key.set_attributes(attrs)

        for spacer, base_width, base_height in self.keyboard_spacer_geometry:
            spacer.set_size_request(
                max(1, int(round(base_width * scale))),
                max(1, int(round(base_height * scale))),
            )

        for box, base_spacing in self.keyboard_spacing_boxes:
            box.set_spacing(max(1, int(round(base_spacing * scale))))

        margin = max(2, int(round(8 * scale)))
        self.keyboard_board.set_margin_start(margin)
        self.keyboard_board.set_margin_end(margin)
        self.keyboard_board.set_margin_bottom(margin)

    def keyboard_layout(self):
        K = lambda l, a=None, w=32: (l, tuple(a or (l,)), w)

        # Deutsches ISO-QWERTZ-Layout.
        # Die Aliase entsprechen den GDK-Keyval-Namen eines deutschen
        # XKB-Layouts, damit Umlaute/Sondertasten korrekt erkannt werden.
        return [
            [
                K("Esc", ("Escape",), 34),
                K("F1"), K("F2"), K("F3"), K("F4"),
                K("F5"), K("F6"), K("F7"), K("F8"),
                K("F9"), K("F10"), K("F11"), K("F12"),
                K("Druck", ("Print",), 40),
                K("Rollen", ("Scroll_Lock",), 42),
                K("Pause", ("Pause",), 40),
            ],
            [
                K("^", ("dead_circumflex", "degree")),
                K("1", ("1", "exclam")),
                K("2", ("2", "quotedbl")),
                K("3", ("3", "section")),
                K("4", ("4", "dollar")),
                K("5", ("5", "percent")),
                K("6", ("6", "ampersand")),
                K("7", ("7", "slash")),
                K("8", ("8", "parenleft")),
                K("9", ("9", "parenright")),
                K("0", ("0", "equal")),
                K("ß", ("ssharp", "question")),
                K("´", ("dead_acute", "dead_grave")),
                K("Backspace", ("BackSpace",), 62),
                K("Einfg", ("Insert",), 38),
                K("Pos1", ("Home",), 40),
                K("Bild↑", ("Page_Up",), 40),
            ],
            [
                K("Tab", ("Tab", "ISO_Left_Tab"), 50),
                K("Q", ("q",)),
                K("W", ("w",)),
                K("E", ("e",)),
                K("R", ("r",)),
                K("T", ("t",)),
                K("Z", ("z",)),
                K("U", ("u",)),
                K("I", ("i",)),
                K("O", ("o",)),
                K("P", ("p",)),
                K("Ü", ("udiaeresis", "Udiaeresis")),
                K("+", ("plus", "asterisk", "asciitilde")),
                K("Entf", ("Delete",), 38),
                K("Ende", ("End",), 40),
                K("Bild↓", ("Page_Down",), 40),
            ],
            [
                K("Caps", ("Caps_Lock",), 58),
                K("A", ("a",)),
                K("S", ("s",)),
                K("D", ("d",)),
                K("F", ("f",)),
                K("G", ("g",)),
                K("H", ("h",)),
                K("J", ("j",)),
                K("K", ("k",)),
                K("L", ("l",)),
                K("Ö", ("odiaeresis", "Odiaeresis")),
                K("Ä", ("adiaeresis", "Adiaeresis")),
                K("#", ("numbersign", "apostrophe")),
                K("Enter", ("Return",), 70),
            ],
            [
                K("Shift L", ("Shift_L",), 70),
                K("<", ("less", "greater", "bar")),
                K("Y", ("y",)),
                K("X", ("x",)),
                K("C", ("c",)),
                K("V", ("v",)),
                K("B", ("b",)),
                K("N", ("n",)),
                K("M", ("m",)),
                K(",", ("comma", "semicolon")),
                K(".", ("period", "colon")),
                K("-", ("minus", "underscore")),
                K("Shift R", ("Shift_R",), 78),
            ],
            [
                K("Strg L", ("Control_L",), 48),
                K("Super L", ("Super_L", "Meta_L"), 52),
                K("Alt L", ("Alt_L",), 44),
                K("Space", ("space",), 180),
                K("AltGr", ("ISO_Level3_Shift", "Alt_R"), 48),
                K("Super R", ("Super_R", "Meta_R"), 52),
                K("Menu", ("Menu",), 44),
                K("Strg R", ("Control_R",), 48),
            ],
        ]

    def block_super_for_keyboard_test(self):
        """Einzelne SUPER-Taste während des Tastatur-Tests blockieren.

        GNOME/Mutter verwendet ``org.gnome.mutter overlay-key`` für das
        Öffnen der Übersicht durch einen einzelnen Super-Tastendruck.
        Der bisherige Wert wird gespeichert und nach dem Test exakt
        wiederhergestellt. Ein kleiner externer Wächter stellt den Wert
        zusätzlich wieder her, falls Hardware Check unerwartet beendet wird.
        """
        if self.super_block_active:
            return
        if self.stack.get_visible_child_name() != "keyboard":
            return

        gsettings = shutil.which("gsettings")
        if not gsettings:
            log("SUPER-Blockierung: gsettings nicht gefunden")
            return

        try:
            get_proc = subprocess.run(
                [
                    gsettings,
                    "get",
                    "org.gnome.mutter",
                    "overlay-key",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=1.5,
                check=False,
            )
            original = get_proc.stdout.strip()
            if get_proc.returncode != 0 or not original:
                log("SUPER-Blockierung: overlay-key konnte nicht gelesen werden")
                return
            if self.stack.get_visible_child_name() != "keyboard":
                return

            set_proc = subprocess.run(
                [
                    gsettings,
                    "set",
                    "org.gnome.mutter",
                    "overlay-key",
                    "",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
                check=False,
            )
            if set_proc.returncode != 0:
                log("SUPER-Blockierung: overlay-key konnte nicht deaktiviert werden")
                return

            self.super_overlay_original = original
            self.super_block_active = True

            # Wächter: Falls Hardware Check hart beendet wird, stellt ein
            # unabhängiger Prozess den ursprünglichen GNOME-Wert wieder her.
            helper_code = (
                "import os,subprocess,sys,time;"
                "pid=int(sys.argv[1]);original=sys.argv[2];"
                "path=f'/proc/{pid}';"
                "\nwhile os.path.exists(path): time.sleep(0.25)"
                "\nsubprocess.run(['gsettings','set','org.gnome.mutter',"
                "'overlay-key',original],stdin=subprocess.DEVNULL,"
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,"
                "check=False)"
            )
            try:
                self.super_restore_helper = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        helper_code,
                        str(os.getpid()),
                        original,
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:
                self.super_restore_helper = None

            # Die Seite kann während des gsettings-set verlassen worden sein.
            # Erst nach Anlage des Crash-Wächters den normalen Restore-Pfad
            # verwenden; der Wächter endet nur bei erfolgreichem Restore.
            if self.stack.get_visible_child_name() != "keyboard":
                self.restore_keyboard_shortcuts_with_retries()

            log("Tastatur-Test: einzelne SUPER-Taste für GNOME blockiert")
        except Exception as exc:
            log(f"SUPER-Blockierung Fehler: {exc}")

    def restore_super_after_keyboard_test(self):
        if not self.super_block_active:
            return

        gsettings = shutil.which("gsettings")
        restored = False

        if gsettings and self.super_overlay_original:
            try:
                p = subprocess.run(
                    [
                        gsettings,
                        "set",
                        "org.gnome.mutter",
                        "overlay-key",
                        self.super_overlay_original,
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1.5,
                    check=False,
                )
                restored = p.returncode == 0
            except Exception:
                restored = False

        if restored:
            helper = self.super_restore_helper
            self.super_restore_helper = None
            if helper is not None:
                try:
                    helper.terminate()
                except Exception:
                    pass

            self.super_overlay_original = None
            self.super_block_active = False
            log("Tastatur-Test: SUPER-Taste wieder normal aktiviert")

    def block_alt_space_for_keyboard_test(self):
        """GNOME-Fenstermenü auf ALT+SPACE während des Tastatur-Tests blockieren.

        Die eigentlichen Tastendrücke werden weiterhin direkt über /dev/input
        erkannt und können deshalb ganz normal als ALT L + Space geprüft werden.
        """
        if self.alt_space_block_active:
            return

        gsettings = shutil.which("gsettings")
        if not gsettings:
            log("ALT+SPACE-Blockierung: gsettings nicht gefunden")
            return

        schema = "org.gnome.desktop.wm.keybindings"
        key = "activate-window-menu"

        try:
            get_proc = subprocess.run(
                [gsettings, "get", schema, key],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=1.5,
                check=False,
            )
            original = get_proc.stdout.strip()
            if get_proc.returncode != 0 or not original:
                log("ALT+SPACE-Blockierung: ursprüngliche Belegung konnte nicht gelesen werden")
                return

            set_proc = subprocess.run(
                [gsettings, "set", schema, key, "[]"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
                check=False,
            )
            if set_proc.returncode != 0:
                log("ALT+SPACE-Blockierung: activate-window-menu konnte nicht deaktiviert werden")
                return

            self.alt_space_original = original
            self.alt_space_block_active = True

            # Externer Wächter stellt die ursprüngliche Belegung auch dann
            # wieder her, wenn Hardware Check unerwartet beendet wird.
            helper_code = (
                "import os,subprocess,sys,time;"
                "pid=int(sys.argv[1]);original=sys.argv[2];"
                "path=f'/proc/{pid}';"
                "\nwhile os.path.exists(path): time.sleep(0.25)"
                "\nsubprocess.run(['gsettings','set',"
                "'org.gnome.desktop.wm.keybindings','activate-window-menu',"
                "original],stdin=subprocess.DEVNULL,"
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,"
                "check=False)"
            )
            try:
                self.alt_space_restore_helper = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        helper_code,
                        str(os.getpid()),
                        original,
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:
                self.alt_space_restore_helper = None

            log("Tastatur-Test: GNOME ALT+SPACE-Fenstermenü blockiert")
        except Exception as exc:
            log(f"ALT+SPACE-Blockierung Fehler: {exc}")

    def restore_alt_space_after_keyboard_test(self):
        if not self.alt_space_block_active:
            return

        gsettings = shutil.which("gsettings")
        restored = False

        if gsettings and self.alt_space_original:
            try:
                p = subprocess.run(
                    [
                        gsettings,
                        "set",
                        "org.gnome.desktop.wm.keybindings",
                        "activate-window-menu",
                        self.alt_space_original,
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1.5,
                    check=False,
                )
                restored = p.returncode == 0
            except Exception:
                restored = False

        if restored:
            helper = self.alt_space_restore_helper
            self.alt_space_restore_helper = None
            if helper is not None:
                try:
                    helper.terminate()
                except Exception:
                    pass

            self.alt_space_original = None
            self.alt_space_block_active = False
            log("Tastatur-Test: GNOME ALT+SPACE wieder normal aktiviert")

    def block_super_arrows_for_keyboard_test(self):
        """SUPER+Pfeiltasten während des Tastatur-Tests neutralisieren.

        Ressourcenschonend/schnell: Pro relevantem Schema nur EIN
        ``gsettings list-recursively`` statt früher je Key einen eigenen
        ``gsettings get``-Prozess. Dadurch reagiert K deutlich schneller.
        """
        if self.super_arrow_block_active:
            return

        gsettings = shutil.which("gsettings")
        if not gsettings:
            log("SUPER+Pfeile-Blockierung: gsettings nicht gefunden")
            return

        schemas = (
            "org.gnome.shell.extensions.tiling-assistant",
            "org.gnome.mutter.keybindings",
            "org.gnome.desktop.wm.keybindings",
        )
        directions = ("Left", "Right", "Up", "Down")
        saved = []

        for schema in schemas:
            try:
                proc = subprocess.run(
                    [gsettings, "list-recursively", schema],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=2.0,
                    check=False,
                )
            except Exception:
                continue

            if proc.returncode != 0:
                continue

            for raw_line in (proc.stdout or "").splitlines():
                # Format:
                # org.example.schema key ['<Super>Left']
                parts = raw_line.strip().split(None, 2)
                if len(parts) != 3:
                    continue

                _, key, original = parts
                original = original.strip()

                # Nur Array-Keybindings anfassen, die tatsächlich SUPER plus
                # eine Pfeilrichtung enthalten.
                if not original.startswith("["):
                    continue
                if "<Super>" not in original:
                    continue
                if not any(direction in original for direction in directions):
                    continue

                try:
                    set_proc = subprocess.run(
                        [gsettings, "set", schema, key, "[]"],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=1.0,
                        check=False,
                    )
                except Exception:
                    continue

                if set_proc.returncode == 0:
                    saved.append((schema, key, original))
                    log(
                        "Tastatur-Test: SUPER+Pfeil-Binding blockiert: "
                        f"{schema} {key} = {original}"
                    )

        if not saved:
            log("SUPER+Pfeile-Blockierung: keine aktiven passenden Bindings gefunden")
            return

        self.super_arrow_bindings_original = saved
        self.super_arrow_block_active = True

        # Unabhängiger Restore-Wächter für einen unerwarteten HC-Abbruch.
        helper_code = (
            "import json,os,subprocess,sys,time;"
            "pid=int(sys.argv[1]);items=json.loads(sys.argv[2]);"
            "path=f'/proc/{pid}';"
            "\nwhile os.path.exists(path): time.sleep(0.25)"
            "\nfor schema,key,value in items:"
            "\n subprocess.run(['gsettings','set',schema,key,value],"
            "stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,"
            "stderr=subprocess.DEVNULL,check=False)"
        )
        try:
            self.super_arrow_restore_helper = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    helper_code,
                    str(os.getpid()),
                    json.dumps(saved),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception:
            self.super_arrow_restore_helper = None

        log(
            f"Tastatur-Test: {len(saved)} SUPER+Pfeil-Binding(s) "
            "temporär deaktiviert"
        )

    def restore_super_arrows_after_keyboard_test(self):
        if not self.super_arrow_block_active:
            return

        gsettings = shutil.which("gsettings")
        all_restored = True

        if not gsettings:
            all_restored = False
        else:
            for schema, key, original in self.super_arrow_bindings_original:
                try:
                    proc = subprocess.run(
                        [gsettings, "set", schema, key, original],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=1.0,
                        check=False,
                    )
                    if proc.returncode != 0:
                        all_restored = False
                except Exception:
                    all_restored = False

        if all_restored:
            helper = self.super_arrow_restore_helper
            self.super_arrow_restore_helper = None
            if helper is not None:
                try:
                    helper.terminate()
                except Exception:
                    pass

            count = len(self.super_arrow_bindings_original)
            self.super_arrow_bindings_original = []
            self.super_arrow_block_active = False
            log(
                f"Tastatur-Test: {count} SUPER+Pfeil-Binding(s) "
                "wiederhergestellt"
            )

    @staticmethod
    def should_block_keyboard_test_binding(value):
        """Nur bekannte, im Tastatur-Test störende Accelerators auswählen."""
        blocked = {
            "<alt>tab",
            "<shift><alt>tab",
            "<alt>f4",
            "<alt>space",
            "<super>left",
            "<super>right",
            "<super>up",
            "<super>down",
            "print",
            "<shift>print",
            "<alt>print",
        }

        try:
            accelerators = ast.literal_eval(value)
        except (SyntaxError, ValueError):
            return False

        return (
            isinstance(accelerators, (list, tuple))
            and any(
                isinstance(accelerator, str)
                and accelerator.lower() in blocked
                for accelerator in accelerators
            )
        )

    def block_desktop_shortcuts_for_keyboard_test(self):
        """GNOME-Desktop-Shortcuts temporär deaktivieren, ohne Input-Grab.

        Ausschließlich bekannte störende Kombinationen werden verändert.
        Power-, Sleep-, Media- und Helligkeits-Tasten bleiben unangetastet.
        """
        if self.desktop_shortcut_block_active:
            return False
        if self.stack.get_visible_child_name() != "keyboard":
            return False

        gsettings = shutil.which("gsettings")
        if not gsettings:
            log("Keyboard-Test: gsettings nicht gefunden")
            return False

        schemas = (
            "org.gnome.shell.keybindings",
            "org.gnome.desktop.wm.keybindings",
            "org.gnome.mutter.keybindings",
            "org.gnome.settings-daemon.plugins.media-keys",
            "org.gnome.shell.extensions.tiling-assistant",
        )

        saved = []

        for schema in schemas:
            # Testet gleichzeitig, ob das Schema auf diesem Ubuntu existiert.
            try:
                proc = subprocess.run(
                    [gsettings, "list-recursively", schema],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=2.0,
                    check=False,
                )
            except Exception:
                continue

            if proc.returncode != 0:
                continue

            for raw_line in (proc.stdout or "").splitlines():
                parts = raw_line.strip().split(None, 2)
                if len(parts) != 3:
                    continue

                _, key, original = parts
                original = original.strip()

                # Nur echte Keybinding-Arrays anfassen.
                if not original.startswith("[") or not original.endswith("]"):
                    continue
                if original == "[]":
                    continue
                if not self.should_block_keyboard_test_binding(original):
                    continue
                if self.stack.get_visible_child_name() != "keyboard":
                    break

                try:
                    set_proc = subprocess.run(
                        [gsettings, "set", schema, key, "[]"],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=1.0,
                        check=False,
                    )
                except Exception:
                    continue

                if set_proc.returncode == 0:
                    saved.append((schema, key, original))
                    # Sofort veröffentlichen, damit ein paralleler Seitenwechsel
                    # auch einen gerade gesetzten Wert zuverlässig restauriert.
                    self.desktop_shortcut_bindings_original = saved
                    self.desktop_shortcut_block_active = True

        # Einzelne SUPER-Taste ist kein Array-Keybinding und wird weiterhin
        # über die bestehende overlay-key-Funktion neutralisiert.
        self.desktop_shortcut_bindings_original = saved
        self.desktop_shortcut_block_active = bool(saved)

        if saved:
            helper_code = (
                "import json,os,subprocess,sys,time;"
                "pid=int(sys.argv[1]);items=json.loads(sys.argv[2]);"
                "path=f'/proc/{pid}';"
                "\nwhile os.path.exists(path): time.sleep(0.25)"
                "\nfor schema,key,value in items:"
                "\n subprocess.run(['gsettings','set',schema,key,value],"
                "stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,"
                "stderr=subprocess.DEVNULL,check=False)"
            )
            try:
                self.desktop_shortcut_restore_helper = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        helper_code,
                        str(os.getpid()),
                        json.dumps(saved),
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:
                self.desktop_shortcut_restore_helper = None

            # Falls die Seite während der GSettings-Abfrage verlassen wurde,
            # nach Anlage des Crash-Wächters unverzüglich restaurieren.
            if self.stack.get_visible_child_name() != "keyboard":
                self.restore_keyboard_shortcuts_async()

        log(
            f"Keyboard-Test: {len(saved)} Desktop-Keybinding(s) "
            "temporär deaktiviert · Input bleibt read-only"
        )
        return False

    def restore_keyboard_shortcuts_with_retries(self, force=False):
        """Alle HC-Sperren mit kurzen Wiederholungsversuchen restaurieren."""
        pauses = (0.15, 0.30)
        for attempt in range(3):
            # Ein alter asynchroner Restore darf einen sofort erneut
            # geöffneten Keyboard-Test nicht entsperren. Die bestehenden
            # Flags und Crash-Wächter bleiben für das spätere Verlassen aktiv.
            if (
                not force
                and self.stack.get_visible_child_name() == "keyboard"
            ):
                log(
                    "Keyboard-Test: Shortcut-Restore ausgesetzt, weil der "
                    "Keyboard-Test wieder aktiv ist"
                )
                return False

            try:
                self.restore_super_after_keyboard_test()
                self.restore_desktop_shortcuts_after_keyboard_test()
            except Exception as exc:
                log(
                    "Keyboard-Test: Shortcut-Restore Versuch "
                    f"{attempt + 1} fehlgeschlagen: {exc}"
                )

            # Die Keyboard-Seite kann erst nach der Prüfung am Anfang des
            # Versuchs erneut geöffnet worden sein. Beide Block-Funktionen
            # immer aufrufen: Ihre eigenen Flags reparieren auch einen
            # gemischten Zustand, in dem nur eine Sperrkategorie aktiv ist.
            if (
                not force
                and self.stack.get_visible_child_name() == "keyboard"
            ):
                log(
                    "Keyboard-Test: nach parallelem Restore erneut "
                    "geöffnet; Shortcut-Sperren werden neu angewendet"
                )
                self.block_super_for_keyboard_test()
                self.block_desktop_shortcuts_for_keyboard_test()
                return False

            if not (
                self.super_block_active
                or self.desktop_shortcut_block_active
            ):
                return True
            if attempt < len(pauses):
                time.sleep(pauses[attempt])

        log(
            "FEHLER: Keyboard-Test-Shortcuts konnten nach 3 Versuchen "
            "nicht vollständig wiederhergestellt werden; externe "
            "Restore-Wächter bleiben aktiv"
        )
        return False

    def restore_keyboard_shortcuts_async(self):
        """Desktop-Keybindings nach sichtbarem Wechsel im Hintergrund restaurieren."""
        def worker():
            self.restore_keyboard_shortcuts_with_retries()

        threading.Thread(target=worker, daemon=True).start()
        return False

    def restore_desktop_shortcuts_after_keyboard_test(self):
        if not self.desktop_shortcut_block_active:
            return

        gsettings = shutil.which("gsettings")
        all_restored = bool(gsettings)

        if gsettings:
            for schema, key, original in self.desktop_shortcut_bindings_original:
                try:
                    proc = subprocess.run(
                        [gsettings, "set", schema, key, original],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=1.0,
                        check=False,
                    )
                    if proc.returncode != 0:
                        all_restored = False
                except Exception:
                    all_restored = False

        if all_restored:
            helper = self.desktop_shortcut_restore_helper
            self.desktop_shortcut_restore_helper = None
            if helper is not None:
                try:
                    helper.terminate()
                except Exception:
                    pass

            count = len(self.desktop_shortcut_bindings_original)
            self.desktop_shortcut_bindings_original = []
            self.desktop_shortcut_block_active = False
            log(
                f"Keyboard-Test: {count} Desktop-Keybinding(s) "
                "wiederhergestellt"
            )

    def focus_keyboard_window(self):
        if self.stack.get_visible_child_name() != "keyboard":
            return False

        try:
            self.window.present()
        except Exception:
            pass

        if self.keyboard_focus_widget is not None:
            try:
                self.window.set_focus(self.keyboard_focus_widget)
            except Exception:
                pass
            try:
                self.keyboard_focus_widget.grab_focus()
            except Exception:
                pass

        return False

    def restart_input_monitor_after_keyboard_test(self):
        """Nach jedem Keyboard-Test alle Input-FDs garantiert neu öffnen.

        Selbst wenn ein Gerät oder Treiber ein normales UNGRAB verschluckt,
        beendet das Schließen des gesamten Helferprozesses jeden verbliebenen
        Kernel-Grab. Der selbstheilende Listener startet direkt danach wieder
        ohne exklusiven Grab.
        """
        if self.keyboard_input_grab_desired:
            return False

        proc = self.global_input_proc
        if proc is not None and proc.poll() is None:
            log(
                "Keyboard-Test: Input-Helfer wird nach Testende vorsorglich "
                "neu gestartet, damit alle Grabs sicher gelöst sind"
            )
            self.stop_input_monitor_process(proc)

        return False

    def finish_keyboard_test_from_monitor(self):
        """ESC x3 wurde direkt im exklusiven Input-Helfer erkannt."""
        if self.stack.get_visible_child_name() != "keyboard":
            return False

        log("Tastatur-Test: ESC x3 vom Input-Helfer bestätigt")
        self.show_overview()
        return False

    def show_keyboard(self, *_):
        if self.stack.get_visible_child_name() == "keyboard":
            return False

        self.keyboard_escape_count = 0
        self.keyboard_escape_last_at = 0.0

        # Sofort anzeigen. /dev/input bleibt vollständig read-only:
        # Es wird unter keinen Umständen ein EVIOCGRAB ausgelöst.
        self.stack.set_visible_child_name("keyboard")
        self.window.set_default_size(860, 360)
        GLib.idle_add(self.refresh_keyboard_layout_scale)
        GLib.timeout_add(120, self.refresh_keyboard_layout_scale)

        # Einzelne Super-Taste sowie die normalen Desktop-Keybindings werden
        # unabhängig vom GTK-Thread deaktiviert. Dadurch bleibt K schnell.
        threading.Thread(
            target=self.block_super_for_keyboard_test,
            daemon=True,
        ).start()
        threading.Thread(
            target=self.block_desktop_shortcuts_for_keyboard_test,
            daemon=True,
        ).start()

        self.focus_keyboard_window()
        GLib.idle_add(self.focus_keyboard_window)
        GLib.timeout_add(120, self.focus_keyboard_window)
        GLib.timeout_add(350, self.focus_keyboard_window)
        return False


    def handle_keyboard_escape_sequence(self):
        now = time.monotonic()

        if (
            self.keyboard_escape_last_at <= 0.0
            or now - self.keyboard_escape_last_at > self.keyboard_escape_window
        ):
            self.keyboard_escape_count = 1
        else:
            self.keyboard_escape_count += 1

        self.keyboard_escape_last_at = now

        if self.keyboard_escape_count >= 3:
            self.keyboard_escape_count = 0
            self.keyboard_escape_last_at = 0.0
            log("Tastatur-Test: mit ESC x3 beendet")
            self.show_overview()
            return True

        log(
            f"Tastatur-Test: ESC {self.keyboard_escape_count}/3 "
            f"(Fenster {self.keyboard_escape_window:.1f}s)"
        )
        return False

    def show_overview(self, *_):
        # HC4.5.46: Beim Verlassen des Keyboard-Tests zuerst SOFORT zurück
        # zur Übersicht wechseln. Die langsameren gsettings-Restores laufen
        # anschließend im Hintergrund.
        leaving_keyboard = (
            self.stack is not None
            and self.stack.get_visible_child_name() == "keyboard"
        )

        if (
            self.stack.get_visible_child_name() == "benchmarks"
            and self.test_proc is not None
            and self.test_proc.poll() is None
        ):
            self.cancel_test()

        self.stack.set_visible_child_name("overview")
        self.window.set_default_size(860, 360)

        if leaving_keyboard:
            # Oberfläche ist bereits zurück. Restore läuft ohne sichtbare
            # Verzögerung im Hintergrund weiter.
            self.restore_keyboard_shortcuts_async()
        else:
            self.restore_super_after_keyboard_test()
            self.restore_desktop_shortcuts_after_keyboard_test()

    def reset_keyboard(self, *_):
        self.key_tested.clear()
        self.key_phase.clear()

        for w in self.key_widgets.values():
            w.remove_css_class("key-tested")
            w.remove_css_class("key-tested-blue")

        self.update_keyboard()
        log("Keyboard-Test zurückgesetzt")
    def mark_keyboard_alias(self, alias, pressed=True):
        if not alias:
            return False

        lookup = alias.lower() if len(alias) == 1 and alias.isalpha() else alias
        key_id = self.key_aliases.get(lookup)
        if not key_id:
            return False

        widget = self.key_widgets[key_id]

        # Ab dem ersten Druck zählt die Taste dauerhaft als getestet.
        if pressed:
            self.key_tested.add(key_id)

        widget.remove_css_class("key-tested")
        widget.remove_css_class("key-tested-blue")

        # Live-Farbe:
        # gedrückt/gehalten = blau
        # losgelassen = grün
        if pressed:
            widget.add_css_class("key-tested-blue")
        elif key_id in self.key_tested:
            widget.add_css_class("key-tested")

        self.update_keyboard()
        return True

    def handle_keyboard_linux_keycode(self, code, state):
        if self.stack.get_visible_child_name() != "keyboard":
            return False

        alias = self.keyboard_linux_aliases.get(code)
        pressed = state == "down"

        if alias:
            self.mark_keyboard_alias(alias, pressed=pressed)

        # HC4.5.45: Der Input-Monitor ist ausschließlich read-only.
        # ESC x3 wird deshalb immer hier ausgewertet.
        if pressed:
            if code == 1:
                self.handle_keyboard_escape_sequence()
            else:
                self.keyboard_escape_count = 0
                self.keyboard_escape_last_at = 0.0

        return False

    def update_keyboard(self):
        total, tested = len(self.key_widgets), len(self.key_tested)
        keyboard_passed = tested >= 75

        if hasattr(self, "keyboard_progress"):
            # Im Tastatur-Test bleibt nur der neutrale Zähler stehen.
            # Die Tasten selbst zeigen den Live-Zustand blau/grün.
            self.keyboard_progress.set_text(f"{tested} von {total} getestet")
            self.keyboard_progress.remove_css_class("status-green")
            self.keyboard_progress.remove_css_class("status-orange")

        if hasattr(self, "keyboard_summary"):
            color = (
                "green"
                if keyboard_passed
                else "orange"
            )

            for widget in (
                self.keyboard_status_dot,
                self.keyboard_status_name,
                self.keyboard_summary,
            ):
                for cls in (
                    "status-green",
                    "status-orange",
                    "status-red",
                    "status-blue",
                ):
                    widget.remove_css_class(cls)
                widget.add_css_class("status-" + color)

            self.keyboard_summary.set_text(
                f"{tested} GETESTET"
            )

    def on_key_released(self, controller, keyval, keycode, state):
        if self.stack.get_visible_child_name() != "keyboard":
            return

        # Bei aktivem /dev/input-Monitor kommt das Release bereits über den
        # globalen Pfad. GTK ist nur der Fallback, damit nichts doppelt läuft.
        if self.global_input_active:
            return

        name = Gdk.keyval_name(keyval) or ""
        self.mark_keyboard_alias(name, pressed=False)

    def do_shutdown(self):
        self.wlan_diag_stop.set()
        self.stop_power_dialog_helper()
        self.restore_keyboard_shortcuts_with_retries(force=True)
        self.restore_alt_space_after_keyboard_test()
        self.restore_super_arrows_after_keyboard_test()
        if self.info_window is not None:
            try:
                self.info_window.destroy()
            except Exception:
                pass
            self.info_window = None
        if self.hotkeys_window is not None:
            try:
                self.hotkeys_window.destroy()
            except Exception:
                pass
            self.hotkeys_window = None
        if self.update_window is not None:
            try:
                self.update_window.destroy()
            except Exception:
                pass
            self.update_window = None
        self.global_input_stop.set()
        self.stop_input_monitor_process(self.global_input_proc)
        self.stop_touchpad_click_monitors()
        self.stop_test_process()
        # Update-Prozess NICHT beenden: Nach erfolgreicher Installation muss
        # der externe Helfer Hardware Check schließen und den Kiosk neu starten
        # können. Er läuft bewusst in einer eigenen Prozessgruppe.
        log("Hardware Check beendet.")
        Gtk.Application.do_shutdown(self)


    def on_key(self, controller, keyval, keycode, state):
        name = Gdk.keyval_name(keyval) or ""

        if state & Gdk.ModifierType.CONTROL_MASK:
            if name.lower() == "w":
                log("Beendet per Strg+W")
                self.quit()
                return True
            if name.lower() == "q":
                log("Strg+Q: alle Uwuntu-Diagnosefenster beenden")
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

        visible = self.stack.get_visible_child_name()

        # Das zweite Benchmark-Fenster bleibt bewusst auf seine Aufgabe
        # beschränkt. Es darf keine Keyboard-/Info-/Update-Dialoge der
        # normalen Hardware-Check-Instanz öffnen.
        if BENCHMARK_WINDOW_MODE:
            if name == "Escape":
                if self.test_proc is not None and self.test_proc.poll() is None:
                    self.cancel_test()
                return True

            audio_shortcuts = {
                "Left": "audio-left",
                "Up": "audio-both",
                "Right": "audio-right",
                "Down": "audio-auto",
            }
            action = audio_shortcuts.get(name)
            if action:
                self.handle_global_hotkey(action)
                return True

            lower_name = name.lower()
            benchmark_shortcuts = {
                "b": "benchmark",
                "r": "ram",
                "a": "all",
            }
            action = benchmark_shortcuts.get(lower_name)
            if action:
                self.handle_global_hotkey(action)
                return True
            return False

        # ESC auf der Benchmark-Seite bricht einen laufenden CPU-/RAM-Test ab
        # und geht danach zurück zur Übersicht.
        if name == "Escape" and visible == "benchmarks":
            if self.test_proc is not None and self.test_proc.poll() is None:
                self.cancel_test()
            if not BENCHMARK_WINDOW_MODE:
                self.show_overview()
            return True

        # Im Tastatur-Test übernimmt bei aktivem /dev/input-Monitor dieser
        # ALLE Prüftasten. Das verhindert doppelte Markierungen, wenn Hardware
        # Check selbst den Fokus hat.
        if visible == "keyboard" and self.global_input_active:
            return True

        # GTK-Fallback ohne globalen Monitor: ESC ebenfalls markieren und
        # anschließend für die 3er-Folge zählen.
        if name == "Escape" and visible == "keyboard":
            self.mark_keyboard_alias(name, pressed=True)
            self.handle_keyboard_escape_sequence()
            return True

        # Fallback für Systeme, auf denen der globale /dev/input-Monitor
        # nicht verfügbar ist: Hat Hardware Check selbst den Fokus, werden die
        # vier Audio-Pfeiltasten trotzdem an den separaten Audio Test gereicht.
        if not self.global_input_active and visible != "keyboard":
            audio_shortcuts = {
                "Left": "audio-left",
                "Up": "audio-both",
                "Right": "audio-right",
                "Down": "audio-auto",
            }
            action = audio_shortcuts.get(name)
            if action:
                self.handle_global_hotkey(action)
                return True

        # B/R/A sind globale Benchmark-Hotkeys und werden auch dann
        # an das separate Benchmark-Fenster gereicht, wenn der normale HC
        # selbst Fokus hat. Der /dev/input-Pfad deckt alle anderen Fenster ab.
        # Im aktiven Tastatur-Test bleiben Buchstaben reine Prüftasten.
        lower_name = name.lower()
        benchmark_shortcuts = {
            "b": "benchmark",
            "r": "ram",
            "a": "all",
        }
        benchmark_action = benchmark_shortcuts.get(lower_name)
        if benchmark_action and visible != "keyboard":
            self.handle_global_hotkey(benchmark_action)
            return True

        if lower_name == "k" and visible != "keyboard":
            self.handle_global_hotkey("keyboard")
            return True
        if lower_name == "i" and visible != "keyboard":
            self.handle_global_hotkey("info")
            return True
        if lower_name == "u" and visible != "keyboard":
            self.handle_global_hotkey("update")
            return True
        if lower_name == "g" and visible != "keyboard":
            self.handle_global_hotkey("warranty")
            return True
        if lower_name == "t" and visible != "keyboard":
            self.handle_global_hotkey("touch")
            return True
        if (
            lower_name == "d"
            and visible != "keyboard"
            and not (state & Gdk.ModifierType.CONTROL_MASK)
        ):
            self.handle_global_hotkey("display")
            return True
        if name == "F1" and visible != "keyboard":
            self.handle_global_hotkey("hotkeys")
            return True

        # Normale Tasten nur dann als Tastaturtest auswerten, wenn
        # ausdrücklich die Seite "TASTATUR TEST" geöffnet wurde.
        # Auf der Hardware-Check-Übersicht wird nichts mitgezählt.
        if self.stack.get_visible_child_name() != "keyboard":
            return False

        if name != "Escape":
            # Jede andere Taste unterbricht eine angefangene ESC-x3-Folge.
            self.keyboard_escape_count = 0
            self.keyboard_escape_last_at = 0.0

        if self.mark_keyboard_alias(name, pressed=True):
            # Verhindert insbesondere, dass SPACE oder ENTER zusätzlich
            # irgendeine GTK-Button-Aktion auslösen.
            return True

        return False


# ---------------------------------------------------------------------------
# USB Port Mapper
# Separater Rohdaten-Diagnosemodus für schwer auflösbare USB-C/USB-A-
# Companion-Topologien. Normaler Hardware Check bleibt davon unberührt.
# Start: hardware-check.sh --usb-map
# ---------------------------------------------------------------------------

USB_MAPPER_PORTS = (
    "USB-C Port 1",
    "USB-A Port 2",
    "USB-A Port 3",
    "USB-C Port 4",
)


def usb_mapper_cmd(args, timeout=5):
    try:
        proc = subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        return proc.stdout.strip()
    except Exception as exc:
        return f"<Fehler: {exc}>"


def usb_mapper_jsonable(value):
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, set):
        return sorted(usb_mapper_jsonable(item) for item in value)
    if isinstance(value, dict):
        return {
            str(key): usb_mapper_jsonable(item)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [usb_mapper_jsonable(item) for item in value]
    return value


def usb_mapper_file_values(path, names):
    result = {}
    for name in names:
        result[name] = read_text(path / name)
    return result


def usb_mapper_raw_root_ports():
    result = []

    for hub in root_usb_hubs():
        pattern = f"usb{hub['bus']}-port*"
        for port in sorted(
            hub["interface"].glob(pattern),
            key=lambda p: natural_key(p.name),
        ):
            port_no = port_number_from_name(port.name)
            device_name = (
                port_device_name(hub["bus"], port_no)
                if port_no is not None
                else ""
            )
            dev_path = SYS_USB / device_name if device_name else None

            result.append({
                "bus": hub["bus"],
                "root_speed": hub["speed"],
                "name": port.name,
                "port_no": port_no,
                "path": str(port.resolve()),
                "connect_type": read_text(port / "connect_type"),
                "peer": symlink_target(port / "peer"),
                "connector": symlink_target(port / "connector"),
                "device_name": device_name,
                "device_present": bool(
                    dev_path is not None and dev_path.exists()
                ),
                "device_resolved": (
                    str(dev_path.resolve())
                    if dev_path is not None and dev_path.exists()
                    else ""
                ),
            })

    return result


def usb_mapper_usb_devices():
    result = []
    if not SYS_USB.exists():
        return result

    fields = (
        "idVendor",
        "idProduct",
        "manufacturer",
        "product",
        "serial",
        "speed",
        "removable",
        "bDeviceClass",
        "bDeviceSubClass",
        "busnum",
        "devnum",
        "devpath",
        "version",
        "maxchild",
        "authorized",
    )

    for dev in sorted(SYS_USB.iterdir(), key=lambda p: natural_key(p.name)):
        if not re.fullmatch(r"\d+-\d+(?:\.\d+)*", dev.name):
            continue
        if not (dev / "idVendor").exists():
            continue

        item = {
            "name": dev.name,
            "path": str(dev.resolve()),
        }
        item.update(usb_mapper_file_values(dev, fields))
        try:
            item["uevent"] = (dev / "uevent").read_text(
                encoding="utf-8",
                errors="ignore",
            ).strip()
        except Exception:
            item["uevent"] = ""
        result.append(item)

    return result


def usb_mapper_typec():
    result = []
    if not SYS_TYPEC.exists():
        return result

    fields = (
        "data_role",
        "power_role",
        "power_operation_mode",
        "preferred_role",
        "port_type",
        "orientation",
        "usb_power_delivery_revision",
    )

    for port in sorted(SYS_TYPEC.glob("port*"), key=lambda p: natural_key(p.name)):
        if not re.fullmatch(r"port\d+", port.name):
            continue

        partner = port / f"{port.name}-partner"
        item = {
            "name": port.name,
            "path": str(port.resolve()),
            "partner_present": partner.exists(),
            "partner_path": str(partner.resolve()) if partner.exists() else "",
            "connector_symlink": symlink_target(port / "connector"),
        }
        item.update(usb_mapper_file_values(port, fields))

        if partner.exists():
            partner_fields = (
                "accessory_mode",
                "number_of_alternate_modes",
                "supports_usb_power_delivery",
                "usb_power_delivery_revision",
            )
            item["partner"] = usb_mapper_file_values(
                partner,
                partner_fields,
            )
        else:
            item["partner"] = {}

        result.append(item)

    return result


def usb_mapper_discovery():
    try:
        discovery = discover_physical_ports()
        result = {
            "mode": discovery.get("mode"),
            "classification": discovery.get("classification"),
            "raw_group_count": discovery.get("raw_group_count"),
            "physical_total": discovery.get("physical_total"),
            "usb_a_count": discovery.get("usb_a_count"),
            "usb_c_count": discovery.get("usb_c_count"),
            "layout_quirk": discovery.get("layout_quirk"),
            "a_map": discovery.get("a_map", {}),
            "c_map": discovery.get("c_map", {}),
            "a_reserve": discovery.get("a_reserve", []),
            "groups": discovery.get("groups", []),
            "typec": [],
        }
        for port in discovery.get("typec", []):
            result["typec"].append({
                "name": port.get("name"),
                "path": port.get("path"),
                "partner": str(port.get("partner", "")),
                "partner_present": bool(
                    port.get("partner") and port["partner"].exists()
                ),
            })
        return usb_mapper_jsonable(result)
    except Exception as exc:
        return {"error": repr(exc)}


def usb_mapper_snapshot(label, phase):
    boot_name = boot_usb_device_name()
    return {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "monotonic": time.monotonic(),
        "label": label,
        "phase": phase,
        "boot_usb_device_name": boot_name or "",
        "findmnt_cdrom": usb_mapper_cmd(
            ["findmnt", "-n", "-o", "SOURCE,TARGET,FSTYPE,OPTIONS", "/cdrom"]
        ),
        "findmnt_root": usb_mapper_cmd(
            ["findmnt", "-n", "-o", "SOURCE,TARGET,FSTYPE,OPTIONS", "/"]
        ),
        "lsusb": usb_mapper_cmd(["lsusb"]),
        "lsusb_tree": usb_mapper_cmd(["lsusb", "-t"]),
        "lsblk": usb_mapper_cmd([
            "lsblk",
            "-o",
            "NAME,KNAME,PKNAME,TRAN,TYPE,SIZE,MODEL,SERIAL,MOUNTPOINTS",
        ]),
        "raw_root_ports": usb_mapper_raw_root_ports(),
        "usb_devices": usb_mapper_usb_devices(),
        "typec": usb_mapper_typec(),
        "hc_discovery": usb_mapper_discovery(),
    }


def usb_mapper_keyed(items, key):
    return {
        str(item.get(key)): item
        for item in items
        if item.get(key) not in (None, "")
    }


def usb_mapper_delta(before, after):
    before_devs = usb_mapper_keyed(before.get("usb_devices", []), "name")
    after_devs = usb_mapper_keyed(after.get("usb_devices", []), "name")
    before_ports = usb_mapper_keyed(before.get("raw_root_ports", []), "name")
    after_ports = usb_mapper_keyed(after.get("raw_root_ports", []), "name")
    before_typec = usb_mapper_keyed(before.get("typec", []), "name")
    after_typec = usb_mapper_keyed(after.get("typec", []), "name")

    result = {
        "usb_devices_added": sorted(set(after_devs) - set(before_devs)),
        "usb_devices_removed": sorted(set(before_devs) - set(after_devs)),
        "root_port_presence_changed": [],
        "typec_partner_changed": [],
    }

    for name in sorted(set(before_ports) | set(after_ports), key=natural_key):
        old = bool(before_ports.get(name, {}).get("device_present"))
        new = bool(after_ports.get(name, {}).get("device_present"))
        if old != new:
            result["root_port_presence_changed"].append({
                "name": name,
                "from": old,
                "to": new,
                "before": before_ports.get(name, {}),
                "after": after_ports.get(name, {}),
            })

    for name in sorted(set(before_typec) | set(after_typec), key=natural_key):
        old = bool(before_typec.get(name, {}).get("partner_present"))
        new = bool(after_typec.get(name, {}).get("partner_present"))
        if old != new:
            result["typec_partner_changed"].append({
                "name": name,
                "from": old,
                "to": new,
                "before": before_typec.get(name, {}),
                "after": after_typec.get(name, {}),
            })

    return result


def usb_mapper_print_delta(delta):
    added = ", ".join(delta["usb_devices_added"]) or "-"
    removed = ", ".join(delta["usb_devices_removed"]) or "-"
    ports = ", ".join(
        f"{item['name']}:{int(item['from'])}->{int(item['to'])}"
        for item in delta["root_port_presence_changed"]
    ) or "-"
    typec = ", ".join(
        f"{item['name']}:{int(item['from'])}->{int(item['to'])}"
        for item in delta["typec_partner_changed"]
    ) or "-"

    print(f"  Neue USB-Geräte:      {added}")
    print(f"  Entfernte USB-Geräte: {removed}")
    print(f"  Root-Port-Änderungen: {ports}")
    print(f"  Type-C-Partner:       {typec}")


def usb_mapper_choose_boot_port():
    print()
    print("Wo steckt der Uwuntu-Bootstick gerade?")
    for idx, label in enumerate(USB_MAPPER_PORTS, 1):
        print(f"  {idx}) {label}")
    print("  0) anderer / unbekannt")

    while True:
        answer = input("Auswahl [0-4]: ").strip()
        if answer in {"0", "1", "2", "3", "4"}:
            if answer == "0":
                return ""
            return USB_MAPPER_PORTS[int(answer) - 1]
        print("Bitte 0, 1, 2, 3 oder 4 eingeben.")


def usb_mapper_wait(message):
    while True:
        answer = input(message).strip().lower()
        if answer in {"", "enter", "ok", "j", "ja"}:
            return True
        if answer in {"s", "skip", "überspringen", "ueberspringen"}:
            return False
        print("ENTER = weiter, S = diesen Port überspringen")


def run_usb_port_mapper():
    print("=" * 72)
    print(" UWUNTU USB PORT MAPPER")
    print(" Rohdaten-Mapping für USB-A / USB-C / UCSI / xHCI")
    print("=" * 72)
    print()
    print("WICHTIG:")
    print("- Uwuntu-Bootstick NICHT abziehen.")
    print("- Für die Tests möglichst immer denselben zweiten USB-Stick verwenden.")
    print("- Alle anderen externen USB-Geräte nach Möglichkeit vorher abziehen.")
    print("- Das Tool verändert keine USB-Zuordnung im Hardware Check.")
    print()

    boot_label = usb_mapper_choose_boot_port()
    test_ports = [
        label for label in USB_MAPPER_PORTS
        if label != boot_label
    ]

    run_id = time.strftime("%Y%m%d-%H%M%S")
    desktop = Path.home() / "Desktop"
    output_dir = desktop if desktop.exists() else Path.home()
    safe_boot = re.sub(
        r"[^A-Za-z0-9_-]+",
        "_",
        boot_label or "unknown",
    ).strip("_")
    base = output_dir / f"uwuntu-usb-map-{run_id}-boot-{safe_boot}"

    report = {
        "tool": "Uwuntu USB Port Mapper",
        "tool_version": "1.0",
        "started": time.strftime("%Y-%m-%d %H:%M:%S"),
        "boot_label_user": boot_label or "anderer / unbekannt",
        "dmi": {
            "sys_vendor": read_text(Path("/sys/class/dmi/id/sys_vendor")),
            "product_name": read_text(Path("/sys/class/dmi/id/product_name")),
            "product_version": read_text(Path("/sys/class/dmi/id/product_version")),
            "bios_version": read_text(Path("/sys/class/dmi/id/bios_version")),
            "bios_date": read_text(Path("/sys/class/dmi/id/bios_date")),
        },
        "initial_kernel_tail": "\n".join(
            usb_mapper_cmd(["dmesg", "--ctime"], timeout=5).splitlines()[-120:]
        ),
        "steps": [],
    }

    print()
    print("Erste Gesamtsicherung wird aufgenommen ...")
    report["initial"] = usb_mapper_snapshot("START", "initial")
    print(
        "Boot-USB laut Linux:",
        report["initial"].get("boot_usb_device_name") or "nicht erkannt",
    )

    for index, label in enumerate(test_ports, 1):
        print()
        print("=" * 72)
        print(f"TEST {index}/{len(test_ports)}: {label}")
        print("=" * 72)

        if not usb_mapper_wait(
            f"{label}: Testgerät ABZIEHEN/Port frei lassen, dann ENTER "
            "(S = überspringen): "
        ):
            report["steps"].append({
                "port": label,
                "skipped": True,
            })
            print(f"{label} übersprungen.")
            continue

        time.sleep(0.4)
        before = usb_mapper_snapshot(label, "before")

        if not usb_mapper_wait(
            f">>> Jetzt Teststick in {label} EINSTECKEN, "
            "2 Sekunden warten, dann ENTER: "
        ):
            report["steps"].append({
                "port": label,
                "skipped": True,
                "before": before,
            })
            print(f"{label} nach Baseline übersprungen.")
            continue

        time.sleep(0.15)
        inserted_1 = usb_mapper_snapshot(label, "inserted_150ms")
        time.sleep(0.45)
        inserted_2 = usb_mapper_snapshot(label, "inserted_600ms")
        time.sleep(1.0)
        inserted_3 = usb_mapper_snapshot(label, "inserted_1600ms")

        delta_insert = usb_mapper_delta(before, inserted_3)
        print()
        print("Erkannte Änderung beim EINSTECKEN:")
        usb_mapper_print_delta(delta_insert)

        usb_mapper_wait(
            f">>> Teststick aus {label} wieder ABZIEHEN, "
            "2 Sekunden warten, dann ENTER: "
        )
        time.sleep(0.2)
        removed_1 = usb_mapper_snapshot(label, "removed_200ms")
        time.sleep(0.8)
        removed_2 = usb_mapper_snapshot(label, "removed_1000ms")

        delta_remove = usb_mapper_delta(inserted_3, removed_2)
        print()
        print("Erkannte Änderung beim ABZIEHEN:")
        usb_mapper_print_delta(delta_remove)

        report["steps"].append({
            "port": label,
            "skipped": False,
            "before": before,
            "inserted_150ms": inserted_1,
            "inserted_600ms": inserted_2,
            "inserted_1600ms": inserted_3,
            "removed_200ms": removed_1,
            "removed_1000ms": removed_2,
            "delta_insert": delta_insert,
            "delta_remove": delta_remove,
        })

    report["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    report["final_kernel_tail"] = "\n".join(
        usb_mapper_cmd(["dmesg", "--ctime"], timeout=5).splitlines()[-180:]
    )

    json_path = base.with_suffix(".json")
    txt_path = base.with_suffix(".txt")

    json_path.write_text(
        json.dumps(
            usb_mapper_jsonable(report),
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    summary = []
    summary.append("UWUNTU USB PORT MAPPER")
    summary.append("=" * 72)
    summary.append(f"Start: {report['started']}")
    summary.append(f"Boot-Port laut Benutzer: {report['boot_label_user']}")
    summary.append(
        f"Boot-USB laut Linux: "
        f"{report['initial'].get('boot_usb_device_name') or '-'}"
    )
    summary.append(
        f"System: {report['dmi'].get('sys_vendor','')} "
        f"{report['dmi'].get('product_name','')}"
    )
    summary.append("")

    for step in report["steps"]:
        summary.append(step["port"])
        summary.append("-" * 72)
        if step.get("skipped"):
            summary.append("ÜBERSPRUNGEN")
        else:
            summary.append("EINSTECKEN:")
            summary.append(json.dumps(
                step["delta_insert"],
                indent=2,
                ensure_ascii=False,
            ))
            summary.append("ABZIEHEN:")
            summary.append(json.dumps(
                step["delta_remove"],
                indent=2,
                ensure_ascii=False,
            ))
        summary.append("")

    summary.append("Vollständige Rohdaten stehen in:")
    summary.append(str(json_path))
    txt_path.write_text("\n".join(summary) + "\n", encoding="utf-8")

    print()
    print("=" * 72)
    print("FERTIG")
    print("=" * 72)
    print("Bitte diese Datei hier im Chat hochladen:")
    print(f"  {json_path}")
    print()
    print("Kurze Zusammenfassung:")
    print(f"  {txt_path}")
    print()
    input("ENTER beendet den USB Port Mapper ... ")
    return 0



if len(sys.argv) >= 3 and sys.argv[1] == "--global-arrow-monitor":
    try:
        monitor_parent_pid = int(sys.argv[2])
    except (TypeError, ValueError):
        raise SystemExit(2)
    raise SystemExit(run_global_arrow_monitor(monitor_parent_pid))

if len(sys.argv) >= 2 and sys.argv[1] == "--usb-map":
    raise SystemExit(run_usb_port_mapper())

app = App()
raise SystemExit(app.run([]))
PY
if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
    echo "FEHLER: Python GTK4 / PyGObject fehlt."
    echo "Benötigt werden python3-gi und GTK4."
    exit 1
fi

python3 "$TMP_PY" "$@"
