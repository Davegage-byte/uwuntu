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
# Wipe Auto - GTK4
# ============================================================

for cmd in upower lsblk wipefs partprobe smartctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FEHLER: $cmd fehlt."
        exit 10
    fi
done

TMP_PY="$(mktemp /tmp/wipe-auto-XXXXXX.py)"
trap 'rm -f "$TMP_PY"' EXIT

cat > "$TMP_PY" <<'PY'
#!/usr/bin/env python3

import gi
gi.require_version("Gtk", "4.0")

from gi.repository import Gtk, GLib, Gdk, Pango
import os
import re
import json
import subprocess
import threading
from pathlib import Path
from datetime import datetime

VERSION = "3.45"
BATTERY_BAD_BELOW = 75.0
LOG = Path.home() / "wipe_auto.log"

ENV_C = os.environ.copy()
ENV_C["LC_ALL"] = "C"
ENV_C["LANG"] = "C"

def log(message):
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}  {message}"
    try:
        with LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)

def run_text(args, timeout=8):
    try:
        p = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            env=ENV_C,
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as e:
        return 99, "", str(e)


def sudo_cmd(args, timeout=30):
    return run_text(["sudo", "-n"] + args, timeout=timeout)


def _lsblk_snapshot():
    """Liest die Blockgeräte nur ein; diese Funktion verändert nichts."""
    columns = (
        "PATH,NAME,KNAME,PKNAME,TYPE,ROTA,RM,TRAN,MODEL,SIZE,"
        "MOUNTPOINTS,MAJ:MIN,SERIAL,WWN"
    )
    rc, out, err = run_text(["lsblk", "-Jb", "-o", columns])
    if rc != 0:
        log(f"Zielerkennung: lsblk fehlgeschlagen: {err or rc}")
        return []
    try:
        import json
        return json.loads(out).get("blockdevices", [])
    except Exception as exc:
        log(f"Zielerkennung: ungültige lsblk-Ausgabe: {exc}")
        return []


def _flatten_devices(devices, parent=None):
    flat = []
    for raw in devices:
        item = dict(raw)
        item["_parent"] = parent
        children = item.pop("children", []) or []
        flat.append(item)
        flat.extend(_flatten_devices(children, item))
    return flat


def _mounted_sources():
    sources = set()
    rc, out, _ = run_text(["findmnt", "-rn", "-o", "SOURCE,TARGET"])
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


def _udev_properties(path):
    rc, out, _ = run_text(
        ["udevadm", "info", "--query=property", f"--name={path}"]
    )
    if rc != 0:
        return {}
    return dict(
        line.split("=", 1) for line in out.splitlines() if "=" in line
    )


def _device_identity(device):
    return (
        str(device.get("maj:min") or ""),
        str(device.get("serial") or ""),
        str(device.get("wwn") or ""),
        os.path.realpath(str(device.get("path") or "")),
    )


def _sysfs_path_is_usb(sys_path):
    path = sys_path.lower()
    return bool(
        "/usb" in path
        or re.search(r"/(?:\d+-\d+(?:\.\d+)*)/", path)
    )


def _is_certainly_internal_ssd(device):
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
    props = _udev_properties(path)
    bus = props.get("ID_BUS", "").lower()
    if tran == "usb" or bus == "usb" or _sysfs_path_is_usb(sys_path):
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


def detect_wipe_candidates():
    """Gibt sichere Kandidaten zurück und führt nie Destruktivbefehle aus."""
    flat = _flatten_devices(_lsblk_snapshot())
    by_path = {
        os.path.realpath(str(item.get("path") or "")): item
        for item in flat if item.get("path")
    }
    system_disks = set()
    mounted = _mounted_sources()

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
        if path in system_disks or not _is_certainly_internal_ssd(item):
            continue
        candidates.append(item)
    return candidates


def detect_wipe_target():
    candidates = detect_wipe_candidates()
    return candidates[0] if len(candidates) == 1 else None, len(candidates)


def validate_wipe_target(path, identity):
    """Validiert genau das bestätigte Gerät; wählt nie Ersatz."""
    if not path or not Path(path).exists():
        return False
    for candidate in detect_wipe_candidates():
        if candidate.get("path") == path:
            return _device_identity(candidate) == identity
    return False

def compact_battery_time(seconds):
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

