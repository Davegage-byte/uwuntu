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

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/uwuntu-camera-test"
PY_FILE="$CACHE_DIR/camera_test_v1_20.py"
LOG_FILE="$CACHE_DIR/camera_test.log"
STATE_FILE="$HOME/.local/state/uwuntu/camera_test_status.json"
mkdir -p "$CACHE_DIR" "$(dirname "$STATE_FILE")"
rm -f "$STATE_FILE" 2>/dev/null || true

{
    echo
    echo "============================================================"
    echo "$(date '+%Y-%m-%d %H:%M:%S')  Uwuntu Kamera Test v1.20 Start"
} >> "$LOG_FILE" 2>/dev/null || true

# XWayland gibt dem Kamera-Fenster eine klassische WM_CLASS. Zusammen mit
# der echten Gtk.Application-ID kann GNOME/Tiling Assistant das Fenster so
# eindeutig einer Desktop-App zuordnen und normal verschieben/kacheln.
if [[ -n "${DISPLAY:-}" ]]; then
    export GDK_BACKEND=x11
fi

REQUIRED_PKGS=(
  python3-gi
  gir1.2-gtk-3.0
  gir1.2-gstreamer-1.0
  gstreamer1.0-plugins-base
  gstreamer1.0-plugins-good
  gstreamer1.0-gtk3
)

missing=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done

repair_camera_dpkg() {
    if sudo -n true >/dev/null 2>&1; then
        sudo -n dpkg --configure -a
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec dpkg --configure -a
    else
        sudo dpkg --configure -a
    fi
}

