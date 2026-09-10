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

export GDK_BACKEND=x11

if [[ -z "${DISPLAY:-}" ]]; then
    echo "Display-Test: Kein X11/XWayland DISPLAY gefunden."
    exit 4
fi

REQUIRED_PKGS=(python3-gi gir1.2-gtk-3.0)
missing=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done

if ((${#missing[@]})); then
    if command -v pkexec >/dev/null 2>&1; then
        pkexec env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" || exit 1
    else
        sudo apt-get install -y "${missing[@]}" || exit 1
    fi
fi

exec -a uwuntu-display-test-python python3 - <<'PY'
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib

STATE_DIR = Path.home() / ".local" / "state" / "uwuntu"
STATE_FILE = STATE_DIR / "display_test_status.json"

SCREENS = [
    ("Weiß", (1.0, 1.0, 1.0)),
    ("Rot", (1.0, 0.0, 0.0)),
    ("Grün", (0.0, 1.0, 0.0)),
    ("Blau", (0.0, 0.0, 1.0)),
    ("Grau", (0.5, 0.5, 0.5)),
    ("Schwarz-Weiß Farbverlauf", None),
]
TOTAL = len(SCREENS)


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def write_state(result, index=0, note=None):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    index = max(0, min(int(index), TOTAL - 1))
    data = {
        "test": "display",
        "result": result,
        "screen_index": index,
        "screen_number": index + 1,
        "total_screens": TOTAL,
        "screen_name": SCREENS[index][0],
        "timestamp": now_iso(),
    }
    if note:
        data["note"] = note
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(STATE_FILE)


class DisplayArea(Gtk.EventBox):
    def __init__(self, owner):
        super().__init__()
        self.owner = owner
        self.set_name("display_surface")
        self.set_visible_window(True)
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.TOUCH_MASK)
        self.connect("button-press-event", self.on_button)
        self.connect("touch-event", self.on_touch)

        # Den Hintergrund NICHT mehr über Cairo/"draw" erzeugen. Auf einigen
        # Uwuntu/XWayland-Systemen wurde der DrawingArea-Renderpfad vom Theme /
        # Compositor überlagert und erschien dadurch unabhängig von der
        # Sollfarbe grau. Eine sichtbare EventBox mit lokalem USER-CSS malt
        # ihren eigenen deckenden Hintergrund direkt über GTK.
        self.provider = Gtk.CssProvider()
        self.get_style_context().add_provider(
            self.provider,
            Gtk.STYLE_PROVIDER_PRIORITY_USER,
        )
        self.apply_screen()

    def apply_screen(self):
        name, color = SCREENS[self.owner.index]
        if color is None:
            background = (
                "background-color: #000000; "
                "background-image: linear-gradient(to right, #000000, #ffffff);"
            )
        else:
            r = max(0, min(255, int(round(color[0] * 255))))
            g = max(0, min(255, int(round(color[1] * 255))))
            b = max(0, min(255, int(round(color[2] * 255))))
            background = (
                f"background-color: rgb({r},{g},{b}); "
                "background-image: none;"
            )

        css = (
            "#display_surface { "
            f"{background} "
            "border: none; box-shadow: none; padding: 0; margin: 0; "
            "}"
        ).encode("utf-8")
        try:
            self.provider.load_from_data(css)
        except Exception as exc:
            write_state(
                "error",
                self.owner.index,
                f"Display-CSS konnte nicht gesetzt werden: {exc}",
            )
        self.queue_draw()

    def on_button(self, widget, event):
        # Manche XWayland-Treiber erzeugen direkt nach einem Touch zusätzlich
        # ein emuliertes Mausereignis. Dieses nicht doppelt werten.
        if time.monotonic() - self.owner.last_touch_at < 0.35:
            return True
        if event.button == 1:
            self.owner.next_screen()
            return True
        if event.button == 3:
            self.owner.previous_screen()
            return True
        return True

    def on_touch(self, widget, event):
        if event.type != Gdk.EventType.TOUCH_BEGIN:
            return True
        self.owner.last_touch_at = time.monotonic()
        width = max(1, self.get_allocated_width())
        if event.x >= width / 2.0:
            self.owner.next_screen()
        else:
            self.owner.previous_screen()
        return True

class DisplayWindow(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_title("Uwuntu Display-Test")
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_accept_focus(True)
        self.set_focus_on_map(True)
        self.index = 0
        self.finished = False
        self.front_attempts = 0
        self.last_touch_at = 0.0

        # Schwarzer Fallback-Hintergrund am Top-Level. Die eigentliche
        # Testfarbe kommt deckend von DisplayArea/EventBox.
        self.window_provider = Gtk.CssProvider()
        self.window_provider.load_from_data(b"window { background: #000000; }")
        self.get_style_context().add_provider(
            self.window_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_USER,
        )

        self.area = DisplayArea(self)
        self.add(self.area)
        self.connect("key-press-event", self.on_key)
        self.connect("delete-event", self.on_delete)
        self.connect("realize", self.on_realize)

        self.fullscreen()
        self.show_all()
        self.present()
        self.grab_focus()
        GLib.idle_add(self.redraw)
        GLib.timeout_add(150, self.force_front)
        write_state("running", self.index, "Display-Test gestartet")

    def on_realize(self, *_):
        try:
            display = Gdk.Display.get_default()
            cursor = Gdk.Cursor.new_for_display(display, Gdk.CursorType.BLANK_CURSOR)
            self.get_window().set_cursor(cursor)
        except Exception:
            pass

    def force_front(self):
        if self.finished:
            return False
        self.front_attempts += 1
        try:
            self.set_keep_above(True)
            self.present()
            self.grab_focus()
        except Exception:
            pass
        return self.front_attempts < 12

    def redraw(self):
        self.area.apply_screen()
        write_state("running", self.index, f"Anzeige: {SCREENS[self.index][0]}")

    def next_screen(self):
        if self.finished:
            return
        if self.index >= TOTAL - 1:
            self.finish_success()
            return
        self.index += 1
        self.redraw()

    def previous_screen(self):
        if self.finished:
            return
        if self.index > 0:
            self.index -= 1
            self.redraw()

    def finish_success(self):
        if self.finished:
            return
        self.finished = True
        write_state("success", TOTAL - 1, "Alle Display-Farben vollständig geprüft")
        Gtk.main_quit()

    def abort(self, reason="Display-Test abgebrochen"):
        if self.finished:
            return
        self.finished = True
        write_state("aborted", self.index, reason)
        Gtk.main_quit()

    def abort_all(self):
        if not self.finished:
            self.finished = True
            write_state("aborted", self.index, "Display-Test durch STRG+Q abgebrochen")
        helper = Path.home() / ".local/bin/close-diagnostic-apps.sh"
        try:
            subprocess.Popen(
                [str(helper)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception:
            pass
        Gtk.main_quit()

    def on_key(self, widget, event):
        ctrl = bool(event.state & Gdk.ModifierType.CONTROL_MASK)
        if event.keyval == Gdk.KEY_Escape:
            self.abort("Display-Test mit ESC abgebrochen")
            return True
        if ctrl and event.keyval in (Gdk.KEY_w, Gdk.KEY_W):
            self.abort("Display-Test mit STRG+W abgebrochen")
            return True
        if ctrl and event.keyval in (Gdk.KEY_q, Gdk.KEY_Q):
            self.abort_all()
            return True
        if event.keyval in (Gdk.KEY_Right, Gdk.KEY_space):
            self.next_screen()
            return True
        if event.keyval == Gdk.KEY_Left:
            self.previous_screen()
            return True
        return True

    def on_delete(self, *_):
        self.abort("Display-Test durch Fenster-Schließen abgebrochen")
        return True


win = DisplayWindow()
Gtk.main()
PY
