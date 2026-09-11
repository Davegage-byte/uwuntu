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

APP_NAME="Uwuntu Audio Test"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/uwuntu-audio-test"
PY_FILE="$CACHE_DIR/audio_test_v1_23.py"
STATE_FILE="$HOME/.local/state/uwuntu/audio_test_status.json"

mkdir -p "$CACHE_DIR" "$(dirname "$STATE_FILE")"
rm -f "$STATE_FILE" 2>/dev/null || true

need_install=0

python3 - <<'PY' >/dev/null 2>&1 || need_install=1
import numpy
import sounddevice
from PIL import Image, ImageDraw
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib
PY

if [ "$need_install" -eq 1 ]; then
    echo
    echo "Benötigte Komponenten fehlen."
    echo "Uwuntu installiert sie jetzt automatisch ..."
    echo

    if ! command -v sudo >/dev/null 2>&1; then
        echo "FEHLER: sudo ist nicht verfügbar."
        exit 1
    fi

    sudo apt-get update || exit 1
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 \
        python3-numpy \
        python3-sounddevice \
        python3-pil \
        python3-gi \
        gir1.2-gtk-4.0 \
        gir1.2-gdkpixbuf-2.0 \
        libportaudio2 || exit 1
fi

if ! command -v paplay >/dev/null 2>&1 && ! command -v aplay >/dev/null 2>&1; then
    echo
    echo "Audio-Player fehlt."
    echo "Uwuntu installiert ihn jetzt automatisch ..."
    echo
    sudo apt-get update || exit 1
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        pulseaudio-utils \
        alsa-utils || exit 1
fi

cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import json
import math
import os
import time
import wave
import struct
import shutil
import queue
import tempfile
import threading
import subprocess
from collections import deque
from pathlib import Path

import numpy as np
import sounddevice as sd
from PIL import Image, ImageDraw

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, GLib, Gdk, GdkPixbuf, Gio


VERSION = "v1.23"

STATE_DIR = Path.home() / ".local/state/uwuntu"
STATE_FILE = STATE_DIR / "audio_test_status.json"
HARDWARE_REFRESH_FILE = STATE_DIR / "hardware_refresh.json"


def hardware_refresh_stamp():
    try:
        return HARDWARE_REFRESH_FILE.stat().st_mtime_ns
    except Exception:
        return 0


def write_mic_state(status):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        data = {"status": str(status), "time": time.time(), "pid": os.getpid()}
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(data), encoding="utf-8")
        tmp.replace(STATE_FILE)
    except Exception:
        pass


SAMPLE_RATE = 48000
INPUT_BLOCK = 512
DISPLAY_SAMPLES = 2048
UI_REFRESH_MS = 16

NO_SIGNAL_DBFS = -55.0
GOOD_SIGNAL_DBFS = -32.0

HIGHPASS_HZ = 80.0

MIN_VISUAL_GATE = 0.0010
MAX_VISUAL_GATE = 0.0300
NOISE_GATE_MULTIPLIER = 2.4

# Original-Uwuntu-Dreiklang aus Hardware Check:
# C5 -> E5 -> G5
TONE_NOTES = [
    (523.25, 0.18),
    (659.25, 0.18),
    (783.99, 0.28),
]
TONE_GAP = 0.035
TONE_AMP = 0.22

CANVAS_W = 1200
CANVAS_H = 430

COL_BG = (18, 22, 27, 255)
COL_GRID = (58, 66, 76, 255)
COL_CENTER = (145, 153, 165, 255)
COL_BORDER = (78, 87, 98, 255)

COL_RED = (255, 76, 76, 255)
COL_ORANGE = (245, 166, 35, 255)
COL_BLUE = (90, 162, 255, 255)
COL_GREEN = (97, 211, 107, 255)


INVALID_CAPTURE_MARKERS = (
    ".monitor",
    "monitor",
    "loopback",
    "stereo mix",
    "stereo-mix",
    "stereomix",
    "auto_null",
    "auto-null",
    "alsa_output",
    "dummy",
    "null",
    "null sink",
    "null-sink",
    "schein-ausgabe",
    "scheinausgabe",
)

GENERIC_CAPTURE_NAMES = {
    "default",
    "default source",
    "pipewire",
    "pulse",
    "pulseaudio",
}


def is_valid_capture_name(name):
    """Nur Namen akzeptieren, die nicht auf Output/Loopback hindeuten."""
    normalized = " ".join(str(name or "").strip().lower().split())
    if not normalized or normalized in GENERIC_CAPTURE_NAMES:
        return False
    return not any(marker in normalized for marker in INVALID_CAPTURE_MARKERS)


def choose_pulse_capture_source(default_source, source_names):
    """Echten Pulse-/PipeWire-Eingang wählen; gültigen Default bevorzugen."""
    sources = []
    for name in source_names:
        name = str(name or "").strip()
        if name and name not in sources:
            sources.append(name)

    default_source = str(default_source or "").strip()
    if (
        is_valid_capture_name(default_source)
        and default_source in sources
    ):
        return default_source

    candidates = [name for name in sources if is_valid_capture_name(name)]
    if not candidates:
        return None

    def capture_rank(name):
        lowered = name.lower()
        markers = (
            "alsa_input",
            "mic__source",
            "microphone",
            "capture",
            "headset",
            "usb",
            "mic",
        )
        return next(
            (index for index, marker in enumerate(markers) if marker in lowered),
            len(markers),
        )

    return min(candidates, key=capture_rank)