def parse_upower_time(value):
    """
    UPower läuft durch ENV_C auf Englisch und liefert z.B.
    '1.5 hours', '42.0 minutes' oder '120 seconds'.
    """
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


def battery_power_w_sysfs(battery_name):
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
        # µW -> W
        return power_now / 1_000_000.0

    current_now = number("current_now")
    voltage_now = number("voltage_now")
    if (
        current_now is not None
        and voltage_now is not None
        and current_now >= 0
        and voltage_now > 0
    ):
        # µA * µV = 1e-12 W; geteilt durch 1e12.
        return (current_now * voltage_now) / 1_000_000_000_000.0

    return None


def format_battery_power(power_w, state):
    if power_w is None:
        return ""

    try:
        power_w = abs(float(power_w))
    except Exception:
        return ""
    # Solange noch kein sinnvoller Leistungswert vorliegt,
    # nichts anzeigen statt "0.0 W".
    if power_w < 0.05:
        return ""

    state_l = (state or "").strip().lower()

    # Laden positiv, Entladen mit getrenntem Minuszeichen.
    # Beispiel: "- 35.5W" statt "-35.5 W".
    if state_l == "discharging":
        return f"- {power_w:.1f}W"

    return f"{power_w:.1f}W"


def battery_info():
    rc, out, _ = run_text(["upower", "-e"])
    if rc != 0:
        return None, None, None, None
    bat = None
    for line in out.splitlines():
        if "BAT" in line:
            bat = line.strip()
            break

    if not bat:
        return None, None, None, None

    rc, info, _ = run_text(["upower", "-i", bat])
    if rc != 0:
        return None, None, None, None

    health = None
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

        m = re.match(r"\s*state:\s*(.+?)\s*$", line, re.I)
        if m:
            state = m.group(1).strip().lower()
        m = re.match(r"\s*time to empty:\s*(.+?)\s*$", line, re.I)
        if m:
            time_to_empty = parse_upower_time(m.group(1))

        m = re.match(r"\s*time to full:\s*(.+?)\s*$", line, re.I)
        if m:
            time_to_full = parse_upower_time(m.group(1))
        # UPower liefert die aktuelle Akku-Leistung in Watt.
        m = re.match(
            r"\s*energy-rate:\s*([0-9.,]+)\s*W\s*$",
            line,
            re.I,
        )
        if m:
            try:
                power_w = float(m.group(1).replace(",", "."))
            except Exception:
                power_w = None
    # Fallback direkt über /sys/class/power_supply/BATx.
    if power_w is None:
        battery_name = bat.rsplit("/", 1)[-1]
        if battery_name.startswith("battery_"):
            battery_name = battery_name[len("battery_"):]
        power_w = battery_power_w_sysfs(battery_name)

    remaining = None

    if state in {"discharging", "pending-discharge"}:
        remaining = time_to_empty
    elif state in {"charging", "pending-charge"}:
        remaining = time_to_full
    return (
        health,
        state,
        compact_battery_time(remaining),
        power_w,
    )

def disk_details(disk):
    if not disk or not Path(disk).exists():
        return None

    rc, out, _ = run_text(
        ["lsblk", "-dn", "-o", "SIZE,MODEL", disk]
    )
    if rc != 0:
        return {"size": "--", "model": "--"}

    parts = out.split(None, 1)
    size = parts[0] if parts else "--"
    model = parts[1].strip() if len(parts) > 1 else "--"
    return {"size": size, "model": model}


SMART_TEMP_WARN_C = 60.0
SMART_TEMP_BAD_C = 70.0
SMART_SENSOR_TEMP_WARN_C = 70.0
SMART_SENSOR_TEMP_BAD_C = 80.0
SMART_WEAR_WARN_PERCENT = 80
SMART_WEAR_BAD_PERCENT = 100
SMART_UNSAFE_SHUTDOWN_WARN = 100
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
    if temp > 170:
        temp -= 273.15
    return temp

def smart_format_count(value):
    return f"{smart_number(value):,}".replace(",", ".")

def smart_format_tb(data_units):
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
            "Stromverlust oder hartes Ausschalten ohne sauberes Herunterfahren. Unter 100 unauffällig.",
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

