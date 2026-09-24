#!/usr/bin/env bash
set -u
LOG="$HOME/kiosk_start.log"

MAX_TILING_WAIT_SECONDS=90
MAX_SOCKET_WAIT_SECONDS=30
POLL_SECONDS=0.25

exec >>"$LOG" 2>&1

echo
echo "============================================================"
echo "4-Felder-Kiosk Start: $(date)"
echo "============================================================"

FORCE_UPDATE_SCRIPT="$HOME/.local/bin/uwuntu-force-update.sh"
KIOSK_SELF="$HOME/.local/bin/start-kiosk-apps.sh"

startup_network_may_reach_github() {
    # Bei eindeutig fehlender/limitierter Konnektivität nicht erst Curl-
    # Timeouts abwarten. "unknown" wird trotzdem kurz probiert, weil die
    # NetworkManager-Konnektivitätsprüfung deaktiviert sein kann.
    if ! command -v nmcli >/dev/null 2>&1; then
        return 0
    fi

    local connectivity
    connectivity="$(
        nmcli -t -f CONNECTIVITY general 2>/dev/null \
            | head -n 1 \
            | tr '[:upper:]' '[:lower:]'
    )"

    case "$connectivity" in
        none|portal|limited)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

run_startup_update_preflight() {
    if [ "${UWUNTU_SKIP_STARTUP_UPDATE:-0}" = "1" ]; then
        unset UWUNTU_SKIP_STARTUP_UPDATE
        echo "Update-Preflight nach erfolgreichem Update einmal übersprungen."
        return 0
    fi

    if [ ! -x "$FORCE_UPDATE_SCRIPT" ]; then
        echo "Hinweis: Update-Helfer fehlt; starte lokalen Stand ohne Preflight."
        return 0
    fi

    if ! startup_network_may_reach_github; then
        echo "Kein voll nutzbares Netzwerk gemeldet; starte ohne Update-Wartezeit."
        return 0
    fi

    echo "Prüfe vor dem App-Start kurz auf Uwuntu-Updates ..."

    python3 - "$FORCE_UPDATE_SCRIPT" <<'PY'
import subprocess
import sys
import threading

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, GLib, Gtk

helper = sys.argv[1]

CSS = b"""
window {
    background: #17171c;
    color: #f4f4f5;
}
.update-box {
    background: #232329;
    border: 1px solid #34343c;
    border-radius: 10px;
    padding: 14px 16px;
}
.update-title {
    color: #f4f4f5;
    font-size: 17px;
    font-weight: 800;
}
.update-status {
    color: #f5a623;
    font-size: 12px;
    font-weight: 700;
}
.update-status.status-orange { color: #f5a623; }
.update-status.status-blue   { color: #5aa2ff; }
.update-status.status-green  { color: #61d36b; }
.update-status.status-red    { color: #ff4c4c; }
"""


class StartupUpdate(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.david.UwuntuStartupUpdate")
        self.window = None
        self.status_label = None
        self.result_code = 0

    def do_activate(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        display = Gdk.Display.get_default()
        if display is not None:
            Gtk.StyleContext.add_provider_for_display(
                display,
                provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            )

        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_title("Uwuntu Update")
        self.window.set_default_size(560, 145)
        self.window.set_resizable(False)
        try:
            self.window.set_deletable(False)
        except Exception:
            pass

        outer = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=12,
        )
        outer.set_margin_top(16)
        outer.set_margin_bottom(16)
        outer.set_margin_start(18)
        outer.set_margin_end(18)
        outer.add_css_class("update-box")

        title = Gtk.Label(label="UWUNTU UPDATE")
        title.set_xalign(0)
        title.add_css_class("update-title")
        outer.append(title)

        self.status_label = Gtk.Label(
            label="Prüfe GitHub vor dem Programmstart …"
        )
        self.status_label.set_xalign(0)
        self.status_label.set_wrap(True)
        self.status_label.add_css_class("update-status")
        self.status_label.add_css_class("status-orange")
        outer.append(self.status_label)

        self.window.set_child(outer)
        self.window.present()

        threading.Thread(
            target=self.worker,
            name="uwuntu-startup-update",
            daemon=True,
        ).start()

    def set_status(self, text):
        if self.status_label is None:
            return False

        self.status_label.set_text(text)
        for css_class in (
            "status-orange",
            "status-blue",
            "status-green",
            "status-red",
        ):
            self.status_label.remove_css_class(css_class)

        normalized = (text or "").strip()
        if normalized.startswith("FEHLER:"):
            color = "red"
        elif (
            normalized.startswith("Update gefunden")
            or normalized.startswith("Installiere")
            or normalized.startswith("Update erfolgreich")
        ):
            color = "blue"
        elif (
            normalized == "Bereits aktuell"
            or "starte lokalen Stand" in normalized
        ):
            color = "green"
        else:
            color = "orange"

        self.status_label.add_css_class("status-" + color)
        return False

    def finish(self):
        if self.window is not None:
            try:
                self.window.close()
            except Exception:
                pass
        self.quit()
        return False

    def worker(self):
        try:
            proc = subprocess.Popen(
                [helper, "--startup-check"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            if proc.stdout is not None:
                for raw in proc.stdout:
                    line = raw.strip()
                    if not line.startswith("STATUS|"):
                        continue
                    status = line.split("|", 1)[1].strip()
                    GLib.idle_add(self.set_status, status)

            self.result_code = proc.wait()
        except Exception as exc:
            self.result_code = 99
            GLib.idle_add(self.set_status, f"FEHLER: {exc}")

        if self.result_code == 0:
            delay_ms = 250
        elif self.result_code == 10:
            delay_ms = 550
        else:
            delay_ms = 1200

        GLib.timeout_add(delay_ms, self.finish)


app = StartupUpdate()
app.run([])
raise SystemExit(app.result_code)
PY
    return $?
}

run_startup_update_preflight
STARTUP_UPDATE_RC=$?

if [ "$STARTUP_UPDATE_RC" -eq 10 ]; then
    echo "Update wurde vor dem App-Start installiert; starte den neuen Kiosk-Stand."

    if [ -x "$KIOSK_SELF" ]; then
        export UWUNTU_SKIP_STARTUP_UPDATE=1
        exec "$KIOSK_SELF"
    fi

    echo "WARNUNG: Neuer Kiosk-Launcher fehlt nach Update; fahre lokal fort."
elif [ "$STARTUP_UPDATE_RC" -ne 0 ]; then
    echo "WARNUNG: Startup-Updateprüfung fehlgeschlagen (Code $STARTUP_UPDATE_RC)."
    echo "Der vorhandene lokale Uwuntu-Stand wird trotzdem gestartet."
fi

# ------------------------------------------------------------
# Bildschirmhelligkeit auf Maximum
# ------------------------------------------------------------

set_max_brightness() {
    echo "Setze Bildschirmhelligkeit auf Maximum ..."

    if command -v brightnessctl >/dev/null 2>&1; then
        if brightnessctl -q set 100% >/dev/null 2>&1; then
            echo "Bildschirmhelligkeit: 100% (brightnessctl)"
            return 0
        fi
    fi

    local changed=0
    local dev max value_file
    for dev in /sys/class/backlight/*; do
        [ -d "$dev" ] || continue

        max="$(cat "$dev/max_brightness" 2>/dev/null || true)"
        value_file="$dev/brightness"

        [ -n "$max" ] || continue

        if [ -w "$value_file" ]; then
            printf '%s\n' "$max" > "$value_file" 2>/dev/null || true
        elif sudo -n true >/dev/null 2>&1; then
            printf '%s\n' "$max" \
                | sudo -n tee "$value_file" >/dev/null 2>&1 || true
        fi
        if [ "$(cat "$value_file" 2>/dev/null || true)" = "$max" ]; then
            changed=1
        fi
    done

    if [ "$changed" -eq 1 ]; then
        echo "Bildschirmhelligkeit: Maximum (sysfs)"
    else
        echo "WARNUNG: Bildschirmhelligkeit konnte nicht gesetzt werden."
    fi
}

set_max_brightness

# ------------------------------------------------------------
# Ubuntu-Dock / Taskleiste automatisch ausblenden
# ------------------------------------------------------------

set_dock_autohide() {
    echo "Setze Ubuntu-Dock auf Auto-Hide ..."

    if ! command -v gsettings >/dev/null 2>&1; then
        echo "Hinweis: gsettings nicht vorhanden – Dock-Einstellung übersprungen."
        return 0
    fi

    local schema="org.gnome.shell.extensions.dash-to-dock"

    if ! gsettings list-schemas 2>/dev/null \
        | grep -Fxq "$schema"
    then
        echo "Hinweis: Ubuntu-Dock-Schema nicht vorhanden – übersprungen."
        return 0
    fi

    # Die bestehende Position (beim Uwuntu-Stick links) bleibt unberührt.
    gsettings set "$schema" dock-fixed false \
        >/dev/null 2>&1 || true
    gsettings set "$schema" autohide true \
        >/dev/null 2>&1 || true
    gsettings set "$schema" intellihide false \
        >/dev/null 2>&1 || true

    local current_position
    current_position="$(
        gsettings get "$schema" dock-position 2>/dev/null || echo "unbekannt"
    )"

    echo "Ubuntu-Dock: Auto-Hide aktiv, Position unverändert (${current_position})."
    return 0
}

set_dock_autohide

# ------------------------------------------------------------
# 1) Auf Tiling Assistant warten
# ------------------------------------------------------------

echo "Warte auf Tiling Assistant ..."

TILING_READY=0
TILING_LOOPS="$(python3 -c "print(int(${MAX_TILING_WAIT_SECONDS}/${POLL_SECONDS}))")"
for i in $(seq 1 "$TILING_LOOPS"); do
    if gnome-extensions info tiling-assistant@ubuntu.com 2>/dev/null \
        | grep -qE 'State:[[:space:]]*ACTIVE|ACTIVE'
    then
        TILING_READY=1
        break
    fi

    sleep "$POLL_SECONDS"
done

if [ "$TILING_READY" -ne 1 ]; then
    echo "FEHLER: Tiling Assistant wurde nach ${MAX_TILING_WAIT_SECONDS}s nicht ACTIVE."
    exit 30
fi

echo "Tiling Assistant ist bereit."
# AT-SPI für den abschließenden, gezielten Tastaturfokus aktivieren.
OLD_TOOLKIT_ACCESSIBILITY="$(
    gsettings get org.gnome.desktop.interface toolkit-accessibility 2>/dev/null         || echo false
)"
ACCESSIBILITY_CHANGED=0

if [ "$OLD_TOOLKIT_ACCESSIBILITY" != "true" ]; then
    gsettings set org.gnome.desktop.interface toolkit-accessibility true         >/dev/null 2>&1 || true
    ACCESSIBILITY_CHANGED=1
fi
restore_accessibility() {
    if [ "$ACCESSIBILITY_CHANGED" -eq 1 ]; then
        gsettings set org.gnome.desktop.interface toolkit-accessibility             "$OLD_TOOLKIT_ACCESSIBILITY" >/dev/null 2>&1 || true
        ACCESSIBILITY_CHANGED=0
    fi
}

trap restore_accessibility EXIT
# ------------------------------------------------------------
# 2) Auf ydotool warten
# ------------------------------------------------------------

find_socket() {
    for s in \
        "/run/ydotool-kiosk.sock" \
        "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket" \
        "/run/user/$(id -u)/.ydotool_socket" \
        "/tmp/.ydotool_socket"
    do
        if [ -S "$s" ] && [ -w "$s" ]; then
            echo "$s"
            return 0
        fi
    done

    return 1
}
echo "Warte auf ydotool ..."

YD_SOCKET=""
SOCKET_LOOPS="$(python3 -c "print(int(${MAX_SOCKET_WAIT_SECONDS}/${POLL_SECONDS}))")"

for i in $(seq 1 "$SOCKET_LOOPS"); do
    YD_SOCKET="$(find_socket || true)"

    if [ -n "$YD_SOCKET" ]; then
        break
    fi

    sleep "$POLL_SECONDS"
done

if [ -z "$YD_SOCKET" ]; then
    echo "FEHLER: Kein nutzbarer ydotool-Socket nach ${MAX_SOCKET_WAIT_SECONDS}s."
    exit 31
fi

export YDOTOOL_SOCKET="$YD_SOCKET"
echo "ydotool ist bereit: $YDOTOOL_SOCKET"

# ------------------------------------------------------------
# 3) Touchscreen: falls vorhanden, VOR allen Diagnosefenstern testen
# ------------------------------------------------------------
has_touchscreen() {
    local dev
    for dev in /dev/input/event*; do
        [ -e "$dev" ] || continue
        if udevadm info --query=property --name="$dev" 2>/dev/null \
            | grep -q '^ID_INPUT_TOUCHSCREEN=1$'
        then
            return 0
        fi
    done
    return 1
}

# Ergebnis gehört immer nur zum aktuell getesteten Notebook.
rm -f "$HOME/.local/state/uwuntu/touch_tester_status.json" 2>/dev/null || true
rm -f "$HOME/.local/state/uwuntu/display_test_status.json" 2>/dev/null || true

if has_touchscreen; then
    echo "Touchscreen erkannt: Touch-Test startet vor dem 4-Felder-Layout ..."

    if [ -x "$HOME/.local/bin/uwuntu-touch-tester.sh" ]; then
        "$HOME/.local/bin/uwuntu-touch-tester.sh" >>"$LOG" 2>&1 &
        TOUCH_PID=$!
        # Solange der fullscreen XWayland-Touch-Tester offen ist, werden die
        # vier Diagnosefenster bewusst noch NICHT gestartet.
        wait "$TOUCH_PID" || true
        echo "Touch-Test geschlossen/abgeschlossen; starte jetzt das 4-Felder-Layout."
    else
        echo "WARNUNG: Touch-Tester ist nicht installiert."
    fi
else
    echo "Kein Touchscreen erkannt: Touch-Test wird nicht automatisch gestartet."
fi

# ------------------------------------------------------------
# 4) Tiling-Assistant-Layout EINMAL starten
#
# Das Layout selbst startet:
#   oben links   Network Check + Wipe Auto
#   oben rechts  Uwuntu Kamera Test
#   unten links  Uwuntu Audio Test
#   unten rechts Hardware Check
#
# Firefox ist vollständig aus dem Kiosk entfernt.
# ------------------------------------------------------------

# Das Dock wurde bereits beim Kiosk-Start auf Auto-Hide gesetzt.
# Nach Touch-Test/Boot kann GNOME die nutzbare Arbeitsfläche aber noch einen
# kurzen Moment mit der alten Dock-Breite melden. Deshalb unmittelbar vor dem
# Tiling noch einmal erzwingen und die Dock-Animation/Workarea stabilisieren.
echo "Bereite freie Arbeitsfläche für 4-Felder-Layout vor ..."
set_dock_autohide
sleep 1.2

echo "Starte 4-Felder-Layout mit Strg+D ..."

/usr/bin/ydotool key 29:1 32:1 32:0 29:0

echo "Layout-Aufruf gesendet."
# ------------------------------------------------------------
# Kamera-Test erst sichtbar werden lassen
# ------------------------------------------------------------
# Der Kamera-Test ersetzt Snapshot und muss vor dem späteren Wipe-Fokus
# stabil im oberen rechten Feld stehen.
echo "Warte kurz auf das Kamera-Test-Fenster ..."

if python3 - <<'PY'
import time
import pyatspi
MAX_SECONDS = 12.0
STABLE_SECONDS = 1.2
POLL_SECONDS = 0.12

deadline = time.monotonic() + MAX_SECONDS
last_geometry = None
stable_since = None

def geometry(obj):
    try:
        e = obj.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
        if e.width > 100 and e.height > 100:
            return (e.x, e.y, e.width, e.height)
    except Exception:
        pass
    return None

def find_camera_window():
    try:
        desktop = pyatspi.Registry.getDesktop(0)
    except Exception:
        return None

    try:
        app_count = desktop.childCount
    except Exception:
        app_count = 0

    for i in range(app_count):
        try:
            app = desktop.getChildAtIndex(i)
            app_name = (app.name or "").strip().lower()
            child_count = app.childCount
        except Exception:
            continue
        for j in range(child_count):
            try:
                child = app.getChildAtIndex(j)
                role = child.getRoleName()
                child_name = (child.name or "").strip().lower()
            except Exception:
                continue

            if role not in ("frame", "window", "dialog"):
                continue

            haystack = f"{app_name} {child_name}"
            if "uwuntu kamera test" not in haystack and "kamera test" not in haystack:
                continue
            g = geometry(child)
            if g:
                return g

    return None

while time.monotonic() < deadline:
    current = find_camera_window()

    if current is None:
        last_geometry = None
        stable_since = None
        time.sleep(POLL_SECONDS)
        continue
    if current != last_geometry:
        last_geometry = current
        stable_since = time.monotonic()
    elif stable_since is not None and time.monotonic() - stable_since >= STABLE_SECONDS:
        raise SystemExit(0)

    time.sleep(POLL_SECONDS)

raise SystemExit(1)
PY
then
    echo "Kamera-Test-Fenster ist bereit."
else
    echo "WARNUNG: Kamera-Test-Fenster nach 12s nicht eindeutig erkannt."
    echo "Fokus wird trotzdem fortgesetzt."
fi
# ------------------------------------------------------------
# Hardware Check ebenfalls vollständig erscheinen lassen
# ------------------------------------------------------------
# Das neue vierte Fenster darf nach dem finalen Wipe-Fokus nicht verspätet
# auftauchen und den Fokus wieder stehlen. Deshalb warten wir hier
# zustandsbasiert auf ein stabiles Hardware-Check-Fenster.
echo "Warte kurz auf das Hardware-Check-Fenster ..."

if python3 - <<'PY'
import time
import pyatspi
MAX_SECONDS = 12.0
STABLE_SECONDS = 0.8
POLL_SECONDS = 0.12

deadline = time.monotonic() + MAX_SECONDS
last_geometry = None
stable_since = None

def geometry(obj):
    try:
        e = obj.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
        if e.width > 100 and e.height > 100:
            return (e.x, e.y, e.width, e.height)
    except Exception:
        pass
    return None
def find_hardware_check_window():
    try:
        desktop = pyatspi.Registry.getDesktop(0)
    except Exception:
        return None

    try:
        app_count = desktop.childCount
    except Exception:
        app_count = 0

    for i in range(app_count):
        try:
            app = desktop.getChildAtIndex(i)
            app_name = (app.name or "").strip().lower()
            child_count = app.childCount
        except Exception:
            continue
        for j in range(child_count):
            try:
                child = app.getChildAtIndex(j)
                role = child.getRoleName()
                child_name = (child.name or "").strip().lower()
            except Exception:
                continue

            if role not in ("frame", "window", "dialog"):
                continue

            haystack = f"{app_name} {child_name}"
            if "hardware check" not in haystack and "hardwarecheck" not in haystack:
                continue
            g = geometry(child)
            if g:
                return g

    return None

while time.monotonic() < deadline:
    current = find_hardware_check_window()

    if current is None:
        last_geometry = None
        stable_since = None
        time.sleep(POLL_SECONDS)
        continue
    if current != last_geometry:
        last_geometry = current
        stable_since = time.monotonic()
    elif stable_since is not None and time.monotonic() - stable_since >= STABLE_SECONDS:
        raise SystemExit(0)

    time.sleep(POLL_SECONDS)

raise SystemExit(1)
PY
then
    echo "Hardware-Check-Fenster ist bereit."
else
    echo "WARNUNG: Hardware Check nach 12s nicht eindeutig erkannt."
    echo "Fokus wird trotzdem versucht."
fi

# Keine separate 90-Sekunden-App-Erkennung mehr.
# Die anschließende AT-SPI-Fokusprüfung wartet selbst darauf,
# dass Wipe Auto und der Button LÖSCHEN wirklich vorhanden sind.
# Dadurch gibt es beim Boot keinen unnötigen 90s-Timeout mehr.
# Wipe Auto sitzt jetzt im gemeinsamen Network-Check-Fenster oben links.
# Deshalb gezielt dieses Fenster aktivieren und danach den eingebetteten
# WIPE-SSD-Button fokussieren.
#
# Update- und Shortcut-Fenster haben Vorrang. Solange eines davon sichtbar
# ist, darf der abschließende Wipe-Fokus das Network/Wipe-Fenster nicht nach
# vorne holen. Nach dem Schließen wird der normale LÖSCHEN-Fokus fortgesetzt.
echo "Prüfe auf vorrangige Uwuntu-Fenster vor dem LÖSCHEN-Fokus ..."
if ! python3 - <<'PY'
import time
import pyatspi

PRIORITY_TITLES = {"Uwuntu Update", "Shortcuts / Hotkeys"}
MAX_WAIT_SECONDS = 120.0
POLL_SECONDS = 0.20
deadline = time.monotonic() + MAX_WAIT_SECONDS
last_titles = None


def walk(obj, depth=0):
    if depth > 4:
        return
    try:
        count = obj.childCount
    except Exception:
        count = 0
    for index in range(count):
        try:
            child = obj.getChildAtIndex(index)
        except Exception:
            continue
        yield child
        yield from walk(child, depth + 1)


def visible_priority_titles():
    try:
        desktop = pyatspi.Registry.getDesktop(0)
        app_count = desktop.childCount
    except Exception:
        return set()

    found = set()
    for app_index in range(app_count):
        try:
            app = desktop.getChildAtIndex(app_index)
        except Exception:
            continue

        for candidate in walk(app):
            try:
                role = (candidate.getRoleName() or "").lower()
                title = (candidate.name or "").strip()
            except Exception:
                continue

            if role not in ("dialog", "frame", "window"):
                continue
            if title not in PRIORITY_TITLES:
                continue

            try:
                state = candidate.getState()
                if not state.contains(pyatspi.STATE_SHOWING):
                    continue
            except Exception:
                pass

            found.add(title)

    return found


while True:
    titles = visible_priority_titles()
    if not titles:
        raise SystemExit(0)

    if titles != last_titles:
        print(
            "Vorrangiges Fenster offen: " + ", ".join(sorted(titles))
            + " · LÖSCHEN-Fokus wartet.",
            flush=True,
        )
        last_titles = titles

    if time.monotonic() >= deadline:
        print(
            "WARNUNG: Vorrangiges Fenster nach 120s noch offen · "
            "LÖSCHEN-Fokus wird für diesen Start ausgelassen.",
            flush=True,
        )
        raise SystemExit(2)

    time.sleep(POLL_SECONDS)
PY
then
    echo "Vorrangiges Fenster blieb offen; LÖSCHEN-Fokus wird nicht erzwungen."
    restore_accessibility
    echo "Kiosk fertig ohne erzwungenen LÖSCHEN-Fokus: $(date)"
    exit 0
fi

if command -v gapplication >/dev/null 2>&1; then
    gapplication activate com.david.NetworkCheck >/dev/null 2>&1 || true
else
    gtk-launch com.david.NetworkCheck >/dev/null 2>&1 || true
fi
# Mutter/Tiling Assistant kurz Zeit geben, das gemeinsame Fenster wirklich
# zum aktiven Vordergrundfenster zu machen. Nach dem Dock-/Workarea-Wechsel
# etwas großzügiger warten. Danach fokussiert zusätzlich die App selbst
# LÖSCHEN; AT-SPI bleibt als zweite Absicherung erhalten.
sleep 0.45

echo "Fokussiere LÖSCHEN im gemeinsamen Network/Wipe-Fenster ..."
FOCUS_OK=0

if python3 - <<'PY'
import os
import subprocess
import time
import pyatspi

MAX_SECONDS = 12.0
POLL_SECONDS = 0.12
deadline = time.monotonic() + MAX_SECONDS
safe_clicks = 0
last_click_at = 0.0

def walk(obj):
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
        yield from walk(child)

def get_extents(obj):
    try:
        ext = obj.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
        if ext.width > 1 and ext.height > 1:
            return ext
    except Exception:
        pass
    return None

def find_targets():
    try:
        desktop = pyatspi.Registry.getDesktop(0)
    except Exception:
        return None, None, None

    network_window = None
    wipe_button = None
    safe_ssd_label = None

    try:
        app_count = desktop.childCount
    except Exception:
        app_count = 0

    for i in range(app_count):
        try:
            app = desktop.getChildAtIndex(i)
            app_name = (app.name or "").strip().lower()
        except Exception:
            continue

        # Erst das konkrete Network-Check-Fenster finden.
        for item in walk(app):
            try:
                name = (item.name or "").strip()
                name_l = name.lower()
                role = item.getRoleName()
            except Exception:
                continue

            if role in ("frame", "window", "dialog"):
                if (
                    "network check" in name_l
                    or "networkcheck" in name_l
                    or "network check" in app_name
                    or "networkcheck" in app_name
                ):
                    if get_extents(item) is not None:
                        network_window = item

        if network_window is None:
            continue

        # Nur innerhalb dieses Fensters nach SSD-Label und LÖSCHEN suchen.
        for item in walk(network_window):
            try:
                name = (item.name or "").strip()
                role = item.getRoleName()
            except Exception:
                continue

            if name == "LÖSCHEN" and role in ("push button", "button"):
                wipe_button = item

            if name == "SSD" and role in ("label", "text"):
                if get_extents(item) is not None:
                    safe_ssd_label = item

        if wipe_button is not None:
            return network_window, wipe_button, safe_ssd_label

    return network_window, wipe_button, safe_ssd_label

def is_focused(obj):
    try:
        return bool(obj.getState().contains(pyatspi.STATE_FOCUSED))
    except Exception:
        return False

def atspi_focus(window, button):
    # Erst das Fenster, dann den Button. Unter Wayland ist dies allein
    # nicht immer genug, schadet aber nicht und funktioniert auf manchen
    # Systemen bereits vollständig.
    try:
        window.queryComponent().grabFocus()
    except Exception:
        pass
    try:
        button.queryComponent().grabFocus()
    except Exception:
        pass

def safe_activate_with_ydotool(label, window):
    """Aktiviere Network/Wipe nur über einen sicheren Punkt IM Fenster.

    Frühere Versionen nutzten bevorzugt die AT-SPI-Koordinaten des SSD-Labels.
    Während GNOME gerade das Dock ein-/ausblendet oder Fenster neu tiled,
    können diese Label-Koordinaten kurzzeitig falsch sein. Dann konnte ein
    Klick versehentlich im oberen GNOME-Panel auf Uhr/Benachrichtigungen landen.

    Deshalb wird ausschließlich die Fenstergeometrie verwendet. Der Klickpunkt
    liegt fest im oberen Inhaltsbereich und hängt nicht von der Fensterhöhe ab.
    Ist die Geometrie nicht plausibel, findet überhaupt kein Pointer-Klick statt.
    """
    win = get_extents(window)
    if win is None:
        return False

    # Nur auf ein plausibel großes, tatsächlich dargestelltes Fenster klicken.
    if win.width < 300 or win.height < 220:
        return False

    # Sicherer Punkt im OBEREN Inhaltsbereich des Network/Wipe-Fensters.
    # Wichtig: Die Y-Position hängt absichtlich NICHT von der gemeldeten
    # Fensterhöhe ab. Falls GNOME während eines Re-Tilings vorübergehend eine
    # zu große Höhe meldet, kann der Klick dadurch nicht in das darunter
    # liegende Audio-Fenster abrutschen.
    x = int(win.x + max(70, min(110, win.width * 0.10)))
    y = int(win.y + 92)

    # Niemals in den oberen GNOME-Panel-/Titelleistenbereich klicken.
    if y < 72:
        return False

    # Der Zielpunkt muss eindeutig innerhalb der gemeldeten Fenstergrenzen
    # liegen; andernfalls kein synthetischer Klick.
    if not (win.x + 8 <= x <= win.x + win.width - 8):
        return False
    if not (win.y + 58 <= y <= win.y + win.height - 8):
        return False

    env = os.environ.copy()

    # Je nach ydotool-Version funktionieren beide dokumentierten Formen.
    commands = [
        ["ydotool", "mousemove", "--absolute", str(x), str(y)],
        ["ydotool", "mousemove", "--absolute", "-x", str(x), "-y", str(y)],
    ]

    moved = False
    for cmd in commands:
        try:
            p = subprocess.run(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=1.5,
                env=env,
                check=False,
            )
            if p.returncode == 0:
                moved = True
                break
        except Exception:
            pass

    if not moved:
        return False

    try:
        p = subprocess.run(
            ["ydotool", "click", "0xC0"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1.5,
            env=env,
            check=False,
        )
        return p.returncode == 0
    except Exception:
        return False

while time.monotonic() < deadline:
    window, button, ssd_label = find_targets()

    if window is not None and button is not None:
        atspi_focus(window, button)
        time.sleep(0.08)

        if is_focused(button):
            raise SystemExit(0)

        # Wenn AT-SPI nur den internen Widget-Fokus setzt, aber das Wayland-
        # Fenster nicht wirklich aktiv wird, simulieren wir einen harmlosen
        # echten Klick auf einen validierten sicheren Punkt IM Fenster.
        now = time.monotonic()
        if safe_clicks < 3 and now - last_click_at >= 0.75:
            if safe_activate_with_ydotool(ssd_label, window):
                safe_clicks += 1
                last_click_at = now
                time.sleep(0.18)

                # Durch die echte Fensteraktivierung feuert zusätzlich
                # notify::is-active in der GTK-App und fokussiert LÖSCHEN.
                # Zweimal kurz nachfassen, weil Mutter unter Wayland das
                # Aktivierungsereignis leicht verzögert zustellen kann.
                atspi_focus(window, button)
                time.sleep(0.12)
                atspi_focus(window, button)
                time.sleep(0.12)

                if is_focused(button):
                    raise SystemExit(0)

    time.sleep(POLL_SECONDS)

raise SystemExit(1)
PY
then
    FOCUS_OK=1
    echo "OK: LÖSCHEN hat bestätigten Tastaturfokus."
else
    echo "WARNUNG: LÖSCHEN konnte nicht sicher fokussiert werden."
fi
restore_accessibility

echo "Kiosk fertig: $(date)"