def query_pulse_sources():
    """Default und Sources einmalig per pactl abfragen."""
    try:
        default_result = subprocess.run(
            ["pactl", "get-default-source"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
        sources_result = subprocess.run(
            ["pactl", "list", "short", "sources"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        return None, [], f"pactl nicht verfügbar: {exc}"

    default_source = (
        default_result.stdout.strip() if default_result.returncode == 0 else ""
    )
    sources = []
    if sources_result.returncode == 0:
        for line in sources_result.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) < 2:
                fields = line.split()
            if len(fields) >= 2:
                sources.append(fields[1].strip())

    if not default_source and not sources:
        return None, [], "pactl lieferte keine verwertbaren Sources"
    return default_source or None, sources, None


def sounddevice_input_devices():
    devices = []
    for index, device in enumerate(sd.query_devices()):
        if int(device.get("max_input_channels", 0)) > 0:
            devices.append((index, str(device.get("name", ""))))
    return devices


def resolve_pulse_source(source_name, devices):
    """Eine validierte Pulse-Source einem expliziten PortAudio-Gerät zuordnen."""
    wanted = source_name.casefold()
    exact = [index for index, name in devices if name.casefold() == wanted]
    if len(exact) == 1:
        return exact[0]

    partial = [
        index
        for index, name in devices
        if wanted in name.casefold() or name.casefold() in wanted
    ]
    return partial[0] if len(partial) == 1 else None


def sounddevice_default_input(devices):
    """Den konfigurierten generischen PortAudio-Default-Input ermitteln."""
    try:
        default_index = int(sd.default.device[0])
    except (TypeError, ValueError, IndexError):
        return None

    device_names = dict(devices)
    name = device_names.get(default_index)
    if name is None:
        return None

    normalized = " ".join(name.strip().lower().split())
    if any(marker in normalized for marker in INVALID_CAPTURE_MARKERS):
        return None

    generic_names = GENERIC_CAPTURE_NAMES | {
        "alsa default",
        "alsa-default",
        "sysdefault",
    }
    if normalized in generic_names or normalized.startswith("default:"):
        return default_index
    return None


def choose_sounddevice_fallback(devices):
    """Ohne pactl nur eindeutig als Capture erkennbaren Input verwenden."""
    capture_markers = (
        "alsa_input",
        "mic__source",
        "microphone",
        "capture",
        "headset",
        "usb",
        " mic",
        "mic ",
    )
    for index, name in devices:
        lowered = name.lower()
        if (
            is_valid_capture_name(name)
            and any(marker in lowered for marker in capture_markers)
        ):
            return index, name
    return None, None


def select_capture_device():
    default_source, sources, pulse_error = query_pulse_sources()
    try:
        devices = sounddevice_input_devices()
    except Exception as exc:
        reason = f"sounddevice-Geräteliste nicht verfügbar: {exc}"
        return default_source, None, None, None, reason

    if default_source is not None or sources:
        source_name = choose_pulse_capture_source(default_source, sources)
        if source_name is None:
            reason = "keine gültige Capture-Source in pactl gefunden"
            return default_source, None, None, None, reason

        if source_name == default_source:
            default_device = sounddevice_default_input(devices)
            if default_device is not None:
                return (
                    default_source,
                    source_name,
                    default_device,
                    "validated-default",
                    None,
                )

        device = resolve_pulse_source(source_name, devices)
        if device is None:
            reason = (
                f"Capture-Source {source_name!r} keinem sounddevice-Gerät "
                "eindeutig zuordenbar"
            )
            return default_source, source_name, None, None, reason
        return default_source, source_name, device, "explicit-fallback", None

    device, name = choose_sounddevice_fallback(devices)
    if device is not None:
        return default_source, name, device, "explicit-fallback", pulse_error

    reason = pulse_error or "keine eindeutig echte Aufnahmequelle gefunden"
    return default_source, None, None, None, reason


def calc_rms(samples):
    return float(np.sqrt(np.mean(np.square(samples)) + 1e-15))


def dbfs_from_samples(samples):
    value = calc_rms(samples)
    if value <= 1e-12:
        return -120.0
    return max(-120.0, 20.0 * math.log10(value))


def make_tone(channel):
    """Originaler 3-Ton-Testklang aus dem Hardware Check.

    C5 - E5 - G5, gleiche Dauer, gleiche Lautstärke,
    gleiche leise zweite Harmonische und gleiche Kanaltrennung.
    """
    sr = SAMPLE_RATE
    amp = TONE_AMP
    notes = TONE_NOTES
    gap = TONE_GAP

    path = Path(tempfile.gettempdir()) / f"uwuntu-audio-test-{channel}.wav"

    frames = bytearray()

    def add_sample(left, right):
        frames.extend(struct.pack("<hh", left, right))

    for note_index, (freq, duration) in enumerate(notes):
        count = int(sr * duration)

        for i in range(count):
            fade_len = max(1, int(sr * 0.025))
            fade_in = min(1.0, i / fade_len)
            fade_out = min(1.0, (count - 1 - i) / fade_len)
            envelope = max(0.0, min(fade_in, fade_out))

            t = i / sr
            sample = (
                math.sin(2 * math.pi * freq * t)
                + 0.16 * math.sin(2 * math.pi * freq * 2 * t)
            ) / 1.16

            value = int(32767 * amp * envelope * sample)

            if channel == "left":
                left, right = value, 0
            elif channel == "right":
                left, right = 0, value
            else:
                left, right = value, value

            add_sample(left, right)

        if note_index != len(notes) - 1:
            for _ in range(int(sr * gap)):
                add_sample(0, 0)

    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(frames))

    return path


class AudioAnalyzer:
    def __init__(self):
        self.q = queue.Queue(maxsize=16)
        self.running = False
        self.stream = None
        self.error = None

        self.dbfs = -120.0
        self.peak_freq = 0.0
        self.status = "KEIN SIGNAL"
        self.color_name = "red"

        self.waveform = np.zeros(DISPLAY_SAMPLES, dtype=np.float32)
        self._display_roll = np.zeros(DISPLAY_SAMPLES, dtype=np.float32)

        # Nur die VISUELLE Darstellung beruhigen. Die Audioanalyse selbst
        # arbeitet weiterhin mit den unveränderten Roh-/Filterdaten.
        # UI_REFRESH_MS bleibt bei 16 ms (~60 FPS).
        self._visual_scale = 1.0

        # Mehrere Sekunden gefilterte Rohdaten für den automatischen
        # Lautsprechervergleich behalten.
        self._history = deque()
        self._history_lock = threading.Lock()
        self._history_seconds = 5.0

        self._level_history = deque(maxlen=8)

        self._hp_prev_x = 0.0
        self._hp_prev_y = 0.0
        dt = 1.0 / SAMPLE_RATE
        rc = 1.0 / (2.0 * math.pi * HIGHPASS_HZ)
        self._hp_alpha = rc / (rc + dt)

        self._noise_rms = 0.002
        self._noise_initialized = False

    def callback(self, indata, frames, time_info, status):
        try:
            samples = np.asarray(indata[:, 0], dtype=np.float32).copy()
        except Exception:
            return

        try:
            self.q.put_nowait(samples)
        except queue.Full:
            try:
                self.q.get_nowait()
            except queue.Empty:
                pass
            try:
                self.q.put_nowait(samples)
            except queue.Full:
                pass

    def start(self):
        default_source, capture_source, capture_device, capture_path, reason = (
            select_capture_device()
        )
        default_label = default_source or "nicht ermittelt"

        if capture_device is None:
            self.error = reason or "keine gültige Capture-Quelle gefunden"
            print(
                "Audio-Eingang: "
                f"Default Source={default_label!r}; {self.error}",
                file=sys.stderr,
            )
            self.running = False
            return False

        print(
            "Audio-Eingang: "
            f"Default Source={default_label!r}; "
            f"Capture-Quelle={capture_source!r}; "
            f"Pfad={capture_path}; "
            f"sounddevice={capture_device}",
            file=sys.stderr,
        )

        try:
            self.stream = sd.InputStream(
                device=capture_device,
                samplerate=SAMPLE_RATE,
                blocksize=INPUT_BLOCK,
                channels=1,
                dtype="float32",
                callback=self.callback,
            )
            self.stream.start()
            self.running = True
            threading.Thread(target=self.worker, daemon=True).start()
            return True
        except Exception as exc:
            self.error = str(exc)
            self.running = False
            if self.stream is not None:
                try:
                    self.stream.close()
                except Exception:
                    pass
                self.stream = None
            return False

    def stop(self):
        self.running = False

        if self.stream is not None:
            try:
                self.stream.stop()
            except Exception:
                pass

            try:
                self.stream.close()
            except Exception:
                pass

            self.stream = None

    def highpass(self, x):
        out = np.empty_like(x)

        prev_x = self._hp_prev_x
        prev_y = self._hp_prev_y
        a = self._hp_alpha

        for i, current_x in enumerate(x):
            current_y = a * (prev_y + float(current_x) - prev_x)
            out[i] = current_y
            prev_x = float(current_x)
            prev_y = current_y

        self._hp_prev_x = prev_x
        self._hp_prev_y = prev_y

        return out

    def update_noise_floor(self, block_rms):
        if not self._noise_initialized:
            self._noise_rms = max(block_rms, MIN_VISUAL_GATE / 2.0)
            self._noise_initialized = True
            return

        if block_rms < self._noise_rms:
            alpha = 0.90
        elif block_rms < self._noise_rms * 1.8:
            alpha = 0.995
        else:
            alpha = 0.9997

        self._noise_rms = (
            alpha * self._noise_rms
            + (1.0 - alpha) * block_rms
        )

    def visual_gate(self, samples):
        current_rms = calc_rms(samples)
        self.update_noise_floor(current_rms)

        threshold = self._noise_rms * NOISE_GATE_MULTIPLIER
        threshold = max(
            MIN_VISUAL_GATE,
            min(MAX_VISUAL_GATE, threshold)
        )

        magnitude = np.abs(samples)
        cleaned_mag = np.maximum(magnitude - threshold, 0.0)

        return (np.sign(samples) * cleaned_mag).astype(np.float32)

    def normalize_for_display(self, samples):
        """Waveform ruhig, aber weiterhin flüssig darstellen.

        Die bisherige sofortige Auto-Skalierung ließ die komplette Kurve bei
        kleinen Pegeländerungen sichtbar "pumpen"/flackern. Jetzt wird nur der
        Darstellungsfaktor weich nachgeführt und die gezeichnete Linie ganz
        leicht räumlich geglättet. Messung, Pegelerkennung und Speaker-Test
        bleiben unverändert.
        """
        peak_abs = float(np.max(np.abs(samples))) if len(samples) else 0.0

        if peak_abs < 1e-7:
            return np.zeros_like(samples)

        if peak_abs < 0.01:
            target_scale = min(10.0, 0.20 / max(peak_abs, 1e-9))
        elif peak_abs < 0.08:
            target_scale = min(5.0, 0.55 / max(peak_abs, 1e-9))
        else:
            target_scale = min(2.0, 0.90 / max(peak_abs, 1e-9))

        # Bei plötzlich lautem Signal zügig herunterregeln, damit nichts
        # anschlägt. Beim Wieder-Hochregeln etwas weicher nachführen; dadurch
        # bleibt die Waveform lebendig, ohne hektisch zu pulsieren.
        alpha = 0.34 if target_scale < self._visual_scale else 0.16
        self._visual_scale += alpha * (target_scale - self._visual_scale)

        displayed = np.clip(
            samples * self._visual_scale,
            -1.0,
            1.0
        ).astype(np.float32)

        # Sehr leichte 3-Punkt-Glättung nur für die gezeichnete Linie.
        # Keine niedrigere Framerate und keine Änderung der Audioauswertung.
        if len(displayed) >= 3:
            displayed = np.convolve(
                displayed,
                np.array([0.18, 0.64, 0.18], dtype=np.float32),
                mode="same",
            ).astype(np.float32)

        return displayed

    def add_history(self, timestamp, filtered):
        with self._history_lock:
            self._history.append(
                (timestamp, filtered.astype(np.float32).copy())
            )

            cutoff = timestamp - self._history_seconds
            while self._history and self._history[0][0] < cutoff:
                self._history.popleft()

    def samples_between(self, start_time, end_time):
        blocks = []

        with self._history_lock:
            for ts, data in self._history:
                block_duration = len(data) / SAMPLE_RATE
                block_start = ts - block_duration

                if ts < start_time:
                    continue

                if block_start > end_time:
                    break

                blocks.append(data.copy())

        if not blocks:
            return np.zeros(0, dtype=np.float32)

        return np.concatenate(blocks)

    @staticmethod
    def frequency_level_db(samples, frequency):
        if samples is None or len(samples) < 256:
            return -120.0

        x = samples.astype(np.float64)
        x -= float(np.mean(x))

        window = np.hanning(len(x))
        n = np.arange(len(x), dtype=np.float64)

        coefficient = np.sum(
            (x * window)
            * np.exp(-2j * np.pi * frequency * n / SAMPLE_RATE)
        )

        gain = np.sum(window) / 2.0
        amplitude = abs(coefficient) / max(gain, 1e-12)

        if amplitude <= 1e-12:
            return -120.0

        return 20.0 * math.log10(amplitude)

    def signature_levels(self, samples):
        return {
            freq: self.frequency_level_db(samples, freq)
            for freq, _duration in TONE_NOTES
        }

    def worker(self):
        while self.running:
            try:
                samples = self.q.get(timeout=0.25)
            except queue.Empty:
                continue

            if len(samples) < 16:
                continue

            centered = samples - float(np.mean(samples))
            filtered = self.highpass(centered)

            now = time.monotonic()
            self.add_history(now, filtered)

            signal_db = dbfs_from_samples(filtered)
            self._level_history.append(signal_db)

            stable_db = float(np.median(self._level_history))

            cleaned = self.visual_gate(filtered)

            n = len(cleaned)

            if n >= DISPLAY_SAMPLES:
                self._display_roll[:] = cleaned[-DISPLAY_SAMPLES:]
            else:
                self._display_roll[:-n] = self._display_roll[n:]
                self._display_roll[-n:] = cleaned

            self.waveform = self.normalize_for_display(
                self._display_roll.copy()
            )

            fft_n = len(filtered)
            window = np.hanning(fft_n)
            spectrum = np.abs(np.fft.rfft(filtered * window))
            freqs = np.fft.rfftfreq(fft_n, 1.0 / SAMPLE_RATE)

            valid = (freqs >= 80.0) & (freqs <= 12000.0)

            if np.any(valid):
                vf = freqs[valid]
                va = spectrum[valid]

                if len(va) and float(np.max(va)) > 1e-12:
                    self.peak_freq = float(vf[int(np.argmax(va))])
                else:
                    self.peak_freq = 0.0

            if stable_db < NO_SIGNAL_DBFS:
                self.status = "KEIN SIGNAL"
                self.color_name = "red"

            elif stable_db < GOOD_SIGNAL_DBFS:
                self.status = "SCHWACHES SIGNAL"
                self.color_name = "orange"

            else:
                self.status = "SIGNAL ERKANNT"
                self.color_name = "green"

            self.dbfs = stable_db


class WaveRenderer:
    def render(self, waveform, color_name):
        img = Image.new("RGBA", (CANVAS_W, CANVAS_H), COL_BG)
        draw = ImageDraw.Draw(img)

        left = 30
        right = 30
        top = 22
        bottom = 22

        x0 = left
        y0 = top
        x1 = CANVAS_W - right
        y1 = CANVAS_H - bottom

        width = x1 - x0
        height = y1 - y0
        center_y = y0 + height // 2

        for i in range(1, 10):
            x = int(x0 + width * i / 10)
            draw.line((x, y0, x, y1), fill=COL_GRID, width=1)

        for frac in (0.25, 0.75):
            y = int(y0 + height * frac)
            draw.line((x0, y, x1, y), fill=COL_GRID, width=1)

        draw.line(
            (x0, center_y, x1, center_y),
            fill=COL_CENTER,
            width=2
        )

        if color_name == "green":
            color = COL_GREEN
        elif color_name == "blue":
            color = COL_BLUE
        elif color_name == "orange":
            color = COL_ORANGE
        else:
            color = COL_RED

        if waveform is None or len(waveform) < 2:
            waveform = np.zeros(2, dtype=np.float32)

        point_count = min(width, len(waveform))
        indices = np.linspace(
            0,
            len(waveform) - 1,
            point_count
        ).astype(int)

        values = waveform[indices]
        amp_px = height * 0.45

        points = []

        for i, value in enumerate(values):
            x = int(x0 + width * i / (point_count - 1))
            y = int(center_y - float(value) * amp_px)
            y = max(y0 + 2, min(y1 - 2, y))
            points.append((x, y))

        if len(points) >= 2:
            draw.line(
                points,
                fill=color,
                width=5,
                joint="curve"
            )

        draw.rectangle(
            (x0, y0, x1, y1),
            outline=COL_BORDER,
            width=2
        )

        return img


class SpeakerTester:
    def __init__(self, analyzer, ui_callback):
        self.analyzer = analyzer
        self.ui_callback = ui_callback

        self.busy = False

        # Die drei originalen Uwuntu-Dreiklang-Dateien müssen pro Kanal
        # tatsächlich erzeugt werden. Beim ersten integrierten Build fehlten
        # diese Zuweisungen; dadurch liefen die Buttons direkt auf Fehler/Rot.
        self.left_tone = make_tone("left")
        self.both_tone = make_tone("both")
        self.right_tone = make_tone("right")

        # Wiedergabe bevorzugt über Pulse/PipeWire. APlay und sounddevice
        # bleiben als Fallback, damit der Test auf verschiedenen Uwuntu-
        # Hardwareständen zuverlässig Ton ausgibt.
        self.players = [
            player for player in (shutil.which("paplay"), shutil.which("aplay"))
            if player
        ]

        # Schnelle manuelle Wiedergabe nach dem AUTO-Test:
        # separate Player-Prozesse dürfen parallel laufen, damit Links/Rechts
        # bei schnellem Tastendruck bewusst leicht überlappen können.
        self.quick_processes = []
        self.quick_lock = threading.Lock()

    def _cleanup_quick_processes(self):
        with self.quick_lock:
            self.quick_processes = [
                proc for proc in self.quick_processes
                if proc.poll() is None
            ]

    def stop_quick_playback(self):
        with self.quick_lock:
            processes = list(self.quick_processes)
            self.quick_processes = []

        for proc in processes:
            if proc.poll() is None:
                try:
                    proc.terminate()
                except Exception:
                    pass

    def quick_play(self, side):
        """Ton sofort und nicht-blockierend abspielen.

        Dieser Weg ist absichtlich KEIN neuer Messlauf. Er wird erst nach
        abgeschlossenem AUTO-Test für Links/Rechts verwendet. Mehrere schnelle
        Tastendrücke dürfen parallel laufen und sich dadurch leicht überlappen.
        """
        tone_path = self.tone_path(side)
        self._cleanup_quick_processes()

        for player in self.players:
            try:
                proc = subprocess.Popen(
                    [player, str(tone_path)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                with self.quick_lock:
                    self.quick_processes.append(proc)
                return True
            except Exception:
                pass

        # Fallback ohne paplay/aplay. sounddevice kann je nach Backend einen
        # vorherigen sd.play-Aufruf ersetzen; der normale Uwuntu-Installations-
        # weg installiert deshalb weiterhin paplay/aplay für echte Überlappung.
        def fallback():
            try:
                with wave.open(str(tone_path), "rb") as w:
                    channels = w.getnchannels()
                    rate = w.getframerate()
                    raw = w.readframes(w.getnframes())
                audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                audio = audio.reshape(-1, channels)
                sd.play(audio, rate, blocking=True)
            except Exception:
                pass

        threading.Thread(target=fallback, daemon=True).start()
        return True

    def tone_path(self, side):
        if side == "left":
            return self.left_tone
        if side == "right":
            return self.right_tone
        return self.both_tone

    def manual_test(self, side):
        if self.busy:
            return

        self.busy = True

        threading.Thread(
            target=self._single_worker,
            args=(side,),
            daemon=True
        ).start()

    def auto_test(self):
        if self.busy:
            return

        # Ein neuer vollständiger AUTO-Test soll mit sauberer Baseline starten.
        # Eventuell noch laufende Spaß-/Überlappungstöne vorher beenden.
        self.stop_quick_playback()
        self.busy = True

        threading.Thread(
            target=self._auto_worker,
            daemon=True
        ).start()

    def play(self, side):
        tone_path = self.tone_path(side)

        # Erst die systemnahen Player probieren. Ein Player gilt nur dann
        # als erfolgreich, wenn er mit Returncode 0 beendet wird.
        for player in self.players:
            try:
                result = subprocess.run(
                    [player, str(tone_path)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=4,
                    check=False
                )
                if result.returncode == 0:
                    return
            except Exception:
                pass

        # Letzter Fallback: WAV direkt über sounddevice abspielen.
        try:
            with wave.open(str(tone_path), "rb") as w:
                channels = w.getnchannels()
                rate = w.getframerate()
                raw = w.readframes(w.getnframes())
            audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            audio = audio.reshape(-1, channels)
            sd.play(audio, rate, blocking=True)
            return
        except Exception as exc:
            raise RuntimeError(f"Audio-Wiedergabe fehlgeschlagen: {exc}")

    def measure_baseline(self):
        end = time.monotonic() + 0.35
        start = end - 0.30
        time.sleep(0.35)

        samples = self.analyzer.samples_between(start, end)

        return self.analyzer.signature_levels(samples)

    def run_test(self, side):
        # Den Button sofort blau setzen. Danach bewusst eine kurze ruhige
        # Baseline neu aufnehmen. Dadurch kann derselbe Test direkt nach
        # einem vorherigen Ton erneut gestartet werden, ohne dass der alte
        # Dreiklang noch als "Grundrauschen" in die Bewertung eingeht.
        self.ui_callback(
            "playing",
            side,
            None
        )

        baseline_start = time.monotonic()
        time.sleep(0.30)
        baseline_end = time.monotonic()
        baseline_samples = self.analyzer.samples_between(
            baseline_start,
            baseline_end
        )
        baseline = self.analyzer.signature_levels(baseline_samples)

        start = time.monotonic()
        self.play(side)
        end = time.monotonic()

        # Noch einen kleinen Nachlauf mitnehmen.
        time.sleep(0.12)
        capture = self.analyzer.samples_between(
            start - 0.03,
            end + 0.10
        )

        measured = self.analyzer.signature_levels(capture)

        improvements = {
            freq: measured[freq] - baseline.get(freq, -120.0)
            for freq, _duration in TONE_NOTES
        }

        # Der Dreiklang soll als Dreiklang angekommen sein:
        # alle drei erwarteten Frequenzen müssen gegenüber Grundrauschen
        # deutlich ansteigen.
        pass_notes = 0
        weak_notes = 0

        for freq, _duration in TONE_NOTES:
            level = measured[freq]
            improvement = improvements[freq]

            if level >= -48.0 and improvement >= 7.0:
                pass_notes += 1
            elif level >= -58.0 and improvement >= 4.0:
                weak_notes += 1

        avg_level = float(np.mean(list(measured.values())))
        avg_improvement = float(np.mean(list(improvements.values())))

        # Robuste Hardware-Test-Bewertung:
        #
        # Notebook-Lautsprecher und Mikrofonpositionen haben oft deutlich
        # unterschiedliche Frequenzgänge. Ein einzelner Ton des Dreiklangs
        # kann daher schwächer sein, obwohl der Lautsprecher klar funktioniert.
        #
        # PASS:
        # - alle 3 Töne sauber erkannt
        # ODER
        # - mindestens 2/3 Töne sauber erkannt UND das Gesamtsignal ist
        #   deutlich laut genug und hebt sich klar vom Grundrauschen ab.
        #
        # WEAK:
        # - Dreiklang insgesamt erkennbar, aber Pegel/Abstand ist knapp.
        if pass_notes == 3:
            result = "pass"
        elif (
            pass_notes >= 2
            and avg_level >= -42.0
            and avg_improvement >= 10.0
        ):
            result = "pass"
        elif (
            pass_notes + weak_notes >= 2
            and avg_level >= -52.0
            and avg_improvement >= 6.0
        ):
            result = "pass"
        else:
            result = "fail"

        details = {
            "level": avg_level,
            "improvement": avg_improvement,
            "notes": pass_notes,
            "levels": measured,
        }

        self.ui_callback(
            result,
            side,
            details
        )

        return result

    def _single_worker(self, side):
        try:
            self.run_test(side)

        except Exception as exc:
            self.ui_callback(
                "error",
                side,
                str(exc)
            )

        finally:
            self.busy = False
            self.ui_callback(
                "idle",
                None,
                None
            )

    def _auto_worker(self):
        try:
            self.ui_callback(
                "auto_start",
                None,
                None
            )

            results = {}

            for index, side in enumerate(("left", "both", "right")):
                results[side] = self.run_test(side)

                if index < 2:
                    time.sleep(0.45)

            left = results["left"]
            both = results["both"]
            right = results["right"]

            if left == "pass" and both == "pass" and right == "pass":
                overall = "auto_pass"
            else:
                overall = "auto_fail"

            self.ui_callback(
                overall,
                None,
                results
            )

        except Exception as exc:
            self.ui_callback(
                "error",
                None,
                str(exc)
            )

        finally:
            self.busy = False
            self.ui_callback(
                "idle",
                None,
                None
            )


class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)

        self.set_title(f"Uwuntu Audio Test {VERSION}")
        self.set_default_size(850, 410)

        # Einheitliche Titelleiste: Fenstertitel mittig, REFRESH rechts.
        self.header_bar = Gtk.HeaderBar()
        self.header_bar.set_show_title_buttons(True)

        title_label = Gtk.Label(label=f"Uwuntu Audio Test {VERSION}")
        title_label.add_css_class("title")
        self.header_bar.set_title_widget(title_label)

        self.refresh_button = Gtk.Button(label="REFRESH")
        self.refresh_button.add_css_class("refresh-button")
        self.refresh_button.set_focusable(False)
        self.refresh_button.connect("clicked", self.on_refresh_clicked)
        self.header_bar.pack_end(self.refresh_button)

        self.set_titlebar(self.header_bar)

        self.analyzer = AudioAnalyzer()
        self.renderer = WaveRenderer()
        self.last_trigger_at = {
            "left": 0.0,
            "both": 0.0,
            "right": 0.0,
            "auto": 0.0,
        }

        # Nach dem AUTO-Test bleiben erfolgreiche Einzelkanäle bestehen.
        # Grüne Kanäle dürfen weiter schnell abgespielt werden; ein roter Kanal
        # startet beim erneuten Drücken dagegen einen echten Messlauf.
        # Sobald dadurch alle drei Kanäle Grün sind, wird AUTO ebenfalls Grün.
        self.quick_play_enabled = False
        self.hardware_refresh_stamp = hardware_refresh_stamp()

        # Nur ein tatsächlich laufender, gemessener Lautsprechertest
        # übersteuert die Live-Farbe des Mikrofons vorübergehend mit Blau.
        self.speaker_scan_active = False
        self.all_speakers_passed = False

        # Sichtzustände merken, damit ein schneller Links/Rechts-Spaßton
        # während der Wiedergabe blau werden und danach wieder auf das
        # Testergebnis (grün/rot) zurückspringen kann.
        self.button_states = {
            "left": "orange",
            "both": "orange",
            "right": "orange",
            "auto": "orange",
        }

        # Testergebnis getrennt vom transienten Blauzustand merken.
        # Sonst kann ein zweiter schneller Klick "blau" als Rückkehrfarbe
        # übernehmen und der Button bleibt danach hängen.
        self.result_states = {
            "left": "orange",
            "both": "orange",
            "right": "orange",
        }

        self.quick_visual_generation = {
            "left": 0,
            "right": 0,
        }

        css = Gtk.CssProvider()
        css.load_from_data(b"""
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
            background: #0e1114;
            color: #f4f4f5;
        }

        button.audio-button {
            min-height: 40px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 800;
            padding: 4px 8px;
        }

        button.state-orange {
            background: #232329;
            color: #f5a623;
            border: 1px solid #f5a623;
        }

        button.state-blue {
            background: #232329;
            color: #5aa2ff;
            border: 1px solid #5aa2ff;
        }

        button.state-green {
            background: #232329;
            color: #61d36b;
            border: 1px solid #61d36b;
        }

        button.state-red {
            background: #232329;
            color: #ff4c4c;
            border: 1px solid #ff4c4c;
        }

        button.refresh-button {
            min-height: 22px;
            padding: 1px 7px;
            border-radius: 7px;
            font-size: 11px;
            font-weight: 800;
        }
        """)

        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        root = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=7
        )
        root.set_margin_top(7)
        root.set_margin_bottom(7)
        root.set_margin_start(7)
        root.set_margin_end(7)
        self.set_child(root)

        # ----------------------------------------------------
        # Waveform ohne eingeblendeten Button – REFRESH sitzt jetzt
        # ausschließlich in der Titelleiste.
        # ----------------------------------------------------
        self.wave_overlay = Gtk.Overlay()
        self.wave_overlay.set_hexpand(True)
        self.wave_overlay.set_vexpand(True)

        self.picture = Gtk.Picture()
        self.picture.set_hexpand(True)
        self.picture.set_vexpand(True)
        self.picture.set_can_shrink(True)

        try:
            self.picture.set_keep_aspect_ratio(False)
        except Exception:
            pass

        self.wave_overlay.set_child(self.picture)
        root.append(self.wave_overlay)

        # ----------------------------------------------------
        # Vier kompakte Testbuttons
        # ----------------------------------------------------
        buttons = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=7
        )
        root.append(buttons)

        self.left_button = Gtk.Button(label="←  LINKS")
        self.middle_button = Gtk.Button(label="↑  MITTE")
        self.right_button = Gtk.Button(label="RECHTS  →")
        self.auto_button = Gtk.Button(label="↓  AUTO")

        self.button_map = {
            "left": self.left_button,
            "both": self.middle_button,
            "right": self.right_button,
            "auto": self.auto_button,
        }

        for button in self.button_map.values():
            button.set_hexpand(True)
            button.add_css_class("audio-button")
            button.add_css_class("state-orange")
            button.set_focusable(False)
            buttons.append(button)

        self.left_button.connect(
            "clicked",
            lambda *_: self.trigger_test("left")
        )
        self.middle_button.connect(
            "clicked",
            lambda *_: self.trigger_test("both")
        )
        self.right_button.connect(
            "clicked",
            lambda *_: self.trigger_test("right")
        )
        self.auto_button.connect(
            "clicked",
            lambda *_: self.trigger_test("auto")
        )

        # ----------------------------------------------------
        # Tastatur
        # ----------------------------------------------------
        key = Gtk.EventControllerKey()
        key.connect("key-pressed", self.on_key)
        self.add_controller(key)

        self.connect("close-request", self.on_close)

        if self.analyzer.start():
            write_mic_state("detected")
        else:
            # Waveform bleibt trotzdem sichtbar; bei fehlendem Mikrofon
            # können die Lautsprechertests nur nicht automatisch bestehen.
            write_mic_state("missing")

        self.speaker_tester = SpeakerTester(
            self.analyzer,
            self.speaker_event
        )

        self.update_picture()

        GLib.timeout_add(
            UI_REFRESH_MS,
            self.refresh
        )
        GLib.timeout_add(250, self.poll_hardware_refresh)

        # Beim Öffnen einmal automatisch den kompletten Audio-Test starten.
        # Kurze Wartezeit: Mikrofon-Stream und Fenster dürfen erst stabil anlaufen.
        GLib.timeout_add(1400, self.start_initial_auto_test)

    def start_initial_auto_test(self):
        self.trigger_test("auto")
        return False

    def poll_hardware_refresh(self):
        stamp = hardware_refresh_stamp()

        if not stamp or stamp == self.hardware_refresh_stamp:
            return True

        if self.speaker_tester.busy:
            return True

        self.hardware_refresh_stamp = stamp
        self.quick_play_enabled = False
        self.reset_side_buttons()
        self.set_button_state("auto", "orange")
        write_mic_state(
            "detected"
            if self.analyzer.running
            else "missing"
        )
        return True

    def trigger_test(self, action):
        # Einheitlicher Einstieg für Buttons, lokale Pfeiltasten und globale
        # GApplication-Aktionen aus dem Hardware Check.
        if action not in self.last_trigger_at:
            return False

        now = time.monotonic()

        # Für den gewünschten "Spaßmodus" nach AUTO nur sehr kurz entprellen:
        # Links/Rechts dürfen schnell hintereinander und parallel abgespielt
        # werden, sodass sich die Dreiklänge leicht überlappen.
        debounce = 0.045 if (
            self.quick_play_enabled
            and action in ("left", "right")
            and self.result_states.get(action) == "green"
        ) else 0.12

        if now - self.last_trigger_at[action] < debounce:
            return False
        self.last_trigger_at[action] = now

        if self.speaker_tester.busy:
            return False

        if action == "auto":
            self.quick_play_enabled = False
            self.speaker_tester.auto_test()
            return True

        if self.quick_play_enabled and action in ("left", "both", "right"):
            result_state = self.result_states.get(action, "orange")

            # Nach einem fehlgeschlagenen AUTO-Test muss nur der rote Kanal
            # erneut geprüft werden. Der Ton wird abgespielt UND erneut über
            # das Mikrofon gemessen; bereits grüne Kanäle bleiben erhalten.
            if result_state == "red":
                self.speaker_tester.manual_test(action)
                return True

            # Erfolgreiche Links/Rechts-Kanäle behalten den schnellen
            # Überlappungsmodus ohne neuen Messlauf.
            if action in ("left", "right") and result_state == "green":
                previous_state = result_state
                self.quick_visual_generation[action] += 1
                generation = self.quick_visual_generation[action]

                self.set_button_state(action, "blue")
                self.speaker_tester.quick_play(action)

                # Gesamtdauer des Dreiklangs liegt bei rund 0,71 s.
                # Danach Testergebnis wieder sichtbar machen.
                GLib.timeout_add(
                    760,
                    self.restore_quick_button_state,
                    action,
                    generation,
                    previous_state,
                )
                return True

        self.speaker_tester.manual_test(action)
        return True

    def restore_quick_button_state(self, action, generation, previous_state):
        if self.quick_visual_generation.get(action) != generation:
            return False
        self.set_button_state(action, previous_state)
        return False

    def update_auto_from_individual_results(self):
        """AUTO nach Einzel-Nachtests aus den drei gespeicherten Resultaten ableiten."""
        if all(
            self.result_states.get(side) == "green"
            for side in ("left", "both", "right")
        ):
            self.all_speakers_passed = True
            self.set_button_state("auto", "green")
            self.quick_play_enabled = True
            write_mic_state("tested" if self.analyzer.running else "missing")
            return True

        # Ein noch roter Einzeltest bedeutet: Gesamttest noch nicht bestanden.
        if any(
            self.result_states.get(side) == "red"
            for side in ("left", "both", "right")
        ):
            self.set_button_state("auto", "red")
            write_mic_state("detected" if self.analyzer.running else "missing")

        return False

    def on_refresh_clicked(self, _button):
        # REFRESH = Ergebnis zurücksetzen und den kompletten Audio-Test
        # erneut ausführen. Während eines laufenden Tests ignorieren wir
        # zusätzliche Klicks; unmittelbar danach ist REFRESH wieder nutzbar.
        if self.speaker_tester.busy:
            return
        self.quick_play_enabled = False
        self.reset_side_buttons()
        self.set_button_state("auto", "orange")
        self.trigger_test("auto")

    def set_button_state(self, name, state):
        button = self.button_map.get(name)
        if button is None:
            return

        for cls in (
            "state-orange",
            "state-blue",
            "state-green",
            "state-red",
        ):
            button.remove_css_class(cls)

        button.add_css_class("state-" + state)
        self.button_states[name] = state

    def reset_side_buttons(self):
        self.set_button_state("left", "orange")
        self.set_button_state("both", "orange")
        self.set_button_state("right", "orange")
        self.result_states["left"] = "orange"
        self.result_states["both"] = "orange"
        self.result_states["right"] = "orange"

    def pil_to_texture(self, img):
        rgba = img.convert("RGBA")
        raw = rgba.tobytes()
        gbytes = GLib.Bytes.new(raw)

        pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(
            gbytes,
            GdkPixbuf.Colorspace.RGB,
            True,
            8,
            rgba.width,
            rgba.height,
            rgba.width * 4
        )

        return Gdk.Texture.new_for_pixbuf(pixbuf)

    def update_picture(self):
        if not self.analyzer.running:
            waveform_color = "red"
        elif self.speaker_scan_active:
            waveform_color = "blue"
        elif self.all_speakers_passed:
            waveform_color = "green"
        else:
            waveform_color = self.analyzer.color_name

        image = self.renderer.render(
            self.analyzer.waveform,
            waveform_color
        )

        texture = self.pil_to_texture(image)
        self.picture.set_paintable(texture)
        self._texture = texture

    def set_buttons_sensitive(self, value):
        for button in self.button_map.values():
            button.set_sensitive(value)

    def speaker_event(self, event, side, data):
        GLib.idle_add(
            self._speaker_event_ui,
            event,
            side,
            data
        )

    def _speaker_event_ui(self, event, side, data):
        # ----------------------------------------------------
        # AUTO startet:
        # Auto = blau, die drei Einzeltasten gehen wieder auf Orange
        # und werden danach nacheinander blau/gruen/rot.
        # ----------------------------------------------------
        if event == "auto_start":
            self.quick_play_enabled = False
            self.speaker_scan_active = False
            self.all_speakers_passed = False
            self.reset_side_buttons()
            self.set_button_state("auto", "blue")
            write_mic_state("auto" if self.analyzer.running else "missing")
            return False

        # ----------------------------------------------------
        # Einzeltest läuft
        # ----------------------------------------------------
        if event == "playing":
            if side in ("left", "both", "right"):
                self.set_button_state(side, "blue")
                self.speaker_scan_active = True

            return False

        # ----------------------------------------------------
        # Einzeltest fertig
        # ----------------------------------------------------
        if event == "pass":
            self.speaker_scan_active = False
            if side in ("left", "both", "right"):
                self.result_states[side] = "green"
                self.set_button_state(side, "green")

                if all(
                    self.result_states.get(name) == "green"
                    for name in ("left", "both", "right")
                ):
                    self.all_speakers_passed = True

                # Nach einem AUTO-Fehler kann ein einzelner erfolgreicher
                # Nachtest den Gesamtstatus vervollständigen.
                if self.quick_play_enabled:
                    self.update_auto_from_individual_results()
            return False

        if event in ("fail", "weak", "error"):
            self.speaker_scan_active = False
            if side in ("left", "both", "right"):
                self.result_states[side] = "red"
                self.set_button_state(side, "red")
                if self.quick_play_enabled:
                    self.update_auto_from_individual_results()
            return False

        # ----------------------------------------------------
        # Gesamter Auto-Test
        # ----------------------------------------------------
        if event == "auto_pass":
            self.speaker_scan_active = False
            self.all_speakers_passed = True
            self.set_button_state("auto", "green")
            self.quick_play_enabled = True
            write_mic_state("tested" if self.analyzer.running else "missing")
            return False

        if event in ("auto_fail", "auto_weak"):
            self.speaker_scan_active = False
            self.set_button_state("auto", "red")
            write_mic_state("detected" if self.analyzer.running else "missing")

            # Bereits grüne Ergebnisse bleiben gültig. Rote Einzelkanäle
            # können jetzt einzeln erneut abgespielt UND gemessen werden.
            self.quick_play_enabled = True
            return False

        if event == "idle":
            self.speaker_scan_active = False
            # Buttons bleiben grundsätzlich bedienbar. Während ein Test läuft
            # ignoriert SpeakerTester weitere Starts über sein busy-Flag; direkt
            # nach Ende kann derselbe Test sofort erneut gedrückt werden.
            return False

        return False

    def refresh(self):
        self.update_picture()
        return True

    def on_key(self, controller, keyval, keycode, state):
        ctrl = bool(state & Gdk.ModifierType.CONTROL_MASK)

        if ctrl and keyval in (Gdk.KEY_w, Gdk.KEY_W):
            self.close()
            return True

        if ctrl and keyval in (Gdk.KEY_q, Gdk.KEY_Q):
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

        if self.speaker_tester.busy:
            return False

        if keyval == Gdk.KEY_Left:
            self.trigger_test("left")
            return True

        if keyval == Gdk.KEY_Up:
            self.trigger_test("both")
            return True

        if keyval == Gdk.KEY_Right:
            self.trigger_test("right")
            return True

        if keyval == Gdk.KEY_Down:
            self.trigger_test("auto")
            return True

        return False

    def on_close(self, *args):
        try:
            self.speaker_tester.stop_quick_playback()
        except Exception:
            pass
        self.analyzer.stop()
        return False


class App(Gtk.Application):
    def __init__(self):
        super().__init__(
            application_id="com.david.UwuntuAudioTest"
        )
        self.window = None

        # Globale Hardware-Check-Pfeiltasten können diese Aktionen per
        # `gapplication action` auslösen, auch wenn Wipe Auto den Fokus hat.
        for action_name in ("left", "both", "right", "auto"):
            action = Gio.SimpleAction.new(action_name, None)
            action.connect("activate", self.on_audio_action, action_name)
            self.add_action(action)

    def on_audio_action(self, _action, _parameter, action_name):
        if self.window is not None:
            self.window.trigger_test(action_name)

    def do_activate(self):
        if self.window is None:
            self.window = MainWindow(self)
        self.window.present()


if __name__ == "__main__":
    app = App()
    raise SystemExit(app.run(sys.argv))
PYCODE

chmod +x "$PY_FILE"

echo "Starte $APP_NAME ..."
exec -a uwuntu-audio-test-python python3 "$PY_FILE"