def disk_is_clean(disk):
    # 1) Keine bekannten Signaturen mehr auf dem Hauptgerät.
    # Das Lesen der Signaturen auf einem Blockgerät benötigt ebenfalls
    # Root-Rechte. Im persistenten Live-System funktioniert sudo -n
    # passwortlos.
    rc, signatures, err = sudo_cmd(["wipefs", "-n", disk], timeout=10)
    if rc != 0:
        return False, f"Prüfung fehlgeschlagen: {err or 'sudo wipefs -n'}"

    if signatures.strip():
        return False, "Es sind noch Datenträger-Signaturen vorhanden."
    # 2) Keine Partitionen mehr unterhalb des NVMe-Geräts.
    rc, out, err = run_text(["lsblk", "-nr", "-o", "NAME,TYPE", disk])
    if rc != 0:
        return False, f"Prüfung fehlgeschlagen: {err or 'lsblk'}"

    lines = [line.strip() for line in out.splitlines() if line.strip()]
    child_parts = [
        line for line in lines[1:]
        if line.split()[-1] == "part"
    ]

    if child_parts:
        return False, "Partitionen werden weiterhin vom Kernel erkannt."

    return True, ""

class WipeAutoApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.david.WipeAuto")
        self.window = None
        self.wiping = False
        self.confirming = False
        self.soh_alert_active = False
        self.soh_blink_on = False
        self.disk = None
        self.disk_info = None
        self.confirmed_disk = None
        self.confirmed_identity = None
        self.smart_window = None
        self.smart_refresh_button = None
        self.smart_disk_path = None
        self.smart_overall = None
        self.smart_data = None
        self.smart_check_disk = None

        # Letzte erkannte Größe + Modellbezeichnung der SSD.
        # Diese Information bleibt nach dem Wipe sichtbar.
        self.last_disk_display = None

    def do_activate(self):
        if self.window:
            self.window.present()
            GLib.idle_add(self.focus_wipe_button)
            return
        self.install_css()

        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_title("Wipe Auto")
        self.window.set_default_size(690, 395)

        key_controller = Gtk.EventControllerKey.new()
        key_controller.connect("key-pressed", self.on_key_pressed)
        self.window.add_controller(key_controller)
        # Sobald Wipe Auto wirklich das aktive Wayland-Fenster wird,
        # den Tastaturfokus sofort auf WIPE SSD legen.
        self.window.connect(
            "notify::is-active",
            self.on_window_active_changed
        )

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.set_margin_top(8)
        outer.set_margin_bottom(8)
        outer.set_margin_start(10)
        outer.set_margin_end(10)
        # ----------------------------------------------------
        # Kopfzeile
        # ----------------------------------------------------
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)

        title_line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        title_line.set_hexpand(True)

        title = Gtk.Label(label="WIPE AUTO")
        title.set_xalign(0)
        title.add_css_class("main-title")
        version = Gtk.Label(label=f"v{VERSION}")
        version.set_xalign(0)
        version.add_css_class("version")

        title_line.append(title)
        title_line.append(version)

        self.refresh_button = Gtk.Button(label="REFRESH")
        self.refresh_button.add_css_class("action")
        self.refresh_button.set_valign(Gtk.Align.CENTER)
        self.refresh_button.set_focusable(False)
        self.refresh_button.connect("clicked", self.on_refresh)
        top.append(title_line)
        top.append(self.refresh_button)
        outer.append(top)

        # ----------------------------------------------------
        # Akku
        # ----------------------------------------------------
        self.battery_card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=6
        )
        self.battery_card.add_css_class("card")

        bhead = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        btitle = Gtk.Label(label="BATTERIE")
        btitle.set_xalign(0)
        btitle.set_hexpand(True)
        btitle.add_css_class("card-title")

        bhead.append(btitle)
        self.battery_card.append(bhead)

        # Links ein leicht verbreitertes SoH-Feld, rechts Platz für
        # Status + Restzeit + Lade-/Entladeleistung.
        battery_metrics = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8
        )
        battery_metrics.set_homogeneous(False)
        self.health_metric = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=2
        )
        self.health_metric.add_css_class("metric")
        self.health_metric.set_size_request(400, -1)
        self.health_metric.set_hexpand(False)

        self.battery_value = Gtk.Label(label="--")
        self.battery_value.add_css_class("metric-value")
        self.battery_value.add_css_class("neutral")

        self.health_metric.append(self.battery_value)
        charging_metric = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=2
        )
        charging_metric.add_css_class("metric")
        charging_metric.set_hexpand(True)

        self.charging_value = Gtk.Label(label="--")
        self.charging_value.add_css_class("metric-value")
        self.charging_value.add_css_class("neutral")

        charging_metric.append(self.charging_value)
        battery_metrics.append(self.health_metric)
        battery_metrics.append(charging_metric)
        self.battery_card.append(battery_metrics)

        self.battery_note = Gtk.Label(label="")
        self.battery_note.set_xalign(0)
        self.battery_note.set_wrap(True)
        self.battery_note.add_css_class("note")
        self.battery_card.append(self.battery_note)

        outer.append(self.battery_card)
        # ----------------------------------------------------
        # Datenträger
        # ----------------------------------------------------
        self.disk_card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=6
        )
        self.disk_card.add_css_class("card")

        dhead = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        dtitle = Gtk.Label(label="DATENTRÄGER")
        dtitle.set_xalign(0)
        dtitle.set_hexpand(True)
        dtitle.add_css_class("card-title")

        self.disk_badge = Gtk.Label(label="CHECKING")
        self.disk_badge.add_css_class("badge")
        self.set_class(self.disk_badge, "warn")

        dhead.append(dtitle)
        dhead.append(self.disk_badge)
        self.disk_card.append(dhead)
        self.disk_device = Gtk.Label(label="--")
        self.disk_device.set_xalign(0)
        self.disk_device.add_css_class("interface")
        self.disk_card.append(self.disk_device)

        self.disk_value = Gtk.Label(label="--")
        self.disk_value.set_xalign(0)
        self.disk_value.add_css_class("disk-result")
        self.disk_value.add_css_class("neutral")
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
        disk_info_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        disk_info_row.set_hexpand(True)
        self.disk_value.set_hexpand(True)
        disk_info_row.append(self.disk_value)
        self.disk_info_indicator = Gtk.Label(label="ⓘ")
        self.disk_info_indicator.set_valign(Gtk.Align.CENTER)
        self.disk_info_indicator.set_halign(Gtk.Align.END)
        self.disk_info_indicator.set_tooltip_text("SSD-/SMART-Werte anzeigen (S)")
        self.disk_info_indicator.add_css_class("disk-info")
        info_click = Gtk.GestureClick.new()
        info_click.set_button(1)
        info_click.connect(
            "released",
            lambda _gesture, n_press, _x, _y: (
                self.show_smart_window() if n_press == 1 else None
            ),
        )
        self.disk_info_indicator.add_controller(info_click)
        disk_info_row.append(self.disk_info_indicator)
        self.disk_card.append(disk_info_row)
        self.disk_note = Gtk.Label(label="")
        self.disk_note.set_xalign(0)
        self.disk_note.set_wrap(False)
        self.disk_note.set_ellipsize(Pango.EllipsizeMode.END)
        self.disk_note.set_max_width_chars(35)
        self.disk_note.add_css_class("note")
        self.disk_card.append(self.disk_note)

        self.action_area = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8
        )
        self.action_area.set_halign(Gtk.Align.END)
        self.wipe_button = Gtk.Button(label="WIPE SSD")
        self.wipe_button.add_css_class("danger-action")
        self.wipe_button.connect("clicked", self.on_wipe_clicked)
        self.wipe_button.connect(
            "notify::has-focus",
            self.on_wipe_focus_changed
        )

        self.action_area.append(self.wipe_button)
        self.disk_card.append(self.action_area)

        outer.append(self.disk_card)

        self.window.set_child(outer)
        # ENTER soll direkt WIPE SSD auslösen.
        self.window.set_default_widget(self.wipe_button)
        self.wipe_button.grab_focus()

        self.window.present()

        log("Wipe Auto gestartet.")
        self.refresh_all()

        # Charging Status jede Sekunde aktuell halten, ohne SSD-Ergebnis
        # oder Bestätigungszustand anzufassen.
        GLib.timeout_add_seconds(1, self.refresh_battery_timer)
        # Unter 75 % SoH blinkt das komplette linke SoH-Feld rot.
        GLib.timeout_add(450, self.update_soh_blink)
        # Nach dem Refresh Fokus sicher wieder auf WIPE SSD setzen.
        GLib.idle_add(self.focus_wipe_button)

    def install_css(self):
        css = b"""
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
        .card {
            background: #191c22;
            border: 1px solid #303641;
            border-radius: 8px;
            padding: 6px;
        }

        .card-title {
            font-size: 13px;
            font-weight: 800;
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
        .metric {
            background: #111318;
            border: 1px solid transparent;
            border-radius: 8px;
            padding: 4px 6px;
        }

        .metric.soh-alert {
            background: #ff4c4c;
            border-color: #ff4c4c;
        }

        .metric.soh-alert .bad {
            color: #f4f4f5;
            background: transparent;
        }

        .metric-caption {
            color: #9d9da7;
            font-size: 10px;
            font-weight: 600;
        }

        .metric-value {
            font-size: 17px;
            font-weight: 800;
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
        .smart-summary.good {
            color: #61d36b;
        }
        .smart-summary.warn {
            color: #f5a623;
        }
        .smart-summary.bad {
            color: #ff4c4c;
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
        .smart-row-alert.warn {
            color: #f5a623;
        }
        .smart-row-alert.bad {
            color: #ff4c4c;
        }
        .disk-info {
            font-size: 16px;
            font-weight: 800;
            padding: 4px 6px;
        }
        .disk-result {
            background: #111318;
            border-radius: 8px;
            padding: 5px 6px;
            font-size: 17px;
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

        headerbar button.header-refresh {
            min-height: 22px;
            padding: 1px 7px;
            border-radius: 7px;
            font-size: 11px;
            font-weight: 800;
        }

        button.danger-action {
            font-size: 12px;
            font-weight: 800;
            padding: 4px 10px;
            border-radius: 8px;
        }
        /* Sehr deutlich sichtbarer Tastaturfokus */
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
            padding: 4px 10px;
            border-radius: 8px;
        }

        button.confirm.keyboard-focus,
        button.confirm:focus {
            background: #232329;
            color: #f4f4f5;
            border-color: #5aa2ff;
            outline: 3px solid #5aa2ff;
            outline-offset: 2px;
        }

        button.cancel {
            font-size: 12px;
            font-weight: 800;
            padding: 4px 10px;
            border-radius: 8px;
        }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)

        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def set_class(self, widget, klass):
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
        self.set_class(self.disk_info_indicator, klass)

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

    def on_wipe_focus_changed(self, widget, pspec):
        try:
            focused = widget.get_property("has-focus")
        except Exception:
            focused = False

        if focused:
            widget.add_css_class("keyboard-focus")
        else:
            widget.remove_css_class("keyboard-focus")

    def on_window_active_changed(self, window, pspec):
        try:
            active = window.get_property("is-active")
        except Exception:
            active = False
        if active and not self.wiping:
            GLib.idle_add(self.focus_wipe_button)

    def focus_wipe_button(self):
        if (
            self.window is not None
            and not self.wiping
            and self.wipe_button.get_sensitive()
        ):
            self.window.set_default_widget(self.wipe_button)
            self.wipe_button.grab_focus()
        return False
    def on_refresh(self, button):
        if not self.wiping and not self.confirming:
            # Nach einem erfolgreichen Wipe ist der WIPE-Button bewusst
            # ausgeblendet. REFRESH setzt die SSD-Karte wieder auf den
            # normalen Ausgangszustand zurück.
            self.restore_wipe_button()
            self.refresh_all()
            GLib.idle_add(self.focus_wipe_button)

    def refresh_battery(self):
        health, state, remaining, power_w = battery_info()
        power_text = format_battery_power(power_w, state)
        self.set_soh_alert(
            health is not None and health < BATTERY_BAD_BELOW
        )
        # ----------------------------------------------------
        # LINKS: nur State of Health
        # ----------------------------------------------------
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
        # ----------------------------------------------------
        # RECHTS: Charging/Discharging + Restzeit + Leistung
        # ----------------------------------------------------
        # UPower-Zustände vollständig auf Deutsch anzeigen.
        # Bekannte Rohwerte: unknown, charging, discharging, empty,
        # fully-charged, pending-charge, pending-discharge.
        if state == "fully-charged":
            parts = ["VOLL"]
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

        self.charging_value.set_text(" · ".join(parts))
        self.set_class(self.charging_value, state_class)

    def set_soh_alert(self, active):
        active = bool(active)
        if active == self.soh_alert_active:
            return

        self.soh_alert_active = active
        self.soh_blink_on = active

        if active:
            self.health_metric.add_css_class("soh-alert")
        else:
            self.health_metric.remove_css_class("soh-alert")

    def update_soh_blink(self):
        if self.window is None:
            return False

        if not self.soh_alert_active:
            self.soh_blink_on = False
            self.health_metric.remove_css_class("soh-alert")
            return True

        self.soh_blink_on = not self.soh_blink_on
        if self.soh_blink_on:
            self.health_metric.add_css_class("soh-alert")
        else:
            self.health_metric.remove_css_class("soh-alert")

        return True

    def refresh_battery_timer(self):
        if self.window is None:
            return False

        self.refresh_battery()
        return True

    def refresh_all(self):
        self.refresh_battery()
        # Datenträger
        target, candidate_count = detect_wipe_target()
        self.disk_info = target
        self.disk = target.get("path") if target else None
        self.disk_device.set_text(self.disk or "--")
        details = disk_details(self.disk)
        if candidate_count > 1:
            self.disk_badge.set_text("AMBIGUOUS")
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
            self.disk_note.set_text(
                "Kein sicherer interner Datenträger erkannt."
            )
            self.wipe_button.set_sensitive(False)
        else:
            self.disk_badge.set_text("READY")
            self.set_class(self.disk_badge, "neutral")
            self.last_disk_display = (
                f"{details['size']}  •  {details['model']}"
            )

            self.disk_value.set_text(self.last_disk_display)
            self.apply_disk_smart_color()
            self.disk_note.set_text("Bereit zum Löschen.")
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

        model = Gtk.Label(label=f"{data['model']}  •  {disk or '--'}")
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
        summary.add_css_class(overall)
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

            if status in ("warn", "bad"):
                for cell in (label, value, help_label):
                    cell.add_css_class("smart-row-alert")
                    cell.add_css_class(status)

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

        window = Gtk.ApplicationWindow(application=self)
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

    def clear_action_area(self):
        child = self.action_area.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            self.action_area.remove(child)
            child = nxt
    def restore_wipe_button(self):
        self.clear_action_area()
        self.action_area.set_hexpand(False)
        self.action_area.set_halign(Gtk.Align.END)
        self.action_area.append(self.wipe_button)
        self.wipe_button.set_sensitive(True)
        self.window.set_default_widget(self.wipe_button)

    def on_wipe_clicked(self, button):
        if self.wiping or self.confirming or not self.disk or not self.disk_info:
            return

        # Das in der UI angezeigte Ziel bereits vor dem Bestätigungsdialog
        # unveränderlich festhalten. Ein späterer Refresh darf es nicht ersetzen.
        self.confirmed_disk = self.disk
        self.confirmed_identity = _device_identity(self.disk_info)
        self.confirming = True
        self.refresh_button.set_sensitive(False)

        self.clear_action_area()
        # Bestätigungszeile über die verfügbare Breite ziehen.
        self.action_area.set_halign(Gtk.Align.FILL)
        self.action_area.set_hexpand(True)

        warning = Gtk.Label(label="WIRKLICH LÖSCHEN?")
        warning.set_xalign(0)
        warning.set_hexpand(True)
        warning.add_css_class("confirm-warning")
        yes = Gtk.Button(label="YES")
        yes.add_css_class("confirm")
        yes.connect("clicked", self.on_confirm_wipe)
        yes.connect(
            "notify::has-focus",
            self.on_wipe_focus_changed
        )

        cancel = Gtk.Button(label="CANCEL")
        cancel.add_css_class("cancel")
        cancel.connect("clicked", self.on_cancel_wipe)

        self.action_area.append(warning)
        self.action_area.append(cancel)
        self.action_area.append(yes)
        # Zweites ENTER bestätigt direkt mit YES.
        self.window.set_default_widget(yes)
        yes.grab_focus()

        self.disk_badge.set_text("CONFIRM")
        self.set_class(self.disk_badge, "warn")
        self.disk_note.set_text(
            f"Alle Partitions-/Dateisystem-Signaturen auf {self.confirmed_disk} werden entfernt."
        )

    def on_cancel_wipe(self, button):
        if self.wiping:
            return
        self.confirming = False
        self.confirmed_disk = None
        self.confirmed_identity = None
        self.refresh_button.set_sensitive(True)
        self.restore_wipe_button()
        self.refresh_all()
        GLib.idle_add(self.focus_wipe_button)

    def on_confirm_wipe(self, button):
        if (
            self.wiping
            or not self.confirming
            or not self.confirmed_disk
            or not self.confirmed_identity
        ):
            return

        self.confirming = False
        self.wiping = True

        self.clear_action_area()

        self.disk_badge.set_text("WIRD GELÖSCHT")
        self.set_class(self.disk_badge, "live")
        if self.last_disk_display:
            self.disk_value.set_text(
                f"{self.last_disk_display} • Wird Gelöscht …"
            )
        else:
            self.disk_value.set_text("SSD WIRD GELÖSCHT …")

        self.apply_disk_smart_color()
        self.disk_note.set_text("Bitte warten.")

        thread = threading.Thread(
            target=self.wipe_worker,
            args=(self.confirmed_disk, self.confirmed_identity),
            daemon=True,
        )
        thread.start()

    def wipe_worker(self, disk, identity):
        log(f"Wipe angefordert: {disk}")
        # Unmittelbar vor dem ersten Unmount/destruktiven Befehl erneut exakt
        # das bestätigte Ziel prüfen. Keine automatische Ersatzauswahl.
        if not validate_wipe_target(disk, identity):
            log(f"Wipe abgebrochen: Ziel nicht mehr sicher: {disk}")
            GLib.idle_add(
                self.finish_wipe_error,
                f"{disk or 'Ziel'} ist nicht mehr sicher – Wipe abgebrochen."
            )
            return

        log(f"Wipe gestartet: {disk}")

        # Alle Child-Partitionen zuerst aushängen.
        rc, out, _ = run_text(["lsblk", "-nrpo", "NAME,TYPE", disk])
        if rc == 0:
            children = []
            for line in out.splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 2 and parts[-1] == "part":
                    children.append(parts[0])

            for part in reversed(children):
                sudo_cmd(["umount", part], timeout=10)
                sudo_cmd(["fuser", "-k", part], timeout=10)
        # Hauptgerät vorsichtshalber ebenfalls unmount/fuser.
        sudo_cmd(["umount", disk], timeout=10)
        sudo_cmd(["fuser", "-k", disk], timeout=10)

        # Eigentliche destruktive Aktion.
        rc, out, err = sudo_cmd(["wipefs", "-a", disk], timeout=30)
        if rc != 0:
            log(f"wipefs FEHLER rc={rc}: {err}")
            GLib.idle_add(
                self.finish_wipe_error,
                f"wipefs fehlgeschlagen: {err or 'unbekannter Fehler'}"
            )
            return

        # Kernel-Partitionstabelle neu einlesen.
        sudo_cmd(["partprobe", disk], timeout=15)

        clean, reason = disk_is_clean(disk)
        if not clean:
            log(f"Verifikation FEHLER: {reason}")
            GLib.idle_add(
                self.finish_wipe_error,
                reason
            )
            return

        log(f"Wipe erfolgreich verifiziert: {disk}")
        GLib.idle_add(self.finish_wipe_success, disk)

    def finish_wipe_success(self, disk):
        self.wiping = False
        self.confirmed_disk = None
        self.confirmed_identity = None
        self.refresh_button.set_sensitive(True)

        self.disk_badge.set_text("PASS")
        self.set_class(self.disk_badge, "good")
        if self.last_disk_display:
            self.disk_value.set_text(
                f"{self.last_disk_display} • Erfolgreich Gelöscht"
            )
        else:
            self.disk_value.set_text("Erfolgreich Gelöscht")

        self.apply_disk_smart_color()

        self.disk_note.set_text(
            f"{disk}: keine Signaturen und keine Partitionen mehr erkannt."
        )

        self.clear_action_area()
        # Nach Erfolg bewusst NICHT refresh_all() aufrufen:
        # Der Erfolg soll sichtbar stehen bleiben.
        return False

    def finish_wipe_error(self, message):
        self.wiping = False
        self.confirmed_disk = None
        self.confirmed_identity = None
        self.refresh_button.set_sensitive(True)

        self.disk_badge.set_text("ERROR")
        self.set_class(self.disk_badge, "bad")
        if self.last_disk_display:
            self.disk_value.set_text(
                f"{self.last_disk_display} • Löschen Fehlgeschlagen"
            )
        else:
            self.disk_value.set_text("Löschen Fehlgeschlagen")

        self.apply_disk_smart_color()

        self.disk_note.set_text(message)

        self.restore_wipe_button()
        self.wipe_button.set_sensitive(False)
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
            self.show_smart_window()
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
        log("Wipe Auto beendet.")
        Gtk.Application.do_shutdown(self)


app = WipeAutoApp()
raise SystemExit(app.run(None))
PY

python3 "$TMP_PY"
