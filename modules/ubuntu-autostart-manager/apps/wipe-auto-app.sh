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

for cmd in upower lsblk wipefs partprobe; do
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
import subprocess
import threading
from pathlib import Path
from datetime import datetime

VERSION = "3.32"
DISK = "/dev/nvme0n1"
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

def disk_details():
    if not Path(DISK).exists():
        return None

    rc, out, _ = run_text(
        ["lsblk", "-dn", "-o", "SIZE,MODEL", DISK]
    )
    if rc != 0:
        return {"size": "--", "model": "--"}

    parts = out.split(None, 1)
    size = parts[0] if parts else "--"
    model = parts[1].strip() if len(parts) > 1 else "--"
    return {"size": size, "model": model}

def disk_is_clean():
    # 1) Keine bekannten Signaturen mehr auf dem Hauptgerät.
    # Das Lesen der Signaturen auf einem Blockgerät benötigt ebenfalls
    # Root-Rechte. Im persistenten Live-System funktioniert sudo -n
    # passwortlos.
    rc, signatures, err = sudo_cmd(["wipefs", "-n", DISK], timeout=10)
    if rc != 0:
        return False, f"Prüfung fehlgeschlagen: {err or 'sudo wipefs -n'}"

    if signatures.strip():
        return False, "Es sind noch Datenträger-Signaturen vorhanden."
    # 2) Keine Partitionen mehr unterhalb des NVMe-Geräts.
    rc, out, err = run_text(["lsblk", "-nr", "-o", "NAME,TYPE", DISK])
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
        self.soh_alert_active = False
        self.soh_blink_on = False

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
        self.disk_device = Gtk.Label(label=DISK)
        self.disk_device.set_xalign(0)
        self.disk_device.add_css_class("interface")
        self.disk_card.append(self.disk_device)

        self.disk_value = Gtk.Label(label="--")
        self.disk_value.set_xalign(0)
        self.disk_value.add_css_class("disk-result")
        self.disk_value.add_css_class("neutral")
        self.disk_card.append(self.disk_value)
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
        if not self.wiping:
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
        details = disk_details()
        if details is None:
            self.disk_badge.set_text("NOT FOUND")
            self.set_class(self.disk_badge, "warn")
            self.disk_value.set_text("SSD NICHT GEFUNDEN")
            self.set_class(self.disk_value, "warn")
            self.disk_note.set_text(
                f"{DISK} ist nicht vorhanden – Hardware prüfen."
            )
            self.wipe_button.set_sensitive(False)
        else:
            self.disk_badge.set_text("READY")
            self.set_class(self.disk_badge, "neutral")
            self.last_disk_display = (
                f"{details['size']}  •  {details['model']}"
            )

            self.disk_value.set_text(self.last_disk_display)
            self.set_class(self.disk_value, "warn")
            self.disk_note.set_text("Bereit zum Löschen.")
            self.wipe_button.set_sensitive(True)
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
        if self.wiping:
            return

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
            f"Alle Partitions-/Dateisystem-Signaturen auf {DISK} werden entfernt."
        )

    def on_cancel_wipe(self, button):
        if self.wiping:
            return
        self.restore_wipe_button()
        self.refresh_all()
        GLib.idle_add(self.focus_wipe_button)

    def on_confirm_wipe(self, button):
        if self.wiping:
            return

        self.wiping = True
        self.refresh_button.set_sensitive(False)

        self.clear_action_area()

        self.disk_badge.set_text("WIRD GELÖSCHT")
        self.set_class(self.disk_badge, "live")
        if self.last_disk_display:
            self.disk_value.set_text(
                f"{self.last_disk_display} • Wird Gelöscht …"
            )
        else:
            self.disk_value.set_text("SSD WIRD GELÖSCHT …")

        self.set_class(self.disk_value, "live")
        self.disk_note.set_text("Bitte warten.")

        thread = threading.Thread(target=self.wipe_worker, daemon=True)
        thread.start()

    def wipe_worker(self):
        log(f"Wipe gestartet: {DISK}")
        # Sicherheitscheck: Zielgerät muss existieren und ein block device sein.
        if not Path(DISK).exists():
            GLib.idle_add(
                self.finish_wipe_error,
                f"{DISK} wurde nicht gefunden."
            )
            return

        # Alle Child-Partitionen zuerst aushängen.
        rc, out, _ = run_text(["lsblk", "-nrpo", "NAME,TYPE", DISK])
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
        sudo_cmd(["umount", DISK], timeout=10)
        sudo_cmd(["fuser", "-k", DISK], timeout=10)

        # Eigentliche destruktive Aktion.
        rc, out, err = sudo_cmd(["wipefs", "-a", DISK], timeout=30)
        if rc != 0:
            log(f"wipefs FEHLER rc={rc}: {err}")
            GLib.idle_add(
                self.finish_wipe_error,
                f"wipefs fehlgeschlagen: {err or 'unbekannter Fehler'}"
            )
            return

        # Kernel-Partitionstabelle neu einlesen.
        sudo_cmd(["partprobe", DISK], timeout=15)

        clean, reason = disk_is_clean()
        if not clean:
            log(f"Verifikation FEHLER: {reason}")
            GLib.idle_add(
                self.finish_wipe_error,
                reason
            )
            return

        log(f"Wipe erfolgreich verifiziert: {DISK}")
        GLib.idle_add(self.finish_wipe_success)

    def finish_wipe_success(self):
        self.wiping = False
        self.refresh_button.set_sensitive(True)

        self.disk_badge.set_text("PASS")
        self.set_class(self.disk_badge, "good")
        if self.last_disk_display:
            self.disk_value.set_text(
                f"{self.last_disk_display} • Erfolgreich Gelöscht"
            )
        else:
            self.disk_value.set_text("Erfolgreich Gelöscht")

        self.set_class(self.disk_value, "good")

        self.disk_note.set_text(
            f"{DISK}: keine Signaturen und keine Partitionen mehr erkannt."
        )

        self.clear_action_area()
        # Nach Erfolg bewusst NICHT refresh_all() aufrufen:
        # Der Erfolg soll sichtbar stehen bleiben.
        return False

    def finish_wipe_error(self, message):
        self.wiping = False
        self.refresh_button.set_sensitive(True)

        self.disk_badge.set_text("ERROR")
        self.set_class(self.disk_badge, "bad")
        if self.last_disk_display:
            self.disk_value.set_text(
                f"{self.last_disk_display} • Löschen Fehlgeschlagen"
            )
        else:
            self.disk_value.set_text("Löschen Fehlgeschlagen")

        self.set_class(self.disk_value, "bad")

        self.disk_note.set_text(message)

        self.restore_wipe_button()
        return False

    def on_key_pressed(self, controller, keyval, keycode, state):
        name = Gdk.keyval_name(keyval) or ""
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
