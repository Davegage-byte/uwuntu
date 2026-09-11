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

from gi.repository import Gtk, Gdk, GLib, Pango
from pathlib import Path
import ast
import glob
import json
import os
import fcntl
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import select

APP_ID = "com.david.HardwareCheck"
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

button.benchmark-choice {
    min-height: 44px;
    border-radius: 8px;
    font-size: 12px;
    font-weight: 800;
}

.benchmark-status {
    font-size: 12px;
    font-weight: 800;
}

.benchmark-result {
    font-size: 17px;
    font-weight: 800;
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
def detect_hdmi():
    """DRM-HDMI-Status wie im getesteten Standalone-Test v1.1 lesen.

    Rückgabe ist bewusst nur der aktuelle Hardwarezustand. Ob HDMI bereits
    einmal verbunden war, merkt sich die App separat (hdmi_ever_connected).
    """
    connectors = sorted(glob.glob("/sys/class/drm/*HDMI*/status"))
    if not connectors:
        return "error", "Kein HDMI-Connector erkannt"

    statuses = []
    read_errors = 0
    for status_path in connectors:
        try:
            with open(status_path, "r", encoding="utf-8") as f:
                statuses.append(f.read().strip().lower())
        except OSError:
            read_errors += 1

    if any(status == "connected" for status in statuses):
        return "connected", "HDMI verbunden"

    if read_errors == len(connectors):
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

    raw_count = len(groups)
    c_count_hint = min(len(typec), len(groups))
    a_map = {}
    c_map = {}
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

    if c_count_hint > 0 and len(common_ports) >= c_count_hint:
        classification = "ucsi-companion-topology"
        c_ports = common_ports[:c_count_hint]
        used_keys = set()
        for idx, port_no in enumerate(c_ports):
            ss_group = ss_by_port[port_no]
            usb2_group = usb2_by_port[port_no]

            c_map[ss_group["raw_key"]] = idx
            c_map[usb2_group["raw_key"]] = idx
            used_keys.add(ss_group["raw_key"])
            used_keys.add(usb2_group["raw_key"])
        a_groups = [g for g in groups if g["raw_key"] not in used_keys]
        a_groups.sort(
            key=lambda g: (
                min(group_port_numbers(g) or [999]),
                g["raw_key"],
            )
        )

        for idx, group in enumerate(a_groups):
            a_map[group["raw_key"]] = idx

        c_count = len(c_ports)
        a_count = len(a_groups)
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
        if c_count > 0 and len(groups) >= 2 * c_count:
            physical_total = max(c_count, len(groups) - c_count)
        else:
            physical_total = len(groups)

        a_count = max(0, physical_total - c_count)

        for idx, group in enumerate(a_groups[:a_count]):
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
        self.update_window = None
        self.update_status_label = None
        self.update_proc = None
        self.serial_clipboard = None
        self.serial_clipboard_text = None
        self.test_proc = None
        self.test_kind = None
        self.test_duration = 0.0
        self.test_started = 0.0
        self.test_cancelled = False
        self.benchmark_buttons = []
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
    def do_activate(self):
        if self.window:
            self.window.present()
            return

        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_title("Hardware Check v4.5.79")
        self.window.set_default_size(860, 360)

        # Einheitliche Titelleiste wie Network/Wipe und Audio.
        self.header_bar = Gtk.HeaderBar()
        self.header_bar.set_show_title_buttons(True)

        title_label = Gtk.Label(label="Hardware Check v4.5.79")
        title_label.add_css_class("title")
        self.header_bar.set_title_widget(title_label)

        self.header_refresh_button = Gtk.Button(label="REFRESH")
        self.header_refresh_button.add_css_class("refresh-button")
        self.header_refresh_button.set_focusable(False)
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
        self.stack.add_named(self.build_overview(), "overview")
        self.stack.add_named(self.build_keyboard(), "keyboard")
        self.stack.add_named(self.build_benchmarks(), "benchmarks")
        # Die Hardware-Test-Buttons dürfen niemals Tastaturfokus bekommen.
        # Dadurch kann z.B. SPACE im Tastatur-Test nicht versehentlich
        # "ÜBERSICHT", "RESET" oder einen anderen Button auslösen.
        self.disable_button_focus(self.stack)

        self.window.set_child(self.stack)

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
    ):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.set_margin_start(10)
        row.set_margin_end(10)
        row.set_margin_top(5)
        row.set_margin_bottom(3)

        if back:
            b = Gtk.Button(label=back_label)
            b.add_css_class("secondary")
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
        # =====================================================
        # LINKE SPALTE
        # Security -> Webcam/Mic -> Eingabegeräte
        # =====================================================
        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        left.set_size_request(285, -1)
        left.set_hexpand(False)

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

        benchmark_btn = Gtk.Button(label="Benchmark (B)")
        benchmark_btn.add_css_class("benchmark-open")
        benchmark_btn.set_hexpand(True)
        benchmark_btn.connect("clicked", self.show_benchmarks)
        right.append(benchmark_btn)

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
                "WEBCAM MIT LINUX NICHT TESTBAR",
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
            self.set_hdmi_status_ui("blue", "VERBUNDEN", "HDMI")
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
                            "escape", "benchmark", "keyboard", "ram",
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

    def close_hotkeys_window(self, *_):
        window = self.hotkeys_window
        self.hotkeys_window = None
        if window is not None:
            try:
                window.destroy()
            except Exception:
                pass
        return True

    def on_hotkeys_key(self, controller, keyval, keycode, state):
        name = Gdk.keyval_name(keyval) or ""

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

        # Bewusst NICHT transient an Hardware Check binden:
        # Mutter kann das Fenster dadurch über present_centered() wieder in
        # der Bildschirmmitte platzieren, statt relativ zum HC-Fenster.
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

        title = Gtk.Label(label="SHORTCUTS / HOTKEYS")
        title.set_xalign(0)
        title.add_css_class("info-title")
        outer.append(title)

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
            ("B", "Benchmark-Seite öffnen / CPU-Benchmark starten"),
            ("K", "Keyboard-Test global öffnen"),
            ("R", "RAM-Test auf der Benchmark-Seite starten"),
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
                "Hinweis: Im KEYBOARD TEST sind F1, B, K, R, I, U, G, T, D,\n"
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

        window.set_child(outer)
        self.hotkeys_window = window
        self.present_centered(window)
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
        elif normalized in {
            "Bereits aktuell",
            "GitHub-Version ist älter · kein Update",
        }:
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
            if last_status in {
                "Bereits aktuell",
                "GitHub-Version ist älter · kein Update",
            }:
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
                    "com.david.UwuntuAudioTest",
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

        if action == "benchmark":
            if visible == "benchmarks":
                self.start_test(None, "cpu-short", 10.0)
                log("Globaler Hotkey B: CPU Benchmark gestartet")
            else:
                self.show_benchmarks()
                log("Globaler Hotkey B: Benchmark-Seite geöffnet")
            return False

        if action == "keyboard":
            self.show_keyboard()
            log("Globaler Hotkey K: Tastatur-Test geöffnet")
            return False

        if action == "ram" and visible == "benchmarks":
            self.start_test(None, "ram-short", 30.0)
            log("Globaler Hotkey R: RAM Test gestartet")
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
                {"type": "USB-A", "groups": set()},
            )
            slot["groups"].add(raw_key)
        for raw_key, local_idx in discovery.get("c_map", {}).items():
            slot = raw_slots.setdefault(
                ("USB-C", int(local_idx)),
                {"type": "USB-C", "groups": set()},
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
    def usb_slot_for_device(self, device_name):
        if not device_name or not self.usb_discovery:
            return None

        for group in self.usb_discovery["groups"]:
            if group_contains_device(group, device_name):
                slot_idx = self.usb_group_to_slot.get(group["raw_key"])
                if slot_idx is not None:
                    return slot_idx

        return None
    def usb_group_states(self):
        if not self.usb_discovery:
            return {}
        return {
            group["raw_key"]: group_present(group)
            for group in self.usb_discovery["groups"]
        }

    def sync_usb_connected(self, group_states, mark_tested=True):
        connected = set()

        for raw_key, present in group_states.items():
            if not present:
                continue
            slot_idx = self.usb_group_to_slot.get(raw_key)
            if slot_idx is None:
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
            f"USB-C={discovery['usb_c_count']}"
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
    def poll_usb(self):
        if self.window is None or not self.usb_discovery:
            return False

        current_groups = self.usb_group_states()
        old_connected = set(self.usb_connected)
        changed = False

        for raw_key, present in current_groups.items():
            before = self.usb_last_group_present.get(raw_key, False)
            if present == before:
                continue
            slot_idx = self.usb_group_to_slot.get(raw_key)
            if present:
                if slot_idx is not None:
                    self.usb_tested.add(slot_idx)
                    log(f"USB-Port {slot_idx + 1} verbunden")
                else:
                    log(f"Nicht zugeordneter USB-Pfad verbunden: {raw_key}")
            else:
                if slot_idx is not None:
                    log(f"USB-Port {slot_idx + 1}: Pfad entfernt")
            changed = True
        self.sync_usb_connected(current_groups, mark_tested=True)
        if self.usb_connected != old_connected:
            changed = True
        self.usb_last_group_present = dict(current_groups)

        current_devices = usb_device_snapshot()
        previous_names = set(self.usb_last_devices)
        current_names = set(current_devices)
        for dev_name in sorted(current_names - previous_names, key=natural_key):
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
                back=True,
                back_label="← ÜBERSICHT (ESC)",
            )
        )

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        body.set_margin_start(10)
        body.set_margin_end(10)
        body.set_margin_bottom(8)
        grid = Gtk.Grid()
        grid.set_row_spacing(6)
        grid.set_column_spacing(6)
        grid.set_column_homogeneous(True)

        specs = [
            ("Benchmark (B)", "cpu-short", 10.0, 0, 0),
            ("BENCHMARK (ERWEITERT)", "cpu-long", 600.0, 1, 0),
            ("RAM TEST (R)", "ram-short", 30.0, 0, 1),
            ("RAM TEST (ERWEITERT)", "ram-long", 600.0, 1, 1),
        ]

        self.benchmark_buttons = []
        for label, kind, duration, col, row in specs:
            b = Gtk.Button(label=label)
            b.add_css_class("benchmark-choice")
            b.set_hexpand(True)
            b.connect("clicked", self.start_test, kind, duration)
            self.benchmark_buttons.append(b)
            grid.attach(b, col, row, 1, 1)

        body.append(grid)
        self.benchmark_status = Gtk.Label(label="Bereit")
        self.benchmark_status.set_xalign(0)
        self.benchmark_status.add_css_class("benchmark-status")
        body.append(self.benchmark_status)

        self.benchmark_progress = Gtk.ProgressBar()
        self.benchmark_progress.set_fraction(0.0)
        self.benchmark_progress.set_show_text(False)
        body.append(self.benchmark_progress)
        progress_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8
        )

        self.benchmark_time = Gtk.Label(label="00:00 / 00:00")
        self.benchmark_time.set_xalign(0)
        self.benchmark_time.set_hexpand(True)
        self.benchmark_time.add_css_class("muted")
        self.cancel_test_button = Gtk.Button(label="ABBRECHEN")
        self.cancel_test_button.add_css_class("tiny-button")
        self.cancel_test_button.set_sensitive(False)
        self.cancel_test_button.connect("clicked", self.cancel_test)

        progress_row.append(self.benchmark_time)
        progress_row.append(self.cancel_test_button)
        body.append(progress_row)
        self.benchmark_result = Gtk.Label(label="")
        self.benchmark_result.set_xalign(0)
        self.benchmark_result.set_wrap(True)
        self.benchmark_result.add_css_class("benchmark-result")
        body.append(self.benchmark_result)

        root.append(body)
        return root

    def set_benchmark_result_class(self, color):
        for cls in ("status-green", "status-orange", "status-red"):
            self.benchmark_result.remove_css_class(cls)
        if color:
            self.benchmark_result.add_css_class("status-" + color)

    def reset_benchmark_ui(self):
        self.stop_test_process()
        self.test_kind = None
        self.test_duration = 0.0
        self.test_started = 0.0
        self.test_cancelled = False

        if hasattr(self, "benchmark_status"):
            self.set_benchmark_status_temp_class(None)
            self.benchmark_status.set_text("Bereit")
            self.benchmark_progress.set_fraction(0.0)
            self.benchmark_time.set_text("00:00 / 00:00")
            self.benchmark_result.set_text("")
            self.set_benchmark_result_class(None)
            self.set_benchmark_controls(False)

    def set_benchmark_status_temp_class(self, temp_c):
        for cls in ("status-yellow", "status-red"):
            self.benchmark_status.remove_css_class(cls)

        if temp_c is None:
            return

        if temp_c >= 97.0:
            self.benchmark_status.add_css_class("status-red")
        elif temp_c >= 90.0:
            self.benchmark_status.add_css_class("status-yellow")
    def update_cpu_benchmark_status(self):
        cores = os.cpu_count() or 1

        # Die Temperatur ist nur Zusatzinformation.
        # Sensorfehler dürfen die CPU-Lastmessung niemals blockieren.
        try:
            temp_c = read_cpu_temperature()
        except Exception as exc:
            temp_c = None
            log(f"CPU-Temperatur nicht lesbar: {exc}")

        text = f"CPU Benchmark läuft · {cores} Threads / Kerne"

        if temp_c is not None:
            text += f" · {temp_c:.0f}°C"
        self.benchmark_status.set_text(text)
        self.set_benchmark_status_temp_class(temp_c)

    def set_benchmark_controls(self, running):
        for b in self.benchmark_buttons:
            b.set_sensitive(not running)

        if hasattr(self, "cancel_test_button"):
            self.cancel_test_button.set_sensitive(running)

    def show_benchmarks(self, *_):
        self.stack.set_visible_child_name("benchmarks")
        self.window.set_default_size(860, 360)
    def start_test(self, button, kind, duration):
        if self.test_proc is not None and self.test_proc.poll() is None:
            return

        self.stop_test_process()

        self.test_kind = kind
        self.test_duration = float(duration)
        self.test_started = time.monotonic()
        self.test_cancelled = False
        self.benchmark_progress.set_fraction(0.0)
        self.benchmark_time.set_text(
            f"00:00 / {format_test_clock(duration)}"
        )
        self.benchmark_result.set_text("")
        self.set_benchmark_result_class(None)

        if kind.startswith("cpu"):
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
        else:
            self.set_benchmark_status_temp_class(None)
            mode = "short" if kind == "ram-short" else "long"
            if mode == "short":
                self.benchmark_status.set_text(
                    "RAM Test läuft · mehrere Bitmuster"
                )
            else:
                self.benchmark_status.set_text(
                    "RAM Test (Erweitert) läuft · maximale RAM-Last"
                )
            args = [
                sys.executable,
                "-c",
                RAM_TEST_WORKER,
                str(duration),
                mode,
            ]

        log(
            f"Test gestartet: {kind}, Dauer={duration:.0f}s"
        )
        try:
            self.test_proc = subprocess.Popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
        except Exception as exc:
            self.test_proc = None
            self.benchmark_status.set_text("Test konnte nicht gestartet werden")
            self.benchmark_result.set_text(str(exc))
            self.set_benchmark_result_class("red")
            return
        self.set_benchmark_controls(True)
        GLib.timeout_add(200, self.poll_test)

    def poll_test(self):
        proc = self.test_proc

        if proc is None:
            return False

        elapsed = max(0.0, time.monotonic() - self.test_started)
        duration = max(0.1, self.test_duration)
        if proc.poll() is None:
            fraction = min(0.99, elapsed / duration)
            self.benchmark_progress.set_fraction(fraction)
            self.benchmark_time.set_text(
                f"{format_test_clock(elapsed)} / "
                f"{format_test_clock(duration)}"
            )

            if self.test_kind and self.test_kind.startswith("cpu"):
                self.update_cpu_benchmark_status()

            return True
        try:
            output = proc.communicate(timeout=1)[0] or ""
        except Exception:
            output = ""

        self.test_proc = None
        self.benchmark_progress.set_fraction(1.0)
        self.benchmark_time.set_text(
            f"{format_test_clock(elapsed)} / "
            f"{format_test_clock(duration)}"
        )
        self.set_benchmark_controls(False)

        if self.test_cancelled:
            return False
        self.finish_test_result(output, proc.returncode)
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
        if returncode != 0 or not result:
            self.set_benchmark_status_temp_class(None)
            self.benchmark_status.set_text("Test fehlgeschlagen")
            self.benchmark_result.set_text(
                error[6:] if error else (
                    lines[-1] if lines else "Keine Ergebnisdaten"
                )
            )
            self.set_benchmark_result_class("red")
            log(
                f"Test fehlgeschlagen: {self.test_kind}; "
                f"returncode={returncode}; output={output[-1000:]}"
            )
            return
        parts = result.split()

        if len(parts) >= 5 and parts[1] == "CPU":
            total = int(parts[2])
            elapsed = float(parts[3])
            workers = int(parts[4])

            points = int((total / max(0.001, elapsed)) / 1000.0)
            points_text = f"{points:,}".replace(",", ".")
            self.set_benchmark_status_temp_class(None)
            self.benchmark_status.set_text("CPU Benchmark abgeschlossen")
            self.benchmark_result.set_text(
                f"{points_text} Punkte · "
                f"{workers} Threads · "
                f"{elapsed:.1f}s"
            )
            self.set_benchmark_result_class("green")
            log(
                f"CPU Benchmark fertig: "
                f"{points} Punkte, {workers} Threads, {elapsed:.2f}s"
            )
            return

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
                self.benchmark_status.set_text("RAM Test abgeschlossen")
                self.benchmark_result.set_text(
                    f"0 Fehler · "
                    f"{target_gib:.1f} GB RAM · "
                    f"{checked_gib:.1f} GB geprüft · "
                    f"{throughput:.1f} GB/s"
                )
                self.set_benchmark_result_class("green")
            else:
                self.benchmark_status.set_text(
                    "RAM FEHLER ERKANNT"
                )
                self.benchmark_result.set_text(
                    f"{errors} fehlerhafte Blöcke · "
                    f"{target_gib:.1f} GB RAM · "
                    f"{passes} Prüfmuster"
                )
                self.set_benchmark_result_class("red")
            log(
                f"RAM Test fertig: errors={errors}, "
                f"target={target}, checked={checked}, "
                f"elapsed={elapsed:.2f}s, passes={passes}"
            )
            return

        self.benchmark_status.set_text("Unbekanntes Testergebnis")
        self.benchmark_result.set_text(result)
        self.set_benchmark_result_class("red")

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

    def cancel_test(self, *_):
        if self.test_proc is None:
            return
        self.test_cancelled = True
        self.stop_test_process()
        self.set_benchmark_controls(False)

        self.set_benchmark_status_temp_class(None)
        self.benchmark_status.set_text("Test abgebrochen")
        self.benchmark_progress.set_fraction(0.0)
        self.benchmark_result.set_text("")
        self.set_benchmark_result_class("orange")

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

        def add_key(parent, label, aliases, width, height=25):
            key = Gtk.Label(label=label)
            key.add_css_class("key")
            key.set_size_request(width, height)
            key_id = label + "|" + ",".join(aliases)
            self.key_widgets[key_id] = key

            for alias in aliases:
                self.key_aliases[alias] = key_id

            parent.append(key)
            return key

        rows = self.keyboard_layout()

        for row_index, row_spec in enumerate(rows):
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=3)

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

                blank_left = Gtk.Box()
                blank_left.set_size_request(24, 22)
                blank_right = Gtk.Box()
                blank_right.set_size_request(24, 22)
                upper.append(blank_left)
                add_key(upper, "↑", ("Up",), 24, 22)
                upper.append(blank_right)

                add_key(lower, "←", ("Left",), 24, 22)
                add_key(lower, "↓", ("Down",), 24, 22)
                add_key(lower, "→", ("Right",), 24, 22)

                arrows.append(upper)
                arrows.append(lower)
                row.append(arrows)

            board.append(row)

        scroll.set_child(board)
        root.append(scroll)
        self.update_keyboard()
        return root

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

        # ESC auf der Benchmark-Seite bricht einen laufenden CPU-/RAM-Test ab
        # und geht danach zurück zur Übersicht.
        if name == "Escape" and visible == "benchmarks":
            if self.test_proc is not None and self.test_proc.poll() is None:
                self.cancel_test()
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

        # B/K/R/I/U/G/F1 auch über GTK behandeln, wenn Hardware Check den Fokus hat.
        # B = Benchmark, K = Tastatur-Test. Innerhalb des Tastatur-Tests
        # bleiben beide selbstverständlich normale Prüftasten.
        # Der Hotkey-Handler entprellt das parallele /dev/input-Ereignis.
        lower_name = name.lower()
        if lower_name == "b" and visible != "keyboard":
            self.handle_global_hotkey("benchmark")
            return True
        if lower_name == "k" and visible != "keyboard":
            self.handle_global_hotkey("keyboard")
            return True
        if lower_name == "r" and visible == "benchmarks":
            self.handle_global_hotkey("ram")
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

if len(sys.argv) >= 3 and sys.argv[1] == "--global-arrow-monitor":
    try:
        monitor_parent_pid = int(sys.argv[2])
    except (TypeError, ValueError):
        raise SystemExit(2)
    raise SystemExit(run_global_arrow_monitor(monitor_parent_pid))

app = App()
raise SystemExit(app.run([]))
PY
if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
    echo "FEHLER: Python GTK4 / PyGObject fehlt."
    echo "Benötigt werden python3-gi und GTK4."
    exit 1
fi

python3 "$TMP_PY"