if ((${#missing[@]})); then
    repair_camera_dpkg || exit 1
    if sudo -n true >/dev/null 2>&1; then
        sudo -n apt-get clean || exit 1
        sudo -n apt-get update || exit 1
        sudo -n env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "${missing[@]}" || exit 1
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec apt-get clean || exit 1
        pkexec env DEBIAN_FRONTEND=noninteractive apt-get update || exit 1
        pkexec env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "${missing[@]}" || exit 1
    else
        sudo apt-get clean || exit 1
        sudo apt-get update || exit 1
        sudo env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "${missing[@]}" || exit 1
    fi
fi

# OpenCV/opencv-data werden über Punkt 1 bzw. das U-Update installiert.
# Der Kamera-Start selbst führt bewusst KEINE privilegierte Paketinstallation
# mehr aus. Fehlt die optionale Gesichtserkennung trotzdem, startet die Kamera
# normal weiter und deaktiviert nur den Face-Status.

cat > "$PY_FILE" <<'PY'
import glob
import json
import os
import subprocess
import time
from pathlib import Path
import gi

try:
    import cv2
    import numpy as np
except Exception as exc:
    cv2 = None
    np = None
    print(f"Optionale Gesichtserkennung nicht verfügbar: {exc}", flush=True)

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("Gst", "1.0")
gi.require_version("Gio", "2.0")

from gi.repository import Gtk, Gdk, Gst, GLib, Gio

APP_ID = "com.david.UwuntuCameraTest"
APP_NAME = "Uwuntu Kamera Test"
VERSION = "1.20"
ERROR_TEXT = "KEIN KAMERABILD ERKANNT"
IPU7_LIMITED_TEXT = "IPU7 KAMERA – LINUX NICHT TESTBAR"

STATE_DIR = Path.home() / ".local/state/uwuntu"
STATE_FILE = STATE_DIR / "camera_test_status.json"
HARDWARE_REFRESH_FILE = STATE_DIR / "hardware_refresh.json"


def hardware_refresh_stamp():
    try:
        return HARDWARE_REFRESH_FILE.stat().st_mtime_ns
    except Exception:
        return 0


def write_camera_state(status):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        data = {"status": str(status), "time": time.time(), "pid": os.getpid()}
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(data), encoding="utf-8")
        tmp.replace(STATE_FILE)
    except Exception as exc:
        print(f"Kamera-Statusdatei konnte nicht geschrieben werden: {exc}", flush=True)


Gst.init(None)
GLib.set_application_name(APP_NAME)
try:
    Gdk.set_program_class("UwuntuCameraTest")
except Exception:
    pass


def video_node_name(dev):
    """Lesbaren V4L2-Namen eines /dev/video*-Nodes ermitteln."""
    try:
        name_file = Path("/sys/class/video4linux") / Path(dev).name / "name"
        return name_file.read_text(
            encoding="utf-8",
            errors="ignore",
        ).strip()
    except Exception:
        return ""


def is_ipu7_isys_raw_node(dev):
    """Intel-IPU7-ISYS-Capture-Nodes sind noch keine fertige Webcam.

    Auf z. B. Dell Pro 14 Plus PB14250 werden viele rohe ISYS-Capture-Nodes
    angelegt. Ohne passenden Intel-Camera-HAL/Userspace-Stack liefern diese
    normalen Webcam-Anwendungen kein nutzbares Kamerabild.
    """
    name = video_node_name(dev).lower()
    return "ipu7" in name and "isys capture" in name


def ipu7_raw_nodes_present():
    try:
        return any(
            is_ipu7_isys_raw_node(dev)
            for dev in glob.glob("/dev/video*")
        )
    except Exception:
        return False


def camera_devices():
    """Nur direkt nutzbare Video-Capture-Nodes verwenden.

    IPU7-ISYS-Raw-Nodes werden bewusst übersprungen. Existiert daneben eine
    normale USB/UVC-Webcam, wird diese weiterhin exakt wie bisher getestet.
    """
    all_devices = sorted(glob.glob("/dev/video*"))
    if not all_devices:
        # Bewährtes Fehlverhalten für Systeme ohne Kamera beibehalten:
        # /dev/video0 wird einmal probiert und endet danach sauber in Rot.
        return ["/dev/video0"]

    devices = [
        dev for dev in all_devices
        if not is_ipu7_isys_raw_node(dev)
    ]

    # Reines IPU7-ISYS-System: Nicht 32 Raw-Nodes nacheinander testen.
    if not devices and ipu7_raw_nodes_present():
        return []

    # Falls ein unbekannter Sondertreiber keinen sysfs-Namen liefert,
    # bleibt der bisherige V4L2-Erkennungsweg unverändert aktiv.
    if not devices:
        devices = all_devices

    capture = []
    unknown = []
    for dev in devices:
        try:
            p = subprocess.run(
                ["udevadm", "info", "--query=property", f"--name={dev}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=1.5,
                check=False,
            )
            props = {}
            for line in p.stdout.splitlines():
                if "=" in line:
                    key, value = line.split("=", 1)
                    props[key] = value
            caps = props.get("ID_V4L_CAPABILITIES", "")
            if ":capture:" in caps:
                capture.append(dev)
            elif not caps:
                unknown.append(dev)
        except Exception:
            unknown.append(dev)

    return capture or unknown or devices


MODES = [
    (
        "MJPEG 1920x1080 @ 30 FPS",
        "image/jpeg,width=1920,height=1080,framerate=30/1 ! jpegdec",
    ),
    (
        "MJPEG 1280x720 @ 30 FPS",
        "image/jpeg,width=1280,height=720,framerate=30/1 ! jpegdec",
    ),
    ("AUTO", None),
]


def find_face_cascade():
    """Finde das kleine klassische OpenCV-Haar-Modell ohne Zusatzframework."""
    if cv2 is None:
        return None

    candidates = []
    try:
        candidates.append(
            os.path.join(
                cv2.data.haarcascades,
                "haarcascade_frontalface_default.xml",
            )
        )
    except Exception:
        pass

    candidates.extend(
        [
            "/usr/share/opencv4/haarcascades/haarcascade_frontalface_default.xml",
            "/usr/share/opencv/haarcascades/haarcascade_frontalface_default.xml",
        ]
    )

    for path in candidates:
        if path and os.path.isfile(path):
            return path
    return None


class CameraWindow(Gtk.ApplicationWindow):
    def __init__(self, application):
        super().__init__(application=application)
        self.set_title(f"{APP_NAME} v{VERSION}")
        self.set_decorated(True)

        # Eigene GTK3-HeaderBar für eine wirklich kompakte Titelleiste.
        self.header_bar = Gtk.HeaderBar()
        self.header_bar.set_title(f"{APP_NAME} v{VERSION}")
        self.header_bar.set_show_close_button(True)
        try:
            self.header_bar.set_has_subtitle(False)
        except Exception:
            pass

        # Kleiner Statuspunkt wie bei USB/HDMI:
        # Orange = Kamera aktiv, Gesicht noch nie erkannt
        # Rot    = Kamera nicht nutzbar
        # Blau   = Gesicht aktuell erkannt
        # Grün   = Gesicht bereits erkannt, aktuell nicht sichtbar
        self.status_dot = Gtk.Label(label="●")
        self.status_dot.get_style_context().add_class("camera-status-dot")
        self.header_bar.pack_end(self.status_dot)

        self.set_titlebar(self.header_bar)

        self.set_resizable(True)
        self.set_keep_above(False)
        self.set_skip_taskbar_hint(False)
        self.set_skip_pager_hint(False)
        self.set_default_size(960, 540)
        try:
            self.set_type_hint(Gdk.WindowTypeHint.NORMAL)
        except Exception:
            pass

        self.connect("key-press-event", self.on_key_press)
        self.connect("delete-event", self.on_delete)

        self.pipeline = None
        self.serial = 0
        self.frame_seen = False
        self.devices = camera_devices()
        self.ipu7_linux_limited = (
            not self.devices
            and ipu7_raw_nodes_present()
        )
        self.device_index = 0
        self.mode_index = 0

        # Ressourcenschonende Gesichtserkennung:
        # maximal 1 kleines 320x180-Graubild pro Sekunde.
        # Die sichtbare Kameravorschau bleibt davon unberührt bei bis zu 30 FPS.
        self.face_ever_seen = False
        self.face_currently_visible = False
        self.face_miss_count = 0
        self.face_last_sample_at = 0.0
        self.hardware_refresh_stamp = hardware_refresh_stamp()
        self.face_cascade_path = find_face_cascade()
        self.face_cascade = None

        if self.face_cascade_path and cv2 is not None:
            try:
                cascade = cv2.CascadeClassifier(self.face_cascade_path)
                if cascade is not None and not cascade.empty():
                    self.face_cascade = cascade
                    print(
                        f"Gesichtserkennung aktiv: {self.face_cascade_path}",
                        flush=True,
                    )
            except Exception as exc:
                print(f"Gesichtserkennung konnte nicht geladen werden: {exc}", flush=True)

        if self.face_cascade is None:
            print(
                "Gesichtserkennung nicht verfügbar; Kamera-Test läuft ohne Face-Status.",
                flush=True,
            )

        # Wird pro Kamera/Auflösung zunächst aktiviert, falls das Modell da ist.
        # Scheitert ausschließlich der Face-Zweig, wird dieselbe Konfiguration
        # sofort noch einmal mit dem bewährten einfachen Kamera-Pfad getestet.
        self.face_pipeline_enabled = self.face_cascade is not None

        css = Gtk.CssProvider()
        css.load_from_data(b'''
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
headerbar button.titlebutton {
    min-height: 20px;
    min-width: 20px;
    padding: 0px;
    margin: 0px 1px;
}

.camera-status-dot {
    font-size: 15px;
    font-weight: 900;
    padding: 0px 5px 1px 3px;
}
.camera-status-orange { color: #f5a623; }
.camera-status-red    { color: #ff4c4c; }
.camera-status-blue   { color: #5aa2ff; }
.camera-status-green  { color: #61d36b; }

window { background: #000; }
#camera_error {
    color: #ff4c4c;
    font-size: 12px;
    font-weight: 800;
}
#camera_error.camera-warning {
    color: #f5a623;
}
''')
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        self.overlay = Gtk.Overlay()
        self.add(self.overlay)

        self.video_box = Gtk.Box()
        self.video_box.set_hexpand(True)
        self.video_box.set_vexpand(True)
        self.overlay.add(self.video_box)

        self.error_label = Gtk.Label(label=ERROR_TEXT)
        self.error_label.set_name("camera_error")
        self.error_label.set_halign(Gtk.Align.CENTER)
        self.error_label.set_valign(Gtk.Align.CENTER)
        self.overlay.add_overlay(self.error_label)

        # Transparente Klickfläche über dem Videobereich. So ist der Klick zum
        # Kamerawechsel unabhängig vom konkreten gtksink-Widget zuverlässig.
        # Die normale Titelleiste liegt außerhalb und bleibt zum Ziehen frei.
        self.click_layer = Gtk.EventBox()
        self.click_layer.set_visible_window(False)
        self.click_layer.set_hexpand(True)
        self.click_layer.set_vexpand(True)
        self.click_layer.add_events(Gdk.EventMask.BUTTON_RELEASE_MASK)
        self.click_layer.connect("button-release-event", self.on_camera_click)
        self.overlay.add_overlay(self.click_layer)

        self.show_all()
        self.error_label.hide()
        self.set_status_color("orange")
        GLib.idle_add(self.try_current)
        GLib.timeout_add(250, self.poll_hardware_refresh)

    def poll_hardware_refresh(self):
        stamp = hardware_refresh_stamp()
        if not stamp or stamp == self.hardware_refresh_stamp:
            return True

        self.hardware_refresh_stamp = stamp

        if self.devices:
            self.reset_face_state()
            print("HC REFRESH: Kamera-Teststatus zurückgesetzt", flush=True)
        elif self.ipu7_linux_limited:
            self.error_label.set_text(IPU7_LIMITED_TEXT)
            self.error_label.get_style_context().add_class("camera-warning")
            self.error_label.show()
            self.set_status_color("orange")
        else:
            self.set_status_color("red")

        return True

    def set_status_color(self, color):
        if not hasattr(self, "status_dot"):
            return False

        ctx = self.status_dot.get_style_context()
        for cls in (
            "camera-status-orange",
            "camera-status-red",
            "camera-status-blue",
            "camera-status-green",
        ):
            ctx.remove_class(cls)

        ctx.add_class(f"camera-status-{color}")

        state = {
            "red": "missing",
            "orange": (
                "linux_unsupported"
                if getattr(self, "ipu7_linux_limited", False)
                else "detected"
            ),
            "blue": "face",
            "green": "tested",
        }.get(color)
        if state:
            write_camera_state(state)

        return False

    def update_face_status(self, face_visible):
        if face_visible:
            self.face_ever_seen = True
            self.face_currently_visible = True
            self.face_miss_count = 0
            self.set_status_color("blue")
            return False

        if not self.face_ever_seen:
            self.face_currently_visible = False
            self.set_status_color("orange")
            return False

        # Haar-Erkennung kann einzelne Frames kurz verpassen.
        # Erst nach zwei aufeinanderfolgenden Fehl-Treffern (~2 s bei 1 FPS)
        # von Blau auf Grün wechseln.
        self.face_miss_count += 1
        if self.face_miss_count >= 2:
            self.face_currently_visible = False
            self.set_status_color("green")

        return False

    def reset_face_state(self):
        self.face_ever_seen = False
        self.face_currently_visible = False
        self.face_miss_count = 0
        self.face_last_sample_at = 0.0
        self.set_status_color("orange")

    def stop_pipeline(self):
        if self.pipeline:
            try:
                self.pipeline.get_bus().remove_signal_watch()
            except Exception:
                pass
            try:
                self.pipeline.set_state(Gst.State.NULL)
            except Exception:
                pass
            self.pipeline = None

    def clear_video(self):
        for child in self.video_box.get_children():
            self.video_box.remove(child)

    def build_pipeline(self, device, caps):
        if caps is None:
            source = f'v4l2src device="{device}" ! '
        else:
            source = (
                f'v4l2src device="{device}" ! '
                f'{caps} ! '
            )

        # Bewährter einfacher Kamera-Pfad.
        if not self.face_pipeline_enabled:
            return (
                source
                + 'videoconvert ! '
                  'identity name=probe signal-handoffs=true ! '
                  'gtksink name=sink sync=false'
            )

        # Wichtig: Beide tee-Zweige bekommen ihren EIGENEN videoconvert.
        # So muss der gemeinsame Upstream nicht gleichzeitig ein Format für
        # gtksink und GRAY8/Face-Erkennung aushandeln.
        return (
            source
            + 'tee name=t '
              't. ! queue ! '
              'videoconvert ! '
              'identity name=probe signal-handoffs=true ! '
              'gtksink name=sink sync=false '
              't. ! queue leaky=downstream max-size-buffers=1 ! '
              'videoconvert ! videoscale ! videorate ! '
              'video/x-raw,format=GRAY8,width=320,height=180,framerate=1/1 ! '
              'appsink name=facesink emit-signals=true drop=true '
              'max-buffers=1 sync=false'
        )

    def current_device(self):
        if not self.devices:
            return "/dev/video0"
        self.device_index %= len(self.devices)
        return self.devices[self.device_index]

    def try_current(self):
        self.serial += 1
        current_serial = self.serial
        self.stop_pipeline()
        self.clear_video()
        self.frame_seen = False
        self.error_label.hide()

        if not self.devices:
            if self.ipu7_linux_limited:
                self.error_label.set_text(IPU7_LIMITED_TEXT)
                self.error_label.get_style_context().add_class(
                    "camera-warning"
                )
                self.set_status_color("orange")
                self.error_label.show()
                print(
                    "Intel IPU7 ISYS erkannt: "
                    "Raw-Capture-Nodes werden nicht als Webcam getestet.",
                    flush=True,
                )
            else:
                self.error_label.set_text(ERROR_TEXT)
                self.error_label.get_style_context().remove_class(
                    "camera-warning"
                )
                self.set_status_color("red")
                self.error_label.show()
            return False

        if self.mode_index >= len(MODES):
            self.device_index += 1
            self.mode_index = 0
            self.face_pipeline_enabled = self.face_cascade is not None
            if self.device_index >= len(self.devices):
                self.device_index = 0
                self.set_status_color("red")
                self.error_label.show()
                print("Keine funktionierende Kamera-Konfiguration gefunden.", flush=True)
                return False

        device = self.current_device()
        label, caps = MODES[self.mode_index]
        print(
            f"Kamera v{VERSION} · teste {device}: {label} · "
            f"Backend={os.environ.get('GDK_BACKEND', 'auto')}",
            flush=True,
        )

        try:
            self.pipeline = Gst.parse_launch(self.build_pipeline(device, caps))
            sink = self.pipeline.get_by_name("sink")
            probe = self.pipeline.get_by_name("probe")
            facesink = self.pipeline.get_by_name("facesink")
            if sink is None or probe is None:
                raise RuntimeError("GStreamer-Element fehlt")
            if self.face_pipeline_enabled and facesink is None:
                raise RuntimeError("Face-Appsink fehlt")

            widget = sink.get_property("widget")
            widget.set_hexpand(True)
            widget.set_vexpand(True)
            self.video_box.pack_start(widget, True, True, 0)
            widget.show()

            probe.connect("handoff", self.on_frame, current_serial)

            # Face-Erkennung läuft nur, wenn Cascade erfolgreich geladen wurde.
            # Der kleine Appsink-Zweig bleibt ansonsten praktisch kostenlos.
            if self.face_pipeline_enabled and facesink is not None:
                facesink.connect("new-sample", self.on_face_sample, current_serial)

            bus = self.pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message::error", self.on_error, current_serial)
            bus.connect("message::eos", self.on_eos, current_serial)

            result = self.pipeline.set_state(Gst.State.PLAYING)
            if result == Gst.StateChangeReturn.FAILURE:
                GLib.idle_add(self.fail_current, current_serial)
            else:
                GLib.timeout_add(2200, self.check_timeout, current_serial)
        except Exception as exc:
            print(f"Kamera-Fehler: {exc}", flush=True)
            GLib.idle_add(self.fail_current, current_serial)

        return False

    def on_frame(self, element, buffer, current_serial):
        if current_serial != self.serial:
            return
        if not self.frame_seen:
            self.frame_seen = True
            device = self.current_device()
            label, _ = MODES[self.mode_index]
            print(f"Kamera aktiv: {device} | {label}", flush=True)
            GLib.idle_add(self.error_label.hide)
            if not self.face_ever_seen:
                GLib.idle_add(self.set_status_color, "orange")

    def on_face_sample(self, sink, current_serial):
        if current_serial != self.serial or self.face_cascade is None:
            return Gst.FlowReturn.OK

        # Zusätzliche Zeitbremse als Schutz, obwohl der GStreamer-Zweig bereits
        # auf 1 FPS begrenzt ist.
        now = time.monotonic()
        if now - self.face_last_sample_at < 0.80:
            try:
                sink.emit("pull-sample")
            except Exception:
                pass
            return Gst.FlowReturn.OK
        self.face_last_sample_at = now

        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK

        buffer = sample.get_buffer()
        caps = sample.get_caps()
        if buffer is None or caps is None:
            return Gst.FlowReturn.OK

        try:
            structure = caps.get_structure(0)
            width = int(structure.get_value("width"))
            height = int(structure.get_value("height"))
        except Exception:
            return Gst.FlowReturn.OK

        ok, mapinfo = buffer.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.OK

        face_visible = False
        try:
            frame = np.frombuffer(mapinfo.data, dtype=np.uint8)
            expected = width * height
            if frame.size >= expected:
                gray = frame[:expected].reshape((height, width))

                faces = self.face_cascade.detectMultiScale(
                    gray,
                    scaleFactor=1.15,
                    minNeighbors=4,
                    minSize=(34, 34),
                    flags=cv2.CASCADE_SCALE_IMAGE,
                )
                face_visible = len(faces) > 0
        except Exception as exc:
            print(f"Gesichtserkennung Frame-Fehler: {exc}", flush=True)
        finally:
            buffer.unmap(mapinfo)

        GLib.idle_add(self.update_face_status, face_visible)
        return Gst.FlowReturn.OK

    def check_timeout(self, current_serial):
        if current_serial == self.serial and not self.frame_seen:
            self.fail_current(current_serial)
        return False

    def fail_current(self, current_serial):
        if current_serial != self.serial or self.frame_seen:
            return False

        # Falls gerade der Face-Zweig aktiv war, dieselbe Kamera/Auflösung
        # zuerst ohne Face-Zweig testen. Damit kann eine optionale Funktion
        # niemals den normalen Kamera-Test komplett blockieren.
        if self.face_pipeline_enabled and self.face_cascade is not None:
            print(
                "Face-Pipeline lieferte kein Bild · "
                "teste dieselbe Kamera/Auflösung ohne Face-Zweig.",
                flush=True,
            )
            self.face_pipeline_enabled = False
            GLib.idle_add(self.try_current)
            return False

        # Auch der einfache Pfad hat kein Bild geliefert: nächste Auflösung.
        # Dort Face-Erkennung erneut versuchen.
        self.mode_index += 1
        self.face_pipeline_enabled = self.face_cascade is not None
        GLib.idle_add(self.try_current)
        return False

    def on_error(self, bus, message, current_serial):
        if current_serial == self.serial and not self.frame_seen:
            try:
                err, _ = message.parse_error()
                print("GStreamer:", err.message, flush=True)
            except Exception:
                pass
            GLib.idle_add(self.fail_current, current_serial)

    def on_eos(self, bus, message, current_serial):
        if current_serial == self.serial and not self.frame_seen:
            GLib.idle_add(self.fail_current, current_serial)

    def on_camera_click(self, widget, event):
        if getattr(event, "button", 0) != 1:
            return False

        refreshed = camera_devices()
        active = self.current_device() if self.devices else None
        self.devices = refreshed
        self.ipu7_linux_limited = (
            not self.devices
            and ipu7_raw_nodes_present()
        )

        if self.ipu7_linux_limited:
            self.error_label.set_text(IPU7_LIMITED_TEXT)
            self.error_label.get_style_context().add_class("camera-warning")
            self.set_status_color("orange")
            self.error_label.show()
            print(
                "IPU7 Kamera erkannt – unter Linux aktuell nicht testbar.",
                flush=True,
            )
            return True

        if len(self.devices) <= 1:
            print("Keine weitere Kamera vorhanden.", flush=True)
            return True

        try:
            pos = self.devices.index(active)
        except (ValueError, TypeError):
            pos = -1

        self.device_index = (pos + 1) % len(self.devices)
        self.mode_index = 0
        self.face_pipeline_enabled = self.face_cascade is not None
        self.reset_face_state()
        self.error_label.hide()
        print(
            f"Klick: wechsle zur nächsten Kamera {self.current_device()}",
            flush=True,
        )
        GLib.idle_add(self.try_current)
        return True

    def on_key_press(self, widget, event):
        ctrl = bool(event.state & Gdk.ModifierType.CONTROL_MASK)
        # ESC bleibt bewusst ohne Schließfunktion. STRG+W / STRG+Q sind
        # Diagnose-Hotkeys; Titelleisten-X und Alt+F4 dürfen normal schließen.
        if ctrl and event.keyval in (Gdk.KEY_w, Gdk.KEY_W):
            self.get_application().quit()
            return True
        if ctrl and event.keyval in (Gdk.KEY_q, Gdk.KEY_Q):
            helper = os.path.expanduser("~/.local/bin/close-diagnostic-apps.sh")
            try:
                subprocess.Popen(
                    [helper],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception:
                pass
            return True
        return False

    def on_delete(self, *_args):
        # Normales Fensterschließen erlauben: Titelleisten-X und Alt+F4.
        # ESC wird weiterhin nicht als Schließbefehl behandelt.
        return False

    def cleanup(self):
        self.serial += 1
        self.stop_pipeline()


class CameraApplication(Gtk.Application):
    def __init__(self):
        super().__init__(
            application_id=APP_ID,
            flags=Gio.ApplicationFlags.FLAGS_NONE,
        )
        self.window = None

    def do_activate(self):
        if self.window is None:
            self.window = CameraWindow(self)
        self.window.present()

    def do_shutdown(self):
        if self.window is not None:
            self.window.cleanup()
            self.window = None
        Gtk.Application.do_shutdown(self)


app = CameraApplication()
raise SystemExit(app.run(None))
PY

chmod +x "$PY_FILE"
exec -a uwuntu-camera-test-python python3 "$PY_FILE" >>"$LOG_FILE" 2>&1
