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

# Let GTK connect to the X server provided by XWayland, even when the
# desktop session itself is Wayland.
export GDK_BACKEND=x11

if [[ -z "${DISPLAY:-}" ]]; then
  echo "Touch-Tester: Kein X11/XWayland DISPLAY gefunden."
  echo "DISPLAY ist nicht gesetzt; dieser Transparenz-Test kann so nicht starten."
  exit 4
fi

exec -a uwuntu-touch-tester-python python3 - <<'PY'
import sys, json, glob, subprocess
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path.home() / ".local" / "state" / "uwuntu"
STATE_FILE = STATE_DIR / "touch_tester_status.json"
TOTAL = 5


def now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def write_state(result, completed=0, device=None, note=None):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    data = {
        "test": "touchscreen",
        "result": result,
        "completed_fields": completed,
        "total_fields": TOTAL,
        "variant": "xwayland-rgba-final",
        "timestamp": now_iso(),
    }
    if device:
        data["device"] = device
    if note:
        data["note"] = note
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(STATE_FILE)


def find_touchscreen():
    for dev in sorted(glob.glob("/dev/input/event*")):
        try:
            p = subprocess.run(
                ["udevadm", "info", "--query=property", f"--name={dev}"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        props = {}
        for line in p.stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k] = v
        if props.get("ID_INPUT_TOUCHSCREEN") == "1":
            name = props.get("NAME") or props.get("ID_MODEL_FROM_DATABASE") or props.get("ID_MODEL")
            return dev, name
    return None, None


device, device_name = find_touchscreen()
if not device:
    write_state("no_touchscreen", note="Kein Touchscreen über udev erkannt")
    print("Touch-Tester: Kein Touchscreen erkannt.")
    sys.exit(2)

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gtk, Gdk, GLib
except Exception as exc:
    write_state("error", device=device, note=f"GTK3/PyGObject fehlt: {exc}")
    print("Touch-Tester: GTK3/PyGObject konnte nicht geladen werden.")
    print(f"Fehler: {exc}")
    print("Falls nötig: sudo apt install gir1.2-gtk-3.0")
    sys.exit(3)


CSS = b"""
window#touch_host {
    background-color: rgba(0,0,0,0);
    background-image: none;
}
.touch-target {
    background-color: #ff4c4c;
    border: 5px solid #f4f4f5;
    border-radius: 14px;
    box-shadow: 0 4px 22px rgba(0,0,0,0.80);
}
.touch-target.target-red   { background-color: #ff4c4c; }
.touch-target.target-blue  { background-color: #5aa2ff; }
.touch-target.target-green { background-color: #61d36b; }
.target-label {
    color: #f4f4f5;
    font-size: 14px;
    font-weight: 800;
}
.title-panel {
    background-color: rgba(18,18,18,0.78);
    border: 2px solid #f4f4f5;
    border-radius: 14px;
    box-shadow: 0 5px 28px rgba(0,0,0,0.75);
    padding: 13px 20px;
}
.main-title {
    color: #f4f4f5;
    font-size: 30px;
    font-weight: 900;
}
.progress {
    color: #f4f4f5;
    font-size: 15px;
    font-weight: 800;
}
.progress-ready {
    color: #61d36b;
}
.hint {
    color: #9d9da7;
    font-size: 11px;
}
"""


# TOUCH_LAYOUT_START
def calculate_touch_layout(width, height):
    """Berechne das Layout vollständig in logischen GTK-Koordinaten.

    size-allocate, set_size_request() und Gtk.Fixed.move() verwenden dieselbe
    Koordinatenbasis. Der GDK-Skalierungsfaktor wird erst bei der Ausgabe in
    Gerätepixel umgesetzt und darf auch unter XWayland/Fractional Scaling
    nicht ein zweites Mal in diese Rechnung einfließen.
    """
    sw, sh = max(1, int(width)), max(1, int(height))
    scale = min(sw / 1366.0, sh / 768.0, 1.25)

    margin_x = min(max(0, int(round(125 * scale))), sw // 4)
    margin_y = min(max(0, int(round(85 * scale))), sh // 4)
    target_w = min(max(1, int(round(160 * scale))), max(1, sw - 2 * margin_x))
    target_h = min(max(1, int(round(115 * scale))), max(1, sh - 2 * margin_y))
    # Gleiche Parität ermöglicht auch bei ganzzahligen GTK-Koordinaten ein
    # mathematisch exakt zentriertes mittleres Feld.
    if target_w % 2 != sw % 2 and target_w > 1:
        target_w -= 1
    if target_h % 2 != sh % 2 and target_h > 1:
        target_h -= 1

    center_x = max(0, (sw - target_w) // 2)
    center_y = max(0, (sh - target_h) // 2)
    left_x = min(margin_x, max(0, sw - target_w))
    right_x = max(left_x, sw - margin_x - target_w)
    top_y = min(margin_y, max(0, sh - target_h))
    bottom_y = max(top_y, sh - margin_y - target_h)

    gap = min(max(0, int(round(22 * scale))), center_y // 4)
    panel_w = min(max(1, int(round(350 * scale))), sw)
    panel_h = min(max(1, int(round(105 * scale))), max(1, center_y - gap))
    panel_x = max(0, (sw - panel_w) // 2)
    panel_y = max(0, center_y - gap - panel_h)

    return {
        "window": (sw, sh),
        "scale": scale,
        "target_size": (target_w, target_h),
        "panel_size": (panel_w, panel_h),
        "positions": {
            "top-left": (left_x, top_y),
            "top-right": (right_x, top_y),
            "center": (center_x, center_y),
            "bottom-left": (left_x, bottom_y),
            "bottom-right": (right_x, bottom_y),
        },
        "panel_position": (panel_x, panel_y),
        "margins": (margin_x, margin_y),
        "gap": gap,
    }
# TOUCH_LAYOUT_END


class TouchTarget(Gtk.EventBox):

    def __init__(self, owner, target_id):
        super().__init__()
        self.owner = owner
        self.target_id = target_id
        self.done = False
        self.touch_down = False

        self.set_visible_window(True)
        self.add_events(Gdk.EventMask.TOUCH_MASK)

        ctx = self.get_style_context()
        ctx.add_class("touch-target")
        ctx.add_class("target-red")

        self.connect("touch-event", self.on_touch_event)

    def set_state(self, state):
        ctx = self.get_style_context()
        for cls in ("target-red", "target-blue", "target-green"):
            ctx.remove_class(cls)
        ctx.add_class(state)

    def on_touch_event(self, widget, event):
        et = event.type
        if et == Gdk.EventType.TOUCH_BEGIN:
            self.touch_down = True
            self.set_state("target-blue")
            return True
        if et in (Gdk.EventType.TOUCH_END, Gdk.EventType.TOUCH_CANCEL):
            if not self.touch_down:
                return True
            self.touch_down = False
            if et == Gdk.EventType.TOUCH_END:
                self.done = True
                self.set_state("target-green")
                self.owner.update_progress()
            else:
                self.set_state("target-green" if self.done else "target-red")
            return True
        return False


class TouchWindow(Gtk.Window):
    def __init__(self):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.set_name("touch_host")
        self.set_title("Uwuntu Touch-Tester XWayland")
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_app_paintable(True)
        self.set_accept_focus(True)
        self.set_focus_on_map(True)
        self.finished = False
        self.front_attempts = 0
        self.completed = 0
        self.layout_key = None

        # GTK3/X11 specific: explicitly request a visual with an alpha channel.
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)
            self.rgba_ok = True
        else:
            self.rgba_ok = False

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self._provider = provider

        self.fixed = Gtk.Fixed()
        self.fixed.set_hexpand(True)
        self.fixed.set_vexpand(True)
        self.add(self.fixed)

        self.targets = {
            "top-left": TouchTarget(self, "top-left"),
            "top-right": TouchTarget(self, "top-right"),
            "center": TouchTarget(self, "center"),
            "bottom-left": TouchTarget(self, "bottom-left"),
            "bottom-right": TouchTarget(self, "bottom-right"),
        }
        for target in self.targets.values():
            self.fixed.put(target, 0, 0)

        self.panel = self.build_panel()
        self.fixed.put(self.panel, 0, 0)

        self.connect("size-allocate", self.on_size_allocate)
        self.connect("key-press-event", self.on_key_press)
        self.connect("delete-event", self.on_delete)

        self.fullscreen()
        self.show_all()
        self.present()
        self.grab_focus()
        # Unter XWayland mehrfach nach vorne holen. Der Touch-Test soll
        # beim Kiosk-Start garantiert vor allen Diagnosefenstern liegen.
        GLib.timeout_add(180, self.force_front)

        display_name = Gdk.Display.get_default().get_name() if Gdk.Display.get_default() else "?"
        print(f"Touch-Tester Backend: X11/XWayland ({display_name})")
        print(f"RGBA-Visual: {'JA' if self.rgba_ok else 'NEIN'}")
        print(f"Compositor: {'JA' if screen.is_composited() else 'NEIN'}")
        print(f"GTK/GDK-Skalierungsfaktor: {self.get_scale_factor()}")

        if not self.rgba_ok:
            write_state(
                "error",
                completed=0,
                device=device_name or device,
                note="XWayland gestartet, aber kein RGBA-Visual/Compositor verfügbar",
            )
        else:
            write_state(
                "running",
                completed=0,
                device=device_name or device,
                note="XWayland GTK3 RGBA Touch-Tester gestartet",
            )

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

    def build_panel(self):
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        outer.get_style_context().add_class("title-panel")

        title = Gtk.Label(label="TOUCH-TESTER")
        title.get_style_context().add_class("main-title")
        outer.pack_start(title, True, True, 0)

        self.progress_label = Gtk.Label(label="0 / 5")
        self.progress_label.get_style_context().add_class("progress")
        outer.pack_start(self.progress_label, True, True, 0)

        hint = Gtk.Label(label="ESC / STRG+W = Abbruch")
        hint.get_style_context().add_class("hint")
        outer.pack_start(hint, True, True, 0)
        return outer

    def on_size_allocate(self, widget, allocation):
        layout = calculate_touch_layout(allocation.width, allocation.height)
        tw, th = layout["target_size"]
        pw, ph = layout["panel_size"]
        layout_key = (layout["window"], tw, th, pw, ph)

        if layout_key != self.layout_key:
            self.layout_key = layout_key
            for target in self.targets.values():
                target.set_size_request(tw, th)
            self.panel.set_size_request(pw, ph)

            # CSS-Inhaltsminima skalieren mit, damit GTK die dynamischen
            # Größenwünsche nicht wegen fester Fonts/Paddings vergrößert.
            scale = layout["scale"]
            border = max(1, int(round(5 * scale)))
            radius = max(2, int(round(14 * scale)))
            panel_border = max(1, int(round(2 * scale)))
            pad_y = max(1, int(round(13 * scale)))
            pad_x = max(2, int(round(20 * scale)))
            self.panel.set_spacing(max(0, int(round(4 * scale))))
            dynamic_css = CSS + f"""
.touch-target {{ border-width: {border}px; border-radius: {radius}px; }}
.title-panel {{ border-width: {panel_border}px; border-radius: {radius}px;
                padding: {pad_y}px {pad_x}px; }}
.main-title {{ font-size: {max(8, int(round(30 * scale)))}px; }}
.progress {{ font-size: {max(7, int(round(15 * scale)))}px; }}
.hint {{ font-size: {max(6, int(round(11 * scale)))}px; }}
""".encode()
            self._provider.load_from_data(dynamic_css)

        for key, (x, y) in layout["positions"].items():
            self.fixed.move(self.targets[key], x, y)
        self.fixed.move(self.panel, *layout["panel_position"])

    def update_progress(self):
        self.completed = sum(1 for t in self.targets.values() if t.done)
        self.progress_label.set_text(f"{self.completed} / {TOTAL}")
        write_state(
            "running",
            completed=self.completed,
            device=device_name or device,
            note="XWayland Touch-Test läuft",
        )
        if self.completed == TOTAL:
            self.progress_label.get_style_context().add_class("progress-ready")
            self.progress_label.set_text("5 / 5  ✓")
            GLib.timeout_add(500, self.finish_success)

    def finish_success(self):
        if self.finished:
            return False
        self.finished = True
        write_state(
            "success",
            completed=TOTAL,
            device=device_name or device,
            note="Alle fünf Touch-Flächen erfolgreich getestet (XWayland)",
        )
        Gtk.main_quit()
        return False

    def abort(self):
        if self.finished:
            return
        self.finished = True
        write_state(
            "aborted",
            completed=self.completed,
            device=device_name or device,
            note="Touch-Test durch Benutzer abgebrochen (XWayland)",
        )
        Gtk.main_quit()

    def on_key_press(self, widget, event):
        ctrl = bool(event.state & Gdk.ModifierType.CONTROL_MASK)
        if event.keyval == Gdk.KEY_Escape or (ctrl and event.keyval in (Gdk.KEY_w, Gdk.KEY_W)):
            self.abort()
            return True
        if ctrl and event.keyval in (Gdk.KEY_q, Gdk.KEY_Q):
            if not self.finished:
                self.finished = True
                write_state(
                    "aborted",
                    completed=self.completed,
                    device=device_name or device,
                    note="Touch-Test durch STRG+Q beendet (XWayland)",
                )
            helper = Path.home() / ".local/bin/close-diagnostic-apps.sh"
            try:
                subprocess.Popen(
                    [str(helper)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:
                pass
            return True
        return False

    def on_delete(self, *_args):
        self.abort()
        return True


win = TouchWindow()
Gtk.main()
PY
